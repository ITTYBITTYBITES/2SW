extends RefCounted
class_name CosmeticCatalog
## CosmeticCatalog — every procedural cosmetic in the game.
##
## PHASE 4 DATA. Built in code rather than loaded from .tres files so the
## catalogue is diffable in review and cannot drift from the seeds it produces.
##
## LEGACY MIGRATION: v1's 16 hat SKUs map here by id, so a returning player's
## unlocks convert automatically. Any legacy SKU without a v2 equivalent still
## converts to a permanent seed (see IrisState.map_legacy_profile_data) — the
## player keeps ownership even if the ornament is regenerated procedurally.

## v1 hat SKUs, kept so migration can be verified. Reference schema only.
const LEGACY_SKUS: Array[String] = [
	"starter_cap", "crown", "celestial_crown", "founders_crown",
	"galaxy_halo", "gem_band", "hallow_horns", "halo",
	"horns", "jester_hat", "laurel", "phoenix_crest",
	"spring_wreath", "top_hat", "winter_hat", "wizard_hat",
]

static var _cache: Array[CosmeticDef] = []


## All cosmetics, built once and cached.
static func all() -> Array[CosmeticDef]:
	if _cache.is_empty():
		_cache = _build()
	return _cache


static func by_layer(layer: CosmeticDef.Layer) -> Array[CosmeticDef]:
	var out: Array[CosmeticDef] = []
	for def: CosmeticDef in all():
		if def.layer == layer:
			out.append(def)
	return out


static func by_id(id: StringName) -> CosmeticDef:
	for def: CosmeticDef in all():
		if def.id == id:
			return def
	return null


## Seeds for every catalogue entry — used to validate migration coverage.
static func all_seeds() -> Array[int]:
	var seeds: Array[int] = []
	for def: CosmeticDef in all():
		seeds.append(def.seed_value())
	return seeds


static func _make(
		id: String,
		display_name: String,
		layer: CosmeticDef.Layer,
		acquisition: CosmeticDef.Acquisition,
		anchor: String,
		rules: Dictionary,
		cost: int = 0,
		rank: int = 0) -> CosmeticDef:
	var def: CosmeticDef = CosmeticDef.new()
	def.id = StringName(id)
	def.display_name = display_name
	def.layer = layer
	def.acquisition = acquisition
	def.anchor_slot = StringName(anchor)
	def.draw_rules = rules
	def.lumina_cost = cost
	def.required_rank = rank
	return def


static func _build() -> Array[CosmeticDef]:
	var defs: Array[CosmeticDef] = []
	const HEAD: CosmeticDef.Layer = CosmeticDef.Layer.HEADPIECE
	const FRAME: CosmeticDef.Layer = CosmeticDef.Layer.FRAME
	const LIMB: CosmeticDef.Layer = CosmeticDef.Layer.LIMB
	const AURA: CosmeticDef.Layer = CosmeticDef.Layer.AURA
	const FREE: CosmeticDef.Acquisition = CosmeticDef.Acquisition.FREE
	const LUM: CosmeticDef.Acquisition = CosmeticDef.Acquisition.LUMINA
	const AD: CosmeticDef.Acquisition = CosmeticDef.Acquisition.AD_RENTAL
	const DROP: CosmeticDef.Acquisition = CosmeticDef.Acquisition.DROP_ONLY

	# ── HEADPIECES (TOP_ARC) ─────────────────────────────────────────────
	defs.append(_make("starter_cap", "Starter Cap", HEAD, FREE, "TOP_ARC",
		{"shape": "cap", "segments": 5, "symmetry": 1, "hue_shift": 0.0}))
	defs.append(_make("crown", "Crown", HEAD, LUM, "TOP_ARC",
		{"shape": "crown", "spikes": 5, "symmetry": 2, "gem_count": 3}, 120))
	defs.append(_make("horns", "Horns", HEAD, LUM, "TOP_ARC",
		{"shape": "horns", "curve": 0.6, "symmetry": 2, "taper": 0.4}, 90))
	defs.append(_make("halo", "Halo", HEAD, LUM, "TOP_ARC",
		{"shape": "ring", "thickness": 0.08, "tilt": 0.22, "glow": 1.4}, 150))
	defs.append(_make("laurel", "Laurel", HEAD, LUM, "TOP_ARC",
		{"shape": "laurel", "leaves": 9, "symmetry": 2, "spread": 0.7}, 110))
	defs.append(_make("tiara", "Tiara", HEAD, LUM, "TOP_ARC",
		{"shape": "tiara", "spikes": 7, "symmetry": 2, "gem_count": 5}, 200, 10))
	defs.append(_make("wizard_hat", "Wizard Hat", HEAD, AD, "TOP_ARC",
		{"shape": "cone", "lean": 0.18, "stars": 6, "brim": 0.9}))
	defs.append(_make("jester_hat", "Jester Hat", HEAD, AD, "TOP_ARC",
		{"shape": "jester", "bells": 3, "lobes": 3, "wobble": 0.5}))
	# Prestige tier: expensive Lumina grind rather than a paywall.
	defs.append(_make("celestial_crown", "Celestial Crown", HEAD, LUM, "TOP_ARC",
		{"shape": "crown", "spikes": 9, "symmetry": 2, "gem_count": 7,
			"orbit_motes": 5, "glow": 2.0}, 900, 25))
	defs.append(_make("founders_crown", "Founder's Crown", HEAD, DROP, "TOP_ARC",
		{"shape": "crown", "spikes": 11, "symmetry": 2, "gem_count": 9,
			"prismatic": true, "glow": 2.4}))

	# ── FRAMES / RIMS (hinges) ───────────────────────────────────────────
	defs.append(_make("monocle", "Monocle", FRAME, LUM, "RIGHT_HINGE",
		{"shape": "monocle", "rim_thickness": 0.06, "chain_links": 8}, 80))
	defs.append(_make("glasses", "Spectacles", FRAME, LUM, "LEFT_HINGE",
		{"shape": "glasses", "rim_thickness": 0.05, "bridge": 0.3}, 100))
	defs.append(_make("gem_band", "Gem Band", FRAME, LUM, "LEFT_HINGE",
		{"shape": "band", "gem_count": 5, "symmetry": 2}, 130))
	defs.append(_make("vines", "Creeping Vines", FRAME, AD, "LEFT_HINGE",
		{"shape": "vine", "tendrils": 6, "leaf_density": 0.7, "curl": 0.5}))
	defs.append(_make("earrings", "Dangle Earrings", FRAME, AD, "RIGHT_HINGE",
		{"shape": "dangle", "links": 4, "sway": 0.35}))

	# ── LIMBS / UNDERLAYS (BOTTOM_ARC) ───────────────────────────────────
	defs.append(_make("peeking_hands", "Peeking Hands", LIMB, LUM, "BOTTOM_ARC",
		{"shape": "hands", "fingers": 4, "symmetry": 2, "peek_depth": 0.3}, 160))
	defs.append(_make("little_feet", "Little Feet", LIMB, LUM, "BOTTOM_ARC",
		{"shape": "feet", "toes": 3, "symmetry": 2, "shuffle": 0.4}, 140))
	defs.append(_make("wings", "Wings", LIMB, LUM, "BOTTOM_ARC",
		{"shape": "wings", "feathers": 11, "symmetry": 2, "flap": 0.25}, 260, 15))
	defs.append(_make("tentacles", "Tentacles", LIMB, AD, "BOTTOM_ARC",
		{"shape": "tentacle", "arms": 5, "segments": 7, "writhe": 0.6}))

	# ── AURAS (full-field particles) ─────────────────────────────────────
	defs.append(_make("sparks", "Sparks", AURA, LUM, "TOP_ARC",
		{"shape": "particles", "kind": "spark", "count": 24, "rise": 0.4}, 70))
	defs.append(_make("snow", "Snowfall", AURA, LUM, "TOP_ARC",
		{"shape": "particles", "kind": "snow", "count": 40, "drift": 0.3}, 90))
	defs.append(_make("matrix_code", "Matrix Rain", AURA, AD, "TOP_ARC",
		{"shape": "particles", "kind": "glyph", "count": 32, "fall": 0.8}))
	defs.append(_make("cosmic_dust", "Cosmic Dust", AURA, LUM, "TOP_ARC",
		{"shape": "particles", "kind": "dust", "count": 56, "swirl": 0.5,
			"prismatic": true}, 750, 20))

	return defs
