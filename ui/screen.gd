extends Control
class_name Screen
## Screen — base class for everything Router can show.
##
## v1 screens were plain Controls that each hand-rolled their own back handling
## (or, in the case of every trial, didn't — which is why back exited the app).
## Here the contract is explicit and inherited:
##
##   configure(payload)   — args delivered BEFORE _ready(), no global races
##   on_back_requested()  — return true to consume the back press
##   safe_*               — notch/gesture-bar insets, resolved once
##   _setup()             — build the tree. Geometry is NOT valid yet.
##   _layout()            — geometry IS valid. Measure and place here.
##
## Subclasses override _setup() rather than _ready() so the base can guarantee
## safe-area and palette wiring happens first.
##
## ── WHY _layout() EXISTS ────────────────────────────────────────────────
## _ready() runs BEFORE the container pass has sized anything, so `size` is
## whatever the .tscn declared, not what the screen will actually occupy.
## Any controller that measured `size` inside _setup() therefore computed its
## geometry from a stale rect, and the resulting bug was always the same
## shape: an element sized for a screen that never existed.
##
## It bit three times in three sessions, each time diagnosed from scratch:
##   hub_portal      the Iris kept a 508px rect inside a 452px band and drew
##                   through the hint and the Share button
##   trial_results   the action buttons computed a 296px width on a 360px
##                   screen and "Return to Hub" ran off the right edge
##   iris_view       _enforce_square() computed a side from a rect that had
##                   not been laid out, so the shader got the wrong aspect
##
## Every one of those was fixed by hand with a call_deferred. That is the
## fragile pattern this replaces: geometry work belongs in _layout(), which
## the base class guarantees is called only when the rect is real, and again
## on every resize thereafter.

var payload: Dictionary = {}

var safe_top: float = 0.0
var safe_bottom: float = 0.0
var safe_left: float = 0.0
var safe_right: float = 0.0

## Set by a subclass that insets itself, so the base class does not do it
## again. Three screens (consent, chrono card, trend hub) fold safe_top and
## safe_bottom into their own MarginContainer; applying the generic offset on
## top of that double-counted the inset and pushed the consent card 11px off
## the bottom at 800x600 — caught by layout_flow.gd the moment the generic
## pass landed.
var handles_own_safe_area: bool = false

## Last size _layout() ran against, so a resize storm cannot recurse.
var _last_layout_size: Vector2 = Vector2.ZERO


## Called by Router before the node enters the tree.
func configure(p: Dictionary) -> void:
	payload = p


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_resolve_safe_area()
	# Rule B: subscribe in _ready, disconnect in _exit_tree.
	Bus.palette_changed.connect(_on_palette_changed)
	_setup()
	# AFTER _setup(), so a subclass that builds its own layout is inset too.
	apply_safe_area_insets()

	# Geometry hook. resized fires on every subsequent layout change; the
	# deferred call covers the first frame, because reparenting into the
	# Router host does not reliably emit resized and _ready() itself runs
	# before the container pass.
	resized.connect(_run_layout)
	_run_layout.call_deferred()


## Invoke _layout() only when the rect is real and has actually changed.
##
## Guarding on a size change stops a resize storm: _layout() implementations
## routinely set child sizes, which can re-emit resized on this node.
func _run_layout() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	if size.is_equal_approx(_last_layout_size):
		return
	_last_layout_size = size
	_layout()


## Force a re-measure. For a subclass that changes its own content in a way
## that invalidates geometry without the screen itself resizing.
func request_layout() -> void:
	_last_layout_size = Vector2.ZERO
	_run_layout.call_deferred()


## Rule B: every Bus subscription is torn down explicitly. Subclasses that add
## their own subscriptions must override this and call super().
func _exit_tree() -> void:
	if Bus.palette_changed.is_connected(_on_palette_changed):
		Bus.palette_changed.disconnect(_on_palette_changed)


## Override this instead of _ready(). Build nodes here.
##
## `size` is NOT trustworthy at this point. Anything that measures the rect
## belongs in _layout().
func _setup() -> void:
	pass


## Override to measure and place. Called once the rect is real, and again on
## every resize. Must be idempotent: it runs many times per screen.
func _layout() -> void:
	pass


## Override to react to a rank-driven palette change.
func _on_palette_changed(_tier: int) -> void:
	pass


## Override. Return true if this screen handled the back press itself
## (e.g. closed a sub-panel, or showed a "forfeit run?" confirm).
func on_back_requested() -> bool:
	return false


# ─────────────────────────────────────────────────────────────────────────
# Safe area
# ─────────────────────────────────────────────────────────────────────────
## v1 recomputed insets ad-hoc inside TrialBase._apply_safe_area() by poking at
## specific node names ("Root", "Status", "ConfirmButton", "Field") — which
## silently did nothing if a scene used different names. Resolved once here.
func _resolve_safe_area() -> void:
	var win := DisplayServer.window_get_size()
	var rect := DisplayServer.get_display_safe_area()

	# Editor / desktop: no insets reported. Use a small margin so layouts
	# designed here still look right on a notched phone.
	if rect.size == Vector2i.ZERO or rect.size == win:
		safe_top = 28.0
		safe_bottom = 28.0
		safe_left = 0.0
		safe_right = 0.0
		return

	# Convert device pixels to our stretched viewport space.
	var vp := get_viewport_rect().size
	var sx := vp.x / float(maxi(win.x, 1))
	var sy := vp.y / float(maxi(win.y, 1))

	safe_top    = float(rect.position.y) * sy
	safe_bottom = float(win.y - (rect.position.y + rect.size.y)) * sy
	safe_left   = float(rect.position.x) * sx
	safe_right  = float(win.x - (rect.position.x + rect.size.x)) * sx

	# Always keep a little breathing room off the gesture bar.
	safe_bottom = maxf(safe_bottom, 24.0)
	safe_top = maxf(safe_top, 16.0)


## Names a child is allowed to keep at full bleed. A background must reach the
## physical screen edge — insetting it would letterbox the app with bars of the
## wrong colour around a notch.
const FULL_BLEED_NAMES: Array[String] = ["Background", "Backdrop", "Scrim"]


## Push every content child clear of notches and the gesture bar.
##
## THE GAP THIS CLOSES: Screen has resolved safe_top/safe_bottom since Phase 1,
## but only three of eleven screens ever read them — the rest were laid out
## against the raw viewport, so a camera cutout would sit on top of their title
## and the gesture bar under their footer. Measured before fixing: six
## controllers contained zero references to the safe area.
##
## Applied generically here rather than screen by screen, because the next
## screen added would have the same omission.
##
## Only ANCHORED children are adjusted. A child inside a container has its
## position owned by that container, and offsetting it fights the layout pass.
func apply_safe_area_insets() -> void:
	if handles_own_safe_area:
		return
	if safe_top <= 0.0 and safe_bottom <= 0.0:
		return
	for child: Node in get_children():
		if not (child is Control):
			continue
		var control: Control = child as Control
		if control.name in FULL_BLEED_NAMES:
			continue
		# Only reposition children this Screen owns directly and that are
		# anchored rather than container-managed.
		if control.anchor_bottom <= control.anchor_top:
			continue
		control.offset_top += safe_top
		control.offset_bottom -= safe_bottom


## Install the shared vignette + dust backdrop behind everything.
##
## Called by a screen that wants the atmosphere. It is opt-in rather than
## automatic because three screens deliberately own their whole frame — the
## splash ident, the trial field and the intro — and a drifting particle
## field behind a timed reflex test is a distraction, not polish.
##
## Inserted at index 0 so it sits behind every sibling, and after any
## existing Background ColorRect so the flat fill still reads underneath.
func install_atmosphere() -> Atmosphere:
	var existing: Node = get_node_or_null("Atmosphere")
	if existing is Atmosphere:
		return existing as Atmosphere
	var layer := Atmosphere.new()
	layer.name = "Atmosphere"
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	# Directly above a Background fill if there is one, otherwise at the very
	# back. Either way it must not cover the screen's real content.
	var target: int = 1 if get_node_or_null("Background") != null else 0
	move_child(layer, target)
	return layer


## Convenience: a full-rect child inset by the safe area.
func make_safe_container() -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_top", int(safe_top))
	m.add_theme_constant_override("margin_bottom", int(safe_bottom))
	m.add_theme_constant_override("margin_left", int(safe_left + Palette.SPACE_LG))
	m.add_theme_constant_override("margin_right", int(safe_right + Palette.SPACE_LG))
	return m
