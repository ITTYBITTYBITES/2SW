extends Control
class_name RuneBand

## RuneBand — a carved band with etched rune ticks, drawn behind a Label.
##
## WHY THIS IS PROCEDURAL WHEN THE CENTERPIECES ARE BAKED
## The centerpieces are fixed artwork at a fixed aspect, so baking them costs
## two files and buys photographic metal. A frame around LIVE TEXT is the
## opposite case: the sponsor name, the status line and the skip hint all
## change width with their string and with the accessibility font scale, so a
## fixed-size texture behind them would either crop the text or drift away
## from it. This measures the label and draws to fit.
##
## It shares the centerpieces' vocabulary — the same warm metal token, tapered
## caps, an etched rail with rune ticks — so the two read as one object even
## though they are produced completely differently.
##
## NON-DESTRUCTIVE. It sits BEHIND a Label it does not own and never modifies.
## The controller still sets the text, the colour and the font size. Remove
## every band and the labels render exactly as they did before.

## The Label this band frames. Set by the controller at mount.
var _label: Label = null
var _time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(not Palette.reduced_motion())
	Bus.palette_changed.connect(_on_palette_changed)


func _exit_tree() -> void:
	Bus.palette_changed.disconnect(_on_palette_changed)


func _on_palette_changed(_tier: int) -> void:
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## Frame a label. The band inserts itself as the label's PRECEDING sibling so
## it paints underneath, and tracks the label's rect every draw.
func frame(label: Label) -> void:
	if not Log.must(label != null, "RuneBand", "frame() got null"):
		return
	_label = label
	queue_redraw()


func framed_label() -> Label:
	return _label


## The band's drawn rect, in this control's local space.
##
## Measured from the LABEL's text extents, not from the label's own rect: a
## Label in a VBox is stretched to the container's full width, so framing its
## rect would draw a band across the entire screen regardless of how short the
## word is. Exposed so a test can assert the band actually hugs the text.
func band_rect() -> Rect2:
	if _label == null:
		return Rect2()
	var font: Font = _label.get_theme_font("font")
	var font_size: int = _label.get_theme_font_size("font_size")
	if font == null or font_size <= 0:
		return Rect2()
	var text: String = _label.text.strip_edges()
	if text == "":
		return Rect2()

	var extent: Vector2 = font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
	var line_h: float = float(font_size)
	var band_h: float = line_h * Palette.RUNE_BAND_PAD
	var band_w: float = extent.x + line_h * Palette.RUNE_BAND_SIDE * 2.0
	# Never wider than the space we were given.
	band_w = minf(band_w, size.x)

	# Centred on the label's own centre line, so the band follows the text
	# wherever the container puts it.
	var centre_y: float = _label.position.y + _label.size.y * 0.5 - position.y
	if _label.get_parent() != get_parent():
		centre_y = size.y * 0.5
	return Rect2(
		Vector2((size.x - band_w) * 0.5, centre_y - band_h * 0.5),
		Vector2(band_w, band_h))


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var rect: Rect2 = band_rect()
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return

	var accent: Color = Palette.accent()
	var metal: Color = Palette.COLOR_RUNE_ETCH
	var rail: float = maxf(rect.size.y * Palette.RUNE_RAIL_FRAC, 1.0)
	var cap: float = rect.size.y * Palette.RUNE_CAP_FRAC

	# ── Plate: a hexagonal band with tapered ends ────────────────────────
	# Tapered rather than square, so it reads as a forged cartouche instead of
	# a text box.
	var plate := PackedVector2Array([
		Vector2(rect.position.x + cap, rect.position.y),
		Vector2(rect.end.x - cap, rect.position.y),
		Vector2(rect.end.x, rect.position.y + rect.size.y * 0.5),
		Vector2(rect.end.x - cap, rect.end.y),
		Vector2(rect.position.x + cap, rect.end.y),
		Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5),
	])
	var fill: Color = Palette.COLOR_RUNE_BAND
	fill.a = Palette.PANEL_OPACITY
	draw_colored_polygon(plate, fill)

	# ── Rails: lit top, shadowed bottom ──────────────────────────────────
	var lit: Color = metal
	var breath: float = 0.0
	if not Palette.reduced_motion():
		breath = sin(_time * 0.9) * 0.08
	lit.a = clampf(0.66 + breath, 0.0, 1.0)
	draw_line(Vector2(rect.position.x + cap, rect.position.y + rail),
		Vector2(rect.end.x - cap, rect.position.y + rail), lit, rail, true)

	var shade: Color = Palette.COLOR_BACKGROUND
	shade.a = 0.80
	draw_line(Vector2(rect.position.x + cap, rect.end.y - rail),
		Vector2(rect.end.x - cap, rect.end.y - rail), shade, rail, true)

	# Accent hairline just inside the top rail, matching the HUD bezels.
	var edge: Color = accent
	edge.a = 0.24
	draw_line(Vector2(rect.position.x + cap, rect.position.y + rail * 2.2),
		Vector2(rect.end.x - cap, rect.position.y + rail * 2.2),
		edge, maxf(rail * 0.5, 1.0), true)

	# ── Outline, so the taper is legible against a dark backdrop ─────────
	var outline: Color = metal
	outline.a = 0.42
	draw_polyline(plate + PackedVector2Array([plate[0]]), outline,
		maxf(rail * 0.8, 1.0), true)

	_draw_ticks(rect, cap, rail, metal)


## Rune ticks etched along the rails — short marks of alternating length, the
## same motif as the engraved band on the baked centerpieces.
func _draw_ticks(rect: Rect2, cap: float, rail: float, metal: Color) -> void:
	var inner_left: float = rect.position.x + cap
	var inner_right: float = rect.end.x - cap
	var span: float = inner_right - inner_left
	if span <= 0.0:
		return

	var tick: Color = metal
	tick.a = Palette.RUNE_TICK_ALPHA
	var width: float = maxf(rail * 0.7, 1.0)

	for i: int in range(Palette.RUNE_TICKS):
		var t: float = (float(i) + 0.5) / float(Palette.RUNE_TICKS)
		var x: float = inner_left + span * t
		# Alternating tall/short marks read as writing rather than a ruler.
		var length: float = rect.size.y * (0.16 if i % 2 == 0 else 0.10)
		draw_line(Vector2(x, rect.position.y + rail * 3.0),
			Vector2(x, rect.position.y + rail * 3.0 + length), tick, width, true)
		draw_line(Vector2(x, rect.end.y - rail * 3.0),
			Vector2(x, rect.end.y - rail * 3.0 - length), tick, width, true)
