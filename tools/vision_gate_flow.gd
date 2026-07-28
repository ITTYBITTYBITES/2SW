extends SceneTree
## Phase 1 verification: the nav gate and the vision glyph data model.
##
## Loads the classes AFTER the first deferred frame via ResourceLoader, because
## a --script MainLoop compiles before autoloads attach and any class_name
## script that references Log/Palette fails to resolve at that point.

## Luminance below which a rendered pixel counts as pupil rather than iris.
##
## Measured by radially scanning a GPU capture out from the eye centre: the
## pupil interior sits at ~0.04 and the iris jumps to 0.19 within 5px of the
## boundary, so anything in that gap separates them cleanly.
const PUPIL_DARK_MAX: float = 0.10

## Radius of the pupil search, as a fraction of the eye's side. See
## _measure_pupil_centre() for the measurements behind it.
const PUPIL_SEARCH_FRAC: float = 0.36

var _fails: Array[String] = []
var _n: int = 0


func _find(node: Node, want: String) -> Node:
	if node.name == want:
		return node
	for child: Node in node.get_children():
		var found: Node = _find(child, want)
		if found != null:
			return found
	return null


func _visible_markers(screen: Control) -> int:
	var markers: Node = _find(screen, "ShardMarkers")
	var count: int = 0
	for child: Node in markers.get_children():
		if child is Control and (child as Control).is_visible_in_tree():
			count += 1
	return count


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var save: Node = root.get_node_or_null("Save")
	var glyph_script: GDScript = ResourceLoader.load(
		"res://data/vision_glyph.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	var state_script: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	print("\n═══ PHASE 1: NAV GATE + VISION MODEL ═══\n")

	print("── the nav gate ──")
	save.call("wipe")
	await process_frame
	_ok("a fresh save is gated", not bool(save.call("has_returned_from_trial")))
	_ok("the gate is not first_run_done",
		not bool(save.call("get_v", "meta", "first_run_done", false)))

	save.call("mark_returned_from_trial")
	_ok("marking opens the gate", bool(save.call("has_returned_from_trial")))
	save.call("mark_returned_from_trial")
	_ok("marking twice is stable", bool(save.call("has_returned_from_trial")))

	# PERSISTENCE ACROSS A RESTART.
	#
	# Deliberately NO flush() here. mark_returned_from_trial() must write to
	# disk ITSELF — the unlock is the reward for finishing a first trial, and
	# losing it to a crash in the seconds afterwards would re-gate a player
	# who had earned the hub.
	#
	# The first version of this check called flush() before reloading, which
	# wrote the flag regardless and passed even with the flush removed from
	# the function under test. It verified the disk, not the contract.
	save.call("_load")
	await process_frame
	_ok("mark_returned_from_trial() persists WITHOUT an external flush",
		bool(save.call("has_returned_from_trial")))

	save.call("wipe")
	await process_frame
	_ok("a wipe re-gates", not bool(save.call("has_returned_from_trial")))

	print("── the glyph roster ──")
	var routes: Array = glyph_script.covered_routes()
	# DERIVED, not a literal. The roster covers every compass shard PLUS any
	# sidebar destination — Settings is reached from the rail rather than the
	# eye, so it has a glyph but no shard. Hardcoding "five" made this fail
	# the moment the sidebar landed, which is a stale test rather than a
	# regression.
	_ok("the roster is non-empty", routes.size() > 0, str(routes))

	# EVERY navigable shard must have a glyph. This is the check that fails
	# when someone adds a compass destination and forgets its symbol — the
	# preview would silently show nothing, which is invisible in a headless
	# run and only obvious on a device.
	var router: Node = root.get_node_or_null("Router")
	var hub_src: String = FileAccess.get_file_as_string(
		"res://nodes/hub_portal_controller.gd")
	# Parse SHARD_ROUTES only. The first version scraped every dictionary with
	# a CompassShard key and picked up SHARD_LABELS too, so it asserted that
	# "Trend Hub" was a Router route — a test failing on its own parsing
	# rather than on the code under test.
	var shard_routes: Array[String] = []
	var in_table: bool = false
	for line: String in hub_src.split("\n"):
		if line.begins_with("const SHARD_ROUTES"):
			in_table = true
			continue
		if in_table:
			if line.begins_with("}"):
				break
			if line.contains("IrisState.CompassShard.") and line.contains(": \""):
				var start: int = line.find(": \"") + 3
				var stop: int = line.find("\"", start)
				if stop > start:
					shard_routes.append(line.substr(start, stop - start))
	_ok("found the shard route table", shard_routes.size() >= 5,
		str(shard_routes))
	# EVERY shard must have a glyph. The reverse is deliberately not asserted:
	# a glyph without a shard is a sidebar destination, which is legitimate.
	for route: String in shard_routes:
		_ok("shard route '%s' has a glyph" % route,
			glyph_script.for_route(route) != null)
		_ok("shard route '%s' is a real Router route" % route,
			router.ROUTES.has(route))

	for route: String in routes:
		var glyph: Variant = glyph_script.for_route(route)
		_ok("'%s' declares shapes" % route, glyph.shapes.size() > 0)
		_ok("'%s' has a label" % route, str(glyph.label) != "")
		# Every shape must be inside the unit disc, or it draws outside the
		# pupil mask and gets clipped into a crescent.
		var within: bool = true
		for shape: Dictionary in glyph.shapes:
			var reach: float = 0.0
			match int(shape.get("kind", -1)):
				0, 1, 4, 5:
					reach = float(shape.get("radius", 0.0))
				2:
					var centre: Vector2 = shape.get("centre", Vector2.ZERO)
					var half: Vector2 = shape.get("half", Vector2.ZERO)
					reach = (centre.abs() + half.abs()).length()
				3:
					reach = float(shape.get("outer", 0.0))
			if reach > 1.0:
				within = false
		_ok("'%s' fits inside the pupil disc" % route, within)

	_ok("an unknown route yields null", glyph_script.for_route("nope") == null)

	print("── the v1 animation contract ──")
	# DISC_FRACTION IS NO LONGER v1's 0.60. See data/vision_glyph.gd: 0.60 was
	# calibrated against v1's much larger pupil and rendered a disc four times
	# this eye's pupil, so the glyph sprawled across the whole iris. The
	# meaningful assertion is the geometric one below ("the disc fits inside
	# the pupil"), which is measured against the live shader rather than
	# compared to a literal.
	_ok("the disc is smaller than the iris it sits in",
		glyph_script.DISC_FRACTION < 0.5,
		"%.2f" % glyph_script.DISC_FRACTION)
	_ok("fade-in is 0.22s", is_equal_approx(glyph_script.FADE_IN_SEC, 0.22))
	_ok("scale-in is 0.28s", is_equal_approx(glyph_script.SCALE_IN_SEC, 0.28))
	_ok("scale starts at 0.85", is_equal_approx(glyph_script.SCALE_FROM, 0.85))
	_ok("pupil pulse is 0.08", is_equal_approx(glyph_script.PUPIL_PULSE, 0.08))

	print("── the state model ──")
	var state: Object = state_script.new()
	_ok("no vision by default", not bool(state.call("is_vision_visible")))
	_ok("nav is locked by default", not bool(state.get("nav_unlocked")))

	state.call("set_vision", "trial")
	state.call("set_vision_reveal", 1.0)
	_ok("a valid route becomes visible", bool(state.call("is_vision_visible")))
	_ok("the route is recorded", str(state.get("vision_route")) == "trial")

	state.call("set_vision_reveal", 0.0)
	_ok("reveal 0 is not visible", not bool(state.call("is_vision_visible")))
	state.call("set_vision_reveal", 5.0)
	_ok("reveal clamps to 1", is_equal_approx(float(state.get("vision_reveal")), 1.0))

	state.call("set_vision", "")
	_ok("an empty route clears", str(state.get("vision_route")) == "")

	state.call("set_vision", "trial")
	state.call("clear_interaction")
	_ok("clear_interaction drops the vision",
		str(state.get("vision_route")) == "")

	state.call("set_nav_unlocked", true)
	_ok("nav can unlock", bool(state.get("nav_unlocked")))

	# TRANSIENT. Interaction state must never reach the save file: a preview
	# restored on next launch would show a destination the player never chose.
	state.call("set_vision", "daily")
	state.call("set_vision_reveal", 1.0)
	var dict: Dictionary = state.call("to_dict")
	_ok("vision_route is NOT serialised", not dict.has("vision_route"))
	_ok("vision_reveal is NOT serialised", not dict.has("vision_reveal"))
	_ok("nav_unlocked is NOT serialised", not dict.has("nav_unlocked"))

	await _phase2_live()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d PHASE-1+2 CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


# ═════════════════════════════════════════════════════════════════════════
# PHASE 2 — the gate and the vision, in a live tree
# ═════════════════════════════════════════════════════════════════════════
## Behaviour, not wiring. Each check mounts the real hub and reads what a
## player would see: how many shards are on screen, what the hint says, and
## whether a drag produces a preview.
func _phase2_live() -> void:
	print("── phase 2: the gate, live ──")
	var save: Node = root.get_node_or_null("Save")
	save.call("wipe")
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame

	# Router swaps screens into a host container. --script never runs the App
	# shell that normally binds one, so provide it here; otherwise settling a
	# trial trips Router's "no host bound" invariant, which is the guard
	# working correctly rather than a product bug.
	var router: Node = root.get_node_or_null("Router")
	if router != null:
		var host := Control.new()
		host.name = "TestScreenHost"
		root.add_child(host)
		router.call("bind_host", host)

	var hub: PackedScene = load("res://screens/hub_portal.tscn") as PackedScene

	# ── GATED ──
	var gated: Control = hub.instantiate()
	gated.call("configure", {})
	root.add_child(gated)
	for _i: int in range(14):
		await process_frame

	var hint: Label = _find(gated, "HintLabel") as Label
	var eye: Node = _find(gated, "IrisView")
	_ok("gated: no shards are shown", _visible_markers(gated) == 0,
		"%d visible" % _visible_markers(gated))
	_ok("gated: the hint says to tap", hint.text.to_lower().contains("tap"),
		hint.text)
	_ok("gated: compass hit-testing is off",
		not bool(eye.call("nav_enabled")))

	# A drag while gated must resolve nothing and preview nothing. This is
	# the check that fails if the gate only hides labels: an invisible shard
	# that still commits is worse than a visible one.
	eye.call("_update_compass", Vector2(540.0, 100.0))
	await process_frame
	_ok("gated: a drag resolves no shard",
		int(eye.call("hovered_shard")) == 0)
	_ok("gated: a drag shows no vision",
		not bool(eye.call("vision_visible")))
	gated.free()
	await process_frame

	# ── A FORFEIT MUST NOT OPEN THE GATE ──
	#
	# v1 marked the flag unconditionally in TrialContainer, so backing out of
	# a first trial still unlocked the hub — the player skipped the one thing
	# the gate exists to make them do. Driven through the real trial
	# controller rather than by calling Save directly, because the contract
	# under test is "_settle(forfeited) does not open the gate", not "the
	# setter works".
	var trial: Control = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	trial.call("configure", {"trial_id": "false_witness"})
	root.add_child(trial)
	for _i: int in range(14):
		await process_frame
	trial.call("_settle", 0.5, true)
	for _i: int in range(6):
		await process_frame
	_ok("a FORFEITED trial leaves the gate closed",
		not bool(save.call("has_returned_from_trial")))
	trial.free()
	await process_frame

	# ── A COMPLETED TRIAL OPENS IT ──
	var done: Control = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	done.call("configure", {"trial_id": "false_witness"})
	root.add_child(done)
	for _i: int in range(14):
		await process_frame
	done.call("_settle", 0.5, false)
	for _i: int in range(6):
		await process_frame
	_ok("a COMPLETED trial opens the gate",
		bool(save.call("has_returned_from_trial")))
	done.free()
	await process_frame

	# ── UNLOCKED ──
	save.call("mark_returned_from_trial")
	var open_hub: Control = hub.instantiate()
	open_hub.call("configure", {})
	root.add_child(open_hub)
	for _i: int in range(14):
		await process_frame

	var hint2: Label = _find(open_hub, "HintLabel") as Label
	var eye2: Node = _find(open_hub, "IrisView")
	# THE SHARD LABELS ARE DRAG-ONLY NOW.
	#
	# Every destination has a tappable rail node carrying the same caption, so
	# permanently visible shard labels printed each word twice — and they
	# landed on the carved frame, where they read as decoration. They appear
	# on hover, to guide a drag in progress.
	#
	# What the gate must still prove is that unlocking ENABLES the compass,
	# which the nav_enabled check below asserts directly. Absence at rest is
	# the correct state, so that is what is checked here.
	_ok("unlocked: shard labels stay hidden until a drag",
		_visible_markers(open_hub) == 0,
		"%d visible with no drag" % _visible_markers(open_hub))
	_ok("unlocked: the hint says to drag",
		hint2.text.to_lower().contains("drag"), hint2.text)
	_ok("unlocked: compass hit-testing is on",
		bool(eye2.call("nav_enabled")))

	print("── phase 2: the pupil vision, live ──")
	# _pressing mirrors a finger being DOWN. _process() only runs the
	# autonomous idle gaze while it is false, so without this the saccade
	# jitter overwrites _gaze_target every frame and the eye never actually
	# looks at the shard being dragged toward — the gaze measured 0.007 where
	# a real drag holds ~1.0.
	eye2.set("_pressing", true)
	eye2.call("_update_compass", Vector2(540.0, 100.0))
	for _i: int in range(20):
		await process_frame

	_ok("a drag resolves a shard", int(eye2.call("hovered_shard")) != 0)
	_ok("a vision appears", bool(eye2.call("vision_visible")))
	_ok("the vision names a route", str(eye2.call("vision_route")) != "")
	_ok("the hint names the destination",
		hint2.text.to_lower().contains("release"), hint2.text)

	# Unconditional. Guarding these behind `if vision != null` would let a
	# missing node report as three passes — the exact pattern
	# check_architecture.py forbids.
	var vision: Node = _find(open_hub, "PupilVision")
	_ok("the vision node exists", vision != null)
	var rect: Control = vision as Control
	var core: Control = _find(open_hub, "CoreEye") as Control
	_ok("the vision carries a glyph",
		vision != null and bool(vision.call("has_glyph")))
	_ok("the vision is revealed",
		vision != null and float(vision.call("reveal")) > 0.001)
	# THE DISC MUST FIT INSIDE THE PUPIL IT IS DRAWN IN.
	#
	# This compared the disc to the EYE and to a hardcoded 0.60, which is the
	# check that passed for the entire life of the reported defect: the glyph
	# was drawing at 300px inside a 175px pupil, sprawling across the iris and
	# over the collarette, and "0.600 of the eye" was perfectly true the whole
	# time. Comparing a constant against a literal proves only that nobody
	# edited the literal.
	#
	# The pupil radius is whatever the SHADER is currently rendering:
	#   pupil_r = lerp(pupil_min, pupil_max, pupil_dilation) * side
	# so the check follows a dilation or geometry change automatically instead
	# of going stale.
	var ratio: float = 0.0
	if rect != null and core != null:
		ratio = rect.size.x / maxf(core.size.x, 1.0)
	var pupil_d: float = float(eye2.call("pupil_diameter"))
	_ok("the pupil resolved to a real size", pupil_d > 1.0, "%.1fpx" % pupil_d)
	_ok("the vision disc fits inside the pupil",
		rect != null and rect.size.x <= pupil_d + 1.0,
		"disc %.0fpx vs pupil %.0fpx (%.2f of the eye)" % [
			rect.size.x if rect != null else 0.0, pupil_d, ratio])

	# ...and is not so small it reads as a speck. A disc that "fits" at 4px
	# would satisfy the bound above while being invisible.
	_ok("the vision disc actually fills the pupil",
		rect != null and rect.size.x >= pupil_d * 0.55,
		"disc %.0fpx vs pupil %.0fpx" % [
			rect.size.x if rect != null else 0.0, pupil_d])

	# THE DISC MUST RIDE WITH THE PUPIL.
	#
	# The shader translates the iris by `gaze_vector * 0.22` every frame, and
	# the vision is a Control that knows nothing about that. Positioned only
	# on resize, it stayed at the view centre while the pupil slid out from
	# under it — measured on a GPU capture as a 41px separation on a 500px
	# eye, during the drag that is the ONLY time the glyph is ever visible.
	#
	# The eye is looking hard north here (the drag above), so the offset is
	# real and this is not a no-op comparison at gaze zero.
	var gaze: Vector2 = Vector2.ZERO
	var gaze_v: Variant = eye2.get("_gaze_current")
	if gaze_v != null:
		gaze = gaze_v
	_ok("the drag actually moved the gaze", gaze.length() > 0.05,
		"gaze %s" % str(gaze))

	# THE PUPIL IS FOUND BY LOOKING AT THE PIXELS, NOT BY RECOMPUTING.
	#
	# The first version of this check re-derived the pupil position with the
	# same expression the implementation uses. That is a tautology: when the
	# implementation had the SIGN WRONG — sending the disc south while the
	# pupil went north, a ~110px error plainly visible in a GPU capture — the
	# check recomputed the identical wrong value and passed.
	#
	# The rendered eye is the only authority. The pupil is the large dark disc
	# inside a bright iris, so its centroid locates it without knowing
	# anything about gaze maths.
	var disc_centre: Vector2 = Vector2.ZERO
	if rect != null:
		disc_centre = rect.global_position + rect.size * 0.5
	# A --headless run has no rendering device: the viewport texture is never
	# produced, so there are no pixels to measure. That is a limitation of the
	# environment, not a passing test, so it is REPORTED rather than silently
	# skipped — and the suite runs this flow under Xvfb precisely so the check
	# has a real GPU. See tools/godot_validate.sh.
	if not _has_gpu():
		print("  SKIP  the vision disc is centred on the RENDERED pupil"
			+ "  [no rendering device; run under xvfb-run]")
	else:
		var pupil_centre: Vector2 = await _measure_pupil_centre(core)
		_ok("the pupil was locatable on screen", pupil_centre != Vector2.INF)
		if pupil_centre != Vector2.INF:
			_ok("the vision disc is centred on the RENDERED pupil",
				disc_centre.distance_to(pupil_centre) <= 12.0,
				"disc %s vs pupil %s (%.1fpx apart)" % [
					str(disc_centre.round()), str(pupil_centre.round()),
					disc_centre.distance_to(pupil_centre)])

	# Releasing must clear the preview, or a stale glyph sits in the pupil
	# after the finger has gone.
	# The fade-out runs over DURATION_FAST and is frame-rate dependent in a
	# headless run. Measured, it needs ~36 frames to reach zero; the first
	# version of this check waited 20 and failed on a working fade. Waiting
	# on the ACTUAL state rather than a frame count removes the guesswork.
	eye2.call("_set_hover", 0)
	var settled: bool = false
	for _i: int in range(180):
		await process_frame
		if not bool(eye2.call("vision_visible")):
			settled = true
			break
	_ok("clearing the hover hides the vision", settled)
	open_hub.free()
	await process_frame


## Is there a real rendering device to read pixels from?
##
## Under --headless the video driver is "Dummy" and RenderingServer never
## emits frame_post_draw, so awaiting it hangs the run forever rather than
## failing — which is exactly what happened: the suite blocked for 28 minutes
## on this flow before being killed.
func _has_gpu() -> bool:
	return not str(DisplayServer.get_name()).begins_with("headless") \
		and RenderingServer.get_video_adapter_name() != ""


## Centroid of the rendered pupil, in global screen coordinates.
##
## The pupil is the large DARK disc at the middle of a bright iris, so a
## luminance threshold over the eye's rect finds it without reproducing any of
## the gaze arithmetic under test. Returns Vector2.INF when nothing dark
## enough is found — which is itself asserted, so a headless run that renders
## no pixels reports a failure rather than a silent pass.
##
## The vision glyph is drawn INSIDE the pupil in a bright tint, so it is
## excluded by the same threshold rather than dragging the centroid toward
## itself.
func _measure_pupil_centre(core: Control) -> Vector2:
	if core == null:
		return Vector2.INF
	await RenderingServer.frame_post_draw
	var img: Image = core.get_viewport().get_texture().get_image()
	if img == null:
		return Vector2.INF
	# SEARCH A DISC, NOT THE WHOLE RECT.
	#
	# The eyeball is inscribed in a square control, so the rect's corners are
	# dark BACKGROUND outside the sclera, plus the shadowed canthus at each
	# side. Scanning the full rect pulled the centroid toward the geometric
	# middle and reported the pupil 58px from where it renders — enough to
	# mask the very offset under test. Measured across search radii:
	#
	#     120px -> (533, 830)     150px -> (534, 808)
	#     180px -> (534, 807)     250px -> (540, 906)   corners bleed in
	#
	# 0.36 of the side (180px on a 500px eye) is stable and comfortably
	# larger than the pupil at full dilation.
	var centre: Vector2 = core.get_global_rect().position + core.size * 0.5
	var limit: float = minf(core.size.x, core.size.y) * PUPIL_SEARCH_FRAC
	var sum: Vector2 = Vector2.ZERO
	var count: int = 0
	var y: int = int(centre.y - limit)
	while y < int(centre.y + limit):
		var x: int = int(centre.x - limit)
		while x < int(centre.x + limit):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				if Vector2(x, y).distance_to(centre) <= limit \
						and img.get_pixel(x, y).get_luminance() < PUPIL_DARK_MAX:
					sum += Vector2(x, y)
					count += 1
			x += 2
		y += 2
	if count < 200:
		return Vector2.INF
	return sum / float(count)



