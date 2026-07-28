extends Control
class_name VisionRenderer
## VisionRenderer — draws a destination glyph inside the Iris pupil.
##
## PHASE 2. Consumes the Phase 1 shape recipes (data/vision_glyph.gd) and
## renders them with _draw(). Owns no state and decides nothing: it is handed
## a glyph and a reveal amount, and draws exactly that.
##
## WHY _draw() AND NOT A TEXTURE
## v1 mounted a TextureRect and masked it with an inline circle shader. This
## project ships no images (rule 9, enforced by Rule F), so the symbol is
## vector primitives scaled from a normalised [-1, 1] space to whatever pixel
## radius the pupil currently has. That also means the glyph is sharp at every
## eye size — the hub eye ranges from 112px to 520px across the viewports the
## polish audit exercises.
##
## THE CIRCLE MASK
## v1 needed a mask shader because a rectangular texture had to be clipped to
## the pupil. Drawing primitives directly makes the mask unnecessary for
## CORRECTNESS — nothing is drawn outside the disc, and Phase 1's checks
## assert every shape fits within radius 1.0. The soft edge below is therefore
## presentation, not clipping: it fades the outer 12% so a glyph reads as
## suspended in the pupil rather than pasted on top of it.

## Outer fraction of the disc over which the glyph fades out.
const EDGE_SOFTNESS: float = 0.12

## Arc/ring segment count. 48 is smooth at 520px and cheap at 112px.
const CIRCLE_SEGMENTS: int = 48

var _glyph: VisionGlyph = null
var _reveal: float = 0.0
var _tint: Color = Color.WHITE
var _radius: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Show a glyph. `radius` is the pupil disc radius in pixels.
func set_glyph(glyph: VisionGlyph, tint: Color, radius: float) -> void:
	_glyph = glyph
	_tint = tint
	_radius = maxf(radius, 0.0)
	queue_redraw()


## 0..1 reveal. Driven by the controller's tween, never by this node — the
## renderer stays a pure function of what it was handed.
func set_reveal(value: float) -> void:
	var clamped: float = clampf(value, 0.0, 1.0)
	if is_equal_approx(clamped, _reveal):
		return
	_reveal = clamped
	queue_redraw()


func reveal() -> float:
	return _reveal


func has_glyph() -> bool:
	return _glyph != null


# ═════════════════════════════════════════════════════════════════════════
# DRAWING
# ═════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	# Positive guard rather than an early return: all three absences are
	# ordinary states (no glyph before the first hover, zero reveal mid
	# fade-out, zero radius before layout), so there is nothing to report.
	if not _drawable():
		return
	var centre: Vector2 = size * 0.5
	# The v1 contract scales from SCALE_FROM to 1.0 as the glyph reveals, so
	# the symbol arrives with a slight push rather than simply appearing.
	var grow: float = lerpf(VisionGlyph.SCALE_FROM, 1.0, _reveal)
	var unit: float = _radius * grow

	for shape: Dictionary in _glyph.shapes:
		_draw_shape(shape, centre, unit)


## True when there is something meaningful to paint.
func _drawable() -> bool:
	return _glyph != null and _reveal > 0.001 and _radius > 0.0


func _draw_shape(shape: Dictionary, centre: Vector2, unit: float) -> void:
	var kind: int = int(shape.get("kind", -1))
	match kind:
		VisionGlyph.Shape.RING:
			var r: float = float(shape.get("radius", 0.0)) * unit
			draw_arc(centre, r, 0.0, TAU, CIRCLE_SEGMENTS,
				_colour_at(float(shape.get("radius", 0.0))),
				_thickness(shape, unit), true)

		VisionGlyph.Shape.DISC:
			var dr: float = float(shape.get("radius", 0.0)) * unit
			draw_circle(centre, dr, _colour_at(float(shape.get("radius", 0.0))))

		VisionGlyph.Shape.BAR:
			var local_centre: Vector2 = shape.get("centre", Vector2.ZERO)
			var half: Vector2 = shape.get("half", Vector2.ZERO)
			# Y is inverted: the recipes are authored in maths orientation
			# (up is positive) and the screen is not.
			var rect := Rect2(
				centre + Vector2(local_centre.x - half.x,
					-local_centre.y - half.y) * unit,
				half * 2.0 * unit)
			draw_rect(rect, _colour_at(local_centre.length()), true)

		VisionGlyph.Shape.SPOKE:
			var angle: float = float(shape.get("angle", 0.0))
			var inner: float = float(shape.get("inner", 0.0)) * unit
			var outer: float = float(shape.get("outer", 0.0)) * unit
			var dir := Vector2(cos(angle), sin(angle))
			draw_line(centre + dir * inner, centre + dir * outer,
				_colour_at(float(shape.get("outer", 0.0))),
				_thickness(shape, unit), true)

		VisionGlyph.Shape.POLYGON:
			_draw_polygon_outline(shape, centre, unit)

		VisionGlyph.Shape.ARC:
			var ar: float = float(shape.get("radius", 0.0)) * unit
			var start: float = float(shape.get("start", 0.0))
			var sweep: float = float(shape.get("sweep", TAU))
			draw_arc(centre, ar, start, start + sweep, CIRCLE_SEGMENTS,
				_colour_at(float(shape.get("radius", 0.0))),
				_thickness(shape, unit), true)

		_:
			# An unknown kind draws nothing, which would be invisible on a
			# device and silent in a log. Say so.
			Log.warn("Vision", "unknown glyph shape kind %d" % kind)


func _draw_polygon_outline(shape: Dictionary, centre: Vector2,
		unit: float) -> void:
	var sides: int = maxi(int(shape.get("sides", 3)), 3)
	var radius: float = float(shape.get("radius", 0.0)) * unit
	var spin: float = float(shape.get("rotation", 0.0))
	var thickness: float = _thickness(shape, unit)
	var colour: Color = _colour_at(float(shape.get("radius", 0.0)))

	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(sides):
		var angle: float = spin + TAU * float(i) / float(sides)
		points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
	for i: int in range(sides):
		draw_line(points[i], points[(i + 1) % sides], colour, thickness, true)


## Line width in pixels, floored so a glyph never disappears on a small eye.
##
## At the smallest viewport the polish audit exercises the eye is 112px, so
## the pupil disc is roughly 34px across; a 0.10 relative thickness there is
## 1.7px, which vanishes against the background. 1.5px is the floor at which
## a stroke stays legible.
func _thickness(shape: Dictionary, unit: float) -> float:
	return maxf(float(shape.get("thickness", 0.1)) * unit, 1.5)


## Tint at a given normalised radius, faded by reveal and by proximity to the
## disc edge.
func _colour_at(normalised_radius: float) -> Color:
	var edge_start: float = 1.0 - EDGE_SOFTNESS
	var edge_fade: float = 1.0
	if normalised_radius > edge_start:
		edge_fade = 1.0 - clampf(
			(normalised_radius - edge_start) / EDGE_SOFTNESS, 0.0, 1.0)
	var out: Color = _tint
	out.a = _tint.a * _reveal * maxf(edge_fade, 0.25)
	return out
