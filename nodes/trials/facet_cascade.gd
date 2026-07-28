extends TrialMiniGame
## FacetCascade — crystalline match-3.
##
## PHASE 8. The fourth trial, restored from v1. Swap adjacent facets to line up
## 3+ of a colour; matches shatter, facets above fall, new ones drop in, and
## chains cascade for a combo multiplier. Clear `target` facets within `moves`.
##
## This is deliberately the ONE non-cognitive mode — the comfortable trial
## between the demanding ones. Removing it would flatten the suite's pacing.
##
## SCORING: accuracy = min(cleared, target) / target, so partial progress is
## partial credit. A player who clears 30 of 40 scores 75%, which feeds the
## adaptive engine sensibly rather than as a binary pass/fail.
##
## DETERMINISM: the board is generated from the seeded RNG, and generation
## rejects any starting layout that already contains a match — otherwise the
## board would resolve itself before the player touches it.
##
## Difficulty comes from TrialRegistry: 6x6/4 colours -> 8x8/6 colours.

## Combo multiplier per cascade step: 1st clear x1, 2nd x1.5, 3rd x2, capped.
const COMBO_STEP: float = 0.5
const COMBO_MAX: float = 3.0
const MIN_MATCH: int = 3

## Animation beats. Kept short — this is a trial, not a puzzle game.
const RESOLVE_DELAY: float = 0.16
const SHATTER_TIME: float = 0.14

var _size: int = 7
var _color_count: int = 5
var _target: int = 40
var _moves_left: int = 20
var _cleared: int = 0

## _grid[row][col] = colour index, or -1 for an empty cell mid-resolve.
var _grid: Array = []
var _selected: Vector2i = Vector2i(-1, -1)
var _busy: bool = false
var _combo: int = 0
var _shattering: Array[Vector2i] = []
var _shatter_timer: float = 0.0
var _last_combo_text: String = ""


func _configure_bracket(b: int) -> void:
	var params: Dictionary = TrialRegistry.params("facet_cascade", b)
	_size = int(params.get("size", 7))
	_color_count = clampi(int(params.get("colors", 5)), 3, Palette.FACET_COLORS.size())
	_target = maxi(int(params.get("target", 40)), 1)
	_moves_left = maxi(int(params.get("moves", 20)), 1)
	set_round_count(1)   # one board = one scored result


func begin() -> void:
	super()
	_generate_board()
	_build_cell_targets()
	set_process(true)
	queue_redraw()


# ═════════════════════════════════════════════════════════════════════════
# BOARD GENERATION
# ═════════════════════════════════════════════════════════════════════════
## Build a board with no pre-existing matches, so the player's first move
## matters. Retries per-cell rather than regenerating the whole board.
func _generate_board() -> void:
	_grid = []
	for row: int in range(_size):
		var line: Array = []
		for col: int in range(_size):
			line.append(_pick_safe_colour(row, col, line))
		_grid.append(line)


## Choose a colour that cannot complete a run of 3 with already-placed
## neighbours to the left or above.
func _pick_safe_colour(row: int, col: int, current_line: Array) -> int:
	var forbidden: Array[int] = []

	# Two matching to the left.
	if col >= 2:
		var a: int = int(current_line[col - 1])
		var b: int = int(current_line[col - 2])
		if a == b:
			forbidden.append(a)

	# Two matching above.
	if row >= 2:
		var a: int = int(_grid[row - 1][col])
		var b: int = int(_grid[row - 2][col])
		if a == b:
			forbidden.append(a)

	for _attempt: int in range(12):
		var pick: int = _rng.randi_range(0, _color_count - 1)
		if not forbidden.has(pick):
			return pick
	# Degenerate case (very few colours): accept a match rather than loop.
	return _rng.randi_range(0, _color_count - 1)


# ═════════════════════════════════════════════════════════════════════════
# INPUT
# ═════════════════════════════════════════════════════════════════════════
func _build_cell_targets() -> void:
	clear_targets()
	for row: int in range(_size):
		for col: int in range(_size):
			var r: int = row
			var c: int = col
			make_target(_cell_rect(row, col), func() -> void: _on_cell_tapped(r, c))


func _on_cell_tapped(row: int, col: int) -> void:
	if _busy or not is_running():
		return

	if _selected.x < 0:
		_selected = Vector2i(col, row)
		queue_redraw()
		return

	var previous: Vector2i = _selected
	var tapped: Vector2i = Vector2i(col, row)

	# Tapping the same cell deselects.
	if previous == tapped:
		_selected = Vector2i(-1, -1)
		queue_redraw()
		return

	# Only orthogonally adjacent swaps are legal; anything else re-selects.
	if not _is_adjacent(previous, tapped):
		_selected = tapped
		queue_redraw()
		return

	_selected = Vector2i(-1, -1)
	_attempt_swap(previous, tapped)


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1


## Swap, then keep it only if it produced a match. An illegal swap costs no
## move — v1 charged for it, which felt arbitrary.
func _attempt_swap(a: Vector2i, b: Vector2i) -> void:
	_swap_cells(a, b)

	if _find_matches().is_empty():
		_swap_cells(a, b)   # revert
		queue_redraw()
		return

	_moves_left -= 1
	_busy = true
	_combo = 0
	_resolve_cascade()


func _swap_cells(a: Vector2i, b: Vector2i) -> void:
	var temp: int = int(_grid[a.y][a.x])
	_grid[a.y][a.x] = _grid[b.y][b.x]
	_grid[b.y][b.x] = temp


# ═════════════════════════════════════════════════════════════════════════
# MATCH DETECTION
# ═════════════════════════════════════════════════════════════════════════
## Every cell belonging to a run of 3+ horizontally or vertically.
##
## Runs are collected separately then unioned, which is what makes L and T
## shapes work: a cell in both a horizontal and a vertical run appears once.
func _find_matches() -> Array[Vector2i]:
	var matched: Dictionary = {}

	# Horizontal runs.
	for row: int in range(_size):
		var run_start: int = 0
		for col: int in range(1, _size + 1):
			var same: bool = (
				col < _size
				and int(_grid[row][col]) >= 0
				and int(_grid[row][col]) == int(_grid[row][run_start]))
			if not same:
				var length: int = col - run_start
				if length >= MIN_MATCH and int(_grid[row][run_start]) >= 0:
					for c: int in range(run_start, col):
						matched[Vector2i(c, row)] = true
				run_start = col

	# Vertical runs.
	for col: int in range(_size):
		var run_start: int = 0
		for row: int in range(1, _size + 1):
			var same: bool = (
				row < _size
				and int(_grid[row][col]) >= 0
				and int(_grid[row][col]) == int(_grid[run_start][col]))
			if not same:
				var length: int = row - run_start
				if length >= MIN_MATCH and int(_grid[run_start][col]) >= 0:
					for r: int in range(run_start, row):
						matched[Vector2i(col, r)] = true
				run_start = row

	var out: Array[Vector2i] = []
	for key: Vector2i in matched.keys():
		out.append(key)
	return out


# ═════════════════════════════════════════════════════════════════════════
# CASCADE RESOLUTION
# ═════════════════════════════════════════════════════════════════════════
## Clear -> gravity -> refill -> repeat while new matches appear. Each pass
## raises the combo multiplier.
func _resolve_cascade() -> void:
	var matches: Array[Vector2i] = _find_matches()

	if matches.is_empty():
		_busy = false
		_combo = 0
		_check_end_conditions()
		queue_redraw()
		return

	_combo += 1
	HapticsManager.pulse(&"facet_match")
	# Collapsing a group is this mode's signature moment and deserves its own
	# voice, distinct from the generic hit tone the director plays.
	AudioManager.play_sfx(&"match")
	var multiplier: float = minf(1.0 + float(_combo - 1) * COMBO_STEP, COMBO_MAX)
	var scored: int = int(round(float(matches.size()) * multiplier))
	_cleared += scored

	if _combo > 1:
		_last_combo_text = "CHAIN ×%.1f" % multiplier

	_shattering = matches
	_shatter_timer = SHATTER_TIME
	for cell: Vector2i in matches:
		_grid[cell.y][cell.x] = -1

	queue_redraw()

	await get_tree().create_timer(RESOLVE_DELAY).timeout
	if not is_running():
		return

	_apply_gravity()
	_refill()
	queue_redraw()

	await get_tree().create_timer(RESOLVE_DELAY).timeout
	if not is_running():
		return

	_resolve_cascade()


## Facets fall into empty cells below them.
func _apply_gravity() -> void:
	for col: int in range(_size):
		var write_row: int = _size - 1
		for row: int in range(_size - 1, -1, -1):
			if int(_grid[row][col]) >= 0:
				_grid[write_row][col] = _grid[row][col]
				if write_row != row:
					_grid[row][col] = -1
				write_row -= 1
		for row: int in range(write_row, -1, -1):
			_grid[row][col] = -1


func _refill() -> void:
	for row: int in range(_size):
		for col: int in range(_size):
			if int(_grid[row][col]) < 0:
				_grid[row][col] = _rng.randi_range(0, _color_count - 1)


## The board ends when the target is reached or the move budget runs out.
func _check_end_conditions() -> void:
	if _cleared >= _target or _moves_left <= 0:
		_finish_board()


## Report a single scored result: progress toward the target.
##
## NO mark_stimulus() HERE, DELIBERATELY. Reaction latency is meaningless for a
## match-3 board: there is no discrete stimulus to react to, and the run is
## scored on total progress over a move budget rather than on speed. Reporting
## through host.record_answer() directly — rather than submit() — keeps this
## mode out of the latency history entirely, which is correct: a fabricated
## number here would pollute the ChronoPulse and Trend timing stats.
func _finish_board() -> void:
	if not is_running():
		return
	clear_targets()
	var accuracy: float = clampf(float(_cleared) / float(maxi(_target, 1)), 0.0, 1.0)
	# submit() advances the round counter and, at round 1 of 1, calls finish().
	if host != null and host.has_method("record_answer"):
		# Report as a proportion by logging correct/total in one shot: the host
		# tracks discrete answers, so scale to a fixed denominator.
		var granularity: int = 20
		var hits: int = int(round(accuracy * float(granularity)))
		for i: int in range(granularity):
			host.record_answer(i < hits)
	finish()


func _process(delta: float) -> void:
	if _shatter_timer > 0.0:
		_shatter_timer = maxf(_shatter_timer - delta, 0.0)
		if _shatter_timer <= 0.0:
			_shattering.clear()
		queue_redraw()


# ═════════════════════════════════════════════════════════════════════════
# GEOMETRY
# ═════════════════════════════════════════════════════════════════════════
func _board_rect() -> Rect2:
	var unit: float = field_unit()
	var side: float = unit * 0.78
	var centre: Vector2 = field_centre()
	return Rect2(centre - Vector2(side, side) * 0.5, Vector2(side, side))


func _cell_size() -> float:
	return _board_rect().size.x / float(maxi(_size, 1))


func _cell_rect(row: int, col: int) -> Rect2:
	var board: Rect2 = _board_rect()
	var cell: float = _cell_size()
	return Rect2(
		board.position + Vector2(float(col) * cell, float(row) * cell),
		Vector2(cell, cell))


# ═════════════════════════════════════════════════════════════════════════
# DRAWING — procedural crystalline facets, no textures
# ═════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	var board: Rect2 = _board_rect()
	var cell: float = _cell_size()
	var inset: float = cell * 0.12

	# Board backing.
	draw_rect(board.grow(inset * 0.5), Color(Palette.COLOR_SURFACE, 0.55))

	for row: int in range(_size):
		for col: int in range(_size):
			var colour_index: int = int(_grid[row][col])
			if colour_index < 0:
				continue
			var rect: Rect2 = _cell_rect(row, col).grow(-inset)
			var shattering: bool = _shattering.has(Vector2i(col, row))
			_draw_facet(rect, Palette.FACET_COLORS[colour_index], shattering)

	# Selection ring.
	if _selected.x >= 0:
		var sel: Rect2 = _cell_rect(_selected.y, _selected.x).grow(-inset * 0.5)
		draw_rect(sel, Palette.accent(), false, maxf(cell * 0.06, 2.0))

	_draw_hud()


## A crystalline facet: an octagonal gem with an inner highlight, so it reads
## as cut stone rather than a flat tile.
func _draw_facet(rect: Rect2, colour: Color, shattering: bool) -> void:
	var centre: Vector2 = rect.get_center()
	var half: float = rect.size.x * 0.5
	var alpha: float = 1.0
	var swell: float = 1.0

	if shattering:
		# Shrink and fade during the shatter beat.
		var t: float = _shatter_timer / SHATTER_TIME
		alpha = t
		swell = 0.6 + 0.4 * t

	var radius: float = half * swell
	var cut: float = radius * 0.42

	var points: PackedVector2Array = PackedVector2Array([
		centre + Vector2(-radius + cut, -radius),
		centre + Vector2(radius - cut, -radius),
		centre + Vector2(radius, -radius + cut),
		centre + Vector2(radius, radius - cut),
		centre + Vector2(radius - cut, radius),
		centre + Vector2(-radius + cut, radius),
		centre + Vector2(-radius, radius - cut),
		centre + Vector2(-radius, -radius + cut),
	])

	draw_colored_polygon(points, Color(colour, 0.55 * alpha))
	draw_polyline(points + PackedVector2Array([points[0]]),
		Color(colour, 0.95 * alpha), maxf(radius * 0.10, 1.0), true)

	# Facet cuts: two internal lines suggesting a cut gem.
	draw_line(centre + Vector2(-radius * 0.5, -radius * 0.5), centre,
		Color(colour, 0.6 * alpha), maxf(radius * 0.06, 1.0), true)
	draw_line(centre, centre + Vector2(radius * 0.55, radius * 0.35),
		Color(colour, 0.4 * alpha), maxf(radius * 0.05, 1.0), true)

	# Specular corner.
	draw_circle(centre + Vector2(-radius * 0.38, -radius * 0.40),
		radius * 0.14, Color(Palette.COLOR_CATCHLIGHT, alpha))


func _draw_hud() -> void:
	var unit: float = field_unit()
	var board: Rect2 = _board_rect()
	var accent: Color = Palette.accent()

	# Progress bar toward the target, above the board.
	var progress: float = clampf(float(_cleared) / float(maxi(_target, 1)), 0.0, 1.0)
	var bar_y: float = board.position.y - unit * 0.05
	var bar_w: float = board.size.x
	var bar_x: float = board.position.x
	var thickness: float = maxf(unit * 0.010, 3.0)

	draw_line(Vector2(bar_x, bar_y), Vector2(bar_x + bar_w, bar_y),
		Palette.COLOR_HAIRLINE, thickness, true)
	if progress > 0.0:
		draw_line(Vector2(bar_x, bar_y),
			Vector2(bar_x + bar_w * progress, bar_y), accent, thickness, true)

	# Move budget as pips below the board; low budget turns urgent.
	var pip_y: float = board.position.y + board.size.y + unit * 0.045
	var pips: int = mini(_moves_left, 24)
	var spacing: float = unit * 0.022
	var start_x: float = board.get_center().x - spacing * float(maxi(pips - 1, 0)) * 0.5
	var urgent: bool = _moves_left <= 3
	var pip_colour: Color = Palette.danger() if urgent else accent

	for i: int in range(pips):
		draw_circle(Vector2(start_x + spacing * float(i), pip_y),
			unit * 0.007, Color(pip_colour, 0.85))
