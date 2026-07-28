extends AspectRatioContainer
class_name SquareSlot
## SquareSlot — a container that keeps one child perfectly square.
##
## THE PROBLEM THIS REPLACES
## The Iris shader assumes an isotropic coordinate space: its pupil SDF, iris
## mask, polar Voronoi warp and glint falloffs all read a single radius. Give
## it a non-square rect and the pupil renders as an ellipse. Measured, the
## host rect was square on exactly one of the three screens that mount it:
##
##     hub_portal    520 x 520     aspect 1.000
##     intro        1016 x 1350    aspect 0.753   squashed
##     daily_hub    1024 x  200    aspect 5.120   smeared
##
## Two separate fixes were written by hand for this. First the shader learned
## to divide by its short axis, which corrects the DRAWING but leaves the
## control occupying a rect the wrong shape — so the eye floats in dead space
## and hit-testing covers regions with no eye in them. Then hub_portal grew
## forty lines of arithmetic computing a band between the rank label and the
## hint, clamping a side length into it, and centring the result.
##
## That arithmetic is what AspectRatioContainer already does, correctly, for
## free. `ratio = 1.0` with STRETCH_FIT sizes the child to the SHORTER
## available axis and centres it — exactly the intent, expressed once, in a
## node the engine lays out rather than in a controller that has to remember
## to re-run on every resize.
##
## WHY A SUBCLASS RATHER THAN THE STOCK NODE
## Two behaviours the stock container does not provide, both learned from
## real failures on this project:
##
##   1. A floor. On a 640x360 landscape phone the available band collapses to
##      almost nothing, and AspectRatioContainer will happily hand its child a
##      4x4 rect. The shader still runs, the drag target is unhittable, and
##      the hub looks broken rather than compact. Below `hide_below` the slot
##      hides its child and logs, so the degradation is deliberate and
##      visible in the log instead of silently invisible on screen.
##
##   2. A cap. The Iris is designed at 520px; stretched across a tablet it
##      turns soft and dominates the layout. `max_side` holds it at its design
##      size and lets the surrounding container absorb the slack.
##
## USAGE
##   SquareSlot (size_flags_vertical = EXPAND | FILL)
##     └── IrisView
##
## The parent VBox decides how much room the slot gets. The slot decides how
## much of that room can hold a square. The child never computes geometry at
## all, which is the point: there is nothing left to get wrong on the next
## screen size.

## Never render the child below this. A too-small eye is worse than none.
##
## RAISED FROM 64. The nav dock reserves a fixed 272px block at the bottom of
## the hub, so on a short screen (800x600, 360x640) the slot was still handing
## the eye ~70px while the HOUSING drawn around it — 1.95x the eye, reaching
## 0.848 of that half-span — spilled straight over the dock. The polish audit
## caught rail nodes sitting on the carved metal.
##
## An eye smaller than this is not a hero element anyway; hiding it leaves a
## clean, navigable hub instead of a squashed one.
@export var hide_below: float = 200.0

## Never grow the child past this. Its design size.
## REDUCED FROM 520 TO MAKE ROOM FOR THE HERO HOUSING.
##
## The baked frame is drawn around the eye at HOUSING_SPAN, and its outer edge
## lands at 0.848 of its half-span. The compass shard labels sit on a ring that
## the screen width hard-caps at 460px from centre on a 1080px display, so the
## frame has to finish inside that or it swallows them — measured on a GPU
## capture: "Trials" was invisible at peak luminance 9, "Trend Hub" sat on
## bright bronze.
##
## At 520 the frame's outer edge is 430px and the labels are buried. At 480 it
## is 397px, which clears the label ring with margin while the frame still sits
## outside the eyeball (metal at 249px vs a 240px eye edge).
## 440, not 480. Every destination now has a rail node WITH A CAPTION, and a
## caption is wider than the 68px disc it labels — "Wardrobe" and "Progress"
## were printing over the carved frame. Pulling the eye in gives the captions
## clean background to sit on.
## Raised from 440 now that the rails run ABOVE and BELOW rather than beside
## the eye — nothing occupies the left and right margins any more.
##
## 500, not 560. HOUSING_SPAN multiplies this by 1.95, so 560 asks for a
## 1092px frame on a 1080px screen and clips at both edges. 500 gives a 975px
## frame with ~52px of margin either side.
@export var max_side: float = 500.0

## Emitted after the slot resolves a new side length, so a controller can
## place satellites (the hub's five compass shards orbit the eye's radius).
signal side_resolved(side: float)

var _last_side: float = -1.0


func _ready() -> void:
	ratio = 1.0
	stretch_mode = AspectRatioContainer.STRETCH_FIT
	alignment_horizontal = AspectRatioContainer.ALIGNMENT_CENTER
	alignment_vertical = AspectRatioContainer.ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_apply)
	_apply.call_deferred()


func _exit_tree() -> void:
	if resized.is_connected(_apply):
		resized.disconnect(_apply)


## The side length the child will actually receive, after floor and cap.
func resolved_side() -> float:
	return minf(minf(size.x, size.y), max_side)


func _apply() -> void:
	var side: float = resolved_side()
	var visible_now: bool = side >= hide_below

	for child: Node in get_children():
		if child is Control:
			(child as Control).visible = visible_now

	if not visible_now:
		if _last_side >= hide_below or _last_side < 0.0:
			Log.d("SquareSlot", "%s: %.0fpx is below the %.0fpx floor; child hidden"
				% [name, side, hide_below])
		_last_side = side
		return

	# The cap is enforced by shrinking the SLOT, not the child:
	# AspectRatioContainer always fills itself, so a child cannot be smaller
	# than its parent here.
	custom_minimum_size = Vector2.ZERO
	if side >= max_side:
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		custom_minimum_size = Vector2(max_side, max_side)
	else:
		size_flags_vertical = Control.SIZE_EXPAND_FILL
		size_flags_horizontal = Control.SIZE_FILL

	if not is_equal_approx(side, _last_side):
		_last_side = side
		side_resolved.emit(side)
