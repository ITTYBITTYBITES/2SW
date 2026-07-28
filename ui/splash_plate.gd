extends Control
class_name SplashPlate

## SplashPlate — a baked carved-metal centerpiece with procedural light on it.
##
## WHY THIS IS BAKED AND THE REST OF THE APP IS NOT
## The target aesthetic is photographic: pewter with real specular breakup,
## runic engraving, celtic knotwork, volumetric bloom. That was already proven
## unreachable by a fragment shader when the hero eye was built — three
## measured attempts fell short on brightness distribution and saturation —
## and the launcher icon set the bar this screen is now held to. Rule F is
## amended for exactly two files under art/branding/splash/, counted against
## the same 4 MB budget as everything else.
##
## THE ART IS THE STILL PART. EVERYTHING THAT MOVES IS STILL PROCEDURAL.
## A baked texture alone would be a static logo, which is what the splash was
## being replaced FOR. So this class draws three layers:
##
##   BEHIND   a radial bloom, accumulated from many faint discs, breathing
##   MIDDLE   the baked plate, aspect-fitted into this control's rect
##   OVER     a travelling specular glint and a rim light, both procedural
##
## The atmosphere layer, the dust motes, the loading bloom and the iris
## aperture readout are all untouched and all still procedural.
##
## THE TEXTURE MUST HAVE TRANSPARENT CORNERS. It composites over the splash
## bloom; a baked-in opaque backdrop would punch a dark square through the
## halo. tools/bake_splash_art.py asserts that at bake time and the splash
## suite asserts it again on the shipped file.

## Path to the baked art. A path rather than a preloaded Texture2D so the
## scene stays readable and a missing file fails loudly at mount.
@export_file("*.png") var texture_path: String = ""

## Passes in the bloom behind the plate. Many and faint, never few and strong —
## a handful of opaque rings is a disc, not a glow.
const BLOOM_RINGS: int = 18
const BLOOM_ALPHA: float = 0.020
## Bloom reach as a multiple of the fitted plate's half-diagonal.
const BLOOM_REACH: float = 1.15

## Slow breath applied to the bloom, never to the plate itself — scaling baked
## art resamples it every frame and looks soft.
const BREATH_SEC: float = 3.8
const BREATH_AMOUNT: float = 0.05

## The specular glint that travels across the metal.
const GLINT_SEC: float = 5.2
## Width of the glint band, as a fraction of the plate's width.
const GLINT_WIDTH: float = 0.16
const GLINT_ALPHA: float = 0.10
## Slices used to draw the glint gradient.
const GLINT_SLICES: int = 14

var _texture: Texture2D = null
var _time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_texture()
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


func _load_texture() -> void:
	if not Log.must(texture_path != "", "SplashPlate",
			"%s has no texture_path" % name):
		return
	if not Log.must(ResourceLoader.exists(texture_path), "SplashPlate",
			"missing plate art: %s" % texture_path):
		return
	_texture = load(texture_path) as Texture2D
	Log.must(_texture != null, "SplashPlate",
		"plate art is not a texture: %s" % texture_path)


## The baked art, or null if it failed to resolve.
func texture() -> Texture2D:
	return _texture


## Where the plate actually lands inside this control, aspect-fitted and
## centred. Exposed so a test can assert the art is not stretched.
func fitted_rect() -> Rect2:
	if _texture == null or size.x <= 1.0 or size.y <= 1.0:
		return Rect2()
	var src: Vector2 = _texture.get_size()
	if src.x <= 0.0 or src.y <= 0.0:
		return Rect2()
	# Contain, never cover: the whole mark must be visible, and letterboxing
	# costs nothing because the art's surround is transparent anyway.
	var fit: float = minf(size.x / src.x, size.y / src.y)
	var drawn: Vector2 = src * fit
	return Rect2((size - drawn) * 0.5, drawn)


func _breath() -> float:
	if Palette.reduced_motion():
		return 1.0
	return 1.0 + sin(_time * TAU / BREATH_SEC) * BREATH_AMOUNT


func _draw() -> void:
	# Containers report (0,0) for a frame before their first sort, and
	# dividing by that yields NaN geometry the engine silently drops.
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var rect: Rect2 = fitted_rect()
	if rect.size.x <= 0.0:
		return

	_draw_bloom(rect)
	draw_texture_rect(_texture, rect, false)
	_draw_glint(rect)


## Radial light behind the plate, so it reads as lit from within the frame
## rather than pasted onto the background.
func _draw_bloom(rect: Rect2) -> void:
	var centre: Vector2 = rect.position + rect.size * 0.5
	var reach: float = rect.size.length() * 0.5 * BLOOM_REACH * _breath()
	var accent: Color = Palette.accent()
	for i: int in range(BLOOM_RINGS):
		var t: float = float(i) / float(BLOOM_RINGS - 1)
		var radius: float = reach * (1.0 - t * 0.92)
		var colour: Color = accent
		colour.a = BLOOM_ALPHA * (0.35 + pow(t, 0.6))
		draw_circle(centre, maxf(radius, 1.0), colour)


## A soft specular band travelling across the metal, plus a rim light along
## the plate's top edge.
##
## This is what keeps a baked texture from reading as a static sticker. It is
## drawn OVER the art at a low alpha, so it lifts the highlights that are
## already in the painting rather than laying a shape on top of it.
func _draw_glint(rect: Rect2) -> void:
	if Palette.reduced_motion():
		return

	# Sweep from left to right and wrap, with a pause between passes so the
	# glint reads as an occasional catch of light, not a scanning bar.
	var cycle: float = fmod(_time / GLINT_SEC, 1.0)
	var head: float = cycle * (1.0 + GLINT_WIDTH * 2.0) - GLINT_WIDTH
	var band: float = rect.size.x * GLINT_WIDTH
	var centre_x: float = rect.position.x + rect.size.x * head

	var accent: Color = Palette.accent()
	var highlight: Color = Palette.COLOR_CATCHLIGHT

	for i: int in range(GLINT_SLICES):
		var t: float = float(i) / float(GLINT_SLICES - 1)
		# Triangular falloff either side of the head.
		var offset: float = (t - 0.5) * 2.0
		var fade: float = 1.0 - absf(offset)
		if fade <= 0.0:
			continue
		var x: float = centre_x + offset * band
		if x < rect.position.x or x > rect.end.x:
			continue
		var slice_w: float = maxf(band * 2.0 / float(GLINT_SLICES), 1.0)
		var colour: Color = highlight.lerp(accent, 0.5)
		colour.a = GLINT_ALPHA * fade
		draw_rect(Rect2(Vector2(x, rect.position.y),
			Vector2(slice_w, rect.size.y)), colour, true)
