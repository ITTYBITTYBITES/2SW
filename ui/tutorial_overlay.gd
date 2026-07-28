extends Control
class_name TutorialOverlay

## TutorialOverlay — the one-time briefing shown before a player's first run
## of a trial mode.
##
## WHY THIS EXISTS
## A first-time player was dropped straight into a timed round with nothing on
## screen explaining the objective, what to look at, or that tapping was the
## interaction at all. The build was working; it was simply unexplained, which
## for a new player is indistinguishable from broken.
##
## IT HOLDS THE CLOCK. The trial's timer and its mini-game do not start until
## this is dismissed. A briefing that eats the player's first 2.5-second
## window would teach them the game is unfair, which is worse than no briefing.
##
## ONE SCREEN, THREE LINES, ONE BUTTON. Content comes from
## data/tutorial_script.gd; this class owns none of it and only lays it out.
##
## ZERO ASSETS. Scrim, plate and rule are _draw() geometry in Palette tokens.

signal dismissed

## Emitted so the host can start the run. Distinct from `dismissed` so a test
## can tell "the player tapped" from "the trial was released".
@warning_ignore("unused_signal")
signal ready_to_play

var _title: Label = null
var _button: Button = null
var _built: bool = false


func _ready() -> void:
	# ANCHORS ALONE DO NOT SIZE THIS.
	#
	# set_anchors_preset() sets anchors but does not resize a Control whose
	# parent has not laid out yet, and a Control added from code inside
	# _setup() is exactly that case. Measured: anchors read 1.0/1.0 while size
	# stayed (0, 0), so the centred column laid itself out around the origin
	# and rendered off the top-left corner of the screen.
	#
	# set_anchors_and_offsets_preset() writes the offsets too, which resolves
	# to a real rect on the next sort, and the explicit size below covers the
	# current frame so the very first _draw() is already correct.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var host: Control = get_parent() as Control
	if host != null:
		size = host.size
		position = Vector2.ZERO
	# The overlay swallows input while it is up: a tap meant for "Begin" must
	# never fall through to a glyph underneath it.
	mouse_filter = Control.MOUSE_FILTER_STOP


## Build and show the briefing for a trial. Safe to call once.
func present(trial_id: String) -> void:
	if _built:
		return
	_built = true
	var script: Dictionary = TutorialScript.for_trial(trial_id)

	# PRESET_FULL_RECT with keep_offsets, then inset. Using the preset alone
	# and then writing offset_left/right leaves anchor_right at 0 unless the
	# preset actually applied — the first version collapsed the whole column
	# into the top-left corner at its minimum size, which the first render of
	# this overlay showed plainly.
	var column := VBoxContainer.new()
	column.anchor_left = 0.0
	column.anchor_top = 0.0
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.offset_left = Palette.SPACE_HUGE
	column.offset_right = -Palette.SPACE_HUGE
	column.offset_top = 0.0
	column.offset_bottom = 0.0
	column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	column.grow_vertical = Control.GROW_DIRECTION_BOTH
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", int(Palette.SPACE_MD))
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	_title = _make_label(str(script.get("title", "Trial")),
		Palette.FONT_HEADING, Palette.COLOR_TEXT)
	column.add_child(_title)

	var rule := HSeparator.new()
	rule.add_theme_constant_override("separation", int(Palette.SPACE_MD))
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)

	column.add_child(_make_label(str(script.get("objective", "")),
		Palette.FONT_BODY, Palette.COLOR_TEXT))
	column.add_child(_make_label(str(script.get("observe", "")),
		Palette.FONT_SMALL, Palette.COLOR_TEXT_DIM))
	column.add_child(_make_label(str(script.get("act", "")),
		Palette.FONT_SMALL, Palette.accent()))

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, Palette.SPACE_LG)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(spacer)

	_button = Button.new()
	_button.name = "BeginButton"
	_button.text = "Begin"
	_button.custom_minimum_size = Vector2(
		Palette.LABEL_MIN_WIDTH, Palette.CONTROL_HEIGHT_LG)
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_BODY))
	_button.pressed.connect(_on_begin_pressed)
	column.add_child(_button)

	_button.grab_focus()
	queue_redraw()


func _make_label(text: String, size_token: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", colour)
	label.add_theme_font_size_override("font_size", Palette.font(size_token))
	return label


func _on_begin_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	HapticsManager.pulse(&"ui_tap")
	dismissed.emit()
	queue_free()


## The button, so a test can press it rather than calling the handler.
func begin_button() -> Button:
	return _button


func is_presented() -> bool:
	return _built


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	# Scrim over the whole screen, so the field behind reads as inactive.
	draw_rect(Rect2(Vector2.ZERO, size), Palette.COLOR_SCRIM, true)

	# A carved plate behind the text, in the same language as the HUD bezels.
	var plate_w: float = minf(size.x - Palette.SPACE_HUGE, size.x * 0.86)
	var plate_h: float = minf(size.y * 0.52, size.y - Palette.SPACE_HUGE)
	var plate := Rect2(
		Vector2((size.x - plate_w) * 0.5, (size.y - plate_h) * 0.5),
		Vector2(plate_w, plate_h))

	draw_rect(plate, Palette.COLOR_BEZEL_PLATE, true)

	var unit: float = minf(plate.size.x, plate.size.y)
	var metal: Color = Palette.COLOR_BEZEL_METAL
	metal.a = 0.85
	draw_rect(plate, metal, false, maxf(unit * 0.010, 2.0))

	# The divider under the title is a real HSeparator in the column, not a
	# line drawn here: a _draw() rule at a fixed fraction of the plate cannot
	# know where the title actually ended, and the first version put it ABOVE
	# the heading.
