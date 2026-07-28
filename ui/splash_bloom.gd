extends Control
class_name SplashBloom

## SplashBloom — the wide cyan halo behind the startup sequence.
##
## THE PROBLEM THIS SOLVES
## The splash was a flat ColorRect with three vector marks drawn on it. It was
## the first thing a player ever saw and the only screen in the app with no
## depth treatment at all — no vignette, no bloom, nothing behind the marks.
##
## WHAT IT DOES
## A soft cyan glow centred on the marks, which GROWS and BRIGHTENS as the
## real warm-up advances. Combined with the atmosphere layer the controller
## now installs, the sequence reads as something powering up in a dark room
## rather than a logo on a black rectangle.
##
## HOW THE SOFTNESS IS ACHIEVED WITHOUT A SHADER
## Many concentric arcs, each at a very low alpha, accumulating into a
## gradient. The count is high and SPLASH_HALO_ALPHA is deliberately tiny.
##
## THIS IS NOT AN ARBITRARY CHOICE. A preview render of this screen stacked a
## dozen near-opaque rings and produced a solid cyan disc that completely
## obliterated the mark behind it. A bloom is the SUM of many faint layers; a
## handful of strong ones is a target. _peak_alpha() below exists so a test
## can assert the accumulated centre stays translucent rather than trusting
## the constants to have been chosen sensibly.
##
## ZERO ASSETS. Arcs from _draw().
##
## NON-DESTRUCTIVE. Input-transparent, holds no state the sequence depends on,
## and sits behind everything. Remove it and the splash runs identically.

## 0..1, driven by the controller from the real warm-up progress.
var _progress: float = 0.0
var _shown: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	set_process(not Palette.reduced_motion())


func _process(delta: float) -> void:
	_time += delta
	# Ease toward the target so a warm-up step completing swells the bloom
	# rather than stepping it.
	_shown = lerpf(_shown, _progress, clampf(delta * 2.4, 0.0, 1.0))
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## Drive the bloom from the loading progress, 0..1.
func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)
	if Palette.reduced_motion():
		_shown = _progress
	queue_redraw()


func progress() -> float:
	return _progress


## Where the halo sits, in this control's local space.
##
## Defaults to slightly above centre, but the controller POINTS IT AT THE
## ACTIVE MARK — the sponsor aperture during Act 1, the iris during Act 2.
##
## THIS IS NOT COSMETIC. Rendered from live state with a fixed focus, the
## bloom's bright core sat well above the iris, so the eye's own lid mask was
## silhouetted against the lit half of the halo and read as a dark dome pasted
## over the screen. A glow that is not centred on the thing it is lighting
## looks like a mistake, because it is one.
var _focus: Vector2 = Vector2(-1.0, -1.0)


func focus() -> Vector2:
	if _focus.x >= 0.0:
		return _focus
	return Vector2(size.x * 0.5, size.y * 0.42)


## Aim the halo at a point in this control's local space.
func set_focus(point: Vector2) -> void:
	_focus = point
	queue_redraw()


## Aim the halo at another control's centre, converting through global space so
## it stays correct wherever the container puts either node.
func focus_on(target: Control) -> void:
	if not Log.must(target != null, "SplashBloom", "focus_on got null"):
		return
	set_focus(target.global_position + target.size * 0.5 - global_position)


## Current outer reach of the halo, in pixels.
func reach() -> float:
	var unit: float = minf(size.x, size.y)
	var span: float = lerpf(
		Palette.SPLASH_HALO_REACH_MIN, Palette.SPLASH_HALO_REACH, _shown)
	return unit * span * _breath()


func _breath() -> float:
	if Palette.reduced_motion():
		return 1.0
	return 1.0 + sin(_time * TAU / Palette.SPLASH_HALO_BREATH) \
		* Palette.SPLASH_HALO_BREATH_AMOUNT


## Total alpha accumulated at the halo's brightest point, if every ring
## overlapped there.
##
## Exposed so a test can prove the bloom stays SOFT. Compositing N layers of
## alpha a over each other gives 1 - (1-a)^N; this is that. The check that
## uses it is what stops the "solid cyan disc" regression coming back.
func peak_alpha() -> float:
	var remaining: float = 1.0
	for _i: int in range(Palette.SPLASH_HALO_RINGS):
		remaining *= (1.0 - Palette.SPLASH_HALO_ALPHA)
	return 1.0 - remaining


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return

	var centre: Vector2 = focus()
	var outer: float = reach()
	if outer <= 1.0:
		return

	var accent: Color = Palette.accent()
	var rings: int = Palette.SPLASH_HALO_RINGS

	# Filled discs from the outside in. Each is barely visible; together they
	# build a smooth falloff that is brightest at the core.
	for i: int in range(rings):
		var t: float = float(i) / float(rings - 1)
		var radius: float = outer * (1.0 - t * 0.94)
		# Weight the inner passes harder so the gradient tightens toward the
		# centre instead of being a flat wash.
		var weight: float = pow(t, 0.6)
		var colour: Color = accent
		colour.a = Palette.SPLASH_HALO_ALPHA * (0.35 + weight)
		draw_circle(centre, maxf(radius, 1.0), colour)

	# A single crisp ring at the progress frontier, so the bloom carries the
	# same numeric reading the iris aperture does — the glow is not merely
	# decorative light, it is the loading state.
	if _shown > 0.02:
		var edge: Color = accent
		edge.a = 0.20 * _shown
		draw_arc(centre, outer * 0.98, 0.0, TAU, 96, edge,
			maxf(minf(size.x, size.y) * 0.002, 1.0), true)
