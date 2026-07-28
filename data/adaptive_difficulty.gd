extends RefCounted
class_name AdaptiveDifficulty
## AdaptiveDifficulty — per-trial bracket tuning from rolling performance.
##
## PHASE 8. This is the difficulty CURVE, and it was entirely absent from v2
## until now: brackets were handed out at launch and never moved, so a player
## sat at whatever difficulty they started with forever.
##
## RULES (restored from v1 IrisProgression):
##   DEMOTE  when the last 3 scores are ALL below 63%
##   PROMOTE when the last 5 scores are ALL above 87%
##
## Both windows read the tail of a rolling log capped at 10 entries.
##
## WHY IT IS INVISIBLE: the player is never told their bracket changed. The
## game simply stays near the edge of their ability. Announcing a demotion
## reads as punishment; announcing a promotion invites sandbagging.
##
## HISTORY LIVES IN IrisState under a single "trial_history" dictionary keyed
## by trial id, seeded from TrialRegistry.all_ids(). v1 kept a hardcoded list
## in SaveSystem that omitted facet_cascade, silently disabling adaptation for
## 20% of trials. There is no second list here.

const HISTORY_LENGTH: int = 10

const DEMOTE_STREAK: int = 3
const DEMOTE_THRESHOLD: float = 0.63
const PROMOTE_STREAK: int = 5
const PROMOTE_THRESHOLD: float = 0.87

const MIN_BRACKET: int = 0
const MAX_BRACKET: int = 2

## Shift outcomes, for callers that want to react (telemetry, tests).
enum Shift { NONE = 0, PROMOTED = 1, DEMOTED = 2 }


# ═════════════════════════════════════════════════════════════════════════
# HISTORY STORAGE
# ═════════════════════════════════════════════════════════════════════════
## Guarantee a history entry exists. Returns true if one was created.
static func ensure_trial_history(state: IrisState, trial_id: String) -> bool:
	if not Log.must(state != null, "Adaptive", "ensure_trial_history got null"):
		return false
	var history: Dictionary = state.trial_history
	if history.has(trial_id):
		return false
	history[trial_id] = {
		"scores": [], "bracket": MIN_BRACKET, "plays": 0,
		"best": 0.0, "last_shift": Shift.NONE, "seconds": 0.0,
	}
	return true


## The record for a trial, creating it on demand so a caller can never read a
## missing key. This is why facet_cascade cannot be forgotten again.
static func record_for(state: IrisState, trial_id: String) -> Dictionary:
	ensure_trial_history(state, trial_id)
	return state.trial_history.get(trial_id, {})


static func current_bracket(state: IrisState, trial_id: String) -> int:
	var record: Dictionary = record_for(state, trial_id)
	return clampi(int(record.get("bracket", MIN_BRACKET)), MIN_BRACKET, MAX_BRACKET)


static func set_bracket(state: IrisState, trial_id: String, bracket: int) -> void:
	var record: Dictionary = record_for(state, trial_id)
	record["bracket"] = clampi(bracket, MIN_BRACKET, MAX_BRACKET)


## The rolling score log, oldest first.
static func scores(state: IrisState, trial_id: String) -> Array:
	var record: Dictionary = record_for(state, trial_id)
	return record.get("scores", [])


static func play_count(state: IrisState, trial_id: String) -> int:
	return int(record_for(state, trial_id).get("plays", 0))


static func best_accuracy(state: IrisState, trial_id: String) -> float:
	return float(record_for(state, trial_id).get("best", 0.0))


# ═════════════════════════════════════════════════════════════════════════
# RECORDING & EVALUATION
# ═════════════════════════════════════════════════════════════════════════
## Log one completed attempt and evaluate a bracket shift.
##
## Returns:
##   { bracket_before, bracket_after, shift, scores_logged, plays }
##
## Call once per settled trial. Idempotency is the caller's responsibility —
## TrialController's `_settled` guard already ensures a single call per run.
static func record_attempt(state: IrisState, trial_id: String,
		accuracy: float) -> Dictionary:
	var result: Dictionary = {
		"bracket_before": MIN_BRACKET, "bracket_after": MIN_BRACKET,
		"shift": Shift.NONE, "scores_logged": 0, "plays": 0,
	}
	if not Log.must(state != null, "Adaptive", "record_attempt got null state"):
		return result
	if not Log.must(TrialRegistry.has(trial_id), "Adaptive",
			"unregistered trial '%s'" % trial_id):
		return result

	var record: Dictionary = record_for(state, trial_id)
	var before: int = clampi(int(record.get("bracket", MIN_BRACKET)),
		MIN_BRACKET, MAX_BRACKET)

	var safe_accuracy: float = clampf(accuracy, 0.0, 1.0)

	var history: Array = record.get("scores", [])
	history.append(safe_accuracy)
	# Keep only the most recent HISTORY_LENGTH entries.
	while history.size() > HISTORY_LENGTH:
		history.remove_at(0)
	record["scores"] = history

	record["plays"] = int(record.get("plays", 0)) + 1
	record["best"] = maxf(float(record.get("best", 0.0)), safe_accuracy)

	var after: int = evaluate_bracket(history, before)
	record["bracket"] = after

	# A shift resets the window. Without this, the same tail keeps satisfying
	# the rule and the player is promoted again on the very next play — from
	# Easy to Hard in two trials, which reads as the game breaking.
	if after != before:
		record["scores"] = []

	result["bracket_before"] = before
	result["bracket_after"] = after
	result["scores_logged"] = int(record["scores"].size())
	result["plays"] = int(record["plays"])
	if after > before:
		result["shift"] = Shift.PROMOTED
	elif after < before:
		result["shift"] = Shift.DEMOTED

	# Remember the most recent shift so the Progress view can show a trend
	# even on a play that did not itself move the bracket.
	if int(result["shift"]) != int(Shift.NONE):
		record["last_shift"] = int(result["shift"])
	return result


## Record elapsed time for the average-completion stat.
static func record_duration(state: IrisState, trial_id: String,
		seconds: float) -> void:
	if not Log.must(state != null, "Adaptive", "record_duration got null"):
		return
	var record: Dictionary = record_for(state, trial_id)
	record["seconds"] = float(record.get("seconds", 0.0)) + maxf(seconds, 0.0)


## Mean completion time for a trial, or 0.0 with no plays.
static func average_seconds(state: IrisState, trial_id: String) -> float:
	var record: Dictionary = record_for(state, trial_id)
	var plays: int = int(record.get("plays", 0))
	if plays <= 0:
		return 0.0
	return float(record.get("seconds", 0.0)) / float(plays)


## The most recent bracket movement, for a trend indicator.
static func last_shift(state: IrisState, trial_id: String) -> Shift:
	var raw: int = int(record_for(state, trial_id).get("last_shift", Shift.NONE))
	return raw as Shift


## How many more qualifying results are needed to move a bracket, and which
## way the player is heading. Lets the UI say "2 more strong runs" rather than
## leaving adaptation entirely opaque.
static func progress_hint(state: IrisState, trial_id: String) -> Dictionary:
	var history: Array = scores(state, trial_id)
	var toward_promote: int = 0
	var toward_demote: int = 0

	for i: int in range(history.size() - 1, -1, -1):
		if float(history[i]) > PROMOTE_THRESHOLD:
			toward_promote += 1
		else:
			break
	for i: int in range(history.size() - 1, -1, -1):
		if float(history[i]) < DEMOTE_THRESHOLD:
			toward_demote += 1
		else:
			break

	return {
		"to_promote": maxi(PROMOTE_STREAK - toward_promote, 0),
		"to_demote": maxi(DEMOTE_STREAK - toward_demote, 0),
		"promote_run": toward_promote,
		"demote_run": toward_demote,
	}


## Pure bracket evaluation over a score log. No state, no side effects, so
## every threshold case can be tested in isolation.
##
## Demotion is checked FIRST: a struggling player should be helped immediately,
## and the two conditions are mutually exclusive anyway (a tail cannot be both
## entirely below 0.63 and entirely above 0.87).
static func evaluate_bracket(score_log: Array, current: int) -> int:
	var bracket: int = clampi(current, MIN_BRACKET, MAX_BRACKET)

	if _tail_all_below(score_log, DEMOTE_STREAK, DEMOTE_THRESHOLD):
		return maxi(bracket - 1, MIN_BRACKET)

	if _tail_all_above(score_log, PROMOTE_STREAK, PROMOTE_THRESHOLD):
		return mini(bracket + 1, MAX_BRACKET)

	return bracket


## True when the last `count` entries are all strictly below `threshold`.
## Returns false if there aren't enough entries yet — a new player is never
## demoted on their first two plays.
static func _tail_all_below(score_log: Array, count: int, threshold: float) -> bool:
	if score_log.size() < count:
		return false
	for i: int in range(score_log.size() - count, score_log.size()):
		if float(score_log[i]) >= threshold:
			return false
	return true


## True when the last `count` entries are all strictly above `threshold`.
static func _tail_all_above(score_log: Array, count: int, threshold: float) -> bool:
	if score_log.size() < count:
		return false
	for i: int in range(score_log.size() - count, score_log.size()):
		if float(score_log[i]) <= threshold:
			return false
	return true


# ═════════════════════════════════════════════════════════════════════════
# REPORTING
# ═════════════════════════════════════════════════════════════════════════
## Mean of the logged scores, or 0.0 when empty. For the Progress screen.
static func rolling_average(state: IrisState, trial_id: String) -> float:
	var history: Array = scores(state, trial_id)
	if history.is_empty():
		return 0.0
	var total: float = 0.0
	for value: Variant in history:
		total += float(value)
	return total / float(history.size())


## Snapshot of every trial, for the Progress screen. Always covers the full
## roster, including trials never played.
static func summary(state: IrisState) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for trial_id: String in TrialRegistry.sorted_ids():
		rows.append({
			"id": trial_id,
			"name": TrialRegistry.display_name(trial_id),
			"bracket": current_bracket(state, trial_id),
			"bracket_name": TrialRegistry.bracket_name(current_bracket(state, trial_id)),
			"plays": play_count(state, trial_id),
			"best": best_accuracy(state, trial_id),
			"average": rolling_average(state, trial_id),
			"avg_seconds": average_seconds(state, trial_id),
			"last_shift": int(last_shift(state, trial_id)),
			"hint": progress_hint(state, trial_id),
		})
	return rows


## Wipe adaptation for one trial. Debug/QA only.
static func reset_trial(state: IrisState, trial_id: String) -> void:
	if not Log.must(state != null, "Adaptive", "reset_trial got null state"):
		return
	state.trial_history[trial_id] = {
		"scores": [], "bracket": MIN_BRACKET, "plays": 0,
		"best": 0.0, "last_shift": Shift.NONE, "seconds": 0.0,
	}
