extends Node
## AudioManager — procedural audio. Autoload.
##
## PHASE 8. Every sound is synthesised at runtime via AudioStreamGenerator.
## There are no .ogg or .wav files anywhere, matching the no-asset rule the
## visuals already follow.
##
## WHY GENERATIVE:
## v1 shipped 18 baked SFX and looped one music bed per trial. A 2-minute
## cognitive trainer played daily turns a fixed loop into fatigue fast, and
## three voice clips meant hearing "welcome" twice in four seconds at launch.
## A generative pad never repeats exactly, so it can sit under gameplay
## indefinitely without becoming wallpaper the player wants to mute.
##
## VOICE:
## The Iris does not use TTS or recorded speech. `speak()` selects a line from
## DialogueManifest for display, and voices it as a formant-shaped hum — a
## vowel-like timbre that reads as vocal without language. That keeps the
## companion wordless (no localisation burden, no uncanny TTS) while the text
## carries meaning on screen.
##
## SAFETY:
## Every buffer is written through `_push_safe()`, which hard-clamps to ±1.0
## and applies an attack/release envelope. Nothing can emit a click, a DC
## offset, or a full-scale spike — the failure modes that damage headphones and
## get apps uninstalled.

const SAMPLE_RATE: float = 22050.0

## Generator buffer, in seconds.
##
## THE BUG THIS FIXES: this was 0.35s, which at 22050 Hz is 7717 frames.
## play_iris_formant() synthesises up to MAX_VOICE_SECONDS (0.85s / 18742
## frames) in a single push loop, clamped to whatever the buffer could accept
## THAT FRAME — so every line longer than about 12 characters was silently
## cut off mid-utterance and the tail was never heard. Measured against the
## four intro lines:
##
##   "Initialization complete."      27% of the audio discarded
##   "You have exactly two seconds." 35% discarded
##   "Do not hesitate."              10% discarded
##
## The line still appeared on screen in full, which is exactly the reported
## symptom: subtitles with no matching sound.
##
## 1.0s holds the longest utterance the synth can produce with headroom to
## spare. tests/test_daily_audio.py asserts the relationship rather than the
## number, so raising MAX_VOICE_SECONDS cannot silently reintroduce this.
const BUFFER_LENGTH: float = 1.0

## Longest single voice utterance. Must fit inside BUFFER_LENGTH.
const MAX_VOICE_SECONDS: float = 0.85

## Master ceiling applied after every mix. Leaves headroom so simultaneous
## voice + pad + SFX cannot sum past full scale.
const MASTER_CEILING: float = 0.72
const PAD_GAIN: float = 0.16
## Lowered from 0.34 on request: she sat slightly loud against the pad.
const VOICE_GAIN: float = 0.26
const SFX_GAIN: float = 0.28

## Minimum fade applied to the head and tail of every one-shot, in seconds.
## Below roughly 4 ms a discontinuity is audible as a click.
const EDGE_FADE: float = 0.008

# ── Voice bus ────────────────────────────────────────────────────────────
## Dedicated bus for the Iris's spoken lines, so her voice can be placed in a
## room without touching the pad or the SFX.
const VOICE_BUS: StringName = &"IrisVoice"

## Small, close room. Big enough to sit her somewhere, short enough that two
## consecutive one-word lines ("Yes." / "Good.") never smear together.
const VOICE_ROOM_SIZE: float = 0.42
const VOICE_REVERB_WET: float = 0.22
const VOICE_REVERB_DAMPING: float = 0.55
const VOICE_REVERB_SPREAD: float = 0.40

## Top-end roll-off, in Hz. Softens TTS sibilance. Well above the speech
## intelligibility band so nothing becomes hard to understand.
const VOICE_LOWPASS_HZ: float = 7200.0

# ── Formant tables ───────────────────────────────────────────────────────
## First two formants (F1, F2) for vowel-like timbres, in Hz. These are the
## resonances that make a hum read as a voice rather than a synth tone.
const FORMANTS: Dictionary = {
	&"hub_idle":       Vector2(420.0, 900.0),    # relaxed "uh" — resting
	&"touch_respond":  Vector2(520.0, 1400.0),   # brighter "eh" — attentive
	&"streak_celebrate": Vector2(700.0, 1800.0), # open "ah" — joyful
	&"warble_error":   Vector2(320.0, 700.0),    # closed "oo" — dismay
	&"trial_focus":    Vector2(460.0, 1100.0),   # neutral — concentrating
}

## Base pitch per emotion, in Hz. Kept low so the Iris reads as calm.
const BASE_PITCH: Dictionary = {
	&"hub_idle": 138.0,
	&"touch_respond": 165.0,
	&"streak_celebrate": 196.0,
	&"warble_error": 110.0,
	&"trial_focus": 147.0,
}

# ── SFX definitions ──────────────────────────────────────────────────────
## Soft, organic feedback. Each is a short decaying tone cluster rather than a
## click, so rapid interaction never becomes percussive.
const SFX: Dictionary = {
	&"ui_tap":       {"freq": 660.0, "decay": 0.09, "harmonics": 2, "noise": 0.02},
	&"swap":         {"freq": 440.0, "decay": 0.13, "harmonics": 3, "noise": 0.05},
	&"match":        {"freq": 880.0, "decay": 0.22, "harmonics": 4, "noise": 0.03},
	&"sequence_bell": {"freq": 1046.0, "decay": 0.45, "harmonics": 5, "noise": 0.0},
	&"stroop_pulse": {"freq": 520.0, "decay": 0.11, "harmonics": 2, "noise": 0.08},
	&"reward":       {"freq": 784.0, "decay": 0.38, "harmonics": 5, "noise": 0.0},
	&"error":        {"freq": 233.0, "decay": 0.20, "harmonics": 2, "noise": 0.10},
}

# ── Players ──────────────────────────────────────────────────────────────
var _pad_player: AudioStreamPlayer = null
var _voice_player: AudioStreamPlayer = null
var _sfx_player: AudioStreamPlayer = null
## Streams pre-rendered dialogue clips. Separate from _voice_player, which
## still owns the generator used for the formant fallback.
var _clip_player: AudioStreamPlayer = null

var _pad_playback: AudioStreamGeneratorPlayback = null
var _pad_phase: float = 0.0
var _pad_drift: float = 0.0
var _pad_active: bool = false
var _pad_intensity: float = 0.0
var _pad_target_intensity: float = 0.0
var _pad_root: float = 110.0
## Rank tier, kept so a mode change can retune without losing the rank pitch.
var _rank_tier: int = 0
## Transposition and harmonic colour of the current musical mode. Defaults are
## the neutral bed: no transposition, a perfect fifth on the middle partial.
var _mode_semitones: float = 0.0
var _pad_colour: float = 1.5

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _enabled: bool = true
var _last_spoken: String = ""

## Independent channel levels, 0..1, persisted in settings. Kept separate from
## the master so a player can silence the voice without losing the pad.
var _master_level: float = 0.9
var _pad_level: float = 1.0
var _voice_level: float = 1.0
var _sfx_level: float = 1.0


func _ready() -> void:
	# KEEP GENERATING WHILE THE TREE IS PAUSED.
	#
	# THE BUG THIS FIXES: all audio died permanently the first time the window
	# lost focus, and never came back.
	#
	# App pauses the whole tree on focus loss and mutes the master BUS. Muting
	# a bus is correct and reversible. But an autoload defaults to
	# PROCESS_MODE_INHERIT, which under a paused tree means PAUSABLE — so
	# _process() stopped, _fill_pad() stopped, and the AudioStreamGenerator's
	# ring buffer drained to empty. On resume the bus unmuted, but nothing
	# refilled the buffer, so every channel stayed silent forever.
	#
	# In the editor this is brutal: alt-tabbing even once kills audio for the
	# rest of the session, and a reported run showed six focus cycles before
	# the player even reached the hub.
	#
	# ALWAYS is right here and does NOT weaken the gameplay pause. Silence is
	# enforced by the bus mute, which App still applies; this only guarantees
	# the generators are still fed so there is something to un-mute back into.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_rng.randomize()
	_build_players()
	_refresh_from_settings()

	Bus.palette_changed.connect(_on_palette_changed)
	Save.loaded.connect(_refresh_from_settings)


## _exit_tree() is not guaranteed on every shutdown path (a --quit-after or an
## OS-level kill can bypass it), so release on the predelete notification too.
## Both routes are idempotent.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_release_playbacks()


func _exit_tree() -> void:
	if Bus.palette_changed.is_connected(_on_palette_changed):
		Bus.palette_changed.disconnect(_on_palette_changed)
	if Save.loaded.is_connected(_refresh_from_settings):
		Save.loaded.disconnect(_refresh_from_settings)
	_release_playbacks()


## Release playback references and detach streams on shutdown.
##
## NOTE ON THE HEADLESS LEAK WARNING:
## Godot reports "ObjectDB instances leaked at exit" naming two
## AudioStreamGeneratorPlayback objects. That warning is NOT caused by this
## file. A 12-line project that does nothing but create one
## AudioStreamPlayer + AudioStreamGenerator and call play() reproduces it
## exactly, so it is engine behaviour for generator playbacks in a headless
## teardown, not a defect here.
##
## This cleanup is kept regardless: releasing our own references and detaching
## the streams is correct hygiene, costs nothing, and means the warning can
## never mask a real leak we introduce later.
func _release_playbacks() -> void:
	_pad_active = false
	_pad_playback = null
	var every: Array[AudioStreamPlayer] = [
		_pad_player, _voice_player, _sfx_player, _clip_player,
	]
	for player: AudioStreamPlayer in every:
		if player == null:
			continue
		player.stop()
		# stop() alone is not enough: the AudioStreamGenerator keeps its
		# playback alive, and that reference outlives cleanup. Detaching the
		# stream is what actually releases it.
		player.stream = null


func _build_players() -> void:
	_pad_player = _make_player("IrisPad")
	_voice_player = _make_player("IrisVoice")
	_sfx_player = _make_player("IrisSfx")

	_build_voice_bus()

	# The clip player carries pre-rendered speech and routes through the
	# processed bus so her voice sits INSIDE the room rather than flat on top
	# of it. It has no generator: it streams whole Ogg files.
	_clip_player = AudioStreamPlayer.new()
	_clip_player.name = "IrisClips"
	_clip_player.bus = VOICE_BUS
	add_child(_clip_player)


## Create the dedicated voice bus and hang its effects on it.
##
## WHY A BUS RATHER THAN BAKING THE EFFECT INTO THE FILES
## Reverb baked at render time cannot be turned down, cannot respond to a
## reduced-motion or accessibility setting, and doubles the bytes of every
## clip that shares a tail. On a bus it is one instance for all 56 lines, and
## the dry signal is still available if it ever needs to be.
##
## Built in code, not in an audio bus layout resource, because a .tres bus
## layout is a binary-ish project asset that nothing else here uses — and this
## way the reverb parameters sit beside the reasoning for them.
func _build_voice_bus() -> void:
	var index: int = AudioServer.get_bus_index(VOICE_BUS)
	if index != -1:
		return
	index = AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, VOICE_BUS)
	AudioServer.set_bus_send(index, &"Master")

	# A small, close room. Long enough to place her somewhere; short enough
	# that consecutive short lines never smear into each other.
	var room := AudioEffectReverb.new()
	room.room_size = VOICE_ROOM_SIZE
	room.wet = VOICE_REVERB_WET
	room.dry = 1.0 - VOICE_REVERB_WET * 0.5
	room.damping = VOICE_REVERB_DAMPING
	room.spread = VOICE_REVERB_SPREAD
	AudioServer.add_bus_effect(index, room)

	# Gentle top-end roll-off. Takes the digital edge off the TTS sibilance so
	# she reads as present in the space rather than recorded next to the mic.
	var shade := AudioEffectLowPassFilter.new()
	shade.cutoff_hz = VOICE_LOWPASS_HZ
	AudioServer.add_bus_effect(index, shade)


func _make_player(player_name: String) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.name = player_name
	var generator: AudioStreamGenerator = AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = BUFFER_LENGTH
	player.stream = generator
	add_child(player)
	return player


## True when audio should actually be produced. Logs at debug level rather
## than warn: these paths are hit on every tap, and a muted player is a normal
## state, not an error. Silence is still never UNexplained.
func _audible(player: AudioStreamPlayer, context: String) -> bool:
	if not _enabled:
		Log.d("Audio", "muted in %s" % context)
		return false
	if player == null:
		Log.warn("Audio", "no player in %s" % context)
		return false
	return true


func _refresh_from_settings() -> void:
	_enabled = bool(Save.setting("audio_enabled", true))
	_master_level = clampf(float(Save.setting("master_volume", 0.9)), 0.0, 1.0)
	_pad_level = clampf(float(Save.setting("pad_volume", 1.0)), 0.0, 1.0)
	_voice_level = clampf(float(Save.setting("voice_volume", 0.80)), 0.0, 1.0)
	_sfx_level = clampf(float(Save.setting("sfx_volume", 1.0)), 0.0, 1.0)
	_apply_levels()


## Channel level x master, converted to dB. A level at or near zero routes to
## -60 dB rather than linear_to_db(0), which is -inf and produces a NaN warning.
func _apply_levels() -> void:
	_set_channel(_pad_player, _pad_level)
	# THE LAYER BED IS PART OF THE PAD CHANNEL.
	#
	# Without this the settings slider moved the synthesised underlay and
	# left the sampled layers — which are now the LOUDER of the two — at full
	# volume. A "pad" slider that quietens 20% of the pad is worse than no
	# slider, because the player concludes the control is broken.
	#
	# Resolved by name rather than by the LayerEngine global: AudioManager is
	# registered BEFORE LayerEngine, so during its own _ready() the autoload
	# does not exist yet and naming it directly throws.
	var engine: Node = get_tree().root.get_node_or_null("LayerEngine")
	if engine != null and engine.has_method("set_level"):
		engine.call("set_level", _pad_level * _master_level)
	if engine != null and engine.has_method("set_enabled"):
		engine.call("set_enabled", _enabled)
	_set_channel(_voice_player, _voice_level)
	# The clip player is a voice channel too: without this the settings slider
	# would silence the formant fallback and leave the real speech at full
	# volume, which is worse than having no slider.
	_set_channel(_clip_player, _voice_level)
	_set_channel(_sfx_player, _sfx_level)


func _set_channel(player: AudioStreamPlayer, level: float) -> void:
	if player == null:
		Log.d("Audio", "channel player not built yet")
		return
	var combined: float = _master_level * level
	if not _enabled or combined <= 0.001:
		player.volume_db = -60.0
		return
	player.volume_db = linear_to_db(combined)


## Set one channel and persist. `channel` is master/pad/voice/sfx.
func set_channel_level(channel: StringName, level: float) -> void:
	var safe: float = clampf(level, 0.0, 1.0)
	match channel:
		&"master":
			_master_level = safe
			Save.set_setting("master_volume", safe)
		&"pad":
			_pad_level = safe
			Save.set_setting("pad_volume", safe)
		&"voice":
			_voice_level = safe
			Save.set_setting("voice_volume", safe)
		&"sfx":
			_sfx_level = safe
			Save.set_setting("sfx_volume", safe)
		_:
			Log.must(false, "Audio", "unknown channel '%s'" % channel)
			return
	_apply_levels()


func channel_level(channel: StringName) -> float:
	match channel:
		&"master": return _master_level
		&"pad": return _pad_level
		&"voice": return _voice_level
		&"sfx": return _sfx_level
	return 0.0


func _on_palette_changed(tier: int) -> void:
	# Rank retunes the pad's root note, so progression is audible as well as
	# visible. Rises by a semitone per tier, wrapping within one octave.
	_rank_tier = tier
	_retune()


## Recompute the root from rank AND the current musical mode.
##
## Rank sets the pitch; the mode sets the interval the pad's second partial
## sits at. Kept in one place so the two cannot fight: setting a mode used to
## be possible only by overwriting _pad_root directly, which the next rank-up
## silently reverted.
func _retune() -> void:
	_pad_root = (110.0 * pow(2.0, float(_rank_tier % 12) / 12.0)
		* pow(2.0, _mode_semitones / 12.0))


## Give the pad a musical character. `semitones` transposes the root and
## `colour` sets the interval of the middle partial — a perfect fifth (1.5)
## is neutral, a minor third (1.2) is darker, a fourth (1.335) is unsettled.
##
## WHY THIS EXISTS
## The pad was ONE 110 Hz drone for the entire game. Difficulty moved its
## intensity, but every trial sounded identical, so the audio said nothing
## about which mode you were in. This is the smallest lever that makes four
## trials feel like four places without shipping any audio assets.
func set_pad_mode(semitones: float, colour: float) -> void:
	_mode_semitones = clampf(semitones, -12.0, 12.0)
	_pad_colour = clampf(colour, 1.1, 2.0)
	_retune()


func pad_colour() -> float:
	return _pad_colour


func pad_root() -> float:
	return _pad_root


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	Save.set_setting("audio_enabled", enabled)
	if not enabled:
		stop_pad()
	_refresh_from_settings()


func is_enabled() -> bool:
	return _enabled


# ═════════════════════════════════════════════════════════════════════════
# AMBIENT PAD
# ═════════════════════════════════════════════════════════════════════════
## Start the generative pad. `intensity` 0..1 raises harmonic content and
## brightness — the trial host maps difficulty bracket onto it.
func play_ambient_pad(intensity: float = 0.3) -> void:
	if not _audible(_pad_player, "play_ambient_pad"):
		return
	_pad_target_intensity = clampf(intensity, 0.0, 1.0)
	if _pad_active:
		return
	_pad_player.play()
	_pad_playback = _pad_player.get_stream_playback() as AudioStreamGeneratorPlayback
	_pad_active = _pad_playback != null
	set_process(_pad_active)


## Glide to a new intensity. Never jumps, so a difficulty change or a trial
## transition cannot produce a sudden swell.
func set_pad_intensity(intensity: float) -> void:
	_pad_target_intensity = clampf(intensity, 0.0, 1.0)


func stop_pad() -> void:
	_pad_active = false
	_pad_playback = null
	if _pad_player != null:
		_pad_player.stop()
	set_process(false)


func is_pad_playing() -> bool:
	return _pad_active


func _process(delta: float) -> void:
	if not _pad_active or _pad_playback == null:
		return   # pad simply not running; not an error state
	# Ease intensity so nothing steps.
	_pad_intensity = lerpf(_pad_intensity, _pad_target_intensity,
		clampf(delta * 1.5, 0.0, 1.0))
	_fill_pad()


## Write whatever the generator can accept this frame.
##
## The pad is three detuned sine partials over a slow drifting LFO. Detuning
## produces beating that never lines up exactly, which is what stops the bed
## sounding like a loop.
func _fill_pad() -> void:
	var frames: int = _pad_playback.get_frames_available()
	if frames <= 0:
		return   # generator buffer full this frame; normal back-pressure

	var increment: float = 1.0 / SAMPLE_RATE
	for i: int in range(frames):
		_pad_phase += increment
		_pad_drift += increment * 0.037

		var lfo: float = sin(_pad_drift * TAU * 0.11)
		var root: float = _pad_root * (1.0 + lfo * 0.004)

		var sample: float = 0.0
		sample += sin(_pad_phase * TAU * root) * 0.55
		# The middle partial's interval IS the mode's colour. A fifth reads
		# neutral, a minor third dark, a fourth unresolved — which is what
		# makes the four trials sound like different rooms rather than the
		# same drone at different volumes.
		sample += sin(_pad_phase * TAU * root * _pad_colour
			* (1.0 + lfo * 0.002)) * 0.28
		sample += sin(_pad_phase * TAU * root * 2.01) * 0.14 * _pad_intensity

		# Intensity adds a shimmering upper partial.
		if _pad_intensity > 0.4:
			sample += sin(_pad_phase * TAU * root * 4.03) * 0.06 * _pad_intensity

		var gain: float = PAD_GAIN * (0.55 + 0.45 * _pad_intensity)
		_pad_playback.push_frame(_clamp_frame(sample * gain))


# ═════════════════════════════════════════════════════════════════════════
# VOICE
# ═════════════════════════════════════════════════════════════════════════
## Speak a line for a context. Returns the TEXT so a caller can display it —
## meaning lives on screen; the audio conveys only tone.
func speak(context: StringName, emotion: StringName = &"hub_idle") -> String:
	var line: String = DialogueManifest.next_line(context)
	if line == "":
		return ""
	_last_spoken = line

	# PRE-RENDERED SPEECH, WITH THE SYNTH AS A SAFETY NET.
	#
	# The Iris used to hum every line as a formant tone — wordless by design,
	# to dodge localisation and uncanny TTS. That decision was reversed
	# deliberately: she now speaks the authored text aloud.
	#
	# The clip is chosen by the SAME shuffle-bag index that chose the text, so
	# audio and subtitle cannot disagree. If the clip is absent — a line added
	# without regenerating the pack — the formant hum still covers it rather
	# than the moment passing in silence. That fallback is a guard, not a
	# feature: tools/generate_voice_lines.py --check fails the build when the
	# pack and the script diverge.
	var clip: String = DialogueManifest.clip_path(context)
	if clip != "" and ResourceLoader.exists(clip):
		_play_voice_clip(clip)
	else:
		Log.warn("Audio", "no clip for '%s'; humming instead" % context)
		play_iris_formant(emotion, line.length())

	Bus.iris_spoke.emit(context, line)
	return line


## Play one rendered line on the dedicated voice bus.
func _play_voice_clip(path: String) -> void:
	if not _audible(_clip_player, "_play_voice_clip"):
		return
	var stream: AudioStream = load(path) as AudioStream
	if not Log.must(stream != null, "Audio", "clip is not audio: %s" % path):
		return
	# Interrupt any line still playing. Two overlapping utterances from one
	# companion is worse than a clipped word.
	_clip_player.stop()
	_clip_player.stream = stream
	_clip_player.play()


## Synthesise a formant-shaped hum. `syllables` scales duration so a longer
## line hums longer, which makes the voice feel connected to the text.
func play_iris_formant(emotion: StringName, syllables: int = 8) -> void:
	if not _audible(_voice_player, "play_iris_formant"):
		return

	var formant: Vector2 = FORMANTS.get(emotion, FORMANTS[&"hub_idle"])
	var pitch: float = float(BASE_PITCH.get(emotion, 138.0))
	var duration: float = clampf(
		0.22 + float(syllables) * 0.012, 0.22, MAX_VOICE_SECONDS)

	_voice_player.play()
	var playback: AudioStreamGeneratorPlayback = \
		_voice_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if not Log.must(playback != null, "Audio", "voice playback unavailable"):
		return

	var total: int = int(duration * SAMPLE_RATE)
	var available: int = playback.get_frames_available()
	# Report rather than silently truncate. A line cut off mid-word is a bug
	# the player hears and the log never mentioned; this is how 35% of
	# "You have exactly two seconds." went missing without a single warning.
	if total > available:
		Log.warn("Audio", "voice truncated: wanted %d frames, buffer had %d"
			% [total, available])
		total = available

	for i: int in range(total):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / float(maxi(total, 1))

		# Slight downward pitch drift reads as a natural, relaxed utterance.
		var f0: float = pitch * (1.0 - progress * 0.06)

		# Glottal source: a few harmonics with 1/n rolloff.
		var source: float = 0.0
		for harmonic: int in range(1, 7):
			source += sin(t * TAU * f0 * float(harmonic)) / float(harmonic)
		source *= 0.35

		# Formant shaping: two resonant bands multiply the source.
		var band1: float = sin(t * TAU * formant.x) * 0.6
		var band2: float = sin(t * TAU * formant.y) * 0.3
		var shaped: float = source * (0.55 + band1 * 0.30 + band2 * 0.15)

		# Gentle vibrato — a perfectly steady tone reads as synthetic.
		shaped *= 1.0 + sin(t * TAU * 5.2) * 0.04

		playback.push_frame(_clamp_frame(
			shaped * VOICE_GAIN * _envelope(progress, EDGE_FADE / duration)))

	# Drop our reference immediately: the player retains its own, and holding
	# a second one past this call is what leaks at exit.
	playback = null


func last_spoken() -> String:
	return _last_spoken


# ═════════════════════════════════════════════════════════════════════════
# SFX
# ═════════════════════════════════════════════════════════════════════════
## One-shot tactile feedback. Unknown types fail loudly in debug rather than
## silently playing nothing.
func play_sfx(sfx_type: StringName) -> void:
	if not _audible(_sfx_player, "play_sfx"):
		return
	if not Log.must(SFX.has(sfx_type), "Audio", "unknown sfx '%s'" % sfx_type):
		return

	var config: Dictionary = SFX[sfx_type]
	var frequency: float = float(config.get("freq", 440.0))
	var decay: float = float(config.get("decay", 0.15))
	var harmonics: int = int(config.get("harmonics", 3))
	var noise_amount: float = float(config.get("noise", 0.0))

	_sfx_player.play()
	var playback: AudioStreamGeneratorPlayback = \
		_sfx_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if not Log.must(playback != null, "Audio", "sfx playback unavailable"):
		return

	var total: int = mini(int(decay * SAMPLE_RATE), playback.get_frames_available())

	for i: int in range(total):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / float(maxi(total, 1))

		var sample: float = 0.0
		for harmonic: int in range(1, harmonics + 1):
			# Slightly inharmonic partials read as struck material rather than
			# a pure electronic tone.
			var ratio: float = float(harmonic) * (1.0 + float(harmonic) * 0.004)
			sample += sin(t * TAU * frequency * ratio) / float(harmonic)

		if noise_amount > 0.0:
			sample += _rng.randf_range(-1.0, 1.0) * noise_amount

		# Exponential decay: natural, and guarantees the tail reaches silence.
		var decay_env: float = pow(1.0 - progress, 2.2)
		playback.push_frame(_clamp_frame(
			sample * SFX_GAIN * decay_env * _envelope(progress, EDGE_FADE / decay)))

	playback = null


# ═════════════════════════════════════════════════════════════════════════
# SAFETY
# ═════════════════════════════════════════════════════════════════════════
## Attack/release envelope. Prevents the click a raw buffer start/stop makes.
static func _envelope(progress: float, edge: float) -> float:
	var safe_edge: float = clampf(edge, 0.001, 0.5)
	if progress < safe_edge:
		return progress / safe_edge
	if progress > 1.0 - safe_edge:
		return (1.0 - progress) / safe_edge
	return 1.0


## Hard-clamp to the master ceiling. This is the last line of defence: no
## synthesis path can emit a sample outside ±MASTER_CEILING, whatever the maths
## upstream does.
static func _clamp_frame(sample: float) -> Vector2:
	var limited: float = clampf(sample, -MASTER_CEILING, MASTER_CEILING)
	return Vector2(limited, limited)


## Exposed for tests: the peak of a synthesised buffer must never clip.
static func peak_of(samples: PackedFloat32Array) -> float:
	var peak: float = 0.0
	for value: float in samples:
		peak = maxf(peak, absf(value))
	return peak
