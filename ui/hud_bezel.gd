extends Control
class_name HudBezel

## HudBezel — a carved metal plate with a glowing cyan arc, wrapping one
## in-trial readout.
##
## THE PROBLEM THIS SOLVES
## The trial HUD was three bare Labels stacked in the header: a title, a score
## and a timer, drawn in flat dimmed text on the background colour. Every
## other surface in the game had been given carved panels, metallic nodes and
## atmosphere, so the one screen the player spends the most time on was the
## only one that still looked like a debug overlay.
##
## NON-DESTRUCTIVE BY CONSTRUCTION
## This is a WRAPPER, not a replacement. TrialController still owns %ScoreLabel
## and %TimerLabel, still writes their `.text` in _refresh_metrics(), and still
## positions them in _layout(). The bezel reparents an existing Label into
## itself and paints behind it. Delete every HudBezel and the HUD reverts to
## working plain labels — no scoring, signal or layout logic moves in here.
##
## ZERO ASSETS. Plate, groove, rim and arc are all _draw() geometry scaled from
## the control's own rect, so one class serves the score plate, the timer plate
## and the streak bar at any size.
##
## THE ARC IS A REAL READOUT, NOT DECORATION. `set_fill()` is driven by the
## caller from a measured quantity — rounds completed for the score plate,
## elapsed against the bracket window for the timer. An arc that always sweeps
## the same way regardless of play would be a spinner pretending to be a gauge.

## Which quantity this plate reads out. Purely a labelling concern — the
## drawing is identical; only the caller differs.
enum Readout {
	SCORE = 0,
	TIMER = 1,
	STREAK = 2,
}

@export var readout: Readout = Readout.SCORE

## 0..1 sweep of the cyan arc.
var _fill: float = 0.0
## Eased display value, so a round completing glides rather than snapping.
var _shown_fill: float = 0.0
## Slow breath on the rim highlight, so the metal is never perfectly static.
var _time: float = 0.0

var _label: Label = null


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
	_shown_fill = lerpf(_shown_fill, _fill, clampf(delta * 6.0, 0.0, 1.0))
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_fit_label()
		queue_redraw()


# ═════════════════════════════════════════════════════════════════════════
# HOSTING AN EXISTING LABEL
# ═════════════════════════════════════════════════════════════════════════
## Take ownership of a Label the controller already owns and already writes to.
##
## The Label keeps its identity, its %UniqueName and its text contract. Only
## its PARENT and its rect change, which is why _refresh_metrics() upstream
## needs no edit at all.
func host_label(label: Label) -> void:
	if not Log.must(label != null, "HudBezel", "host_label got null"):
		return
	_label = label

	# PRESERVE THE OWNER ACROSS THE REPARENT.
	#
	# remove_child() clears `owner`, and a node with a null owner is no longer
	# registered as a scene-unique name — so %ScoreLabel and %TimerLabel
	# resolved to null the instant this ran, and every caller that looks them
	# up by unique name got nothing back.
	#
	# This is not hypothetical: it broke 16 existing polish-audit checks
	# ("has a field and a readout") the first time the bezel was wired in.
	# Rule B forbids $Node lookups precisely so that %UniqueName is the one
	# way to reach a node, which makes silently dropping the registration a
	# much bigger deal than a cosmetic reparent would suggest.
	var keeper: Node = label.owner
	var previous: Node = label.get_parent()
	if previous != null:
		previous.remove_child(label)
	add_child(label)
	if keeper != null:
		label.owner = keeper
		label.unique_name_in_owner = true
	# The plate provides the alignment and the inset; the label just paints
	# glyphs in the middle of it.
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit_label()


## The label this plate is wrapping, or null if it hosts none.
func hosted_label() -> Label:
	return _label


## Inset the label so its text never collides with the arc track around it.
##
## A bezel with no label is an ordinary state, not a fault — the streak plate
## is drawn as a bare gauge — so this is a POSITIVE guard rather than an early
## return, per Rule C.
func _fit_label() -> void:
	if _label != null:
		var inset: float = _unit() * Palette.BEZEL_ARC_FRAC * 2.0 + Palette.SPACE_XS
		_label.offset_left = inset
		_label.offset_right = -inset
		_label.offset_top = Palette.SPACE_XXS
		_label.offset_bottom = -Palette.SPACE_XXS


# ═════════════════════════════════════════════════════════════════════════
# THE READOUT
# ═════════════════════════════════════════════════════════════════════════
## Set the arc sweep, 0..1. Clamped rather than asserted: a caller dividing by
## a round count that is briefly zero is an ordinary startup state, not a bug
## worth halting on.
func set_fill(value: float) -> void:
	_fill = clampf(value, 0.0, 1.0)
	if Palette.reduced_motion():
		_shown_fill = _fill
	queue_redraw()


func fill() -> float:
	return _fill


## What the arc is actually drawing right now, after easing. Distinct from
## fill() so a test can prove the ease converges instead of assuming it.
func shown_fill() -> float:
	return _shown_fill


# ═════════════════════════════════════════════════════════════════════════
# DRAWING
# ═════════════════════════════════════════════════════════════════════════
func _unit() -> float:
	var shortest: float = minf(size.x, size.y)
	if shortest <= 1.0:
		return 1.0
	return shortest


func _draw() -> void:
	# Containers report (0,0) for a frame before their first sort; dividing by
	# that yields NaN geometry the engine silently drops.
	if size.x <= 1.0 or size.y <= 1.0:
		return

	var unit: float = _unit()
	var accent: Color = Palette.accent()
	var rect := Rect2(Vector2.ZERO, size)

	_draw_plate(rect, unit)
	_draw_rim(rect, unit, accent)
	_draw_arc_track(rect, unit, accent)


## The recessed plate: dark fill, then a groove inset from its edge, which is
## what reads as metal machined out rather than a flat rectangle.
func _draw_plate(rect: Rect2, unit: float) -> void:
	var radius: float = float(Palette.BEZEL_RADIUS)
	draw_rect(rect, Palette.COLOR_BEZEL_PLATE, true)

	var groove: float = unit * Palette.BEZEL_GROOVE_FRAC
	var inner: Rect2 = rect.grow(-groove)
	draw_rect(inner, Palette.COLOR_BEZEL_GROOVE, false, maxf(groove * 0.5, 1.0))

	# A METAL OUTLINE AROUND THE WHOLE PLATE.
	#
	# Without this the bezel was invisible on a real screen. The fill sits at
	# 1.18:1 against the background — correct for a recessed backdrop, useless
	# as an edge. A carved plate is legible because of its lit rim, not its
	# face, and the rim was previously only drawn on the top and bottom edges,
	# so the plate had no left or right boundary at all.
	var edge_metal: Color = Palette.COLOR_BEZEL_METAL
	edge_metal.a = 0.85
	draw_rect(rect, edge_metal, false, maxf(unit * 0.022, 1.5))

	# Corner nicks: four short diagonals that suggest a chamfered plate. Cheap,
	# and they stop the rectangle reading as a plain box at small sizes.
	var nick: float = radius * 0.7
	var corners: Array[Array] = [
		[rect.position + Vector2(0.0, nick), rect.position + Vector2(nick, 0.0)],
		[Vector2(rect.end.x - nick, rect.position.y), Vector2(rect.end.x, rect.position.y + nick)],
		[Vector2(rect.end.x, rect.end.y - nick), Vector2(rect.end.x - nick, rect.end.y)],
		[Vector2(rect.position.x + nick, rect.end.y), Vector2(rect.position.x, rect.end.y - nick)],
	]
	var metal: Color = Palette.COLOR_BEZEL_METAL
	metal.a = 0.55
	for pair: Array in corners:
		draw_line(pair[0] as Vector2, pair[1] as Vector2, metal,
			maxf(unit * 0.02, 1.0), true)


## Lit top edge, shadowed bottom — the same bevel language as Palette's carved
## panels, so the HUD and the modals read as one material.
func _draw_rim(rect: Rect2, unit: float, accent: Color) -> void:
	var rim: float = maxf(unit * Palette.BEZEL_RIM_FRAC, 1.0)
	var breath: float = 0.0
	if not Palette.reduced_motion():
		breath = sin(_time * 1.1) * 0.06

	var lit: Color = Palette.COLOR_BEZEL_METAL
	lit.a = clampf(0.62 + breath, 0.0, 1.0)
	draw_line(rect.position, Vector2(rect.end.x, rect.position.y), lit, rim, true)

	var shade: Color = Palette.COLOR_BACKGROUND
	shade.a = 0.78
	draw_line(Vector2(rect.position.x, rect.end.y), rect.end, shade, rim, true)

	# A hairline of accent along the top, which is what makes the plate look
	# lit by the same cyan source as everything else on screen.
	var edge: Color = accent
	edge.a = 0.22
	draw_line(rect.position + Vector2(0.0, rim),
		Vector2(rect.end.x, rect.position.y + rim), edge, maxf(rim * 0.4, 1.0), true)


## The cyan indicator. Drawn as a rounded track hugging the plate's left and
## right ends — an arc in the literal sense, curved caps around the readout,
## rather than a circle that would not fit a wide shallow plate.
func _draw_arc_track(rect: Rect2, unit: float, accent: Color) -> void:
	var thickness: float = maxf(unit * Palette.BEZEL_ARC_FRAC, 2.0)
	var pad: float = thickness * 1.2
	var radius: float = maxf(rect.size.y * 0.5 - pad, thickness)
	var centre_y: float = rect.position.y + rect.size.y * 0.5
	var left := Vector2(rect.position.x + pad + radius, centre_y)
	var right := Vector2(rect.end.x - pad - radius, centre_y)

	# Unfilled track, so the gauge has visible extents.
	var track: Color = accent
	track.a = Palette.BEZEL_TRACK_ALPHA
	_draw_capsule(left, right, radius, track, thickness)

	if _shown_fill <= 0.001:
		return

	# Glow passes beneath the core stroke — a bloom without a shader.
	var span: float = right.x - left.x
	var tip := Vector2(left.x + span * _shown_fill, centre_y)
	for ring: int in range(Palette.BEZEL_GLOW_RINGS):
		var t: float = float(ring + 1) / float(Palette.BEZEL_GLOW_RINGS)
		var glow: Color = accent
		glow.a = Palette.BEZEL_GLOW_ALPHA * (1.0 - t * 0.6)
		_draw_capsule(left, tip, radius, glow, thickness * (1.0 + t * 2.2))

	var core: Color = accent
	core.a = Palette.BEZEL_ARC_ALPHA
	_draw_capsule(left, tip, radius, core, thickness)

	# Bright head on the leading edge, so the eye can find the current value
	# without reading the whole sweep.
	draw_circle(tip + Vector2(0.0, -radius), thickness * 0.7, core)
	draw_circle(tip + Vector2(0.0, radius), thickness * 0.7, core)


## Two horizontal runs joined by semicircular caps: the outline of a stadium.
## Used for both the track and the fill so they register exactly.
func _draw_capsule(from: Vector2, to: Vector2, radius: float,
		colour: Color, thickness: float) -> void:
	if to.x <= from.x:
		# Degenerate sweep — just the left cap, so a zero fill still shows the
		# gauge's origin rather than vanishing.
		draw_arc(from, radius, PI * 0.5, PI * 1.5, 24, colour, thickness, true)
		return
	draw_line(Vector2(from.x, from.y - radius), Vector2(to.x, to.y - radius),
		colour, thickness, true)
	draw_line(Vector2(from.x, from.y + radius), Vector2(to.x, to.y + radius),
		colour, thickness, true)
	draw_arc(from, radius, PI * 0.5, PI * 1.5, 24, colour, thickness, true)
	draw_arc(to, radius, -PI * 0.5, PI * 0.5, 24, colour, thickness, true)
