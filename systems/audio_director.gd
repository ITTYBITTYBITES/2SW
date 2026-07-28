extends Node
class_name AudioDirectorSystem

## AudioDirector — decides WHEN the game makes a sound. Autoload.
##
## AudioManager is a synthesiser: give it an SFX id or an emotion and it
## produces samples. It has no opinion about gameplay. This is the other half —
## the policy layer that watches the Bus and decides what the moment calls for.
##
## WHY A SEPARATE SYSTEM RATHER THAN CALLS IN GAMEPLAY CODE
##
## Before this existed there were 39 AudioManager call sites and 33 of them
## were `ui_tap` on a button. The hub controller had ZERO. Every mini-game had
## ZERO. Answering a question correctly made no sound at all, because
## `Bus.iris_express` had three emitters and no listeners — the trial announced
## every hit and miss into a void.
##
## Scattering `AudioManager.play_sfx()` through gameplay would have fixed the
## symptom and guaranteed the next mode forgets. Subscribing to signals the
## game ALREADY emits means a new trial mode is audible the moment it reports
## an answer, without knowing this class exists.
##
## WHAT IT SUBSCRIBES TO, AND WHY EACH ONE
##
##   iris_express            every answer, from any mode, via record_answer()
##   trial_started           opening line + lift the ambient pad
##   trial_completed         closing line, toned by accuracy
##   trial_urgency_changed   the final quarter of an answer window
##   iris_tapped             the player touched the eye on the hub
##   iris_shard_hovered      a compass destination came under the finger
##   iris_shard_committed    they let go on one
##   route_changed           settle the pad per screen
##   level_changed           rank-up flourish
##
## RULE C: every handler is a positive guard. A director that logged an error
## on each of sixty urgency frames would be worse than the silence it replaced.

## Ambient pad intensity per context. The pad runs continuously from the
## splash onward; only its intensity moves, so there is never a gap where the
## room goes dead.
const PAD_HUB: float = 0.20
const PAD_TRIAL: float = 0.42
const PAD_URGENT: float = 0.60
const PAD_MENU: float = 0.14
const PAD_RESULTS: float = 0.26

## Voice length, in "syllables", per context. AudioManager scales the hum's
## duration from this, so a short acknowledgement stays short.
const SYLLABLES_TOUCH: int = 5
const SYLLABLES_GREET: int = 12

## Minimum gap between two eye-touch vocalisations, in seconds.
##
## Without this, tapping the eye repeatedly retriggers the voice on every
## touch and the companion sounds like a stuck record. Long enough to prevent
## machine-gunning, short enough that a deliberate second tap still answers.
const TOUCH_VOICE_COOLDOWN: float = 1.6

## Minimum gap between urgency ticks, in seconds.
const TICK_INTERVAL: float = 0.42

var _wired: bool = false
var _in_trial: bool = false
var _urgent: bool = false
var _tick_accum: float = 0.0
var _last_touch_voice_msec: int = -100000
## Counts every sound this director has dispatched, by kind. Test-visible, so
## a check can prove a signal produced a sound rather than merely firing.
var _dispatch_counts: Dictionary = {}


func _ready() -> void:
	# The pad must keep generating while the tree is paused, for the same
	# reason AudioManager does: focus loss pauses the tree, and a starved
	# generator buffer never recovers.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

	Bus.iris_express.connect(_on_iris_express)
	Bus.trial_started.connect(_on_trial_started)
	Bus.trial_completed.connect(_on_trial_completed)
	Bus.trial_urgency_changed.connect(_on_urgency_changed)
	Bus.iris_tapped.connect(_on_iris_tapped)
	Bus.iris_shard_hovered.connect(_on_shard_hovered)
	Bus.iris_shard_committed.connect(_on_shard_committed)
	Bus.route_changed.connect(_on_route_changed)
	Bus.level_changed.connect(_on_level_changed)
	_wired = true
	Log.info("AudioDirector", "subscribed to the bus")


func _exit_tree() -> void:
	if not _wired:
		return
	Bus.iris_express.disconnect(_on_iris_express)
	Bus.trial_started.disconnect(_on_trial_started)
	Bus.trial_completed.disconnect(_on_trial_completed)
	Bus.trial_urgency_changed.disconnect(_on_urgency_changed)
	Bus.iris_tapped.disconnect(_on_iris_tapped)
	Bus.iris_shard_hovered.disconnect(_on_shard_hovered)
	Bus.iris_shard_committed.disconnect(_on_shard_committed)
	Bus.route_changed.disconnect(_on_route_changed)
	Bus.level_changed.disconnect(_on_level_changed)
	_wired = false


# ═════════════════════════════════════════════════════════════════════════
# DISPATCH
# ═════════════════════════════════════════════════════════════════════════
## One funnel for every sound, so the counters cannot disagree with reality.
func _fire(sfx: StringName) -> void:
	AudioManager.play_sfx(sfx)
	_dispatch_counts[sfx] = int(_dispatch_counts.get(sfx, 0)) + 1


func _voice(context: StringName, emotion: StringName) -> String:
	var line: String = AudioManager.speak(context, emotion)
	var key: StringName = StringName("voice:%s" % context)
	_dispatch_counts[key] = int(_dispatch_counts.get(key, 0)) + 1
	return line


## How many times a given sound has been dispatched this session.
##
## Exposed because `AudioStreamPlayer.playing` is USELESS as evidence here: a
## generator stream reports `true` forever once started, so it cannot
## distinguish "this event made a sound" from "something played a minute ago".
## Verified directly — a probe showed the voice player still `playing` 1.5s
## after a 0.3s utterance. Counting dispatches is the only honest assertion.
func dispatch_count(key: StringName) -> int:
	return int(_dispatch_counts.get(key, 0))


func total_dispatches() -> int:
	var total: int = 0
	for key: StringName in _dispatch_counts:
		total += int(_dispatch_counts[key])
	return total


func is_in_trial() -> bool:
	return _in_trial


func is_urgent() -> bool:
	return _urgent


# ═════════════════════════════════════════════════════════════════════════
# TRIAL AUDIO
# ═════════════════════════════════════════════════════════════════════════
## Every answer, from every mode. `iris_express` is emitted by
## TrialController.record_answer(), which is the single choke point all five
## mini-games already report through — so a new mode is audible for free.
func _on_iris_express(kind: String, _intensity: float) -> void:
	match kind:
		"reward":
			_fire(&"reward")
			# A spoken reaction on EVERY hit would be exhausting inside a
			# 2-second loop, so the voice is left to the round boundaries and
			# the hit itself is a tone.
		"miss":
			_fire(&"error")
		"evolve":
			_fire(&"sequence_bell")
		"focus":
			_fire(&"stroop_pulse")
		"greet":
			_voice(DialogueManifest.HUB_GREET, &"hub_idle")
		_:
			# An unknown kind is a caller's typo, not a fault worth halting on,
			# but silence here is exactly the bug this class exists to fix.
			Log.warn("AudioDirector", "unhandled iris_express kind '%s'" % kind)


func _on_trial_started(_trial_id: String, _bracket: int) -> void:
	_in_trial = true
	_urgent = false
	_tick_accum = 0.0
	AudioManager.set_pad_intensity(PAD_TRIAL)
	_voice(DialogueManifest.TRIAL_START, &"trial_focus")


## Closing line, toned by how it went. DialogueManifest.completion_context()
## already routes accuracy to HIGH / MID / LOW; it had simply never been called.
func _on_trial_completed(summary: Dictionary) -> void:
	_in_trial = false
	_set_urgent(false)
	AudioManager.set_pad_intensity(PAD_RESULTS)

	var accuracy: float = float(summary.get("accuracy", 0.0))
	var context: StringName = DialogueManifest.completion_context(accuracy)
	var emotion: StringName = &"streak_celebrate"
	if accuracy < DialogueManifest.MID_ACCURACY:
		emotion = &"warble_error"
	elif accuracy < DialogueManifest.HIGH_ACCURACY:
		emotion = &"hub_idle"
	_voice(context, emotion)


# ═════════════════════════════════════════════════════════════════════════
# URGENCY TICKS
# ═════════════════════════════════════════════════════════════════════════
## The answer window entered or left its final quarter.
func _on_urgency_changed(urgent: bool) -> void:
	_set_urgent(urgent)


func _set_urgent(urgent: bool) -> void:
	if urgent == _urgent:
		return
	_urgent = urgent
	# Ticking is driven from _process so the cadence is wall-clock steady
	# rather than tied to how often the mini-game happens to redraw.
	set_process(urgent)
	_tick_accum = 0.0
	if urgent:
		AudioManager.set_pad_intensity(PAD_URGENT)
		# Lead with a tick so the pressure is felt at the transition, not up
		# to TICK_INTERVAL later.
		_fire(&"stroop_pulse")
	elif _in_trial:
		AudioManager.set_pad_intensity(PAD_TRIAL)


func _process(delta: float) -> void:
	if not _urgent:
		set_process(false)
		return
	_tick_accum += delta
	if _tick_accum >= TICK_INTERVAL:
		_tick_accum = 0.0
		_fire(&"stroop_pulse")


# ═════════════════════════════════════════════════════════════════════════
# HUB INTERACTION
# ═════════════════════════════════════════════════════════════════════════
## The player touched the eye. It answers with a formant hum plus a line, so
## the companion reacts to being touched rather than staying inert.
func _on_iris_tapped(_shard_id: int) -> void:
	_fire(&"ui_tap")
	var now: int = Time.get_ticks_msec()
	var since: float = float(now - _last_touch_voice_msec) / 1000.0
	if since >= TOUCH_VOICE_COOLDOWN:
		_last_touch_voice_msec = now
		_voice(DialogueManifest.HUB_GREET, &"touch_respond")


## A compass destination came under the finger during a drag.
func _on_shard_hovered(shard_id: int) -> void:
	# NONE means the drag left every shard. That is a real transition, but a
	# sound on it would click constantly as the finger crosses dead space.
	if shard_id == IrisState.CompassShard.NONE:
		return
	_fire(&"swap")


## They released on a destination. Navigation follows, so this is the last
## sound the hub makes before the screen changes.
func _on_shard_committed(_shard_id: int) -> void:
	_fire(&"match")


func _on_level_changed(_old_level: int, _new_level: int) -> void:
	_fire(&"reward")
	_voice(DialogueManifest.STREAK_MILESTONE, &"streak_celebrate")


# ═════════════════════════════════════════════════════════════════════════
# AMBIENCE PER SCREEN
# ═════════════════════════════════════════════════════════════════════════
## Settle the pad to suit the screen.
##
## The pad's intensity used to be set exactly once, by the splash, and never
## moved again — so the room sounded identical whether the player was idling
## on the hub or two seconds from failing a timed round.
func _on_route_changed(route: String, _payload: Dictionary) -> void:
	if route != "trial":
		_in_trial = false
		_set_urgent(false)
	match route:
		"hub":
			AudioManager.set_pad_intensity(PAD_HUB)
		"trial":
			AudioManager.set_pad_intensity(PAD_TRIAL)
		"results", "chrono_card":
			AudioManager.set_pad_intensity(PAD_RESULTS)
		_:
			AudioManager.set_pad_intensity(PAD_MENU)
