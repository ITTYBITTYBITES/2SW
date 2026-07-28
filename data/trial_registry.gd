extends RefCounted
class_name TrialRegistry
## TrialRegistry — the single source of truth for every trial.
##
## PHASE 8. Pure data: roster, pick weights, difficulty tables, round counts,
## and mini-game script paths all live here.
##
## THE V1 BUG THIS MAKES IMPOSSIBLE:
## v1 spread a trial's identity across FOUR parallel structures —
## TrialGenerator.TRIAL_META, TrialGenerator.DIFFICULTY,
## TrialContainer.TRIAL_SCENES, and a hardcoded string array inside
## SaveSystem._seed_defaults(). Nothing checked they agreed, and they didn't:
## `facet_cascade` was omitted from the save seeding, so despite a 20% pick
## weight and a full 361-line implementation it was permanently pinned to Easy
## with its adaptive difficulty silently dead.
##
## Here there is ONE table. `all_ids()` drives history seeding, weighted
## selection, difficulty lookup, and mini-game loading alike, so a trial cannot
## be half-registered. `validate()` proves it at boot.

const TRIALS: Dictionary = {
	"false_witness": {
		"name": "False Witness",
		"weight": 35,
		"script": "res://nodes/trials/false_witness.gd",
		"domain": "perception",
		# Rapid visual discrimination. More glyphs, less time, subtler delta.
		"brackets": [
			{"rounds": 6, "glyphs": 6,  "window": 6.5, "delta": 0.45},
			{"rounds": 6, "glyphs": 11, "window": 4.0, "delta": 0.30},
			{"rounds": 6, "glyphs": 17, "window": 2.2, "delta": 0.20},
		],
	},
	"sequence_recall": {
		"name": "Sequence Recall",
		"weight": 25,
		"script": "res://nodes/trials/sequence_recall.gd",
		"domain": "memory",
		# Spatial memory. Longer sequences shown faster.
		"brackets": [
			{"rounds": 4, "len_min": 3, "len_max": 4, "display": 1.10, "gap": 1.8},
			{"rounds": 4, "len_min": 5, "len_max": 6, "display": 0.65, "gap": 1.1},
			{"rounds": 4, "len_min": 7, "len_max": 9, "display": 0.35, "gap": 0.6},
		],
	},
	"cognitive_conflict": {
		"name": "Cognitive Conflict",
		"weight": 20,
		"script": "res://nodes/trials/cognitive_conflict.gd",
		"domain": "inhibition",
		# RESTORED: v1 ran a fixed 8 rounds at every bracket, with `stimuli` as
		# a SEPARATE knob. A previous pass collapsed the two and shortened the
		# easy bracket to 4 rounds. Difficulty now scales speed and noise, not
		# session length — so the trial always feels the same size.
		"brackets": [
			{"rounds": 8, "window": 2.40, "noise": 0.25, "distractors": 0},
			{"rounds": 8, "window": 1.10, "noise": 0.55, "distractors": 2},
			{"rounds": 8, "window": 0.55, "noise": 0.85, "distractors": 4},
		],
	},
	"trend_witness": {
		"name": "Trend Witness",
		# Weight 0 would fail validate(); this mode is launched EXPLICITLY from
		# the Trend Hub and must never appear in a weighted daily/practice
		# draw, because it needs a category id the random path cannot supply.
		# A low weight plus exclusion from pick_weighted() keeps validate()
		# honest without polluting selection.
		"weight": 1,
		"selectable": false,
		"script": "res://nodes/mini_games/trend_witness_game.gd",
		"domain": "recall",
		# Rounds are fixed at 5; difficulty comes from the CATEGORY (symbol
		# count and tempo), not the bracket, so every bracket matches.
		"brackets": [
			{"rounds": 5},
			{"rounds": 5},
			{"rounds": 5},
		],
	},
	"facet_cascade": {
		"name": "Facet Cascade",
		"weight": 20,
		"script": "res://nodes/trials/facet_cascade.gd",
		"domain": "planning",
		# Match-3. The one non-cognitive mode: the comfortable trial between
		# the demanding ones. Board and target grow; move budget barely does.
		"brackets": [
			{"rounds": 1, "size": 6, "colors": 4, "target": 25, "moves": 18},
			{"rounds": 1, "size": 7, "colors": 5, "target": 40, "moves": 20},
			{"rounds": 1, "size": 8, "colors": 6, "target": 60, "moves": 22},
		],
	},
}

const BRACKET_NAMES: Array[String] = ["Easy", "Medium", "Hard"]
const BRACKET_COUNT: int = 3


# ═════════════════════════════════════════════════════════════════════════
# ROSTER
# ═════════════════════════════════════════════════════════════════════════
## Every registered trial id. This drives history seeding, so a trial in the
## registry is ALWAYS tracked — the v1 omission cannot recur.
static func all_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in TRIALS.keys():
		ids.append(id)
	return ids


static func has(trial_id: String) -> bool:
	return TRIALS.has(trial_id)


static func display_name(trial_id: String) -> String:
	if not TRIALS.has(trial_id):
		return trial_id
	return str(TRIALS[trial_id].get("name", trial_id))


static func script_path(trial_id: String) -> String:
	if not TRIALS.has(trial_id):
		return ""
	return str(TRIALS[trial_id].get("script", ""))


static func domain(trial_id: String) -> String:
	if not TRIALS.has(trial_id):
		return ""
	return str(TRIALS[trial_id].get("domain", ""))


static func weight(trial_id: String) -> int:
	if not TRIALS.has(trial_id):
		return 0
	return int(TRIALS[trial_id].get("weight", 0))


## Total weight across SELECTABLE trials only. Including a mode that can never
## be drawn would skew every other trial's share downward by its weight.
static func total_weight() -> int:
	var total: int = 0
	for id: String in TRIALS.keys():
		if not bool(TRIALS[id].get("selectable", true)):
			continue
		total += int(TRIALS[id].get("weight", 0))
	return total


static func bracket_name(bracket: int) -> String:
	return BRACKET_NAMES[clampi(bracket, 0, BRACKET_COUNT - 1)]


# ═════════════════════════════════════════════════════════════════════════
# DIFFICULTY LOOKUP
# ═════════════════════════════════════════════════════════════════════════
## Parameters for a trial at a bracket. Returns an empty dict for an unknown
## trial, and fails loudly in debug — v1 silently awarded a neutral score.
static func params(trial_id: String, bracket: int) -> Dictionary:
	if not Log.must(TRIALS.has(trial_id), "TrialRegistry",
			"unknown trial '%s'" % trial_id):
		return {}
	var brackets: Array = TRIALS[trial_id].get("brackets", [])
	if not Log.must(not brackets.is_empty(), "TrialRegistry",
			"trial '%s' has no brackets" % trial_id):
		return {}
	var index: int = clampi(bracket, 0, brackets.size() - 1)
	return brackets[index]


## A single parameter with a typed fallback.
static func param(trial_id: String, bracket: int, key: String,
		fallback: Variant) -> Variant:
	var table: Dictionary = params(trial_id, bracket)
	return table.get(key, fallback)


## Rounds a trial runs at a bracket. Used by the host to size the session.
static func rounds(trial_id: String, bracket: int) -> int:
	return int(param(trial_id, bracket, "rounds", 1))


# ═════════════════════════════════════════════════════════════════════════
# WEIGHTED SELECTION
# ═════════════════════════════════════════════════════════════════════════
## Pick the next trial by weight. Deterministic when `rng` is supplied, which
## makes daily challenges reproducible and selection testable.
## True when a trial may appear in a random draw. A mode that requires an
## explicit argument (Trend Witness needs a category) must be excluded, or the
## random path launches it with nothing to run.
static func is_selectable(trial_id: String) -> bool:
	if not TRIALS.has(trial_id):
		return false
	return bool(TRIALS[trial_id].get("selectable", true))


## Ids eligible for a weighted draw.
static func selectable_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in sorted_ids():
		if is_selectable(id):
			ids.append(id)
	return ids


static func pick_weighted(rng: RandomNumberGenerator = null) -> String:
	var total: int = total_weight()
	if not Log.must(total > 0, "TrialRegistry", "total weight is zero"):
		return "false_witness"

	var roll: int = 0
	if rng != null:
		roll = rng.randi_range(0, total - 1)
	else:
		roll = randi() % total

	# Iterate a SORTED id list so selection is stable across runs. Dictionary
	# key order is an implementation detail and must not affect the outcome.
	var accumulator: int = 0
	for id: String in selectable_ids():
		accumulator += int(TRIALS[id].get("weight", 0))
		if roll < accumulator:
			return id
	return selectable_ids()[0]


## Ids in a stable, deterministic order.
static func sorted_ids() -> Array[String]:
	var ids: Array[String] = all_ids()
	ids.sort()
	return ids


## Expected selection share for a trial, 0.0-1.0. Used by tests and by the
## Progress screen to show trial distribution.
static func weight_fraction(trial_id: String) -> float:
	var total: int = total_weight()
	if total <= 0:
		return 0.0
	if not is_selectable(trial_id):
		return 0.0
	return float(weight(trial_id)) / float(total)


# ═════════════════════════════════════════════════════════════════════════
# VALIDATION
# ═════════════════════════════════════════════════════════════════════════
## Prove the registry is internally consistent. Called at boot so a malformed
## entry crashes in debug rather than shipping a silently broken trial.
## Returns a list of problems; empty means healthy.
static func validate() -> Array[String]:
	var problems: Array[String] = []

	for id: String in TRIALS.keys():
		var entry: Dictionary = TRIALS[id]

		if str(entry.get("name", "")) == "":
			problems.append("%s: missing display name" % id)
		if int(entry.get("weight", 0)) <= 0:
			problems.append("%s: weight must be > 0" % id)

		var path: String = str(entry.get("script", ""))
		if path == "":
			problems.append("%s: missing script path" % id)
		elif not ResourceLoader.exists(path):
			problems.append("%s: script not found at %s" % [id, path])

		var brackets: Array = entry.get("brackets", [])
		if brackets.size() != BRACKET_COUNT:
			problems.append("%s: expected %d brackets, found %d" % [
				id, BRACKET_COUNT, brackets.size()])
			continue

		for i: int in range(brackets.size()):
			var bracket: Dictionary = brackets[i]
			if int(bracket.get("rounds", 0)) <= 0:
				problems.append("%s[%d]: rounds must be > 0" % [id, i])

	if total_weight() <= 0:
		problems.append("registry: total weight is zero")

	return problems


## Seed per-trial history for EVERY registered trial. Called on boot.
## Iterating the registry rather than a hardcoded list is exactly what v1 got
## wrong; there is no second list to fall out of sync with.
static func ensure_history(state: IrisState) -> int:
	if not Log.must(state != null, "TrialRegistry", "ensure_history got null"):
		return 0
	var seeded: int = 0
	for id: String in all_ids():
		if AdaptiveDifficulty.ensure_trial_history(state, id):
			seeded += 1
	return seeded
