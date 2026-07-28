extends RefCounted
class_name RelicRecipe

## RelicRecipe — gameplay tile appearance, derived from player progression.
##
## PURE DATA AND PURE MATH. No node, no scene, no draw call. A renderer asks
## for a recipe and gets numbers; what it does with them is its own business.
##
## THE PROBLEM THIS SOLVES
## Gameplay visuals were fixed constants. false_witness drew `var rings: int =
## 3` for every player at every rank forever; facet_cascade indexed a static
## FACET_COLORS array. A rank-1 Observer and a rank-40 Oracle saw pixel
## identical tiles, so the single longest-running reward in the game — rank —
## had no visual expression anywhere the player actually spends their time.
##
## WHAT DRIVES IT
## Nothing new is stored. Every value below is derived from state the game
## already keeps and already persists:
##
##     rank_tier      -> ring count, facet count, carve depth
##     complexity     -> IrisState.current_complexity_factor(), the same
##                       1.0 + log(1+rank) * 0.25 curve the Iris shader uses,
##                       so tiles and eye scale together by construction
##     lens_shimmer   -> glow pulse amplitude (the Resonance currency, which
##                       until now only the eye displayed)
##     bracket        -> hue offset, so Easy/Medium/Hard read apart at a glance
##
## WHY LOGARITHMIC AND NOT LINEAR
## Rank is unbounded. A linear mapping would put a rank-200 tile at 200 rings.
## The log curve means rank 1->5 is a visible jump and rank 100->105 is a
## subtle one, which matches how the reward actually feels.

## Ring/facet bounds. The floor is what a rank-1 player sees; the ceiling
## exists because past it the detail is smaller than a pixel on a phone.
const RINGS_MIN: int = 2
const RINGS_MAX: int = 7
const FACETS_MIN: int = 3
const FACETS_MAX: int = 9

## Carved-metal bevel depth, 0 = flat plate, 1 = deeply machined.
const CARVE_MIN: float = 0.12
const CARVE_MAX: float = 0.85

## Glow pulse amplitude, before shimmer is added.
const PULSE_MIN: float = 0.06
const PULSE_MAX: float = 0.34

## Hue rotation per difficulty bracket, in degrees. Easy stays on the tier
## accent; harder brackets shift warmer, which reads as heat.
const BRACKET_HUE: Array[float] = [0.0, 18.0, 40.0]

var rings: int = RINGS_MIN
var facets: int = FACETS_MIN
var carve: float = CARVE_MIN
var pulse: float = PULSE_MIN
var hue_shift: float = 0.0
var complexity: float = 1.0


## Build a recipe from live progression values.
##
## Takes primitives rather than an IrisState so a renderer can be tested
## without constructing a whole view model, and so this file keeps no
## dependency on the state class.
## rank_tier is deliberately NOT a parameter. complexity_factor is
## 1.0 + log(1+rank) * 0.25, so it already encodes the rank — taking both
## would let a caller pass a tier and a factor that disagree, and there would
## be no correct way to resolve that. One source of truth.
static func derive(complexity_factor: float, shimmer: float,
		bracket: int) -> RelicRecipe:
	var recipe := RelicRecipe.new()
	recipe.complexity = maxf(complexity_factor, 1.0)

	# complexity_factor is 1.0 + log(1+rank) * 0.25, so it reaches ~2.0 around
	# rank 55 and ~2.4 around rank 150. Normalising against 2.6 puts a
	# lifetime of progression across the full visual range without the curve
	# saturating early.
	var progress: float = clampf((recipe.complexity - 1.0) / 1.6, 0.0, 1.0)

	recipe.rings = RINGS_MIN + int(round(progress * float(RINGS_MAX - RINGS_MIN)))
	recipe.facets = FACETS_MIN + int(round(progress * float(FACETS_MAX - FACETS_MIN)))
	recipe.carve = lerpf(CARVE_MIN, CARVE_MAX, progress)

	# Shimmer is the Resonance currency. It ADDS to the rank-driven pulse
	# rather than replacing it, so a low-rank player who has earned Resonance
	# still sees their tiles react.
	recipe.pulse = lerpf(PULSE_MIN, PULSE_MAX, progress) \
		+ clampf(shimmer, 0.0, 1.0) * 0.22

	var safe_bracket: int = clampi(bracket, 0, BRACKET_HUE.size() - 1)
	recipe.hue_shift = BRACKET_HUE[safe_bracket]
	return recipe


## The tile colour for this recipe, derived from the live tier accent.
##
## Never a literal: Rule D forbids one outside Palette, and deriving from the
## accent means a rank-up re-skins gameplay in step with the hub.
func tint(accent: Color) -> Color:
	var out: Color = accent
	out.h = fposmod(accent.h + hue_shift / 360.0, 1.0)
	# Higher ranks read hotter, not just busier.
	out.s = clampf(accent.s * (1.0 + carve * 0.22), 0.0, 1.0)
	return out


## Glow amplitude at a given moment. Renderers call this per frame rather
## than computing their own oscillator, so every tile in a run breathes in
## phase and the field reads as one object.
func glow_at(time_seconds: float) -> float:
	return 1.0 + sin(time_seconds * 2.2) * pulse


## Human-readable, for logs and tests.
func describe() -> String:
	return "rings=%d facets=%d carve=%.2f pulse=%.2f hue=%.0f" % [
		rings, facets, carve, pulse, hue_shift]
