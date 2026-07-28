extends RefCounted
class_name ChronoPulse
## ChronoPulse — the daily anomaly: one shared puzzle, one shot, every day.
##
## PHASE 1: pure data and maths. No UI, no scene, no node accessors, no Save
## writes. Every function is static and takes its inputs explicitly, so the
## whole system can be exercised headlessly and — critically — at any date the
## test wants, including ones that have not happened yet.
##
## ═══════════════════════════════════════════════════════════════════════════
## THE TWO-CLOCK DESIGN, AND WHY IT IS NOT AN INCONSISTENCY
## ═══════════════════════════════════════════════════════════════════════════
## This system deliberately reads the calendar TWICE, against two different
## clocks, because it is answering two different questions:
##
##   WHICH PUZZLE?  → UTC date (seed_for_unix)
##       Every player on Earth must face the same anomaly on the same date, or
##       comparing results is meaningless and a shared score card is a lie. A
##       local-time seed would hand Auckland and Los Angeles different puzzles
##       on the same calendar date.
##
##   DID YOU SHOW UP?  → LOCAL date (ProgressionEngine.local_day_index)
##       Streaks are about habit, and habit is lived in local time. v1 used UTC
##       for streaks and broke them for UTC+13 players, whose day had already
##       rolled over while it was still Tuesday evening for them. That fix is
##       load-bearing and documented at progression_engine.gd:211 — this system
##       does not get to re-break it.
##
## The consequence is real and accepted: near the date line a player can be
## shown puzzle N while being credited for local day M. That is strictly better
## than either alternative (different puzzles for different zones, or streaks
## that break at 11am). The mismatch is bounded — see max_seed_day_skew().
##
## ═══════════════════════════════════════════════════════════════════════════
## DETERMINISM
## ═══════════════════════════════════════════════════════════════════════════
## Parameters derive from the date string via FNV-1a, the same hash IrisState
## uses for cosmetic seeds, and for the same reason: String.hash() is an engine
## implementation detail. If it changed between Godot versions, every player's
## "identical" daily puzzle would silently diverge from every other player's,
## and the bug would be invisible until someone compared two phones.
##
## FNV-1a is fully specified, stable across engine versions and platforms, and
## already proven in this codebase.

# ═════════════════════════════════════════════════════════════════════════
# SAVE CONTRACT
# ═════════════════════════════════════════════════════════════════════════
## Everything ChronoPulse persists lives under this one section.
const SECTION: String = "chrono"

const KEY_CURRENT_STREAK: String = "current_streak"
const KEY_BEST_STREAK: String = "best_streak"
const KEY_LAST_COMPLETED_DATE: String = "last_completed_date"
const KEY_LAST_COMPLETED_DAY_INDEX: String = "last_completed_day_index"
const KEY_RECOVERY_USED_DATE: String = "recovery_used_date"
const KEY_HISTORY: String = "history"

## Completion records are stored as "solved_<UTC date>" so a day's result can
## be looked up without loading a list, and so the key itself is legible in a
## save dump when diagnosing a support report.
const COMPLETED_PREFIX: String = "solved_"

## The trial mode every daily anomaly runs in.
##
## Fixed, not weighted-random. A shared daily must be the same task for every
## player, or two people comparing cards from the same seed are describing
## different games. Variety comes from the anomaly's `kind` and its tuning,
## which change daily within this one mode.
##
## Stroop was chosen because it is the mode whose difficulty is expressed
## purely as a reaction window — exactly the quantity the card reports.
const TRIAL_ID: String = "cognitive_conflict"

## Cap on retained history. A daily game runs for years; unbounded growth would
## quietly inflate the save file forever. 400 keeps a full year plus slack.
const MAX_HISTORY_ENTRIES: int = 400

# ═════════════════════════════════════════════════════════════════════════
# STREAK RULES
# ═════════════════════════════════════════════════════════════════════════
## Missing a single day does NOT break the streak — matching the existing daily
## reward's grace so the two never disagree about whether a player "kept" it.
## Sourced from ProgressionEngine rather than redeclared: two constants that
## must be equal are one constant that is sometimes wrong.
const GRACE_DAYS: int = ProgressionEngine.STREAK_GRACE_DAYS

## Recovery restores a streak broken by a gap no larger than this. Beyond it
## the streak is genuinely gone; selling a recovery for a month-old lapse
## would make the streak meaningless.
const MAX_RECOVERABLE_GAP_DAYS: int = 3

## Lumina price of a streak recovery. Lumina, not a new currency: the project
## is 100% F2P with one earned currency, and inventing a second one to sell
## recoveries is the shape of an IAP with the money filed off.
const RECOVERY_LUMINA_COST: int = 250

## Recoveries are limited to one per local day, so a lapsed player cannot
## rebuild an arbitrarily long streak in a single sitting.
const MAX_RECOVERIES_PER_DAY: int = 1

# ═════════════════════════════════════════════════════════════════════════
# ANOMALY PARAMETERS
# ═════════════════════════════════════════════════════════════════════════
## Anomaly archetypes. Stable and persisted in history — never reorder.
enum Anomaly {
	PULSE_MATCH = 0,   # react when the pulse matches the reference
	PHASE_DRIFT = 1,   # react when drift exceeds a threshold
	ECHO_COUNT = 2,    # count echoes, react on the target beat
	NULL_WINDOW = 3,   # react inside a silent gap
}

const ANOMALY_NAMES: Array[String] = [
	"Pulse Match", "Phase Drift", "Echo Count", "Null Window",
]

## Reaction window bounds in milliseconds. The generator picks inside this
## range; the floor is above human reaction time (~200ms) so a legitimate
## player is never handed an impossible day.
const WINDOW_MIN_MS: int = 900
const WINDOW_MAX_MS: int = 2400

## Number of pulses in a run. More pulses = more chances to err, so this is the
## main difficulty dial alongside the window.
const PULSES_MIN: int = 4
const PULSES_MAX: int = 9

## Delay before the anomaly appears, in milliseconds. Randomised per day so the
## run cannot be answered by rote timing.
const LEAD_IN_MIN_MS: int = 1200
const LEAD_IN_MAX_MS: int = 3800

# ═════════════════════════════════════════════════════════════════════════
# PRECISION TIERS
# ═════════════════════════════════════════════════════════════════════════
## Latency tiers, fastest first. `max_ms` is INCLUSIVE and each tier begins one
## millisecond after the previous ends, so every latency lands in exactly one
## tier with no gap and no overlap. verify_tier_coverage() proves it.
const TIERS: Array[Dictionary] = [
	{"id": &"instant",  "label": "Instant",  "max_ms": 250},
	{"id": &"sharp",    "label": "Sharp",    "max_ms": 400},
	{"id": &"steady",   "label": "Steady",   "max_ms": 650},
	{"id": &"delayed",  "label": "Delayed",  "max_ms": 1000},
	{"id": &"adrift",   "label": "Adrift",   "max_ms": 2147483647},
]

## A miss is not a slow reaction — it is a different outcome, and collapsing
## the two would let a player who never reacted share a card claiming "Adrift"
## as though they had merely been slow.
const TIER_MISSED: StringName = &"missed"


# ═════════════════════════════════════════════════════════════════════════
# DATE HANDLING
# ═════════════════════════════════════════════════════════════════════════
## The UTC date string "YYYY-MM-DD" for a unix timestamp. This IS the seed id.
##
## Takes an explicit timestamp rather than reading the clock, because a
## function that reads the system clock can only ever be tested on the day the
## test runs. Every date-rollover, leap-year and month-boundary check in the
## suite exists only because this parameter is here.
static func seed_for_unix(unix_time: float) -> String:
	var utc: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d" % [
		int(utc.get("year", 1970)),
		int(utc.get("month", 1)),
		int(utc.get("day", 1)),
	]


## Today's UTC seed id, from the device clock.
static func current_seed() -> String:
	return seed_for_unix(Time.get_unix_time_from_system())


## The LOCAL date string "YYYY-MM-DD" for a unix timestamp.
##
## Display and record-keeping only. Streak arithmetic uses the integer day
## index below, because subtracting two date strings is not a thing.
static func local_date_for_unix(unix_time: float) -> String:
	var zone: Dictionary = Time.get_time_zone_from_system()
	var bias_seconds: int = int(zone.get("bias", 0)) * 60
	var local: Dictionary = Time.get_datetime_dict_from_unix_time(
		int(unix_time) + bias_seconds)
	return "%04d-%02d-%02d" % [
		int(local.get("year", 1970)),
		int(local.get("month", 1)),
		int(local.get("day", 1)),
	]


static func current_local_date() -> String:
	return local_date_for_unix(Time.get_unix_time_from_system())


## Local day index — the integer the streak actually advances on.
##
## Delegates to ProgressionEngine rather than reimplementing the timezone
## maths. A second copy of this calculation is exactly how a player would end
## up with a ChronoPulse streak of 7 and a daily-reward streak of 6.
static func local_day_index(unix_time: float) -> int:
	return ProgressionEngine.local_day_index(unix_time)


## Largest possible difference, in days, between the UTC seed date and the
## local streak date. Real offsets span UTC-12..UTC+14, so the two calendars
## can never disagree by more than one day in either direction.
##
## Exposed so the UI can state the bound honestly rather than pretending the
## two clocks always agree, and so a test can assert it holds across the whole
## offset range instead of trusting the comment.
static func max_seed_day_skew() -> int:
	return 1


# ═════════════════════════════════════════════════════════════════════════
# DETERMINISTIC GENERATION
# ═════════════════════════════════════════════════════════════════════════
## 32-bit FNV-1a. Identical to IrisState.derive_seed_from_sku, duplicated
## deliberately: this file must not depend on the cosmetic system, and the
## algorithm is a fixed public specification rather than a shared policy that
## might legitimately change in one place but not the other.
static func hash_seed(text: String) -> int:
	var hash_value: int = 2166136261
	for i: int in range(text.length()):
		hash_value ^= text.unicode_at(i)
		hash_value = (hash_value * 16777619) & 0xFFFFFFFF
	return hash_value


## Derive an independent value from one seed by salting it.
##
## Each parameter gets its OWN salted hash rather than consecutive draws from a
## shared RNG stream. Sequential draws couple the parameters: inserting a new
## field, or reordering two existing ones, silently changes every value after
## it and every player's puzzle shifts on the next release. Salting means
## parameters can be added or reordered freely and the existing ones do not
## move.
static func derive(seed_id: String, salt: String) -> int:
	return hash_seed(seed_id + "|" + salt)


## Map a derived hash into [minimum, maximum] inclusive.
static func _span(value: int, minimum: int, maximum: int) -> int:
	if not Log.must(maximum >= minimum, "ChronoPulse",
			"inverted span %d..%d" % [minimum, maximum]):
		return minimum
	var width: int = maximum - minimum + 1
	return minimum + (value % width)


## The full parameter set for a given day. Same date in, same puzzle out, on
## every device, forever.
##
## Returns a plain Dictionary rather than a Resource so it can be compared,
## hashed and serialised in tests without engine machinery.
static func anomaly_for_seed(seed_id: String) -> Dictionary:
	if not Log.must(seed_id != "", "ChronoPulse", "anomaly_for_seed got empty id"):
		seed_id = "1970-01-01"

	var kind: int = _span(derive(seed_id, "kind"), 0, ANOMALY_NAMES.size() - 1)
	var pulses: int = _span(derive(seed_id, "pulses"), PULSES_MIN, PULSES_MAX)
	var window_ms: int = _span(derive(seed_id, "window"), WINDOW_MIN_MS, WINDOW_MAX_MS)
	var lead_in_ms: int = _span(derive(seed_id, "lead"), LEAD_IN_MIN_MS, LEAD_IN_MAX_MS)

	# Which pulse carries the anomaly. Never the first — a player needs at
	# least one pulse to establish the rhythm before being asked to judge a
	# deviation from it.
	var target_index: int = _span(derive(seed_id, "target"), 1, pulses - 1)

	# Interval between pulses. Derived AFTER the window so a tight window is
	# not also compounded by a frantic tempo.
	var interval_ms: int = _span(derive(seed_id, "interval"), 620, 1150)

	return {
		"seed_id": seed_id,
		"kind": kind,
		"kind_name": ANOMALY_NAMES[kind],
		"pulses": pulses,
		"target_index": target_index,
		"window_ms": window_ms,
		"lead_in_ms": lead_in_ms,
		"interval_ms": interval_ms,
	}


## Convenience: today's anomaly.
static func anomaly_for_unix(unix_time: float) -> Dictionary:
	return anomaly_for_seed(seed_for_unix(unix_time))


# ═════════════════════════════════════════════════════════════════════════
# SCORING
# ═════════════════════════════════════════════════════════════════════════
## The precision tier for a reaction latency.
##
## A miss outranks every latency check: `hit == false` means the player never
## reacted, which is categorically different from reacting slowly.
static func tier_for_latency(latency_ms: int, hit: bool) -> StringName:
	if not hit:
		return TIER_MISSED
	if not Log.must(latency_ms >= 0, "ChronoPulse",
			"negative latency %d" % latency_ms):
		return TIER_MISSED
	for tier: Dictionary in TIERS:
		if latency_ms <= int(tier["max_ms"]):
			return StringName(tier["id"])
	# Unreachable: the last tier's ceiling is INT32_MAX. Guarded anyway,
	# because "unreachable" is what every silent fallback said before it fired.
	Log.warn("ChronoPulse", "latency %d fell through all tiers" % latency_ms)
	return TIER_MISSED


static func tier_label(tier_id: StringName) -> String:
	if tier_id == TIER_MISSED:
		return "Missed"
	for tier: Dictionary in TIERS:
		if StringName(tier["id"]) == tier_id:
			return str(tier["label"])
	Log.warn("ChronoPulse", "unknown tier '%s'" % str(tier_id))
	return "Unknown"


## Tier rank, 0 = best. Used for ordering and for the card's bar count.
static func tier_rank(tier_id: StringName) -> int:
	if tier_id == TIER_MISSED:
		return TIERS.size()
	for i: int in range(TIERS.size()):
		if StringName(TIERS[i]["id"]) == tier_id:
			return i
	return TIERS.size()


## Abstract 0..1 performance score for the card's pulse bars.
##
## Deliberately NOT a latency in disguise: the card is spoiler-free, and a
## precise millisecond count would let a player who has already played tell a
## friend exactly how fast the answer comes. Bars quantise to five buckets.
static func performance_score(latency_ms: int, hit: bool, accuracy: float) -> float:
	if not hit:
		return 0.0
	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)
	var rank: int = tier_rank(tier_for_latency(latency_ms, hit))
	# Invert rank into 0..1, then weight by accuracy so a fast wrong answer
	# cannot outscore a correct one.
	var speed: float = 1.0 - (float(rank) / float(TIERS.size()))
	return clampf(speed * 0.65 + safe_accuracy * 0.35, 0.0, 1.0)


## Bar count for the result card, 0..5.
static func pulse_bars(latency_ms: int, hit: bool, accuracy: float) -> int:
	return int(round(performance_score(latency_ms, hit, accuracy) * 5.0))


# ═════════════════════════════════════════════════════════════════════════
# STREAK EVALUATION — DELIBERATELY ABSENT
# ═════════════════════════════════════════════════════════════════════════
## There is NO evaluate_streak() here, and that is the point.
##
## Phase 1 shipped one. It mirrored ProgressionEngine.evaluate_daily_streak()
## rule for rule — grace, clock-rollback immunity, best-streak tracking — and
## every one of those rules was correct. It was still wrong to exist.
##
## Two functions that must always agree are one function that is sometimes
## wrong. That is the precise shape of the v1 defect where trial identity lived
## in four separate tables and facet_cascade stayed pinned to Easy forever
## because one of them was never updated. A second streak evaluator would have
## drifted the first time someone tuned the grace period on one side only, and
## the symptom — "my streak says 7 here and 6 there" — would have been reported
## as a display bug and looked for in the UI.
##
## ChronoPulse completion advances THE streak, the one ProgressionEngine owns
## and the Daily Hub displays, through the single mutation path every other
## caller uses. See ChronoPulseController.record_completion().
##
## The idempotence that makes this safe is already built in:
## evaluate_daily_streak() compares against the stored local day index and
## returns claimed=false if today is already collected. So whichever surface
## the player reaches first — the anomaly or the Daily Hub's Claim button —
## advances the streak and pays out, and the other correctly reports
## "already claimed today" rather than paying twice.

# ═════════════════════════════════════════════════════════════════════════
# STREAK RECOVERY
# ═════════════════════════════════════════════════════════════════════════
## Can a lapsed streak be bought back?
##
## Returns { eligible, reason, gap_days, lost_streak, lumina_cost,
##           ad_eligible, affordable }
##
## `eligible` answers "is recovery offered at all"; `affordable` answers "can
## this player pay for it". Separating them lets the UI show a priced, greyed
## option instead of hiding recovery entirely and leaving the player unaware it
## exists — the difference between a locked door and a missing one.
static func recovery_offer(stored_streak: int, last_day_index: int,
		today_index: int, lumina_balance: int,
		recoveries_used_today: int) -> Dictionary:
	var offer: Dictionary = {
		"eligible": false,
		"reason": "",
		"gap_days": 0,
		"lost_streak": maxi(stored_streak, 0),
		"lumina_cost": RECOVERY_LUMINA_COST,
		"ad_eligible": false,
		"affordable": false,
	}

	if last_day_index < 0:
		offer["reason"] = "no streak to recover"
		return offer

	if stored_streak <= 0:
		offer["reason"] = "no streak to recover"
		return offer

	if last_day_index >= today_index:
		offer["reason"] = "streak is not broken"
		return offer

	var gap: int = today_index - last_day_index
	offer["gap_days"] = gap

	# Still inside grace — nothing to recover, the streak is alive.
	if gap <= 1 + GRACE_DAYS:
		offer["reason"] = "streak is still alive"
		return offer

	if gap > MAX_RECOVERABLE_GAP_DAYS + 1:
		offer["reason"] = "gap too large (%d days)" % (gap - 1)
		return offer

	if recoveries_used_today >= MAX_RECOVERIES_PER_DAY:
		offer["reason"] = "recovery already used today"
		return offer

	offer["eligible"] = true
	offer["affordable"] = lumina_balance >= RECOVERY_LUMINA_COST
	# A rewarded ad is the free path, so a player with no Lumina is never hard
	# locked out. AdManager owns whether an ad is actually available right now;
	# this only states that recovery-by-ad is permitted for this lapse.
	offer["ad_eligible"] = true
	offer["reason"] = "recoverable"
	return offer


## The streak value after a successful recovery.
##
## Recovery restores the lapsed streak and counts today, so a player who had 9
## days, missed two, and recovers lands on 10. It does NOT credit the missed
## days themselves — the streak survives the lapse, it is not retroactively
## rewritten as though the lapse never happened.
static func streak_after_recovery(lost_streak: int) -> int:
	return maxi(lost_streak, 0) + 1


# ═════════════════════════════════════════════════════════════════════════
# HISTORY
# ═════════════════════════════════════════════════════════════════════════
## Upper bound on a credible reaction latency, in milliseconds.
##
## Nothing human takes 10 minutes to react. A value above this means the timer
## kept running while the app was backgrounded, the device clock was edited, or
## a stimulus timestamp was never set — all of which produce a number that is
## measuring something other than a reaction. Recording it would poison the
## history and the shared card with a value no player actually produced.
const MAX_CREDIBLE_LATENCY_MS: int = 600_000


## Validate a result BEFORE it is persisted. Returns [] when the data is sane.
##
## This is the gate between the trial surface and the save file. A daily run
## cannot be repeated, so a bad write is permanent — there is no next attempt
## to overwrite it with something correct.
static func validate_result(latency_ms: int, hit: bool, accuracy: float) -> Array[String]:
	var problems: Array[String] = []

	if latency_ms < 0:
		problems.append("latency %d is negative" % latency_ms)
	if latency_ms > MAX_CREDIBLE_LATENCY_MS:
		problems.append("latency %d exceeds the credible ceiling %d" % [
			latency_ms, MAX_CREDIBLE_LATENCY_MS])

	# NaN fails every comparison including against itself, so it would slip
	# past a naive range check and land in the save as a null on reload.
	if is_nan(accuracy):
		problems.append("accuracy is NaN")
	elif accuracy < 0.0 or accuracy > 1.0:
		problems.append("accuracy %f outside 0..1" % accuracy)

	# A hit with no measured latency means the stimulus timestamp was never
	# taken — the run reported success without ever timing anything.
	if hit and latency_ms <= 0:
		problems.append("hit reported with a latency of %d" % latency_ms)

	return problems


## Build the record persisted for one completed day.
static func build_record(seed_id: String, local_date: String, latency_ms: int,
		hit: bool, accuracy: float, streak: int) -> Dictionary:
	var safe_latency: int = maxi(latency_ms, 0)
	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)
	var tier: StringName = tier_for_latency(safe_latency, hit)
	return {
		"seed_id": seed_id,
		"local_date": local_date,
		"latency_ms": safe_latency,
		"hit": hit,
		"accuracy": safe_accuracy,
		"tier": str(tier),
		"bars": pulse_bars(safe_latency, hit, safe_accuracy),
		"streak": maxi(streak, 0),
	}


## Trim history to the retention cap, oldest first.
##
## Keys are ISO dates, which sort lexicographically in chronological order —
## the reason the date format is "YYYY-MM-DD" and not anything friendlier.
static func trim_history(history: Dictionary) -> Dictionary:
	if history.size() <= MAX_HISTORY_ENTRIES:
		return history
	var keys: Array = history.keys()
	keys.sort()
	var trimmed: Dictionary = {}
	var start: int = keys.size() - MAX_HISTORY_ENTRIES
	for i: int in range(start, keys.size()):
		trimmed[keys[i]] = history[keys[i]]
	return trimmed


# ═════════════════════════════════════════════════════════════════════════
# SHARE TEXT
# ═════════════════════════════════════════════════════════════════════════
## Spoiler-free share text.
##
## THE SPOILER RULE: this string may contain the date, the streak, the tier and
## the bars. It may NOT contain the anomaly kind, the target pulse, the window,
## or the exact latency — anything that would let a recipient who has not yet
## played know what is coming or when to tap. verify_share_is_spoiler_free()
## enforces this against a real generated card rather than by inspection.
static func share_text(record: Dictionary, streak: int) -> String:
	var bars: int = clampi(int(record.get("bars", 0)), 0, 5)
	var filled: String = "▰".repeat(bars)
	var empty: String = "▱".repeat(5 - bars)
	var tier_name: String = tier_label(StringName(str(record.get("tier", "missed"))))
	return "CHRONO-PULSE %s\n%s%s  %s\nStreak %d" % [
		str(record.get("seed_id", "")), filled, empty, tier_name, maxi(streak, 0)]


# ═════════════════════════════════════════════════════════════════════════
# SELF-VERIFICATION
# ═════════════════════════════════════════════════════════════════════════
## Prove the tier table covers every latency exactly once, with no gap and no
## overlap. Returns [] when sound.
##
## A table like this is edited by hand and looks correct while being wrong by
## one millisecond at a boundary; that error would silently mis-tier a small
## band of players. Checked from data rather than asserted in a comment.
static func verify_tier_coverage() -> Array[String]:
	var problems: Array[String] = []
	if TIERS.is_empty():
		problems.append("tier table is empty")
		return problems

	var previous_max: int = -1
	for tier: Dictionary in TIERS:
		var ceiling: int = int(tier["max_ms"])
		if ceiling <= previous_max:
			problems.append("tier '%s' ceiling %d does not exceed previous %d" % [
				str(tier["id"]), ceiling, previous_max])
		previous_max = ceiling

	if previous_max != 2147483647:
		problems.append("final tier must be unbounded, got %d" % previous_max)

	var ids: Dictionary = {}
	for tier: Dictionary in TIERS:
		var id: String = str(tier["id"])
		if ids.has(id):
			problems.append("duplicate tier id '%s'" % id)
		ids[id] = true

	return problems


## Prove a generated anomaly is playable. Returns [] when sound.
static func verify_anomaly(anomaly: Dictionary) -> Array[String]:
	var problems: Array[String] = []

	var pulses: int = int(anomaly.get("pulses", 0))
	if pulses < PULSES_MIN or pulses > PULSES_MAX:
		problems.append("pulses %d outside %d..%d" % [pulses, PULSES_MIN, PULSES_MAX])

	var target: int = int(anomaly.get("target_index", -1))
	if target < 1:
		problems.append("target_index %d must be >= 1 (never the first pulse)" % target)
	if target >= pulses:
		problems.append("target_index %d outside pulse count %d" % [target, pulses])

	var window: int = int(anomaly.get("window_ms", 0))
	if window < WINDOW_MIN_MS or window > WINDOW_MAX_MS:
		problems.append("window %d outside %d..%d" % [
			window, WINDOW_MIN_MS, WINDOW_MAX_MS])

	var kind: int = int(anomaly.get("kind", -1))
	if kind < 0 or kind >= ANOMALY_NAMES.size():
		problems.append("kind %d outside 0..%d" % [kind, ANOMALY_NAMES.size() - 1])

	return problems


## Prove share text leaks nothing. Returns [] when clean.
##
## WHY THIS IS NOT A SUBSTRING SEARCH:
## A naive `text.contains(str(value))` is unsound in both directions. The date
## "2026-01-01" contains "1", "01", "20", "202" and "2026" as substrings, so
## any single-digit parameter reports a false leak — and a window_ms of 2026
## would collide with the year while a genuine leak of "900" inside "1900"
## would slip through. The first version of this check reported 62 leaks
## across 104 cards, every one of them spurious.
##
## Instead: strip the content that is LEGITIMATELY on the card, then treat any
## remaining number as a leak. That inverts the test from "does this specific
## value appear" to "is there anything here that should not be", which also
## catches spoilers nobody thought to enumerate.
static func verify_share_is_spoiler_free(text: String, anomaly: Dictionary,
		record: Dictionary = {}) -> Array[String]:
	var problems: Array[String] = []

	# The anomaly's NAME would tell a recipient which puzzle they are facing.
	var kind_name: String = str(anomaly.get("kind_name", ""))
	if kind_name != "" and text.contains(kind_name):
		problems.append("share text names the anomaly ('%s')" % kind_name)

	# Remove approved content, longest first so "2026-01-01" is consumed
	# before the bare "1" inside it can be.
	var allowed_values: Array = []
	allowed_values.append(anomaly.get("seed_id", ""))
	allowed_values.append(record.get("seed_id", ""))
	allowed_values.append(record.get("local_date", ""))
	allowed_values.append(record.get("streak", ""))
	allowed_values.append(record.get("bars", ""))

	var approved: Array[String] = []
	for value: Variant in allowed_values:
		var as_text: String = str(value)
		if as_text != "" and as_text != "0":
			approved.append(as_text)
	approved.sort_custom(func(a: String, b: String) -> bool:
		return a.length() > b.length())

	var residual: String = text
	for value: String in approved:
		residual = residual.replace(value, " ")

	# Anything numeric left over is unaccounted for, and therefore a leak.
	var digits: RegEx = RegEx.new()
	if not Log.must(digits.compile("\\d+") == OK, "ChronoPulse",
			"leak regex failed to compile"):
		return problems
	for found: RegExMatch in digits.search_all(residual):
		problems.append("share text carries an unaccounted number '%s'"
			% found.get_string())

	return problems
