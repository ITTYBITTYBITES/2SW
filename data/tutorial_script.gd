extends RefCounted
class_name TutorialScript

## TutorialScript — what a first-time player is told, per trial mode.
##
## PURE DATA. No node, no scene, no draw call. A screen asks for the lines and
## gets strings; presentation is entirely the overlay's business.
##
## WHY THIS EXISTS
## The trial screen dropped a first-time player straight into a 2.5-second
## timed round with no explanation of the objective, what to look for, or that
## tapping was even the interaction. Reported directly: the game "is not
## functional" — it was, but nothing on screen said what to do, which amounts
## to the same thing for a new player.
##
## SEEN-STATE LIVES IN Save UNDER meta.tutorials_seen, which the save schema
## has carried since v1 and nothing has ever written to. Keyed by trial id, so
## a player who learns false_witness is still taught sequence_recall.
##
## ONE SCREEN, THREE LINES, NEVER AGAIN. A tutorial that spans pages is a
## tutorial people dismiss without reading.

## Lines per trial id. Each entry is {objective, observe, act}.
##
## The three keys are deliberate and always in this order, because it is the
## order a player needs them: what am I doing, what am I looking at, what do I
## physically do.
const SCRIPTS: Dictionary = {
	"false_witness": {
		"title": "False Witness",
		"objective": "One glyph is not like the others.",
		"observe": "Every glyph shares the same rings, size and glow — except one.",
		"act": "Tap the odd one before the ring of light runs out.",
	},
	"sequence_recall": {
		"title": "Sequence Recall",
		"objective": "Watch the order, then repeat it.",
		"observe": "Glyphs light one at a time. The order is the answer.",
		"act": "Tap them back in the same order.",
	},
	"cognitive_conflict": {
		"title": "Cognitive Conflict",
		"objective": "Trust the colour, not the word.",
		"observe": "The word names one colour and is painted in another.",
		"act": "Tap the swatch matching the INK, not the word.",
	},
	"facet_cascade": {
		"title": "Facet Cascade",
		"objective": "Clear facets by matching three or more.",
		"observe": "Adjacent facets of the same colour can be collapsed.",
		"act": "Tap a group to collapse it before your moves run out.",
	},
	"trend_witness": {
		"title": "Trend Witness",
		"objective": "Spot the symbol that breaks the pattern.",
		"observe": "The set follows one rule. One member does not.",
		"act": "Tap the outlier before the window closes.",
	},
}

## Shown when a trial has no authored script. Deliberately generic rather than
## absent: a missing entry must not mean a first-time player gets nothing.
const FALLBACK: Dictionary = {
	"title": "Trial",
	"objective": "Find what does not belong.",
	"observe": "Study the field before you commit.",
	"act": "Tap your answer before time runs out.",
}


## The script for a trial id. Never returns empty.
static func for_trial(trial_id: String) -> Dictionary:
	var entry: Variant = SCRIPTS.get(trial_id, null)
	if entry is Dictionary:
		return entry as Dictionary
	Log.d("Tutorial", "no script for '%s'; using the fallback" % trial_id)
	return FALLBACK


## Has this player already been taught this mode?
static func is_seen(trial_id: String) -> bool:
	var seen: Array = Save.get_v(Save.SEC_META, "tutorials_seen", [])
	return trial_id in seen


## Record that the tutorial was shown, so it never appears again.
##
## Idempotent and self-flushing: a player who force-quits immediately after
## dismissing it must not be taught the same thing twice.
static func mark_seen(trial_id: String) -> void:
	if trial_id == "":
		Log.warn("Tutorial", "mark_seen got an empty trial id")
		return
	var seen: Array = Save.get_v(Save.SEC_META, "tutorials_seen", [])
	if trial_id in seen:
		return
	seen.append(trial_id)
	Save.set_v(Save.SEC_META, "tutorials_seen", seen)
	Save.flush()
	Log.info("Tutorial", "'%s' taught" % trial_id)


## Every id that has an authored script. Used by the audit to prove the table
## covers the registry rather than trusting it does.
static func covered_trials() -> Array[String]:
	var out: Array[String] = []
	for key: String in SCRIPTS.keys():
		out.append(key)
	out.sort()
	return out
