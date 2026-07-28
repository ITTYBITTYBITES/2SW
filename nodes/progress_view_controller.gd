extends Screen
class_name ProgressViewController
## ProgressViewController — cognitive performance analytics.
##
## PHASE 9. READ-ONLY. Renders adaptive history and progression totals; it
## never records an attempt, awards currency, or writes to Save.
##
## WHAT THIS SCREEN IS FOR:
## Adaptive difficulty is deliberately invisible during play — the game just
## stays near the player's edge. But invisible systems feel arbitrary if the
## player can NEVER see them. This is the one place the machinery is exposed:
## current bracket, trend, and how close they are to moving. Seeing "2 more
## strong runs" turns a hidden system into a goal.

const TREND_NONE: int = 0
const TREND_PROMOTED: int = 1
const TREND_DEMOTED: int = 2

@onready var _background: ColorRect = %Background
@onready var _title: Label = %TitleLabel
@onready var _rank_label: Label = %RankLabel
@onready var _rank_bar: ProgressBar = %RankBar
@onready var _totals_label: Label = %TotalsLabel
@onready var _trial_list: VBoxContainer = %TrialList
@onready var _back_button: Button = %BackButton

var _state: IrisState = null
var _wired: bool = false


func _setup() -> void:
	_state = _resolve_state()

	_wired = (
		Log.must(_trial_list != null, "Progress", "%TrialList missing")
		and Log.must(_rank_bar != null, "Progress", "%RankBar missing")
		and Log.must(_state != null, "Progress", "state failed to resolve")
	)
	if not _wired:
		return

	install_atmosphere()

	# Guarantee every registered trial has a row, including ones never played.
	TrialRegistry.ensure_history(_state)

	_back_button.pressed.connect(_on_back_pressed)
	_style()
	_refresh()


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
	state.reduced_motion = Palette.reduced_motion()
	return state


func _operational(context: String) -> bool:
	if _wired and _state != null:
		return true
	Log.d("Progress", "not operational in %s" % context)
	return false


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_title.text = "Progress"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))
	_rank_label.add_theme_color_override("font_color", Palette.accent())
	_rank_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_HEADING))
	_totals_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	_totals_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	_rank_bar.add_theme_stylebox_override("background",
		Palette.bar_style(Palette.COLOR_HAIRLINE))
	_rank_bar.add_theme_stylebox_override("fill", Palette.bar_style(Palette.accent()))


func _on_palette_changed(_tier: int) -> void:
	_style()
	_refresh()


# ═════════════════════════════════════════════════════════════════════════
# RENDER
# ═════════════════════════════════════════════════════════════════════════
func _refresh() -> void:
	if not _operational("_refresh"):
		return

	_rank_label.text = "%s  ·  Rank %d" % [
		_state.current_rank_title(), _state.rank_tier]
	_rank_bar.value = clampf(_state.rank_progress(), 0.0, 1.0)

	_totals_label.text = _totals_text()
	_build_trial_rows()


## Overall progression, in one line per fact rather than a dense block.
func _totals_text() -> String:
	var lines: PackedStringArray = []
	lines.append("%s ✦ Lumina    %.0f ◈ Resonance" % [
		_state.lumina, _state.lens_shimmer])
	lines.append("%d XP    %d to next rank" % [
		_state.rank_xp, _state.xp_to_next_rank()])
	lines.append("%d trials completed" % _state.trials_completed)
	if _state.trials_completed > 0:
		lines.append("avg %.1fs per trial" % (
			_state.total_trial_seconds / float(_state.trials_completed)))
	lines.append("longest streak  %d days" % _state.best_streak_days)
	return "\n".join(lines)


## One row per trial. Always covers the full roster — a trial the player has
## never touched still shows, so the suite reads as complete rather than
## mysteriously partial.
func _build_trial_rows() -> void:
	for child: Node in _trial_list.get_children():
		child.queue_free()

	for row: Dictionary in AdaptiveDifficulty.summary(_state):
		_trial_list.add_child(_build_row(row))


func _build_row(row: Dictionary) -> Control:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_constant_override("separation", int(Palette.SPACE_XXS))

	var plays: int = int(row.get("plays", 0))

	# Header: name + bracket + trend.
	var header: HBoxContainer = HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var name_label: Label = Label.new()
	name_label.text = str(row.get("name", "?"))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	name_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))
	header.add_child(name_label)

	var bracket_label: Label = Label.new()
	bracket_label.text = "%s %s" % [
		str(row.get("bracket_name", "Easy")), _trend_glyph(int(row.get("last_shift", 0)))]
	bracket_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bracket_label.add_theme_color_override("font_color",
		_trend_colour(int(row.get("last_shift", 0))))
	bracket_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	header.add_child(bracket_label)
	panel.add_child(header)

	# Stats line.
	var stats: Label = Label.new()
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if plays <= 0:
		stats.text = "not yet attempted"
	else:
		stats.text = "%d%% avg   ·   best %d%%   ·   %.1fs   ·   %d plays" % [
			int(round(float(row.get("average", 0.0)) * 100.0)),
			int(round(float(row.get("best", 0.0)) * 100.0)),
			float(row.get("avg_seconds", 0.0)),
			plays,
		]
	stats.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	stats.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	panel.add_child(stats)

	# Adaptation hint — the part that makes the hidden system legible.
	var hint: Label = Label.new()
	hint.text = _hint_text(row, plays)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	hint.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	panel.add_child(hint)

	return panel


## Turn the raw counters into one honest sentence. Only ever reports the run
## the player is actually on, so it can't promise a promotion they aren't
## close to.
func _hint_text(row: Dictionary, plays: int) -> String:
	if plays <= 0:
		return "play to begin tracking"
	var hint: Dictionary = row.get("hint", {})
	var promote_run: int = int(hint.get("promote_run", 0))
	var demote_run: int = int(hint.get("demote_run", 0))
	var to_promote: int = int(hint.get("to_promote", 0))
	var to_demote: int = int(hint.get("to_demote", 0))
	var bracket: int = int(row.get("bracket", 0))

	if promote_run > 0 and bracket < AdaptiveDifficulty.MAX_BRACKET:
		return "%d more strong run%s to advance" % [to_promote, "" if to_promote == 1 else "s"]
	if demote_run > 0 and bracket > AdaptiveDifficulty.MIN_BRACKET:
		return "%d more low run%s will ease difficulty" % [to_demote, "" if to_demote == 1 else "s"]
	if bracket >= AdaptiveDifficulty.MAX_BRACKET:
		return "at maximum difficulty"
	return "difficulty steady"


func _trend_glyph(shift: int) -> String:
	match shift:
		TREND_PROMOTED: return "▲"
		TREND_DEMOTED: return "▼"
	return "·"


func _trend_colour(shift: int) -> Color:
	match shift:
		TREND_PROMOTED: return Palette.success()
		TREND_DEMOTED: return Palette.COLOR_WARNING
	return Palette.COLOR_TEXT_DIM


func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


func on_back_requested() -> bool:
	return false
