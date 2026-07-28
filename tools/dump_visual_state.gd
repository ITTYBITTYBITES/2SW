extends SceneTree
## Dump the LIVE state of the trial HUD and the splash sequence to JSON.
##
## WHY THIS EXISTS
## The sandbox has no display server, so Godot cannot open a window and no
## screenshot can be taken. Every visual claim in this project therefore has to
## be backed by geometry measured from the RUNNING tree and then re-drawn by a
## CPU port of the same maths — never by a hand-drawn mock-up.
##
## That distinction has already mattered twice. A previous "splash snapshot"
## was a designed picture of a screen that did not exist, and a previous
## "atmosphere snapshot" drew the motes flat and opaque when the real ones
## pulse with a halo. Both overstated the build.
##
## This dumps only values READ BACK from live nodes after layout settles:
## rects, the bezels' actual arc fills, the feedback overlay's actual mode and
## origin, the bloom's actual reach. tools/render_visual_state.py draws from
## this file and nothing else.

const OUT_PATH: String = "user://visual_state.json"
const VIEWPORT: Vector2i = Vector2i(1080, 1920)


func _init() -> void:
	_run.call_deferred()


## Alpha as actually seen on screen: this node's modulate multiplied by every
## Control ancestor's, which is how CanvasItem propagates it.
func _effective_alpha(c: Control) -> float:
	var a: float = c.get_modulate().a
	var parent: Node = c.get_parent()
	while parent is CanvasItem:
		a *= (parent as CanvasItem).get_modulate().a
		parent = parent.get_parent()
	return a


func _collect(node: Node, out: Array, origin: Vector2) -> void:
	if node is Control:
		var c: Control = node as Control
		var text: String = ""
		if c is Label:
			text = (c as Label).text
		elif c is Button:
			text = (c as Button).text
		out.append({
			"name": String(c.name),
			"cls": c.get_class(),
			"script": (c.get_script() as Script).resource_path if c.get_script() != null else "",
			"pos": [c.global_position.x - origin.x, c.global_position.y - origin.y],
			"size": [c.size.x, c.size.y],
			"visible": c.is_visible_in_tree(),
			# EFFECTIVE alpha, with every ancestor's modulate folded in. The
			# raw per-node value is not enough: TitleName sits at 1.0 while
			# its TitleLayer parent is at 0.0, so a renderer reading only the
			# node drew the title during the sponsor act, when it is invisible.
			"modulate_a": _effective_alpha(c),
			"text": text,
		})
	for child: Node in node.get_children():
		_collect(child, out, origin)


## Where a baked plate actually lands, in screen space, plus its source art.
func _plate_info(plate: Control, origin: Control) -> Dictionary:
	if plate == null:
		return {}
	var rect: Rect2 = plate.call("fitted_rect")
	var tex: Texture2D = plate.call("texture") as Texture2D
	return {
		"path": str(plate.get("texture_path")),
		"pos": [plate.global_position.x - origin.global_position.x + rect.position.x,
			plate.global_position.y - origin.global_position.y + rect.position.y],
		"size": [rect.size.x, rect.size.y],
		"tex_size": [tex.get_size().x, tex.get_size().y] if tex != null else [],
	}


func _run() -> void:
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("wipe")
	root.content_scale_size = VIEWPORT
	root.size = VIEWPORT
	await process_frame

	var payload: Dictionary = {
		"viewport": [VIEWPORT.x, VIEWPORT.y],
		"trial": await _dump_trial(),
		"splash": await _dump_splash(),
	}

	var f: FileAccess = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	print("wrote ", ProjectSettings.globalize_path(OUT_PATH))
	quit(0)


# ═════════════════════════════════════════════════════════════════════════
# TRIAL HUD
# ═════════════════════════════════════════════════════════════════════════
## Mount a real trial, play REAL answers through record_answer(), and read the
## HUD's resulting state. The arc fills below are whatever the controller
## actually computed — not values chosen to look good in a picture.
func _dump_trial() -> Dictionary:
	var host: Control = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	var state_script: GDScript = ResourceLoader.load(
		"res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	host.call("configure", {"trial_id": "false_witness",
		"iris_state": state_script.new()})
	root.add_child(host)
	for _i: int in range(4):
		await process_frame

	# Three right, one wrong: a plausible mid-run state that leaves the score
	# arc at 75% and the last feedback event a SUCCESS pulse.
	host.call("record_answer", true)
	host.call("record_answer", true)
	host.call("record_answer", false)
	host.call("record_answer", true)
	await process_frame

	var nodes: Array = []
	_collect(host, nodes, host.global_position)

	var score_bezel: Control = host.get_node_or_null("%ScoreBezel") as Control
	var timer_bezel: Control = host.get_node_or_null("%TimerBezel") as Control
	var feedback: Control = host.get_node_or_null("%Feedback") as Control
	var field: Control = host.get("_minigame") as Control

	# Put the pulse somewhere off-centre so the snapshot shows it tracking the
	# pressed target rather than defaulting to the middle.
	var probe := Vector2(feedback.size.x * 0.34, feedback.size.y * 0.40)
	feedback.call("play", true, probe)
	for _i: int in range(6):
		await process_frame

	var out: Dictionary = {
		"nodes": nodes,
		"score_fill": float(score_bezel.call("fill")),
		"score_shown": float(score_bezel.call("shown_fill")),
		"timer_fill": float(timer_bezel.call("fill")),
		"accuracy": float(host.call("accuracy")),
		"feedback_mode": int(feedback.call("mode")),
		"feedback_phase": float(feedback.call("phase")),
		"feedback_origin": [
			(feedback.call("origin") as Vector2).x,
			(feedback.call("origin") as Vector2).y],
		"field_rect": [field.global_position.x, field.global_position.y,
			field.size.x, field.size.y] if field != null else [],
	}

	# A second capture showing the FAILURE abrasion, so the deliverable can
	# show both responses side by side from real state.
	feedback.call("play", false, Vector2(feedback.size.x * 0.62, feedback.size.y * 0.55))
	for _i: int in range(4):
		await process_frame
	out["fail_mode"] = int(feedback.call("mode"))
	out["fail_phase"] = float(feedback.call("phase"))
	out["fail_origin"] = [
		(feedback.call("origin") as Vector2).x,
		(feedback.call("origin") as Vector2).y]

	host.free()
	await process_frame
	return out


# ═════════════════════════════════════════════════════════════════════════
# SPLASH
# ═════════════════════════════════════════════════════════════════════════
## Mount the real splash and let the real warm-up run, capturing the bloom at
## two genuine points in the sequence.
func _dump_splash() -> Dictionary:
	var live: Control = (load("res://screens/splash/splash.tscn") as PackedScene).instantiate()
	live.call("configure", {})
	root.add_child(live)
	for _i: int in range(4):
		await process_frame

	var bloom: Control = live.get_node_or_null("%Bloom") as Control

	# Let the ident's fade-in finish before capturing. Sampling four frames in
	# caught it at 9% opacity, which made the snapshot look like a bug rather
	# than showing the act at its hold.
	for _i: int in range(90):
		await process_frame

	# ACT 1 — the sponsor ident, at its own base bloom level.
	var sp: Control = live.get_node_or_null("%SponsorPlate") as Control
	var tp: Control = live.get_node_or_null("%TitlePlate") as Control

	var act1: Dictionary = {
		"nodes": [],
		"plate": _plate_info(sp, live),
		"bloom_progress": float(bloom.call("progress")),
		"bloom_reach": float(bloom.call("reach")),
		"bloom_focus": [(bloom.call("focus") as Vector2).x,
			(bloom.call("focus") as Vector2).y],
	}
	var n1: Array = []
	_collect(live, n1, live.global_position)
	act1["nodes"] = n1

	# ACT 2 — skip to the title and let the REAL warm-up run to completion.
	live.call("skip")
	for _i: int in range(180):
		await process_frame
		if float(live.call("progress")) >= 1.0:
			break
	# Let the bloom's easing converge on the finished value.
	for _i: int in range(90):
		await process_frame

	var n2: Array = []
	_collect(live, n2, live.global_position)
	var act2: Dictionary = {
		"nodes": n2,
		"plate": _plate_info(tp, live),
		"bloom_progress": float(bloom.call("progress")),
		"bloom_reach": float(bloom.call("reach")),
		"bloom_focus": [(bloom.call("focus") as Vector2).x,
			(bloom.call("focus") as Vector2).y],
		"peak_alpha": float(bloom.call("peak_alpha")),
		"loader_progress": float(live.call("progress")),
	}

	# Re-read the atmosphere AFTER the sequence has run. Reading it straight
	# after mount reported null: _setup() installs it, and _setup() had not
	# been reached yet at that point. The first version of this dump recorded
	# has_atmosphere=false against a build where it was demonstrably present —
	# a fault in the instrument, not the app, and worth noting because a
	# snapshot tool that lies is exactly what this file exists to avoid.
	var atmosphere: Node = live.get_node_or_null("Atmosphere")

	var result: Dictionary = {
		"has_atmosphere": atmosphere != null,
		"atmosphere_index": atmosphere.get_index() if atmosphere != null else -1,
		"act1": act1,
		"act2": act2,
	}
	live.free()
	await process_frame
	return result
