extends TrialMiniGame
## FalseWitness — rapid visual discrimination.
##
## PHASE 7. A ring of procedurally drawn iris glyphs appears. All are identical
## except one anomaly, which differs by exactly ONE property (ring count, pupil
## size, tilt, or fleck placement). Tap the anomaly before the window closes.
##
## v1's version needed 36 object PNGs and 20 layout templates (2.8 MB). This
## generates every glyph from the same vector maths the real Iris uses, so the
## discrimination task is thematically consistent and weighs nothing.
##
## DIFFICULTY (mirrors the v1 schema, glyph counts preserved):
##   bracket 0: 6 glyphs, 6.5s window, subtle delta 0.45
##   bracket 1: 11 glyphs, 4.0s window, delta 0.30
##   bracket 2: 17 glyphs, 2.2s window, delta 0.20

const ROUNDS: int = 6
const GLYPH_COUNTS: Array[int] = [6, 11, 17]
const WINDOWS: Array[float] = [6.5, 4.0, 2.2]
## How different the anomaly is. Lower = harder to spot.
const DELTAS: Array[float] = [0.45, 0.30, 0.20]

## Glyph ring geometry, as fractions of the field's short side.
##
## These were bare literals duplicated between _next_round() (which PLACES the
## glyphs) and _draw() (which DRAWS them and the timer arc). Two copies of a
## layout constant is how the arc and the ring ended up disagreeing about how
## big the round was.
## Fraction of the answer window below which the round counts as urgent. The
## timer arc already turned red here; now the sound follows the same number,
## from the same constant, so they cannot drift apart.
const URGENCY_FRACTION: float = 0.25

const RING_FRACTION: float = 0.32
const GLYPH_FRACTION: float = 0.055

## One property that can differ. Varying WHICH property changes per round stops
## players pattern-matching on a single cue.
enum Anomaly { RINGS = 0, PUPIL = 1, TILT = 2, FLECK = 3 }

var _glyph_count: int = 6
var _window: float = 6.5
var _delta: float = 0.45

var _positions: Array[Vector2] = []
var _anomaly_index: int = 0
var _anomaly_kind: Anomaly = Anomaly.RINGS
var _time_left: float = 0.0
## Last urgency state pushed to the Bus, so only transitions are emitted.
var _urgency_reported: bool = false
var _feedback: int = 0            # -1 wrong, 0 none, +1 right
var _feedback_timer: float = 0.0
var _feedback_at: Vector2 = Vector2.ZERO


## Radius the glyphs are laid out on. The ONE definition; both the layout and
## the timer arc read it, so they cannot drift apart.
func ring_radius() -> float:
	return field_unit() * RING_FRACTION


## Radius of a single glyph.
func glyph_radius() -> float:
	return field_unit() * GLYPH_FRACTION


func _configure_bracket(b: int) -> void:
	_glyph_count = GLYPH_COUNTS[b]
	_window = WINDOWS[b]
	_delta = DELTAS[b]
	set_round_count(ROUNDS)


func begin() -> void:
	super()
	set_process(true)
	_next_round()


func _next_round() -> void:
	clear_targets()
	_positions.clear()

	var centre: Vector2 = field_centre()
	var radius: float = ring_radius()
	var glyph_r: float = glyph_radius()

	# Ring layout with a deterministic jitter so it never looks mechanical.
	for i: int in range(_glyph_count):
		var angle: float = TAU * float(i) / float(_glyph_count) - PI * 0.5
		var wobble: float = _rng.randf_range(-0.06, 0.06)
		var dist: float = radius * (1.0 + _rng.randf_range(-0.12, 0.12))
		_positions.append(centre + Vector2(cos(angle + wobble), sin(angle + wobble)) * dist)

	# A fresh window is not urgent. Clearing here means the tick stops the
	# instant the round resolves, rather than running on into the next one.
	if _urgency_reported:
		_urgency_reported = false
		Bus.trial_urgency_changed.emit(false)

	_anomaly_index = _rng.randi_range(0, _glyph_count - 1)
	_anomaly_kind = Anomaly.values()[_rng.randi_range(0, Anomaly.size() - 1)]
	_time_left = _window

	# One hit target per glyph. Nothing else in this node takes input.
	for i: int in range(_positions.size()):
		var index: int = i
		var rect: Rect2 = Rect2(
			_positions[i] - Vector2(glyph_r, glyph_r) * 1.6,
			Vector2(glyph_r, glyph_r) * 3.2)
		make_target(rect, func() -> void: _on_glyph_tapped(index))

	# The round is answerable the moment its targets exist. Without this the
	# base class has no stimulus to time against and logs "answer submitted
	# with no live stimulus" on every single answer.
	mark_stimulus()
	queue_redraw()


## Announce the urgency EDGE, never per frame.
##
## The urgency state used to live only inside _draw(), where it tinted the arc
## red. Nothing outside could see it, so the one moment in the game with real
## time pressure was silent. Emitting on the transition keeps the Bus quiet:
## two signals per round rather than sixty a second.
func _report_urgency() -> void:
	if _window <= 0.0:
		return
	var fraction: float = clampf(_time_left / _window, 0.0, 1.0)
	var urgent: bool = fraction < URGENCY_FRACTION and is_running()
	if urgent != _urgency_reported:
		_urgency_reported = urgent
		Bus.trial_urgency_changed.emit(urgent)


func _on_glyph_tapped(index: int) -> void:
	if not is_running() or _time_left <= 0.0:
		return
	var correct: bool = index == _anomaly_index
	_feedback = 1 if correct else -1
	_feedback_timer = 0.45
	HapticsManager.pulse(&"facet_match" if correct else &"error")
	_feedback_at = _positions[index]
	clear_targets()   # no double-answering a resolved round
	submit(correct, false)
	if is_running():
		_next_round()


func _process(delta: float) -> void:
	if _feedback_timer > 0.0:
		_feedback_timer -= delta
		if _feedback_timer <= 0.0:
			_feedback = 0
		queue_redraw()

	if not is_running():
		return

	_time_left -= delta
	_report_urgency()
	if _time_left <= 0.0:
		# Timeout counts as a miss, then advances.
		_feedback = -1
		_feedback_timer = 0.35
		_feedback_at = _positions[_anomaly_index] if _positions.size() > 0 else field_centre()
		clear_targets()
		# A timeout is a MISS, not a slow answer: flagged so the base class
		# records it as such instead of inventing a latency.
		submit(false, true)
		if is_running():
			_next_round()
	queue_redraw()


func _draw() -> void:
	var glyph_r: float = glyph_radius()
	var accent: Color = Palette.accent()

	# Timer arc, drawn JUST OUTSIDE the glyph ring it times.
	#
	# TWO WRONG VERSIONS PRECEDED THIS ONE.
	#
	# First it was `field_unit() * 0.44`. field_unit() is min(w, h), which on a
	# portrait field is the WIDTH — a 1059x1408 field gave a 466px radius and
	# the arc ran off both screen edges.
	#
	# Then I "fixed" it by fitting the arc to the FIELD RECT, which produced
	# 504px: BIGGER than the bug it replaced. Fitting the field proves nothing,
	# because the field is 1408px tall and taller than anything the player can
	# see at once.
	#
	# The arc belongs to the GLYPH RING, not to the field. RING_FRACTION is the
	# radius the glyphs are laid out on, so the arc sits one glyph-width
	# outside that and is correct at any field shape by construction.
	if is_running() and _window > 0.0:
		var fraction: float = clampf(_time_left / _window, 0.0, 1.0)
		var urgent: bool = fraction < URGENCY_FRACTION
		var timer_col: Color = Palette.danger() if urgent else accent
		var stroke: float = maxf(field_unit() * 0.010, 2.0)
		var ring_r: float = ring_radius() + glyph_r * 1.35
		draw_arc(field_centre(), ring_r, -PI * 0.5,
			-PI * 0.5 + TAU * fraction, 64, Color(timer_col, 0.75),
			stroke, true)

	for i: int in range(_positions.size()):
		var is_anomaly: bool = i == _anomaly_index
		_draw_glyph(_positions[i], glyph_r, accent, is_anomaly)

	# Feedback pulse at the tapped location.
	if _feedback != 0:
		var col: Color = Palette.success() if _feedback > 0 else Palette.danger()
		var alpha: float = clampf(_feedback_timer / 0.45, 0.0, 1.0)
		draw_arc(_feedback_at, glyph_r * 2.0, 0.0, TAU, 32,
			Color(col, alpha * 0.9), maxf(field_unit() * 0.010, 2.0), true)


## A miniature iris. The anomaly differs in exactly one property, by _delta.
func _draw_glyph(centre: Vector2, radius: float, accent: Color, anomalous: bool) -> void:
	# Ring count comes from the player's rank rather than a fixed 3, so a
	# high-rank glyph is visibly more intricate. The ANOMALY DELTA below is
	# unchanged and still relative to this baseline, so the puzzle is exactly
	# as hard as before — only the drawing is richer.
	var base_rings: int = recipe.rings if recipe != null else 3
	var rings: int = base_rings
	var pupil_scale: float = 0.34
	var tilt: float = 0.0
	var fleck_angle: float = PI * 0.25

	if anomalous:
		match _anomaly_kind:
			Anomaly.RINGS:
				rings = base_rings + maxi(int(round(_delta * 4.0)), 1)
			Anomaly.PUPIL:
				pupil_scale = 0.34 + _delta * 0.45
			Anomaly.TILT:
				tilt = _delta * 0.9
			Anomaly.FLECK:
				fleck_angle = PI * 1.25

	# Outer limbus.
	draw_arc(centre, radius, 0.0, TAU, 28, Color(accent, 0.85),
		maxf(radius * 0.10, 1.5), true)

	# Concentric stroma rings.
	for r: int in range(rings):
		var t: float = float(r + 1) / float(rings + 1)
		draw_arc(centre, radius * t * 0.9, tilt, TAU + tilt, 24,
			Color(accent, 0.38), maxf(radius * 0.05, 1.0), true)

	# Pupil.
	draw_circle(centre, radius * pupil_scale, Palette.COLOR_PUPIL)

	# Single fleck — the subtlest anomaly cue.
	var fleck: Vector2 = centre + Vector2(cos(fleck_angle), sin(fleck_angle)) * radius * 0.62
	draw_circle(fleck, radius * 0.14, Color(accent, 0.9))

	# Catchlight, so each glyph reads as an eye rather than a target.
	draw_circle(centre - Vector2(radius * 0.22, radius * 0.26), radius * 0.11,
		Palette.COLOR_CATCHLIGHT)
