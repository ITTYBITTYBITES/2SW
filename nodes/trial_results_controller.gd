extends Screen
class_name TrialResultsController
## TrialResultsController — animated settlement summary.
##
## PHASE 7. READ-ONLY. Settlement already happened in TrialController; this
## screen only *displays* the summary. It never awards, never grants a seed,
## and never writes to Save — otherwise a player could farm rewards by
## re-entering results.
##
## v1's Results screen re-read globals and recomputed values, which meant the
## numbers shown could disagree with the numbers banked. Here the summary
## dictionary is the single source of truth.

## Stagger between reveal steps so tallies land as separate beats.
const STEP_DELAY: float = 0.28
const COUNT_DURATION: float = 0.65

## The action row's sizing budget. Below ACTION_MIN_WIDTH per button the row
## stacks vertically rather than letting a button run off the screen edge.
const ACTION_MIN_WIDTH: float = 240.0
const ACTION_MAX_WIDTH: float = 320.0
const ACTION_HEIGHT: float = Palette.CONTROL_HEIGHT_LG

@onready var _background: ColorRect = %Background
@onready var _title: Label = %TitleLabel
@onready var _accuracy_label: Label = %AccuracyLabel
@onready var _time_label: Label = %TimeLabel
@onready var _lumina_label: Label = %LuminaLabel
@onready var _breakdown_label: Label = %BreakdownLabel
@onready var _rank_label: Label = %RankLabel
@onready var _xp_bar: ProgressBar = %XPBar
@onready var _actions: BoxContainer = %Actions
@onready var _retry_button: Button = %RetryButton
@onready var _hub_button: Button = %HubButton
@onready var _celebration: Control = %CelebrationModal
@onready var _celebration_label: Label = %CelebrationLabel
@onready var _celebration_claim: Button = %CelebrationClaimButton

var _summary: Dictionary = {}
var _state: IrisState = null
var _wired: bool = false
var _displayed_lumina: int = 0


func _setup() -> void:
	_summary = payload.get("summary", {})
	var incoming: Variant = payload.get("iris_state", null)
	_state = incoming as IrisState if incoming is IrisState else null

	_wired = (
		Log.must(_title != null, "Results", "%TitleLabel missing")
		and Log.must(_xp_bar != null, "Results", "%XPBar missing")
		and Log.must(_celebration != null, "Results", "%CelebrationModal missing")
	)
	if not _wired:
		return

	if _summary.is_empty():
		Log.warn("Results", "no summary payload; showing empty state")

	_retry_button.pressed.connect(_on_retry)
	_hub_button.pressed.connect(_on_hub)
	_celebration_claim.pressed.connect(_hide_celebration)

	_style()
	_hide_celebration()
	_animate_reveal()


## Keep the two action buttons inside a narrow screen.
##
## THE BUG THIS FIXES: the buttons carried a fixed 288px minimum each. Side
## by side with a 24px gap that needs 600px of width, so at 360px wide the
## row overflowed by 120px and "Return to Hub" ran off the right edge —
## unreachable. Below roughly 640px of width the row is stacked instead.
##
## The buttons are also the ONLY way off this screen: trial_results is in
## App.NO_RESUME and on_back_requested() is not overridden, so a player
## who cannot reach a button is stuck.
func _layout() -> void:
	if not _operational("_layout"):
		return
	var gap: float = Palette.SPACE_LG
	var usable: float = size.x - Palette.SPACE_XL * 2.0
	var side_by_side: bool = usable >= ACTION_MIN_WIDTH * 2.0 + gap

	_actions.vertical = not side_by_side

	# CRITICAL: clear the minimum BEFORE measuring, and never set one wider
	# than the row can hold.
	#
	# A VBoxContainer's own minimum size is the widest of its children, and
	# the Root VBox is anchored full-rect — so a custom_minimum_size wider
	# than the screen inflates the container past its anchors instead of
	# being clipped. Measured at 360x640, two 296px buttons made Root 616px
	# wide at x=-128, pushing "Retry Trial" off the left edge and
	# "Return to Hub" off the right. The container was obeying its children;
	# the children were the ones lying about how much room existed.
	var each: float = (usable - gap) * 0.5 if side_by_side else usable
	each = clampf(each, Palette.MIN_TOUCH_TARGET, minf(ACTION_MAX_WIDTH, usable))

	for button: Button in [_retry_button, _hub_button]:
		button.custom_minimum_size = Vector2(each, ACTION_HEIGHT)
		button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER


func _exit_tree() -> void:
	super()


func _operational(context: String) -> bool:
	if _wired:
		return true
	Log.d("Results", "not operational in %s" % context)
	return false


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))
	_title.text = "Forfeited" if bool(_summary.get("forfeited", false)) else "Complete"

	for label: Label in [_accuracy_label, _time_label, _rank_label]:
		label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
		label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))

	_lumina_label.add_theme_color_override("font_color", Palette.accent())
	_lumina_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_DISPLAY))
	_breakdown_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_breakdown_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))

	_xp_bar.add_theme_stylebox_override("background",
		Palette.bar_style(Palette.COLOR_HAIRLINE))
	_xp_bar.add_theme_stylebox_override("fill", Palette.bar_style(Palette.accent()))


func _on_palette_changed(_tier: int) -> void:
	_style()


# ═════════════════════════════════════════════════════════════════════════
# ANIMATED REVEAL
# ═════════════════════════════════════════════════════════════════════════
## Values land in sequence rather than all at once, so each reward reads as a
## separate beat. Reduced motion collapses this to an instant fill.
func _animate_reveal() -> void:
	if not _operational("_animate_reveal"):
		return

	var accuracy: float = float(_summary.get("accuracy", 0.0))
	var elapsed: float = float(_summary.get("elapsed_seconds", 0.0))
	var lumina: int = int(_summary.get("lumina", 0))

	_accuracy_label.text = "Accuracy  0%"
	_time_label.text = "Time  %.1fs" % elapsed
	_lumina_label.text = "+0 ✦"
	_breakdown_label.text = _breakdown_text()
	_rank_label.text = _rank_text()

	if Palette.reduced_motion():
		_accuracy_label.text = "Accuracy  %d%%" % int(round(accuracy * 100.0))
		_lumina_label.text = "+%d ✦" % lumina
		_xp_bar.value = _target_xp_fraction()
		_maybe_celebrate()
		return

	var tween: Tween = create_tween()
	tween.tween_interval(STEP_DELAY)
	tween.tween_method(_set_accuracy_display, 0.0, accuracy, COUNT_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_interval(STEP_DELAY)
	tween.tween_method(_set_lumina_display, 0, lumina, COUNT_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_interval(STEP_DELAY)
	tween.tween_property(_xp_bar, "value", _target_xp_fraction(), COUNT_DURATION) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_callback(_maybe_celebrate)


func _set_accuracy_display(value: float) -> void:
	if _accuracy_label != null:
		_accuracy_label.text = "Accuracy  %d%%" % int(round(value * 100.0))


func _set_lumina_display(value: int) -> void:
	_displayed_lumina = value
	if _lumina_label != null:
		_lumina_label.text = "+%d ✦" % value


## Where the XP bar should end. If the player ranked up, the bar fills fully —
## the rank-up itself is the reward moment, and a partial bar undersells it.
func _target_xp_fraction() -> float:
	if int(_summary.get("ranks_gained", 0)) > 0:
		return 1.0
	if _state == null:
		return 0.0
	return clampf(_state.rank_progress(), 0.0, 1.0)


func _breakdown_text() -> String:
	var streak_mult: float = float(_summary.get("streak_multiplier", 1.0))
	var rank_mult: float = float(_summary.get("rank_multiplier", 1.0))
	var bracket: int = int(_summary.get("bracket", 0))
	var difficulty: float = 1.0
	if bracket >= 0 and bracket < ProgressionEngine.BRACKET_MULTIPLIER.size():
		difficulty = ProgressionEngine.BRACKET_MULTIPLIER[bracket]

	var parts: PackedStringArray = []
	parts.append("difficulty ×%.2f" % difficulty)
	if streak_mult > 1.0:
		parts.append("streak ×%.2f" % streak_mult)
	if rank_mult > 1.0:
		parts.append("rank ×%.2f" % rank_mult)
	var resonance: int = int(_summary.get("resonance", 0))
	if resonance > 0:
		parts.append("+%d ◈" % resonance)
	return "  ·  ".join(parts)


func _rank_text() -> String:
	var gained: int = int(_summary.get("ranks_gained", 0))
	var after: int = int(_summary.get("rank_after", 0))
	if gained > 0:
		return "RANK UP  →  %d" % after
	return "Rank %d  ·  +%d XP" % [after, int(_summary.get("xp", 0))]


# ═════════════════════════════════════════════════════════════════════════
# CELEBRATION MODAL
# ═════════════════════════════════════════════════════════════════════════
## Fires for a rank-up seed unlock or a streak reward. Display only — the seed
## was already granted during settlement, so dismissing this cannot lose it.
func _maybe_celebrate() -> void:
	if not _operational("_maybe_celebrate"):
		return
	var seeds: Array = _summary.get("unlocked_seeds", [])
	var milestone: bool = bool(_summary.get("is_milestone", false))
	if seeds.is_empty() and not milestone:
		return

	var text: String = "Milestone reward unlocked"
	if not seeds.is_empty():
		text = "New cosmetic unlocked\nVisit the Wardrobe to equip it"

	_celebration_label.text = text
	_celebration_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_celebration_label.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_HEADING))
	_celebration.visible = true
	Bus.iris_express.emit("evolve", 1.0)


func _hide_celebration() -> void:
	if _celebration != null:
		_celebration.visible = false


# ═════════════════════════════════════════════════════════════════════════
# NAVIGATION
# ═════════════════════════════════════════════════════════════════════════
## Replay the same trial at the same bracket.
func _on_retry() -> void:
	await Router.replace("trial", {
		"trial_id": str(_summary.get("trial_id", "false_witness")),
		"bracket": int(_summary.get("bracket", 0)),
		"iris_state": _state,
	})


func _on_hub() -> void:
	await Router.go("hub", {"iris_state": _state})


## Back closes the celebration first, then returns to the hub. Never falls
## through to a quit — results is reached from a root route.
func on_back_requested() -> bool:
	if _celebration != null and _celebration.visible:
		_hide_celebration()
		return true
	_on_hub()
	return true
