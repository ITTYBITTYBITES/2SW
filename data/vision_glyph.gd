extends RefCounted
class_name VisionGlyph
## VisionGlyph — the procedural symbol shown inside the pupil on hover.
##
## PHASE 1. Pure data. This file describes WHAT each destination's glyph is
## made of; it draws nothing, references no node, and loads no resource.
##
## WHY A TABLE RATHER THAN ART
## v1 showed a TextureRect inside the pupil and looked its artwork up by path
## (`show_vision("res://art/nav/trials.png")`). Two problems, both of which
## this replaces:
##
##   1. This project is 100% procedural (rule 9, enforced by Rule F). There
##      are no PNGs to point at and there will not be any.
##   2. docs/features/iris_interface_contract.md flags the v1 arrangement as
##      the coupling Router exists to remove: "the eye knows destination
##      names and their artwork paths. Add a screen and you edit the eye."
##
## So the eye is handed a VisionGlyph — a shape recipe — by the controller
## that already owns the shard-to-route mapping. The eye still knows nothing
## about destinations, and adding a screen means adding a row here, not
## editing the renderer.
##
## WHY VECTOR PRIMITIVES RATHER THAN A PATH STRING
## Every glyph is expressed as rings, spokes, bars and polygons in a
## normalised [-1, 1] space. A renderer converts those to _draw() calls at
## whatever pixel size the pupil happens to be, so the symbol is resolution
## independent and re-tints with the accent without a re-import. An SVG path
## string would need a parser and would still be an asset in all but name.

## Shape kinds a glyph can be built from. Each maps to one _draw() primitive
## in the Phase 3 renderer, so this enum is the complete drawing vocabulary.
enum Shape {
	RING = 0,      ## circle outline: radius, thickness
	DISC = 1,      ## filled circle: radius
	BAR = 2,       ## rounded rect: centre, half-extents, thickness
	SPOKE = 3,     ## line from origin outward: angle, inner, outer, thickness
	POLYGON = 4,   ## regular n-gon outline: sides, radius, rotation, thickness
	ARC = 5,       ## partial ring: radius, start angle, sweep, thickness
}

## Diameter of the preview disc as a fraction of the eye's short side.
##
## 0.60 is inherited verbatim from v1's VISION_DISC_FRAC. It is the largest
## disc that still sits inside the iris ring rather than overlapping the
## limbus, which is what makes the symbol read as being *in* the eye rather
## than pasted over it.
const DISC_FRACTION: float = 0.60

## Animation contract, also inherited from v1 (IrisCore.show_vision).
## Fade and scale run in parallel; the scale uses TRANS_BACK/EASE_OUT so the
## glyph settles with a slight overshoot rather than arriving inert.
const FADE_IN_SEC: float = 0.22
const SCALE_IN_SEC: float = 0.28
const SCALE_FROM: float = 0.85
const PUPIL_PULSE: float = 0.08

## Hue rotation applied to the tier accent, per destination, in degrees.
##
## Each destination shifts the CURRENT rank accent rather than declaring its
## own literal colour. That keeps Rule D intact (no hardcoded Color outside
## Palette) and means a rank-up re-skins the previews in step with the rest
## of the app, instead of five fixed colours drifting away from the theme.
const HUE_NEUTRAL: float = 0.0
const HUE_WARM: float = 28.0
const HUE_COOL: float = -32.0
const HUE_DEEP: float = -64.0
const HUE_BRIGHT: float = 58.0

var id: StringName = &""
var label: String = ""
var hue_shift: float = 0.0
var shapes: Array[Dictionary] = []


func _init(p_id: StringName, p_label: String, p_hue: float,
		p_shapes: Array[Dictionary]) -> void:
	id = p_id
	label = p_label
	hue_shift = p_hue
	shapes = p_shapes


# ═════════════════════════════════════════════════════════════════════════
# SHAPE BUILDERS
# ═════════════════════════════════════════════════════════════════════════
## Typed constructors, so a malformed glyph is a compile error rather than a
## dictionary with a misspelled key that silently draws nothing.

static func ring(radius: float, thickness: float) -> Dictionary:
	return {"kind": Shape.RING, "radius": radius, "thickness": thickness}


static func disc(radius: float) -> Dictionary:
	return {"kind": Shape.DISC, "radius": radius}


static func bar(centre: Vector2, half: Vector2, thickness: float) -> Dictionary:
	return {"kind": Shape.BAR, "centre": centre, "half": half,
		"thickness": thickness}


static func spoke(angle: float, inner: float, outer: float,
		thickness: float) -> Dictionary:
	return {"kind": Shape.SPOKE, "angle": angle, "inner": inner,
		"outer": outer, "thickness": thickness}


static func polygon(sides: int, radius: float, rotation: float,
		thickness: float) -> Dictionary:
	return {"kind": Shape.POLYGON, "sides": sides, "radius": radius,
		"rotation": rotation, "thickness": thickness}


static func arc(radius: float, start: float, sweep: float,
		thickness: float) -> Dictionary:
	return {"kind": Shape.ARC, "radius": radius, "start": start,
		"sweep": sweep, "thickness": thickness}


# ═════════════════════════════════════════════════════════════════════════
# THE ROSTER
# ═════════════════════════════════════════════════════════════════════════
## One glyph per navigable destination, keyed by the SAME route name Router
## uses. Keying on the route rather than the shard id means the table cannot
## drift out of step with SHARD_ROUTES: a route with no glyph is detectable,
## and a glyph for a route that does not exist is detectable.
##
## Each symbol is chosen to be legible at roughly 60px — the disc size on a
## small phone — which rules out anything with fine detail.
static func roster() -> Dictionary:
	return {
		# TRIALS — concentric rings around a pupil, the false_witness glyph.
		# The trial screen draws the same figure, so the preview is a literal
		# picture of what the player is about to see.
		"trial": VisionGlyph.new(&"trial", "Trials", HUE_NEUTRAL, [
			ring(0.86, 0.14),
			ring(0.56, 0.10),
			disc(0.26),
		]),

		# PROGRESS — three ascending bars. The universal chart figure, and the
		# only one of the five that must read instantly as "numbers".
		"progress": VisionGlyph.new(&"progress", "Progress", HUE_COOL, [
			bar(Vector2(-0.46, 0.30), Vector2(0.15, 0.34), 0.0),
			bar(Vector2(0.00, 0.10), Vector2(0.15, 0.54), 0.0),
			bar(Vector2(0.46, -0.06), Vector2(0.15, 0.70), 0.0),
		]),

		# DAILY — a ring of twelve marks with a filled centre: a clock face
		# without hands, which reads as "today" rather than "a timer".
		"daily": VisionGlyph.new(&"daily", "Daily", HUE_WARM, [
			ring(0.90, 0.10),
			spoke(-PI * 0.5, 0.62, 0.82, 0.12),
			spoke(-PI * 0.5 + TAU / 12.0 * 3.0, 0.62, 0.82, 0.12),
			spoke(-PI * 0.5 + TAU / 12.0 * 6.0, 0.62, 0.82, 0.12),
			spoke(-PI * 0.5 + TAU / 12.0 * 9.0, 0.62, 0.82, 0.12),
			disc(0.20),
		]),

		# WARDROBE — a faceted gem. Matches the cosmetic language already used
		# by cosmetic_renderer.gd, so the preview and the destination share a
		# visual vocabulary.
		"visage": VisionGlyph.new(&"visage", "Wardrobe", HUE_DEEP, [
			polygon(6, 0.84, PI / 6.0, 0.12),
			polygon(6, 0.46, PI / 6.0, 0.10),
			spoke(-PI / 6.0, 0.46, 0.84, 0.08),
			spoke(PI * 0.5, 0.46, 0.84, 0.08),
			spoke(PI * 7.0 / 6.0, 0.46, 0.84, 0.08),
		]),

		# SETTINGS — a cog: a ring with eight radial teeth and a hub. Reached
		# from the sidebar rather than the compass, so it has no shard, but
		# it needs a glyph for the same reason the others do.
		"settings": VisionGlyph.new(&"settings", "Settings", HUE_NEUTRAL, [
			ring(0.54, 0.16),
			spoke(0.0, 0.62, 0.92, 0.14),
			spoke(PI * 0.25, 0.62, 0.92, 0.14),
			spoke(PI * 0.5, 0.62, 0.92, 0.14),
			spoke(PI * 0.75, 0.62, 0.92, 0.14),
			spoke(PI, 0.62, 0.92, 0.14),
			spoke(PI * 1.25, 0.62, 0.92, 0.14),
			spoke(PI * 1.5, 0.62, 0.92, 0.14),
			spoke(PI * 1.75, 0.62, 0.92, 0.14),
			disc(0.20),
		]),

		# TREND HUB — a rising line over a baseline arc. Distinct from
		# Progress at a glance: one is discrete bars, this is a trajectory.
		"trend_hub": VisionGlyph.new(&"trend_hub", "Trend Hub", HUE_BRIGHT, [
			arc(0.88, PI * 0.15, PI * 0.70, 0.10),
			spoke(-PI * 0.25, 0.00, 0.78, 0.14),
			disc(0.18),
		]),
	}


## Look up one glyph by route name. Returns null when the route has none,
## which is a legitimate state (settings and chrono_card are reached by
## button, not by the compass) rather than an error.
static func for_route(route: String) -> VisionGlyph:
	var table: Dictionary = roster()
	if not table.has(route):
		return null
	return table[route] as VisionGlyph


## Every route the roster covers. Used by the Phase 2 controller to assert it
## can preview every shard it can navigate to.
static func covered_routes() -> Array[String]:
	var out: Array[String] = []
	for route: String in roster().keys():
		out.append(route)
	out.sort()
	return out
