extends RefCounted
class_name CosmeticMount
## CosmeticMount — attaches procedural cosmetics to an IrisView.
##
## PHASE 5. Pure glue: reads the four equipped-rule dictionaries from an
## IrisState, spawns one CosmeticRenderer per occupied layer, and anchors each
## using IrisView's coordinate helpers.
##
## v1 put all of this INSIDE the eye — IrisCore reached into Cosmetics for art
## paths, did its own sprite layout, and owned the mount arc maths. That was
## ~70 lines of the 801-line file and one of the reasons touching the eye was
## risky. Here the eye exposes anchor geometry and knows nothing else.
##
## LAYER ROUTING (matches IrisView's Z isolation):
##   LIMB              -> underlay  (Z -10, behind the eyeball)
##   HEADPIECE/FRAME/AURA -> overlay (Z +10, in front)
##
## INPUT: every generated node is MOUSE_FILTER_IGNORE, applied recursively
## after mounting, so a cosmetic can never intercept a tap meant for the eye.

## Layers that render BEHIND the eyeball.
const UNDERLAY_LAYERS: Array[int] = [IrisState.CosmeticLayer.LIMB]


## Rebuild every equipped cosmetic on `view` from `state`.
## Clears existing mounts first, so this is safe to call on any change.
static func apply(view: IrisView, state: IrisState) -> int:
	if not Log.must(view != null, "CosmeticMount", "apply got null view"):
		return 0
	if not Log.must(state != null, "CosmeticMount", "apply got null state"):
		return 0

	view.clear_cosmetics()

	var complexity: float = state.current_complexity_factor()
	var accent: Color = Palette.accent()
	var mounted: int = 0

	var layers: Array[IrisState.CosmeticLayer] = [
		IrisState.CosmeticLayer.LIMB,       # underlay first (drawn behind)
		IrisState.CosmeticLayer.HEADPIECE,
		IrisState.CosmeticLayer.FRAME,
		IrisState.CosmeticLayer.AURA,
	]

	for layer: IrisState.CosmeticLayer in layers:
		var rules: Dictionary = state.rules_for_layer(layer)
		if rules.is_empty():
			continue
		if _mount_one(view, state, layer, rules, complexity, accent):
			mounted += 1

	# Belt and braces: re-assert input isolation across everything just added.
	view.refresh_input_isolation()
	return mounted


static func _mount_one(view: IrisView, state: IrisState,
		layer: IrisState.CosmeticLayer, rules: Dictionary,
		complexity: float, accent: Color) -> bool:
	var anchor: StringName = StringName(str(rules.get("anchor", "TOP_ARC")))
	if not IrisState.ANCHOR_OFFSETS.has(anchor):
		Log.warn("CosmeticMount", "cosmetic '%s' has unknown anchor '%s'" % [
			rules.get("id", "?"), anchor])
		anchor = IrisState.ANCHOR_TOP_ARC

	var renderer: CosmeticRenderer = CosmeticRenderer.new()
	renderer.name = "Cosmetic_%s" % str(rules.get("id", "unknown"))
	# Size the drawing surface to the eye so `unit` maths lines up with the
	# anchor scale. The renderer draws around its own origin.
	var side: float = minf(view.size.x, view.size.y)
	renderer.custom_minimum_size = Vector2(side, side)
	renderer.size = Vector2(side, side)
	renderer.configure(rules, complexity, accent, state.reduced_motion)

	var overlay: bool = not (int(layer) in UNDERLAY_LAYERS)
	view.mount_cosmetic(renderer, anchor, overlay)
	return true


## Preview a single cosmetic without touching persistent state — used by the
## Wardrobe to show an item before it is equipped.
static func preview(view: IrisView, def: CosmeticDef, state: IrisState) -> void:
	if not Log.must(view != null and def != null and state != null,
			"CosmeticMount", "preview got null argument"):
		return
	var renderer: CosmeticRenderer = CosmeticRenderer.new()
	renderer.name = "Preview_%s" % String(def.id)
	var side: float = minf(view.size.x, view.size.y)
	renderer.custom_minimum_size = Vector2(side, side)
	renderer.size = Vector2(side, side)
	renderer.configure(def.to_equip_rules(), state.current_complexity_factor(),
		Palette.accent(), state.reduced_motion)

	var overlay: bool = not (int(def.state_layer()) in UNDERLAY_LAYERS)
	view.mount_cosmetic(renderer, def.anchor_slot, overlay)
	view.refresh_input_isolation()
