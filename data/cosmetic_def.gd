extends Resource
class_name CosmeticDef
## CosmeticDef — one procedurally-generated cosmetic.
##
## PHASE 4 DATA. Like IrisState this is a pure container: no nodes, no scenes,
## and critically NO ART PATHS. A cosmetic is defined by a seed plus drawing
## rules; the renderer generates it. Nothing here can ever reference a PNG.
##
## v1 shipped 16 hats as 1536x1024 PNGs totalling 28.8 MB, rendering as ~200 px
## overlays — roughly 50x the pixels it could display. This whole catalogue
## weighs nothing.

## Which anchor layer this mounts on. Mirrors IrisState.CosmeticLayer.
enum Layer { HEADPIECE = 0, FRAME = 1, LIMB = 2, AURA = 3 }

## How a locked cosmetic can be obtained.
##
## The game is 100% free-to-play: there is deliberately NO real-money path.
## Everything is earned through Lumina grind, rewarded-ad rentals, or surprise
## drops. Do not add an IAP member here without revisiting that decision.
enum Acquisition {
	FREE = 0,        # owned from the start
	LUMINA = 1,      # spend soft currency
	AD_RENTAL = 2,   # watch a rewarded ad -> 7-day pass
	DROP_ONLY = 3,   # surprise drops only; never purchasable
}

@export var id: StringName = &""
@export var display_name: String = ""
@export var layer: Layer = Layer.HEADPIECE
@export var acquisition: Acquisition = Acquisition.LUMINA

## Cost in Lumina when acquisition == LUMINA.
@export var lumina_cost: int = 0

## Which anchor slot on the eyelid frame this mounts to.
@export var anchor_slot: StringName = &"TOP_ARC"

## Procedural drawing rules consumed by the renderer: shape family, symmetry,
## layer count, spike count, colour keys. Never a file path.
@export var draw_rules: Dictionary = {}

## Minimum rank before this even appears in the store. 0 = always visible.
@export var required_rank: int = 0


## Deterministic seed for this cosmetic. Same id always yields the same
## ornament, on every device and every engine version.
##
## Delegates to IrisState.derive_seed_from_sku (FNV-1a) rather than
## String.hash(), whose value is an engine implementation detail — if it ever
## changed, every player's ornaments would silently transform.
func seed_value() -> int:
	return IrisState.derive_seed_from_sku(String(id))


## Rental pack id for ad-unlocked cosmetics.
func pack_id() -> StringName:
	return StringName("pack_" + String(id))


## The rule dictionary written into IrisState when equipped. Carries the id and
## seed so the renderer can regenerate the exact ornament, plus the anchor so it
## knows where to mount.
func to_equip_rules() -> Dictionary:
	var rules: Dictionary = draw_rules.duplicate(true)
	rules["id"] = String(id)
	rules["seed"] = seed_value()
	rules["anchor"] = String(anchor_slot)
	rules["layer"] = int(layer)
	return rules


func is_free() -> bool:
	return acquisition == Acquisition.FREE


func is_ad_rental() -> bool:
	return acquisition == Acquisition.AD_RENTAL


func is_purchasable() -> bool:
	return acquisition == Acquisition.LUMINA


## Maps to IrisState.CosmeticLayer. The enums are declared separately so this
## data script never has to import view-model internals, but they must agree.
func state_layer() -> IrisState.CosmeticLayer:
	return layer as IrisState.CosmeticLayer
