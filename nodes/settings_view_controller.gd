extends Screen
class_name SettingsViewController
## SettingsViewController — audio mix, accessibility, and data actions.
##
## PHASE 9. Every control writes straight through to Save via its owning
## system (AudioManager for channels, Save.set_setting for accessibility), so
## there is no "apply" step and no way to leave the UI and the stored value
## disagreeing.
##
## THE DESTRUCTIVE ACTION:
## Reset requires TWO confirmations. A single "are you sure?" is muscle memory
## by the third time a player sees any dialog; the second step names what is
## about to be lost. Progress here is unrecoverable — there is no cloud save.

## Channels rendered as sliders, in mix order.
const CHANNELS: Array = [
	{"id": &"master", "label": "Master"},
	{"id": &"pad", "label": "Ambient Pad"},
	{"id": &"voice", "label": "Iris Voice"},
	{"id": &"sfx", "label": "Effects"},
]

const PRIVACY_URL: String = "https://ittybittybites.github.io/privacy-policy/"
const TERMS_URL: String = "https://ittybittybites.github.io/privacy-policy/terms/"

@onready var _background: ColorRect = %Background
@onready var _title: Label = %TitleLabel
@onready var _list: VBoxContainer = %SettingsList
@onready var _back_button: Button = %BackButton
@onready var _confirm_first: ConfirmationDialog = %ConfirmResetFirst
@onready var _confirm_second: ConfirmationDialog = %ConfirmResetSecond

var _state: IrisState = null
var _wired: bool = false


func _setup() -> void:
	_state = _resolve_state()

	_wired = (
		Log.must(_list != null, "Settings", "%SettingsList missing")
		and Log.must(_confirm_first != null, "Settings", "%ConfirmResetFirst missing")
		and Log.must(_confirm_second != null, "Settings", "%ConfirmResetSecond missing")
		and Log.must(_state != null, "Settings", "state failed to resolve")
	)
	if not _wired:
		return

	install_atmosphere()
	_back_button.pressed.connect(_on_back_pressed)
	# Restyle only. The confirmed/canceled wiring below is untouched.
	ArcaneTheme.apply(_confirm_first)
	ArcaneTheme.apply(_confirm_second)
	_confirm_first.confirmed.connect(_on_reset_first_confirmed)
	_confirm_second.confirmed.connect(_on_reset_second_confirmed)

	_confirm_first.dialog_text = "Reset all progress?"
	_confirm_second.dialog_text = (
		"This erases your rank, Lumina, cosmetics, streak and trial history.\n"
		+ "It cannot be undone.")

	_style()
	_build()


func _exit_tree() -> void:
	super()


func _resolve_state() -> IrisState:
	var incoming: Variant = payload.get("iris_state", null)
	if incoming is IrisState:
		return incoming as IrisState
	var state: IrisState = IrisState.new()
	var stored: Dictionary = Save.get_v("iris", "state", {})
	if not stored.is_empty():
		state.from_dict(stored)
	return state


func _operational(context: String) -> bool:
	if _wired and _state != null:
		return true
	Log.d("Settings", "not operational in %s" % context)
	return false


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_title.text = "Settings"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))


func _on_palette_changed(_tier: int) -> void:
	_style()
	_build()


# ═════════════════════════════════════════════════════════════════════════
# BUILD
# ═════════════════════════════════════════════════════════════════════════
func _build() -> void:
	if not _operational("_build"):
		return
	for child: Node in _list.get_children():
		child.queue_free()

	_add_section("Audio")
	_add_toggle("Sound", "audio_enabled", true, func(on: bool) -> void:
		AudioManager.set_enabled(on))
	for channel: Dictionary in CHANNELS:
		_add_channel_slider(channel["id"], str(channel["label"]))

	_add_section("Accessibility")
	_add_toggle("Haptic Feedback", "haptics", true, func(on: bool) -> void:
		HapticsManager.set_enabled(on)
		# Fire one pulse on enable so the player feels what they just turned on.
		if on:
			HapticsManager.pulse(&"ui_tap"))
	_add_toggle("High Contrast", "high_contrast", false, func(on: bool) -> void:
		Save.set_setting("high_contrast", on)
		Palette.refresh())
	_add_toggle("Colorblind Symbols", "colorblind", false, func(on: bool) -> void:
		Save.set_setting("colorblind", on)
		Palette.refresh())
	_add_toggle("Reduced Motion", "reduced_motion", false, func(on: bool) -> void:
		Save.set_setting("reduced_motion", on)
		Palette.refresh())

	# PRIVACY & DATA — the only place the two optional data switches live.
	#
	# They were removed from the first-run consent screen: both default OFF,
	# and an untouched switch is legally identical to no switch, so asking on
	# the very first screen was friction that bought nothing. Here a player
	# who wants to opt in can, and — the part that actually matters under
	# GDPR — a player who opted in can withdraw just as easily.
	#
	# Each writes through ConsentController rather than Save directly, so
	# there is exactly one writer for the consent section and one audit line
	# per change regardless of which screen triggered it.
	_add_section("Privacy & Data")
	_add_privacy_toggle(
		"Personalised Ads",
		"Use activity to choose which rewarded ads you see.",
		"personalized_ads",
		ConsentController.personalized_ads_allowed())
	_add_privacy_toggle(
		"Anonymous Analytics",
		"Share crash and usage data to help improve the game.",
		"analytics",
		ConsentController.analytics_allowed())
	_add_note("Both are off unless you turn them on. The game plays "
		+ "identically either way.")
	# Re-openable at any time so the terms can be re-read after acceptance.
	_add_button("Review Privacy Terms", func() -> void:
		AudioManager.play_sfx(&"ui_tap")
		await Router.go("consent", {"revisit": true}))

	_add_section("About")
	_add_link("Privacy Policy", PRIVACY_URL)
	_add_link("Terms & Conditions", TERMS_URL)
	_add_note("Two Second Witness is free to play. No purchases, ever — "
		+ "cosmetics are earned through play, rewarded ads, or surprise drops.")

	_add_section("Help")
	# THE BRIEFINGS MUST BE RE-READABLE.
	#
	# Each trial explains itself once, on first entry, and then never again.
	# A player who tapped past it — or who tested an early build before the
	# briefings existed — had no way back to the rules and no way to find out
	# what a mode wanted. Clearing the seen-list makes every mode teach itself
	# again on next entry.
	_add_button("Show Trial Instructions Again", func() -> void:
		AudioManager.play_sfx(&"ui_tap")
		Save.set_v(Save.SEC_META, "tutorials_seen", [])
		Save.flush()
		Bus.toast.emit("Instructions will show again", "?"))
	_add_note("Each trial explains itself the first time you play it. "
		+ "This brings those explanations back.")

	_add_section("Data")
	_add_danger_button("Reset All Progress", func() -> void:
		AudioManager.play_sfx(&"ui_tap")
		_confirm_first.popup_centered())


func _add_section(title: String) -> void:
	var label: Label = Label.new()
	label.text = title.to_upper()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.accent())
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	_list.add_child(label)


## A labelled slider bound to one audio channel. Applies live so the player
## hears the change while dragging, with a tap cue on release to audition it.
func _add_channel_slider(channel: StringName, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", int(Palette.SPACE_SM))

	var label: Label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(Palette.LABEL_MIN_WIDTH, 0.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	row.add_child(label)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = AudioManager.channel_level(channel)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0.0, Palette.MIN_TOUCH_TARGET)
	slider.value_changed.connect(func(value: float) -> void:
		AudioManager.set_channel_level(channel, value))
	slider.drag_ended.connect(func(_changed: bool) -> void:
		AudioManager.play_sfx(&"ui_tap"))
	row.add_child(slider)

	_list.add_child(row)


func _add_toggle(label_text: String, key: String, fallback: bool,
		on_changed: Callable) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", int(Palette.SPACE_SM))

	var label: Label = Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	row.add_child(label)

	var button: CheckButton = CheckButton.new()
	# A bare CheckButton renders 44x27, under the 48px accessibility
	# minimum on every viewport. Measured, not assumed — see
	# tools/polish_audit.gd.
	button.custom_minimum_size = Vector2(Palette.MIN_TOUCH_TARGET,
		Palette.MIN_TOUCH_TARGET)
	button.button_pressed = bool(Save.setting(key, fallback))
	button.toggled.connect(func(pressed: bool) -> void:
		AudioManager.play_sfx(&"ui_tap")
		on_changed.call(pressed))
	row.add_child(button)

	_list.add_child(row)


## A privacy switch with its own explanatory caption.
##
## Distinct from _add_toggle(): that one reads and writes the SETTINGS section
## for preferences, while consent lives in its own save section with its own
## writer, audit line and Bus event. Routing a legal choice through the
## generic preference path is how it would eventually get written without one.
##
## Nothing is pre-ticked. `initial` is read from what is actually stored, so
## the switch reflects reality rather than an assumption about it.
func _add_privacy_toggle(label_text: String, detail: String, key: String,
		initial: bool) -> void:
	var block: VBoxContainer = VBoxContainer.new()
	block.add_theme_constant_override("separation", int(Palette.SPACE_XXS))

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", int(Palette.SPACE_SM))

	var label: Label = Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	row.add_child(label)

	var button: CheckButton = CheckButton.new()
	# A bare CheckButton renders 44x27, under the 48px accessibility
	# minimum on every viewport. Measured, not assumed — see
	# tools/polish_audit.gd.
	button.custom_minimum_size = Vector2(Palette.MIN_TOUCH_TARGET,
		Palette.MIN_TOUCH_TARGET)
	button.button_pressed = initial
	button.toggled.connect(func(pressed: bool) -> void:
		AudioManager.play_sfx(&"ui_tap")
		ConsentController.set_privacy_choice(key, pressed))
	row.add_child(button)
	block.add_child(row)

	var caption: Label = Label.new()
	caption.text = detail
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	caption.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	block.add_child(caption)

	_list.add_child(block)


func _add_button(label_text: String, on_pressed: Callable) -> void:
	var button: Button = Button.new()
	button.text = label_text
	button.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_MD)
	button.pressed.connect(on_pressed)
	_list.add_child(button)


func _add_link(label_text: String, url: String) -> void:
	var button: Button = Button.new()
	button.text = label_text
	button.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_MD)
	button.pressed.connect(func() -> void:
		AudioManager.play_sfx(&"ui_tap")
		OS.shell_open(url))
	_list.add_child(button)


func _add_note(text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	_list.add_child(label)


func _add_danger_button(label_text: String, on_pressed: Callable) -> void:
	var button: Button = Button.new()
	button.text = label_text
	button.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_MD)
	button.add_theme_color_override("font_color", Palette.danger())
	button.pressed.connect(on_pressed)
	_list.add_child(button)


# ═════════════════════════════════════════════════════════════════════════
# RESET — two-step confirmation
# ═════════════════════════════════════════════════════════════════════════
## First gate. Deliberately does NOT reset; it opens the second dialog, which
## names exactly what will be destroyed.
func _on_reset_first_confirmed() -> void:
	_confirm_second.popup_centered()


func _on_reset_second_confirmed() -> void:
	if not _operational("_on_reset_second_confirmed"):
		return
	Log.warn("Settings", "player confirmed full progress reset")

	_state = IrisState.new()
	TrialRegistry.ensure_history(_state)

	Save.set_v("iris", "state", _state.to_dict())
	Save.set_v(Save.SEC_DAILY, "last_day_index", -1)
	Save.set_v(Save.SEC_DAILY, "streak", 0)
	Save.set_v(Save.SEC_DAILY, "best_streak", 0)
	Save.flush()

	AudioManager.play_sfx(&"error")
	Bus.toast.emit("Progress reset", "✧")
	await Router.go("hub", {"iris_state": _state})


## THE await IS LOAD-BEARING. DO NOT REMOVE IT.
##
## Router.back() is a coroutine — it ends in `await _swap(...)`. GDScript runs
## an un-awaited coroutine only as far as its FIRST await and then abandons it,
## with no error and no warning. So `Router.back()` without await advanced the
## router exactly zero routes and the player was trapped on this screen with a
## Back button that looked perfectly normal and did nothing.
##
## Every on-screen Back button in the app had this bug. Only app.gd's system
## back handler awaited correctly, which is why the Android back gesture worked
## while the button did not.
func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


## Back closes an open confirmation rather than leaving the screen, so a
## mis-tap on a destructive dialog cannot be resolved by accident.
func on_back_requested() -> bool:
	if _confirm_second != null and _confirm_second.visible:
		_confirm_second.hide()
		return true
	if _confirm_first != null and _confirm_first.visible:
		_confirm_first.hide()
		return true
	return false
