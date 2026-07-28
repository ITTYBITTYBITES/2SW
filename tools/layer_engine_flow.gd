extends SceneTree
## Verification for the hybrid procedural audio engine.
##
## THE THING THIS MUST NOT DO is assert that the code exists. The pad had a
## per-trial mode table for a whole commit before anyone noticed every trial
## sounded the same, because the check compared the table to itself. Every
## check here measures a RESULT: a resolved mix, a live voice count, a
## rendered spectrum.
##
## Three properties matter, in order:
##   1. NOTHING BELOW 120 Hz reaches a phone speaker, from any path
##   2. the mix RESPONDS — density, brightness and pitch move with state
##   3. the four trials are actually DIFFERENT, not one bed at four volumes

var _fails: Array[String] = []
var _n: int = 0


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != ""
			else ""])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ LAYER ENGINE ═══\n")
	await process_frame
	await process_frame

	var scene: GDScript = ResourceLoader.load(
		"res://data/audio_scene.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	_check_frequency_rule(scene)
	_check_modes_differ(scene)
	_check_state_response(scene)
	_check_library(scene)
	await _check_live_engine()
	await _check_no_clipping(scene)

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d LAYER ENGINE CHECKS PASSED" % _n)
	else:
		print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(0 if _fails.is_empty() else 1)


# ═════════════════════════════════════════════════════════════════════════
## THE FREQUENCY RULE. Sub-bass is inaudible on a phone and distorts on a
## laptop, so the whole point of the rebuild is that nothing goes there.
##
## Checked at the MODEL level (every mode, every interval, every transposition
## the engine can request) rather than by inspecting constants, because the
## dangerous case is a legal-looking mode transposed down at runtime.
func _check_frequency_rule(scene: GDScript) -> void:
	print("── nothing reaches the sub-bass ──")
	var consts: Dictionary = scene.get_script_constant_map()
	var floor_hz: float = float(consts["MIN_AUDIBLE_HZ"])
	var low: float = float(consts["CLEAR_LOW_HZ"])
	var high: float = float(consts["CLEAR_HIGH_HZ"])

	_ok("the audible floor is at least 120 Hz", floor_hz >= 120.0,
		"%.0f Hz" % floor_hz)
	_ok("the clear band is the mid-range",
		low >= 200.0 and high <= 1200.0 and low < high,
		"%.0f-%.0f Hz" % [low, high])

	var modes: Dictionary = consts["MODES"]
	var all_modes: Array = modes.values()
	all_modes.append(consts["MODE_NEUTRAL"])

	for mode: Dictionary in all_modes:
		# `mode_root`, not `root`: SceneTree already declares a `root`
		# property (the window), and shadowing it is a warning the sweep
		# treats as an error — and a genuine trap for anyone who later
		# reaches for the viewport inside this loop.
		var mode_root: float = float(mode["root_hz"])
		_ok("root %.1f Hz is inside the clear band" % mode_root,
			scene.in_clear_band(mode_root), "%.1f Hz" % mode_root)
		# EVERY VOICED INTERVAL, not just the root. A mode whose root is legal
		# can still voice a note below the floor if an interval is negative.
		for semis: float in mode["intervals"]:
			var hz: float = scene.resolve_pitch(mode_root, float(semis))
			_ok("root %.0f + %.0f semitones stays audible (%.1f Hz)"
				% [mode_root, semis, hz], hz >= floor_hz, "%.1f Hz" % hz)

	# THE CLAMP IS THE POINT. Ask for something absurd and it must refuse.
	# Without this the check above only proves the authored data is fine,
	# which says nothing about the function that protects it.
	_ok("a -48 semitone transposition is clamped, not obeyed",
		scene.resolve_pitch(440.0, -48.0) >= floor_hz,
		"%.2f Hz" % scene.resolve_pitch(440.0, -48.0))
	_ok("27 Hz is rejected as inaudible", not scene.is_audible(27.0))
	_ok("60 Hz is rejected as inaudible", not scene.is_audible(60.0))
	_ok("110 Hz — the OLD pad root — is rejected",
		not scene.is_audible(110.0),
		"the previous bed's fundamental was below the floor")
	_ok("330 Hz is accepted", scene.is_audible(330.0))


# ═════════════════════════════════════════════════════════════════════════
## THE FOUR TRIALS MUST SOUND DIFFERENT.
##
## Compared by RESOLVED MIX, not by reading the mode table: a resolver that
## ignored the mode entirely would pass a table-vs-table comparison.
func _check_modes_differ(scene: GDScript) -> void:
	print("── every trial has its own character ──")
	var trials: Array[String] = [
		"false_witness", "sequence_recall", "cognitive_conflict",
		"facet_cascade",
	]
	var signatures: Dictionary = {}
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var mix: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.0, 0.0)
		_ok("%s resolves a mix" % trial_id, mix.size() >= 3,
			"%d layers" % mix.size())
		# A signature is the actual sounding result: which layers, at what
		# pitches, through what filter.
		var parts: Array[String] = []
		for m in mix:
			parts.append("%s@%.3f/%.0f" % [String(m.layer), m.pitch, m.cutoff])
		parts.sort()
		signatures[trial_id] = "|".join(parts)

	var distinct: int = 0
	var pairs: int = 0
	for i: int in range(trials.size()):
		for j: int in range(i + 1, trials.size()):
			pairs += 1
			if signatures[trials[i]] != signatures[trials[j]]:
				distinct += 1
	_ok("all four trials resolve DIFFERENT mixes", distinct == pairs,
		"%d of %d pairs differ" % [distinct, pairs])

	# ── WHAT ACTUALLY REACHES THE SPEAKER ────────────────────────────────
	#
	# THE BUG THIS CATCHES, found by rendering audio and running an FFT
	# rather than by any check: a voice's playback ratio was computed as
	# `sounding_hz / mode_root_hz`, which is the interval alone. The mode's
	# root cancelled out, so two modes sharing a layer sounded at IDENTICAL
	# pitches. sequence_recall (root 293.66) and cognitive_conflict (root
	# 349.23) measured the same five strongest partials to 0.1 Hz.
	#
	# The signature check above passed the whole time, because it compared
	# layer names, requested ratios and cutoffs — everything EXCEPT the
	# frequency the player hears.
	var pitch_sets: Dictionary = {}
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var mix: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.0, 0.0)
		var heard: Array[String] = []
		for m in mix:
			var baked: float = float(scene.LAYER_ROOT_HZ.get(m.layer, 0.0))
			if baked <= 0.0:
				continue    # texture: no fundamental to compare
			heard.append("%.1f" % (baked * m.pitch))
		heard.sort()
		pitch_sets[trial_id] = ",".join(heard)
		_ok("%s sounds real pitches" % trial_id, not heard.is_empty(),
			pitch_sets[trial_id])

	var heard_distinct: int = 0
	for i: int in range(trials.size()):
		for j: int in range(i + 1, trials.size()):
			if pitch_sets[trials[i]] != pitch_sets[trials[j]]:
				heard_distinct += 1
			else:
				print("      %s and %s sound IDENTICAL: %s" % [
					trials[i], trials[j], pitch_sets[trials[i]]])
	_ok("all four trials SOUND at different pitches",
		heard_distinct == pairs,
		"%d of %d pairs differ" % [heard_distinct, pairs])

	# Every sounding frequency must clear the floor AFTER the ratio clamp —
	# a clamped ratio can land somewhere the unclamped request never would.
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var probe_states: Array = [scene.State.IDLE, scene.State.STREAK,
			scene.State.URGENT]
		for state: int in probe_states:
			var mix: Array = scene.resolve_mix(mode, state, 1.0, 1.0)
			for m in mix:
				var baked: float = float(scene.LAYER_ROOT_HZ.get(m.layer, 0.0))
				if baked <= 0.0:
					continue
				var hz: float = baked * m.pitch
				_ok("%s/%d: %s sounds at %.0f Hz, above the floor"
					% [trial_id, state, String(m.layer), hz],
					hz >= float(scene.get_script_constant_map()[
						"MIN_AUDIBLE_HZ"]), "%.1f Hz" % hz)

	# ── THE CLEAR BAND, NOT MERELY "ABOVE THE FLOOR" ─────────────────────
	#
	# 143 Hz clears MIN_AUDIBLE_HZ and is still wrong: the spec asks for the
	# dynamic layering to sit in 200 Hz - 1.2 kHz, because that is where a
	# phone speaker is actually flat. Between 120 and 200 Hz it is rolling
	# off hard.
	#
	# THE BUG THIS CATCHES: pitching the bed an octave below the mode root
	# put false_witness's foundation at 143 Hz and both mid modes at 191 Hz.
	# Every "above the floor" check passed; measured on rendered audio,
	# clear-band energy had collapsed from 91-99% to 24-37%.
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var mix: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.0, 0.0)
		for m in mix:
			var baked: float = float(scene.LAYER_ROOT_HZ.get(m.layer, 0.0))
			if baked <= 0.0:
				continue
			var hz: float = baked * m.pitch
			# Upper chord voices may exceed the band — that is overtone
			# content and it is fine. What must NOT happen is a fundamental
			# falling below it.
			_ok("%s: %s does not sound below the clear band"
				% [trial_id, String(m.layer)],
				hz >= float(scene.get_script_constant_map()["CLEAR_LOW_HZ"]),
				"%.1f Hz" % hz)

	# ── THE REQUESTED NOTE MUST ACTUALLY SOUND ───────────────────────────
	#
	# THE BUG THIS CATCHES, spotted only by reading a live voice dump:
	# `glass_low@1.5500` — the ratio pinned exactly at MAX_PITCH_RATIO.
	# false_witness voices root +12 (an octave, 523.25 Hz) but named
	# glass_low, baked at 261.63, so it asked for a 2.0x shift, got clamped
	# to 1.55, and the octave SOUNDED AT 405 Hz — a flat sixth.
	#
	# Every check passed: the pitch was "musical", the frequency was above
	# the floor and inside the clear band. It was simply the wrong note.
	# Comparing what sounds against what was ASKED FOR is the only version
	# of this that bites.
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var mode_root: float = float(mode["root_hz"])
		var mix: Array = scene.resolve_mix(mode, scene.State.STREAK, 1.0, 0.0)
		var voiced: Array[float] = []
		for m in mix:
			if m.role == scene.Role.VOICE:
				var baked: float = float(scene.LAYER_ROOT_HZ.get(m.layer, 0.0))
				voiced.append(baked * m.pitch)
		voiced.sort()
		for i: int in range(mode["intervals"].size()):
			if i >= voiced.size():
				continue
			var wanted: float = scene.resolve_pitch(
				mode_root, float(mode["intervals"][i]))
			# Within a quarter-tone (~3%) of the intended pitch. Anything
			# further and it is a different note, not a detune.
			var cents_off: float = absf(
				1200.0 * log(voiced[i] / wanted) / log(2.0))
			_ok("%s: interval %d sounds the note it asked for"
				% [trial_id, int(mode["intervals"][i])],
				cents_off <= 50.0,
				"wanted %.1f Hz, sounds %.1f Hz (%.0f cents off)" % [
					wanted, voiced[i], cents_off])

	# The pitch shift must stay musical. Past roughly a fifth the modelled
	# body's formants stretch audibly and a bowed glass starts to chirp.
	for trial_id: String in trials:
		var mode: Dictionary = scene.mode_for(trial_id)
		var mix: Array = scene.resolve_mix(mode, scene.State.STREAK, 1.0, 0.0)
		for m in mix:
			_ok("%s: %s is shifted by a musical amount"
				% [trial_id, String(m.layer)],
				m.pitch >= 0.6 and m.pitch <= 1.6, "x%.3f" % m.pitch)

	# ...and each must differ from the hub, or entering a trial is silent
	# news.
	var neutral: Array = scene.resolve_mix(
		scene.MODE_NEUTRAL, scene.State.IDLE, 0.0, 0.0)
	var neutral_parts: Array[String] = []
	for m in neutral:
		neutral_parts.append("%s@%.3f/%.0f" % [String(m.layer), m.pitch,
			m.cutoff])
	neutral_parts.sort()
	var neutral_sig: String = "|".join(neutral_parts)
	for trial_id: String in trials:
		_ok("%s differs from the hub bed" % trial_id,
			signatures[trial_id] != neutral_sig)


# ═════════════════════════════════════════════════════════════════════════
## THE MIX RESPONDS TO PLAY.
##
## The old bed moved one number: intensity. These assert the three dimensions
## the rebuild added — density, brightness, and continuous modulation.
func _check_state_response(scene: GDScript) -> void:
	print("── the mix responds to gameplay ──")
	var mode: Dictionary = scene.mode_for("false_witness")

	var idle: Array = scene.resolve_mix(mode, scene.State.IDLE, 0.0, 0.0)
	var active: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.0, 0.0)
	var streak: Array = scene.resolve_mix(mode, scene.State.STREAK, 1.0, 0.0)
	var urgent: Array = scene.resolve_mix(mode, scene.State.URGENT, 0.0, 1.0)
	var menu: Array = scene.resolve_mix(mode, scene.State.MENU, 0.0, 0.0)

	# DENSITY. More going on when more is at stake.
	_ok("a streak adds layers over idle", streak.size() > idle.size(),
		"idle %d vs streak %d" % [idle.size(), streak.size()])
	_ok("a menu is thinner than active play", menu.size() <= active.size(),
		"menu %d vs active %d" % [menu.size(), active.size()])
	_ok("the bed is never empty", menu.size() >= 1, "%d" % menu.size())

	# BRIGHTNESS. Urgency opens the filter; that is the "pulse" of the
	# urgency state and it must be measurable.
	var idle_cut: float = _max_cutoff(idle)
	var urgent_cut: float = _max_cutoff(urgent)
	_ok("urgency opens the filter", urgent_cut > idle_cut * 1.3,
		"idle %.0f Hz vs urgent %.0f Hz" % [idle_cut, urgent_cut])

	# CONTINUOUS, not stepped. A half-built streak must land between the two
	# extremes, or the system is six presets wearing a trench coat.
	var half: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.5, 0.0)
	var none: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 0.0, 0.0)
	var full: Array = scene.resolve_mix(mode, scene.State.ACTIVE, 1.0, 0.0)
	_ok("streak modulates continuously within a state",
		half.size() >= none.size() and full.size() >= half.size(),
		"%d / %d / %d layers" % [none.size(), half.size(), full.size()])

	var u0: float = _max_cutoff(scene.resolve_mix(
		mode, scene.State.ACTIVE, 0.0, 0.0))
	var u5: float = _max_cutoff(scene.resolve_mix(
		mode, scene.State.ACTIVE, 0.0, 0.5))
	var u1: float = _max_cutoff(scene.resolve_mix(
		mode, scene.State.ACTIVE, 0.0, 1.0))
	_ok("urgency modulates the filter continuously",
		u5 > u0 and u1 > u5, "%.0f / %.0f / %.0f Hz" % [u0, u5, u1])

	# EVERY resolved cutoff must stay inside the reproducible band.
	var every_state: Array = [scene.State.IDLE, scene.State.ACTIVE,
		scene.State.STREAK, scene.State.URGENT, scene.State.RESULTS,
		scene.State.MENU]
	for state: int in every_state:
		var mix: Array = scene.resolve_mix(mode, state, 1.0, 1.0)
		for m in mix:
			_ok("state %d: %s cutoff is sane" % [state, String(m.layer)],
				m.cutoff >= 800.0 and m.cutoff <= float(
					scene.get_script_constant_map()["TEXTURE_MAX_HZ"]),
				"%.0f Hz" % m.cutoff)


func _max_cutoff(mix: Array) -> float:
	var top: float = 0.0
	for m in mix:
		top = maxf(top, m.cutoff)
	return top


# ═════════════════════════════════════════════════════════════════════════
## EVERY LAYER A MODE NAMES MUST EXIST ON DISK.
##
## A missing layer is one silent voice in a chord — the mix still plays, so
## nothing looks broken, and the mode quietly loses its character.
func _check_library(scene: GDScript) -> void:
	print("── the layer library is complete ──")
	var required: Array = scene.required_layers()
	_ok("the model requires layers at all", required.size() >= 5,
		"%d" % required.size())
	for layer in required:
		var path: String = "res://audio/layers/%s.ogg" % String(layer)
		# FileAccess, not ResourceLoader.exists(): the latter returns true for
		# a deleted file whose .import sidecar survives.
		_ok("layer '%s' exists" % String(layer),
			FileAccess.file_exists(path), path)


# ═════════════════════════════════════════════════════════════════════════
## THE LIVE ENGINE. Everything above is the model; this is the autoload.
func _check_live_engine() -> void:
	print("── the live engine plays and responds ──")
	var engine: Node = root.get_node_or_null("LayerEngine")
	_ok("the LayerEngine autoload is registered", engine != null)
	if engine == null:
		return

	# THE BUS CHAIN. Order is load-bearing: a reverb fed sub-bass returns a
	# smeared sub-bass tail, so the high-pass must come FIRST.
	var bus: int = AudioServer.get_bus_index(&"IrisLayers")
	_ok("the IrisLayers bus exists", bus != -1)
	if bus == -1:
		return
	var effects: Array[String] = []
	for i: int in range(AudioServer.get_bus_effect_count(bus)):
		effects.append(AudioServer.get_bus_effect(bus, i).get_class())
	_ok("the bus carries a high-pass", effects.has("AudioEffectHighPassFilter"),
		str(effects))
	_ok("the high-pass runs FIRST, before anything can resonate the low end",
		effects.size() > 0 and effects[0] == "AudioEffectHighPassFilter",
		str(effects))
	_ok("the bus carries reverb for depth", effects.has("AudioEffectReverb"))
	_ok("the bus carries a delay for space", effects.has("AudioEffectDelay"))
	_ok("the bus carries a limiter as a backstop",
		effects.has("AudioEffectLimiter"))

	var hp: AudioEffectHighPassFilter = null
	for i: int in range(AudioServer.get_bus_effect_count(bus)):
		var fx: AudioEffect = AudioServer.get_bus_effect(bus, i)
		if fx is AudioEffectHighPassFilter:
			hp = fx as AudioEffectHighPassFilter
			break
	_ok("the runtime high-pass cuts at 100 Hz or above",
		hp != null and hp.cutoff_hz >= 100.0,
		"%.0f Hz" % (hp.cutoff_hz if hp != null else 0.0))

	# IT ACTUALLY PLAYS. A correct model driving a dead engine is silence.
	engine.call("set_mode", "cognitive_conflict")
	engine.call("set_state", 1)   # ACTIVE
	for _i: int in range(90):
		await process_frame
	await create_timer(1.2).timeout
	_ok("the engine is running", bool(engine.call("is_running")))
	var active_voices: int = int(engine.call("active_voice_count"))
	_ok("layers are audible", active_voices >= 3, "%d voices" % active_voices)

	# PITCH SHIFTING IS REAL. The chord is voiced by transposing one layer,
	# so at least two voices must be playing at different pitches.
	var report: Dictionary = engine.call("voice_report")
	var pitches: Dictionary = {}
	for key: String in report.keys():
		pitches[float(report[key]["pitch"])] = true
	_ok("the chord is voiced at multiple pitches", pitches.size() >= 2,
		str(pitches.keys()))

	# NO VOICE MAY BE PITCHED INTO THE SUB-BASS. This is the runtime version
	# of the frequency rule: a legal layer played at 0.4x is not legal.
	for key: String in report.keys():
		var pitch: float = float(report[key]["pitch"])
		_ok("voice '%s' is not pitched into the sub-bass" % key,
			pitch >= 0.5, "pitch %.3f" % pitch)

	# RESPONSIVENESS. A state change must be reflected without a restart,
	# and must not drop the bed to silence in between — a gap is worse than
	# a wrong mix.
	var before: int = int(engine.call("active_voice_count"))
	engine.call("set_state", 3)   # URGENT
	engine.call("set_urgency", 1.0)
	for _i: int in range(30):
		await process_frame
	_ok("the engine keeps sounding through a state change",
		bool(engine.call("is_running")),
		"before %d after %d" % [before, engine.call("active_voice_count")])
	_ok("the state actually changed", int(engine.call("current_state")) == 3)

	# LEAVING A TRIAL RESOLVES THE BED.
	engine.call("set_neutral_mode")
	engine.call("set_state", 0)
	for _i: int in range(30):
		await process_frame
	_ok("returning to neutral changes the root",
		not is_equal_approx(float(engine.call("mode_root_hz")), 349.23),
		"%.2f Hz" % float(engine.call("mode_root_hz")))


# ═════════════════════════════════════════════════════════════════════════
## THE MIX MUST NOT CLIP.
##
## Six layers can sound at once. The bus limiter is a BACKSTOP; if the summed
## gain routinely exceeds unity the limiter is doing the mixing, which
## pumps and squashes exactly when the game is most intense.
func _check_no_clipping(scene: GDScript) -> void:
	print("── the mix cannot clip ──")
	var worst: float = 0.0
	var worst_where: String = ""
	var all_modes: Array = scene.MODES.values()
	all_modes.append(scene.MODE_NEUTRAL)
	for mode: Dictionary in all_modes:
		var loud_states: Array = [scene.State.IDLE, scene.State.ACTIVE,
			scene.State.STREAK, scene.State.URGENT, scene.State.RESULTS,
			scene.State.MENU]
		for state: int in loud_states:
			# The loudest possible request: full streak AND full urgency.
			var mix: Array = scene.resolve_mix(mode, state, 1.0, 1.0)
			var total: float = scene.total_gain(mix)
			if total > worst:
				worst = total
				worst_where = "root %.0f state %d" % [
					float(mode["root_hz"]), state]
	_ok("the summed gain stays below unity at every extreme", worst < 1.0,
		"%.3f at %s" % [worst, worst_where])
	# ...and is not so quiet the bed is inaudible.
	_ok("the loudest mix is still a real signal", worst > 0.30,
		"%.3f" % worst)
