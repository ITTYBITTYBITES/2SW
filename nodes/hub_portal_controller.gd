extends Screen
class_name HubPortalController
## HubPortalController — the Hub Portal screen. The Iris is the navigation.
##
## PHASE 3 CONTRACT.
##
## THIS IS A READ-ONLY VIEW MODEL. It renders IrisState and never mutates
## persistent data. Equipping, positioning, and purchasing happen exclusively
## in the Wardrobe (West shard). The only fields this screen writes are the
## TRANSIENT interaction drivers — gaze, dilation, hover, portal transition —
## which are explicitly excluded from IrisState.to_dict() and therefore never
## reach disk.
##
## THE COMPASS BOUNDARY (the v1 bug this fixes):
## v1's IrisCore owned a NAV_SHARDS table containing route names AND asset
## paths, hit-tested them itself, played audio on hover, and called
## change_scene_to_file(). Adding a screen meant editing the eye.
##
## Here the split is absolute:
##   IrisView   reports "shard 2 was committed"    (knows no route names)
##   THIS class maps shard 2 -> "progress"          (knows no rendering)
##   Router     owns the scene swap                 (knows no shards)
##
## Swapping a destination is a one-line change to SHARD_ROUTES.

# ═════════════════════════════════════════════════════════════════════════
# COMPASS MAPPING — the single place shard ids become routes
# ═════════════════════════════════════════════════════════════════════════
const SHARD_ROUTES: Dictionary = {
	IrisState.CompassShard.NORTH_TRIALS: "trial",
	IrisState.CompassShard.EAST_PROGRESS: "progress",
	IrisState.CompassShard.SOUTH_DAILY: "daily",
	IrisState.CompassShard.WEST_PROFILE: "visage",
	IrisState.CompassShard.NORTHEAST_TREND: "trend_hub",
}

const SHARD_LABELS: Dictionary = {
	IrisState.CompassShard.NORTH_TRIALS: "Trials",
	IrisState.CompassShard.EAST_PROGRESS: "Progress",
	IrisState.CompassShard.SOUTH_DAILY: "Daily",
	IrisState.CompassShard.WEST_PROFILE: "Wardrobe",
	IrisState.CompassShard.NORTHEAST_TREND: "Trend Hub",
}

## Unit direction per shard, used to place the marker labels around the eye.
const SHARD_DIRECTIONS: Dictionary = {
	IrisState.CompassShard.NORTH_TRIALS: Vector2(0, -1),
	IrisState.CompassShard.EAST_PROGRESS: Vector2(1, 0),
	IrisState.CompassShard.SOUTH_DAILY: Vector2(0, 1),
	IrisState.CompassShard.WEST_PROFILE: Vector2(-1, 0),
	IrisState.CompassShard.NORTHEAST_TREND: Vector2(0.7071, -0.7071),
}

## Marker ring radius as a fraction of the eye's side length.
## Shard-label ring radius, as a fraction of the eye's short side.
##
## RAISED FROM 0.78 SO THE LABELS CLEAR THE HERO HOUSING.
##
## The baked frame extends to 0.848 of its own half-span, which at
## HOUSING_SPAN 1.95 puts its outer edge 430px from centre on a 520px eye. At
## 0.78 the labels landed at 406px — INSIDE the metal. Measured on a GPU
## capture: "Trials" was invisible (peak luminance 9 against a background of
## 9) and "Trend Hub" sat on bright bronze at 144 over 115.
##
## 0.90 puts them at 468px, clear of the frame with ~38px of margin.
const MARKER_RING_FRAC: float = 0.90

## Sidebar contents, by rail. Route names, resolved through Router.ROUTES.
##
## Adding a destination is appending one string here — the rail builds the
## node, the glyph comes from the shared VisionGlyph roster, and the caption
## comes from the table below. Nothing else changes.
## Rail width. Wide enough for a 68px node plus its caption.
const RAIL_WIDTH: float = 112.0

const SIDEBAR_LEFT: Array[String] = ["settings"]
## Reserved. The rail is built and anchored so a future entry needs no
## layout work.
const SIDEBAR_RIGHT: Array[String] = []

const SIDEBAR_CAPTIONS: Dictionary = {
	"settings": "Settings",
	"progress": "Progress",
	"visage": "Wardrobe",
	"daily": "Daily",
	"trend_hub": "Trends",
}

## The eye's geometry now lives in ui/square_slot.gd, configured on the
## %IrisSlot node in hub_portal.tscn. The design size, minimum, hide
## threshold, band margins and chrome extents that used to be declared here
## were all inputs to hand-rolled arithmetic that AspectRatioContainer does
## natively — see _on_iris_side_resolved() for why they went away.
## Dilation the pupil eases to while a shard is hovered (portal opening).
const HOVER_DILATION: float = 0.78
const REST_DILATION: float = 0.5
## How far the portal transition advances on a commit before the route swaps.
const PORTAL_COMMIT_TARGET: float = 1.0

# ── Scene-unique nodes (Rule B) ──────────────────────────────────────────
@onready var _background: ColorRect = %Background
@onready var _iris_view: IrisView = %IrisView
@onready var _iris_slot: SquareSlot = %IrisSlot
@onready var _left_rail: HubSidebar = %LeftSidebar
@onready var _right_rail: HubSidebar = %RightSidebar
@onready var _markers: Control = %ShardMarkers
@onready var _chrome: Control = %Chrome
@onready var _title: Label = %TitleLabel
@onready var _hint: Label = %HintLabel
@onready var _rank_label: Label = %RankLabel

# ── State ────────────────────────────────────────────────────────────────
## The view model. Owned by the caller; this screen only reads persistent
## fields and writes transient interaction ones.
var _state: IrisState = null
var _marker_labels: Dictionary = {}
var _hovered: int = 0
var _committing: bool = false
## Set once in _setup() after every required node is verified. Guards read
## this instead of re-testing nulls, so a scene-wiring fault is reported once
## rather than silently swallowed on every frame.
var _wired: bool = false


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	_state = _resolve_state()

	# Validate the whole scene contract up front. One loud failure beats a
	# dozen quiet null-checks scattered through the frame loop.
	_wired = (
		Log.must(_iris_view != null, "HubPortal", "%IrisView missing")
		and Log.must(_markers != null, "HubPortal", "%ShardMarkers missing")
		and Log.must(_chrome != null, "HubPortal", "%Chrome missing")
		and Log.must(_hint != null, "HubPortal", "%HintLabel missing")
		and Log.must(_state != null, "HubPortal", "state failed to resolve")
	)
	if not _wired:
		return

	# THE NAV GATE. A brand-new player gets one affordance: tap the eye to
	# begin. The compass appears only after they return from a first trial,
	# because five destinations in front of someone who has not played yet is
	# a menu, not an introduction.
	_state.set_nav_unlocked(Save.has_returned_from_trial())

	install_atmosphere()

	# %ShardMarkers is authored AFTER %IrisBand in hub_portal.tscn so the
	# compass labels paint over the hero housing rather than under it. The
	# frame is larger than the eye, and when the markers came first it covered
	# every label — all five destinations vanished on a GPU capture. Ordering
	# lives in the scene, asserted by the polish audit; nothing to do here.
	_build_sidebars()
	_build_shard_markers()
	_apply_state_to_view()

	_iris_view.set_interactive(true)
	# Compass hit-testing is suppressed while gated: a drag must not preview
	# a destination the player cannot reach. The eye stays tappable.
	_iris_view.set_nav_enabled(_state.nav_unlocked)
	_apply_nav_gate()

	# Rule B: subscribe here, disconnect in _exit_tree.
	Bus.iris_shard_hovered.connect(_on_shard_hovered)
	Bus.iris_shard_committed.connect(_on_shard_committed)
	Bus.iris_tapped.connect(_on_iris_tapped)
	Bus.surprise_drop_earned.connect(_on_surprise_drop)

	_refresh_chrome_text()


## Rule B: tear down every subscription. Screen.super() handles palette.
func _exit_tree() -> void:
	super()
	if _iris_slot != null and _iris_slot.side_resolved.is_connected(_on_iris_side_resolved):
		_iris_slot.side_resolved.disconnect(_on_iris_side_resolved)
	if Bus.iris_shard_hovered.is_connected(_on_shard_hovered):
		Bus.iris_shard_hovered.disconnect(_on_shard_hovered)
	if Bus.iris_shard_committed.is_connected(_on_shard_committed):
		Bus.iris_shard_committed.disconnect(_on_shard_committed)
	if Bus.iris_tapped.is_connected(_on_iris_tapped):
		Bus.iris_tapped.disconnect(_on_iris_tapped)
	if Bus.surprise_drop_earned.is_connected(_on_surprise_drop):
		Bus.surprise_drop_earned.disconnect(_on_surprise_drop)
	if _left_rail != null and _left_rail.node_pressed.is_connected(_on_sidebar_pressed):
		_left_rail.node_pressed.disconnect(_on_sidebar_pressed)
	if _right_rail != null and _right_rail.node_pressed.is_connected(_on_sidebar_pressed):
		_right_rail.node_pressed.disconnect(_on_sidebar_pressed)


## Accept a state passed through Router, or build one from persisted values.
## Phase 4 will replace the fallback with a Progression system read.
func _resolve_state() -> IrisState:
	var incoming: Variant = payload.get("iris_state", null)
	if incoming is IrisState:
		return incoming as IrisState

	var state: IrisState = IrisState.new()
	var stored: Dictionary = Save.get_v("iris", "state", {})
	if not stored.is_empty():
		state.from_dict(stored)
	state.reduced_motion = Palette.reduced_motion()
	return state


func _restyle_rails() -> void:
	if _left_rail != null:
		_left_rail.restyle()
	if _right_rail != null:
		_right_rail.restyle()


func _on_palette_changed(_tier: int) -> void:
	if _background != null:
		_background.color = Palette.COLOR_BACKGROUND
	_style_markers()
	# NOT a connect. This used to call side_resolved.connect() here, which
	# added a DUPLICATE subscription on every palette change — a rank-up left
	# the hub re-laying-out the eye once per past rank. Godot permits
	# repeated connections silently, so nothing complained.
	_restyle_rails()
	_refresh_chrome_text()


## True when the scene contract was satisfied in _setup(). Leaves a debug
## breadcrumb rather than failing silently, but does not spam at warn level
## because per-frame call sites would flood the log.
func _operational(context: String) -> bool:
	if _wired:
		return true
	Log.d("HubPortal", "not wired in %s" % context)
	return false


# ═════════════════════════════════════════════════════════════════════════
# STATE -> VIEW  (read-only direction)
# ═════════════════════════════════════════════════════════════════════════
func _apply_state_to_view() -> void:
	if not _operational("_apply_state_to_view"):
		return
	_iris_view.apply_state(_state)
	CosmeticMount.apply(_iris_view, _state)


## Populate the sidebar rails.
##
## LEFT holds Settings alone. Profile and the rest live inside the settings
## drawer rather than on the hub, because a hub whose job is to present one
## eye should not also be a menu.
##
## RIGHT is deliberately EMPTY and deliberately still built. The rail exists,
## is anchored, and is centred, so adding a destination later is one
## add_node() call rather than a scene edit — and the layout it will occupy
## is already exercised by the polish audit today.
func _build_sidebars() -> void:
	if not _operational("_build_sidebars"):
		return
	for route: String in SIDEBAR_LEFT:
		_left_rail.add_node(route, str(SIDEBAR_CAPTIONS.get(route, route)))
	for route: String in SIDEBAR_RIGHT:
		_right_rail.add_node(route, str(SIDEBAR_CAPTIONS.get(route, route)))

	_left_rail.node_pressed.connect(_on_sidebar_pressed)
	_right_rail.node_pressed.connect(_on_sidebar_pressed)


## A sidebar node was tapped. Same exit as a compass commit: clear the
## interaction, then hand the route to Router.
func _on_sidebar_pressed(route: String) -> void:
	if _committing:
		return
	if not Log.must(Router.ROUTES.has(route), "HubPortal",
			"sidebar node names an unknown route '%s'" % route):
		return
	_committing = true
	_iris_view.set_interactive(false)
	_navigate(route)


## The accent for a destination glyph: the live tier accent, hue-shifted.
##
## Rule D forbids a literal Color outside Palette, and a per-destination
## literal would also drift away from the theme on a rank-up. Shifting the
## current accent keeps every preview in step with the rest of the app.
func _vision_tint(route: String) -> Color:
	var glyph: VisionGlyph = VisionGlyph.for_route(route)
	var accent: Color = Palette.accent()
	if glyph == null:
		return accent
	var shifted: Color = accent
	shifted.h = fposmod(accent.h + glyph.hue_shift / 360.0, 1.0)
	return shifted


## Show or hide the compass according to the gate.
##
## Markers are hidden rather than dimmed. A locked affordance the player
## cannot use is noise on the one screen whose job is to say "tap here".
func _apply_nav_gate() -> void:
	if not _operational("_apply_nav_gate"):
		return
	var unlocked: bool = _state.nav_unlocked
	for shard_id: int in _marker_labels.keys():
		(_marker_labels[shard_id] as Label).visible = unlocked
	_refresh_chrome_text()


func _refresh_chrome_text() -> void:
	if not _operational("_refresh_chrome_text"):
		return
	if _title != null:
		_title.text = "Iris"
		_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
		_title.add_theme_font_size_override(
			"font_size", Palette.font(Palette.FONT_TITLE))
	if _rank_label != null:
		_rank_label.text = "%s · Rank %d" % [
			_state.current_rank_title(), _state.rank_tier]
		_rank_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
		_rank_label.add_theme_font_size_override(
			"font_size", Palette.font(Palette.FONT_SMALL))
	# The hint is the only instruction on this screen, so it must describe
	# what is ACTUALLY possible right now rather than the eventual feature.
	if _state.nav_unlocked:
		_set_hint("Drag from the Iris to travel")
	else:
		_set_hint("Tap the Iris to begin your first trial")


func _set_hint(text: String) -> void:
	if not _operational("_set_hint"):
		return
	_hint.text = text
	_hint.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_hint.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))


# ═════════════════════════════════════════════════════════════════════════
# SHARD MARKERS
# ═════════════════════════════════════════════════════════════════════════
## Labels ringing the eye. Purely indicative — they never receive input, so
## they cannot compete with the eye for a tap.
func _build_shard_markers() -> void:
	if not Log.must(_markers != null, "HubPortal", "%ShardMarkers missing"):
		return
	_markers.mouse_filter = Control.MOUSE_FILTER_IGNORE

	for shard_id: int in SHARD_LABELS.keys():
		var label: Label = Label.new()
		label.text = SHARD_LABELS[shard_id]
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Palette.MARKER_SIZE
		_markers.add_child(label)
		_marker_labels[shard_id] = label

	_style_markers()


## The eye's geometry is owned by %IrisSlot (ui/square_slot.gd), not by this
## controller.
##
## This function used to be forty lines: derive a band between the rank label
## and the hint, subtract margins, clamp a side into it, apply a floor, apply
## a hide threshold, then centre the result — re-run manually from a resized
## signal and a call_deferred. Every one of those steps is what an
## AspectRatioContainer with ratio 1.0 does natively, and each hand-rolled
## step was a place the previous three layout bugs came from.
##
## What remains here is the only part that is genuinely this screen's
## business: the five compass shards orbit the eye, so they must be
## repositioned whenever its radius changes.
func _on_iris_side_resolved(_side: float) -> void:
	_position_markers()


## Geometry hook. Screen guarantees this runs only with a real rect, and
## again on every resize — replacing the hand-rolled resized/call_deferred
## pair this screen used to carry.
func _layout() -> void:
	_fit_rails()
	_position_markers()


## Keep the sidebars clear of the eye and inside the screen.
##
## The rails shipped at fixed offsets (24..136 horizontally, 260 from each
## vertical edge) and both assumptions broke:
##
##   720x1280  the eye grows to fill the width, so its left edge reached 100
##             while the rail still ended at 114 — a 14px overlap and a
##             tap-target conflict on the hero assembly
##   640x360   260 + 260 exceeds a 360px screen, collapsing the rail to zero
##             height and hiding every node on it
##
## Derived from the live eye and the live chrome instead.
func _fit_rails() -> void:
	if not _operational("_fit_rails"):
		return
	var margin: float = Palette.SPACE_LG
	var band_top: float = margin
	if _rank_label != null:
		band_top = _rank_label.position.y + _rank_label.size.y + margin
	var band_bottom: float = size.y - margin
	if _hint != null:
		band_bottom = _hint.position.y - margin
	# Never invert, and never leave less than a single node's worth.
	var band_height: float = maxf(band_bottom - band_top, OrbitNode.DIAMETER)

	# The rail may not cross the eye. Its own width plus a gap is the most it
	# can claim from either edge.
	var eye_left: float = size.x * 0.5
	if _iris_view != null and _iris_view.is_visible_in_tree():
		eye_left = _iris_view.position.x
	var usable: float = maxf(eye_left - margin * 2.0, OrbitNode.DIAMETER)
	var rail_width: float = minf(RAIL_WIDTH, usable)

	for pair: Array in [[_left_rail, true], [_right_rail, false]]:
		var rail: Control = pair[0]
		if rail == null:
			continue
		rail.size = Vector2(rail_width, band_height)
		rail.position = Vector2(
			margin if bool(pair[1]) else size.x - margin - rail_width,
			band_top)


func _position_markers() -> void:
	if not _operational("_position_markers"):
		return
	if not _iris_view.is_visible_in_tree():
		# The slot hides the eye when there is no room for it (640x360
		# landscape). Markers orbiting an invisible eye would float over the
		# chrome, so they go with it.
		for hidden_id: int in _marker_labels.keys():
			(_marker_labels[hidden_id] as Label).visible = false
		return

	# THE BUG THIS FIXES: this read _iris_view.position, which is the eye's
	# offset INSIDE ITS OWN PARENT. Once the eye moved into %IrisSlot that
	# value became (0, 0) while the labels are still children of
	# %ShardMarkers — so every marker was placed 269x216px from where the eye
	# actually is, and three of five hung off the screen edge at 1059x1884
	# (Wardrobe 332px past the left border, Progress 172px past the right).
	#
	# Convert through global space so the two node trees agree no matter how
	# either is reparented later.
	var eye_centre_global: Vector2 = (_iris_view.global_position
		+ _iris_view.size * 0.5)
	var to_marker_space: Transform2D = _markers.get_global_transform().affine_inverse()
	var centre: Vector2 = to_marker_space * eye_centre_global

	var ring: float = minf(_iris_view.size.x, _iris_view.size.y) * MARKER_RING_FRAC
	ring = _clamp_ring_to_screen(centre, ring)

	for shard_id: int in _marker_labels.keys():
		var label: Label = _marker_labels[shard_id]
		# Honour the nav gate. This ran unconditionally and overwrote
		# _apply_nav_gate(), because Screen._layout() fires AFTER _setup() —
		# so the gate hid five markers and the very next frame showed them
		# all again. Two functions owning one property, resolved by making
		# the gate the authority.
		label.visible = _state.nav_unlocked
		var direction: Vector2 = SHARD_DIRECTIONS[shard_id]
		var target: Vector2 = centre + direction * ring
		label.size = label.custom_minimum_size
		# Clamp into the marker container so a label can never leave the
		# screen even if the ring itself is legal — the diagonal Trend Hub
		# shard reaches further than the cardinal four.
		label.position = Vector2(
			clampf(target.x - label.size.x * 0.5,
				0.0, maxf(_markers.size.x - label.size.x, 0.0)),
			clampf(target.y - label.size.y * 0.5,
				0.0, maxf(_markers.size.y - label.size.y, 0.0)))


## Shrink the marker ring until every shard fits inside the container.
##
## MARKER_RING_FRAC is a fraction of the EYE, which says nothing about the
## screen: a 520px eye wants a 406px ring, and on a narrow viewport that puts
## the east and west shards past the border. The ring is a suggestion; the
## screen edge is not.
## Largest ring radius that keeps every shard label on screen AND clear of the
## sidebar rails.
##
## THE RAILS WERE MISSING FROM THIS. The clamp measured only the viewport edge,
## so the westward "Wardrobe" label was pushed flush to x = 0 — straight
## underneath the Settings node on the left rail. Both drew, overlapping, and
## the label was half unreadable. Caught on a GPU capture, not by any check.
##
## The rails are fixed chrome at both edges, so they are part of the boundary
## the labels have to respect, exactly like the screen edge is.
func _clamp_ring_to_screen(centre: Vector2, ring: float) -> float:
	var half: Vector2 = Palette.MARKER_SIZE * 0.5
	var limit: float = ring
	# Horizontal room is bounded by the RAILS, not the window, wherever a rail
	# is present. RAIL_WIDTH plus its inset is what the label must clear.
	var rail: float = RAIL_WIDTH
	for shard_id: int in SHARD_DIRECTIONS.keys():
		var direction: Vector2 = SHARD_DIRECTIONS[shard_id]
		# Largest radius along this direction that keeps the label inside.
		if not is_zero_approx(direction.x):
			var room_x: float = ((_markers.size.x - rail - half.x - centre.x)
				if direction.x > 0.0 else (centre.x - rail - half.x))
			limit = minf(limit, maxf(room_x, 0.0) / absf(direction.x))
		if not is_zero_approx(direction.y):
			var room_y: float = ((_markers.size.y - half.y - centre.y)
				if direction.y > 0.0 else (centre.y - half.y))
			limit = minf(limit, maxf(room_y, 0.0) / absf(direction.y))
	return maxf(limit, 0.0)


func _style_markers() -> void:
	for shard_id: int in _marker_labels.keys():
		var label: Label = _marker_labels[shard_id]
		var active: bool = shard_id == _hovered
		var colour: Color = Palette.accent() if active else Palette.COLOR_TEXT_FAINT
		label.add_theme_color_override("font_color", colour)
		label.add_theme_font_size_override("font_size",
			Palette.font(Palette.FONT_SMALL))


# ═════════════════════════════════════════════════════════════════════════
# INTERACTION — Bus in, Router out
# ═════════════════════════════════════════════════════════════════════════
## The eye reports a hover. We update transient drivers and the marker
## highlight. Nothing persistent is touched.
func _on_shard_hovered(shard_id: int) -> void:
	if _committing:
		return
	_hovered = shard_id
	_style_markers()

	if _state != null:
		_state.set_compass_shard(shard_id)
		_state.set_dilation(
			HOVER_DILATION if shard_id != IrisState.CompassShard.NONE else REST_DILATION)
		_apply_state_to_view()

	# The pupil vision. The controller owns the shard->route mapping, so it
	# tells the eye WHICH glyph; the eye still knows no route names.
	if shard_id == IrisState.CompassShard.NONE:
		_iris_view.hide_vision()
		_state.set_vision("")
		_refresh_chrome_text()
	else:
		var route: String = str(SHARD_ROUTES.get(shard_id, ""))
		if route != "":
			_iris_view.show_vision(route, _vision_tint(route))
			_state.set_vision(route)
		_set_hint("Release to enter %s" % SHARD_LABELS.get(shard_id, "?"))


## Commit: open the portal, then hand off to Router. This is the ONLY place
## a shard id becomes a route.
func _on_shard_committed(shard_id: int) -> void:
	if _committing:
		return
	var route: String = str(SHARD_ROUTES.get(shard_id, ""))
	if not Log.must(route != "", "HubPortal", "no route for shard %d" % shard_id):
		return

	_committing = true
	HapticsManager.pulse(&"ui_tap")
	_iris_view.set_interactive(false)
	_travel_through_portal(route)


## Plain tap in the dead zone — start the next trial. Kept distinct from the
## North shard so a first-time player who hasn't learned the compass still has
## a one-tap path into gameplay.
func _on_iris_tapped(_shard_id: int) -> void:
	if _committing:
		return
	_committing = true
	_iris_view.set_interactive(false)
	_travel_through_portal("trial")


## Dive "through the eye": the pupil dilates into a doorway, then Router swaps.
## Honours reduced motion by skipping straight to the navigation.
func _travel_through_portal(route: String) -> void:
	if not _wired or Palette.reduced_motion():
		_navigate(route)   # branch, not a swallow: navigation still happens
		return

	_iris_view.express(&"flare", 1.0)

	var tween: Tween = create_tween()
	tween.tween_method(_set_portal_progress, 0.0, PORTAL_COMMIT_TARGET,
		Palette.duration(Palette.DURATION_SLOW)).set_trans(Tween.TRANS_CUBIC)
	tween.parallel().tween_property(_chrome, "modulate:a", 0.0,
		Palette.duration(Palette.DURATION_MED))
	tween.tween_callback(func() -> void: _navigate(route))


func _set_portal_progress(value: float) -> void:
	if not _operational("_set_portal_progress"):
		return
	_state.set_portal_transition(value)
	_apply_state_to_view()


func _navigate(route: String) -> void:
	# Reset transient drivers so returning to the hub starts clean rather than
	# resuming mid-dive with a blown-open pupil.
	if _state != null:
		_state.clear_interaction()
	await Router.go(route)


# ═════════════════════════════════════════════════════════════════════════
# SURPRISE DROP
# ═════════════════════════════════════════════════════════════════════════
## An ad milestone landed. The hub only ANNOUNCES it — granting the seed is a
## Wardrobe/economy concern, preserving the read-only rule.
func _on_surprise_drop(drop: Dictionary) -> void:
	var label: String = str(drop.get("label", "A gift from the Iris"))
	_iris_view.express(&"flare", 1.0)
	Bus.toast.emit(label, "✦")
	_set_hint("Surprise drop unlocked — visit the Wardrobe")


# ═════════════════════════════════════════════════════════════════════════
# BACK
# ═════════════════════════════════════════════════════════════════════════
## Hub is a root route. Consume back only while a portal dive is in flight so
## a mid-transition press can't strand the player.
func on_back_requested() -> bool:
	return _committing
