extends SceneTree
## Visual polish audit: measured, not declared.
##
## The existing layout_flow.gd asks "does this fit inside the viewport". That
## catches gross overflow and nothing else. This asks the questions a player
## actually notices:
##
##   * Does a long label overflow its CARD, rather than the screen? A card is
##     a container inside a scroll view, so text can spill out of it while the
##     screen-level check stays perfectly green.
##   * Is every tappable control really 48x48 on screen? A declared
##     custom_minimum_size is an intention; the rendered rect is the truth,
##     and a squeezed HBoxContainer overrides the intention silently.
##   * Do sibling cards share consistent spacing, or does one rail use a
##     different rhythm from another?
##
## Every check reads the LIVE rendered geometry after two frames of layout.

const VIEWPORTS: Array[Vector2i] = [
	Vector2i(1080, 1920),   # design target
	Vector2i(1440, 3200),   # tall modern phone
	Vector2i(1920, 1080),   # landscape
	Vector2i(1280, 720),    # small landscape
	Vector2i(800, 600),     # worst case
	Vector2i(2048, 1536),   # tablet
]

## Platform minimum touch target. Both iOS HIG and Material use 44-48pt; 48 is
## the stricter of the two and the one Android accessibility scanning applies.
const MIN_TOUCH: float = 48.0

## A label may exceed its container by this much before it counts as clipped.
## One pixel of tolerance absorbs rounding in the layout pass.
const OVERFLOW_TOLERANCE: float = 1.0

## Screens that take no payload and can be instantiated bare.
const SCREENS: Array[String] = [
	"res://screens/trend_hub.tscn",
	"res://screens/consent/consent.tscn",
	"res://screens/daily_hub.tscn",
	"res://screens/wardrobe.tscn",
	"res://screens/progress_view.tscn",
	"res://screens/settings_view.tscn",
	"res://screens/trial_results.tscn",
	"res://screens/chrono_pulse/result_card.tscn",
	"res://screens/splash/splash.tscn",
	"res://screens/hub_portal.tscn",
	"res://screens/trial_host.tscn",
]

## A title long enough that WRAPPING IS THE ONLY WAY IT FITS.
##
## Length matters and was measured, not guessed. At a 600px container the
## single-sentence version renders 600px wide with or without autowrap — the
## text simply fits, so the check passed either way and proved nothing.
## Tripling it produces 1242px unwrapped against 600px wrapped, which is the
## margin that makes the assertion bite.
const TORTURE_NAME: String = ("Extraordinarily Long Category Title That Should Wrap "
	+ "Across Several Lines Without Ever Escaping Its Card Boundary "
	+ "No Matter How Narrow The Viewport Happens To Be")

var _fails: Array[String] = []
var _n: int = 0


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ VISUAL POLISH AUDIT ═══\n")
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("wipe")
	await process_frame

	await _audit_branding_and_dialogs()
	await _audit_global_styling()
	await _audit_hub_sidebars()
	await _audit_touch_targets()
	await _audit_label_overflow()
	await _audit_card_spacing()
	await _audit_long_titles()
	await _audit_scroll_width()
	await _audit_shader_alpha()
	await _audit_shader_optics()
	await _audit_text_contrast()
	await _audit_bottom_keepout()
	await _audit_iris_aspect()
	await _audit_hub_iris_fit()
	await _audit_shard_placement()
	await _audit_trial_field()
	await _audit_trial_hud()
	await _audit_visible_on_device()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d POLISH CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


# ─────────────────────────────────────────────────────────────────────────
func _mount(path: String, viewport: Vector2i) -> Control:
	root.content_scale_size = viewport
	root.size = viewport
	await process_frame
	var screen: Control = (load(path) as PackedScene).instantiate()
	if screen.has_method("configure"):
		screen.call("configure", {})
	root.add_child(screen)
	await process_frame
	await process_frame
	return screen


## Every VISIBLE, ENABLED button must be at least MIN_TOUCH on both axes.
##
## Disabled buttons are exempt: they cannot be tapped, so their size is a
## cosmetic question rather than an accessibility one. Invisible ones likewise.
func _audit_touch_targets() -> void:
	print("── touch targets (%.0fx%.0f minimum) ──" % [MIN_TOUCH, MIN_TOUCH])
	for viewport: Vector2i in VIEWPORTS:
		var undersized: Array[String] = []
		for path: String in SCREENS:
			if not ResourceLoader.exists(path):
				continue
			var screen: Control = await _mount(path, viewport)
			_collect_small_targets(screen, undersized, path.get_file())
			screen.free()
			await process_frame
		_ok("all touch targets >= %.0fpx at %dx%d" % [MIN_TOUCH, viewport.x, viewport.y],
			undersized.is_empty(), ", ".join(undersized.slice(0, 4)))


func _collect_small_targets(node: Node, out: Array[String], origin: String) -> void:
	if node is Button:
		var button: Button = node as Button
		if button.visible and not button.disabled and button.is_visible_in_tree():
			var rect: Rect2 = button.get_global_rect()
			if rect.size.y < MIN_TOUCH or rect.size.x < MIN_TOUCH:
				out.append("%s/%s %.0fx%.0f" % [
					origin, button.name, rect.size.x, rect.size.y])
	for child: Node in node.get_children():
		_collect_small_targets(child, out, origin)


## A label must not spill outside the container that owns it.
##
## THE GAP THIS CLOSES: layout_flow.gd checks containment in the VIEWPORT, so
## text overflowing a card while staying on screen passes it completely. A
## card is exactly where a long category name would break.
func _audit_label_overflow() -> void:
	print("── labels stay inside their panels ──")
	for viewport: Vector2i in VIEWPORTS:
		var spilled: Array[String] = []
		for path: String in SCREENS:
			if not ResourceLoader.exists(path):
				continue
			var screen: Control = await _mount(path, viewport)
			_collect_label_overflow(screen, null, spilled, path.get_file())
			screen.free()
			await process_frame
		_ok("no label overflows its panel at %dx%d" % [viewport.x, viewport.y],
			spilled.is_empty(), ", ".join(spilled.slice(0, 4)))


func _collect_label_overflow(node: Node, panel: Control, out: Array[String],
		origin: String) -> void:
	var owner_panel: Control = panel
	if node is PanelContainer:
		owner_panel = node as Control

	if node is Label and owner_panel != null:
		var label: Label = node as Label
		if label.is_visible_in_tree() and not label.text.is_empty():
			var label_rect: Rect2 = label.get_global_rect()
			var panel_rect: Rect2 = owner_panel.get_global_rect()
			var over_right: float = (label_rect.position.x + label_rect.size.x) \
				- (panel_rect.position.x + panel_rect.size.x)
			var over_bottom: float = (label_rect.position.y + label_rect.size.y) \
				- (panel_rect.position.y + panel_rect.size.y)
			if over_right > OVERFLOW_TOLERANCE or over_bottom > OVERFLOW_TOLERANCE:
				out.append("%s/%s +%.0f/+%.0f" % [
					origin, label.name, maxf(over_right, 0.0), maxf(over_bottom, 0.0)])

	for child: Node in node.get_children():
		_collect_label_overflow(child, owner_panel, out, origin)


## Sibling cards in one list must share a spacing rhythm. An inconsistent gap
## reads as a rendering fault even when nothing is technically wrong.
func _audit_card_spacing() -> void:
	print("── card spacing is consistent ──")
	var screen: Control = await _mount("res://screens/trend_hub.tscn",
		Vector2i(1080, 1920))
	var column: Control = screen.get_node_or_null("%CardColumn") as Control
	_ok("the card column exists", column != null)
	if column == null:
		screen.free()
		return

	var gaps: Dictionary = {}
	var previous_bottom: float = -1.0
	for child: Node in column.get_children():
		if not (child is Control):
			continue
		var rect: Rect2 = (child as Control).get_global_rect()
		if previous_bottom >= 0.0:
			gaps[int(round(rect.position.y - previous_bottom))] = true
		previous_bottom = rect.position.y + rect.size.y

	# One distinct gap value across twenty cards. More than one means a card
	# is sized differently from its siblings.
	_ok("all card gaps are identical", gaps.size() <= 1, str(gaps.keys()))
	screen.free()
	await process_frame


## Content must not be WIDER than the scroll view that holds it.
##
## THE BLIND SPOT THIS CLOSES: a PanelContainer expands to fit its child, so a
## non-wrapping label makes the CARD grow with it and the label never overflows
## its panel. Measured: an unwrapped title produced a 523px card inside a 400px
## scroll view — invisible to both the viewport check and the panel check,
## while being exactly the horizontal-clipping bug a player would report.
##
## Horizontal scrolling is disabled on every list in this project, so anything
## wider than the viewport is simply unreachable.
func _audit_scroll_width() -> void:
	print("── scroll content never exceeds its view ──")
	for viewport: Vector2i in VIEWPORTS:
		var too_wide: Array[String] = []
		for path: String in SCREENS:
			if not ResourceLoader.exists(path):
				continue
			var screen: Control = await _mount(path, viewport)
			_collect_wide_content(screen, too_wide, path.get_file())
			screen.free()
			await process_frame
		_ok("no scroll content is too wide at %dx%d" % [viewport.x, viewport.y],
			too_wide.is_empty(), ", ".join(too_wide.slice(0, 4)))

	# NOTE ON WHAT THIS CAN AND CANNOT CATCH:
	# With horizontal_scroll_mode DISABLED, Godot clamps content to the view
	# width — measured directly: a card stayed at 728px inside a 736px scroll
	# even with autowrap switched OFF entirely. So this check cannot fail
	# while horizontal scrolling stays disabled, and disabling autowrap on the
	# real hub does NOT reproduce the 523px overflow seen with an unclamped
	# container.
	#
	# It is kept deliberately: it is the guard that fires the day someone
	# enables horizontal scrolling on a list, which is exactly when unwrapped
	# titles WOULD escape. The honest claim is "structure prevents this", not
	# "wrapping is verified" — _audit_long_titles() covers the wrapping itself
	# against an unclamped container, where the failure is reproducible.
	print("── a long title in a REAL hub card ──")
	for viewport: Vector2i in [Vector2i(800, 600), Vector2i(1080, 1920)]:
		var hub: Control = await _mount("res://screens/trend_hub.tscn", viewport)
		var column: Control = hub.get_node_or_null("%CardColumn") as Control
		if column == null:
			_ok("hub card column present at %dx%d" % [viewport.x, viewport.y], false)
			hub.free()
			continue

		# Build a card the way the hub does, then lengthen its title.
		var stretched: Array[String] = []
		for child: Node in column.get_children():
			_retitle_first_label(child, TORTURE_NAME)
			break
		await process_frame
		await process_frame
		_collect_wide_content(hub, stretched, "trend_hub(long title)")
		_ok("a long card title does not widen the list at %dx%d" % [
				viewport.x, viewport.y],
			stretched.is_empty(), ", ".join(stretched.slice(0, 2)))
		hub.free()
		await process_frame


## Replace the first Label found under a node, so a real card can be given an
## unrealistically long title without rebuilding the screen.
func _retitle_first_label(node: Node, text: String) -> bool:
	if node is Label:
		(node as Label).text = text
		return true
	for child: Node in node.get_children():
		if _retitle_first_label(child, text):
			return true
	return false


func _collect_wide_content(node: Node, out: Array[String], origin: String) -> void:
	if node is ScrollContainer:
		var scroll: ScrollContainer = node as ScrollContainer
		# Only meaningful where horizontal scrolling is OFF; where it is on,
		# wide content is the intended behaviour.
		if scroll.is_visible_in_tree() \
				and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED:
			var view_width: float = scroll.get_global_rect().size.x
			for child: Node in scroll.get_children():
				if not (child is Control):
					continue
				var content: Control = child as Control
				if content is ScrollBar:
					continue
				var width: float = content.get_global_rect().size.x
				if view_width > 1.0 and width > view_width + OVERFLOW_TOLERANCE:
					out.append("%s/%s %.0f>%.0f" % [
						origin, content.name, width, view_width])
	for child: Node in node.get_children():
		_collect_wide_content(child, out, origin)


## Prove wrapping WORKS, not merely that autowrap_mode is set.
##
## A label with autowrap enabled still overflows if its parent never
## constrains its width, so the only honest test is to feed it a name longer
## than any real one and measure.
func _audit_long_titles() -> void:
	print("── long titles wrap instead of overflowing ──")
	for viewport: Vector2i in VIEWPORTS:
		root.content_scale_size = viewport
		root.size = viewport
		await process_frame

		# A container with a REAL fixed width.
		#
		# An earlier version anchored the holder with PRESET_TOP_WIDE, which
		# collapsed it to 1px — the label then reported 1219px of height and
		# "wraps to multiple lines" passed on a degenerate layout that proved
		# nothing. Measured before trusting: an explicit width is the only way
		# this comparison means anything.
		var measure_width: float = minf(600.0, float(viewport.x) - 80.0)
		var holder: PanelContainer = PanelContainer.new()
		holder.custom_minimum_size = Vector2(measure_width, 0.0)
		holder.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		root.add_child(holder)

		var body: VBoxContainer = VBoxContainer.new()
		holder.add_child(body)
		var label: Label = Label.new()
		label.text = TORTURE_NAME
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(label)

		await process_frame
		await process_frame

		var font_size: float = float(label.get_theme_font_size("font_size"))
		var label_rect: Rect2 = label.get_global_rect()

		# The container is fixed, so a wrapping label fits it and an
		# unwrapped one blows past it. This is the comparison that bites.
		_ok("a torture-length title fits its %.0fpx container at %dx%d" % [
				measure_width, viewport.x, viewport.y],
			label_rect.size.x <= measure_width + OVERFLOW_TOLERANCE,
			"label %.0f > container %.0f" % [label_rect.size.x, measure_width])

		# Wrapping means MORE than one line, but not an absurd number of them
		# — the upper bound catches the collapsed-container case that fooled
		# the previous version.
		_ok("it wraps to a sane number of lines at %dx%d" % [viewport.x, viewport.y],
			label_rect.size.y > font_size * 1.2
			and label_rect.size.y < font_size * 12.0,
			"height %.0f, font %.0f" % [label_rect.size.y, font_size])

		holder.free()
		await process_frame


# ═════════════════════════════════════════════════════════════════════════
# SHADER VISIBILITY
# ═════════════════════════════════════════════════════════════════════════
## A shader must not multiply its output alpha by its host rect's alpha.
##
## THE BUG THIS CATCHES, WHICH SHIPPED AND WAS REPORTED BY A PLAYER:
## iris_procedural.gdshader ended with `COLOR = vec4(col, alpha * COLOR.a)`.
## Its host ColorRect ships with color = (0,0,0,0), because the rect is only a
## canvas and a visible fill would draw a solid square behind the eye. The
## multiply therefore zeroed every pixel and the Iris was invisible EVERYWHERE
## it appeared — hub, intro, daily hub — for the entire life of the project.
##
## Every structural test passed: the node existed, had the right size, the
## right script, the right material, and the right uniforms. None of them
## asked whether anything was actually drawn. "It has a shader" is not "it is
## visible".
## The shader's coordinate space must stay isotropic on every host rect.
##
## THE BUG THIS CATCHES: iris_procedural.gdshader hardcoded `p = uv * 2.0`
## under a comment asserting "the view keeps the control square". Measured,
## the rect is square on one of the three screens that mount iris_view:
## hub_portal 520x520, intro 1016x1350 (0.753), daily_hub 1024x200 (5.120).
## Every radial term assumes an isotropic p, so the pupil rendered as an
## ellipse on two screens out of three.
##
## This asserts the shader consumes rect_size AND that IrisView actually
## pushes the live rect into it — a uniform nobody writes is worse than no
## uniform, because it reads as handled.
## The Iris must never draw through the hub's chrome.
##
## THE BUG THIS CATCHES: hub_portal.tscn pinned IrisView to a hardcoded
## +/-260px at anchors_preset 8 (a fixed 520x520 centred on the screen) while
## the hint and Share button anchor to the BOTTOM edge. The gap between them
## shrinks with the viewport, so below roughly 1035px of height the eye was
## drawn straight through "Drag from the Iris to travel" and the "Share Iris"
## button. Reported from a 1059x1884 editor window where the eye ran over
## both.
##
## Three separate faults had to be fixed and each is checked here:
##   1. the fixed 520x520 rect, now fitted to the band between the chrome
##   2. a band derived from .tscn offsets, which ignored the safe-area shift
##      applied to Chrome at runtime (off by exactly the top inset)
##   3. _fit_iris() running only in _setup(), before the container pass had
##      given the screen its final rect, so the stale size survived
## Every compass shard must sit inside the screen and ring the eye.
##
## THE BUG THIS CATCHES: _position_markers() computed the eye centre from
## _iris_view.position — the eye's offset inside ITS OWN parent. Once the
## SquareSlot refactor reparented the eye into %IrisSlot that value became
## (0, 0), while the markers are children of %ShardMarkers. Every shard was
## therefore placed 269x216px from where the eye actually was, and at
## 1059x1884 three of five hung off the screen: Wardrobe 332px past the left
## border, Progress 172px past the right, Trials 15px above the top.
##
## Two independent faults, both checked here: the coordinate-space error, and
## an unbounded ring radius (MARKER_RING_FRAC is a fraction of the EYE, which
## says nothing about the screen).
func _audit_shard_placement() -> void:
	print("── compass shards stay on screen and ring the eye ──")
	# Open the nav gate. On a fresh save the hub hides every shard by design
	# (a first-run player gets one affordance), so without this the audit
	# measures the gated state and reports it as five missing markers.
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("mark_returned_from_trial")
	var shard_state: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	for viewport: Vector2i in HUB_VIEWPORTS:
		var screen: Control = await _mount_hub(viewport, shard_state)
		await create_timer(SETTLE_SEC).timeout
		var eye: Control = _descendant(screen, "CoreEye") as Control
		var markers: Control = _descendant(screen, "ShardMarkers") as Control
		var found: bool = eye != null and markers != null
		_ok("%dx%d: eye and marker layer present" % [viewport.x, viewport.y], found)
		if not found:
			screen.free()
			await process_frame
			continue

		var labels: Array[Label] = []
		for child: Node in markers.get_children():
			if child is Label and (child as Label).is_visible_in_tree():
				labels.append(child as Label)

		# When the eye is hidden (no room) the markers go with it; nothing to
		# place, and that is the declared degradation rather than a failure.
		if not eye.is_visible_in_tree():
			_ok("%dx%d: markers hide with the eye" % [viewport.x, viewport.y],
				labels.is_empty(), "%d still visible" % labels.size())
			screen.free()
			await process_frame
			continue

		_ok("%dx%d: all five shards visible" % [viewport.x, viewport.y],
			labels.size() == 5, "%d shown" % labels.size())

		var eye_centre: Vector2 = eye.global_position + eye.size * 0.5
		for label: Label in labels:
			var pos: Vector2 = label.global_position
			_ok("%dx%d: '%s' is inside the screen" % [
					viewport.x, viewport.y, label.text],
				pos.x >= -OVERFLOW_TOLERANCE
				and pos.y >= -OVERFLOW_TOLERANCE
				and pos.x + label.size.x <= float(viewport.x) + OVERFLOW_TOLERANCE
				and pos.y + label.size.y <= float(viewport.y) + OVERFLOW_TOLERANCE,
				"at (%.0f,%.0f) %.0fx%.0f in %dx%d" % [
					pos.x, pos.y, label.size.x, label.size.y, viewport.x, viewport.y])

			# BEHAVIOUR, not bounds. Staying on screen is not enough: a shard
			# must lie in the DIRECTION it represents, or the compass lies.
			#
			# The first version of this check measured distance from the eye
			# against a fraction of the viewport, and the injected
			# coordinate-space bug passed it — the shards were displaced 216px
			# vertically but the clamps kept them on screen and the threshold
			# was loose enough to swallow it. Direction is the property that
			# actually matters and the one that fails when the centre is wrong.
			var centre: Vector2 = pos + label.size * 0.5
			var offset: Vector2 = centre - eye_centre
			var want: Vector2 = SHARD_UNIT_VECTORS.get(label.text, Vector2.ZERO)
			if want != Vector2.ZERO and offset.length() > 1.0:
				var alignment: float = offset.normalized().dot(want.normalized())
				_ok("%dx%d: '%s' lies to its own compass point" % [
						viewport.x, viewport.y, label.text],
					alignment >= 0.92,
					"offset %s vs direction %s (dot %.2f)" % [
						str(offset.round()), str(want), alignment])

		screen.free()
		await process_frame


func _audit_hub_iris_fit() -> void:
	print("── the hub eye never overlaps its chrome ──")
	for viewport: Vector2i in HUB_VIEWPORTS:
		var screen: Control = await _mount("res://screens/hub_portal.tscn", viewport)
		await create_timer(SETTLE_SEC).timeout
		var eye: Control = _descendant(screen, "CoreEye") as Control
		var hint: Control = _descendant(screen, "HintLabel") as Control
		var rank: Control = _descendant(screen, "RankLabel") as Control
		var found: bool = eye != null and hint != null and rank != null
		_ok("%dx%d: hub parts present" % [viewport.x, viewport.y], found)
		if not found:
			screen.free()
			await process_frame
			continue

		# A hidden eye is the declared degradation on a viewport with no room
		# (640x360 landscape). Not overlapping is trivially true then.
		if eye.is_visible_in_tree():
			var eye_bottom: float = eye.global_position.y + eye.size.y
			var eye_top: float = eye.global_position.y
			_ok("%dx%d: eye clears the hint" % [viewport.x, viewport.y],
				eye_bottom <= hint.global_position.y + OVERFLOW_TOLERANCE,
				"eye bottom %.0f vs hint %.0f" % [eye_bottom, hint.global_position.y])
			_ok("%dx%d: eye clears the rank label" % [viewport.x, viewport.y],
				eye_top >= rank.global_position.y + rank.size.y - OVERFLOW_TOLERANCE,
				"eye top %.0f vs rank bottom %.0f" % [
					eye_top, rank.global_position.y + rank.size.y])
			_ok("%dx%d: eye stays square" % [viewport.x, viewport.y],
				absf(eye.size.x - eye.size.y) <= 1.0,
				"%.0fx%.0f" % [eye.size.x, eye.size.y])
			_ok("%dx%d: eye stays on screen horizontally" % [viewport.x, viewport.y],
				eye.global_position.x >= -OVERFLOW_TOLERANCE
				and eye.global_position.x + eye.size.x <= float(viewport.x) + OVERFLOW_TOLERANCE,
				"x %.0f w %.0f" % [eye.global_position.x, eye.size.x])
		screen.free()
		await process_frame


## Find a node by name anywhere under `root_node`.
##
## %UniqueName only resolves inside its OWNER scene, and CoreEye is owned by
## iris_view.tscn rather than by the screen that instances it, so a
## get_node("%CoreEye") on the screen returns null.
func _descendant(root_node: Node, want: String) -> Node:
	if root_node.name == want:
		return root_node
	for child: Node in root_node.get_children():
		var found: Node = _descendant(child, want)
		if found != null:
			return found
	return null


## The trial play field must be a real band, and the readout must not sit in it.
##
## THE BUG THIS CATCHES: %Stage was anchored full-rect, so the play field was
## the entire window. field_centre() returned the window centre rather than
## the centre of the free area, so every mini-game laid its geometry around a
## point the chrome also occupied. Measured at 1059x1884: the score label sat
## at y=882 and the timer at y=946, both INSIDE a glyph ring spanning y
## 625..1278, and three of six glyphs fell past the bottom of a window shorter
## than the design height. Reported as a trial rendering three glyphs with the
## timer arc sweeping off the right edge.
##
## Checked for EVERY registered mini-game, because the field contract lives in
## the shared host: a fix that only satisfied false_witness would leave the
## other three silently broken.
const TRIAL_IDS: Array[String] = [
	"false_witness", "sequence_recall", "cognitive_conflict", "facet_cascade",
]

const TRIAL_VIEWPORTS: Array[Vector2i] = [
	Vector2i(1080, 1920),
	Vector2i(1059, 1884),
	Vector2i(800, 600),
	Vector2i(360, 640),
]

## A field smaller than this cannot hold a glyph ring without a target
## escaping it.
const MIN_FIELD: float = 100.0

## Screens that opt into the vignette + dust backdrop. The splash, intro and
## trial deliberately do NOT: a drifting particle field behind a timed reflex
## test is a distraction, not polish.
## Android launcher variants Google Play requires.
const ANDROID_ICONS: Array[String] = [
	"res://art/branding/icon_192.png",
	"res://art/branding/icon_adaptive_fg.png",
	"res://art/branding/icon_adaptive_bg.png",
]

## Every controller that owns a ConfirmationDialog.
const DIALOG_SOURCES: Array[String] = [
	"res://nodes/settings_view_controller.gd",
	"res://nodes/trial_controller.gd",
]

const ATMOSPHERE_SCREENS: Array[String] = [
	"res://screens/hub_portal.tscn",
	"res://screens/settings_view.tscn",
	"res://screens/progress_view.tscn",
	"res://screens/wardrobe.tscn",
]

## Which way each shard label must lie from the eye centre. Keyed by the text
## the player reads, so the check is written in the same terms as the screen.
const SHARD_UNIT_VECTORS: Dictionary = {
	"Trials": Vector2(0, -1),
	"Progress": Vector2(1, 0),
	"Daily": Vector2(0, 1),
	"Wardrobe": Vector2(-1, 0),
	"Trend Hub": Vector2(0.7071, -0.7071),
}


func _audit_trial_field() -> void:
	print("── the trial play field is a real band ──")
	for trial_id: String in TRIAL_IDS:
		for viewport: Vector2i in TRIAL_VIEWPORTS:
			var host: Control = await _mount_trial(trial_id, viewport)
			if host == null:
				_ok("%s @ %dx%d mounts" % [trial_id, viewport.x, viewport.y], false)
				continue
			var field: Control = host.get("_minigame") as Control
			var score: Control = host.get_node_or_null("%ScoreLabel") as Control
			var timer: Control = host.get_node_or_null("%TimerLabel") as Control
			var found: bool = field != null and score != null and timer != null
			_ok("%s @ %dx%d has a field and a readout"
				% [trial_id, viewport.x, viewport.y], found)
			if found:
				var top: float = field.global_position.y
				var bottom: float = top + field.size.y
				_ok("%s @ %dx%d field is usable"
					% [trial_id, viewport.x, viewport.y],
					field.size.y >= MIN_FIELD, "%.0fpx tall" % field.size.y)
				_ok("%s @ %dx%d field stays on screen"
					% [trial_id, viewport.x, viewport.y],
					bottom <= float(viewport.y) + OVERFLOW_TOLERANCE,
					"bottom %.0f vs %d" % [bottom, viewport.y])
				# The readout must be OUTSIDE the field, not floating in it.
				for pair: Array in [["score", score], ["timer", timer]]:
					var label: Control = pair[1]
					var centre: float = label.global_position.y + label.size.y * 0.5
					_ok("%s @ %dx%d %s is outside the play field"
						% [trial_id, viewport.x, viewport.y, pair[0]],
						centre <= top + OVERFLOW_TOLERANCE
						or centre >= bottom - OVERFLOW_TOLERANCE,
						"label centre %.0f inside field %.0f..%.0f" % [centre, top, bottom])
			host.free()
			await process_frame


func _mount_trial(trial_id: String, viewport: Vector2i) -> Control:
	root.content_scale_size = viewport
	root.size = viewport
	await process_frame
	var host: Control = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	# Supply the state for the same reason _mount_hub() does: the controller
	# builds one itself by calling Palette.reduced_motion(), which throws
	# under a --script MainLoop, leaving _wired false and no mini-game built.
	var state_script: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	host.call("configure", {"trial_id": trial_id,
		"iris_state": state_script.new(),
		# The audit drives record_answer() directly; the first-run briefing
		# would hold begin_trial() and leave every metric at zero.
		"skip_tutorial": true})
	root.add_child(host)
	await process_frame
	await process_frame
	await process_frame
	return host


func _audit_iris_aspect() -> void:
	print("── the eye stays round on every host rect ──")
	var code: String = FileAccess.get_file_as_string(
		"res://shaders/iris_procedural.gdshader")
	_ok("the shader declares rect_size", code.contains("uniform vec2 rect_size"))
	_ok("the shader divides by the short axis",
		code.contains("min(rect_size.x, rect_size.y)"))
	# Strip comments first. The fix's own explanatory block quotes the old
	# expression, and a substring search over raw source would match the
	# prose describing the bug rather than any live statement.
	_ok("the shader no longer assumes a square control",
		not _strip_comments(code).contains("vec2 p = uv * 2.0;"))

	# Behaviour, not text: mount the view at a deliberately non-square size
	# and read back what the material actually received.
	var view: Control = (load("res://nodes/iris_view.tscn") as PackedScene).instantiate()
	view.custom_minimum_size = Vector2(1016, 1350)
	root.add_child(view)
	view.size = Vector2(1016, 1350)
	await process_frame
	await process_frame
	var core: ColorRect = view.get_node_or_null("%CoreEye") as ColorRect
	_ok("the core rect exists", core != null)
	var mat: ShaderMaterial = null
	if core != null:
		mat = core.material as ShaderMaterial
	_ok("the core carries a shader material", mat != null)
	# Unconditional: guarding these behind `if mat != null` meant that if the
	# material ever went missing, the two checks that verify the elliptical-iris
	# fix (ce886d7) would have silently vanished rather than failed.
	var pushed: Variant = null
	if mat != null:
		pushed = mat.get_shader_parameter("rect_size")
	var vec: Vector2 = pushed if pushed is Vector2 else Vector2.ZERO
	_ok("IrisView pushes the live rect size",
		mat != null and vec.x > 1.0 and vec.y > 1.0, str(vec))
	_ok("the pushed size matches the rendered rect",
		mat != null and core != null and vec.is_equal_approx(core.size),
		"pushed %s vs rect %s" % [
			str(vec), str(core.size) if core != null else "no rect"])
	view.free()
	await process_frame


## Remove // line comments so a source scan tests code, not documentation.
func _strip_comments(code: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for line: String in code.split("\n"):
		var idx: int = line.find("//")
		out.append(line if idx < 0 else line.substr(0, idx))
	return "\n".join(out)


## The Phase 3 optical upgrades must stay physically calibrated.
##
## Every value here was measured on a CPU raster of the shader, not chosen by
## eye. Two of them were WRONG on the first attempt and only measurement
## caught it:
##
##   CORNEA_DEPTH was 0.16, which magnified the pupil 47%. A real cornea
##   magnifies the iris 10-13%; the eye rendered as a fisheye and the stroma
##   ring was crushed to a thin band. 0.045 measures ~11%.
##
##   The lid shadow used `lid_curve - p.y` when +y is DOWN in this space, so
##   it shaded the BOTTOM of the globe. Top/bottom luminance rose to 1.34
##   when a sphere lit from above must fall below 1.0. Corrected to
##   `p.y + lid_curve`, it measures 0.726.
##
## Source-level rather than rendered, because the sandbox has no display
## server. The rendered proof lives in tools/raster_preview.py.
## The hub sidebars stay usable and out of the eye's way.
##
## The rails are the extensible half of the hub: LEFT holds Settings, RIGHT
## is deliberately empty but built, so a future destination is one add_node()
## call rather than a scene edit. Checked at every viewport because an empty
## rail that is correctly anchored today is what makes that promise real.
## The global styling holds across every screen that opts in.
##
## Three things are checked, all BEHAVIOURAL:
##   * the atmosphere layer is present AND behind the content, not over it
##   * panels are translucent, so the vignette reads through them
##   * the panel bevel is asymmetric — an even 1px outline on all four sides
##     is exactly what this replaced, and reads as flat vector art
## The launcher icon and the dialog theme are wired.
##
## Both are configuration rather than layout, and both fail INVISIBLY: a
## missing icon shows Godot's default robot on the home screen, and an
## unthemed dialog looks like a different app's popup. Neither shows up in a
## layout check, which is why they are asserted here.
func _audit_branding_and_dialogs() -> void:
	print("── branding + dialog theme ──")
	var icon_path: String = str(
		ProjectSettings.get_setting("application/config/icon", ""))
	_ok("the app declares a launcher icon", icon_path != "")
	var icon: Texture2D = load(icon_path) as Texture2D
	_ok("the launcher icon loads", icon != null)
	# 512 is the store requirement. Asserted as a MINIMUM so a future
	# higher-resolution icon does not fail here.
	_ok("the launcher icon is at least 512px",
		icon != null and icon.get_width() >= 512
		and icon.get_height() >= 512,
		str(icon.get_size()) if icon != null else "none")

	# ...and it must be a RASTER file. Godot rasterises an SVG to 512x512 on
	# import, so a size check alone cannot tell the two apart — reverting to
	# the old placeholder icon.svg passed the dimension assertion above while
	# shipping a store-invalid asset. Google Play rejects SVG outright.
	_ok("the launcher icon is a raster file for the store",
		icon_path.to_lower().ends_with(".png"), icon_path)

	for variant: String in ANDROID_ICONS:
		var art: Texture2D = load(variant) as Texture2D
		_ok("%s exists" % variant.get_file(), art != null)

	var presets: String = FileAccess.get_file_as_string(
		"res://export_presets.cfg.template")
	_ok("the Android preset names a launcher icon",
		presets.contains("launcher_icons/main_192x192=\"res://"))
	_ok("the Android preset names an adaptive icon",
		presets.contains("adaptive_foreground_432x432=\"res://"))

	# The dialog theme, asserted on source: ArcaneTheme builds a Theme at
	# runtime and there is no dialog mounted here to read it back from.
	var theme_src: String = FileAccess.get_file_as_string(
		"res://ui/arcane_theme.gd")
	_ok("dialogs get a carved panel",
		theme_src.contains("set_stylebox(\"panel\", \"AcceptDialog\""))
	_ok("dialog buttons are restyled",
		theme_src.contains("set_stylebox(\"normal\", \"Button\""))
	_ok("the dialog theme follows the live accent",
		theme_src.contains("var accent: Color = Palette.accent()"))

	# Every dialog in the app must be themed, or one stays grey.
	for source: String in DIALOG_SOURCES:
		var code: String = FileAccess.get_file_as_string(source)
		var dialogs: int = code.count(": ConfirmationDialog = %")
		var applied: int = code.count("ArcaneTheme.apply(")
		_ok("%s themes every dialog it owns" % source.get_file(),
			applied >= dialogs, "%d dialogs, %d themed" % [dialogs, applied])


func _audit_global_styling() -> void:
	print("── global styling ──")
	var state_script: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	for path: String in ATMOSPHERE_SCREENS:
		var screen: Control = await _mount_styled(path, state_script)
		var layer: Node = _descendant(screen, "Atmosphere")
		_ok("%s has the atmosphere layer" % path.get_file(), layer != null)
		# BEHIND the content. An atmosphere drawn on top would veil the UI —
		# the failure mode that matters, and one a presence check misses.
		var behind: bool = false
		if layer != null:
			behind = layer.get_index() <= 1
		_ok("%s draws the atmosphere behind its content" % path.get_file(),
			behind, "index %d" % (layer.get_index() if layer != null else -1))
		screen.free()
		await process_frame

	# Panels come from ONE function, so checking that function checks every
	# panel in the app. Asserted on SOURCE rather than by calling it: under a
	# --script MainLoop the Palette autoload has no script, so panel_style()
	# cannot be invoked here. The properties below are the ones that make a
	# plate read as carved rather than as a flat rectangle.
	var pal_src: String = FileAccess.get_file_as_string("res://design/palette.gd")
	var body: String = pal_src.substr(pal_src.find("func panel_style"))
	body = body.substr(0, body.find("\nfunc "))

	_ok("panels are translucent", body.contains("base.a = PANEL_OPACITY"))
	_ok("panels carry a lit top bevel",
		body.contains("border_width_top = 2")
		and body.contains("border_width_bottom = 1"))
	_ok("panels cast a shadow", body.contains("shadow_size"))
	_ok("the bevel is tinted with the live accent",
		body.contains("var lit: Color = accent()"))
	_ok("panel opacity leaves the backdrop visible",
		pal_src.contains("const PANEL_OPACITY := 0.88"))


func _mount_styled(path: String, state_script: GDScript) -> Control:
	root.content_scale_size = VIEWPORTS[0]
	root.size = VIEWPORTS[0]
	await process_frame
	var screen: Control = (load(path) as PackedScene).instantiate()
	var state: Object = state_script.new()
	state.call("set_nav_unlocked", true)
	screen.call("configure", {"iris_state": state})
	root.add_child(screen)
	await process_frame
	await process_frame
	return screen


func _audit_hub_sidebars() -> void:
	print("── hub sidebars ──")
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("mark_returned_from_trial")

	# The hub needs an IrisState. _resolve_state() builds one itself in the
	# real game, but it finishes by reading Palette.reduced_motion() — and
	# under a --script MainLoop the Palette autoload has no script, so that
	# call throws, state resolves to null, _wired stays false and _setup()
	# returns before building anything. Supplying a state sidesteps the
	# engine limitation without weakening what is being checked.
	var state_script: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	for viewport: Vector2i in HUB_VIEWPORTS:
		var screen: Control = await _mount_hub(viewport, state_script)
		await create_timer(SETTLE_SEC).timeout
		var left: Node = _descendant(screen, "LeftSidebar")
		var right: Node = _descendant(screen, "RightSidebar")
		var eye: Control = _descendant(screen, "CoreEye") as Control
		var found: bool = left != null and right != null and eye != null
		_ok("%dx%d: both rails exist" % [viewport.x, viewport.y], found)
		if not found:
			screen.free()
			await process_frame
			continue

		# The right rail is EMPTY on purpose. Asserting it stays anchored and
		# sized is what proves the extension point is real rather than
		# aspirational.
		_ok("%dx%d: the right rail is reserved and anchored"
			% [viewport.x, viewport.y],
			(right as Control).size.x > 1.0 and (right as Control).size.y > 1.0,
			str((right as Control).size))

		var settings: Button = _descendant(screen, "Orbit_settings") as Button
		_ok("%dx%d: the settings node exists" % [viewport.x, viewport.y],
			settings != null)
		if settings == null:
			screen.free()
			await process_frame
			continue

		var rect: Rect2 = settings.get_global_rect()
		_ok("%dx%d: settings meets the touch minimum" % [viewport.x, viewport.y],
			rect.size.x >= Palette.MIN_TOUCH_TARGET
			and rect.size.y >= Palette.MIN_TOUCH_TARGET,
			str(rect.size))
		_ok("%dx%d: settings stays on screen" % [viewport.x, viewport.y],
			rect.position.x >= -OVERFLOW_TOLERANCE
			and rect.position.y >= -OVERFLOW_TOLERANCE
			and rect.position.x + rect.size.x <= float(viewport.x) + OVERFLOW_TOLERANCE
			and rect.position.y + rect.size.y <= float(viewport.y) + OVERFLOW_TOLERANCE,
			str(rect))

		# The rail must not sit on top of the eye. A node overlapping the
		# hero assembly is both ugly and a tap-target conflict.
		if eye.is_visible_in_tree():
			_ok("%dx%d: settings clears the eye" % [viewport.x, viewport.y],
				rect.position.x + rect.size.x <= eye.global_position.x + OVERFLOW_TOLERANCE,
				"node right %.0f vs eye left %.0f" % [
					rect.position.x + rect.size.x, eye.global_position.x])
		screen.free()
		await process_frame


## Mount the hub with an explicit IrisState. See _audit_hub_sidebars().
func _mount_hub(viewport: Vector2i, state_script: GDScript,
		unlocked: bool = true) -> Control:
	root.content_scale_size = viewport
	root.size = viewport
	await process_frame
	var screen: Control = (load("res://screens/hub_portal.tscn") as PackedScene).instantiate()
	# A fresh IrisState defaults nav_unlocked to false, which is correct for a
	# first run and wrong for an audit of the unlocked hub — the first version
	# of this helper hid all five shards and reported it as a layout failure.
	var state: Object = state_script.new()
	state.call("set_nav_unlocked", unlocked)
	screen.call("configure", {"iris_state": state})
	root.add_child(screen)
	await process_frame
	await process_frame
	return screen


func _audit_shader_optics() -> void:
	print("── the eye shader stays physically calibrated ──")
	var code: String = FileAccess.get_file_as_string(
		"res://shaders/iris_procedural.gdshader")
	var stripped: String = _strip_comments(code)

	_ok("the shader declares a refraction strength",
		stripped.contains("uniform float refraction_strength"))
	_ok("corneal depth is calibrated, not the 0.16 that gave 47% magnification",
		stripped.contains("const float CORNEA_DEPTH = 0.045"))
	_ok("the cornea dome spans wider than the iris",
		stripped.contains("CORNEA_BULGE_SCALE"))

	# THE SIGN. This is the one that produced a plausible-looking image while
	# lighting the eye from underneath.
	_ok("the lid shadow measures DOWNWARD from the lid margin",
		stripped.contains("float below_lid = p.y + lid_curve;"),
		"an inverted sign shades the bottom of the globe")
	_ok("the lid shadow is applied before the lids composite",
		stripped.find("below_lid") < stripped.find("col = mix(col, lid_shaded"))

	_ok("catchlights are anisotropic, not round",
		stripped.contains("curve_stretch"))
	_ok("there is more than one specular lobe",
		stripped.contains("glint_sub") and stripped.contains("glint_halo"))
	_ok("the stroma is layered, not a single octave",
		stripped.contains("fibre_mid") and stripped.contains("fibre_fine"))
	_ok("fibres darken their gaps as well as lightening their ridges",
		stripped.contains("1.0 - (1.0 - fibre)"))
	_ok("the lid has volume rather than a flat fill",
		stripped.contains("lid_shaded"))


func _audit_shader_alpha() -> void:
	print("── shaders do not zero their own output ──")
	for path: String in _shader_paths("res://shaders/"):
		var code: String = FileAccess.get_file_as_string(path)
		_ok("%s loads" % path.get_file(), not code.is_empty())

		# The specific defect: folding the host's alpha into the output.
		var zeroing: bool = (code.contains("alpha * COLOR.a")
			or code.contains("COLOR.a * alpha")
			or code.contains("* COLOR.a)"))
		_ok("%s does not multiply by COLOR.a" % path.get_file(), not zeroing,
			"a transparent host rect would zero every pixel")

	# And the host rect itself: if a scene DOES rely on its alpha, that is
	# worth knowing about explicitly rather than discovering on a screenshot.
	var view: Control = (load("res://nodes/iris_view.tscn") as PackedScene).instantiate()
	root.add_child(view)
	await process_frame
	await process_frame
	var core: ColorRect = view.get_node_or_null("%CoreEye") as ColorRect
	_ok("the Iris core exists", core != null)
	var material_ok: bool = core != null and core.material is ShaderMaterial
	_ok("the Iris core carries a shader material", material_ok)
	# The rect is deliberately transparent — that is fine ONLY because the
	# shader now ignores it. Assert the pairing so neither half can drift.
	_ok("a transparent host rect is safe because the shader ignores it",
		core != null and core.color.a <= 0.01,
		"host alpha %.2f" % (core.color.a if core != null else -1.0))
	view.free()
	await process_frame


## WCAG 2.1 AA contrast floors.
##
## 4.5:1 for body text, relaxed to 3.0:1 for "large" text, which the spec
## defines as 18pt/24px regular or 14pt/18.66px bold. Every token in this app
## is regular weight, so the 24px boundary is the one that applies.
## Long enough for every entrance tween to reach its final alpha, and short
## enough to sample before a timed screen starts animating OUT again.
##
## Measured against the tightest window in the app, the splash: its skip hint
## is delayed by SPONSOR_FADE_IN (0.6s) then fades over DURATION_SLOW (0.42s),
## settling at 1.02s, while the sponsor layer begins fading out at 1.9s. 1.5s
## sits inside that gap. Sampling at 0.9s caught the hint at 3.07:1 mid-fade
## and sampling after 1.9s would catch the layer dissolving — both would be
## measuring the animation instead of the design.
## Viewports the hub must survive. Includes the reported 1059x1884 editor
## window and the short/landscape extremes where the overlap was worst.
const HUB_VIEWPORTS: Array[Vector2i] = [
	Vector2i(1080, 1920),
	Vector2i(1059, 1884),
	Vector2i(720, 1280),
	Vector2i(1080, 2400),
	Vector2i(800, 600),
	Vector2i(360, 640),
	Vector2i(640, 360),
]

const SETTLE_SEC: float = 1.5

const CONTRAST_MIN: float = 4.5
const CONTRAST_MIN_LARGE: float = 3.0
const LARGE_TEXT_PX: int = 24

## Decorative glyphs whose meaning is carried by an adjacent real label.
##
## The streak rail draws hollow "○" markers for days not yet earned; the
## intro draws the same for lines not yet read. Dimness IS the message there
## — an unearned marker that shouts is a worse design than one that recedes,
## and the state is also announced in text beside it. Exempted deliberately
## and narrowly: single-glyph labels only, never anything with words in it.
const DECORATIVE_GLYPHS: Array[String] = ["○", "●", "·", "—", "✦"]


## Relative luminance, per the WCAG 2.1 definition.
func _relative_luminance(c: Color) -> float:
	var channels: Array[float] = [c.r, c.g, c.b]
	for i: int in range(3):
		var v: float = channels[i]
		channels[i] = v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


## Contrast of a possibly-translucent foreground composited over an opaque
## background. Alpha is the whole point: a colour that would pass at full
## opacity can fail badly at 0.34, and reading the RGB alone hides that.
func _contrast_ratio(fg: Color, bg: Color) -> float:
	var composited := Color(
		lerpf(bg.r, fg.r, fg.a),
		lerpf(bg.g, fg.g, fg.a),
		lerpf(bg.b, fg.b, fg.a))
	var l1: float = _relative_luminance(composited)
	var l2: float = _relative_luminance(bg)
	return (maxf(l1, l2) + 0.05) / (minf(l1, l2) + 0.05)


## Walk up the tree for the nearest opaque thing actually painted behind a
## label. Comparing against a guessed backdrop would make the whole check
## fiction, so this reads real ColorRect/Panel fills.
func _backdrop_for(node: Node) -> Color:
	var cursor: Node = node
	while cursor != null:
		if cursor is ColorRect:
			var rect: ColorRect = cursor as ColorRect
			if rect.color.a >= 0.99:
				return rect.color
		if cursor is Panel or cursor is PanelContainer:
			var box: StyleBox = (cursor as Control).get_theme_stylebox("panel")
			if box is StyleBoxFlat and (box as StyleBoxFlat).bg_color.a >= 0.99:
				return (box as StyleBoxFlat).bg_color
		# A sibling painted before this branch is the usual full-screen
		# background: check earlier children of each ancestor too.
		var parent: Node = cursor.get_parent()
		if parent != null:
			for sibling: Node in parent.get_children():
				if sibling == cursor:
					break
				if sibling is ColorRect and (sibling as ColorRect).color.a >= 0.99:
					return (sibling as ColorRect).color
		cursor = parent
	return _palette_background()


## Read a Palette constant WITHOUT naming the autoload.
##
## Naming `Palette` directly from a --script MainLoop forces the identifier to
## resolve while the MainLoop compiles, which happens BEFORE autoloads attach.
## The autoload then materialises as a bare Node with no script, and every
## screen's Palette.accent() call fails — silently styling nothing, which is
## precisely what made the first version of this audit vacuous.
func _palette_background() -> Color:
	var pal: Node = root.get_node_or_null("Palette")
	if pal == null or pal.get_script() == null:
		return Color(0, 0, 0)
	var consts: Dictionary = (pal.get_script() as GDScript).get_script_constant_map()
	return consts.get("COLOR_BACKGROUND", Color(0, 0, 0))


func _is_decorative(text: String) -> bool:
	var trimmed: String = text.strip_edges()
	return trimmed.length() <= 1 and DECORATIVE_GLYPHS.has(trimmed)


## Every visible label must be READABLE, not merely present.
##
## THE BUG THIS CATCHES: COLOR_TEXT_FAINT shipped at alpha 0.34, which
## composites to 2.47:1 over the app's background — barely more than half the
## 4.5:1 AA floor. 75 of 206 labels used it, at 15px and 19px, so none of them
## qualified for the large-text relaxation either. The intro's "tap to
## continue" was the visible symptom: a first-run player was told how to
## advance by a string they could not read.
##
## Why the suite missed it: layout_flow asserted labels FIT and polish asserted
## they did not OVERFLOW. Both are questions about geometry. Neither asked
## whether the pixels differed enough from the backdrop to form letters.
func _audit_text_contrast() -> void:
	print("── text contrast (WCAG AA: %.1f:1, %.1f:1 above %dpx) ──" % [
		CONTRAST_MIN, CONTRAST_MIN_LARGE, LARGE_TEXT_PX])
	for path: String in SCREENS:
		var screen: Control = await _mount(path, VIEWPORTS[0])
		# Let entrance tweens settle. Several screens fade their text in from
		# modulate.a = 0, and sampling mid-fade measures the animation rather
		# than the design — the first run of this check reported 1.00:1 for
		# labels that end up perfectly legible.
		await create_timer(SETTLE_SEC).timeout
		var worst: float = 999.0
		var worst_text: String = ""
		var checked: int = 0
		for label: Label in _all_labels(screen):
			if not label.is_visible_in_tree() or label.text.strip_edges() == "":
				continue
			if _is_decorative(label.text):
				continue
			var fg: Color = label.get_theme_color("font_color")
			fg.a *= label.get_modulate().a * label.get_self_modulate().a
			var size_px: int = label.get_theme_font_size("font_size")
			var floor_needed: float = (CONTRAST_MIN_LARGE
				if size_px >= LARGE_TEXT_PX else CONTRAST_MIN)
			var ratio: float = _contrast_ratio(fg, _backdrop_for(label))
			checked += 1
			# Normalise against the floor so the single worst offender on the
			# screen is reported, whatever its size class.
			if ratio / floor_needed < worst / CONTRAST_MIN:
				worst = ratio * (CONTRAST_MIN / floor_needed)
				worst_text = "%s '%s' %dpx -> %.2f:1 (needs %.1f:1)" % [
					label.name, label.text.substr(0, 24), size_px, ratio, floor_needed]
		_ok("%s: every label meets AA" % path.get_file(),
			worst >= CONTRAST_MIN or checked == 0, worst_text)
		screen.free()
		await process_frame


func _all_labels(node: Node) -> Array[Label]:
	var out: Array[Label] = []
	if node is Label:
		out.append(node as Label)
	for child: Node in node.get_children():
		out.append_array(_all_labels(child))
	return out


## A hint that teaches the core interaction must be inside the visible frame,
## not tucked under the gesture bar.
##
## THE BUG THIS CATCHES: a Root VBox with a -24px bottom offset put the
## teaching hint 52px from the bottom of a 1920px screen — inside the Android
## gesture inset and cropped out entirely. The player saw a dark screen and no
## instruction.
##
## Originally asserted on the intro carousel, which has since been removed.
## Repointed at the HUB's hint, which is now the FIRST instruction a new player
## ever receives and therefore the one that must not be swallowed by the
## gesture bar. The check is more important here, not less.
const BOTTOM_KEEPOUT: float = 64.0


func _audit_bottom_keepout() -> void:
	print("── bottom keep-out (%.0fpx gesture inset) ──" % BOTTOM_KEEPOUT)
	var screen: Control = await _mount("res://screens/hub_portal.tscn", VIEWPORTS[0])
	var hint: Label = screen.get_node_or_null("%HintLabel") as Label
	_ok("the hub hint exists", hint != null)
	# Unconditional: a guarded assertion reports a skip as a pass.
	_ok("the hub hint says how to begin",
		hint != null and hint.text.strip_edges() != "" and hint.visible,
		hint.text if hint != null else "no hint")
	var bottom_gap: float = 0.0
	if hint != null:
		bottom_gap = float(VIEWPORTS[0].y) - (hint.global_position.y + hint.size.y)
	_ok("the hub hint clears the gesture inset",
		hint != null and bottom_gap >= BOTTOM_KEEPOUT,
		"only %.0fpx of clearance" % bottom_gap)
	screen.free()
	await process_frame


# ═════════════════════════════════════════════════════════════════════════
# TRIAL HUD — carved bezels and success/failure feedback
# ═════════════════════════════════════════════════════════════════════════
## Prove the HUD BEHAVES, not that it exists.
##
## The temptation here is to assert that a HudBezel node is present and a
## TrialFeedback node is present, call it two checks and move on. That test
## would pass against a bezel that never draws, an arc frozen at zero, and a
## feedback overlay that plays the success pulse for a wrong answer.
##
## So every check below drives the controller through its REAL entry points —
## record_answer(), the same method every mini-game calls — and asserts a
## consequence that could only happen if the wiring works:
##
##   * the arc moves when accuracy moves, and moves the RIGHT way
##   * a correct answer selects SUCCESS and a wrong answer selects FAILURE
##   * the pulse lands on the target the player pressed, not the screen centre
##   * the label is still reachable as %ScoreLabel after being reparented
##   * the plate is big enough to actually read
func _audit_trial_hud() -> void:
	print("── the trial HUD is carved, wired and reactive ──")

	var host: Control = await _mount_trial("false_witness", TRIAL_VIEWPORTS[0])
	if host == null:
		_ok("the trial host mounts for the HUD audit", false)
		return

	var score_bezel: Control = host.get_node_or_null("%ScoreBezel") as Control
	var timer_bezel: Control = host.get_node_or_null("%TimerBezel") as Control
	var feedback: Control = host.get_node_or_null("%Feedback") as Control
	var score_label: Label = host.get_node_or_null("%ScoreLabel") as Label

	var present: bool = (score_bezel != null and timer_bezel != null
		and feedback != null and score_label != null)
	_ok("the HUD bezels and feedback overlay are mounted", present)
	if not present:
		host.free()
		await process_frame
		return

	# ── The reparent must not cost the label its unique name ─────────────
	# host_label() moves the Label into the plate. remove_child() clears
	# `owner`, and a node with a null owner stops being a scene-unique name —
	# which broke 16 existing checks the first time this was wired.
	_ok("%ScoreLabel survives being reparented into its bezel",
		score_label.get_parent() == score_bezel and score_label.owner != null,
		"parent=%s owner=%s" % [str(score_label.get_parent()), str(score_label.owner)])

	# ── The plate is readable ────────────────────────────────────────────
	_ok("the score plate clears the touch-target floor",
		score_bezel.size.y >= 48.0, "%.0fpx tall" % score_bezel.size.y)
	_ok("the score label is inset clear of the arc track",
		score_label.size.x < score_bezel.size.x,
		"label %.0f vs plate %.0f" % [score_label.size.x, score_bezel.size.x])

	# ── The arc is a real gauge ──────────────────────────────────────────
	# Drive genuine answers and watch the sweep follow accuracy. A decorative
	# arc — one that animates on a fixed schedule — passes an existence check
	# and fails this one.
	var start_fill: float = float(score_bezel.call("fill"))
	_ok("the score arc starts empty", is_equal_approx(start_fill, 0.0),
		"%.3f" % start_fill)

	host.call("record_answer", true)
	await process_frame
	var after_hit: float = float(score_bezel.call("fill"))
	_ok("a correct answer drives the score arc up",
		after_hit > start_fill, "%.3f -> %.3f" % [start_fill, after_hit])
	_ok("the score arc equals the accuracy it reads out",
		is_equal_approx(after_hit, float(host.call("accuracy"))),
		"arc %.3f vs accuracy %.3f" % [after_hit, float(host.call("accuracy"))])

	host.call("record_answer", false)
	await process_frame
	var after_miss: float = float(score_bezel.call("fill"))
	_ok("a wrong answer drives the score arc down",
		after_miss < after_hit, "%.3f -> %.3f" % [after_hit, after_miss])

	# The timer plate reads rounds completed, which is a bounded quantity.
	# Its arc must stay inside 0..1 whatever the mini-game reports.
	var timer_fill: float = float(timer_bezel.call("fill"))
	_ok("the timer arc stays in range",
		timer_fill >= 0.0 and timer_fill <= 1.0, "%.3f" % timer_fill)

	# ── Feedback fires, and fires the right one ──────────────────────────
	# TrialFeedback.Mode: 0 IDLE, 1 SUCCESS, 2 FAILURE.
	host.call("record_answer", true)
	await process_frame
	_ok("a correct answer plays the SUCCESS pulse",
		int(feedback.call("mode")) == 1,
		"mode=%d" % int(feedback.call("mode")))

	host.call("record_answer", false)
	await process_frame
	_ok("a wrong answer plays the FAILURE abrasion",
		int(feedback.call("mode")) == 2,
		"mode=%d" % int(feedback.call("mode")))

	# ── The overlay covers exactly the play field ────────────────────────
	# A pulse centred on a field-local point only lands on the thing the
	# player touched if the overlay and the field share a rect.
	# Written UNCONDITIONALLY. Nesting these behind `if field != null` would
	# make them silently pass whenever the mini-game failed to mount, which is
	# precisely the case they need to catch.
	var field: Control = host.get("_minigame") as Control
	_ok("the mini-game mounted for the HUD audit", field != null)
	_ok("the feedback overlay registers with the play field",
		field != null
		and feedback.global_position.distance_to(field.global_position) < 1.0
		and feedback.size.distance_to(field.size) < 1.0,
		"overlay %s%s vs field %s" % [
			str(feedback.global_position), str(feedback.size),
			str(field.global_position) if field != null else "no field"])

	# ── The pulse lands where the player pressed ─────────────────────────
	# Not at the centre by default: make_target() records the pressed target,
	# and record_answer() must forward it.
	var probe := Vector2(feedback.size.x * 0.25, feedback.size.y * 0.75)
	feedback.call("play", true, probe)
	await process_frame
	var landed: Vector2 = feedback.call("origin")
	_ok("the pulse centres on the point it was given",
		landed.distance_to(probe) < 1.0,
		"asked %s got %s" % [str(probe), str(landed)])
	_ok("the pulse origin is not silently the field centre",
		landed.distance_to(feedback.size * 0.5) > 1.0,
		"origin collapsed to centre %s" % str(feedback.size * 0.5))

	# ── THE ABRASION MUST NOT FLOOD THE FIELD ────────────────────────────
	# The first implementation drew each tear as a full-width rectangle at up
	# to 0.30 alpha. Rendered, it covered the entire play field in solid red
	# and cyan stripes — a full-screen glitch that also hid the stimulus the
	# player was being asked to read.
	#
	# Bound the ink it can lay down: tear length x thickness x count, against
	# the field's area. "Subtle" has to be a number, or the next rewrite drifts
	# straight back to stripes.
	# Read the tokens from the SCRIPT ON DISK, not from the Palette autoload
	# node. Under a --script MainLoop the autoload materialises as a bare
	# scriptless Node, so get_script() returns null and every check hung off it
	# silently skips. The first version of this block did exactly that: an
	# injected full-width abrasion PASSED all three checks because none of them
	# ran. Loading the script directly makes them unconditional.
	var pal_script: GDScript = ResourceLoader.load(
		"res://design/palette.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("the palette script is readable for the abrasion bounds",
		pal_script != null)
	var consts: Dictionary = {}
	if pal_script != null:
		consts = pal_script.get_script_constant_map()

	var bands: int = int(consts.get("FEEDBACK_ABRASION_BANDS", 0))
	var line: float = float(consts.get("FEEDBACK_ABRASION_LINE", 1.0))
	var length: float = float(consts.get("FEEDBACK_ABRASION_LENGTH", 1.0))
	var alpha: float = float(consts.get("FEEDBACK_ABRASION_ALPHA", 1.0))

	# Two strokes per band (warm + cool), each `length` of the width and
	# `line` of the short side thick, over a field of width x height.
	var unit: float = minf(feedback.size.x, feedback.size.y)
	var ink: float = float(bands) * 2.0 * (feedback.size.x * length) \
		* (unit * line)
	var coverage: float = ink / maxf(feedback.size.x * feedback.size.y, 1.0)
	_ok("the abrasion covers a small fraction of the play field",
		bands > 0 and coverage < 0.12,
		"%.1f%% of the field inked" % (coverage * 100.0))
	_ok("the abrasion is translucent",
		bands > 0 and alpha <= 0.35, "alpha %.2f" % alpha)
	# A tear is a streak, not a rule across the screen.
	_ok("an abrasion tear is shorter than the field is wide",
		bands > 0 and length < 0.5, "length %.2f of width" % length)

	# ── The mini-game records where it was touched ───────────────────────
	var tracks: bool = field != null and field.has_method("answer_point")
	_ok("the mini-game exposes an answer point", tracks)
	_ok("an untouched field reports no answer point",
		tracks and not bool(field.call("has_answer_point")))
	_ok("an untouched field falls back to its centre",
		tracks and (field.call("answer_point") as Vector2)
			.distance_to(field.call("field_centre") as Vector2) < 1.0)

	host.free()
	await process_frame


func _shader_paths(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".gdshader"):
			out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return out


# ═════════════════════════════════════════════════════════════════════════
# THINGS THAT WERE INVISIBLE OR OFF-SCREEN ON A REAL DEVICE
# ═════════════════════════════════════════════════════════════════════════
## Three defects shipped past 1,623 green checks and were caught by a human
## looking at a screen. Every one of them is a QUANTITY the suite could have
## measured and did not.
func _audit_visible_on_device() -> void:
	print("── the things a screenshot caught ──")

	var pal_script: GDScript = ResourceLoader.load(
		"res://design/palette.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("the palette is readable", pal_script != null)
	var consts: Dictionary = {}
	if pal_script != null:
		consts = pal_script.get_script_constant_map()

	# ── 1. A SURFACE MUST BE DISTINGUISHABLE FROM THE BACKDROP ───────────
	# COLOR_BEZEL_PLATE shipped at a 1.02:1 contrast ratio against
	# COLOR_BACKGROUND. The plates drew correctly and were invisible; the HUD
	# looked exactly like the bare labels it replaced. "It renders" is not the
	# same claim as "you can see it", and only the second one matters.
	var bg: Color = consts.get("COLOR_BACKGROUND", Color.BLACK)
	var plate: Color = consts.get("COLOR_BEZEL_PLATE", Color.BLACK)
	var ratio: float = _contrast_ratio(plate, bg)
	_ok("the HUD plate is distinguishable from the background",
		ratio >= 1.15, "%.2f:1 — invisible at 1.0" % ratio)

	# Its rim is what actually reads as a carved edge, so hold that too.
	var metal: Color = consts.get("COLOR_BEZEL_METAL", Color.BLACK)
	var rim_ratio: float = _contrast_ratio(metal, plate)
	_ok("the bezel rim reads against its own plate",
		rim_ratio >= 1.4, "%.2f:1" % rim_ratio)

	# ── 2. THE HERO HOUSING MUST FIT THE SCREEN ──────────────────────────
	# On the intro the surround was scaled to 1622px on a 1059px screen, so
	# only its empty middle fell inside the viewport — indistinguishable from
	# no housing at all. Checked on every host that mounts an IrisView,
	# because the fault came from a NON-SQUARE host and the hub is square.
	for path: String in ["res://screens/hub_portal.tscn",
			"res://screens/daily_hub.tscn"]:
		var screen: Control = await _mount(path, Vector2i(1059, 1884))
		var view: Node = screen.find_child("IrisView", true, false)
		_ok("%s mounts an IrisView" % path.get_file(), view != null)
		if view == null:
			screen.free()
			await process_frame
			continue
		var housing: Control = view.get("_housing") as Control
		_ok("%s builds the hero housing" % path.get_file(), housing != null)
		# Unconditional: nesting these behind `if housing != null` would make
		# them silently pass on the one failure they exist to catch.
		var vp := Vector2(1059.0, 1884.0)
		var span: float = housing.size.x if housing != null else -1.0
		_ok("%s: the housing fits the viewport" % path.get_file(),
			housing != null and span <= vp.x + 1.0
			and housing.size.y <= vp.y + 1.0,
			"housing %.0f on a %.0f-wide screen" % [span, vp.x])
			# ── AND ITS METAL MUST NOT BE BURIED BEHIND THE EYE ──────────
		# The check this replaces asserted the housing was "big enough to
		# frame the eye" at 0.6x the view. That passed the entire time the
		# frame was INVISIBLE: at HOUSING_SPAN 1.63 the carved metal sat at
		# 225px from centre while the CoreEye is opaque out to 260px, so the
		# whole ring was hidden behind the eyeball and the player saw bare
		# black. Reported twice.
		#
		# Measure the thing that actually matters: where the metal lands
		# versus where the eye ends. HOUSING_APERTURE is the normalised
		# radius in the texture at which the carved ring begins, measured by
		# scanning the art for its first sustained lit pixel.
		var iv_script: GDScript = ResourceLoader.load(
			"res://nodes/iris_view.gd", "GDScript",
			ResourceLoader.CACHE_MODE_IGNORE) as GDScript
		var aperture: float = 0.0
		if iv_script != null:
			aperture = float(iv_script.get_script_constant_map()
				.get("HOUSING_APERTURE", 0.0))
		var eye_edge: float = minf(view.size.x, view.size.y) * 0.5
		var metal_at: float = span * 0.5 * aperture
		_ok("%s: the housing metal clears the eye" % path.get_file(),
			housing != null and aperture > 0.0 and metal_at >= eye_edge,
			"metal starts %.0fpx, eye ends %.0fpx — the frame is behind the eyeball"
				% [metal_at, eye_edge])

		# ── AND IT MUST NOT BURY THE SHARD LABELS ────────────────────
		# The frame is deliberately larger than the eye, and %ShardMarkers is
		# authored BEFORE %IrisBand in the scene — so the housing painted over
		# every compass label. On a GPU capture all five destinations were
		# gone: "Trials" measured peak luminance 9 against a background of 9.
		#
		# Draw order is the fix, and draw order is what this asserts: a label
		# that paints first is invisible no matter where it sits.
		if path.get_file() == "hub_portal.tscn":
			var shard_layer: Node = screen.get_node_or_null("%ShardMarkers")
			var iris_band: Node = screen.get_node_or_null("%IrisBand")
			_ok("the hub has both the shard markers and the iris band",
				shard_layer != null and iris_band != null)
			_ok("the shard labels draw AFTER the hero housing",
				shard_layer != null and iris_band != null
				and shard_layer.get_index() > iris_band.get_index(),
				"markers at %d, band at %d — the frame covers them" % [
					shard_layer.get_index() if shard_layer != null else -1,
					iris_band.get_index() if iris_band != null else -1])

		screen.free()
		await process_frame
