extends TrialMiniGame
## CognitiveConflict — Stroop-style interference under visual noise.
##
## PHASE 7. A colour word is drawn in a conflicting ink colour. The player taps
## the swatch matching the INK, not the word. Procedural noise drifts across the
## field to raise the perceptual load.
##
## ACCESSIBILITY: v1 drew colour-only answer buttons, which is unplayable for
## colourblind users — the whole task is colour discrimination. Here each swatch
## carries a distinct procedural GLYPH (circle / triangle / square / diamond),
## and the prompt word is spelled out, so the task stays solvable by shape.
##
## The word itself is drawn with vector strokes, not a font, keeping the
## no-texture rule intact while remaining legible.
##
## DIFFICULTY (v1 schema preserved):
##   bracket 0: 4 stimuli, 2.40s window
##   bracket 1: 6 stimuli, 1.10s window
##   bracket 2: 8 stimuli, 0.55s window

const STIMULI_COUNTS: Array[int] = [4, 6, 8]
const RESPONSE_WINDOWS: Array[float] = [2.40, 1.10, 0.55]

## Four inks, each with a distinct shape so colour is never the only cue.
## Colours live in Palette (Rule D) so accessibility passes retune them once.
enum Glyph { CIRCLE = 0, TRIANGLE = 1, SQUARE = 2, DIAMOND = 3 }


static func ink_names() -> Array[String]:
	return Palette.STROOP_INK_NAMES


static func ink_colors() -> Array[Color]:
	return Palette.STROOP_INKS

## Anomaly override. When the host supplies daily parameters, the window and
## round count come from the deterministic seed instead of the bracket table,
## so every player faces an identically-tuned Stroop task.
var _window: float = 2.40
var _word_index: int = 0      # which word is spelled
var _ink_index: int = 0       # which colour it is drawn in (the answer)
var _time_left: float = 0.0
var _noise_phase: float = 0.0
var _feedback: int = 0
var _feedback_timer: float = 0.0


func _configure_bracket(b: int) -> void:
	_window = RESPONSE_WINDOWS[b]
	set_round_count(STIMULI_COUNTS[b])

	# Daily anomaly override. The bracket still sets the baseline so a normal
	# practice run is unaffected; the anomaly replaces the two knobs that
	# decide how the task actually feels.
	var anomaly: Dictionary = {}
	if host != null and host.has_method("anomaly_params"):
		anomaly = host.call("anomaly_params")
	if anomaly.is_empty():
		return

	var window_ms: int = int(anomaly.get("window_ms", 0))
	if window_ms > 0:
		_window = float(window_ms) / 1000.0
	var pulses: int = int(anomaly.get("pulses", 0))
	if pulses > 0:
		set_round_count(pulses)

	Log.d("Stroop", "anomaly tuning: window %.2fs over %d rounds" % [
		_window, rounds_total()])


func begin() -> void:
	super()
	set_process(true)
	_next_stimulus()


func _next_stimulus() -> void:
	clear_targets()

	_word_index = _rng.randi_range(0, ink_names().size() - 1)
	# Genuine conflict: ink must never match the word, or there is no Stroop
	# effect and the trial measures nothing.
	_ink_index = _rng.randi_range(0, ink_colors().size() - 1)
	while _ink_index == _word_index:
		_ink_index = _rng.randi_range(0, ink_colors().size() - 1)

	_time_left = _window
	_build_swatch_targets()
	# The stimulus is answerable the moment its targets exist. Marked here
	# rather than at round setup so lead-in time is never counted as reaction
	# time.
	mark_stimulus()
	queue_redraw()


func _build_swatch_targets() -> void:
	var unit: float = field_unit()
	var centre: Vector2 = field_centre()
	var count: int = ink_colors().size()
	var spacing: float = unit * 0.19
	var start_x: float = centre.x - spacing * float(count - 1) * 0.5
	var y: float = centre.y + unit * 0.26
	var half: float = unit * 0.075

	for i: int in range(count):
		var index: int = i
		var pos: Vector2 = Vector2(start_x + spacing * float(i), y)
		make_target(Rect2(pos - Vector2(half, half), Vector2(half, half) * 2.0),
			func() -> void: _on_swatch_tapped(index))


func _on_swatch_tapped(index: int) -> void:
	if not is_running() or _time_left <= 0.0:
		return
	var correct: bool = index == _ink_index
	_feedback = 1 if correct else -1
	_feedback_timer = 0.35
	HapticsManager.pulse(&"stroop_answer" if correct else &"error")
	# The mode's own cue. Correct/incorrect tones arrive separately from the
	# director, which hears every answer through record_answer().
	AudioManager.play_sfx(&"stroop_pulse")
	clear_targets()
	# A real response: latency is measured from the stimulus mark.
	submit(correct, false)
	if is_running():
		_next_stimulus()


func _process(delta: float) -> void:
	_noise_phase += delta
	if _feedback_timer > 0.0:
		_feedback_timer -= delta
		if _feedback_timer <= 0.0:
			_feedback = 0

	if is_running():
		_time_left -= delta
		if _time_left <= 0.0:
			_feedback = -1
			_feedback_timer = 0.3
			clear_targets()
			# The window closed with no answer. Flagged as a timeout so it is
			# counted as a miss rather than recorded as a latency equal to
			# the window — which would look like a slow but real reaction.
			submit(false, true)
			if is_running():
				_next_stimulus()
	queue_redraw()


func _draw() -> void:
	var unit: float = field_unit()
	var centre: Vector2 = field_centre()

	_draw_noise(unit, centre)

	# Countdown ring.
	if is_running() and _window > 0.0:
		var fraction: float = clampf(_time_left / _window, 0.0, 1.0)
		var urgent: bool = fraction < 0.3
		var col: Color = Palette.danger() if urgent else Palette.accent()
		draw_arc(centre + Vector2(0, -unit * 0.12), unit * 0.30, -PI * 0.5,
			-PI * 0.5 + TAU * fraction, 64, Color(col, 0.7),
			maxf(unit * 0.010, 2.0), true)

	# The prompt word, drawn in the conflicting ink.
	_draw_word(ink_names()[_word_index], centre + Vector2(0, -unit * 0.12),
		unit * 0.055, ink_colors()[_ink_index])

	_draw_swatches(unit, centre)

	if _feedback != 0:
		var col: Color = Palette.success() if _feedback > 0 else Palette.danger()
		var alpha: float = clampf(_feedback_timer / 0.35, 0.0, 1.0)
		draw_arc(centre, unit * 0.46, 0.0, TAU, 64, Color(col, alpha * 0.55),
			maxf(unit * 0.014, 2.0), true)


## Drifting procedural interference. Kept low-contrast so it raises load
## without making the prompt unreadable.
func _draw_noise(unit: float, centre: Vector2) -> void:
	var accent: Color = Palette.accent()
	var lines: int = 14
	for i: int in range(lines):
		var t: float = float(i) / float(lines)
		var drift: float = sin(_noise_phase * 0.6 + t * TAU) * unit * 0.05
		var y: float = centre.y - unit * 0.45 + t * unit * 0.9
		draw_line(
			Vector2(centre.x - unit * 0.46 + drift, y),
			Vector2(centre.x + unit * 0.46 + drift, y),
			Color(accent, 0.045), maxf(unit * 0.004, 1.0), true)


## Answer swatches: colour AND shape, so the task never depends on colour alone.
func _draw_swatches(unit: float, centre: Vector2) -> void:
	var count: int = ink_colors().size()
	var spacing: float = unit * 0.19
	var start_x: float = centre.x - spacing * float(count - 1) * 0.5
	var y: float = centre.y + unit * 0.26
	var radius: float = unit * 0.055

	for i: int in range(count):
		var pos: Vector2 = Vector2(start_x + spacing * float(i), y)
		var col: Color = ink_colors()[i]
		_draw_glyph(pos, radius, col, Glyph.values()[i])
		draw_arc(pos, radius * 1.35, 0.0, TAU, 28, Color(col, 0.35),
			maxf(unit * 0.005, 1.0), true)


func _draw_glyph(centre: Vector2, radius: float, colour: Color, glyph: Glyph) -> void:
	match glyph:
		Glyph.CIRCLE:
			draw_circle(centre, radius, Color(colour, 0.85))
		Glyph.TRIANGLE:
			draw_colored_polygon(PackedVector2Array([
				centre + Vector2(0, -radius),
				centre + Vector2(radius * 0.88, radius * 0.7),
				centre + Vector2(-radius * 0.88, radius * 0.7),
			]), Color(colour, 0.85))
		Glyph.SQUARE:
			draw_rect(Rect2(centre - Vector2(radius, radius) * 0.82,
				Vector2(radius, radius) * 1.64), Color(colour, 0.85))
		Glyph.DIAMOND:
			draw_colored_polygon(PackedVector2Array([
				centre + Vector2(0, -radius),
				centre + Vector2(radius * 0.8, 0),
				centre + Vector2(0, radius),
				centre + Vector2(-radius * 0.8, 0),
			]), Color(colour, 0.85))


# ═════════════════════════════════════════════════════════════════════════
# VECTOR TEXT — no font, no texture
# ═════════════════════════════════════════════════════════════════════════
## Seven-segment style strokes per letter. Only the glyphs used by INK_NAMES
## are defined; anything else draws a placeholder bar rather than failing.
const LETTER_STROKES: Dictionary = {
	"T": [[0.0, 0.0, 1.0, 0.0], [0.5, 0.0, 0.5, 1.0]],
	"E": [[0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0], [0.0, 0.5, 0.8, 0.5], [0.0, 1.0, 1.0, 1.0]],
	"A": [[0.0, 1.0, 0.5, 0.0], [0.5, 0.0, 1.0, 1.0], [0.2, 0.6, 0.8, 0.6]],
	"L": [[0.0, 0.0, 0.0, 1.0], [0.0, 1.0, 1.0, 1.0]],
	"G": [[1.0, 0.15, 0.5, 0.0], [0.5, 0.0, 0.0, 0.3], [0.0, 0.3, 0.0, 0.7],
		[0.0, 0.7, 0.5, 1.0], [0.5, 1.0, 1.0, 0.8], [1.0, 0.8, 1.0, 0.55], [0.6, 0.55, 1.0, 0.55]],
	"O": [[0.5, 0.0, 1.0, 0.35], [1.0, 0.35, 1.0, 0.65], [1.0, 0.65, 0.5, 1.0],
		[0.5, 1.0, 0.0, 0.65], [0.0, 0.65, 0.0, 0.35], [0.0, 0.35, 0.5, 0.0]],
	"D": [[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.7, 0.2], [0.7, 0.2, 0.7, 0.8], [0.7, 0.8, 0.0, 1.0]],
	"R": [[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.9, 0.15], [0.9, 0.15, 0.9, 0.4],
		[0.9, 0.4, 0.0, 0.55], [0.0, 0.55, 1.0, 1.0]],
	"S": [[1.0, 0.1, 0.2, 0.0], [0.2, 0.0, 0.0, 0.3], [0.0, 0.3, 0.9, 0.6],
		[0.9, 0.6, 1.0, 0.8], [1.0, 0.8, 0.1, 1.0]],
	"I": [[0.5, 0.0, 0.5, 1.0]],
	"V": [[0.0, 0.0, 0.5, 1.0], [0.5, 1.0, 1.0, 0.0]],
	"N": [[0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 1.0], [1.0, 1.0, 1.0, 0.0]],
}


func _draw_word(word: String, centre: Vector2, letter_h: float, colour: Color) -> void:
	var letter_w: float = letter_h * 0.62
	var spacing: float = letter_w * 1.45
	var total: float = spacing * float(word.length() - 1)
	var origin: Vector2 = centre - Vector2(total * 0.5, letter_h * 0.5)
	var thickness: float = maxf(letter_h * 0.13, 2.0)

	for i: int in range(word.length()):
		var glyph: String = word.substr(i, 1)
		var base: Vector2 = origin + Vector2(spacing * float(i), 0.0)
		if not LETTER_STROKES.has(glyph):
			draw_line(base, base + Vector2(letter_w, 0.0), colour, thickness, true)
			continue
		for stroke: Array in LETTER_STROKES[glyph]:
			draw_line(
				base + Vector2(float(stroke[0]) * letter_w, float(stroke[1]) * letter_h),
				base + Vector2(float(stroke[2]) * letter_w, float(stroke[3]) * letter_h),
				colour, thickness, true)
