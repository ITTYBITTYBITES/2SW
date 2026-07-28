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

## Largest fraction of the screen a single safe-area inset may ever claim.
##
## A real notch is ~5% of the height and a gesture bar less than that. This is
## a backstop against a platform reporting a rectangle in the wrong coordinate
## space — which Windows does, and which cropped 555px off the bottom of every
## screen in the game. See _resolve_safe_area().
const SAFE_INSET_MAX_FRAC: float = 0.25

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

	# ── DESKTOP AND EDITOR REPORT THE MONITOR, NOT THE WINDOW ────────────
	#
	# THE BUG THIS FIXES, and it broke every screen in the game.
	#
	# On Android get_display_safe_area() returns the window's usable area
	# inside the notch and gesture bar, which is what the arithmetic below
	# assumes. On Windows/Linux/macOS it returns the SCREEN WORK AREA — the
	# whole monitor minus the taskbar — which has nothing to do with the
	# game window and is usually much LARGER than it.
	#
	# Reported from a 817x1452 debug window on a 1080p monitor: safe area
	# came back as 1920x1032, so
	#
	#     safe_bottom = (1452 - (0 + 1032)) * (1920/1452) = 555px
	#     safe_right  = (817  - (0 + 1920)) * (1080/817)  = -1458px
	#
	# 555 virtual pixels were then subtracted from the bottom of every
	# anchored child on every screen. The trial's play field collapsed and
	# slid down, the hub's eye was cropped and its whole nav dock pushed off
	# the bottom edge. Both were reported: "the top 40% of the screen is
	# empty" and "the eye is cut off and i do not see any of the row items".
	#
	# The old guard only caught `rect.size == win` — an exact match — which
	# is true only when the window happens to fill the work area exactly.
	# Any other window size fell through into the phone branch.
	#
	# A safe area is only meaningful when it is a SUBSET of our own window.
	# Anything else is a different rectangle in a different coordinate space,
	# and the only correct response is to ignore it.
	var plausible: bool = (
		rect.size.x > 0 and rect.size.y > 0
		and win.x > 0 and win.y > 0
		and rect.position.x >= 0 and rect.position.y >= 0
		and rect.position.x + rect.size.x <= win.x
		and rect.position.y + rect.size.y <= win.y
		and rect.size != win
	)
	if not plausible:
		# Editor / desktop: no real insets. Use a small margin so layouts
		# designed here still look right on a notched phone.
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

	# LAST-DITCH SANITY BOUND. Even a plausible-looking rect must never eat
	# a large fraction of the screen: a real notch is ~5% of the height and
	# a gesture bar less. Anything past a quarter is a bad reading, not a
	# device, and silently cropping the game is the worst possible response.
	var cap: float = vp.y * SAFE_INSET_MAX_FRAC
	if safe_top > cap or safe_bottom > cap:
		Log.warn("Screen", ("implausible safe area %s in a %s window; "
			+ "insets clamped") % [str(rect), str(win)])
		safe_top = clampf(safe_top, 0.0, cap)
		safe_bottom = clampf(safe_bottom, 0.0, cap)
	safe_left = clampf(safe_left, 0.0, vp.x * SAFE_INSET_MAX_FRAC)
	safe_right = clampf(safe_right, 0.0, vp.x * SAFE_INSET_MAX_FRAC)


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
