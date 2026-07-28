extends Control
class_name TrialFeedback

## TrialFeedback — the arcane success/failure flash over the trial play field.
##
## Two responses, deliberately different in KIND rather than just in colour:
##
##   SUCCESS   an expanding cyan energy pulse — concentric rings racing
##             outward from the answered point and fading as they go.
##
##   FAILURE   a chromatic abrasion — the red and blue channels torn a few
##             pixels apart across horizontal bands, the way a damaged sensor
##             smears. Subtle by intent: the brief asked for abrasion, not a
##             glitch effect, and a punishing full-screen flash on a cognitive
##             trainer teaches players to stop playing.
##
## WHY NOT JUST TINT THE SCREEN GREEN AND RED
## Roughly 1 in 12 men cannot separate those two hues. The pulse and the
## abrasion differ in geometry and motion, so the feedback survives being
## rendered in a single colour — the same reason Palette carries COLOR_*_CB
## variants.
##
## NON-DESTRUCTIVE. This is an overlay sibling of the play field that never
## accepts input and holds no game state. It is told what happened; it does
## not decide, score, or route. Remove it and the trial plays identically.
##
## ZERO ASSETS. Rings and bands are _draw() geometry.

## What is currently playing.
enum Mode {
	IDLE = 0,
	SUCCESS = 1,
	FAILURE = 2,
}

var _mode: Mode = Mode.IDLE
## 0..1 through the current effect.
var _phase: float = 0.0
## Where the effect is centred, in this control's local space.
var _origin: Vector2 = Vector2.ZERO
## Deterministic jitter for the abrasion bands, reseeded per failure so two
## consecutive misses do not tear identically.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _band_offsets: Array[float] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(false)


func _process(delta: float) -> void:
	var span: float = _duration()
	if span <= 0.0:
		_stop()
		return
	_phase += delta / span
	if _phase >= 1.0:
		_stop()
		return
	queue_redraw()


func _duration() -> float:
	match _mode:
		Mode.SUCCESS:
			return Palette.duration(Palette.FEEDBACK_PULSE_SEC)
		Mode.FAILURE:
			return Palette.duration(Palette.FEEDBACK_ABRASION_SEC)
		_:
			return 0.0


func _stop() -> void:
	_mode = Mode.IDLE
	_phase = 0.0
	set_process(false)
	queue_redraw()


# ═════════════════════════════════════════════════════════════════════════
# TRIGGERS
# ═════════════════════════════════════════════════════════════════════════
## Play the response for one answer.
##
## `at` is in this control's LOCAL space. Passing an out-of-rect point is not
## an error — a stimulus can legitimately sit near the edge — so it is clamped
## into the field rather than rejected.
func play(correct: bool, at: Vector2) -> void:
	_origin = Vector2(
		clampf(at.x, 0.0, maxf(size.x, 1.0)),
		clampf(at.y, 0.0, maxf(size.y, 1.0)))
	_mode = Mode.SUCCESS if correct else Mode.FAILURE
	_phase = 0.0

	if not correct:
		_reseed_bands()

	# Reduced motion still gets feedback — losing it entirely would remove
	# the answer confirmation, not just the animation — but it resolves to a
	# single static frame at the effect's midpoint instead of animating.
	if Palette.reduced_motion():
		_phase = 0.5
		set_process(false)
		queue_redraw()
		return

	set_process(true)
	queue_redraw()


## Centre the next effect on the field's middle. For modes with no meaningful
## per-answer position, such as a recalled sequence.
func play_centred(correct: bool) -> void:
	play(correct, size * 0.5)


## What is playing right now. Exposed so a test can prove a wrong answer
## produces FAILURE rather than merely proving play() was reachable.
func mode() -> Mode:
	return _mode


func phase() -> float:
	return _phase


func is_playing() -> bool:
	return _mode != Mode.IDLE


func origin() -> Vector2:
	return _origin


func _reseed_bands() -> void:
	_rng.seed = Time.get_ticks_usec()
	_band_offsets.clear()
	for _i: int in range(Palette.FEEDBACK_ABRASION_BANDS):
		_band_offsets.append(_rng.randf_range(-1.0, 1.0))


# ═════════════════════════════════════════════════════════════════════════
# DRAWING
# ═════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	if _mode == Mode.IDLE:
		return
	if size.x <= 1.0 or size.y <= 1.0:
		return
	match _mode:
		Mode.SUCCESS:
			_draw_pulse()
		Mode.FAILURE:
			_draw_abrasion()
		_:
			pass


## Concentric rings racing outward and fading. Each ring is offset in phase so
## they read as a travelling wavefront rather than one thick expanding band.
func _draw_pulse() -> void:
	var unit: float = minf(size.x, size.y)
	var accent: Color = Palette.accent()
	var reach: float = unit * Palette.FEEDBACK_PULSE_REACH

	for ring: int in range(Palette.FEEDBACK_PULSE_RINGS):
		var lag: float = float(ring) * 0.16
		var t: float = _phase - lag
		if t <= 0.0 or t >= 1.0:
			continue
		# Ease-out: the wave is fastest at the instant of the answer, which is
		# what makes it read as released energy rather than a growing circle.
		var eased: float = 1.0 - pow(1.0 - t, 2.4)
		var radius: float = reach * eased
		var fade: float = (1.0 - t) * Palette.FEEDBACK_PULSE_ALPHA
		var colour: Color = accent
		colour.a = fade
		draw_arc(_origin, maxf(radius, 1.0), 0.0, TAU, 64, colour,
			maxf(unit * 0.010 * (1.0 - t * 0.5), 1.0), true)

	# Core flash at the answered point, brightest at the start.
	var core_fade: float = maxf(1.0 - _phase * 2.4, 0.0)
	if core_fade > 0.0:
		var core: Color = accent
		core.a = core_fade * Palette.FEEDBACK_PULSE_ALPHA
		draw_circle(_origin, unit * 0.045 * (1.0 + _phase), core)


## Red and blue channels pulled apart along thin tear lines near the answer.
##
## THIS WAS REBUILT AFTER SEEING IT RENDERED.
##
## The first version filled each band with a half-height rectangle at up to
## 0.30 alpha across the FULL WIDTH of the play field. Ported to CPU and drawn,
## it covered the entire screen in solid red and cyan stripes — a full-screen
## glitch effect, and the exact opposite of the "subtle chromatic abrasion" the
## brief asked for. It would also have obscured the very stimulus the player
## was being asked to read.
##
## Real chromatic aberration is an EDGE artefact: it fringes boundaries, it
## does not flood areas. So this now draws THIN LINES — a few scan tears near
## the answered point, each a warm and a cool stroke offset against each other
## — and leaves the rest of the field untouched.
func _draw_abrasion() -> void:
	var unit: float = minf(size.x, size.y)
	# Rise fast, fall slow — a tear that fades is damage; one that pops on and
	# off is a strobe.
	var strength: float = sin(clampf(_phase, 0.0, 1.0) * PI)
	var spread: float = unit * Palette.FEEDBACK_ABRASION_SPREAD * strength
	var alpha: float = Palette.FEEDBACK_ABRASION_ALPHA * strength

	var bands: int = Palette.FEEDBACK_ABRASION_BANDS
	# The tears are confined to a band around the answered point rather than
	# spread over the whole field, so the damage clearly belongs to the thing
	# the player just touched.
	var span: float = unit * Palette.FEEDBACK_ABRASION_REACH
	var line_w: float = maxf(unit * Palette.FEEDBACK_ABRASION_LINE, 1.0)
	# A tear is a short streak, not a full-width rule.
	var half_len: float = size.x * Palette.FEEDBACK_ABRASION_LENGTH * 0.5

	var warm: Color = Palette.danger()
	var cool: Color = Palette.accent()

	for i: int in range(bands):
		var offset: float = 0.0
		if i < _band_offsets.size():
			offset = _band_offsets[i]
		var shift: float = spread * offset
		# Distribute the tears through the band, biased toward the centre.
		var t: float = (float(i) / float(maxi(bands - 1, 1))) * 2.0 - 1.0
		var y: float = _origin.y + t * span

		# Fade with distance from the answered point.
		var local: float = clampf(1.0 - absf(t), 0.0, 1.0)
		if local <= 0.01:
			continue

		var line_alpha: float = alpha * local
		warm.a = line_alpha
		cool.a = line_alpha
		var x0: float = _origin.x - half_len * (0.5 + local * 0.5)
		var x1: float = _origin.x + half_len * (0.5 + local * 0.5)

		# The two channels, offset against each other. Where they overlap the
		# result fringes; where they do not, each edge shows its own colour.
		draw_line(Vector2(x0 + shift, y), Vector2(x1 + shift, y),
			warm, line_w, true)
		draw_line(Vector2(x0 - shift, y + line_w), Vector2(x1 - shift, y + line_w),
			cool, line_w, true)

	# A short dark seam through the answered point, so the tear has a centre.
	var seam: Color = Palette.COLOR_BACKGROUND
	seam.a = alpha * 0.7
	draw_line(Vector2(_origin.x - half_len, _origin.y),
		Vector2(_origin.x + half_len, _origin.y), seam, line_w * 1.6, true)
