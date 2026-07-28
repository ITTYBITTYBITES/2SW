extends Screen
class_name WardrobeController
## WardrobeController — the procedural cosmetic store and dressing room.
##
## PHASE 4 CONTRACT.
##
## THIS IS THE PRIMARY MUTATOR for cosmetic state. It is the ONLY screen
## permitted to equip, unequip, rent, or purchase. The Hub Portal is a
## read-only view and its test suite forbids every mutator called here.
##
## Ownership model:
##   OWNED   permanent seed in unlocked_cosmetic_seeds — never expires
##   RENTED  unexpired pack in active_rental_passes — 7-day window
##   LOCKED  shows a Lumina cost or a rewarded-ad offer
##
## The game is 100% free-to-play. There is no real-money path by design.
##
## Ownership always beats rental, so a lapsed pass can never revoke something
## the player actually earned.
##
## PERSISTENCE: every mutation routes through _commit(), which writes once and
## flushes. There is exactly one path to disk, so a transaction cannot be
## half-saved.

# ── Category tabs ────────────────────────────────────────────────────────
const TAB_ORDER: Array[CosmeticDef.Layer] = [
	CosmeticDef.Layer.HEADPIECE,
	CosmeticDef.Layer.FRAME,
	CosmeticDef.Layer.LIMB,
	CosmeticDef.Layer.AURA,
]

const TAB_LABELS: Dictionary = {
	CosmeticDef.Layer.HEADPIECE: "Headpieces",
	CosmeticDef.Layer.FRAME: "Frames",
	CosmeticDef.Layer.LIMB: "Limbs",
	CosmeticDef.Layer.AURA: "Auras",
}

## Availability of a catalogue entry for the current player.
enum Availability { OWNED = 0, RENTED = 1, LOCKED = 2, RANK_LOCKED = 3 }

# ── Scene-unique nodes (Rule B) ──────────────────────────────────────────
@onready var _background: ColorRect = %Background
@onready var _preview: IrisView = %PreviewIris
@onready var _tab_row: HBoxContainer = %TabRow
@onready var _item_list: VBoxContainer = %ItemList
@onready var _lumina_label: Label = %LuminaLabel
@onready var _back_button: Button = %BackButton
@onready var _settings_button: Button = %SettingsButton
@onready var _drop_modal: Control = %SurpriseDropModal
@onready var _drop_label: Label = %DropLabel
@onready var _drop_claim: Button = %DropClaimButton

# ── State ────────────────────────────────────────────────────────────────
var _state: IrisState = null
var _active_tab: CosmeticDef.Layer = CosmeticDef.Layer.HEADPIECE
var _tab_buttons: Dictionary = {}
var _wired: bool = false
var _pending_drop_seed: int = 0
## Cosmetic awaiting an ad result. Cleared on grant or dismissal so a stale
## pending item can never be credited by a later, unrelated ad.
var _pending_ad_def: CosmeticDef = null


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	_state = _resolve_state()

	_wired = (
		Log.must(_preview != null, "Wardrobe", "%PreviewIris missing")
		and Log.must(_tab_row != null, "Wardrobe", "%TabRow missing")
		and Log.must(_item_list != null, "Wardrobe", "%ItemList missing")
		and Log.must(_drop_modal != null, "Wardrobe", "%SurpriseDropModal missing")
		and Log.must(_state != null, "Wardrobe", "state failed to resolve")
	)
	if not _wired:
		return

	install_atmosphere()

	# Housekeeping on entry: expire stale rentals, then convert any legacy
	# unlocks. Both are idempotent and safe to run on every visit.
	var pruned: int = _state.prune_expired_rentals()
	var migrated: int = map_legacy_unlocked_skus()
	if pruned > 0 or migrated > 0:
		Log.info("Wardrobe", "pruned %d rentals, migrated %d legacy skus" % [pruned, migrated])
		_commit()

	# The preview is read-write: it reflects edits live, unlike the hub.
	_preview.apply_state(_state)
	CosmeticMount.apply(_preview, _state)
	_preview.set_interactive(false)   # dressing room, not a navigation surface

	_build_tabs()
	_rebuild_list()
	_refresh_currency()
	_hide_drop_modal()

	if _back_button != null:
		_back_button.pressed.connect(_on_back_pressed)
	if _settings_button != null:
		_settings_button.pressed.connect(_on_settings_pressed)
	if _drop_claim != null:
		_drop_claim.pressed.connect(_on_drop_claimed)

	Bus.surprise_drop_earned.connect(_on_surprise_drop)
	AdManager.ad_watched_successfully.connect(_on_ad_reward)
	AdManager.ad_dismissed_early.connect(_on_ad_dismissed)
	AdManager.ad_failed_to_load.connect(_on_ad_failed)


func _exit_tree() -> void:
	super()
	if Bus.surprise_drop_earned.is_connected(_on_surprise_drop):
		Bus.surprise_drop_earned.disconnect(_on_surprise_drop)
	if AdManager.ad_watched_successfully.is_connected(_on_ad_reward):
		AdManager.ad_watched_successfully.disconnect(_on_ad_reward)
	if AdManager.ad_dismissed_early.is_connected(_on_ad_dismissed):
		AdManager.ad_dismissed_early.disconnect(_on_ad_dismissed)
	if AdManager.ad_failed_to_load.is_connected(_on_ad_failed):
		AdManager.ad_failed_to_load.disconnect(_on_ad_failed)


func _resolve_state() -> IrisState:
	var incoming: Variant = payload.get("iris_state", null)
	if incoming is IrisState:
		return incoming as IrisState
	var state: IrisState = IrisState.new()
	var stored: Dictionary = Save.get_v("iris", "state", {})
	if not stored.is_empty():
		state.from_dict(stored)
	state.reduced_motion = Palette.reduced_motion()
	return state


## The single write path. Every mutation ends here, so a transaction is either
## fully persisted or not attempted.
func _commit() -> void:
	if not _operational("_commit"):
		return
	Save.set_v("iris", "state", _state.to_dict())
	Save.flush()


## True when _setup() validated the scene contract AND state resolved. Guards
## call this instead of re-testing nulls, so a wiring fault is reported once in
## _setup() rather than silently swallowed at every call site.
func _operational(context: String) -> bool:
	if _wired and _state != null:
		return true
	Log.d("Wardrobe", "not operational in %s" % context)
	return false


func _on_palette_changed(_tier: int) -> void:
	if _background != null:
		_background.color = Palette.COLOR_BACKGROUND
	_style_tabs()
	_rebuild_list()


# ═════════════════════════════════════════════════════════════════════════
# LEGACY MIGRATION
# ═════════════════════════════════════════════════════════════════════════
## Convert imported legacy SKU flags into v2 procedural seeds. Idempotent:
## re-running grants nothing new. Returns how many seeds were newly granted.
##
## Runs on every Wardrobe entry rather than once at migration time, so a
## profile imported by a future build still converts without a special path.
func map_legacy_unlocked_skus() -> int:
	if _state == null:
		return 0
	var granted: int = 0
	for sku: String in _state.legacy_unlocked_skus:
		if sku == "":
			continue
		# Same FNV-1a derivation the catalogue uses, so a legacy "crown"
		# resolves to the exact seed of the v2 "crown" entry.
		var seed_value: int = IrisState.derive_seed_from_sku(sku)
		if _state.grant_seed(seed_value):
			granted += 1
	return granted


# ═════════════════════════════════════════════════════════════════════════
# AVAILABILITY EVALUATION
# ═════════════════════════════════════════════════════════════════════════
func evaluate_availability(def: CosmeticDef) -> Availability:
	if not Log.must(def != null, "Wardrobe", "evaluate_availability got null"):
		return Availability.LOCKED
	if _state == null:
		return Availability.LOCKED

	# Ownership wins over everything, including an expired rental.
	if def.is_free() or _state.owns_seed(def.seed_value()):
		return Availability.OWNED
	if _state.is_rental_active(def.pack_id()):
		return Availability.RENTED
	if def.required_rank > _state.rank_tier:
		return Availability.RANK_LOCKED
	return Availability.LOCKED


func is_equipped(def: CosmeticDef) -> bool:
	if _state == null or def == null:
		return false
	return _state.equipped_id_for_layer(def.state_layer()) == String(def.id)


# ═════════════════════════════════════════════════════════════════════════
# TRANSACTIONS — the mutator surface
# ═════════════════════════════════════════════════════════════════════════
## Equip a cosmetic. Refuses unless the player owns or rents it, so a UI bug
## can never dress the Iris in something unpaid for.
func equip(def: CosmeticDef) -> bool:
	if not Log.must(def != null, "Wardrobe", "equip got null"):
		return false
	var availability: Availability = evaluate_availability(def)
	if availability != Availability.OWNED and availability != Availability.RENTED:
		Log.warn("Wardrobe", "refused equip of unowned '%s'" % def.id)
		return false

	_state.set_layer_rules(def.state_layer(), def.to_equip_rules())
	_commit()
	_refresh_preview()
	_rebuild_list()
	Bus.toast.emit("Equipped %s" % def.display_name, "✦")
	return true


func unequip(layer: CosmeticDef.Layer) -> void:
	if not _operational("unequip"):
		return
	_state.clear_layer(layer as IrisState.CosmeticLayer)
	_commit()
	_refresh_preview()
	_rebuild_list()


## Buy permanently with Lumina. spend_lumina() is atomic, so a failed purchase
## cannot leave the balance debited without granting the seed.
func purchase_with_lumina(def: CosmeticDef) -> bool:
	if not Log.must(def != null, "Wardrobe", "purchase got null"):
		return false
	if def.acquisition != CosmeticDef.Acquisition.LUMINA:
		Log.warn("Wardrobe", "'%s' is not a Lumina purchase" % def.id)
		return false
	if def.required_rank > _state.rank_tier:
		Bus.toast.emit("Requires Rank %d" % def.required_rank, "✧")
		return false
	if not _state.spend_lumina(def.lumina_cost):
		Bus.toast.emit("Not enough Lumina", "✧")
		return false

	_state.grant_seed(def.seed_value())
	_commit()
	_refresh_currency()
	_rebuild_list()
	Bus.toast.emit("Unlocked %s" % def.display_name, "✦")
	return true


## Request a rewarded ad for a 7-day rental.
##
## This only STARTS the flow. The grant happens in _on_ad_reward() when the
## network (or the offline fallback) reports a completed watch, so a player
## who closes the ad early gets nothing — while a player defeated by our
## infrastructure still gets the cosmetic.
func watch_ad_for_rental(def: CosmeticDef) -> bool:
	if not Log.must(def != null, "Wardrobe", "ad rental got null"):
		return false
	if not def.is_ad_rental():
		Log.warn("Wardrobe", "'%s' is not an ad rental" % def.id)
		return false
	if _pending_ad_def != null:
		Log.warn("Wardrobe", "an ad request is already in flight")
		return false

	_pending_ad_def = def
	if not AdManager.show_rewarded(String(def.id)):
		# Only the daily cap refuses outright.
		_pending_ad_def = null
		Bus.toast.emit("Daily ad limit reached — try tomorrow", "✧")
		return false
	return true


## The ad completed. Credit the rental, count the watch, and evaluate the
## surprise-drop threshold.
##
## The watch is registered BEFORE the grant so drop credit survives even if the
## grant is somehow refused — the player watched the ad either way.
func _on_ad_reward(placement: String) -> void:
	if not _operational("_on_ad_reward"):
		return
	var def: CosmeticDef = _pending_ad_def
	_pending_ad_def = null
	if def == null or String(def.id) != placement:
		Log.warn("Wardrobe", "reward for '%s' did not match pending item" % placement)
		return

	var drop_earned: bool = _state.register_ad_watch()
	_state.grant_rental(def.pack_id())
	_commit()
	_rebuild_list()

	AudioManager.play_sfx(&"reward")
	HapticsManager.pulse(&"reward")
	Bus.toast.emit("%s unlocked for 7 days" % def.display_name, "✦")

	if drop_earned:
		_trigger_surprise_drop()


## Closed early — no reward is owed, and nothing is charged.
func _on_ad_dismissed(placement: String) -> void:
	_pending_ad_def = null
	Log.info("Wardrobe", "ad dismissed early for '%s'" % placement)
	Bus.toast.emit("Ad closed early — no reward", "✧")


## Load failure. AdManager already grants through the offline fallback, so
## reaching here means a real refusal such as the daily cap.
func _on_ad_failed(reason: String) -> void:
	if _pending_ad_def == null:
		# Not our request. AdManager broadcasts to every listener, so a
		# background pre-load failure reaches us too; ignoring it is correct.
		Log.d("Wardrobe", "ad failure with no pending item: %s" % reason)
		return
	_pending_ad_def = null
	Log.warn("Wardrobe", "ad unavailable: %s" % reason)
	Bus.toast.emit("Ads unavailable right now", "✧")


# ═════════════════════════════════════════════════════════════════════════
# SURPRISE DROP
# ═════════════════════════════════════════════════════════════════════════
## Pick a drop reward, show the modal, and announce it. The threshold was
## already re-rolled inside register_ad_watch().
func _trigger_surprise_drop() -> void:
	var reward: CosmeticDef = _pick_drop_reward()
	if reward == null:
		# Everything is already owned — award Lumina instead of nothing.
		_state.lumina += 100
		_commit()
		_refresh_currency()
		_show_drop_modal("A gift of 100 Lumina")
		return

	_pending_drop_seed = reward.seed_value()
	_show_drop_modal("You found: %s" % reward.display_name)
	Bus.surprise_drop_earned.emit({
		"seed": _pending_drop_seed,
		"tier": "drop",
		"label": reward.display_name,
	})


## Prefer DROP_ONLY exclusives, then anything unowned. Returns null when the
## player already has everything.
func _pick_drop_reward() -> CosmeticDef:
	var exclusives: Array[CosmeticDef] = []
	var others: Array[CosmeticDef] = []
	for def: CosmeticDef in CosmeticCatalog.all():
		if _state.owns_seed(def.seed_value()) or def.is_free():
			continue
		if def.acquisition == CosmeticDef.Acquisition.DROP_ONLY:
			exclusives.append(def)
		else:
			others.append(def)
	if not exclusives.is_empty():
		return exclusives[0]
	if not others.is_empty():
		return others[0]
	return null


func _show_drop_modal(text: String) -> void:
	if not _operational("_show_drop_modal"):
		return
	_drop_label.text = text
	_drop_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_drop_label.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_HEADING))
	_drop_modal.visible = true
	_preview.express(&"flare", 1.0)


func _hide_drop_modal() -> void:
	if _drop_modal != null:
		_drop_modal.visible = false


## Grant the pending seed and close. Granting happens on CLAIM, not on show,
## so a player who backgrounds the app mid-modal still gets the reward next
## time rather than losing it silently.
func _on_drop_claimed() -> void:
	if _pending_drop_seed != 0:
		_state.grant_seed(_pending_drop_seed)
		_pending_drop_seed = 0
		_commit()
		_rebuild_list()
	_hide_drop_modal()


## An external system (e.g. an ad shown outside the Wardrobe) reported a drop.
func _on_surprise_drop(drop: Dictionary) -> void:
	if not _operational("_on_surprise_drop"):
		return
	var seed_value: int = int(drop.get("seed", 0))
	if seed_value == 0:
		Log.warn("Wardrobe", "surprise drop payload had no seed")
		return
	if _state.grant_seed(seed_value):
		_commit()
		_rebuild_list()


# ═════════════════════════════════════════════════════════════════════════
# UI CONSTRUCTION
# ═════════════════════════════════════════════════════════════════════════
func _build_tabs() -> void:
	if not _operational("_build_tabs"):
		return
	for layer: CosmeticDef.Layer in TAB_ORDER:
		var button: Button = Button.new()
		button.text = TAB_LABELS[layer]
		button.toggle_mode = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_tab_pressed.bind(layer))
		_tab_row.add_child(button)
		_tab_buttons[layer] = button
	_style_tabs()


func _style_tabs() -> void:
	for layer: CosmeticDef.Layer in _tab_buttons.keys():
		var button: Button = _tab_buttons[layer]
		var active: bool = layer == _active_tab
		button.button_pressed = active
		button.add_theme_color_override("font_color",
			Palette.accent() if active else Palette.COLOR_TEXT_DIM)
		button.add_theme_font_size_override(
			"font_size", Palette.font(Palette.FONT_SMALL))


func _on_tab_pressed(layer: CosmeticDef.Layer) -> void:
	_active_tab = layer
	_style_tabs()
	_rebuild_list()


func _rebuild_list() -> void:
	if not _operational("_rebuild_list"):
		return
	for child: Node in _item_list.get_children():
		child.queue_free()
	for def: CosmeticDef in CosmeticCatalog.by_layer(_active_tab):
		_item_list.add_child(_build_row(def))


## One catalogue row: name, status, and the single most relevant action.
func _build_row(def: CosmeticDef) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", int(Palette.SPACE_SM))

	var name_label: Label = Label.new()
	name_label.text = def.display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	name_label.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_BODY))
	row.add_child(name_label)

	var status: Label = Label.new()
	status.text = _status_text(def)
	status.add_theme_color_override("font_color", _status_color(def))
	status.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_MICRO))
	row.add_child(status)

	var action: Button = Button.new()
	_configure_action(action, def)
	row.add_child(action)
	return row


func _status_text(def: CosmeticDef) -> String:
	match evaluate_availability(def):
		Availability.OWNED:
			return "Owned"
		Availability.RENTED:
			var days: int = _state.rental_days_remaining(def.pack_id())
			return "%d day%s left" % [days, "" if days == 1 else "s"]
		Availability.RANK_LOCKED:
			return "Rank %d" % def.required_rank
		_:
			match def.acquisition:
				CosmeticDef.Acquisition.LUMINA:
					return "%d ✦" % def.lumina_cost
				CosmeticDef.Acquisition.AD_RENTAL:
					return "Watch ad"
				CosmeticDef.Acquisition.DROP_ONLY:
					return "Surprise drop"
	return ""


func _status_color(def: CosmeticDef) -> Color:
	match evaluate_availability(def):
		Availability.OWNED:
			return Palette.success()
		Availability.RENTED:
			return Palette.COLOR_WARNING
		Availability.RANK_LOCKED:
			return Palette.COLOR_TEXT_FAINT
	return Palette.COLOR_TEXT_DIM


func _configure_action(button: Button, def: CosmeticDef) -> void:
	button.custom_minimum_size = Vector2(
		Palette.MARKER_SIZE.x, Palette.CONTROL_HEIGHT_MD)
	button.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_SMALL))

	var availability: Availability = evaluate_availability(def)
	if availability == Availability.OWNED or availability == Availability.RENTED:
		if is_equipped(def):
			button.text = "Remove"
			button.pressed.connect(unequip.bind(def.layer))
		else:
			button.text = "Equip"
			button.pressed.connect(func() -> void: equip(def))
		return

	if availability == Availability.RANK_LOCKED:
		button.text = "Locked"
		button.disabled = true
		return

	match def.acquisition:
		CosmeticDef.Acquisition.LUMINA:
			button.text = "Buy"
			button.disabled = _state.lumina < def.lumina_cost
			button.pressed.connect(func() -> void: purchase_with_lumina(def))
		CosmeticDef.Acquisition.AD_RENTAL:
			button.text = "▶ 7 days"
			button.pressed.connect(func() -> void: watch_ad_for_rental(def))
		_:
			button.text = "—"
			button.disabled = true


func _refresh_preview() -> void:
	if not _operational("_refresh_preview"):
		return
	_preview.apply_state(_state)
	CosmeticMount.apply(_preview, _state)


func _refresh_currency() -> void:
	if not _operational("_refresh_currency") or _lumina_label == null:
		return
	_lumina_label.text = "%d ✦    %.0f ◈" % [_state.lumina, _state.lens_shimmer]
	_lumina_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	_lumina_label.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_SMALL))


# ═════════════════════════════════════════════════════════════════════════
# NAVIGATION
# ═════════════════════════════════════════════════════════════════════════
func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


## The West shard is the player's own space, so Settings lives here rather
## than competing for a compass direction of its own.
func _on_settings_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.go("settings", {"iris_state": _state})


## Back closes the drop modal first, so a player can't dismiss the screen and
## skip an unclaimed reward.
func on_back_requested() -> bool:
	if _drop_modal != null and _drop_modal.visible:
		_on_drop_claimed()
		return true
	return false
