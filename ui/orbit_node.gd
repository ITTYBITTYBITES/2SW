extends Button
class_name OrbitNode
## OrbitNode — a glowing circular navigation node for the hub sidebars.
##
## The reference composition places its destinations as illuminated discs down
## the left and right edges rather than as a menu. This is that disc: a ring
## of accent light around a procedural glyph, with a caption beneath.
##
## ZERO ASSETS. The ring, glow and glyph are _draw() geometry scaled from the
## node's own radius, so one class serves every sidebar entry at any size.
##
## WHY A Button SUBCLASS
## Focus, hover, disabled state, keyboard navigation and the `pressed` signal
## are inherited rather than reimplemented. A Control with a gui_input handler
## would need all of that written by hand and would still miss accessibility
## affordances the engine gives away.
##
## EXTENSIBILITY
## Adding a destination is one call to HubSidebar.add_node(). The glyph comes
## from data/vision_glyph.gd — the SAME table the pupil hover preview reads —
## so a sidebar entry and its pupil vision can never show different symbols.

## Diameter of the disc. Comfortably past MIN_TOUCH_TARGET so the ring has
## room to breathe inside the tap area.
const DIAMETER: float = 68.0

## Ring thickness as a fraction of the radius.
const RING_FRAC: float = 0.085

## The glyph is drawn inside this fraction of the radius, leaving a margin
## between the symbol and the ring around it.
const GLYPH_FRAC: float = 0.52

## Outer glow, drawn as concentric fading rings.
const GLOW_RINGS: int = 6
const GLOW_REACH: float = 1.42
const GLOW_ALPHA: float = 0.10

## How much brighter the ring gets while hovered or focused.
const HOVER_LIFT: float = 0.38

var route: String = ""

var _glyph: VisionGlyph = null
var _caption: String = ""
var _lit: float = 0.0
var _lit_tween: Tween = null


func _ready() -> void:
	custom_minimum_size = Vector2(DIAMETER, DIAMETER)
	focus_mode = Control.FOCUS_ALL
	# The disc paints itself; the Button's own StyleBoxes would draw a
	# rectangle behind it.
	for slot: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(slot, StyleBoxEmpty.new())

	mouse_entered.connect(_on_lit_changed.bind(true))
	mouse_exited.connect(_on_lit_changed.bind(false))
	focus_entered.connect(_on_lit_changed.bind(true))
	focus_exited.connect(_on_lit_changed.bind(false))


func _exit_tree() -> void:
	if mouse_entered.is_connected(_on_lit_changed):
		mouse_entered.disconnect(_on_lit_changed)
	if mouse_exited.is_connected(_on_lit_changed):
		mouse_exited.disconnect(_on_lit_changed)
	if focus_entered.is_connected(_on_lit_changed):
		focus_entered.disconnect(_on_lit_changed)
	if focus_exited.is_connected(_on_lit_changed):
		focus_exited.disconnect(_on_lit_changed)


## Configure from a route name. The glyph is looked up in the shared roster,
## so this node and the pupil preview for the same destination always agree.
func configure(p_route: String, label_text: String) -> void:
	route = p_route
	_caption = label_text
	_glyph = VisionGlyph.for_route(p_route)
	tooltip_text = label_text
	queue_redraw()


func caption() -> String:
	return _caption


func _on_lit_changed(lit: bool) -> void:
	if _lit_tween != null and _lit_tween.is_running():
		_lit_tween.kill()
	var target: float = 1.0 if lit else 0.0
	# Snap instead of tweening when motion is reduced, or when Palette has no
	# script (a --script MainLoop). Both are ordinary states.
	var pal: Node = _palette()
	if pal != null and not bool(pal.call("reduced_motion")):
		_lit_tween = create_tween()
		_lit_tween.tween_method(_set_lit, _lit, target,
			float(pal.call("duration", 0.14)))
	else:
		_lit = target
		queue_redraw()


func _set_lit(value: float) -> void:
	_lit = value
	queue_redraw()


## The Palette autoload, or null when it has no script — which is the case
## under a --script MainLoop, where autoloads attach after compilation.
func _palette() -> Node:
	var pal: Node = get_tree().root.get_node_or_null("Palette")
	if pal == null or pal.get_script() == null:
		return null
	return pal


func _const(key: String, fallback: Variant) -> Variant:
	var pal: Node = _palette()
	if pal == null:
		return fallback
	return (pal.get_script() as GDScript).get_script_constant_map().get(key, fallback)


func _draw() -> void:
	var radius: float = minf(size.x, size.y) * 0.5
	if radius <= 1.0:
		return
	var centre: Vector2 = size * 0.5
	# Palette is absent under a --script MainLoop, where autoloads attach
	# after compilation. Drawing nothing then is correct, not an error.
	var pal: Node = _palette()
	if pal != null:
		_paint(centre, radius, pal.call("accent"))


func _paint(centre: Vector2, radius: float, accent: Color) -> void:
	if _glyph != null:
		accent.h = fposmod(accent.h + _glyph.hue_shift / 360.0, 1.0)

	_draw_glow(centre, radius, accent)
	_draw_disc(centre, radius, accent)
	_draw_glyph(centre, radius, accent)


## Soft halo, brightening on hover. Additive-looking without a second pass:
## each ring is faint enough that overlap reads as falloff rather than banding.
func _draw_glow(centre: Vector2, radius: float, accent: Color) -> void:
	for i: int in range(GLOW_RINGS):
		var t: float = float(i) / float(GLOW_RINGS - 1)
		var r: float = lerpf(1.0, GLOW_REACH, t) * radius
		var tint: Color = accent
		tint.a = GLOW_ALPHA * (1.0 - t) * (1.0 - t) * (1.0 + _lit * 1.6)
		draw_arc(centre, r, 0.0, TAU, 40, tint,
			radius * (GLOW_REACH - 1.0) / float(GLOW_RINGS) * 2.4, true)


## The disc: a carved metal ring around a dark well, matching the hero eye's
## housing so the sidebar and the centrepiece read as one object.
##
## A single-stroke outline reads as vector clip-art. A real machined ring has
## FOUR distinct bands — outer shadow, lit bevel, dark channel, inner glow —
## and it is that layering, not the colour, that makes it look metallic.
func _draw_disc(centre: Vector2, radius: float, accent: Color) -> void:
	var metal: Color = _const("COLOR_SURROUND_METAL", accent.darkened(0.70))

	# 1. Outer shadow, seating the node into the background.
	var seat: Color = _const("COLOR_BACKGROUND", accent.darkened(0.95))
	seat.a = 0.85
	draw_circle(centre, radius, seat)

	# 2. The metal band. Lit on the upper arc, shadowed below — the same
	# above/below split the hero housing uses.
	var band_r: float = radius * 0.90
	var band_w: float = radius * RING_FRAC * 2.4
	var lit: Color = metal.lightened(lerpf(0.30, 0.55, _lit))
	var dim: Color = metal.darkened(0.42)
	draw_arc(centre, band_r, PI * 1.04, PI * 1.96, 40, lit, band_w, true)
	draw_arc(centre, band_r, PI * 0.04, PI * 0.96, 40, dim, band_w, true)

	# 3. The dark well the glyph sits in.
	var well: float = radius * 0.72
	draw_circle(centre, well, accent.darkened(0.90))

	# 4. Accent channel: a thin bright line where the metal meets the well,
	# as if the glyph's light is bleeding onto the frame.
	var channel: Color = accent
	channel.a = lerpf(0.55, 1.0, _lit)
	draw_arc(centre, well * 1.04, 0.0, TAU, 48, channel,
		maxf(radius * 0.030, 1.0), true)


## The destination symbol, using the shared shape recipes.
func _draw_glyph(centre: Vector2, radius: float, accent: Color) -> void:
	# A node without a glyph still draws its ring — a route may legitimately
	# have no symbol yet, and a bare disc is a better placeholder than a gap
	# in the rail.
	if _glyph != null:
		var unit: float = radius * GLYPH_FRAC
		var tint: Color = accent.lightened(lerpf(0.0, 0.30, _lit))
		tint.a = lerpf(0.86, 1.0, _lit)
		for shape: Dictionary in _glyph.shapes:
			_draw_shape(shape, centre, unit, tint)


func _draw_shape(shape: Dictionary, centre: Vector2, unit: float,
		tint: Color) -> void:
	var width: float = maxf(float(shape.get("thickness", 0.1)) * unit, 1.5)
	match int(shape.get("kind", -1)):
		VisionGlyph.Shape.RING:
			draw_arc(centre, float(shape.get("radius", 0.0)) * unit, 0.0, TAU,
				32, tint, width, true)
		VisionGlyph.Shape.DISC:
			draw_circle(centre, float(shape.get("radius", 0.0)) * unit, tint)
		VisionGlyph.Shape.BAR:
			var local: Vector2 = shape.get("centre", Vector2.ZERO)
			var half: Vector2 = shape.get("half", Vector2.ZERO)
			draw_rect(Rect2(
				centre + Vector2(local.x - half.x, -local.y - half.y) * unit,
				half * 2.0 * unit), tint, true)
		VisionGlyph.Shape.SPOKE:
			var angle: float = float(shape.get("angle", 0.0))
			var dir := Vector2(cos(angle), sin(angle))
			draw_line(centre + dir * float(shape.get("inner", 0.0)) * unit,
				centre + dir * float(shape.get("outer", 0.0)) * unit,
				tint, width, true)
		VisionGlyph.Shape.POLYGON:
			var sides: int = maxi(int(shape.get("sides", 3)), 3)
			var pr: float = float(shape.get("radius", 0.0)) * unit
			var spin: float = float(shape.get("rotation", 0.0))
			var pts: PackedVector2Array = PackedVector2Array()
			for i: int in range(sides):
				var a: float = spin + TAU * float(i) / float(sides)
				pts.append(centre + Vector2(cos(a), sin(a)) * pr)
			for i: int in range(sides):
				draw_line(pts[i], pts[(i + 1) % sides], tint, width, true)
		VisionGlyph.Shape.ARC:
			var start: float = float(shape.get("start", 0.0))
			draw_arc(centre, float(shape.get("radius", 0.0)) * unit, start,
				start + float(shape.get("sweep", TAU)), 32, tint, width, true)
