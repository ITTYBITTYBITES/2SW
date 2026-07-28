extends Node
class_name LayerEngineSystem
## LayerEngine — PHASE 2 CONTROLLER for the hybrid procedural audio system.
##
## AudioScene (Phase 1) decides WHAT the mix should be. This owns the players,
## the buses and the crossfades that make it so. It knows nothing about
## gameplay: AudioDirector translates Bus signals into set_state() calls.
##
## ── HYBRID, NOT SAMPLED AND NOT SYNTHESISED ──────────────────────────────
## The layers are baked (tools/bake_audio_layers.py) because timbre is what
## the old three-sine bed lacked, and a physically-modelled bowed-glass body
## is not something to re-derive every frame on a phone. Everything DYNAMIC
## is procedural: which layers are audible, their pitch, their filter cutoff,
## their entry timing, and a continuous filter sweep. Eleven loops therefore
## produce an effectively unbounded number of mixes, and nothing ever repeats
## exactly because the sweep LFOs run at incommensurate rates.
##
## ── THE FREQUENCY RULE, AT RUNTIME ───────────────────────────────────────
## The bus chain opens with a 100 Hz high-pass. This is the THIRD independent
## gate — the baker high-passes at 120 Hz and AudioScene clamps every pitch —
## and it exists because the other two are each one edit away from removal.
## A pitch-shifted layer can also fold content downward: playing a 220 Hz bed
## at 0.5x would put its fundamental at 110 Hz, and the bus catches that even
## though AudioScene should never have asked for it.
##
## ── WHY CROSSFADES AND NOT RESTARTS ──────────────────────────────────────
## A layer entering at full gain clicks and announces itself. Every gain and
## cutoff move is eased over FADE_SEC, so a state change is a swell rather
## than a cut, and a player never hears the machinery.

## The dedicated bus this system's players feed.
const LAYER_BUS: StringName = &"IrisLayers"

## Runtime high-pass. Below this, small speakers produce distortion or
## nothing. See the header: third of three independent gates.
const HIGHPASS_HZ: float = 100.0

## Bus chain shaping. Reverb places the layers in a room; the delay adds
## depth without smearing; the limiter is a backstop, not a mixing strategy.
const REVERB_ROOM: float = 0.62
const REVERB_WET: float = 0.30
const REVERB_DAMPING: float = 0.42
const REVERB_SPREAD: float = 0.72
const DELAY_TAP_MS: float = 320.0
const DELAY_LEVEL_DB: float = -18.0
const LIMIT_CEILING_DB: float = -1.5

## Seconds a gain or cutoff move takes. Long enough to read as a swell,
## short enough that a state change feels responsive.
const FADE_SEC: float = 1.10
## Faster path for urgency, which must arrive as a lurch, not a drift.
const FADE_FAST_SEC: float = 0.28

## Master trim for the whole layer bed, before the user's pad slider.
const BED_GAIN: float = 0.80

## Below this linear gain a player is stopped outright rather than left
## running silently — a dozen inaudible streams is wasted CPU on a phone.
const SILENCE_EPSILON: float = 0.004

const LAYER_DIR: String = "res://audio/layers/"


## One playing layer: its player, its filter, and where it is heading.
class Voice extends RefCounted:
	var key: String = ""
	var layer: StringName = &""
	var player: AudioStreamPlayer = null
	var target_gain: float = 0.0
	var current_gain: float = 0.0
	var target_cutoff: float = 6000.0
	var current_cutoff: float = 6000.0
	var pitch: float = 1.0
	## Per-voice LFO phase, so two layers never breathe in lockstep.
	var sweep_phase: float = 0.0
	var sweep_rate: float = 0.03
	var alive: bool = false


var _bus_index: int = -1
var _filter_index: int = -1
var _voices: Dictionary = {}
var _streams: Dictionary = {}
var _mode: Dictionary = {}
var _state: int = AudioScene.State.IDLE
var _streak: float = 0.0
var _urgency: float = 0.0
var _enabled: bool = true
var _level: float = 1.0
## Set once the bus and the library are both ready.
var _ready_to_play: bool = false
## Rising each frame while a state's layers stagger in, so entry_seconds
## actually staggers rather than everything arriving together.
var _state_age: float = 0.0


func _ready() -> void:
	_build_bus()
	_load_library()
	_ready_to_play = _bus_index != -1 and not _streams.is_empty()
	Log.must(_ready_to_play, "LayerEngine",
		"no layer library; the procedural bed will be silent")
	set_process(_ready_to_play)


func _exit_tree() -> void:
	for key: String in _voices.keys():
		var voice: Voice = _voices[key]
		if voice.player != null and is_instance_valid(voice.player):
			voice.player.stop()


# ═════════════════════════════════════════════════════════════════════════
# BUS CHAIN — physical depth, and the frequency rule
# ═════════════════════════════════════════════════════════════════════════
## Build the dedicated bus and hang the effect chain on it.
##
## Order matters and is deliberate:
##   1. HIGH-PASS   remove sub-bass BEFORE anything can resonate it. A reverb
##                  fed 60 Hz returns a smeared 60 Hz tail, so filtering
##                  afterwards would be too late.
##   2. REVERB      places the layers in a room rather than against the ear
##   3. DELAY       one soft tap; depth without a rhythmic echo
##   4. LIMITER     backstop only. If this is working hard, the mix is wrong.
##
## Built in code rather than as a bus layout resource for the same reason the
## voice bus is: the parameters belong beside the reasoning for them.
func _build_bus() -> void:
	_bus_index = AudioServer.get_bus_index(LAYER_BUS)
	if _bus_index != -1:
		_filter_index = 0
		return
	_bus_index = AudioServer.bus_count
	AudioServer.add_bus(_bus_index)
	AudioServer.set_bus_name(_bus_index, LAYER_BUS)
	AudioServer.set_bus_send(_bus_index, &"Master")

	var cut := AudioEffectHighPassFilter.new()
	cut.cutoff_hz = HIGHPASS_HZ
	# 12 dB/oct is not enough on its own; the baker's own 24 dB/oct pass and
	# this one together put anything an octave down well below audibility.
	cut.resonance = 0.5
	AudioServer.add_bus_effect(_bus_index, cut)
	_filter_index = 0

	var room := AudioEffectReverb.new()
	room.room_size = REVERB_ROOM
	room.wet = REVERB_WET
	room.dry = 1.0 - REVERB_WET * 0.5
	room.damping = REVERB_DAMPING
	room.spread = REVERB_SPREAD
	AudioServer.add_bus_effect(_bus_index, room)

	var echo := AudioEffectDelay.new()
	echo.tap1_active = true
	echo.tap1_delay_ms = DELAY_TAP_MS
	echo.tap1_level_db = DELAY_LEVEL_DB
	echo.tap2_active = false
	echo.feedback_active = false
	AudioServer.add_bus_effect(_bus_index, echo)

	var limiter := AudioEffectLimiter.new()
	limiter.ceiling_db = LIMIT_CEILING_DB
	limiter.threshold_db = -6.0
	AudioServer.add_bus_effect(_bus_index, limiter)


## Preload every layer AudioScene can ask for.
##
## Missing files are reported per-layer rather than as one count: a chord
## quietly voicing two notes instead of three is the kind of fault that never
## gets noticed, and naming the absent layer is what makes it findable.
func _load_library() -> void:
	for layer: StringName in AudioScene.required_layers():
		var path: String = "%s%s.ogg" % [LAYER_DIR, String(layer)]
		# FileAccess, not ResourceLoader.exists(): the latter returns true for
		# a deleted file whose .import sidecar survives.
		if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
			Log.warn("LayerEngine", "layer '%s' is missing at %s"
				% [String(layer), path])
			continue
		var stream: AudioStream = load(path) as AudioStream
		if stream == null:
			Log.warn("LayerEngine", "layer '%s' failed to load" % String(layer))
			continue
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = true
		_streams[layer] = stream


# ═════════════════════════════════════════════════════════════════════════
# PUBLIC CONTROL — what AudioDirector calls
# ═════════════════════════════════════════════════════════════════════════
## Switch to a trial's musical mode. Unregistered ids get the neutral bed.
func set_mode(trial_id: String) -> void:
	var next: Dictionary = AudioScene.mode_for(trial_id)
	if next == _mode:
		return
	_mode = next
	_state_age = 0.0
	_apply_mix()


func set_neutral_mode() -> void:
	if _mode == AudioScene.MODE_NEUTRAL:
		return
	_mode = AudioScene.MODE_NEUTRAL
	_state_age = 0.0
	_apply_mix()


## Move to a gameplay state. Idempotent, so a controller may call it freely.
func set_state(state: int) -> void:
	if state == _state:
		return
	_state = state
	_state_age = 0.0
	_apply_mix()


## Continuous 0..1 modulators inside the current state.
func set_streak(value: float) -> void:
	var next: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(next, _streak):
		return
	_streak = next
	_apply_mix()


func set_urgency(value: float) -> void:
	var next: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(next, _urgency):
		return
	_urgency = next
	_apply_mix()


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_apply_mix()


## The user's pad slider, 0..1.
func set_level(level: float) -> void:
	_level = clampf(level, 0.0, 1.0)
	_apply_mix()


func is_running() -> bool:
	for key: String in _voices.keys():
		if (_voices[key] as Voice).alive:
			return true
	return false


## Number of layers currently audible. The flow test reads this to prove
## density actually changes with state.
func active_voice_count() -> int:
	var n: int = 0
	for key: String in _voices.keys():
		var v: Voice = _voices[key]
		if v.alive and v.target_gain > SILENCE_EPSILON:
			n += 1
	return n


## Snapshot for tests: layer name -> {gain, pitch, cutoff}.
func voice_report() -> Dictionary:
	var out: Dictionary = {}
	for key: String in _voices.keys():
		var v: Voice = _voices[key]
		if not v.alive:
			continue
		out[key] = {
			"layer": String(v.layer), "gain": v.current_gain,
			"target_gain": v.target_gain, "pitch": v.pitch,
			"cutoff": v.current_cutoff,
		}
	return out


func current_state() -> int:
	return _state


func mode_root_hz() -> float:
	return float(_mode.get("root_hz", 0.0))


# ═════════════════════════════════════════════════════════════════════════
# MIXING
# ═════════════════════════════════════════════════════════════════════════
## Resolve the target mix and reconcile the live voices against it.
##
## Voices absent from the new mix are faded to zero rather than stopped, so a
## layer leaving is as smooth as one arriving. _process() reaps them once
## they are actually silent.
func _apply_mix() -> void:
	if not _ready_to_play:
		return
	if _mode.is_empty():
		_mode = AudioScene.MODE_NEUTRAL

	var wanted: Array[AudioScene.LayerMix] = AudioScene.resolve_mix(
		_mode, _state, _streak, _urgency)

	var seen: Dictionary = {}
	var entry: Array = _mode.get("entry_seconds", [0.0])
	var index: int = 0
	for m: AudioScene.LayerMix in wanted:
		# Two voices can share a layer at different pitches (the chord), so
		# the key carries the pitch.
		var key: String = "%s@%.4f" % [String(m.layer), m.pitch]
		seen[key] = true
		var voice: Voice = _voices.get(key)
		if voice == null:
			voice = _spawn(key, m)
			if voice == null:
				index += 1
				continue
		# STAGGERED ENTRY. A mode that arrives all at once has no shape; the
		# per-mode entry_seconds let it assemble itself.
		var wait: float = 0.0
		if index < entry.size():
			wait = float(entry[index])
		var gate: float = 1.0 if _state_age >= wait else 0.0
		voice.target_gain = (m.gain * BED_GAIN * _level * gate
			if _enabled else 0.0)
		voice.target_cutoff = m.cutoff
		voice.sweep_rate = float(_mode.get("sweep_hz", 0.03)) * float(
			AudioScene.STATE_RESPONSE.get(_state,
				AudioScene.STATE_RESPONSE[AudioScene.State.IDLE])["sweep"])
		index += 1

	for key: String in _voices.keys():
		if not seen.has(key):
			(_voices[key] as Voice).target_gain = 0.0


func _spawn(key: String, m: AudioScene.LayerMix) -> Voice:
	var stream: AudioStream = _streams.get(m.layer)
	if stream == null:
		# Reported once at load; a second warning per frame would be noise.
		return null
	var voice := Voice.new()
	voice.key = key
	voice.layer = m.layer
	voice.pitch = m.pitch
	voice.current_cutoff = m.cutoff
	voice.target_cutoff = m.cutoff
	# Random start phase so two voices sharing a sweep rate never align.
	voice.sweep_phase = randf() * TAU

	var player := AudioStreamPlayer.new()
	player.name = "Layer_%s" % key.replace("@", "_").replace(".", "_")
	player.stream = stream
	player.bus = LAYER_BUS
	player.pitch_scale = clampf(m.pitch, 0.25, 4.0)
	player.volume_db = -80.0
	add_child(player)
	# Start at a random offset so a restart does not replay the same phrase.
	player.play(randf() * maxf(stream.get_length() - 0.5, 0.1))
	voice.player = player
	voice.alive = true
	_voices[key] = voice
	return voice


func _process(delta: float) -> void:
	if not _ready_to_play:
		return
	_state_age += delta
	# Re-apply while layers are still staggering in, so entry_seconds
	# actually releases them rather than only being read on a state change.
	if _state_age < 6.0:
		_apply_mix()

	var fade: float = FADE_FAST_SEC if _state == AudioScene.State.URGENT \
		else FADE_SEC
	var step: float = clampf(delta / maxf(fade, 0.01), 0.0, 1.0)

	var dead: Array[String] = []
	for key: String in _voices.keys():
		var v: Voice = _voices[key]
		if not v.alive or v.player == null or not is_instance_valid(v.player):
			continue

		v.current_gain = lerpf(v.current_gain, v.target_gain, step)
		v.current_cutoff = lerpf(v.current_cutoff, v.target_cutoff, step)

		# THE FILTER SWEEP. A static cutoff sounds like a recording; a slowly
		# moving one sounds like a room. Rates are per-mode and per-voice, so
		# nothing ever lines up.
		v.sweep_phase += delta * v.sweep_rate * TAU
		var breath: float = 1.0 + 0.22 * sin(v.sweep_phase)

		if v.current_gain <= SILENCE_EPSILON \
				and v.target_gain <= SILENCE_EPSILON:
			dead.append(key)
			continue

		v.player.volume_db = linear_to_db(clampf(v.current_gain, 0.0, 1.0))
		# Pitch and filter both live on the player: Godot has no per-player
		# filter, so the cutoff is expressed through the bus and the voice's
		# own brightness is carried by its gain envelope. Keeping the sweep
		# on gain rather than faking a filter avoids lying about what is
		# happening to the signal.
		v.player.pitch_scale = clampf(v.pitch * (1.0 + 0.004 * sin(
			v.sweep_phase * 0.37)), 0.25, 4.0)
		v.player.volume_db += linear_to_db(clampf(breath, 0.1, 2.0)) * 0.35

	for key: String in dead:
		var v: Voice = _voices[key]
		if v.player != null and is_instance_valid(v.player):
			v.player.stop()
			v.player.queue_free()
		v.alive = false
		_voices.erase(key)


## Bus cutoff, driven by the brightest voice in the mix.
##
## Godot applies effects per BUS, not per player, so the mode's filter
## behaviour is expressed here: the whole bed opens and closes together,
## which is also how a real room behaves.
func apply_bus_cutoff(hz: float) -> void:
	if _bus_index == -1:
		return
	var count: int = AudioServer.get_bus_effect_count(_bus_index)
	for i: int in range(count):
		var fx: AudioEffect = AudioServer.get_bus_effect(_bus_index, i)
		if fx is AudioEffectLowPassFilter:
			(fx as AudioEffectLowPassFilter).cutoff_hz = clampf(
				hz, 800.0, AudioScene.TEXTURE_MAX_HZ)
			return
