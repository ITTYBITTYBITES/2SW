extends Control
class_name SplashVisuals
## SplashVisuals — the three procedural marks used by the startup sequence.
##
## PHASE 12. All vector maths, zero assets. v1's equivalent was a 12 MB
## branding PNG that rendered at roughly a tenth of its native size.
##
## One script with a `kind` switch rather than three near-identical files:
## they share the same breathing/glow vocabulary, and keeping them together is
## what stops the ident and the title drifting apart visually.

enum Kind {
	SPONSOR_MARK = 0,   # ITTYBITTYBITES: nested geometric aperture
	MONOGRAM = 1,       # 2SW lettermark
	IRIS_PROGRESS = 2,  # miniature eye that opens as loading advances
}

@export var kind: Kind = Kind.SPONSOR_MARK

## Draw as a dim ambient underlay rather than as the centerpiece.
##
## The sponsor aperture and the 2SW monogram now have baked carved-metal
## centerpieces drawn over them (ui/splash_plate.gd). The vector marks are NOT
## deleted — they still supply the motion the still art cannot: the aperture's
## counter-rotating rings and the monogram's pulse keep breathing behind the
## plate, visible in the gaps and around the rim.
##
## Without this they would draw at full strength UNDERNEATH an opaque plate:
## invisible where it covers them, and a competing bright shape everywhere it
## does not. At UNDERLAY_ALPHA they read as light spilling from behind forged
## metal, which is the effect the reference has.
##
## The iris progress mark never sets this. It is the loading readout and stays
## the primary, fully-lit element.
@export var underlay: bool = false

## How much of its normal strength an underlay mark draws at.
const UNDERLAY_ALPHA: float = 0.30

var _time: float = 0.0
var _progress: float = 0.0
var _shown_progress: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(not Palette.reduced_motion())


func _process(delta: float) -> void:
	_time += delta
	# Ease the displayed progress so a step completing does not snap the eye.
	_shown_progress = lerpf(_shown_progress, _progress,
		clampf(delta * 4.0, 0.0, 1.0))
	queue_redraw()


func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)
	if Palette.reduced_motion():
		_shown_progress = _progress
	queue_redraw()


func _draw() -> void:
	# Nothing sensible to draw before the container has sized us.
	if size.x <= 1.0 or size.y <= 1.0:
		return
	# An underlay mark fades WHOLESALE via the canvas item's modulate rather
	# than by threading an alpha through forty draw calls. One multiply, and
	# no chance of a stroke being missed and left at full strength.
	self_modulate.a = UNDERLAY_ALPHA if underlay else 1.0
	match kind:
		Kind.SPONSOR_MARK:
			_draw_sponsor_mark()
		Kind.MONOGRAM:
			_draw_monogram()
		Kind.IRIS_PROGRESS:
			_draw_iris_progress()


## The short edge of THIS control's real rect. Every mark scales from it, so
## the drawing is identical at any resolution or aspect ratio.
##
## Guards against a zero/degenerate size: containers report (0,0) for a frame
## before their first sort, and dividing by that produces NaN geometry that
## Godot silently drops — the mark simply never appears.
func _unit() -> float:
	var shortest: float = minf(size.x, size.y)
	if shortest <= 1.0:
		return 1.0
	return shortest


## Dead centre of this control's own rect, never the viewport's. The parent
## container decides where the control sits; the mark only ever centres itself
## inside whatever box it is given.
func _centre() -> Vector2:
	return size * 0.5


## Redraw when the container resizes, otherwise the mark keeps the geometry it
## had at its first (often zero) size.
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


# ═════════════════════════════════════════════════════════════════════════
# SPONSOR MARK
# ═════════════════════════════════════════════════════════════════════════
## Nested rotating polygons narrowing to a bright core — an aperture, echoing
## the Iris the whole game is built around. A studio mark that rhymes with the
## product reads as intentional rather than generic.
func _draw_sponsor_mark() -> void:
	var centre: Vector2 = _centre()
	var unit: float = _unit()
	var accent: Color = Palette.accent()
	var breathe: float = 1.0 + sin(_time * 1.15) * 0.03

	# Outer halo.
	draw_circle(centre, unit * 0.46 * breathe, Color(accent, 0.05))

	# Four nested hexagons, each rotated against the last so the negative
	# space forms a spiralling aperture.
	for ring: int in range(4):
		var t: float = float(ring) / 3.0
		var radius: float = unit * lerpf(0.40, 0.14, t) * breathe
		var spin: float = _time * 0.18 * (1.0 if ring % 2 == 0 else -1.0)
		spin += float(ring) * 0.26
		var alpha: float = lerpf(0.30, 0.85, t)
		var width: float = maxf(unit * lerpf(0.010, 0.018, t), 1.5)

		var points: PackedVector2Array = PackedVector2Array()
		for i: int in range(7):
			var angle: float = TAU * float(i) / 6.0 + spin
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
		draw_polyline(points, Color(accent, alpha), width, true)

	# Bright core with a catchlight, so the mark reads as lit rather than flat.
	draw_circle(centre, unit * 0.055 * breathe, Color(accent, 0.95))
	draw_circle(centre - Vector2(unit * 0.018, unit * 0.020), unit * 0.016,
		Palette.COLOR_CATCHLIGHT)

	# Orbiting motes.
	for i: int in range(3):
		var angle: float = _time * 0.5 + TAU * float(i) / 3.0
		var orbit: Vector2 = centre + Vector2(cos(angle), sin(angle)) * unit * 0.44
		draw_circle(orbit, unit * 0.010, Color(accent, 0.7))


# ═════════════════════════════════════════════════════════════════════════
# 2SW MONOGRAM
# ═════════════════════════════════════════════════════════════════════════
## "2SW" drawn as strokes rather than text, so it is crisp at any density and
## can carry the same glow treatment as the Iris.
func _draw_monogram() -> void:
	var centre: Vector2 = _centre()
	var unit: float = _unit()
	var accent: Color = Palette.accent()
	var height: float = unit * 0.34
	var width: float = height * 0.62
	var gap: float = width * 0.42
	var thickness: float = maxf(height * 0.11, 3.0)
	var total: float = width * 3.0 + gap * 2.0
	var left: float = centre.x - total * 0.5
	var top: float = centre.y - height * 0.5

	var glow: float = 0.35 + 0.12 * sin(_time * 1.4)

	# Glow pass beneath the core strokes — a cheap bloom without a shader.
	_stroke_two(left, top, width, height, Color(accent, glow), thickness * 2.4)
	_stroke_s(left + width + gap, top, width, height, Color(accent, glow), thickness * 2.4)
	_stroke_w(left + (width + gap) * 2.0, top, width, height, Color(accent, glow), thickness * 2.4)

	_stroke_two(left, top, width, height, Color(accent, 0.98), thickness)
	_stroke_s(left + width + gap, top, width, height, Color(accent, 0.98), thickness)
	_stroke_w(left + (width + gap) * 2.0, top, width, height, Color(accent, 0.98), thickness)


func _stroke_two(x: float, y: float, w: float, h: float,
		colour: Color, thickness: float) -> void:
	var points: PackedVector2Array = PackedVector2Array([
		Vector2(x + w * 0.08, y + h * 0.22),
		Vector2(x + w * 0.50, y),
		Vector2(x + w * 0.94, y + h * 0.24),
		Vector2(x + w * 0.10, y + h),
		Vector2(x + w, y + h),
	])
	draw_polyline(points, colour, thickness, true)


func _stroke_s(x: float, y: float, w: float, h: float,
		colour: Color, thickness: float) -> void:
	var points: PackedVector2Array = PackedVector2Array([
		Vector2(x + w * 0.94, y + h * 0.14),
		Vector2(x + w * 0.34, y),
		Vector2(x + w * 0.04, y + h * 0.26),
		Vector2(x + w * 0.62, y + h * 0.50),
		Vector2(x + w * 0.96, y + h * 0.74),
		Vector2(x + w * 0.62, y + h),
		Vector2(x + w * 0.04, y + h * 0.88),
	])
	draw_polyline(points, colour, thickness, true)


func _stroke_w(x: float, y: float, w: float, h: float,
		colour: Color, thickness: float) -> void:
	var points: PackedVector2Array = PackedVector2Array([
		Vector2(x, y),
		Vector2(x + w * 0.24, y + h),
		Vector2(x + w * 0.50, y + h * 0.42),
		Vector2(x + w * 0.76, y + h),
		Vector2(x + w, y),
	])
	draw_polyline(points, colour, thickness, true)


# ═════════════════════════════════════════════════════════════════════════
# IRIS PROGRESS
# ═════════════════════════════════════════════════════════════════════════
## A miniature eye that OPENS as loading advances, replacing a progress bar.
##
## The reading is unambiguous — a closed eye is 0%, a fully open one is 100% —
## and it introduces the Iris before the player reaches the hub, so the
## companion is established before it is ever explained.
## Mask the iris disc down to its aperture, without painting over the backdrop.
##
## Drawn as horizontal strips clipped to the disc's own width at each height,
## rather than as two full-width rectangles. Beyond the disc's radius nothing
## is drawn at all, so whatever sits behind the mark — the bloom, the motes,
## the vignette — is left untouched.
func _draw_lids(centre: Vector2, unit: float, aperture: float) -> void:
	# Cover the whole eye assembly: the socket glow reaches furthest.
	var disc: float = unit * LID_COVER
	var lid: Color = Palette.COLOR_BACKGROUND
	var step: float = maxf(unit * 0.006, 1.0)

	var offset: float = aperture
	while offset < disc:
		# Half-width of the disc at this distance from the centre line.
		var half: float = sqrt(maxf(disc * disc - offset * offset, 0.0))

		# Fade at BOTH ends of the mask, not just the outer rim.
		#
		# Feathering only the outside left the aperture edge fully opaque, so
		# the lid met the open eye on a hard line and the whole mask read as a
		# solid dome laid over the screen rather than as a lid closing over an
		# eye. Rendering it from live state is what made that obvious.
		var outer: float = clampf((disc - offset) / (disc * LID_FEATHER), 0.0, 1.0)
		var inner: float = clampf((offset - aperture) / (disc * LID_SOFTEN),
			0.0, 1.0)
		lid.a = outer * inner
		draw_rect(Rect2(
			Vector2(centre.x - half, centre.y - offset - step),
			Vector2(half * 2.0, step)), lid)
		draw_rect(Rect2(
			Vector2(centre.x - half, centre.y + offset),
			Vector2(half * 2.0, step)), lid)
		offset += step


## How far the lid mask reaches, as a fraction of the short side. Must cover
## the socket glow at 0.40 plus the progress arc at 0.44.
const LID_COVER: float = 0.48
## Fraction of the mask's reach spent fading out at the rim.
const LID_FEATHER: float = 0.22
## Fraction spent ramping UP from the aperture edge, so the lid does not meet
## the open eye on a hard line.
const LID_SOFTEN: float = 0.16


func _draw_iris_progress() -> void:
	var centre: Vector2 = _centre()
	var unit: float = _unit()
	var accent: Color = Palette.accent()
	var open: float = ease(_shown_progress, 0.65)

	# Socket glow widens as it wakes.
	draw_circle(centre, unit * 0.40 * (0.6 + 0.4 * open), Color(accent, 0.05))

	# Stroma rings, brightening with progress.
	var iris_radius: float = unit * 0.26
	for i: int in range(6):
		var t: float = float(i) / 5.0
		var radius: float = iris_radius * lerpf(0.30, 1.0, t)
		var alpha: float = lerpf(0.40, 0.06, t) * open
		draw_arc(centre, radius, 0.0, TAU, 48, Color(accent, alpha),
			maxf(unit * 0.008, 1.2), true)

	# Pupil dilates as it opens, with a slow breath.
	var breath: float = 1.0 + sin(_time * 1.6) * 0.04
	var pupil: float = unit * lerpf(0.045, 0.095, open) * breath
	var pupil_colour: Color = Palette.COLOR_PUPIL
	pupil_colour.a = maxf(open, 0.25)
	draw_circle(centre, pupil, pupil_colour)

	# Eyelids: the aperture IS the progress readout.
	#
	# THESE MASK THE EYE, NOT THE SCREEN.
	#
	# They used to be two opaque COLOR_BACKGROUND rectangles spanning the whole
	# control. That was invisible while the backdrop behind them was a flat
	# fill of exactly that colour — but the moment a bloom was added behind the
	# splash, the lids punched a hard black box across it. Caught by rendering
	# the screen from live state; it is precisely the kind of fault a
	# node-state check cannot see.
	#
	# The lids only ever needed to hide the parts of the IRIS that fall outside
	# the aperture, and the iris is a disc. So the mask is that disc: each
	# strip is only as wide as the disc is at that height, and its alpha falls
	# away at the rim so the mask blends into whatever is behind rather than
	# ending on a visible circular edge.
	var aperture: float = unit * lerpf(0.012, 0.30, open)
	_draw_lids(centre, unit, aperture)

	# Lash lines soften the lid edge so it is not a hard vector cut.
	var half_width: float = unit * 0.36
	draw_line(Vector2(centre.x - half_width, centre.y - aperture),
		Vector2(centre.x + half_width, centre.y - aperture),
		Color(accent, 0.28 * open), maxf(unit * 0.006, 1.0), true)
	draw_line(Vector2(centre.x - half_width, centre.y + aperture),
		Vector2(centre.x + half_width, centre.y + aperture),
		Color(accent, 0.16 * open), maxf(unit * 0.006, 1.0), true)

	# Catchlight once open enough to read as wet.
	if open > 0.3:
		var glint: Color = Palette.COLOR_CATCHLIGHT
		glint.a = 0.55 * (open - 0.3) / 0.7
		draw_circle(centre + Vector2(-unit * 0.055, -unit * 0.065),
			unit * 0.028, glint)

	# Thin arc around the whole thing as a secondary numeric readout.
	if _shown_progress > 0.01:
		draw_arc(centre, unit * 0.44, -PI * 0.5,
			-PI * 0.5 + TAU * _shown_progress, 64,
			Color(accent, 0.55), maxf(unit * 0.008, 2.0), true)
