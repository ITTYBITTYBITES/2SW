extends Control
class_name Atmosphere

## Atmosphere — the dark vignette and drifting dust behind every screen.
##
## Two passes, both procedural:
##
##   VIGNETTE   concentric translucent rings darkening toward the edges, so
##              the frame falls away and the centre carries the eye. A flat
##              background makes every screen read as a document; a vignette
##              makes it read as a space.
##
##   MOTES      slow teal particles on deterministic paths. They give the
##              dark an implied depth and, more practically, they move — a
##              perfectly static backdrop reads as a frozen app on a phone
##              where everything else animates.
##
## ZERO ASSETS. Circles and arcs from _draw(), positions from a hash so the
## field is identical every launch rather than reshuffling (v1's freckles
## moved on every boot, which players noticed and disliked).
##
## COST. One _draw() per frame over MOTE_COUNT circles plus VIGNETTE_RINGS
## arcs. At 34 motes that is well under a millisecond on the mobile GPUs this
## targets, and there is no second viewport, no blur pass and no particle
## system allocation.

## Dust motes. Enough to read as a field, few enough to stay cheap.
const MOTE_COUNT: int = 34

## Vignette resolution. More rings is smoother; 12 is below the banding
## threshold at phone sizes.
const VIGNETTE_RINGS: int = 12

## How far the vignette reaches inward, as a fraction of the short side.
const VIGNETTE_INNER: float = 0.55
const VIGNETTE_ALPHA: float = 0.16

## Mote drift, in screen-heights per second. Slow enough to be subliminal.
const DRIFT_SPEED: float = 0.012

## Mote radius range, as a fraction of the short side.
const MOTE_MIN: float = 0.0016
const MOTE_MAX: float = 0.0052

var _time: float = 0.0
var _motes: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seed_motes()
	# Reduced motion freezes the drift but keeps the field: the atmosphere is
	# depth, not animation, and removing it entirely would flatten the app
	# for the players who need that setting.
	set_process(not Palette.reduced_motion())


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


## Deterministic placement. Same field on every launch, forever.
func _seed_motes() -> void:
	_motes.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = MOTE_SEED
	for i: int in range(MOTE_COUNT):
		_motes.append({
			"x": rng.randf(),
			"y": rng.randf(),
			"radius": rng.randf_range(MOTE_MIN, MOTE_MAX),
			"speed": rng.randf_range(0.4, 1.6),
			"phase": rng.randf() * TAU,
			"alpha": rng.randf_range(0.10, 0.42),
		})


## Fixed so the dust never reshuffles between sessions.
const MOTE_SEED: int = 0x2517


func _draw() -> void:
	var short_side: float = minf(size.x, size.y)
	if short_side <= 1.0:
		return
	_draw_vignette()
	_draw_motes(short_side)


## Darken toward the edges with nested rounded rings.
func _draw_vignette() -> void:
	var centre: Vector2 = size * 0.5
	var max_reach: float = size.length() * 0.5
	var inner: float = minf(size.x, size.y) * VIGNETTE_INNER

	for i: int in range(VIGNETTE_RINGS):
		var t: float = float(i) / float(VIGNETTE_RINGS - 1)
		var radius: float = lerpf(inner, max_reach, t)
		var shade: Color = Palette.COLOR_BACKGROUND
		# Quadratic so the darkening accelerates outward rather than
		# stepping evenly, which is what a real vignette does.
		shade.a = VIGNETTE_ALPHA * t * t
		draw_arc(centre, radius, 0.0, TAU, 48, shade,
			(max_reach - inner) / float(VIGNETTE_RINGS) * 2.4, true)


## Floating teal dust.
func _draw_motes(short_side: float) -> void:
	var accent: Color = Palette.accent()
	for mote: Dictionary in _motes:
		var speed: float = float(mote["speed"])
		var phase: float = float(mote["phase"])
		# Rise slowly and wander sideways; wrap at the top.
		var y: float = fposmod(
			float(mote["y"]) - _time * DRIFT_SPEED * speed, 1.0)
		var sway: float = sin(_time * 0.22 * speed + phase) * 0.014
		var pos := Vector2((float(mote["x"]) + sway) * size.x, y * size.y)

		# Breathe the opacity so the field shimmers rather than sliding as a
		# rigid pattern.
		var pulse: float = 0.65 + 0.35 * sin(_time * 0.7 * speed + phase)
		var tint: Color = accent
		tint.a = float(mote["alpha"]) * pulse

		var radius: float = float(mote["radius"]) * short_side
		draw_circle(pos, radius, tint)
		# A faint halo gives each mote a soft edge without a blur pass.
		tint.a *= 0.22
		draw_circle(pos, radius * 2.6, tint)


## Re-seed and repaint after a palette change.
func refresh() -> void:
	set_process(not Palette.reduced_motion())
	queue_redraw()
