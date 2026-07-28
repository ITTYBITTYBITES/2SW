extends Screen
class_name DailyHubController
## DailyHubController — the daily streak hub.
##
## PHASE 8. Shows streak state, the milestone track, and the daily trial CTA.
##
## MUTATION BOUNDARY: this screen may claim the daily reward, because that is
## its entire purpose. It does NOT touch cosmetics, XP, or trial history — the
## claim routes through ProgressionEngine.evaluate_daily_streak(), which is the
## same path any other caller would use, and persists via one _commit().
##
## The claim is idempotent by construction: evaluate_daily_streak() compares
## against the stored day index and returns `claimed: false` if today is
## already collected, so a double-tap or a re-entry cannot pay twice.

## Milestone days shown on the track. Mirrors ProgressionEngine so the UI can
## never advertise a reward the engine won't pay.
const TRACK_DAYS: Array[int] = [3, 7, 14, 21, 30]

@onready var _background: ColorRect = %Background
@onready var _iris_view: IrisView = %IrisView
@onready var _title: Label = %TitleLabel
@onready var _streak_label: Label = %StreakLabel
@onready var _best_label: Label = %BestLabel
@onready var _grace_label: Label = %GraceLabel
@onready var _reward_label: Label = %RewardLabel
@onready var _track: Control = %MilestoneTrack
@onready var _claim_button: Button = %ClaimButton
@onready var _begin_button: Button = %BeginTrialButton
@onready var _back_button: Button = %BackButton
@onready var _subtitle: Label = %SubtitleLabel
@onready var _anomaly_panel: PanelContainer = %AnomalyPanel
@onready var _anomaly_title: Label = %AnomalyTitle
@onready var _anomaly_status: Label = %AnomalyStatus
@onready var _anomaly_button: Button = %AnomalyButton
@onready var _recover_button: Button = %RecoverButton

var _state: IrisState = null
var _wired: bool = false
var _last_day_index: int = -1
var _claimed_today: bool = false


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	_state = _resolve_state()
	_last_day_index = int(Save.get_v(Save.SEC_DAILY, "last_day_index", -1))

	_wired = (
		Log.must(_iris_view != null, "DailyHub", "%IrisView missing")
		and Log.must(_track != null, "DailyHub", "%MilestoneTrack missing")
		and Log.must(_claim_button != null, "DailyHub", "%ClaimButton missing")
		and Log.must(_begin_button != null, "DailyHub", "%BeginTrialButton missing")
		and Log.must(_state != null, "DailyHub", "state failed to resolve")
	)
	if not _wired:
		return

	_claimed_today = not ProgressionEngine.is_daily_available(_last_day_index)

	_iris_view.apply_state(_state)
	CosmeticMount.apply(_iris_view, _state)
	_iris_view.set_interactive(false)   # this hub is not a navigation surface

	_anomaly_button.pressed.connect(_on_anomaly_pressed)
	_recover_button.pressed.connect(_on_recover_pressed)
	_claim_button.pressed.connect(_on_claim_pressed)
	_begin_button.pressed.connect(_on_begin_pressed)
	_back_button.pressed.connect(_on_back_pressed)

	# The Iris reacts to being touched here, which is the whole point of a
	# companion screen. Tap goes through the view's own input receptor.
	Bus.iris_tapped.connect(_on_iris_touched)

	_style()
	_build_track()
	_refresh()
	_greet()


func _exit_tree() -> void:
	super()
	if Bus.iris_tapped.is_connected(_on_iris_touched):
		Bus.iris_tapped.disconnect(_on_iris_touched)


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
	Log.d("DailyHub", "not operational in %s" % context)
	return false


## Single write path, matching the Wardrobe's convention.
func _commit() -> void:
	if not _operational("_commit"):
		return
	Save.set_v("iris", "state", _state.to_dict())
	Save.set_v(Save.SEC_DAILY, "last_day_index", _last_day_index)
	Save.set_v(Save.SEC_DAILY, "streak", _state.streak_days)
	Save.set_v(Save.SEC_DAILY, "best_streak", _state.best_streak_days)
	Save.flush()


func _on_palette_changed(_tier: int) -> void:
	_style()
	_build_track()


# ═════════════════════════════════════════════════════════════════════════
# PRESENTATION
# ═════════════════════════════════════════════════════════════════════════
func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_title.text = "Daily"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))

	_streak_label.add_theme_color_override("font_color", Palette.accent())
	_streak_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_DISPLAY))

	_anomaly_panel.add_theme_stylebox_override("panel", Palette.panel_style(true))
	_anomaly_title.add_theme_color_override("font_color", Palette.accent())
	_anomaly_title.add_theme_font_size_override("font_size",
		Palette.font(Palette.FONT_HEADING))

	var dim_labels: Array[Label] = [
		_best_label, _grace_label, _reward_label, _subtitle, _anomaly_status]
	for label: Label in dim_labels:
		label.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
		label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))


func _refresh() -> void:
	if not _operational("_refresh"):
		return

	_streak_label.text = "%d" % _state.streak_days
	_subtitle.text = "day streak" if _state.streak_days != 1 else "day"
	_best_label.text = "Best  %d" % _state.best_streak_days

	_grace_label.text = _grace_text()
	_grace_label.add_theme_color_override("font_color", _grace_colour())

	_refresh_anomaly()

	if _claimed_today:
		var next_day: int = ProgressionEngine.next_milestone_day(_state.streak_days)
		_reward_label.text = "Claimed today  ·  next milestone day %d" % next_day
		_claim_button.disabled = true
		_claim_button.text = "Claimed"
	else:
		var projected: int = _state.streak_days + 1
		_reward_label.text = "Tomorrow's reward  %d ✦" % \
			ProgressionEngine.compute_daily_lumina(projected)
		_claim_button.disabled = false
		_claim_button.text = "Claim  %d ✦" % \
			ProgressionEngine.compute_daily_lumina(projected)

	_build_track()


## Grace-period and timezone status, in plain language.
##
## v1 used UTC day indices, so a player in UTC+13 finishing at 9pm local had
## already rolled into "tomorrow" and lost streaks they genuinely kept. The
## engine now uses the LOCAL day index; this surfaces that protection so the
## player can see it is working rather than having to trust it.
func _grace_text() -> String:
	if _state.streak_days <= 0:
		return "Start a streak today"
	if _claimed_today:
		return "Protected  ·  local time, 1 day grace"
	var available_since: int = ProgressionEngine.local_day_index(
		Time.get_unix_time_from_system()) - _last_day_index
	if _last_day_index < 0:
		return "Local time  ·  1 day grace"
	if available_since >= 2:
		return "Grace active  ·  claim today to keep your streak"
	return "Protected  ·  local time, 1 day grace"


func _grace_colour() -> Color:
	if _state.streak_days <= 0:
		return Palette.COLOR_TEXT_FAINT
	var gap: int = ProgressionEngine.local_day_index(
		Time.get_unix_time_from_system()) - _last_day_index
	if _last_day_index >= 0 and gap >= 2:
		return Palette.COLOR_WARNING   # at risk
	return Palette.success()


# ═════════════════════════════════════════════════════════════════════════
# MILESTONE TRACK
# ═════════════════════════════════════════════════════════════════════════
## Days 3 / 7 / 14 / 21 / 30 as a horizontal track. Reached milestones fill;
## the next one pulses; later ones stay hollow.
func _build_track() -> void:
	if not _operational("_build_track"):
		return
	for child: Node in _track.get_children():
		child.queue_free()

	var next_day: int = ProgressionEngine.next_milestone_day(_state.streak_days)

	for day: int in TRACK_DAYS:
		var reached: bool = _state.streak_days >= day
		var is_next: bool = day == next_day

		var column: VBoxContainer = VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_theme_constant_override("separation", int(Palette.SPACE_XXS))

		var marker: Label = Label.new()
		marker.text = "◆" if reached else ("◈" if is_next else "○")
		marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var marker_colour: Color = Palette.COLOR_TEXT_FAINT
		if reached:
			marker_colour = Palette.success()
		elif is_next:
			marker_colour = Palette.accent()
		marker.add_theme_color_override("font_color", marker_colour)
		marker.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_HEADING))
		column.add_child(marker)

		var caption: Label = Label.new()
		caption.text = "%d" % day
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		caption.add_theme_color_override("font_color", marker_colour)
		caption.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
		column.add_child(caption)

		var reward: Label = Label.new()
		reward.text = "%d ✦" % ProgressionEngine.compute_daily_lumina(day)
		reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reward.mouse_filter = Control.MOUSE_FILTER_IGNORE
		reward.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
		reward.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
		column.add_child(reward)

		_track.add_child(column)


# ═════════════════════════════════════════════════════════════════════════
# ACTIONS
# ═════════════════════════════════════════════════════════════════════════
func _on_claim_pressed() -> void:
	if not _operational("_on_claim_pressed") or _claimed_today:
		return

	var result: Dictionary = ProgressionEngine.evaluate_daily_streak(
		_state, _last_day_index)

	if not bool(result.get("claimed", false)):
		# Engine refused — already claimed, or the clock moved backwards.
		_claimed_today = true
		_refresh()
		return

	_last_day_index = ProgressionEngine.local_day_index(
		Time.get_unix_time_from_system())
	_claimed_today = true
	_commit()

	var lumina: int = int(result.get("lumina", 0))
	var milestone: bool = bool(result.get("is_milestone", false))

	AudioManager.play_sfx(&"reward")
	Bus.lumina_awarded.emit(lumina, _state.lumina)
	Bus.toast.emit("+%d ✦  ·  day %d" % [lumina, _state.streak_days], "✦")

	if milestone:
		HapticsManager.pattern(&"streak_celebrate")
		_iris_view.express(&"flare", 1.0)
		AudioManager.speak(DialogueManifest.STREAK_MILESTONE, &"streak_celebrate")
		if int(result.get("seed_granted", 0)) != 0:
			Bus.toast.emit("Milestone cosmetic unlocked", "✧")
	else:
		_iris_view.express(&"pulse", 0.7)

	_refresh()


# ═════════════════════════════════════════════════════════════════════════
# CHRONO-PULSE PORTAL
# ═════════════════════════════════════════════════════════════════════════
## The daily anomaly entry point.
##
## Three states, and the button says which one it is in rather than being
## disabled with no explanation:
##   unplayed  -> "Begin Anomaly"
##   played    -> "View Result" (the card is still reachable, one shot is not
##                a reason to hide what you scored)
##   lapsed    -> a recovery offer appears alongside
func _refresh_anomaly() -> void:
	if not _operational("_refresh_anomaly"):
		return

	var solved: bool = ChronoPulseController.is_solved_today()
	var record: Dictionary = ChronoPulseController.today_record()

	if solved:
		var tier: String = ChronoPulse.tier_label(
			StringName(str(record.get("tier", "missed"))))
		_anomaly_status.text = "Today's anomaly: %s" % tier
		_anomaly_button.text = "View Result"
	else:
		# Never name the anomaly kind here — the hub is visible before the run
		# and previewing which puzzle it is would be a spoiler for the player
		# themselves.
		_anomaly_status.text = "A new anomaly is live. One attempt."
		_anomaly_button.text = "Begin Anomaly"

	# Recovery only surfaces when it is genuinely available. An always-visible
	# "Recover Streak" button on an unbroken streak reads as an upsell.
	var offer: Dictionary = ChronoPulseController.current_offer(_state)
	var eligible: bool = bool(offer.get("eligible", false))
	_recover_button.visible = eligible
	if eligible:
		var cost: int = int(offer.get("lumina_cost", 0))
		if bool(offer.get("affordable", false)):
			_recover_button.disabled = false
			_recover_button.text = "Recover Streak  ·  %d ✦" % cost
		else:
			# Shown, priced and disabled rather than hidden: a player who
			# cannot afford it must still learn recovery exists.
			_recover_button.disabled = true
			_recover_button.text = "Recover Streak  ·  %d ✦ (need more)" % cost


func _on_anomaly_pressed() -> void:
	if not _operational("_on_anomaly_pressed"):
		return
	AudioManager.play_sfx(&"ui_tap")

	if ChronoPulseController.is_solved_today():
		await Router.go("chrono_card", {
			"record": ChronoPulseController.today_record(),
			"streak": _state.streak_days,
		})
		return

	# The anomaly is deterministic for everyone today, so the trial host is
	# handed the generated parameters rather than rolling its own.
	#
	# The MODE is fixed to cognitive_conflict rather than weighted-random: a
	# shared daily has to be the same task for everyone, and a random pick
	# would hand one player a match-3 and another a Stroop test while both
	# cards claimed the same seed. The anomaly's own `kind` varies the task
	# within that mode, which is where the daily variety comes from.
	await Router.go("trial", {
		"trial_id": ChronoPulse.TRIAL_ID,
		"iris_state": _state,
		"is_daily": true,
		"chrono_anomaly": ChronoPulseController.today_anomaly(),
	})


## Buy back a lapsed streak. Lumina if affordable; the rewarded ad is the free
## path so a player with no balance is never hard locked out.
func _on_recover_pressed() -> void:
	if not _operational("_on_recover_pressed"):
		return
	AudioManager.play_sfx(&"ui_tap")

	var offer: Dictionary = ChronoPulseController.current_offer(_state)
	if not bool(offer.get("eligible", false)):
		Log.info("DailyHub", "recover pressed but not eligible: %s"
			% str(offer.get("reason", "")))
		_refresh()
		return

	var method: String = "lumina" if bool(offer.get("affordable", false)) else "ad"
	var result: Dictionary = ChronoPulseController.recover_streak(_state, method)

	if not bool(result.get("recovered", false)):
		Bus.toast.emit("Recovery unavailable", "✧")
		_refresh()
		return

	_last_day_index = ProgressionEngine.local_day_index(
		Time.get_unix_time_from_system())
	_claimed_today = true

	HapticsManager.pattern(&"streak_celebrate")
	_iris_view.express(&"flare", 0.9)
	Bus.toast.emit("Streak restored  ·  day %d" % int(result.get("streak", 0)), "✦")
	_refresh()


## Launch the daily run. The bracket is deliberately NOT passed, so the trial
## host resolves it from adaptive history — the daily should sit at the same
## difficulty as normal play, not reset to easy.
func _on_begin_pressed() -> void:
	if not _operational("_on_begin_pressed"):
		return
	AudioManager.play_sfx(&"ui_tap")
	var trial_id: String = TrialRegistry.pick_weighted()
	await Router.go("trial", {"trial_id": trial_id, "iris_state": _state, "is_daily": true})


func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


## Touching the Iris makes it respond — the companion beat this screen exists
## to deliver.
func _on_iris_touched(_shard_id: int) -> void:
	if not _operational("_on_iris_touched"):
		return
	_iris_view.express(&"pulse", 0.5)
	HapticsManager.pulse(&"ui_tap")
	AudioManager.play_iris_formant(&"touch_respond", 6)


## Greet on arrival, choosing tone by absence and milestone state.
func _greet() -> void:
	if not _operational("_greet"):
		return
	var days_absent: int = 0
	if _last_day_index >= 0:
		days_absent = maxi(ProgressionEngine.local_day_index(
			Time.get_unix_time_from_system()) - _last_day_index, 0)
	var context: StringName = DialogueManifest.greeting_context(
		days_absent, ProgressionEngine.is_milestone_day(_state.streak_days))
	AudioManager.speak(context, &"hub_idle")


func on_back_requested() -> bool:
	return false
