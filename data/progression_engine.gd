extends RefCounted
class_name ProgressionEngine
## ProgressionEngine — XP grants, Lumina payouts, and daily streak evaluation.
##
## PHASE 6. Pure logic: no nodes, no scenes, no UI, no Save calls. It mutates a
## supplied IrisState and returns a typed summary; the caller decides when to
## persist. That keeps every calculation unit-testable without a scene tree.
##
## OVERFLOW SAFETY is a first-class concern here. Godot ints are 64-bit, but a
## rank-1,000,000 player with a streak multiplier and a rank bonus can still
## produce a large product. Every award clamps to MAX_SAFE_AWARD before it is
## added, and every balance clamps to MAX_BALANCE after. Negative inputs are
## rejected with a logged assertion rather than silently flipping a balance.
##
## Reference schema (v1 IrisProgression): bracket bases [40, 70, 110],
## daily base 68 with +10%/day capped at 3.0x, resonance gate at 0.90 accuracy.
## Those numbers are carried across; the structure around them is new.

# ═════════════════════════════════════════════════════════════════════════
# ECONOMY CONSTANTS
# ═════════════════════════════════════════════════════════════════════════

## Base Lumina per difficulty bracket, before accuracy and bonuses.
const BRACKET_BASE_LUMINA: Array[int] = [40, 70, 110]
## Difficulty multiplier applied on top of the bracket base.
const BRACKET_MULTIPLIER: Array[float] = [1.0, 1.35, 1.8]
## Nobody leaves empty-handed; a completed trial always pays something.
const MIN_LUMINA_AWARD: int = 5

## XP is earned alongside Lumina, weighted by difficulty.
const BRACKET_BASE_XP: Array[int] = [25, 45, 70]

## Resonance (lens shimmer) is only earned at high accuracy.
const RESONANCE_ACCURACY_GATE: float = 0.90
const RESONANCE_BASE: int = 1

## Rank bonus: +1% Lumina per rank, logarithmically damped so rank 1,000,000
## is generous but not absurd. Capped so late-game cannot trivialise costs.
const RANK_BONUS_SCALE: float = 0.06
const RANK_BONUS_MAX: float = 1.5

# ── Daily streak ─────────────────────────────────────────────────────────
const DAILY_BASE_LUMINA: int = 50
## Each consecutive day adds this fraction to the daily multiplier.
const DAILY_STREAK_STEP: float = 0.10
const DAILY_MAX_MULTIPLIER: float = 3.0
## Explicit milestone track. Day 3 lands early enough to hook a new player
## before the 7-day cliff; day 30 gives long-streak players a horizon.
## Beyond 30, every 7th day repeats the day-7 reward so the curve never dies.
const STREAK_MILESTONE_DAYS: Array[int] = [3, 7, 14, 21, 30]
const STREAK_MILESTONE_LUMINA: Dictionary = {
	3: 150, 7: 500, 14: 900, 21: 1400, 30: 2500,
}
## Repeating reward past the final named milestone, on every 7th day.
const STREAK_MILESTONE_REPEAT_DAY: int = 7
const STREAK_MILESTONE_REPEAT_LUMINA: int = 500
## Grace: returning within this many days keeps the streak alive.
const STREAK_GRACE_DAYS: int = 1

# ── Safety rails ─────────────────────────────────────────────────────────
## Ceiling on any single award. Generous enough that no legitimate play hits
## it, small enough that a bug cannot mint an unusable balance.
const MAX_SAFE_AWARD: int = 1_000_000
## Ceiling on a stored balance. Well inside 64-bit range with room for
## multiplication headroom before any clamp is applied.
const MAX_BALANCE: int = 1_000_000_000_000

## Ranks at which a bonus procedural cosmetic seed unlocks.
const RANK_SEED_MILESTONES: Array[int] = [5, 10, 25, 50, 100, 250, 500, 1000]


# ═════════════════════════════════════════════════════════════════════════
# XP
# ═════════════════════════════════════════════════════════════════════════
## Grant XP and evaluate rank-up. Returns a summary:
##   { granted, rank_before, rank_after, ranks_gained, unlocked_seeds }
##
## Rank-up seeds are granted here because the milestone list is a progression
## rule, not a wardrobe rule — the Wardrobe only ever spends and equips.
static func add_rank_xp(state: IrisState, amount: int) -> Dictionary:
	var empty: Dictionary = {
		"granted": 0, "rank_before": 0, "rank_after": 0,
		"ranks_gained": 0, "unlocked_seeds": [],
	}
	if not Log.must(state != null, "Progression", "add_rank_xp got null state"):
		return empty
	if not Log.must(amount >= 0, "Progression", "cannot grant negative XP (%d)" % amount):
		return empty

	var granted: int = clampi(amount, 0, MAX_SAFE_AWARD)
	var rank_before: int = state.rank_tier

	# Clamp the accumulated total, not just the increment.
	state.rank_xp = clampi(state.rank_xp + granted, 0, MAX_BALANCE)
	state.rank_tier = maxi(state.rank_for_total_xp(state.rank_xp), 1)

	var seeds: Array[int] = []
	if state.rank_tier > rank_before:
		seeds = _grant_rank_milestone_seeds(state, rank_before, state.rank_tier)

	return {
		"granted": granted,
		"rank_before": rank_before,
		"rank_after": state.rank_tier,
		"ranks_gained": maxi(state.rank_tier - rank_before, 0),
		"unlocked_seeds": seeds,
	}


## Grant a seed for every milestone crossed. Crossing several at once (a large
## XP dump) awards all of them rather than only the highest.
static func _grant_rank_milestone_seeds(state: IrisState, from_rank: int,
		to_rank: int) -> Array[int]:
	var granted: Array[int] = []
	for milestone: int in RANK_SEED_MILESTONES:
		if milestone > from_rank and milestone <= to_rank:
			var seed_value: int = IrisState.derive_seed_from_sku(
				"rank_reward_%d" % milestone)
			if state.grant_seed(seed_value):
				granted.append(seed_value)
	return granted


# ═════════════════════════════════════════════════════════════════════════
# LUMINA
# ═════════════════════════════════════════════════════════════════════════
## Award Lumina. Returns the amount actually credited after clamping, which may
## be less than requested if the balance ceiling is reached.
static func award_lumina(state: IrisState, amount: int) -> int:
	if not Log.must(state != null, "Progression", "award_lumina got null state"):
		return 0
	if not Log.must(amount >= 0, "Progression", "cannot award negative Lumina (%d)" % amount):
		return 0

	var granted: int = clampi(amount, 0, MAX_SAFE_AWARD)
	var before: int = state.lumina
	state.lumina = clampi(state.lumina + granted, 0, MAX_BALANCE)
	return state.lumina - before


## Award Resonance (lens shimmer). Stored as a float on IrisState, so the
## clamp is applied in float space.
static func award_resonance(state: IrisState, amount: int) -> int:
	if not Log.must(state != null, "Progression", "award_resonance got null state"):
		return 0
	if not Log.must(amount >= 0, "Progression", "cannot award negative Resonance"):
		return 0
	var granted: int = clampi(amount, 0, MAX_SAFE_AWARD)
	var before: float = state.lens_shimmer
	state.lens_shimmer = clampf(state.lens_shimmer + float(granted),
		0.0, float(MAX_BALANCE))
	return int(state.lens_shimmer - before)


# ═════════════════════════════════════════════════════════════════════════
# REWARD CALCULATION
# ═════════════════════════════════════════════════════════════════════════
## Final Lumina = Base * Difficulty Multiplier * Streak Bonus * Rank Bonus
##
## Pure: takes no state and mutates nothing, so the payout for any hypothetical
## run can be computed and tested in isolation.
static func compute_lumina_reward(accuracy: float, bracket: int,
		streak_days: int, rank_tier: int) -> int:
	var safe_bracket: int = clampi(bracket, 0, BRACKET_BASE_LUMINA.size() - 1)
	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)

	var base: float = float(BRACKET_BASE_LUMINA[safe_bracket]) * safe_accuracy
	var difficulty: float = BRACKET_MULTIPLIER[safe_bracket]
	var streak: float = streak_multiplier(streak_days)
	var rank: float = rank_bonus_multiplier(rank_tier)

	var total: float = base * difficulty * streak * rank
	return clampi(int(round(total)), MIN_LUMINA_AWARD, MAX_SAFE_AWARD)


## XP scales with difficulty and accuracy but NOT with streak — streaks reward
## currency, not permanent progression, so a lapsed player never falls
## irrecoverably behind on rank.
static func compute_xp_reward(accuracy: float, bracket: int) -> int:
	var safe_bracket: int = clampi(bracket, 0, BRACKET_BASE_XP.size() - 1)
	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)
	var total: float = float(BRACKET_BASE_XP[safe_bracket]) * safe_accuracy
	return clampi(int(round(total)), 1, MAX_SAFE_AWARD)


## Resonance is only earned above the accuracy gate, weighted by bracket.
static func compute_resonance_reward(accuracy: float, bracket: int) -> int:
	if accuracy < RESONANCE_ACCURACY_GATE:
		return 0
	return RESONANCE_BASE + clampi(bracket, 0, 2)


## 1.0 + 0.10 per consecutive day, capped at 3.0x (reached at 20 days).
static func streak_multiplier(streak_days: int) -> float:
	var safe_days: int = maxi(streak_days, 0)
	return minf(1.0 + float(safe_days) * DAILY_STREAK_STEP, DAILY_MAX_MULTIPLIER)


## Logarithmic rank bonus, capped. Rank 1 ≈ 1.04x, rank 1,000 ≈ 1.41x,
## rank 1,000,000 ≈ 1.50x (the cap). Rewards depth without breaking the economy.
static func rank_bonus_multiplier(rank_tier: int) -> float:
	var safe_rank: int = maxi(rank_tier, 1)
	return minf(1.0 + log(1.0 + float(safe_rank)) * RANK_BONUS_SCALE, RANK_BONUS_MAX)


# ═════════════════════════════════════════════════════════════════════════
# DAILY STREAK
# ═════════════════════════════════════════════════════════════════════════
## Days since the Unix epoch in LOCAL time.
##
## Local, not UTC: a player in UTC+13 finishing at 9pm local would otherwise
## have their "day" already rolled over, breaking a streak they legitimately
## kept. v1 used UTC and had exactly this bug latent in it.
static func local_day_index(unix_time: float) -> int:
	var zone: Dictionary = Time.get_time_zone_from_system()
	var bias_seconds: int = int(zone.get("bias", 0)) * 60
	return int(floor((unix_time + float(bias_seconds)) / 86400.0))


## Evaluate the daily streak against the device clock. Returns:
##   { claimed, streak_days, previous_streak, lumina, is_milestone,
##     seed_granted, missed_days }
##
## `claimed` is false when the player has already collected today — calling
## this repeatedly in one day is safe and idempotent.
static func evaluate_daily_streak(state: IrisState, last_day_index: int,
		now_unix: float = -1.0) -> Dictionary:
	var result: Dictionary = {
		"claimed": false, "streak_days": 0, "previous_streak": 0,
		"lumina": 0, "is_milestone": false, "seed_granted": 0, "missed_days": 0,
	}
	if not Log.must(state != null, "Progression", "evaluate_daily_streak got null"):
		return result

	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var today: int = local_day_index(now)
	result["previous_streak"] = state.streak_days

	# Already claimed today.
	if last_day_index == today:
		result["streak_days"] = state.streak_days
		return result

	# Clock moved backwards (timezone change, manual clock edit, NTP correction).
	# Do NOT reset or reward — treat it as "not yet today" and wait for the
	# clock to catch up. Punishing the player for a device quirk is worse than
	# briefly withholding a reward.
	if last_day_index > today:
		Log.warn("Progression", "clock moved backwards (last=%d today=%d)" % [
			last_day_index, today])
		result["streak_days"] = state.streak_days
		return result

	var gap: int = today - last_day_index
	var previous: int = state.streak_days

	if last_day_index < 0:
		# First ever claim.
		state.streak_days = 1
	elif gap <= 1 + STREAK_GRACE_DAYS:
		# Consecutive (gap 1) or within grace (gap 2).
		state.streak_days = previous + 1
	else:
		# Missed too many days — start over, but they still get day 1 today.
		state.streak_days = 1
		result["missed_days"] = gap - 1

	var payout: int = compute_daily_lumina(state.streak_days)
	var credited: int = award_lumina(state, payout)

	result["claimed"] = true
	result["streak_days"] = state.streak_days
	result["lumina"] = credited

	# Track the personal best, which never decreases.
	state.best_streak_days = maxi(state.best_streak_days, state.streak_days)

	# Milestones grant a bonus procedural seed on top of the payout.
	if is_milestone_day(state.streak_days):
		result["is_milestone"] = true
		var seed_value: int = IrisState.derive_seed_from_sku(
			"streak_reward_%d" % state.streak_days)
		if state.grant_seed(seed_value):
			result["seed_granted"] = seed_value

	return result


## Daily payout for a given streak length. Day 7 and every 7th day thereafter
## pay the milestone amount instead of the scaled base.
static func compute_daily_lumina(streak_days: int) -> int:
	var safe_days: int = maxi(streak_days, 1)
	if STREAK_MILESTONE_LUMINA.has(safe_days):
		return int(STREAK_MILESTONE_LUMINA[safe_days])
	if is_milestone_day(safe_days):
		return STREAK_MILESTONE_REPEAT_LUMINA
	var scaled: float = float(DAILY_BASE_LUMINA) * streak_multiplier(safe_days - 1)
	return clampi(int(round(scaled)), DAILY_BASE_LUMINA, MAX_SAFE_AWARD)


## True on a named milestone day, or on every 7th day past the final one.
static func is_milestone_day(streak_days: int) -> bool:
	if streak_days <= 0:
		return false
	if STREAK_MILESTONE_DAYS.has(streak_days):
		return true
	var final_named: int = STREAK_MILESTONE_DAYS[STREAK_MILESTONE_DAYS.size() - 1]
	if streak_days > final_named:
		return streak_days % STREAK_MILESTONE_REPEAT_DAY == 0
	return false


## The next milestone day at or after `streak_days`, for the UI track.
static func next_milestone_day(streak_days: int) -> int:
	for day: int in STREAK_MILESTONE_DAYS:
		if day > streak_days:
			return day
	var final_named: int = STREAK_MILESTONE_DAYS[STREAK_MILESTONE_DAYS.size() - 1]
	var next_repeat: int = final_named + STREAK_MILESTONE_REPEAT_DAY
	while next_repeat <= streak_days:
		next_repeat += STREAK_MILESTONE_REPEAT_DAY
	return next_repeat


## True if a daily reward is available right now.
static func is_daily_available(last_day_index: int, now_unix: float = -1.0) -> bool:
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	return local_day_index(now) > last_day_index


# ═════════════════════════════════════════════════════════════════════════
# TRIAL SETTLEMENT
# ═════════════════════════════════════════════════════════════════════════
## Apply a completed trial to state. Returns a full summary for the results UI.
##
## This is the single place a trial turns into progression, so the ordering of
## XP, Lumina, and Resonance can never drift between call sites.
static func settle_trial(state: IrisState, accuracy: float, bracket: int,
		trial_id: String = "") -> Dictionary:
	var summary: Dictionary = {
		"trial_id": trial_id, "accuracy": 0.0, "bracket": 0,
		"lumina": 0, "xp": 0, "resonance": 0,
		"rank_before": 0, "rank_after": 0, "ranks_gained": 0,
		"unlocked_seeds": [], "streak_days": 0,
		"streak_multiplier": 1.0, "rank_multiplier": 1.0,
	}
	if not Log.must(state != null, "Progression", "settle_trial got null state"):
		return summary

	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)
	var safe_bracket: int = clampi(bracket, 0, BRACKET_BASE_LUMINA.size() - 1)

	var lumina: int = compute_lumina_reward(
		safe_accuracy, safe_bracket, state.streak_days, state.rank_tier)
	var xp: int = compute_xp_reward(safe_accuracy, safe_bracket)
	var resonance: int = compute_resonance_reward(safe_accuracy, safe_bracket)

	var credited_lumina: int = award_lumina(state, lumina)
	var credited_resonance: int = award_resonance(state, resonance)
	var xp_result: Dictionary = add_rank_xp(state, xp)

	summary["accuracy"] = safe_accuracy
	summary["bracket"] = safe_bracket
	summary["lumina"] = credited_lumina
	summary["xp"] = int(xp_result.get("granted", 0))
	summary["resonance"] = credited_resonance
	summary["rank_before"] = int(xp_result.get("rank_before", 0))
	summary["rank_after"] = int(xp_result.get("rank_after", 0))
	summary["ranks_gained"] = int(xp_result.get("ranks_gained", 0))
	summary["unlocked_seeds"] = xp_result.get("unlocked_seeds", [])
	summary["streak_days"] = state.streak_days
	summary["streak_multiplier"] = streak_multiplier(state.streak_days)
	summary["rank_multiplier"] = rank_bonus_multiplier(state.rank_tier)
	return summary
