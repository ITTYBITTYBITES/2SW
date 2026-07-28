extends Screen
class_name TrialController

## TrialController — runs a trial stage and dispatches its rewards.
##
## PHASE 6. Owns stage lifecycle and performance metrics; delegates every
## calculation to ProgressionEngine and every scene change to Router.
##
## v1's TrialContainer had three structural faults this fixes:
##   1. Back was unhandled in every trial scene, so the Android back button
##      QUIT THE APP mid-run. Here `on_back_requested()` intercepts and offers
##      a forfeit confirmation.
##   2. A missing trial scene silently awarded a neutral 0.5 accuracy, so a
##      typo looked like working software. Here it fails loudly.
##   3. Timing ran on tweens after `await process_frame`, racing the layout.
##      Here elapsed time is measured from a monotonic clock and the run is
##      driven by explicit state, not animation callbacks.
##
## REWARD ATOMICITY: settlement happens exactly once, guarded by `_settled`.
## A double-tap on "finish", a forfeit racing a completion, or a pause landing
## mid-settlement cannot pay out twice.

enum Phase { IDLE = 0, RUNNING = 1, SETTLING = 2, COMPLETE = 3 }

## Accuracy credited when a player forfeits a run in progress. Partial credit
## rather than zero: they still played, and a punitive zero teaches players to
## force-quit instead of using the back button.
const FORFEIT_ACCURACY_FACTOR: float = 0.5

## Mini-game scripts, brackets, and round counts all come from TrialRegistry.
## There is deliberately no local table here — a second list is exactly how v1
## lost facet_cascade.

@onready var _background: ColorRect = %Background
@onready var _title: Label = %TitleLabel
@onready var _score_label: Label = %ScoreLabel
@onready var _timer_label: Label = %TimerLabel
@onready var _score_bezel: HudBezel = %ScoreBezel
@onready var _timer_bezel: HudBezel = %TimerBezel
@onready var _feedback: TrialFeedback = %Feedback
@onready var _finish_button: Button = %FinishButton
@onready var _confirm_forfeit: ConfirmationDialog = %ConfirmForfeit
## Below this the glyph ring cannot be laid out without a target falling
## outside the field, so the header compresses to protect it.
const MIN_FIELD_HEIGHT: float = 320.0

@onready var _stage: Control = %Stage

var _state: IrisState = null
var _phase: Phase = Phase.IDLE
var _wired: bool = false
var _settled: bool = false

# ── Performance metrics ──────────────────────────────────────────────────
var _trial_id: String = ""
var _bracket: int = 0
var _correct: int = 0
var _attempted: int = 0
var _started_msec: int = 0
var _elapsed_sec: float = 0.0
var _minigame: Control = null
## The one-time briefing while it is up, or null.
var _tutorial: TutorialOverlay = null

# ── Daily anomaly ────────────────────────────────────────────────────────
## Deterministic parameters for today's ChronoPulse run, or {} for an ordinary
## practice trial. Supplied by the Daily Hub; never generated here, so there is
## one generator and the host cannot disagree with the card about what was
## played.
var _anomaly: Dictionary = {}
## Seed handed to the mini-game RNG. Non-zero only for an anomaly run.
var _trial_seed: int = 0

## Trend Hub category for a Trend Witness run, or "" for every other mode.
## Pulled by the mini-game during configure(), the same contract the anomaly
## params use.
var _trend_id: String = ""


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	_state = _resolve_state()
	_trial_id = str(payload.get("trial_id", "false_witness"))
	if not TrialRegistry.has(_trial_id):
		Log.must(false, "Trial", "unregistered trial '%s'" % _trial_id)
		_trial_id = "false_witness"

	# Daily anomaly parameters, if this run is one. Read BEFORE the mini-game
	# mounts, because the mini-game asks for them during configure().
	var incoming_anomaly: Variant = payload.get("chrono_anomaly", null)
	if incoming_anomaly is Dictionary:
		_anomaly = incoming_anomaly as Dictionary
		# The seed is derived from the anomaly's OWN date string, so every
		# player on Earth drives their RNG from the same value. Deriving it
		# from anything device-local would make the "identical daily" claim
		# false while still looking deterministic in a single-device test.
		_trial_seed = ChronoPulse.hash_seed(str(_anomaly.get("seed_id", "")))

	_trend_id = str(payload.get("trend_id", ""))

	# The bracket comes from ADAPTIVE HISTORY, not the caller, unless a caller
	# explicitly overrides (daily challenge, retry-at-same-difficulty).
	if payload.has("bracket"):
		_bracket = clampi(int(payload["bracket"]), 0, 2)
	else:
		_bracket = AdaptiveDifficulty.current_bracket(_state, _trial_id)

	_wired = (
		Log.must(_title != null, "Trial", "%TitleLabel missing")
		and Log.must(_score_label != null, "Trial", "%ScoreLabel missing")
		and Log.must(_score_bezel != null, "Trial", "%ScoreBezel missing")
		and Log.must(_timer_bezel != null, "Trial", "%TimerBezel missing")
		and Log.must(_feedback != null, "Trial", "%Feedback missing")
		and Log.must(_finish_button != null, "Trial", "%FinishButton missing")
		and Log.must(_confirm_forfeit != null, "Trial", "%ConfirmForfeit missing")
		and Log.must(_stage != null, "Trial", "%Stage missing")
		and Log.must(_state != null, "Trial", "state failed to resolve")
	)
	if not _wired:
		return

	_finish_button.pressed.connect(_on_finish_pressed)
	# Restyle only; the confirmed wiring below is unchanged.
	ArcaneTheme.apply(_confirm_forfeit)
	_confirm_forfeit.confirmed.connect(_on_forfeit_confirmed)
	_confirm_forfeit.dialog_text = "Forfeit this run?\nYou will keep partial rewards."

	_adopt_bezels()
	_style()
	_mount_minigame()

	# FIRST RUN OF THIS MODE: brief the player before the clock starts.
	#
	# begin_trial() is what starts the monotonic timer and the mini-game, so
	# holding it is what makes the briefing free. Showing the overlay on top of
	# a running trial would spend the player's first 2.5-second window teaching
	# them the rules, which teaches them instead that the game is unfair.
	# A caller may suppress the briefing outright. Two real cases:
	#
	#   * the daily ChronoPulse run, which is a timed one-shot against the
	#     world — interrupting it with a lesson would spend the player's only
	#     attempt of the day on a modal
	#   * automated flows, which drive rounds programmatically and would
	#     otherwise block forever on a button nobody presses
	#
	# Default is false, so forgetting the flag TEACHES rather than skips.
	var suppress: bool = bool(payload.get("skip_tutorial", false)) or is_anomaly_run()
	if not suppress and not TutorialScript.is_seen(_trial_id):
		# Paint the readouts BEFORE the briefing goes up. _refresh_metrics()
		# normally first runs inside begin_trial(), which the tutorial defers —
		# so the HUD sat on its scene placeholder ("0 / 0  (0%)") behind the
		# overlay, which is exactly the stale counter that was reported.
		_refresh_metrics()
		_present_tutorial()
		return
	begin_trial()


## Put the one-time briefing up and wait for it.
func _present_tutorial() -> void:
	var overlay := TutorialOverlay.new()
	overlay.name = "TutorialOverlay"
	add_child(overlay)
	overlay.present(_trial_id)
	overlay.dismissed.connect(_on_tutorial_dismissed)
	_tutorial = overlay


func _on_tutorial_dismissed() -> void:
	TutorialScript.mark_seen(_trial_id)
	_tutorial = null
	begin_trial()


## The live briefing, or null once dismissed. Exposed so a test can press the
## real button instead of calling the handler.
func tutorial_overlay() -> TutorialOverlay:
	return _tutorial


## Hand each readout label to the carved plate that frames it.
##
## The scene already parents them correctly, so this is normally a no-op that
## only applies the plate's inset and alignment. It is still called, because a
## test that mounts the controller with a hand-built tree — which several do —
## has the labels loose, and the bezel has to be able to adopt them either way.
func _adopt_bezels() -> void:
	if not _operational("_adopt_bezels"):
		return
	if _score_bezel.hosted_label() != _score_label:
		_score_bezel.host_label(_score_label)
	if _timer_bezel.hosted_label() != _timer_label:
		_timer_bezel.host_label(_timer_label)


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
	Log.d("Trial", "not operational in %s" % context)
	return false


# ═════════════════════════════════════════════════════════════════════════
# ANOMALY CONTRACT — read by the mini-game during configure()
# ═════════════════════════════════════════════════════════════════════════
## Today's deterministic parameters, or {} for a practice run.
##
## Pulled by the mini-game rather than pushed, so a mode that has no use for
## anomaly tuning simply never asks and needs no changes.
func anomaly_params() -> Dictionary:
	return _anomaly


## RNG seed for the mini-game. Zero means "no seed supplied, use the clock".
## Progression values a mini-game may READ for appearance.
##
## Deliberately a plain Dictionary of primitives rather than the IrisState
## itself: a mini-game that held the state could mutate progression, and the
## boundary that keeps trials from writing to the save file is worth more
## than the convenience.
func progression_visuals() -> Dictionary:
	if _state == null:
		return {}
	return {
		"rank_tier": _state.rank_tier,
		"complexity": _state.current_complexity_factor(),
		"shimmer": _state.lens_shimmer,
	}


func trial_seed() -> int:
	return _trial_seed


## Is this run today's ChronoPulse anomaly?
func is_anomaly_run() -> bool:
	return not _anomaly.is_empty()


## The Trend Hub category for this run, or "" if it is not a Trend run.
func trend_id() -> String:
	return _trend_id


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND
	_title.text = "Trial"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))
	# Full-strength text on the readouts. They sit on COLOR_BEZEL_PLATE now,
	# which is DARKER than the background they used to sit on, so the dimmed
	# tone they previously used would have lost contrast rather than kept it.
	for label: Label in [_score_label, _timer_label]:
		label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
		label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))
	_score_bezel.queue_redraw()
	_timer_bezel.queue_redraw()


func _on_palette_changed(_tier: int) -> void:
	_style()


## Instantiate the mini-game for this trial id and hand it a reference to us.
## Fails LOUDLY on an unknown id — v1 silently awarded a neutral 0.5 accuracy,
## so a typo looked like working software.
func _mount_minigame() -> void:
	if not _operational("_mount_minigame"):
		return
	var script_path: String = TrialRegistry.script_path(_trial_id)
	if not Log.must(script_path != "", "Trial", "no mini-game for id '%s'" % _trial_id):
		return
	if not Log.must(ResourceLoader.exists(script_path), "Trial",
			"mini-game script missing: %s" % script_path):
		return

	var minigame_script: GDScript = load(script_path)
	var minigame: Control = minigame_script.new()
	minigame.name = "MiniGame"
	minigame.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The stage never swallows input meant for chrome; each mini-game opts its
	# own hit targets back in.
	minigame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(minigame)
	_minigame = minigame
	if minigame.has_method("configure"):
		minigame.configure(self, _bracket)


# ═════════════════════════════════════════════════════════════════════════
# STAGE EXECUTION
# ═════════════════════════════════════════════════════════════════════════
func begin_trial() -> void:
	if not _operational("begin_trial"):
		return
	if _phase != Phase.IDLE:
		Log.warn("Trial", "begin_trial called in phase %d" % int(_phase))
		return

	_phase = Phase.RUNNING
	_correct = 0
	_attempted = 0
	# Monotonic clock, not a tween or the wall clock. Immune to the player
	# changing their device time mid-run.
	_started_msec = Time.get_ticks_msec()
	_elapsed_sec = 0.0

	Bus.trial_started.emit(_trial_id, _bracket)
	set_process(true)
	_refresh_metrics()

	if _minigame != null and _minigame.has_method("begin"):
		_minigame.begin()


## Give the play field the space the chrome is not using.
##
## THE BUG THIS FIXES: %Stage was anchored full-rect, so the play field WAS
## the whole screen. field_centre() therefore returned the centre of the
## window rather than the centre of the free area, and every mini-game laid
## its geometry out around that point — which put the score and timer labels
## inside the glyph ring, and pushed half the glyphs past the bottom of a
## window shorter than the design height. Reported as a trial showing three
## glyphs instead of six with the timer arc running off the right.
##
## The band is READ from the live chrome, not from .tscn offsets, for the
## same reason the hub's is: safe-area insets move these controls at runtime,
## so any constant derived from the scene is wrong by the inset.
func _layout() -> void:
	if not _operational("_layout"):
		return
	# Measure from the BEZEL, not the label. The label now lives inside the
	# plate, so its position is relative to the plate and reads as ~0 — using
	# it would place the play field's top edge under the header again, which
	# is the exact bug 2c9d52b fixed.
	var top: float = _timer_bezel.position.y + _timer_bezel.size.y + Palette.SPACE_LG
	var bottom: float = _finish_button.position.y - Palette.SPACE_LG

	# On a short screen the fixed header eats the play area: at 800x600 the
	# 284px of title + readout left a 152px band, too small to hold the glyph
	# ring. The chrome MOVES UP rather than the field growing under it — an
	# earlier version raised only the field's top edge, which slid the band
	# back over the score and timer and put the readout inside the play area
	# again. The labels have to travel with it.
	var band: float = bottom - top
	if band < MIN_FIELD_HEIGHT:
		var deficit: float = MIN_FIELD_HEIGHT - band
		var headroom: float = _title.position.y - Palette.SPACE_SM
		var shift: float = minf(deficit, maxf(headroom, 0.0))
		if shift > 0.0:
			_title.position.y -= shift
			_score_bezel.position.y -= shift
			_timer_bezel.position.y -= shift
			top -= shift
			band = bottom - top

	# THE PLAY FIELD IS SQUARE AND CENTRED IN THE FREE BAND.
	#
	# It used to be the whole leftover rectangle: on a phone that is 1080x1732,
	# far taller than it is wide. Every mini-game lays its ring out on
	# field_unit(), which is the SHORT side, but centres it on the middle of
	# that tall box — so the glyph ring was sized for the width, floated in the
	# upper half, and left a large dead band beneath it. Visible in a device
	# screenshot as glyphs crowded toward the top with empty space below.
	#
	# A square is the only shape where a ring at any radius sits equidistant
	# from every edge, so the field is squared and centred. Nothing about the
	# mini-games changes; they keep asking for field_unit() and now get a rect
	# where that answer is correct.
	var field_side: float = minf(size.x, maxf(band, 0.0))
	var free_band: float = maxf(band, 0.0)
	_stage.position = Vector2(
		(size.x - field_side) * 0.5,
		top + (free_band - field_side) * 0.5)
	_stage.size = Vector2(field_side, field_side)
	# The feedback overlay tracks the play field exactly, so a pulse centred
	# on a target lands on the target rather than offset by the header.
	_feedback.position = _stage.position
	_feedback.size = _stage.size


func _process(_delta: float) -> void:
	if _phase != Phase.RUNNING:
		return
	_elapsed_sec = float(Time.get_ticks_msec() - _started_msec) / 1000.0
	_refresh_metrics()


## Record one answer. Public so a concrete trial scene can drive scoring
## without reaching into private members — v1's container poked `_trial._ended`.
func record_answer(is_correct: bool) -> void:
	if _phase != Phase.RUNNING:
		Log.d("Trial", "answer recorded outside RUNNING phase")
		return
	_attempted += 1
	if is_correct:
		_correct += 1
	Bus.iris_express.emit("reward" if is_correct else "miss", 0.6)
	_play_feedback(is_correct)
	_refresh_metrics()


## Fire the arcane response for one answer: a cyan energy pulse for a hit, a
## chromatic abrasion for a miss.
##
## Triggered HERE, in record_answer(), because that is the single choke point
## every answer from every mini-game already passes through. Wiring it into
## each of the five modes separately would guarantee that the sixth forgets.
##
## The pulse is centred on the target the player actually pressed. The
## mini-game records that in make_target(); modes answered by gesture or
## timeout have no such point and fall back to the field centre.
## A positive guard rather than an early return: a controller mounted without
## the overlay still has to score normally, so its absence is an ordinary
## state, not an error worth logging on every single answer (Rule C).
func _play_feedback(is_correct: bool) -> void:
	if _feedback != null:
		var at: Vector2 = _feedback.size * 0.5
		if _minigame != null and _minigame.has_method("answer_point"):
			# The mini-game's field and the feedback overlay share %Stage's
			# rect, so a field-local point needs no transform. Converting
			# through global space would break if either were reparented.
			at = _minigame.call("answer_point")
		_feedback.play(is_correct, at)


## Accuracy in 0..1. Zero attempts is zero accuracy, not a division by zero.
func accuracy() -> float:
	if _attempted <= 0:
		return 0.0
	return clampf(float(_correct) / float(_attempted), 0.0, 1.0)


func elapsed_seconds() -> float:
	return _elapsed_sec


func _refresh_metrics() -> void:
	if not _operational("_refresh_metrics"):
		return
	# SHOW THE ROUND, NOT THE ANSWER COUNT.
	#
	# This used to read "%d / %d (%d%%)" of correct-over-ATTEMPTED, which on
	# the first round of every run displays "0 / 0 (0%)" — a counter that
	# tells the player nothing, and reads like a bug rather than a fresh start.
	# It also never revealed how long the run was.
	#
	# Round-of-total is the number a player actually wants mid-run, and the
	# score is appended only once there is a score to show.
	var total: int = 0
	var done: int = 0
	if _minigame != null and _minigame.has_method("rounds_total"):
		total = int(_minigame.call("rounds_total"))
		done = int(_minigame.call("rounds_done"))
	if total > 0:
		var shown: int = mini(done + 1, total)
		if _attempted > 0:
			_score_label.text = "Round %d / %d   ·   %d correct" % [
				shown, total, _correct]
		else:
			_score_label.text = "Round %d / %d" % [shown, total]
	else:
		# No round count to report: fall back to the raw tally rather than
		# inventing a total.
		_score_label.text = "%d correct" % _correct
	_timer_label.text = "%.1fs" % _elapsed_sec
	_refresh_bezels()


## Drive the two cyan arcs from MEASURED quantities.
##
## Both are real readouts, not animation:
##
##   score plate   accuracy, 0..1. The arc IS the percentage the label prints.
##   timer plate   fraction of the run's rounds completed. The timer's own
##                 number is unbounded, so it has no arc of its own — but
##                 "how far through this run am I" is the question a player
##                 glancing at the clock is actually asking, and it does have
##                 a bound.
##
## An arc that swept on a fixed schedule regardless of play would be a spinner
## impersonating a gauge, which is worse than no arc at all.
func _refresh_bezels() -> void:
	_score_bezel.set_fill(accuracy())

	var total: int = 0
	var done: int = 0
	if _minigame != null and _minigame.has_method("rounds_total"):
		total = int(_minigame.call("rounds_total"))
		done = int(_minigame.call("rounds_done"))
	if total > 0:
		_timer_bezel.set_fill(float(done) / float(total))
	else:
		# No round count to measure against — a mode that ends on its own
		# terms. Leave the arc at its origin rather than inventing progress.
		_timer_bezel.set_fill(0.0)


# ═════════════════════════════════════════════════════════════════════════
# COMPLETION & SETTLEMENT
# ═════════════════════════════════════════════════════════════════════════
func _on_finish_pressed() -> void:
	complete_trial()


## Finish normally and settle rewards.
func complete_trial() -> void:
	_settle(accuracy(), false)


## Public name used by mini-game modules when their round set ends.
func conclude_trial() -> void:
	complete_trial()


## Abandon mid-run. Partial credit; still settles exactly once.
func forfeit_trial() -> void:
	_settle(accuracy() * FORFEIT_ACCURACY_FACTOR, true)


## The single settlement path. Guarded so rewards can never be paid twice.
func _settle(final_accuracy: float, forfeited: bool) -> void:
	if not _operational("_settle"):
		return
	if _settled:
		Log.warn("Trial", "settle called twice — ignored")
		return
	if _phase == Phase.SETTLING or _phase == Phase.COMPLETE:
		return

	_settled = true
	_phase = Phase.SETTLING
	set_process(false)

	# Log the attempt and evaluate a bracket shift BEFORE settling, so the
	# summary can report the new difficulty.
	var adaptation: Dictionary = AdaptiveDifficulty.record_attempt(
		_state, _trial_id, final_accuracy)
	AdaptiveDifficulty.record_duration(_state, _trial_id, _elapsed_sec)

	var summary: Dictionary = ProgressionEngine.settle_trial(
		_state, final_accuracy, _bracket, _trial_id)

	summary["bracket_before"] = int(adaptation.get("bracket_before", _bracket))
	summary["bracket_after"] = int(adaptation.get("bracket_after", _bracket))
	summary["difficulty_shift"] = int(adaptation.get("shift", 0))

	# Metrics the engine does not own.
	# Lifetime counters, recorded once per settled run.
	_state.trials_completed += 1
	_state.total_trial_seconds += _elapsed_sec

	summary["elapsed_seconds"] = _elapsed_sec
	summary["correct"] = _correct
	summary["attempted"] = _attempted
	summary["forfeited"] = forfeited
	summary["completed"] = not forfeited

	# THE NAV GATE opens on a completed run, never on a forfeit.
	#
	# v1 set this unconditionally in TrialContainer, which meant backing out
	# of a first trial still unlocked the hub — the player skipped the one
	# thing the gate exists to make them do. A forfeit leaves them gated and
	# the hub keeps saying "tap to begin", which is the honest state.
	#
	# Save.mark_returned_from_trial() is idempotent and flushes itself, so
	# this costs one dictionary read on every subsequent trial.
	if not forfeited:
		Save.mark_returned_from_trial()

	_commit()

	# Record the Trend Hub score, if this was a Trend run. Before the anomaly
	# settle so a category best is banked even if the chrono path bails.
	_settle_trend()

	# Settle the daily anomaly, if this was one. AFTER _commit() so the trial's
	# own progression is already durable — a failure inside the ChronoPulse
	# path must not be able to lose the XP and Lumina the player just earned.
	var chrono: Dictionary = _settle_anomaly(final_accuracy, forfeited)

	if forfeited:
		Bus.trial_forfeited.emit(_trial_id)
	Bus.trial_finished.emit(_trial_id, summary)
	Bus.trial_completed.emit(summary)

	_announce(summary)

	_phase = Phase.COMPLETE

	# A completed anomaly goes to its own card; everything else to the normal
	# results screen. A FORFEITED anomaly deliberately uses the normal screen:
	# there is no shareable time to show, and routing to a card reading
	# "Missed" would present quitting as a result worth posting.
	if bool(chrono.get("recorded", false)):
		await Router.go("chrono_card", {
			"record": chrono.get("record", {}),
			"streak": int(chrono.get("streak", 0)),
			"summary": summary,
		})
		return
	await Router.go("results", {"summary": summary, "iris_state": _state})


# ═════════════════════════════════════════════════════════════════════════
# TREND SETTLEMENT
# ═════════════════════════════════════════════════════════════════════════
## Bank the category score for a Trend Witness run. No-op for every other mode.
##
## The score comes from the MINI-GAME, which owns the speed bonus, rather than
## being recomputed from accuracy here — two formulas for one number is how
## the displayed score and the stored best end up disagreeing.
func _settle_trend() -> void:
	if _trend_id == "":
		return
	if not Log.must(_minigame != null, "Trial", "trend run with no mini-game"):
		return
	if not _minigame.has_method("score"):
		Log.warn("Trial", "trend run mini-game exposes no score()")
		return

	var earned: int = maxi(int(_minigame.call("score")), 0)
	var is_best: bool = TrendRegistry.submit_score(_trend_id, earned)
	if is_best:
		Bus.toast.emit("New best · %d" % earned, "✦")
	Log.info("Trial", "trend '%s' scored %d (best=%s)" % [
		_trend_id, earned, str(is_best)])


# ═════════════════════════════════════════════════════════════════════════
# ANOMALY SETTLEMENT
# ═════════════════════════════════════════════════════════════════════════
## Hand the measured reaction to ChronoPulse. Returns {} for a practice run.
##
## The LATENCY IS MEASURED, NOT DERIVED. It comes from the mini-game's own
## per-stimulus timestamps, so it reflects the player's actual reaction rather
## than total elapsed time divided by rounds — which would silently include
## every inter-round pause and make a fast player look slow.
##
## `hit` means the player answered at least one stimulus within its window. A
## run where every window expired has no reaction to report, so it records as
## a miss with zero latency rather than inventing one.
func _settle_anomaly(final_accuracy: float, forfeited: bool) -> Dictionary:
	if _anomaly.is_empty():
		return {}

	# A forfeit is not an attempt at today's puzzle. Recording it would burn
	# the one daily shot on a run the player abandoned.
	if forfeited:
		Log.info("Trial", "anomaly forfeited; not recorded")
		return {}

	if not Log.must(_minigame != null, "Trial", "anomaly run with no mini-game"):
		return {}

	var responded: bool = false
	var latency: int = 0
	if _minigame.has_method("had_any_response"):
		responded = bool(_minigame.call("had_any_response"))
	if responded and _minigame.has_method("mean_latency_ms"):
		latency = maxi(int(_minigame.call("mean_latency_ms")), 0)

	# A response with an unmeasurable latency is not a hit. Passing hit=true
	# with latency 0 would be rejected by validate_result() anyway; catching
	# it here keeps the reason legible instead of surfacing as a bounds fault.
	if responded and latency <= 0:
		Log.warn("Trial", "responses recorded but no measurable latency")
		responded = false

	var outcome: Dictionary = ChronoPulseController.record_completion(
		_state, latency, responded, final_accuracy)

	if bool(outcome.get("rejected", false)):
		Log.warn("Trial", "anomaly result rejected: %s"
			% str(outcome.get("faults", [])))
	return outcome


## Persist once, after settlement. One write path, so a partial save is
## impossible.
func _commit() -> void:
	if not _operational("_commit"):
		return
	Save.set_v("iris", "state", _state.to_dict())
	Save.flush()


## Surface the emotional beats. The eye reacts; it is not told why.
func _announce(summary: Dictionary) -> void:
	var lumina: int = int(summary.get("lumina", 0))
	if lumina > 0:
		Bus.lumina_awarded.emit(lumina, _state.lumina)
	var resonance: int = int(summary.get("resonance", 0))
	if resonance > 0:
		Bus.resonance_awarded.emit(resonance, int(_state.lens_shimmer))
	HapticsManager.pattern(&"trial_complete")
	var gained: int = int(summary.get("ranks_gained", 0))
	if gained > 0:
		HapticsManager.pattern(&"rank_up")
		Bus.level_changed.emit(
			int(summary.get("rank_before", 0)), int(summary.get("rank_after", 0)))
		Bus.iris_express.emit("evolve", 1.0)
		Bus.toast.emit("Rank %d — %s" % [
			_state.rank_tier, _state.current_rank_title()], "✦")
	var seeds: Array = summary.get("unlocked_seeds", [])
	if not seeds.is_empty():
		Bus.toast.emit("New cosmetic unlocked", "✧")


# ═════════════════════════════════════════════════════════════════════════
# BACK / INTERRUPTION
# ═════════════════════════════════════════════════════════════════════════
## v1 QUIT THE APP here. Now back mid-run offers a forfeit confirmation, and
## back after settlement simply lets Router pop.
func on_back_requested() -> bool:
	if _phase == Phase.RUNNING:
		_confirm_forfeit.popup_centered()
		return true
	return false


func _on_forfeit_confirmed() -> void:
	forfeit_trial()
