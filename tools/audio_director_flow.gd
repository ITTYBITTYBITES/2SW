extends SceneTree
## AUDIO DIRECTOR — live behavioural checks.
##
## WHY THIS RUNS AGAINST THE ENGINE RATHER THAN SCANNING SOURCE
##
## The bug this whole system exists to fix was invisible to source checks:
## AudioManager was complete and correct, DialogueManifest was complete and
## correct, and the game was still almost silent because nothing CALLED them.
## Grepping for `play_sfx` would have found 39 hits and reported health.
##
## AND `AudioStreamPlayer.playing` IS NOT EVIDENCE.
##
## A generator stream reports `playing == true` forever once started. Measured
## directly: the voice player still read `true` 1.5 seconds after a 0.3 second
## utterance had finished. An early diagnostic was fooled by exactly this and
## reported that a correct answer produced a voice line when the sound was
## actually residue from the splash.
##
## So every check below asserts on AudioDirector's DISPATCH COUNTERS, which
## increment once per sound actually handed to the synthesiser.

var _n: int = 0
var _fails: Array[String] = []


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _init() -> void:
	_run.call_deferred()


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _run() -> void:
	print("\n═══ AUDIO DIRECTOR (live) ═══\n")
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("wipe")
	root.size = Vector2i(1080, 1920)
	root.content_scale_size = Vector2i(1080, 1920)
	await process_frame

	var director: Node = root.get_node_or_null("AudioDirector")
	var audio: Node = root.get_node_or_null("AudioManager")
	var bus: Node = root.get_node_or_null("Bus")
	var router: Node = root.get_node_or_null("Router")

	_ok("the AudioDirector autoload exists", director != null)
	_ok("the AudioManager autoload exists", audio != null)
	if director == null or audio == null:
		_report()
		return

	# It must survive backgrounding for the same reason AudioManager must: a
	# paused director stops ticking urgency and the pad never settles again.
	_ok("the director is not pausable",
		director.process_mode == Node.PROCESS_MODE_ALWAYS,
		"process_mode=%d" % director.process_mode)

	var app: Node = (load("res://app/app.tscn") as PackedScene).instantiate()
	root.add_child(app)
	await _wait(0.8)

	await _check_hub(director, audio, bus, router)
	await _check_trial(director, audio, router)
	await _check_trial_modes(director, audio, router)
	await _check_urgency(director, audio, router)
	await _check_dead_signal_is_alive(bus)
	await _check_voice_pack(audio)

	_report()


# ═════════════════════════════════════════════════════════════════════════
func _check_hub(director: Node, audio: Node, bus: Node, router: Node) -> void:
	print("── the hub answers the player ──")
	await router.call("go", "hub")
	await _wait(0.8)

	_ok("the hub settles the pad",
		is_equal_approx(float(audio.get("_pad_target_intensity")), 0.20),
		"pad %.2f" % float(audio.get("_pad_target_intensity")))

	# THE EYE TAP. This produced no sound at all before the director existed:
	# hub_portal_controller.gd contained zero AudioManager calls.
	var taps_before: int = int(director.call("dispatch_count", &"ui_tap"))
	var voice_before: int = int(director.call("dispatch_count", &"voice:hub_greet"))
	bus.emit_signal("iris_tapped", 0)
	await process_frame
	_ok("tapping the eye makes a sound",
		int(director.call("dispatch_count", &"ui_tap")) > taps_before)
	_ok("tapping the eye speaks a line",
		int(director.call("dispatch_count", &"voice:hub_greet")) > voice_before)

	# And it must not machine-gun: a second tap inside the cooldown gets the
	# tone but not another utterance.
	var voice_after: int = int(director.call("dispatch_count", &"voice:hub_greet"))
	bus.emit_signal("iris_tapped", 0)
	await process_frame
	_ok("a rapid second tap does not re-speak",
		int(director.call("dispatch_count", &"voice:hub_greet")) == voice_after,
		"the companion would stutter")

	# Shard drag: hover then commit.
	var swap_before: int = int(director.call("dispatch_count", &"swap"))
	bus.emit_signal("iris_shard_hovered", 1)
	await process_frame
	_ok("hovering a shard ticks",
		int(director.call("dispatch_count", &"swap")) > swap_before)

	# Leaving every shard must NOT tick, or crossing dead space clicks madly.
	var swap_mid: int = int(director.call("dispatch_count", &"swap"))
	# 0 is IrisState.CompassShard.NONE. Named literally because IrisState
	# cannot be referenced from a --script MainLoop: it is compiled before the
	# autoloads it depends on exist, and the whole flow fails to load.
	bus.emit_signal("iris_shard_hovered", 0)
	await process_frame
	_ok("leaving every shard is silent",
		int(director.call("dispatch_count", &"swap")) == swap_mid)

	var match_before: int = int(director.call("dispatch_count", &"match"))
	bus.emit_signal("iris_shard_committed", 1)
	await process_frame
	_ok("committing a shard resolves",
		int(director.call("dispatch_count", &"match")) > match_before)


# ═════════════════════════════════════════════════════════════════════════
func _check_trial(director: Node, audio: Node, router: Node) -> void:
	print("── the trial is audible ──")
	var start_before: int = int(director.call("dispatch_count", &"voice:trial_start"))
	await router.call("go", "trial",
		{"trial_id": "false_witness", "skip_tutorial": true})
	await _wait(1.2)

	# INVERTED. This asserted that entering a trial SPEAKS, which is the
	# behaviour that was reported as a defect: "the voice is only suppose to
	# be on the the hub where the eye is". A 1-3 second clip lands on top of a
	# 2.2 second answer window and competes with the concentration the round
	# demands.
	#
	# Silence during a trial is now the contract, so silence is what is
	# checked. Asserting the absence is the only version of this that catches
	# a regression: the clips still exist, the manifest still lists them, and
	# one uncommented line in _on_trial_started() brings the voice back.
	_ok("entering a trial stays SILENT — the Iris speaks on the hub only",
		int(director.call("dispatch_count", &"voice:trial_start")) == start_before,
		"a spoken line landed inside a timed round")
	_ok("the pad rises for a trial",
		float(audio.get("_pad_target_intensity")) > 0.20,
		"pad %.2f" % float(audio.get("_pad_target_intensity")))

	var host: Node = router.call("current_screen")
	_ok("the trial host mounted", host != null)
	if host == null:
		return

	# THE CENTRAL CASE. record_answer() is the choke point every mini-game
	# reports through, and its iris_express emission had no listener at all.
	var reward_before: int = int(director.call("dispatch_count", &"reward"))
	host.call("record_answer", true)
	await process_frame
	_ok("a correct answer makes a sound",
		int(director.call("dispatch_count", &"reward")) > reward_before,
		"iris_express had no listener before the director")

	var error_before: int = int(director.call("dispatch_count", &"error"))
	host.call("record_answer", false)
	await process_frame
	_ok("a wrong answer makes a DIFFERENT sound",
		int(director.call("dispatch_count", &"error")) > error_before)


# ═════════════════════════════════════════════════════════════════════════
## EVERY TRIAL SOUNDS LIKE ITSELF.
##
## The pad was a single 110 Hz drone for the whole game: _on_trial_started()
## received trial_id and discarded it, so four modes shared one bed and only
## the intensity moved.
##
## Checked by ENTERING each trial for real and reading the pad back, not by
## inspecting the table — a table compared against itself proves nothing, and
## a director that ignored TRIAL_MODES entirely would pass that.
func _check_trial_modes(_director: Node, audio: Node, router: Node) -> void:
	print("── each trial has its own musical bed ──")
	var trials: Array[String] = [
		"false_witness", "sequence_recall", "cognitive_conflict",
		"facet_cascade",
	]
	var roots: Dictionary = {}
	var colours: Dictionary = {}

	for trial_id: String in trials:
		await router.call("go", "hub")
		await _wait(0.3)
		await router.call("go", "trial",
			{"trial_id": trial_id, "skip_tutorial": true})
		await _wait(0.6)
		roots[trial_id] = float(audio.call("pad_root"))
		colours[trial_id] = float(audio.call("pad_colour"))
		_ok("%s retunes the pad" % trial_id,
			roots[trial_id] > 1.0,
			"root %.2f Hz colour %.3f" % [roots[trial_id], colours[trial_id]])

	# THE CENTRAL CLAIM: no two trials sound the same. A director that set
	# every mode to the same value would satisfy every check above.
	var distinct: int = 0
	for i: int in range(trials.size()):
		for j: int in range(i + 1, trials.size()):
			var a: String = trials[i]
			var b: String = trials[j]
			if absf(roots[a] - roots[b]) > 0.5 \
					or absf(colours[a] - colours[b]) > 0.01:
				distinct += 1
	# float division then int(): trials.size() is even here, but integer
	# division silently truncating a pair count would understate the target
	# and let a real collision pass.
	var pairs: int = int(float(trials.size() * (trials.size() - 1)) / 2.0)
	_ok("all four trials are musically distinct", distinct == pairs,
		"%d of %d pairs differ" % [distinct, pairs])

	# Returning to the hub must RESOLVE the bed, not leave the last trial's
	# colour hanging under the menu.
	await router.call("go", "hub")
	await _wait(0.6)
	_ok("the hub returns to the neutral bed",
		is_equal_approx(float(audio.call("pad_colour")), 1.5),
		"colour %.3f" % float(audio.call("pad_colour")))

	# ...and the retuning must reach the SAMPLES, not just a variable. The
	# generator is the only thing a player actually hears.
	await router.call("go", "trial",
		{"trial_id": "cognitive_conflict", "skip_tutorial": true})
	await _wait(0.8)
	_ok("the mode reached the running generator",
		bool(audio.call("is_pad_playing"))
		and is_equal_approx(float(audio.call("pad_colour")), 1.2),
		"playing=%s colour=%.3f" % [
			str(audio.call("is_pad_playing")),
			float(audio.call("pad_colour"))])
	await router.call("go", "hub")
	await _wait(0.3)


# ═════════════════════════════════════════════════════════════════════════
func _check_urgency(director: Node, audio: Node, router: Node) -> void:
	print("── time pressure is audible ──")
	# Bracket 2 is a 2.2s window, so the final quarter (0.55s) arrives fast.
	# Nothing is answered, so the window is allowed to expire naturally: the
	# urgency must come from REAL play, not a hand-emitted signal.
	await router.call("go", "hub")
	await _wait(0.4)
	await router.call("go", "trial",
		{"trial_id": "false_witness", "bracket": 2, "skip_tutorial": true})
	await _wait(0.4)

	var ticks_before: int = int(director.call("dispatch_count", &"stroop_pulse"))
	var saw_urgent: bool = false
	var urgent_pad: float = 0.0
	# Watch for the director to enter urgency during a real window.
	for _i: int in range(240):
		await process_frame
		if bool(director.call("is_urgent")):
			saw_urgent = true
			urgent_pad = float(audio.get("_pad_target_intensity"))
			break

	_ok("a real expiring window becomes urgent", saw_urgent,
		"urgency never fired during live play")
	_ok("urgency lifts the pad", saw_urgent and urgent_pad > 0.42,
		"pad %.2f" % urgent_pad)

	await _wait(0.9)
	_ok("urgency ticks while it lasts",
		int(director.call("dispatch_count", &"stroop_pulse")) > ticks_before)

	# And it must STOP. A tick that outlives the round is worse than none.
	await _wait(1.4)
	var settled: int = int(director.call("dispatch_count", &"stroop_pulse"))
	await _wait(0.8)
	var after_round: bool = not bool(director.call("is_urgent"))
	_ok("urgency clears when the round resolves",
		after_round or int(director.call("dispatch_count", &"stroop_pulse")) > settled,
		"still urgent with no new round")


# ═════════════════════════════════════════════════════════════════════════
## The signal that started all of this.
##
## Bus.iris_express had three emitters and ZERO listeners for the life of the
## project — every answer announced itself into a void. This asserts the
## subscription exists, because a regression here is silent by definition.
func _check_dead_signal_is_alive(bus: Node) -> void:
	print("── no gameplay signal is left unheard ──")
	for signal_name: String in ["iris_express", "trial_started",
			"trial_completed", "trial_urgency_changed",
			"iris_tapped", "iris_shard_committed"]:
		var count: int = bus.get_signal_connection_list(signal_name).size()
		_ok("Bus.%s has a listener" % signal_name, count > 0,
			"emitted by gameplay and heard by nobody")


## The Iris speaks the AUTHORED TEXT, not a hum, and the clip matches the line.
##
## THE FAILURE THIS CATCHES IS SILENT. speak() falls back to the formant synth
## when a clip is missing, so a stale pack does not crash or even log loudly at
## the player — the companion simply stops speaking that line. Asserting the
## clip actually loaded is the only way to see it.
func _check_voice_pack(audio: Node) -> void:
	print("── the Iris speaks her authored lines ──")

	var bus_index: int = AudioServer.get_bus_index("IrisVoice")
	_ok("the dedicated voice bus exists", bus_index != -1)
	_ok("the voice bus carries its room processing",
		bus_index != -1 and AudioServer.get_bus_effect_count(bus_index) >= 2,
		"%d effects" % (AudioServer.get_bus_effect_count(bus_index)
			if bus_index != -1 else 0))

	var clips: Node = audio.get_node_or_null("IrisClips")
	_ok("the clip player exists", clips != null)
	_ok("the clip player routes through the voice bus",
		clips != null and str(clips.get("bus")) == "IrisVoice",
		str(clips.get("bus")) if clips != null else "no player")

	# Draw every line of a context and prove each one resolved to a real file.
	# The shuffle bag guarantees no repeats within a cycle, so this covers the
	# whole pool rather than sampling the same clip seven times.
	var hummed: int = 0
	var spoken: int = 0
	for _i: int in range(7):
		var line: String = str(audio.call("speak", &"hub_greet", &"hub_idle"))
		if line == "":
			continue
		var stream: AudioStream = clips.get("stream") as AudioStream
		if stream != null and str(stream.resource_path).ends_with(".ogg"):
			spoken += 1
		else:
			hummed += 1
		await process_frame
	_ok("every hub line resolved to a rendered clip", hummed == 0,
		"%d of %d fell back to the hum" % [hummed, hummed + spoken])
	_ok("the pack covered a full shuffle cycle", spoken >= 7,
		"only %d clips played" % spoken)

	# Every authored line must have a file. all_clip_paths() is derived from
	# the same table the generator reads, so this compares the script against
	# what actually shipped.
	var manifest: GDScript = ResourceLoader.load(
		"res://data/dialogue_manifest.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("the dialogue manifest is readable", manifest != null)
	var missing: int = 0
	var expected: int = 0
	if manifest != null:
		var paths: Array = manifest.call("all_clip_paths")
		expected = paths.size()
		for path: String in paths:
			# FileAccess, NOT ResourceLoader.exists().
			#
			# ResourceLoader.exists() consults the import database and returns
			# true for a deleted asset whose .import sidecar survives. Proven:
			# with hub_greet_03.ogg deleted from disk it still reported true,
			# and this check passed a genuinely broken pack even from a cold
			# cache. FileAccess asks the filesystem.
			if not FileAccess.file_exists(path):
				missing += 1
	_ok("every authored line has a clip on disk", missing == 0,
		"%d of %d missing" % [missing, expected])
	_ok("the pack is the expected size", expected >= 50,
		"%d clips declared" % expected)


func _report() -> void:
	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d AUDIO DIRECTOR CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)
