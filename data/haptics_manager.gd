extends Node
## HapticsManager — tactile feedback. Autoload.
##
## PHASE 11. A thin, gated wrapper over Input.vibrate_handheld().
##
## THE GATE IS THE POINT:
## Every call checks the `haptics` setting first. The Settings toggle has
## existed since Phase 9 and nothing read it — a persisted preference that
## silently does nothing is worse than no preference at all, because the
## player believes they turned something off.
##
## PLATFORM: vibrate_handheld() is a no-op on desktop and in headless builds,
## so no call site needs a platform check. We still guard explicitly so the
## logs are honest about why nothing happened.
##
## RESTRAINT: durations are deliberately short. Continuous or heavy haptics in
## a 2-minute cognitive trainer drain battery and become irritating within one
## session — the fastest route to a player disabling them permanently.

## Single pulses, in milliseconds.
const DURATION_UI_TAP: int = 15        # barely perceptible acknowledgement
const DURATION_MEDIUM: int = 30        # a match landed, a sequence step registered
const DURATION_STRONG: int = 45        # an error, a forfeit

## Multi-pulse patterns: alternating [vibrate_ms, gap_ms, vibrate_ms, ...].
## A pattern reads as an *event* rather than an acknowledgement, which is why
## celebrations get one and taps do not.
const PATTERN_TRIAL_COMPLETE: Array[int] = [30, 60, 30]
const PATTERN_STREAK_CELEBRATE: Array[int] = [25, 50, 25, 50, 60]
const PATTERN_RANK_UP: Array[int] = [40, 70, 40, 70, 80]

## Named events. Callers use these rather than raw durations, so retuning the
## feel is a change in one file.
const EVENTS: Dictionary = {
	&"ui_tap": DURATION_UI_TAP,
	&"facet_match": DURATION_MEDIUM,
	&"sequence_step": DURATION_MEDIUM,
	&"stroop_answer": DURATION_MEDIUM,
	&"error": DURATION_STRONG,
	&"reward": DURATION_MEDIUM,
}

const PATTERNS: Dictionary = {
	&"trial_complete": PATTERN_TRIAL_COMPLETE,
	&"streak_celebrate": PATTERN_STREAK_CELEBRATE,
	&"rank_up": PATTERN_RANK_UP,
}

var _enabled: bool = true
var _supported: bool = false
## Counts suppressed and delivered pulses so a test can assert the gate works
## without a physical device.
var _delivered: int = 0
var _suppressed: int = 0


func _ready() -> void:
	_supported = _detect_support()
	_refresh_from_settings()
	Save.loaded.connect(_refresh_from_settings)
	Log.info("Haptics", "enabled=%s supported=%s" % [str(_enabled), str(_supported)])


func _exit_tree() -> void:
	if Save.loaded.is_connected(_refresh_from_settings):
		Save.loaded.disconnect(_refresh_from_settings)


## Only handhelds vibrate. Desktop and headless report false so the logs
## explain the silence rather than leaving it mysterious.
func _detect_support() -> bool:
	var platform: String = OS.get_name()
	return platform == "Android" or platform == "iOS"


func _refresh_from_settings() -> void:
	_enabled = bool(Save.setting("haptics", true))


## Update the preference and persist. Called from Settings.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	Save.set_setting("haptics", enabled)
	Log.d("Haptics", "set enabled=%s" % str(enabled))


func is_enabled() -> bool:
	return _enabled


func is_supported() -> bool:
	return _supported


# ═════════════════════════════════════════════════════════════════════════
# FIRING
# ═════════════════════════════════════════════════════════════════════════
## Fire a named single-pulse event.
func pulse(event: StringName) -> void:
	if not Log.must(EVENTS.has(event), "Haptics", "unknown event '%s'" % event):
		return
	_vibrate(int(EVENTS[event]))


## Fire a named multi-pulse pattern. Gaps use scene-tree timers, so a pattern
## never blocks the frame.
func pattern(pattern_name: StringName) -> void:
	if not Log.must(PATTERNS.has(pattern_name), "Haptics",
			"unknown pattern '%s'" % pattern_name):
		return
	if not _allowed():
		_suppressed += 1
		return
	_play_pattern(PATTERNS[pattern_name] as Array[int])


## Arbitrary duration, clamped. Prefer the named events; this exists for
## one-off tuning during development.
func vibrate_ms(duration_ms: int) -> void:
	_vibrate(clampi(duration_ms, 1, 500))


## The single gate every path passes through. Returns false when haptics are
## off OR the device cannot vibrate, and records which so tests can tell the
## difference between "suppressed by preference" and "no hardware".
func _allowed() -> bool:
	if not _enabled:
		return false
	if not _supported:
		return false
	return true


func _vibrate(duration_ms: int) -> void:
	if not _allowed():
		_suppressed += 1
		return
	Input.vibrate_handheld(duration_ms)
	_delivered += 1


func _play_pattern(steps: Array[int]) -> void:
	# Even indices are vibrations, odd indices are gaps.
	for i: int in range(steps.size()):
		if i % 2 == 0:
			Input.vibrate_handheld(steps[i])
			_delivered += 1
		else:
			await get_tree().create_timer(float(steps[i]) / 1000.0).timeout
		# Re-check between steps: a player toggling haptics mid-celebration
		# should stop feeling it immediately.
		if not _allowed():
			return


# ═════════════════════════════════════════════════════════════════════════
# TEST HOOKS
# ═════════════════════════════════════════════════════════════════════════
## Pretend the device supports vibration, so the gate can be exercised on
## desktop and in headless CI.
func set_supported_for_test(supported: bool) -> void:
	_supported = supported


func delivered_count() -> int:
	return _delivered


func suppressed_count() -> int:
	return _suppressed


func reset_counters() -> void:
	_delivered = 0
	_suppressed = 0
