extends Screen
class_name ChronoResultCard
## ChronoResultCard — the shareable summary of today's anomaly.
##
## PHASE 3. Compact, spoiler-free, and legible at a glance: date, streak, a
## precision tier badge, and five abstract pulse bars.
##
## ═══════════════════════════════════════════════════════════════════════════
## WHY THE BARS ARE ABSTRACT
## ═══════════════════════════════════════════════════════════════════════════
## The card exists to be screenshotted and sent to someone who has NOT played
## yet. So it may show how well you did, and may not show anything that helps
## the recipient do well. A millisecond count is the worst offender — "412ms"
## tells a friend exactly how fast to be — so the card quantises to five
## buckets and never prints the raw latency.
##
## ChronoPulse.verify_share_is_spoiler_free() enforces this on the real string
## at export time, not only in tests, because a leak that reaches someone's
## chat cannot be recalled.
##
## ZERO ASSETS: the bars are _draw() geometry, like every other visual in this
## project. No PNG, no texture, no font file.

## Bars drawn, always. Unfilled ones show as hollow outlines so the card has a
## stable shape whatever the result — a five-bar card and a one-bar card
## occupy the same space and read as comparable.
const BAR_COUNT: int = 5

## Card width cap. Held to a readable measure rather than the full screen, and
## shrunk to fit when the viewport is narrower. Matches the consent gate's
## approach, including the scrollbar gutter compensation.
const CARD_MAX_WIDTH: float = 720.0

@onready var _background: ColorRect = %Background
@onready var _root: MarginContainer = %Root
@onready var _scroll: ScrollContainer = %Scroll
@onready var _card: PanelContainer = %Card
@onready var _date_label: Label = %DateLabel
@onready var _streak_label: Label = %StreakLabel
@onready var _tier_badge: Label = %TierBadge
@onready var _bars: Control = %PulseBars
@onready var _caption: Label = %CaptionLabel
@onready var _share_button: Button = %ShareButton
@onready var _done_button: Button = %DoneButton

var _wired: bool = false
var _record: Dictionary = {}
var _streak: int = 0


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	# This screen folds the safe area into its own MarginContainer;
	# the base class must not offset it a second time.
	handles_own_safe_area = true
	_wired = (
		Log.must(_card != null, "ChronoCard", "%Card missing")
		and Log.must(_bars != null, "ChronoCard", "%PulseBars missing")
		and Log.must(_share_button != null, "ChronoCard", "%ShareButton missing")
	)
	if not _wired:
		return

	# The record arrives via payload. Falling back to the stored one means
	# the card still renders if it is reached by a resumed session rather
	# than straight from a completed run.
	var incoming: Variant = payload.get("record", null)
	if incoming is Dictionary and not (incoming as Dictionary).is_empty():
		_record = incoming as Dictionary
	else:
		_record = ChronoPulseController.today_record()

	_streak = int(payload.get("streak", 0))
	if _streak <= 0:
		_streak = int(Save.get_v(ChronoPulse.SECTION,
			ChronoPulse.KEY_CURRENT_STREAK, 0))

	_share_button.pressed.connect(_on_share_pressed)
	_done_button.pressed.connect(_on_done_pressed)
	_scroll.get_v_scroll_bar().visibility_changed.connect(_layout)

	# The bars paint themselves; the card only tells them when to repaint.
	_bars.draw.connect(_draw_bars)

	# No _layout() here: Screen defers the first call for us, and geometry is
	# not valid during _setup() anyway. Calling it would measure a stale rect.
	_style()
	_refresh()


func _exit_tree() -> void:
	# `resized` is owned by Screen, which connects it to the layout hook and
	# tears it down itself. This used to disconnect it here too — a leftover
	# from the hand-rolled _apply_layout era that ran against a connection
	# this class no longer makes.
	if _scroll != null:
		var bar: VScrollBar = _scroll.get_v_scroll_bar()
		if bar != null and bar.visibility_changed.is_connected(_layout):
			bar.visibility_changed.disconnect(_layout)
	if _bars != null and _bars.draw.is_connected(_draw_bars):
		_bars.draw.disconnect(_draw_bars)
	super()


func _operational(context: String) -> bool:
	if _wired:
		return true
	Log.d("ChronoCard", "not operational in %s" % context)
	return false


# ═════════════════════════════════════════════════════════════════════════
# LAYOUT
# ═════════════════════════════════════════════════════════════════════════
## Size the card from the LIVE viewport, never a design constant.
##
## Identical treatment to the consent gate, for the same reason and with the
## same scrollbar correction: a visible vertical bar consumes width from the
## right edge only, so a card centred in the remainder sits half a bar width
## off true centre. The gutter is reserved in the WIDTH unconditionally to
## avoid a visibility/width feedback loop.
func _layout() -> void:
	if not _operational("_layout"):
		return

	var bar: VScrollBar = _scroll.get_v_scroll_bar()
	var gutter: float = 0.0
	if bar != null:
		gutter = maxf(bar.size.x, bar.get_minimum_size().x)

	var margin: float = Palette.SPACE_XL
	var shift: float = gutter if (bar != null and bar.visible) else 0.0
	_root.add_theme_constant_override("margin_left", int(margin + shift))
	_root.add_theme_constant_override("margin_right", int(margin))
	_root.add_theme_constant_override("margin_top", int(maxf(safe_top, Palette.SPACE_LG)))
	_root.add_theme_constant_override("margin_bottom",
		int(maxf(safe_bottom, Palette.SPACE_LG)))

	var available: float = size.x - margin * 2.0 - gutter
	_card.custom_minimum_size = Vector2(maxf(minf(CARD_MAX_WIDTH, available), 1.0), 0.0)
	_bars.queue_redraw()


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_card.add_theme_stylebox_override("panel", Palette.panel_style(true))

	_date_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	_date_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))

	_streak_label.add_theme_color_override("font_color", Palette.accent())
	_streak_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_DISPLAY))

	_tier_badge.add_theme_color_override("font_color", _tier_colour())
	_tier_badge.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_HEADING))

	_caption.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_caption.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))


func _on_palette_changed(_tier: int) -> void:
	_style()
	# A palette change resizes fonts, which changes measured geometry without
	# resizing the screen. request_layout() clears the base class's
	# size-change guard so the re-measure is not skipped as a no-op.
	request_layout()
	_refresh()


# ═════════════════════════════════════════════════════════════════════════
# CONTENT
# ═════════════════════════════════════════════════════════════════════════
func _refresh() -> void:
	if not _operational("_refresh"):
		return

	if _record.is_empty():
		# Reachable if the card is opened before today has been played.
		# Rendering an honest empty state beats rendering a fake perfect one.
		_date_label.text = ChronoPulse.current_seed()
		_streak_label.text = "—"
		_tier_badge.text = "Not yet run"
		_caption.text = "Today's anomaly is waiting."
		_share_button.disabled = true
		_bars.queue_redraw()
		return

	_share_button.disabled = false
	_date_label.text = "CHRONO-PULSE  ·  %s" % str(_record.get("seed_id", ""))
	_streak_label.text = "%d" % _streak

	var tier_id: StringName = StringName(str(_record.get("tier", "missed")))
	_tier_badge.text = ChronoPulse.tier_label(tier_id)
	_tier_badge.add_theme_color_override("font_color", _tier_colour())

	var day_word: String = "day streak" if _streak != 1 else "day"
	_caption.text = "%s  ·  local time, %d day grace" % [
		day_word, ChronoPulse.GRACE_DAYS]

	_bars.queue_redraw()


func _tier_colour() -> Color:
	var tier_id: StringName = StringName(str(_record.get("tier", "missed")))
	if tier_id == ChronoPulse.TIER_MISSED:
		return Palette.danger()
	var rank: int = ChronoPulse.tier_rank(tier_id)
	if rank <= 1:
		return Palette.success()
	if rank <= 2:
		return Palette.accent()
	return Palette.COLOR_WARNING


# ═════════════════════════════════════════════════════════════════════════
# PULSE BARS — procedural, zero assets
# ═════════════════════════════════════════════════════════════════════════
## Five bars. Filled ones carry the tier colour; the rest are hollow outlines,
## so the card keeps a constant silhouette regardless of score.
##
## Deliberately coarse. The bar count IS the score as far as the card is
## concerned — there is no finer readout to leak.
func _draw_bars() -> void:
	if not Log.must(_bars != null, "ChronoCard", "_draw_bars with no %PulseBars"):
		return

	var filled: int = 0
	if not _record.is_empty():
		filled = clampi(int(_record.get("bars", 0)), 0, BAR_COUNT)

	var region: Vector2 = _bars.size
	if region.x <= 1.0 or region.y <= 1.0:
		return

	var gap: float = Palette.SPACE_XS
	var bar_width: float = (region.x - gap * float(BAR_COUNT - 1)) / float(BAR_COUNT)
	if bar_width <= 0.0:
		return

	var fill_colour: Color = _tier_colour()
	var radius: float = minf(float(Palette.RADIUS_SM), bar_width * 0.5)

	for i: int in range(BAR_COUNT):
		var x: float = float(i) * (bar_width + gap)
		# Filled bars step upward so the row reads as a rising pulse rather
		# than a flat meter — the same information, more legible at a glance.
		var height_scale: float = 0.45 + 0.55 * (float(i + 1) / float(BAR_COUNT))
		var bar_height: float = region.y * height_scale
		var y: float = region.y - bar_height
		var rect: Rect2 = Rect2(Vector2(x, y), Vector2(bar_width, bar_height))

		if i < filled:
			_bars.draw_rect(rect, fill_colour, true)
		else:
			var hollow: Color = Palette.COLOR_TEXT_FAINT
			_bars.draw_rect(rect, hollow, false, maxf(radius * 0.25, 1.5))


# ═════════════════════════════════════════════════════════════════════════
# ACTIONS
# ═════════════════════════════════════════════════════════════════════════
func _on_share_pressed() -> void:
	if not _operational("_on_share_pressed"):
		return
	AudioManager.play_sfx(&"ui_tap")

	# copy_share_text re-verifies the string is spoiler-free before it touches
	# the clipboard, and returns false if the platform has none.
	if ChronoPulseController.copy_share_text(_record, _streak):
		HapticsManager.pulse(&"ui_tap")
		Bus.toast.emit("Result copied", "✦")
		return

	# Never claim success we did not achieve. A button that says "Copied" on a
	# platform with no clipboard is worse than one that admits it failed.
	Bus.toast.emit("Copy unavailable on this device", "✧")


func _on_done_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


func on_back_requested() -> bool:
	return false
