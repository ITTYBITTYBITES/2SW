extends RefCounted
class_name DialogueManifest
## DialogueManifest — the Iris's voice, as structured text.
##
## PHASE 8. Pure data plus a shuffle-bag selector. No audio, no nodes; the
## AudioManager decides how a chosen line is voiced.
##
## THE REPETITION PROBLEM:
## v1 had three voice clips ("welcome", "evolve", "resonance") and played
## "welcome" on BOTH the Loading screen and Console entry — so a player heard
## the same line twice within four seconds of launching. Nothing worse for an
## ostensibly living companion.
##
## THE FIX — shuffle bags, not random picks:
## Naive `pick_random()` repeats roughly 1-in-N times, and back-to-back repeats
## are exactly what players notice. A shuffle bag draws without replacement
## until the pool empties, then reshuffles — guaranteeing every line is heard
## once before any repeats, and (with the carry rule below) never twice in a row.
##
## Each context has 6+ variants. Lines are short, second-person, and never
## reference specifics the game might contradict.

# ═════════════════════════════════════════════════════════════════════════
# CONTEXTS
# ═════════════════════════════════════════════════════════════════════════
const HUB_GREET: StringName = &"hub_greet"
const TRIAL_START: StringName = &"trial_start"
const IN_TRIAL_FEEDBACK_GOOD: StringName = &"in_trial_good"
const IN_TRIAL_FEEDBACK_MISS: StringName = &"in_trial_miss"
const TRIAL_COMPLETE_HIGH: StringName = &"trial_complete_high"
const TRIAL_COMPLETE_MID: StringName = &"trial_complete_mid"
const TRIAL_COMPLETE_LOW: StringName = &"trial_complete_low"
const STREAK_MILESTONE: StringName = &"streak_milestone"
const RETURN_AFTER_ABSENCE: StringName = &"return_after_absence"

## Accuracy thresholds that route a completion to a tone.
## Where tools/generate_voice_lines.py writes the rendered clips. Clip names
## are `<context slug>_<1-based index>.ogg`, derived from this table, so the
## audio cannot drift from the text without the generator's --check failing.
const CLIP_DIR: String = "res://audio/dialogue"

const HIGH_ACCURACY: float = 0.85
const MID_ACCURACY: float = 0.55

const LINES: Dictionary = {
	HUB_GREET: [
		"You returned.",
		"I have been watching.",
		"The light finds you again.",
		"Something stirs when you are near.",
		"I kept your place.",
		"Awake. Both of us.",
		"You are expected.",
	],
	TRIAL_START: [
		"Show me what you see.",
		"Attend closely.",
		"Let nothing slip past.",
		"Your focus, now.",
		"Begin. I am watching.",
		"Sharpen yourself.",
		"Hold your attention steady.",
	],
	IN_TRIAL_FEEDBACK_GOOD: [
		"Yes.",
		"Clear sight.",
		"You saw it.",
		"Precisely so.",
		"Good.",
		"That is the one.",
	],
	IN_TRIAL_FEEDBACK_MISS: [
		"It slipped.",
		"Not that one.",
		"Look again.",
		"Missed.",
		"Steady yourself.",
		"Let it go. Continue.",
	],
	TRIAL_COMPLETE_HIGH: [
		"The Iris resonates.",
		"You see clearly now.",
		"Remarkable focus.",
		"Nothing escaped you.",
		"This is what clarity feels like.",
		"You have grown sharper.",
	],
	TRIAL_COMPLETE_MID: [
		"The Iris sharpens.",
		"Progress, steadily.",
		"Better than before.",
		"You are learning to look.",
		"Something is forming.",
		"Keep this pace.",
	],
	TRIAL_COMPLETE_LOW: [
		"The Iris stabilizes.",
		"Difficult sight today.",
		"We begin again.",
		"Even this teaches.",
		"Rest your eyes. Return.",
		"No sight is wasted.",
	],
	STREAK_MILESTONE: [
		"You have not faltered.",
		"Devotion leaves a mark.",
		"Day after day, you return.",
		"This constancy changes you.",
		"I have counted every one.",
		"Something is earned here.",
	],
	RETURN_AFTER_ABSENCE: [
		"You were gone a while.",
		"I waited.",
		"The light dimmed without you.",
		"Time passed. You returned.",
		"I wondered if you would.",
		"Welcome back.",
	],
}

## Minimum variants per context. Enforced by validate() so a future edit
## cannot quietly shrink a pool back into repetition.
const MIN_VARIANTS: int = 6

# ── Shuffle bag state ────────────────────────────────────────────────────
## context -> remaining indices for the current cycle.
static var _bags: Dictionary = {}
## context -> the last index issued, so a reshuffle cannot repeat it.
static var _last_issued: Dictionary = {}
static var _rng: RandomNumberGenerator = null


static func _ensure_rng() -> void:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()


## Deterministic mode for tests.
static func set_seed(value: int) -> void:
	_ensure_rng()
	_rng.seed = value


# ═════════════════════════════════════════════════════════════════════════
# SELECTION
# ═════════════════════════════════════════════════════════════════════════
## Draw the next line for a context, without replacement.
##
## When the bag empties it is refilled and reshuffled, with one extra rule:
## if the refilled bag would hand back the line just spoken, that line is
## swapped deeper into the bag. Without this, a cycle boundary can produce a
## back-to-back repeat — the single most noticeable failure mode.
static func next_line(context: StringName) -> String:
	if not Log.must(LINES.has(context), "Dialogue", "unknown context '%s'" % context):
		return ""
	_ensure_rng()

	var pool: Array = LINES[context]
	if pool.is_empty():
		return ""

	var bag: Array = _bags.get(context, [])
	if bag.is_empty():
		bag = _refill_bag(context, pool.size())

	var index: int = int(bag.pop_back())
	_bags[context] = bag
	_last_issued[context] = index
	return str(pool[index])


## Path to the pre-rendered clip for the line most recently issued by
## next_line(), or "" if that context has never been drawn from.
##
## THE INDEX IS THE LINK. The shuffle bag already records WHICH line it chose,
## and tools/generate_voice_lines.py names every clip from the same
## slug + 1-based index. So the text and its audio are bound by construction —
## there is no second lookup table to fall out of sync, and reordering the
## LINES array moves the text and the clip together.
##
## Callers must handle "" rather than assume a clip exists: a line added
## without regenerating the pack has text but no audio, and going quiet is the
## right response to that, not a crash.
static func clip_path(context: StringName) -> String:
	if not _last_issued.has(context):
		return ""
	var index: int = int(_last_issued[context])
	return "%s/%s_%02d.ogg" % [CLIP_DIR, context, index + 1]


## Every clip path this manifest expects to exist, in context order. The audit
## uses it to prove the generated pack covers the authored script exactly.
static func all_clip_paths() -> Array[String]:
	var out: Array[String] = []
	for context: StringName in LINES:
		var pool: Array = LINES[context]
		for i: int in range(pool.size()):
			out.append("%s/%s_%02d.ogg" % [CLIP_DIR, context, i + 1])
	return out


## Build a shuffled index bag, guarding the cycle boundary.
static func _refill_bag(context: StringName, size: int) -> Array:
	var indices: Array = []
	for i: int in range(size):
		indices.append(i)

	# Fisher-Yates.
	for i: int in range(indices.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var temp: Variant = indices[i]
		indices[i] = indices[j]
		indices[j] = temp

	# Bags are drawn from the BACK, so the last element is issued first.
	# If that repeats the previous line, swap it toward the front.
	if _last_issued.has(context) and indices.size() > 1:
		var previous: int = int(_last_issued[context])
		if int(indices[indices.size() - 1]) == previous:
			var temp: Variant = indices[indices.size() - 1]
			indices[indices.size() - 1] = indices[0]
			indices[0] = temp

	return indices


## Reset every bag. Used on a fresh session so the first line of a run isn't
## constrained by the previous one.
static func reset_bags() -> void:
	_bags.clear()
	_last_issued.clear()


# ═════════════════════════════════════════════════════════════════════════
# CONTEXT RESOLUTION
# ═════════════════════════════════════════════════════════════════════════
## Map a trial result to the right completion tone.
static func completion_context(accuracy: float) -> StringName:
	if accuracy >= HIGH_ACCURACY:
		return TRIAL_COMPLETE_HIGH
	if accuracy >= MID_ACCURACY:
		return TRIAL_COMPLETE_MID
	return TRIAL_COMPLETE_LOW


## Choose the right greeting for an arrival, given days away and streak state.
## Absence takes priority: acknowledging a long gap matters more than a
## milestone the player may have forgotten they were chasing.
static func greeting_context(days_absent: int, is_milestone: bool) -> StringName:
	if days_absent >= 2:
		return RETURN_AFTER_ABSENCE
	if is_milestone:
		return STREAK_MILESTONE
	return HUB_GREET


## In-trial feedback tone.
static func feedback_context(is_correct: bool) -> StringName:
	return IN_TRIAL_FEEDBACK_GOOD if is_correct else IN_TRIAL_FEEDBACK_MISS


# ═════════════════════════════════════════════════════════════════════════
# INTROSPECTION & VALIDATION
# ═════════════════════════════════════════════════════════════════════════
static func all_contexts() -> Array[StringName]:
	var out: Array[StringName] = []
	for key: StringName in LINES.keys():
		out.append(key)
	return out


static func variant_count(context: StringName) -> int:
	if not LINES.has(context):
		return 0
	return (LINES[context] as Array).size()


## Prove the manifest is healthy. Empty result means no problems.
static func validate() -> Array[String]:
	var problems: Array[String] = []
	for context: StringName in LINES.keys():
		var pool: Array = LINES[context]
		if pool.size() < MIN_VARIANTS:
			problems.append("%s: %d variants, minimum is %d" % [
				context, pool.size(), MIN_VARIANTS])
		var seen: Dictionary = {}
		for line: Variant in pool:
			var text: String = str(line)
			if text.strip_edges() == "":
				problems.append("%s: contains an empty line" % context)
			if seen.has(text):
				problems.append("%s: duplicate line '%s'" % [context, text])
			seen[text] = true
	return problems
