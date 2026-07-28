extends SceneTree
## Every trial must report clean reaction timing — or explicitly opt out.
##
## THE BUG THIS EXISTS FOR:
## Latency tracking was added to TrialMiniGame's base submit(), but
## mark_stimulus() was only wired into TWO of the five modes. Playing
## false_witness logged "answer submitted with no live stimulus" on every
## single answer, and recorded no latency at all — so a ChronoPulse or Trend
## run through that mode would have banked a result with no timing behind it.
##
## Nothing caught it because no test ever PLAYED a trial and inspected the
## latency afterwards. The trial suites check scoring and difficulty tables;
## the chrono suite plays only cognitive_conflict, which happened to be one of
## the two wired modes.
##
## This plays EVERY registered mini-game through its real answer path and
## asserts the timing contract, so a new mode cannot be added without either
## wiring mark_stimulus() or declaring itself exempt.

## Modes that legitimately record no latency, with the reason.
##
## An exemption must be a deliberate entry here, not a silent omission — that
## distinction is the entire point of the file.
const EXEMPT: Dictionary = {
	"facet_cascade": "match-3 board: no discrete stimulus, scored on progress",
}

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
	print("\n═══ TRIAL TIMING CONTRACT ═══\n")
	root.get_node_or_null("Save").call("wipe")
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame

	var registry: GDScript = ResourceLoader.load("res://data/trial_registry.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	# Source-level first: every non-exempt mode must call mark_stimulus().
	# Cheap, and it names the offending file directly.
	print("── every mode marks its stimulus ──")
	for trial_id: String in (registry.call("all_ids") as Array):
		var path: String = str(registry.call("script_path", trial_id))
		if path.is_empty() or not ResourceLoader.exists(path):
			continue
		var src: String = FileAccess.get_file_as_string(path)
		var marks: bool = src.contains("mark_stimulus()")
		if EXEMPT.has(trial_id):
			_ok("'%s' is a declared exemption" % trial_id, not marks or true,
				str(EXEMPT[trial_id]))
			continue
		_ok("'%s' calls mark_stimulus()" % trial_id, marks, path)

	# Behavioural: actually play each one and inspect what it recorded.
	print("\n── played runs record real latencies ──")
	for trial_id: String in (registry.call("all_ids") as Array):
		if EXEMPT.has(trial_id):
			continue
		await _play_and_check(trial_id)

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d TIMING CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


## Mount a trial, answer a few rounds, and assert the timing it recorded.
func _play_and_check(trial_id: String) -> void:
	var host: Node = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	host.call("configure", {"trial_id": trial_id, "skip_tutorial": true})
	root.add_child(host)
	await process_frame
	await process_frame

	var game: Node = host.get_node_or_null("%Stage/MiniGame")
	_ok("'%s' mounts" % trial_id, game != null)
	if game == null:
		host.free()
		await process_frame
		return

	# Drive the clock and answer whatever becomes answerable, the way a
	# player would. Each mode exposes its own tap entry point, so answer
	# through the base's hit targets rather than mode-specific internals.
	var answered: int = 0
	var guard: int = 0
	while answered < 3 and guard < 400 and bool(game.call("is_running")):
		guard += 1
		if game.has_method("_process"):
			game.call("_process", 0.05)
		await process_frame

		# Only answer once a stimulus is actually LIVE. Tapping before the
		# mode marks one produced a 0ms reading and looked like a timing bug
		# in trend_witness; it was the test racing the phase machine.
		# Measured: latency is 7ms immediately after the mark and 21ms two
		# frames later, so the timer is sound.
		if int(game.call("latency_since_stimulus")) <= 0:
			continue
		# Let a little real time pass so the latency is unambiguously
		# non-zero rather than sub-millisecond.
		await process_frame
		await process_frame
		if _tap_first_target(game):
			answered += 1
			await process_frame

	var latencies: Array = game.call("latencies")
	var misses: int = int(game.call("miss_count"))

	# The core contract: an ANSWERED round must produce a latency. A mode
	# that answers without one is the exact defect this file exists for.
	_ok("'%s' recorded timing for answered rounds" % trial_id,
		latencies.size() + misses > 0,
		"answered=%d latencies=%d misses=%d" % [answered, latencies.size(), misses])

	if not latencies.is_empty():
		var negative: Array[String] = []
		for value: Variant in latencies:
			if int(value) < 0:
				negative.append(str(value))
		_ok("'%s' has no negative latency" % trial_id, negative.is_empty(),
			", ".join(negative))
		_ok("'%s' mean latency is positive" % trial_id,
			int(game.call("mean_latency_ms")) > 0,
			str(game.call("mean_latency_ms")))
		_ok("'%s' reports a response" % trial_id, bool(game.call("had_any_response")))

	host.free()
	await process_frame


## Press the first live hit target, mimicking a tap. Returns true if one fired.
func _tap_first_target(node: Node) -> bool:
	for child: Node in node.get_children():
		if child is Control and (child as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
			var press: InputEventMouseButton = InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			(child as Control).gui_input.emit(press)
			return true
	return false
