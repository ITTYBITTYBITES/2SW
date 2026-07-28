extends RefCounted
class_name ArcaneTheme

## ArcaneTheme — dark carved styling for engine-owned Windows.
##
## THE PROBLEM THIS SOLVES
## ConfirmationDialog is a Window, not a Control. Palette.panel_style() cannot
## reach it: a Window renders through the platform's own embedded-popup path
## and takes its look from a Theme, not from a theme_override on a parent.
## So the three dialogs in this app — two reset confirmations and the trial
## forfeit — rendered with Godot's stock grey chrome against an otherwise
## carved teal-on-black app.
##
## NON-DESTRUCTIVE BY CONSTRUCTION
## This builds a Theme resource and assigns it. It touches no signal, no
## button text, no confirmed/canceled wiring, and no dialog logic. Remove the
## one apply() call and the dialogs behave exactly as before, just grey again.
##
## WHY A THEME AND NOT A REPLACEMENT PANEL
## Wrapping each dialog in a custom Control would mean reimplementing modal
## focus capture, escape-to-dismiss, button ordering per platform, and screen
## centring — all of which Window already does correctly. Restyling is the
## smaller and safer change.

## Applied to every dialog so they cannot drift apart.
static func apply(dialog: Window) -> void:
	if not Log.must(dialog != null, "ArcaneTheme", "apply got null dialog"):
		return
	dialog.theme = build()
	# The scrim behind an embedded dialog is a Window property, not a theme
	# entry, so it is set alongside rather than inside the Theme.
	dialog.transparent_bg = false


## The shared Theme resource. Built fresh per dialog rather than cached: a
## rank-up changes the accent, and a shared instance would leave already-open
## dialogs on the previous tier.
static func build() -> Theme:
	var built := Theme.new()
	var accent: Color = Palette.accent()

	built.set_stylebox("panel", "AcceptDialog", _panel(accent))
	built.set_stylebox("embedded_border", "Window", _titlebar(accent))
	built.set_stylebox("embedded_unfocused_border", "Window", _titlebar(accent))

	built.set_color("title_color", "Window", Palette.COLOR_TEXT)
	built.set_color("font_color", "AcceptDialog", Palette.COLOR_TEXT)
	built.set_font_size("title_font_size", "Window",
		Palette.font(Palette.FONT_BODY))

	_style_buttons(built, accent)
	return built


## The dialog body: the same carved plate the rest of the app uses.
static func _panel(accent: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	var fill: Color = Palette.COLOR_SURFACE_HIGH
	fill.a = Palette.PANEL_OPACITY
	box.bg_color = fill
	box.set_corner_radius_all(Palette.RADIUS_LG)

	var lit: Color = accent
	lit.a = 0.34
	box.border_color = lit
	box.set_border_width_all(1)
	box.border_width_top = 2

	box.shadow_color = Palette.COLOR_MODAL_SHADOW
	box.shadow_size = int(Palette.SPACE_MD)
	box.shadow_offset = Vector2(0.0, 4.0)

	box.content_margin_left = Palette.SPACE_LG
	box.content_margin_right = Palette.SPACE_LG
	box.content_margin_top = Palette.SPACE_MD
	box.content_margin_bottom = Palette.SPACE_MD
	return box


## The title bar, brighter than the body so the dialog reads as headed.
static func _titlebar(accent: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	var fill: Color = Palette.COLOR_SURFACE_HIGH
	fill.a = Palette.PANEL_OPACITY
	box.bg_color = fill
	box.set_corner_radius_all(Palette.RADIUS_LG)
	box.corner_radius_bottom_left = 0
	box.corner_radius_bottom_right = 0

	var lit: Color = accent
	lit.a = 0.55
	box.border_color = lit
	box.set_border_width_all(1)
	box.border_width_top = 2
	box.expand_margin_top = float(Palette.SPACE_LG)
	return box


## Dialog buttons. Carved, with the accent carrying the focus state — the
## stock Godot button is a light grey slab and is the single most obvious
## thing that made these dialogs look unfinished.
static func _style_buttons(target: Theme, accent: Color) -> void:
	target.set_stylebox("normal", "Button", _button(accent, 0.0))
	target.set_stylebox("hover", "Button", _button(accent, 0.30))
	target.set_stylebox("pressed", "Button", _button(accent, 0.52))
	target.set_stylebox("focus", "Button", _button(accent, 0.42))
	target.set_stylebox("disabled", "Button", _button(accent, -0.35))

	target.set_color("font_color", "Button", Palette.COLOR_TEXT)
	target.set_color("font_hover_color", "Button", Palette.COLOR_TEXT)
	target.set_color("font_pressed_color", "Button", accent.lightened(0.45))
	target.set_color("font_disabled_color", "Button", Palette.COLOR_TEXT_FAINT)
	target.set_font_size("font_size", "Button", Palette.font(Palette.FONT_BODY))


static func _button(accent: Color, lift: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	var fill: Color = Palette.COLOR_SURFACE
	if lift > 0.0:
		fill = fill.lerp(accent, lift * 0.28)
	elif lift < 0.0:
		fill = fill.darkened(-lift)
	fill.a = Palette.PANEL_OPACITY
	box.bg_color = fill
	box.set_corner_radius_all(Palette.RADIUS_SM)

	var edge: Color = accent
	edge.a = clampf(0.30 + lift * 0.9, 0.08, 1.0)
	box.border_color = edge
	box.set_border_width_all(1)
	box.border_width_top = 2

	box.content_margin_left = Palette.SPACE_LG
	box.content_margin_right = Palette.SPACE_LG
	box.content_margin_top = Palette.SPACE_SM
	box.content_margin_bottom = Palette.SPACE_SM
	return box
