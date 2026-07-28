extends TrialMiniGame
## SequenceRecall — spatial memory on the compass shards.
##
## PHASE 7. The four compass shards (N/E/S/W) light in sequence; the player
## repeats it. Deliberately reuses the hub's compass vocabulary, so practising
## this trial also trains hub navigation.
##
## Scoring records ONE answer per tap rather than one per sequence, so a player
## who gets 5 of 6 correct is scored 5/6 — not a binary fail. v1 scored whole
## sequences and felt punishing.
##
## DIFFICULTY (v1 schema preserved):
##   bracket 0: 3-4 long, 1.10s display, 1.8s gap
##   bracket 1: 5-6 long, 0.65s display, 1.1s gap
##   bracket 2: 7-9 long, 0.35s display, 0.6s gap

enum Phase { SHOWING = 0, INPUT = 1, RESOLVING = 2 }

const ROUNDS: int = 4
const LENGTHS_MIN: Array[int] = [3, 5, 7]
const LENGTHS_MAX: Array[int] = [4, 6, 9]
const DISPLAY_TIMES: Array[float] = [1.10, 0.65, 0.35]
const GAP_TIMES: Array[float] = [1.8, 1.1, 0.6]

## Shard directions, matching IrisState.CompassShard order (N, E, S, W).
const DIRECTIONS: Array[Vector2] = [
	Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0),
]

var _len_min: int = 3
var _len_max: int = 4
var _display_time: float = 1.10
var _gap_time: float = 1.8

var _sequence: Array[int] = []
var _input_index: int = 0
var _phase: Phase = Phase.SHOWING
var _show_index: int = -1
var _timer: float = 0.0
var _lit_shard: int = -1
var _flash: float = 0.0
var _flash_correct: bool = true


func _configure_bracket(b: int) -> void:
	_len_min = LENGTHS_MIN[b]
	_len_max = LENGTHS_MAX[b]
	_display_time = DISPLAY_TIMES[b]
	_gap_time = GAP_TIMES[b]
	set_round_count(ROUNDS)


func begin() -> void:
	super()
	set_process(true)
	_next_round()


func _next_round() -> void:
	clear_targets()
	_sequence.clear()
	var length: int = _rng.randi_range(_len_min, _len_max)
	var previous: int = -1
	for i: int in range(length):
		# No immediate repeats — a doubled shard is ambiguous to the player
		# because two flashes of the same target look like one long flash.
		var pick: int = _rng.randi_range(0, DIRECTIONS.size() - 1)
		while pick == previous:
			pick = _rng.randi_range(0, DIRECTIONS.size() - 1)
		_sequence.append(pick)
		previous = pick

	_input_index = 0
	_phase = Phase.SHOWING
	_show_index = -1
	_timer = _gap_time * 0.5
	_lit_shard = -1
	queue_redraw()


func _build_input_targets() -> void:
	clear_targets()
	var centre: Vector2 = field_centre()
	var unit: float = field_unit()
	var ring: float = unit * 0.30
	var hit: float = unit * 0.11

	for i: int in range(DIRECTIONS.size()):
		var index: int = i
		var pos: Vector2 = centre + DIRECTIONS[i] * ring
		make_target(Rect2(pos - Vector2(hit, hit), Vector2(hit, hit) * 2.0),
			func() -> void: _on_shard_tapped(index))


func _on_shard_tapped(shard: int) -> void:
	if not is_running() or _phase != Phase.INPUT:
		return

	var expected: int = _sequence[_input_index]
	var correct: bool = shard == expected

	_lit_shard = shard
	_flash = 0.30
	_flash_correct = correct
	_input_index += 1

	HapticsManager.pulse(&"sequence_step")
	# Paired with the haptic, deliberately: this mode is a melody the player
	# is reproducing, and a bell per step is what makes the sequence audible
	# rather than purely visual. The hit/miss tone still comes from the
	# director via record_answer(); this is the mode's own texture.
	AudioManager.play_sfx(&"sequence_bell")
	# Through submit(), NOT host.record_answer() directly. Calling the host
	# bypassed the base class entirely, so mark_stimulus() had nothing to pair
	# with and this mode recorded no latency at all — invisible until a test
	# actually played it and inspected the result.
	# submit_step(), not submit(): this mode owns its own round counter and
	# several taps make up one round, so submit() would end the run early.
	submit_step(correct, false)
	# Re-arm for the next tap in the sequence: each one is its own reaction.
	if correct and _input_index < _sequence.size():
		mark_stimulus()

	# A wrong tap ends the round immediately — the rest of the sequence is
	# unknowable to the player, so continuing would only punish guessing.
	if not correct or _input_index >= _sequence.size():
		_phase = Phase.RESOLVING
		_timer = 0.45
		clear_targets()

	queue_redraw()


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta, 0.0)
		queue_redraw()

	if not is_running():
		return

	_timer -= delta
	match _phase:
		Phase.SHOWING:
			if _timer <= 0.0:
				_advance_show()
		Phase.RESOLVING:
			if _timer <= 0.0:
				_rounds_advance()
		Phase.INPUT:
			# Deliberately inert: input is driven by tap targets, not by the
			# clock, so there is no per-frame work and no timeout to advance.
			pass


func _advance_show() -> void:
	_show_index += 1
	if _show_index >= _sequence.size():
		# Playback finished — hand over to the player.
		_lit_shard = -1
		_phase = Phase.INPUT
		_build_input_targets()
		# Playback is over and the board is answerable, so reaction time
		# starts NOW — not when the round began. Counting the display
		# sequence as reaction time would inflate every measurement by the
		# length of the pattern.
		mark_stimulus()
		queue_redraw()
		return

	_lit_shard = _sequence[_show_index]
	_timer = _display_time
	# Brief darkness between flashes so consecutive lights read as separate.
	_flash = 0.0
	queue_redraw()
	await get_tree().create_timer(_display_time * 0.7).timeout
	if _phase == Phase.SHOWING:
		_lit_shard = -1
		queue_redraw()


## One "round" of this trial is one sequence; scoring already happened per tap.
func _rounds_advance() -> void:
	_rounds_done += 1
	if _rounds_done >= _rounds_total:
		finish()
		return
	_next_round()


func _draw() -> void:
	var centre: Vector2 = field_centre()
	var unit: float = field_unit()
	var ring: float = unit * 0.30
	var shard_r: float = unit * 0.075
	var accent: Color = Palette.accent()

	# Guide ring.
	draw_arc(centre, ring, 0.0, TAU, 64, Color(accent, 0.10),
		maxf(unit * 0.004, 1.0), true)

	for i: int in range(DIRECTIONS.size()):
		var pos: Vector2 = centre + DIRECTIONS[i] * ring
		var lit: bool = i == _lit_shard
		var alpha: float = 0.22
		var radius: float = shard_r

		if lit:
			alpha = 1.0
			radius = shard_r * 1.25

		var col: Color = accent
		if lit and _flash > 0.0 and _phase != Phase.SHOWING:
			col = Palette.success() if _flash_correct else Palette.danger()

		# Diamond shard, matching the hub's compass language.
		var points: PackedVector2Array = PackedVector2Array([
			pos + Vector2(0, -radius),
			pos + Vector2(radius * 0.72, 0),
			pos + Vector2(0, radius),
			pos + Vector2(-radius * 0.72, 0),
		])
		draw_colored_polygon(points, Color(col, alpha * 0.45))
		draw_polyline(points + PackedVector2Array([points[0]]), Color(col, alpha),
			maxf(unit * 0.008, 1.5), true)

		if lit:
			draw_arc(pos, radius * 1.9, 0.0, TAU, 32, Color(col, alpha * 0.28),
				maxf(unit * 0.012, 2.0), true)

	# Progress pips: filled = entered, hollow = remaining.
	if _phase == Phase.INPUT and not _sequence.is_empty():
		var pip_y: float = centre.y + unit * 0.44
		var spacing: float = unit * 0.035
		var start_x: float = centre.x - spacing * float(_sequence.size() - 1) * 0.5
		for i: int in range(_sequence.size()):
			var pip: Vector2 = Vector2(start_x + spacing * float(i), pip_y)
			if i < _input_index:
				draw_circle(pip, unit * 0.010, Color(accent, 0.9))
			else:
				draw_arc(pip, unit * 0.010, 0.0, TAU, 12, Color(accent, 0.35),
					maxf(unit * 0.003, 1.0), true)
