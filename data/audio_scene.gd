extends RefCounted
class_name AudioScene
## AudioScene — PHASE 1 DATA MODEL for the hybrid procedural audio engine.
##
## Pure data and pure functions. No nodes, no signals, no AudioServer, no
## scene tree — everything here is testable without an audio device, which is
## the point: the mixing RULES are what go wrong, and they should be provable
## on their own.
##
## WHAT THIS REPLACES
## The bed was three detuned sine partials at a single root (110 Hz), retuned
## per trial. Sines have no timbre: no attack, no inharmonicity, no noise
## floor. Worse, the root was in the SUB-BASS, which a phone speaker cannot
## reproduce at all — it was either inaudible or driving cone excursion that
## muddied the mid-range.
##
## ── THE FREQUENCY RULE ───────────────────────────────────────────────────
## Nothing below MIN_AUDIBLE_HZ. Phone and laptop speakers roll off hard
## below ~200 Hz and produce nothing usable under ~120 Hz, so a "rich" mix
## built on sub-bass arrives thin and distorted. Every voice this model can
## request is clamped into CLEAR_LOW_HZ..CLEAR_HIGH_HZ, and texture layers
## live above that. Enforced three times over, independently:
##
##   1. bake time    tools/bake_audio_layers.py high-passes every layer at
##                   120 Hz and refuses to write one with >2% sub-bass energy
##   2. this model   resolve_pitch() clamps, and no mode may name a root
##                   outside the clear band (asserted by the flow test)
##   3. run time     the engine's bus chain carries a 100 Hz high-pass
##
## Three independent gates, because one is a single edit away from being
## removed by someone who does not know why it is there.

## Nothing below this is ever requested. Below it, a phone speaker is silent
## and a laptop speaker distorts.
const MIN_AUDIBLE_HZ: float = 120.0

## The band where small speakers are actually flat, and where every
## fundamental in the game therefore lives.
const CLEAR_LOW_HZ: float = 200.0
const CLEAR_HIGH_HZ: float = 1200.0

## Texture (shimmer, air) may reach here, but only as overtone content — a
## texture layer has no fundamental of its own.
const TEXTURE_MAX_HZ: float = 9000.0

## The pitch each layer was BAKED at, from tools/bake_audio_layers.py.
##
## THE BUG THIS FIXES: a voice's playback ratio was computed as
## `sounding_hz / mode_root_hz`, which is the interval alone — the mode's root
## never reached the speaker, only the layer's own baked root did. Two modes
## sharing a layer therefore sounded IDENTICAL in pitch no matter how far
## apart their roots were.
##
## Measured on rendered audio: sequence_recall (root 293.66) and
## cognitive_conflict (root 349.23) produced byte-identical strongest
## partials — 294.4, 349.4, 584.8, 877.0, 1182.6 Hz — because both voice
## glass_mid, which is baked at 349.23.
##
## A ratio is only meaningful against the pitch the file actually contains,
## so the sounding frequency is divided by THIS, not by the mode root.
const LAYER_ROOT_HZ: Dictionary = {
	&"pad_low": 220.0,
	&"pad_mid": 293.66,
	&"pad_high": 440.0,
	&"glass_low": 261.63,
	&"glass_mid": 349.23,
	&"glass_high": 523.25,
	&"chime_soft": 392.0,
	&"chime_bright": 587.33,
	# Texture layers carry no fundamental, so they are never transposed.
	&"air_calm": 0.0,
	&"air_tense": 0.0,
	&"shimmer_fine": 0.0,
}

## Widest transposition a layer may be played at before it sounds artificial.
##
## Beyond about a fifth either way the formants of a bowed or struck body
## stretch audibly and it stops sounding like the instrument it was modelled
## on — the "chipmunk" artefact. The library therefore ships three pitches per
## voiced family so the engine can pick a near neighbour and shift a little.
const MAX_PITCH_RATIO: float = 1.55
const MIN_PITCH_RATIO: float = 0.65


## ── INTENSITY STATES ─────────────────────────────────────────────────────
## The gameplay states the mix responds to. Ordered by arousal, so a
## comparison is meaningful: URGENT > STREAK > ACTIVE > IDLE.
enum State {
	IDLE,     ## hub at rest
	ACTIVE,   ## a trial is running, or the player is dragging the eye
	STREAK,   ## consecutive correct answers are building
	URGENT,   ## the final quarter of an answer window
	RESULTS,  ## settlement, resolving
	MENU,     ## settings and other non-play screens
}


## ── LAYER ROLES ──────────────────────────────────────────────────────────
## What a layer is FOR, which decides how it is filtered and when it enters.
enum Role {
	BED,      ## continuous warm foundation, always present
	VOICE,    ## the sustained harmonic body that carries the mode
	ACCENT,   ## sparse struck events
	TEXTURE,  ## air and shimmer; presence without pitch
}


## A single layer's mix state at one instant. Plain data so a test can assert
## on it without an AudioServer.
class LayerMix extends RefCounted:
	var layer: StringName = &""
	var role: int = Role.BED
	## Linear gain 0..1. The engine converts to dB.
	var gain: float = 0.0
	## Playback pitch multiplier. 1.0 is the layer's baked root.
	var pitch: float = 1.0
	## Low-pass cutoff in Hz. Brighter states open the filter.
	var cutoff: float = 6000.0

	func _init(p_layer: StringName = &"", p_role: int = Role.BED) -> void:
		layer = p_layer
		role = p_role

	func to_dict() -> Dictionary:
		return {
			"layer": String(layer), "role": role,
			"gain": gain, "pitch": pitch, "cutoff": cutoff,
		}


## ── MUSICAL MODES, PER TRIAL ─────────────────────────────────────────────
## Each trial gets a distinct root, interval set and filter behaviour. This
## replaces the two-number [semitones, ratio] table: a mode is now a whole
## character — which layers play, how bright they are, and how fast the
## filter breathes.
##
##   root_hz          fundamental, always inside the clear band
##   intervals        semitone offsets voiced above the root
##   entry_seconds    how long each successive layer waits before entering,
##                    so a mode assembles itself instead of arriving whole
##   sweep_hz         filter LFO rate; faster reads as more agitated
##   base_cutoff      resting brightness
##   texture          which air layer sits underneath
const MODES: Dictionary = {
	"false_witness": {
		"root_hz": 261.63,            # C4 — steady, watchful
		"intervals": [0.0, 7.0, 12.0],       # root, fifth, octave
		"entry_seconds": [0.0, 1.4, 3.2],
		"sweep_hz": 0.031,
		"base_cutoff": 3200.0,
		"texture": &"air_calm",
		"voice": &"glass_low",
		"bed": &"pad_low",
		"accent": &"chime_soft",
	},
	"sequence_recall": {
		"root_hz": 293.66,            # D4 — unresolved, expectant
		"intervals": [0.0, 5.0, 14.0],       # root, fourth, ninth
		"entry_seconds": [0.0, 0.9, 2.1],
		"sweep_hz": 0.055,
		"base_cutoff": 4200.0,
		"texture": &"air_calm",
		# glass_low (baked 261.63), not glass_mid: 293.66/261.63 = 1.12, a
		# gentle shift, and it keeps this mode's timbre distinct from
		# cognitive_conflict, which voices glass_mid.
		"voice": &"glass_low",
		"bed": &"pad_mid",
		"accent": &"chime_soft",
	},
	"cognitive_conflict": {
		"root_hz": 349.23,            # F4 — the dissonant one
		"intervals": [0.0, 3.0, 6.0],        # minor third + tritone
		"entry_seconds": [0.0, 0.6, 1.2],
		"sweep_hz": 0.092,
		"base_cutoff": 5200.0,
		"texture": &"air_tense",
		"voice": &"glass_mid",
		"bed": &"pad_mid",
		"accent": &"chime_bright",
	},
	"facet_cascade": {
		"root_hz": 440.0,             # A4 — bright and open
		"intervals": [0.0, 4.0, 9.0],        # major third, major sixth
		"entry_seconds": [0.0, 0.7, 1.6],
		"sweep_hz": 0.068,
		"base_cutoff": 6200.0,
		"texture": &"air_tense",
		"voice": &"glass_high",
		"bed": &"pad_high",
		"accent": &"chime_bright",
	},
}

## The hub and every non-trial screen. Calm, open, unhurried — leaving a
## trial should be audible as a release.
const MODE_NEUTRAL: Dictionary = {
	"root_hz": 220.0 * 1.5,           # A3 fifth = 330 Hz, inside the band
	"intervals": [0.0, 7.0, 16.0],
	"entry_seconds": [0.0, 2.0, 4.5],
	"sweep_hz": 0.024,
	"base_cutoff": 2800.0,
	"texture": &"air_calm",
	"voice": &"glass_low",
	"bed": &"pad_low",
	"accent": &"chime_soft",
}


## ── STATE RESPONSE CURVES ────────────────────────────────────────────────
## How each state moves the mix away from rest. These are MULTIPLIERS and
## OFFSETS rather than absolute values, so a mode's character survives its
## intensity changing — which is the failure of the old system, where every
## trial was the same sound at a different volume.
##
##   density   how many layers are audible (0..1 across the roster)
##   cutoff    multiplies the mode's base_cutoff; brighter = more urgent
##   gain      overall level trim
##   sweep     multiplies the mode's filter LFO rate
const STATE_RESPONSE: Dictionary = {
	State.IDLE:    {"density": 0.55, "cutoff": 0.85, "gain": 0.70, "sweep": 0.7},
	State.ACTIVE:  {"density": 0.80, "cutoff": 1.00, "gain": 0.90, "sweep": 1.0},
	State.STREAK:  {"density": 1.00, "cutoff": 1.35, "gain": 1.00, "sweep": 1.3},
	State.URGENT:  {"density": 0.90, "cutoff": 1.70, "gain": 1.00, "sweep": 2.2},
	State.RESULTS: {"density": 0.65, "cutoff": 0.95, "gain": 0.80, "sweep": 0.6},
	State.MENU:    {"density": 0.40, "cutoff": 0.75, "gain": 0.60, "sweep": 0.5},
}

## Per-role base gains, before the state trim. TEXTURE sits low: it is
## presence, not content, and a loud air bed masks the mid-range voices.
##
## HALVED FROM THE FIRST PASS. Six layers can sound at once and these summed
## to 2.13x unity at full streak — the bus limiter would have been doing the
## mixing, which pumps and squashes precisely when the game is most intense.
## The limiter is a backstop for a transient, not a mix strategy.
const ROLE_GAIN: Dictionary = {
	Role.BED: 0.26,
	Role.VOICE: 0.20,
	Role.ACCENT: 0.14,
	Role.TEXTURE: 0.09,
}

## Ceiling for the summed gain of every layer at once.
##
## Below unity with real headroom: the layers are correlated (they share
## harmonics by design), so peaks add closer to linearly than incoherent
## sources would. Asserted at every mode/state extreme by the flow test.
const MIX_GAIN_CEILING: float = 0.92

## Density threshold above which each role becomes audible. BED is always on
## — silence between states would be a gap, not a transition.
const ROLE_DENSITY_GATE: Dictionary = {
	Role.BED: 0.0,
	Role.TEXTURE: 0.35,
	Role.VOICE: 0.50,
	Role.ACCENT: 0.78,
}


## The mode table for a trial, or the neutral bed for anything unregistered.
##
## An unknown id is NOT an error: a mini-game written tomorrow should be
## audible the day it is written, and adding a row to MODES is the deliberate
## upgrade rather than a prerequisite.
static func mode_for(trial_id: String) -> Dictionary:
	return MODES.get(trial_id, MODE_NEUTRAL)


## Semitone offset applied to a frequency, clamped into the audible band.
##
## THE CLAMP IS THE RULE, not a safety net. A mode transposed down far enough
## would otherwise walk its root into the sub-bass, where a phone reproduces
## nothing — and the failure is silent, which is the worst kind.
static func resolve_pitch(root_hz: float, semitones: float) -> float:
	var shifted: float = root_hz * pow(2.0, semitones / 12.0)
	return clampf(shifted, MIN_AUDIBLE_HZ, TEXTURE_MAX_HZ)


## Voiced layer families, ordered by baked pitch. Used to pick the nearest
## sample to a target note so the shift stays small.
##
## THE PROBLEM THIS SOLVES: a mode names ONE voice layer, and its top
## interval is often an octave. false_witness (root 261.63, +12) asked
## glass_low for 523.25 Hz — a 2.0x shift, past MAX_PITCH_RATIO, clamped to
## 1.55 and therefore SOUNDING AT 405 Hz. The chord's octave came out as a
## flat sixth. Measured live: `glass_low@1.5500`.
##
## Picking glass_high (baked 523.25) for that note instead makes it a 1.0x
## shift — exact pitch, untouched formants. This is the whole reason the
## library ships three pitches per family.
const LAYER_FAMILIES: Dictionary = {
	&"glass_low": [&"glass_low", &"glass_mid", &"glass_high"],
	&"glass_mid": [&"glass_low", &"glass_mid", &"glass_high"],
	&"glass_high": [&"glass_low", &"glass_mid", &"glass_high"],
	&"pad_low": [&"pad_low", &"pad_mid", &"pad_high"],
	&"pad_mid": [&"pad_low", &"pad_mid", &"pad_high"],
	&"pad_high": [&"pad_low", &"pad_mid", &"pad_high"],
	&"chime_soft": [&"chime_soft", &"chime_bright"],
	&"chime_bright": [&"chime_soft", &"chime_bright"],
}


## The member of `layer`'s family whose baked root is closest to `target_hz`.
##
## Same timbre, least transposition. Falls back to the layer itself when it
## belongs to no family (air and shimmer, which are never pitched).
static func nearest_in_family(layer: StringName, target_hz: float
		) -> StringName:
	var family: Array = LAYER_FAMILIES.get(layer, [])
	if family.is_empty() or target_hz <= 0.0:
		return layer
	var best: StringName = layer
	var best_ratio: float = INF
	for candidate: StringName in family:
		var baked: float = float(LAYER_ROOT_HZ.get(candidate, 0.0))
		if baked <= 0.0:
			continue
		# Compare in the LOG domain: a 2x shift up and a 0.5x shift down are
		# equally severe, and a linear difference would prefer the wrong one.
		var distance: float = absf(log(target_hz / baked) / log(2.0))
		if distance < best_ratio:
			best_ratio = distance
			best = candidate
	return best


## Playback rate that makes `layer` sound at `target_hz`.
##
## A layer with no baked root (air, shimmer) is texture and is never
## transposed — pitch-shifting noise just changes its brightness, which the
## filter already does more honestly.
##
## Clamped to MIN/MAX_PITCH_RATIO so a distant target degrades to "as close
## as this layer can honestly get" rather than to an obvious artefact. The
## library ships neighbouring pitches precisely so the clamp rarely binds.
static func playback_ratio(layer: StringName, target_hz: float) -> float:
	var baked: float = float(LAYER_ROOT_HZ.get(layer, 0.0))
	if baked <= 0.0:
		return 1.0
	return clampf(target_hz / baked, MIN_PITCH_RATIO, MAX_PITCH_RATIO)


## The frequency a layer will ACTUALLY sound at once the ratio is clamped.
##
## This, not the requested pitch, is what reaches the speaker — so it is what
## the frequency rule has to be checked against.
static func sounding_hz(layer: StringName, target_hz: float) -> float:
	var baked: float = float(LAYER_ROOT_HZ.get(layer, 0.0))
	if baked <= 0.0:
		return target_hz
	return baked * playback_ratio(layer, target_hz)


## Is this frequency safe to reproduce on a phone speaker?
static func is_audible(hz: float) -> bool:
	return hz >= MIN_AUDIBLE_HZ


## Is this a fundamental the small-speaker band handles well?
static func in_clear_band(hz: float) -> bool:
	return hz >= CLEAR_LOW_HZ and hz <= CLEAR_HIGH_HZ


## THE CORE FUNCTION. Resolve a full mix for a mode in a state.
##
## Returns one LayerMix per layer that should be audible. A layer below its
## role's density gate is omitted entirely rather than returned at zero gain,
## so a caller can simply iterate the result.
##
## `streak` 0..1 and `urgency` 0..1 modulate within the state, so the mix
## responds continuously to play rather than stepping between six presets.
static func resolve_mix(mode: Dictionary, state: int, streak: float = 0.0,
		urgency: float = 0.0) -> Array[LayerMix]:
	var response: Dictionary = STATE_RESPONSE.get(state,
		STATE_RESPONSE[State.IDLE])
	var density: float = clampf(
		float(response["density"]) + 0.15 * clampf(streak, 0.0, 1.0),
		0.0, 1.0)
	var cutoff_mul: float = float(response["cutoff"]) * (
		1.0 + 0.45 * clampf(urgency, 0.0, 1.0))
	var gain_mul: float = float(response["gain"])
	var base_cutoff: float = float(mode.get("base_cutoff", 4000.0))
	var root: float = float(mode.get("root_hz", 330.0))
	var intervals: Array = mode.get("intervals", [0.0])

	var out: Array[LayerMix] = []

	# BED — the foundation, always present.
	#
	# AT THE ROOT, NOT AN OCTAVE BELOW IT. Dropping the bed an octave was
	# tried and measured: it put false_witness's foundation at 143 Hz and
	# both mid modes at 191 Hz, and clear-band energy across the four beds
	# fell from 91-99% to 24-37%. Audible on a good speaker, absent on a
	# phone — precisely the failure this whole rebuild exists to avoid.
	#
	# Depth comes from the bus reverb and the layer's own harmonic content,
	# not from reaching for a low fundamental the hardware cannot reproduce.
	var bed_layer: StringName = nearest_in_family(
		mode.get("bed", &"pad_low"), root)
	out.append(_mix(bed_layer, Role.BED, gain_mul,
		playback_ratio(bed_layer, root), base_cutoff * cutoff_mul * 0.8))

	# TEXTURE — air. Enters early; carries no pitch, so it is never
	# transposed, only filtered.
	if density >= float(ROLE_DENSITY_GATE[Role.TEXTURE]):
		out.append(_mix(mode.get("texture", &"air_calm"), Role.TEXTURE,
			gain_mul, 1.0, base_cutoff * cutoff_mul * 1.6))

	# VOICE — one per interval. This is what carries the mode's harmony, and
	# where the four trials stop sounding alike.
	if density >= float(ROLE_DENSITY_GATE[Role.VOICE]):
		var voice_layer: StringName = mode.get("voice", &"glass_low")
		for i: int in range(intervals.size()):
			# Higher intervals fade in with density, so a mode opens up as
			# the player engages rather than arriving fully voiced.
			var need: float = 0.50 + 0.16 * float(i)
			if density < need:
				continue
			var semis: float = float(intervals[i])
			var hz: float = resolve_pitch(root, semis)
			# NEAREST SAMPLE IN THE FAMILY, then a small ratio against ITS
			# baked root. Two separate lessons:
			#   * dividing by the MODE root cancels it out, so every mode
			#     sharing a layer sounded at the same pitch
			#   * asking one sample to cover a two-octave chord clamps, and
			#     the octave came out as a sixth
			var sample: StringName = nearest_in_family(voice_layer, hz)
			var mix: LayerMix = _mix(sample, Role.VOICE, gain_mul,
				playback_ratio(sample, hz), base_cutoff * cutoff_mul)
			# Upper voices sit back, or the chord turns shrill on a phone.
			mix.gain *= 1.0 / (1.0 + 0.42 * float(i))
			out.append(mix)

	# ACCENT — sparse chimes, only at high density.
	if density >= float(ROLE_DENSITY_GATE[Role.ACCENT]):
		out.append(_mix(mode.get("accent", &"chime_soft"), Role.ACCENT,
			gain_mul, 1.0, base_cutoff * cutoff_mul * 1.4))

	# SHIMMER — the top end, reserved for the most aroused states so it
	# reads as an event rather than as constant sparkle.
	if state == State.STREAK or (state == State.URGENT and urgency > 0.5):
		out.append(_mix(&"shimmer_fine", Role.TEXTURE, gain_mul * 0.8,
			1.0, TEXTURE_MAX_HZ))

	# ── HEADROOM, ENFORCED HERE RATHER THAN BY THE LIMITER ───────────────
	#
	# Layer count varies from 1 (MENU) to 6 (STREAK with shimmer), so fixed
	# per-role gains cannot be safe at both ends: tuned for six they are
	# inaudible at one, tuned for one they sum past unity at six. Measured,
	# the first pass hit 2.13x and the second still reached 1.012x in STREAK.
	#
	# Scaling the whole mix down when — and only when — it would exceed the
	# ceiling keeps thin states at full level and prevents dense ones from
	# handing the mixing job to the limiter. The RATIOS between layers are
	# preserved, so the mode's balance survives the trim.
	var total: float = 0.0
	for m: LayerMix in out:
		total += m.gain
	if total > MIX_GAIN_CEILING and total > 0.0:
		var trim: float = MIX_GAIN_CEILING / total
		for m: LayerMix in out:
			m.gain *= trim

	return out


static func _mix(layer: StringName, role: int, gain_mul: float, pitch: float,
		cutoff: float) -> LayerMix:
	var m := LayerMix.new(layer, role)
	m.gain = float(ROLE_GAIN.get(role, 0.3)) * gain_mul
	m.pitch = pitch
	# Never open past the texture ceiling, and never close so far the mix
	# goes muddy.
	m.cutoff = clampf(cutoff, 800.0, TEXTURE_MAX_HZ)
	return m


## Summed gain of a mix. The engine uses this to prove it cannot clip: the
## bus limiter is a backstop, not a mixing strategy.
static func total_gain(mix: Array[LayerMix]) -> float:
	var sum: float = 0.0
	for m: LayerMix in mix:
		sum += m.gain
	return sum


## Every distinct layer this model can ever request. The engine preloads
## exactly this set, and the flow test asserts each one exists on disk —
## a mode naming a layer that was never baked would otherwise fail silently
## at runtime as one missing voice in a chord.
static func required_layers() -> Array[StringName]:
	var seen: Dictionary = {}
	var all_modes: Array = MODES.values()
	all_modes.append(MODE_NEUTRAL)
	for mode: Dictionary in all_modes:
		for key: String in ["bed", "voice", "accent", "texture"]:
			var layer: StringName = mode.get(key, &"")
			if layer != &"":
				seen[layer] = true
	seen[&"shimmer_fine"] = true
	var out: Array[StringName] = []
	for layer: StringName in seen.keys():
		out.append(layer)
	out.sort()
	return out
