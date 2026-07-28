extends TrialMiniGame
class_name TrendWitnessGame
## TrendWitness — witness a glyph string, then identify what you saw.
##
## PHASE 3. The five-phase loop, per round:
##
##   BRIEFING  0.8s   what to watch for
##   FLASH     0.4s   the target glyph, alone
##   WITNESS   fair   the crowd — target hidden among distractors
##   IDENTIFY  open   pick the glyph you witnessed
##   EVALUATE  0.35s  result, then the next round
##
## ═══════════════════════════════════════════════════════════════════════════
## THE "WPM FAIR WINDOW"
## ═══════════════════════════════════════════════════════════════════════════
## WPM appears nowhere else in this project, and this task shows glyphs rather
## than prose — so "words per minute" is applied as its underlying idea rather
## than its literal unit: the window must scale with how much there is to take
## in, so a denser screen is not automatically a harder one.
##
## A fixed window would silently punish the paid categories, which exist to be
## visually richer: Pop Culture shows 10 symbols where Internet Lore shows 6,
## and an identical timer would make the thing you unlocked strictly worse.
## That would be a paid downgrade.
##
## window = (glyphs / READ_RATE) * 1000 * tempo + REACTION_ALLOWANCE_MS
##
## READ_RATE is items-per-second, the direct analogue of a reading rate.
## REACTION_ALLOWANCE_MS is added AFTER scaling because human reaction latency
## is a fixed cost that does not shrink as the display gets simpler — folding
## it into the rate would make short rounds unfairly tight.
##
## The result is floored: below WINDOW_FLOOR_MS no display is readable at all,
## whatever the maths says.

# ── Phase timings ────────────────────────────────────────────────────────
const BRIEFING_SEC: float = 0.8
const FLASH_SEC: float = 0.4
const EVALUATE_SEC: float = 0.35

# ── Fair window ──────────────────────────────────────────────────────────
## Glyphs a player is assumed to take in per second while scanning.
const READ_RATE_PER_SEC: float = 4.5
## Fixed human reaction cost, added after scaling.
const REACTION_ALLOWANCE_MS: int = 320
## No display is readable below this, whatever the formula returns.
const WINDOW_FLOOR_MS: int = 650
## Nothing needs longer than this; past it the round is just slow.
const WINDOW_CEILING_MS: int = 6000

const ROUNDS_PER_RUN: int = 5

## Scoring. A correct identification pays the base, plus a speed bonus that
## decays across the fair window — answering at the buzzer still scores.
const SCORE_PER_HIT: int = 100
const SPEED_BONUS_MAX: int = 120

## A failure only offers a rescue once the player has something worth saving.
## Below this round the offer is nagging rather than helpful — and showing an
## ad prompt on round 1 trains players to expect one on every mistake.
const AD_CONTINUE_MIN_ROUND: int = 3

## Countdown shown when a run resumes, so play never restarts under the
## player's thumb while they are still putting the phone back.
const RESUME_COUNTDOWN_SEC: float = 3.0

## Ad placement id. Namespaced so the Trend Hub's unlock ads and this rescue
## can be told apart by any listener — including AdManager's own daily cap
## accounting and the hub's pending-unlock guard.
const AD_PLACEMENT: String = "trend_continue"

## PROMPT is a distinct phase, not a flag on EVALUATE: the run must be frozen
## while the choice is open, and a phase the timer does not advance is the
## clearest way to guarantee that.
enum Phase { BRIEFING = 0, FLASH = 1, WITNESS = 2, IDENTIFY = 3, EVALUATE = 4,
	PROMPT = 5, RESUMING = 6 }

var _trend_id: String = ""
var _symbols: int = 6
var _tempo: float = 1.0
var _palette_index: int = 0

var _phase: Phase = Phase.BRIEFING
var _phase_left: float = 0.0
var _window_ms: int = 1200

var _target: int = 0
var _crowd: Array[int] = []
var _feedback: int = 0
var _score: int = 0
var _hits: int = 0

# ── Save Your Streak ─────────────────────────────────────────────────────
## ONE rescue per run. Not per category, not per day — per run session, reset
## only by starting a new run. Without this a player could extend a single run
## indefinitely and every score on the board would be meaningless.
var has_used_ad_continue: bool = false
## True while the STREAK IN DANGER prompt is on screen and the run is frozen.
var _prompt_open: bool = false
## Score and hit count captured at the moment of failure, so a rescue restores
## exactly what was earned rather than recomputing it.
var _rescue_score: int = 0
var _rescue_hits: int = 0
var _countdown_left: float = 0.0
## Set when the run ends for real, so a late ad callback cannot resurrect it.
var _run_over: bool = false


# ═════════════════════════════════════════════════════════════════════════
# SETUP
# ═════════════════════════════════════════════════════════════════════════
func _configure_bracket(_bracket: int) -> void:
	set_round_count(ROUNDS_PER_RUN)

	# The category comes from the host, which received it from the Trend Hub.
	# Pulled rather than pushed, matching how the anomaly params are read.
	if host != null and host.has_method("trend_id"):
		_trend_id = str(host.call("trend_id"))

	if _trend_id == "" or not TrendRegistry.has(_trend_id):
		# Not an error: a practice launch with no category still has to work.
		_trend_id = TrendRegistry.default_id()

	_symbols = TrendRegistry.symbol_count(_trend_id)
	_tempo = TrendRegistry.tempo(_trend_id)
	_palette_index = TrendRegistry.palette_index(_trend_id)
	_window_ms = fair_window_ms(_symbols, _tempo)

	Log.d("TrendWitness", "'%s': %d symbols, tempo %.2f, window %dms" % [
		_trend_id, _symbols, _tempo, _window_ms])


## The fair reading window, in milliseconds.
##
## Static and pure so the fairness property can be tested directly across every
## category without running a round.
static func fair_window_ms(symbol_count: int, tempo: float) -> int:
	var safe_symbols: int = maxi(symbol_count, 1)
	var safe_tempo: float = maxf(tempo, 0.05)
	var read_ms: float = (float(safe_symbols) / READ_RATE_PER_SEC) * 1000.0
	var total: float = read_ms * safe_tempo + float(REACTION_ALLOWANCE_MS)
	return clampi(int(round(total)), WINDOW_FLOOR_MS, WINDOW_CEILING_MS)


func trend_id() -> String:
	return _trend_id


func window_ms() -> int:
	return _window_ms


func score() -> int:
	return _score


func hits() -> int:
	return _hits


func current_phase() -> int:
	return int(_phase)


func begin() -> void:
	super()
	set_process(true)
	# A rescue is per RUN. Reset here rather than at declaration so a reused
	# instance cannot inherit a spent continue from the previous run.
	has_used_ad_continue = false
	_run_over = false
	_prompt_open = false
	_start_round()


## Rule B: any Bus/AdManager subscription is torn down explicitly. A rescue ad
## can still be in flight when the player backs out mid-prompt, and a callback
## into a freed node is a crash.
func _exit_tree() -> void:
	_disconnect_rescue_ad()


# ═════════════════════════════════════════════════════════════════════════
# THE FIVE-PHASE LOOP
# ═════════════════════════════════════════════════════════════════════════
func _start_round() -> void:
	clear_targets()
	_target = _rng.randi_range(0, _symbols - 1)
	_build_crowd()
	_enter(Phase.BRIEFING, BRIEFING_SEC)


func _build_crowd() -> void:
	# The crowd always contains the target exactly once, so the answer is
	# always present and never ambiguous.
	_crowd.clear()
	_crowd.append(_target)
	var extras: int = maxi(_symbols - 1, 1)
	for i: int in range(extras):
		var pick: int = _rng.randi_range(0, _symbols - 1)
		if pick == _target:
			pick = (pick + 1) % _symbols
		_crowd.append(pick)
	# Deterministic shuffle from the seeded RNG, so the layout is reproducible
	# for a given seed rather than depending on Array.shuffle()'s global state.
	for i: int in range(_crowd.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var swap: int = _crowd[i]
		_crowd[i] = _crowd[j]
		_crowd[j] = swap


func _enter(phase: Phase, duration: float) -> void:
	_phase = phase
	_phase_left = duration
	if phase == Phase.IDENTIFY:
		_build_answer_targets()
		# The stimulus is answerable NOW — not when the round began. Marked
		# here so briefing, flash and witness time are never counted as
		# reaction time.
		mark_stimulus()
	queue_redraw()


func _process(delta: float) -> void:
	if not is_running():
		return

	_phase_left -= delta

	match _phase:
		Phase.BRIEFING:
			if _phase_left <= 0.0:
				_enter(Phase.FLASH, FLASH_SEC)
		Phase.FLASH:
			if _phase_left <= 0.0:
				_enter(Phase.WITNESS, float(_window_ms) / 1000.0)
		Phase.WITNESS:
			if _phase_left <= 0.0:
				# The crowd clears and the player must now identify from
				# memory, inside the same fair window.
				_enter(Phase.IDENTIFY, float(_window_ms) / 1000.0)
		Phase.IDENTIFY:
			if _phase_left <= 0.0:
				_on_timeout()
		Phase.EVALUATE:
			if _phase_left <= 0.0:
				if rounds_done() < rounds_total():
					_start_round()
		Phase.PROMPT:
			# Deliberately inert. The run is FROZEN while the choice is open:
			# no timer advances, no round starts, and the only exits are the
			# two hit targets or an ad callback.
			pass
		Phase.RESUMING:
			_countdown_left -= delta
			if _countdown_left <= 0.0:
				_start_round()

	queue_redraw()


func _build_answer_targets() -> void:
	clear_targets()
	var unit: float = field_unit()
	var centre: Vector2 = field_centre()
	var per_row: int = mini(_symbols, 5)
	var spacing: float = unit * 0.17
	var half: float = unit * 0.068

	for i: int in range(_symbols):
		var index: int = i
		# Deliberate floor: this is a grid row index, not a ratio.
		@warning_ignore("integer_division")
		var row: int = i / per_row
		var col: int = i % per_row
		var in_row: int = mini(per_row, _symbols - row * per_row)
		var start_x: float = centre.x - spacing * float(in_row - 1) * 0.5
		var pos: Vector2 = Vector2(
			start_x + spacing * float(col),
			centre.y + unit * 0.22 + float(row) * spacing)
		make_target(Rect2(pos - Vector2(half, half), Vector2(half, half) * 2.0),
			func() -> void: _on_answer(index))


func _on_answer(index: int) -> void:
	if not is_running() or _phase != Phase.IDENTIFY:
		return

	var correct: bool = index == _target
	var latency: int = latency_since_stimulus()

	if correct:
		_hits += 1
		_score += SCORE_PER_HIT + _speed_bonus(latency)

	_feedback = 1 if correct else -1
	HapticsManager.pulse(&"ui_tap" if correct else &"error")
	clear_targets()
	# A real response — latency is measured from the IDENTIFY mark.
	submit(correct, false)
	if not is_running():
		return
	if not correct and _offer_rescue():
		return
	_enter(Phase.EVALUATE, EVALUATE_SEC)


## Speed bonus decaying linearly across the fair window. Never negative, so a
## slow-but-correct answer is still worth more than a wrong one.
func _speed_bonus(latency_ms: int) -> int:
	if latency_ms < 0 or _window_ms <= 0:
		return 0
	var fraction: float = 1.0 - clampf(float(latency_ms) / float(_window_ms), 0.0, 1.0)
	return int(round(float(SPEED_BONUS_MAX) * fraction))


func _on_timeout() -> void:
	_feedback = -1
	clear_targets()
	# Flagged as a timeout so it counts as a miss rather than recording a
	# latency equal to the window — which would look like a slow real answer.
	submit(false, true)
	if not is_running():
		return
	# A timeout is a failure like any other, and routes through the SAME gate
	# as a wrong answer. Two rescue paths would eventually disagree about
	# whether the offer had already been used.
	if _offer_rescue():
		return
	_enter(Phase.EVALUATE, EVALUATE_SEC)


# ═════════════════════════════════════════════════════════════════════════
# SAVE YOUR STREAK
# ═════════════════════════════════════════════════════════════════════════
## Is a rescue available for the failure that just happened?
##
## Static and pure so every branch of the eligibility rule is testable without
## a scene, an ad, or a running clock.
static func rescue_eligible(round_index: int, already_used: bool) -> bool:
	if already_used:
		return false
	return round_index >= AD_CONTINUE_MIN_ROUND


## Show the STREAK IN DANGER prompt if this failure qualifies.
## Returns true when the run has been frozen and the caller must not advance.
func _offer_rescue() -> bool:
	# rounds_done() counts the failure that just submitted, so it IS the
	# 1-based round number the player just lost on.
	if not rescue_eligible(rounds_done(), has_used_ad_continue):
		return false
	# Nothing to rescue on the final round — the run is over either way, and
	# offering an ad to continue a finished run would be a lie.
	if rounds_done() >= rounds_total():
		return false
	if not is_running():
		return false

	# COOLDOWN GUARD. A rescue ad too soon after the last one means the player
	# is being asked to watch back-to-back ads, so the prompt is skipped
	# entirely and the run ends normally.
	#
	# Skipped SILENTLY, not shown-and-disabled: a rescue offer the player
	# cannot accept is worse than no offer, because it advertises a way out
	# that does not exist and turns a lost run into a lost run plus a refusal.
	if not AdManager.can_show_retry_ad():
		Log.info("TrendWitness", "rescue suppressed; %ds of ad cooldown left"
			% AdManager.get_retry_cooldown_remaining_sec())
		return false

	# INVENTORY GUARD. Offering a rescue with no ad loaded would show a prompt
	# whose only working option is "give up" — worse than no prompt, because
	# it costs the player a decision and then refuses them anyway.
	#
	# The preload nudge is deliberate: the run is ending either way, and the
	# next one should not inherit an empty cache.
	if not AdManager.is_rewarded_ad_ready():
		Log.info("TrendWitness", "rescue suppressed; no ad loaded")
		AdManager.preload_rewarded_ad()
		return false

	# Capture the exact state to restore. Recomputing it after the ad would
	# risk the speed bonuses drifting from what the player actually earned.
	_rescue_score = _score
	_rescue_hits = _hits
	_prompt_open = true
	clear_targets()
	_build_prompt_targets()
	_enter(Phase.PROMPT, 0.0)
	AudioManager.play_sfx(&"error")
	Log.info("TrendWitness", "streak in danger at round %d/%d" % [
		rounds_done(), rounds_total()])
	return true


## The prompt's two choices. Built as explicit hit targets, matching how every
## other interaction in this mode works.
func _build_prompt_targets() -> void:
	var unit: float = field_unit()
	var centre: Vector2 = field_centre()
	var half_w: float = unit * 0.34
	var half_h: float = unit * 0.055

	make_target(Rect2(centre + Vector2(-half_w, unit * 0.04),
		Vector2(half_w * 2.0, half_h * 2.0)), _on_watch_ad_pressed)
	make_target(Rect2(centre + Vector2(-half_w, unit * 0.20),
		Vector2(half_w * 2.0, half_h * 2.0)), _on_give_up_pressed)


func _on_watch_ad_pressed() -> void:
	if not _prompt_open:
		return
	AudioManager.play_sfx(&"ui_tap")

	# Subscribe only while an ad is in flight, so a rewarded ad watched
	# elsewhere can never resurrect a run that already ended.
	if not AdManager.ad_watched_successfully.is_connected(_on_rescue_ad_watched):
		AdManager.ad_watched_successfully.connect(_on_rescue_ad_watched)
	if not AdManager.ad_dismissed_early.is_connected(_on_rescue_ad_dismissed):
		AdManager.ad_dismissed_early.connect(_on_rescue_ad_dismissed)

	if not AdManager.show_rewarded(AD_PLACEMENT):
		# No ad to serve. Say so and end honestly rather than granting a free
		# continue — a rescue that costs nothing is not a rescue.
		Log.info("TrendWitness", "no rescue ad available")
		Bus.toast.emit("No ad available right now", "✧")
		_disconnect_rescue_ad()
		_end_run()


func _on_give_up_pressed() -> void:
	if not _prompt_open:
		return
	AudioManager.play_sfx(&"ui_tap")
	Log.info("TrendWitness", "player declined the rescue")
	_end_run()


func _on_rescue_ad_watched(placement: String) -> void:
	if placement != AD_PLACEMENT:
		return
	_disconnect_rescue_ad()
	if not _prompt_open or _run_over:
		return
	_resume_after_rescue()


func _on_rescue_ad_dismissed(placement: String) -> void:
	if placement != AD_PLACEMENT:
		return
	_disconnect_rescue_ad()
	if not _prompt_open or _run_over:
		return
	# Dropped without earning the reward. The run ends and the score still
	# counts — the player keeps everything they earned before the failure.
	Log.info("TrendWitness", "rescue ad dismissed; ending the run")
	_end_run()


func _disconnect_rescue_ad() -> void:
	if AdManager.ad_watched_successfully.is_connected(_on_rescue_ad_watched):
		AdManager.ad_watched_successfully.disconnect(_on_rescue_ad_watched)
	if AdManager.ad_dismissed_early.is_connected(_on_rescue_ad_dismissed):
		AdManager.ad_dismissed_early.disconnect(_on_rescue_ad_dismissed)


## The ad completed. Restore what was earned and resume with a countdown.
func _resume_after_rescue() -> void:
	has_used_ad_continue = true
	_prompt_open = false

	# Restore the captured totals. The failed round STAYS counted as attempted
	# — the rescue buys another scenario, it does not erase the mistake, and
	# rewriting history would let a rescued run out-score a clean one.
	_score = _rescue_score
	_hits = _rescue_hits
	_feedback = 0

	clear_targets()
	HapticsManager.pattern(&"streak_celebrate")
	Bus.toast.emit("Streak saved", "✦")
	Log.info("TrendWitness", "rescued at round %d; score %d preserved" % [
		rounds_done(), _score])

	_countdown_left = RESUME_COUNTDOWN_SEC
	_enter(Phase.RESUMING, RESUME_COUNTDOWN_SEC)


## End the run for good and let the host settle it.
func _end_run() -> void:
	if _run_over:
		return
	_run_over = true
	_prompt_open = false
	_disconnect_rescue_ad()
	clear_targets()
	# finish() routes to the host's conclude_trial(), which is the ONLY path
	# that submits a score. This mode never writes one itself.
	finish()


# ═════════════════════════════════════════════════════════════════════════
# DRAW — procedural, zero assets
# ═════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	var unit: float = field_unit()
	var centre: Vector2 = field_centre()

	match _phase:
		Phase.BRIEFING:
			_draw_ring(centre, unit, 1.0 - clampf(_phase_left / BRIEFING_SEC, 0.0, 1.0))
		Phase.FLASH:
			_draw_symbol(centre + Vector2(0, -unit * 0.10), unit * 0.11, _target)
		Phase.WITNESS:
			_draw_crowd(centre, unit)
			_draw_timer(centre, unit, _phase_left / maxf(float(_window_ms) / 1000.0, 0.001))
		Phase.IDENTIFY:
			_draw_answers(centre, unit)
			_draw_timer(centre, unit, _phase_left / maxf(float(_window_ms) / 1000.0, 0.001))
		Phase.EVALUATE:
			_draw_answers(centre, unit)
			var col: Color = Palette.success() if _feedback > 0 else Palette.danger()
			draw_arc(centre, unit * 0.44, 0.0, TAU, 48,
				Color(col, clampf(_phase_left / EVALUATE_SEC, 0.0, 1.0) * 0.6),
				maxf(unit * 0.012, 2.0), true)
		Phase.PROMPT:
			_draw_prompt(centre, unit)
		Phase.RESUMING:
			_draw_countdown(centre, unit)


func _draw_ring(centre: Vector2, unit: float, progress: float) -> void:
	draw_arc(centre, unit * 0.26, -PI * 0.5, -PI * 0.5 + TAU * clampf(progress, 0.0, 1.0),
		48, Color(Palette.accent(), 0.7), maxf(unit * 0.010, 2.0), true)


func _draw_timer(centre: Vector2, unit: float, fraction: float) -> void:
	var clamped: float = clampf(fraction, 0.0, 1.0)
	var col: Color = Palette.danger() if clamped < 0.3 else Palette.accent()
	draw_arc(centre + Vector2(0, -unit * 0.22), unit * 0.16, -PI * 0.5,
		-PI * 0.5 + TAU * clamped, 48, Color(col, 0.65),
		maxf(unit * 0.008, 1.5), true)


func _draw_crowd(centre: Vector2, unit: float) -> void:
	var per_row: int = mini(_crowd.size(), 5)
	if per_row <= 0:
		return
	var spacing: float = unit * 0.15
	var radius: float = unit * 0.048
	for i: int in range(_crowd.size()):
		@warning_ignore("integer_division")
		var row: int = i / per_row
		var col: int = i % per_row
		var in_row: int = mini(per_row, _crowd.size() - row * per_row)
		var start_x: float = centre.x - spacing * float(in_row - 1) * 0.5
		_draw_symbol(Vector2(start_x + spacing * float(col),
			centre.y + float(row) * spacing), radius, _crowd[i])


func _draw_answers(centre: Vector2, unit: float) -> void:
	var per_row: int = mini(_symbols, 5)
	var spacing: float = unit * 0.17
	var radius: float = unit * 0.055
	for i: int in range(_symbols):
		@warning_ignore("integer_division")
		var row: int = i / per_row
		var col: int = i % per_row
		var in_row: int = mini(per_row, _symbols - row * per_row)
		var start_x: float = centre.x - spacing * float(in_row - 1) * 0.5
		_draw_symbol(Vector2(start_x + spacing * float(col),
			centre.y + unit * 0.22 + float(row) * spacing), radius, i)


## The STREAK IN DANGER prompt. Two clearly separated choices, the destructive
## one placed second and rendered quieter — a player tapping fast should not
## land on "give up" by muscle memory.
func _draw_prompt(centre: Vector2, unit: float) -> void:
	# Scrim, so the frozen board reads as inactive rather than merely paused.
	draw_rect(Rect2(Vector2.ZERO, size), Palette.COLOR_SCRIM, true)

	var danger: Color = Palette.danger()
	draw_arc(centre + Vector2(0, -unit * 0.20), unit * 0.13, 0.0, TAU, 48,
		Color(danger, 0.85), maxf(unit * 0.012, 2.0), true)

	# "Watch ad" — the constructive choice, in the accent colour.
	var accent: Color = Palette.accent()
	var half_w: float = unit * 0.34
	var half_h: float = unit * 0.055
	draw_rect(Rect2(centre + Vector2(-half_w, unit * 0.04),
		Vector2(half_w * 2.0, half_h * 2.0)), Color(accent, 0.22), true)
	draw_rect(Rect2(centre + Vector2(-half_w, unit * 0.04),
		Vector2(half_w * 2.0, half_h * 2.0)), Color(accent, 0.9), false,
		maxf(unit * 0.006, 1.5))

	# "Give up" — outline only, no fill, so it never competes for the thumb.
	draw_rect(Rect2(centre + Vector2(-half_w, unit * 0.20),
		Vector2(half_w * 2.0, half_h * 2.0)), Palette.COLOR_TEXT_FAINT, false,
		maxf(unit * 0.004, 1.0))


## 3-2-1 before play resumes, so the run never restarts under the player's
## thumb while they are still putting the phone back to their face.
func _draw_countdown(centre: Vector2, unit: float) -> void:
	var remaining: int = maxi(int(ceil(_countdown_left)), 1)
	var fraction: float = clampf(_countdown_left / RESUME_COUNTDOWN_SEC, 0.0, 1.0)
	var accent: Color = Palette.accent()
	draw_arc(centre, unit * 0.22, -PI * 0.5, -PI * 0.5 + TAU * fraction, 64,
		Color(accent, 0.8), maxf(unit * 0.014, 2.0), true)
	# The count itself, as that many filled pips — no font, no texture.
	for i: int in range(remaining):
		var offset: float = (float(i) - float(remaining - 1) * 0.5) * unit * 0.07
		draw_circle(centre + Vector2(offset, 0.0), unit * 0.022,
			Color(accent, 0.9))


## Read-only view of the rescue state, for tests and the host.
func rescue_prompt_open() -> bool:
	return _prompt_open


func is_run_over() -> bool:
	return _run_over


func countdown_remaining() -> float:
	return _countdown_left


## Each symbol is a distinct procedural polygon AND a distinct hue, so the task
## never depends on colour alone — the same accessibility rule the Stroop trial
## follows.
func _draw_symbol(at: Vector2, radius: float, index: int) -> void:
	var facets: Array[Color] = Palette.FACET_COLORS
	var colour: Color = facets[(index + _palette_index) % facets.size()]
	var sides: int = 3 + (index % 6)
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(sides):
		var angle: float = -PI * 0.5 + TAU * float(i) / float(sides)
		points.append(at + Vector2(cos(angle), sin(angle)) * radius)
	draw_colored_polygon(points, Color(colour, 0.88))
