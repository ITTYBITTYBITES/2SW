extends RefCounted
class_name TrendRegistry
## TrendRegistry — the single roster of Trend Hub categories.
##
## PHASE 1. Pure data: category ids, display names, unlock model, and the
## procedural theming each one drives. Same shape as TrialRegistry, and for the
## same reason — v1 spread a mode's identity across four parallel tables and
## `facet_cascade` fell out of one of them, silently pinning 20% of trials to
## Easy forever. One table, `all_ids()` drives everything, `validate()` proves
## it at boot.
##
## ═══════════════════════════════════════════════════════════════════════════
## UNLOCKS REUSE THE RENTAL ENGINE — THERE IS NO SECOND EXPIRY SYSTEM
## ═══════════════════════════════════════════════════════════════════════════
## A category id IS an IrisState rental pack id. Unlock state is read through
## is_rental_active() / rental_days_remaining() / get_pack_expires_utc(), and
## granted through grant_rental(), which already applies RENTAL_DURATION_SEC
## (7 days), already persists through to_dict()/from_dict(), and is already
## pruned on entry by prune_expired_rentals().
##
## Storing an `unlock_expires_utc` here as well would be two implementations of
## one fact. That is the defect I removed in ChronoPulse Phase 2 (a duplicate
## streak evaluator) and the defect v1 shipped four times over. The rental
## engine is the owner; this file only names the packs.
##
## ═══════════════════════════════════════════════════════════════════════════
## CONTENT IS PROCEDURAL, NOT AUTHORED
## ═══════════════════════════════════════════════════════════════════════════
## The project rule is 100% procedural, zero assets. A trivia bank would mean
## shipping authored text about real games and media — a content pipeline that
## does not exist, factual claims nobody has verified, and third-party IP in a
## Play submission.
##
## So a category is a THEME, not a question bank: it selects a palette family
## and a glyph alphabet for the same procedural witness task. The player is
## still tested on perception and recall under time pressure; the category
## changes how the run looks and reads, not what is true. Nothing here asserts
## a fact about the real world.

## The weekly roster. TWENTY categories, FIVE of them free.
##
## Ids are PERMANENT. A category id is an IrisState rental pack id and a save
## key for best scores, so renaming one orphans every pass a player has paid an
## ad for and every score they have set. The first three ids predate this
## expansion and are deliberately unchanged.
##
## Fields:
##   free     — playable without a pass, forever. Exactly FREE_CATEGORY_COUNT
##              of these; validate() enforces it.
##   order    — display position. Unique, so the list never depends on
##              Dictionary iteration order.
##   symbols  — glyph alphabet size. Drives the fair reading window, so a
##              denser channel gets MORE time, not less.
##   palette  — family index into Palette.FACET_COLORS, wrapped on read.
##   tempo    — multiplies the fair window. Below 1.0 is tighter.
##
## Difficulty rises with `order`: the free five sit at 6-8 symbols, the paid
## fifteen climb to 15. That ordering is asserted in validate() so a future
## edit cannot accidentally make a free channel harder than a paid one.
## Weekly target capacity.
const TARGET_CATEGORY_COUNT: int = 20
## Featured free categories, refreshed weekly by editing `free` above.
const FREE_CATEGORY_COUNT: int = 5

## Editorial popularity prior, 0-100. Mirrors EVERGREEN_POPULARITY in
## tools/trend_content_pipeline so the bundled fallback ranks the same way a
## downloaded roster does — a player who is offline must not see a different
## "popular" list from one who is not.
##
## This is a PRIOR, not a measurement. Real engagement is counted per device
## by run_count() and weighted against this in TrendLoader.

const TRENDS: Dictionary = {
	"trend_internet_lore": {
		"name": "Internet Lore",
		"blurb": "Featured this week. Free to play.",
		"free": true,
		"order": 0,
		"symbols": 6,
		"palette": 0,
		"popularity_score": 96,
		"tempo": 1.00,
	},
	"trend_gaming_myths_glitches": {
		"name": "Gaming Myths & Glitches",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 1,
		"symbols": 8,
		"palette": 2,
		"popularity_score": 93,
		"tempo": 0.90,
	},
	"trend_pop_culture": {
		"name": "Pop Culture",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 2,
		"symbols": 10,
		"palette": 4,
		"popularity_score": 90,
		"tempo": 0.82,
	},
	"trend_music_hooks": {
		"name": "Music Hooks",
		"blurb": "Featured this week. Free to play.",
		"free": true,
		"order": 3,
		"symbols": 6,
		"palette": 1,
		"popularity_score": 71,
		"tempo": 0.98,
	},
	"trend_screen_moments": {
		"name": "Screen Moments",
		"blurb": "Featured this week. Free to play.",
		"free": true,
		"order": 4,
		"symbols": 7,
		"palette": 3,
		"popularity_score": 64,
		"tempo": 0.95,
	},
	"trend_sports_flashes": {
		"name": "Sports Flashes",
		"blurb": "Featured this week. Free to play.",
		"free": true,
		"order": 5,
		"symbols": 7,
		"palette": 5,
		"popularity_score": 61,
		"tempo": 0.94,
	},
	"trend_science_signals": {
		"name": "Science Signals",
		"blurb": "Featured this week. Free to play.",
		"free": true,
		"order": 6,
		"symbols": 8,
		"palette": 6,
		"popularity_score": 58,
		"tempo": 0.92,
	},
	"trend_speedrun_relics": {
		"name": "Speedrun Relics",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 7,
		"symbols": 9,
		"palette": 7,
		"popularity_score": 85,
		"tempo": 0.88,
	},
	"trend_arcade_ghosts": {
		"name": "Arcade Ghosts",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 8,
		"symbols": 9,
		"palette": 0,
		"popularity_score": 81,
		"tempo": 0.87,
	},
	"trend_meme_fossils": {
		"name": "Meme Fossils",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 9,
		"symbols": 10,
		"palette": 1,
		"popularity_score": 88,
		"tempo": 0.85,
	},
	"trend_studio_legends": {
		"name": "Studio Legends",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 10,
		"symbols": 10,
		"palette": 2,
		"popularity_score": 55,
		"tempo": 0.84,
	},
	"trend_console_wars": {
		"name": "Console Wars",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 11,
		"symbols": 11,
		"palette": 3,
		"popularity_score": 72,
		"tempo": 0.83,
	},
	"trend_handheld_era": {
		"name": "Handheld Era",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 12,
		"symbols": 11,
		"palette": 4,
		"popularity_score": 52,
		"tempo": 0.82,
	},
	"trend_soundtrack_vaults": {
		"name": "Soundtrack Vaults",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 13,
		"symbols": 12,
		"palette": 5,
		"popularity_score": 49,
		"tempo": 0.81,
	},
	"trend_pixel_archaeology": {
		"name": "Pixel Archaeology",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 14,
		"symbols": 12,
		"palette": 6,
		"popularity_score": 77,
		"tempo": 0.80,
	},
	"trend_glitch_cathedral": {
		"name": "Glitch Cathedral",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 15,
		"symbols": 13,
		"palette": 7,
		"popularity_score": 75,
		"tempo": 0.79,
	},
	"trend_broadcast_static": {
		"name": "Broadcast Static",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 16,
		"symbols": 13,
		"palette": 0,
		"popularity_score": 46,
		"tempo": 0.78,
	},
	"trend_deep_lore": {
		"name": "Deep Lore",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 17,
		"symbols": 14,
		"palette": 1,
		"popularity_score": 70,
		"tempo": 0.77,
	},
	"trend_lost_media": {
		"name": "Lost Media",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 18,
		"symbols": 14,
		"palette": 2,
		"popularity_score": 79,
		"tempo": 0.76,
	},
	"trend_final_boss": {
		"name": "Final Boss",
		"blurb": "Denser alphabet. Less time to read it.",
		"free": false,
		"order": 19,
		"symbols": 15,
		"palette": 3,
		"popularity_score": 74,
		"tempo": 0.75,
	},
}

## Save section for per-category best scores. Scores are OURS to own; unlock
## state is not, and deliberately lives in IrisState instead.
const SECTION: String = "trend"
const KEY_BEST_PREFIX: String = "best_"
const KEY_RUNS_PREFIX: String = "runs_"


# ═════════════════════════════════════════════════════════════════════════
# ROSTER
# ═════════════════════════════════════════════════════════════════════════
## Ids in stable display order. Dictionary key order is an implementation
## detail and must never decide what a player sees first.
static func all_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in TRENDS.keys():
		ids.append(id)
	ids.sort_custom(func(a: String, b: String) -> bool:
		return int(TRENDS[a].get("order", 0)) < int(TRENDS[b].get("order", 0)))
	return ids


static func has(trend_id: String) -> bool:
	return TRENDS.has(trend_id)


static func display_name(trend_id: String) -> String:
	if not TRENDS.has(trend_id):
		return trend_id
	return str(TRENDS[trend_id].get("name", trend_id))


static func blurb(trend_id: String) -> String:
	if not TRENDS.has(trend_id):
		return ""
	return str(TRENDS[trend_id].get("blurb", ""))


## Is this category free forever?
static func is_free(trend_id: String) -> bool:
	if not TRENDS.has(trend_id):
		return false
	return bool(TRENDS[trend_id].get("free", false))


## The free default — the first free category in display order.
##
## Resolved from the table rather than hardcoded, so rotating the weekly
## featured set is a data edit. all_ids() is order-sorted, which is what makes
## "first" deterministic rather than dependent on Dictionary iteration.
static func default_id() -> String:
	for id: String in all_ids():
		if is_free(id):
			return id
	Log.warn("TrendRegistry", "no free category declared")
	return ""


## Every free category, in display order.
static func free_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in all_ids():
		if is_free(id):
			ids.append(id)
	return ids


## Every ad-unlockable category, in display order.
static func paid_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in all_ids():
		if not is_free(id):
			ids.append(id)
	return ids


## A category id IS a rental pack id. Named explicitly so the coupling is
## searchable rather than implied by a string literal at each call site.
static func pack_id(trend_id: String) -> StringName:
	return StringName(trend_id)


static func param(trend_id: String, key: String, fallback: Variant) -> Variant:
	if not TRENDS.has(trend_id):
		return fallback
	return TRENDS[trend_id].get(key, fallback)


static func symbol_count(trend_id: String) -> int:
	return int(param(trend_id, "symbols", 6))


static func tempo(trend_id: String) -> float:
	return float(param(trend_id, "tempo", 1.0))


static func palette_index(trend_id: String) -> int:
	return int(param(trend_id, "palette", 0))


# ═════════════════════════════════════════════════════════════════════════
# UNLOCK STATE — delegated, never duplicated
# ═════════════════════════════════════════════════════════════════════════
## Can the player run this category right now?
##
## Free categories are always playable and never consult the rental table, so
## the default channel cannot be locked out by a pruning bug or a clock edit.
static func is_unlocked(state: IrisState, trend_id: String,
		now_unix: float = -1.0) -> bool:
	if not Log.must(state != null, "TrendRegistry", "is_unlocked got null state"):
		return false
	if not Log.must(TRENDS.has(trend_id), "TrendRegistry",
			"unknown category '%s'" % trend_id):
		return false
	if is_free(trend_id):
		return true
	return state.is_rental_active(pack_id(trend_id), now_unix)


## Whole days left on a paid category, rounded up. Zero for free categories,
## which have no expiry to report.
static func days_remaining(state: IrisState, trend_id: String,
		now_unix: float = -1.0) -> int:
	if state == null or is_free(trend_id):
		return 0
	return state.rental_days_remaining(pack_id(trend_id), now_unix)


## Absolute UTC expiry, or 0 when there is none. Straight through to the
## read-only accessor on IrisState.
static func expires_utc(state: IrisState, trend_id: String) -> int:
	if state == null or is_free(trend_id):
		return 0
	return state.get_pack_expires_utc(pack_id(trend_id))


# ═════════════════════════════════════════════════════════════════════════
# SCORES
# ═════════════════════════════════════════════════════════════════════════
## Best score recorded for a category, 0 if never played.
static func best_score(trend_id: String) -> int:
	return int(Save.get_v(SECTION, KEY_BEST_PREFIX + trend_id, 0))


static func run_count(trend_id: String) -> int:
	return int(Save.get_v(SECTION, KEY_RUNS_PREFIX + trend_id, 0))


## Record a finished run. Returns true when it set a new personal best.
##
## A best score only ever rises. Writing unconditionally would let a bad run
## erase a good one, which is the kind of loss a player never forgives and
## cannot undo.
static func submit_score(trend_id: String, score: int) -> bool:
	if not Log.must(TRENDS.has(trend_id), "TrendRegistry",
			"submit_score for unknown category '%s'" % trend_id):
		return false
	if not Log.must(score >= 0, "TrendRegistry",
			"negative score %d for '%s'" % [score, trend_id]):
		return false

	Save.set_v(SECTION, KEY_RUNS_PREFIX + trend_id, run_count(trend_id) + 1)

	var previous: int = best_score(trend_id)
	if score <= previous:
		Save.flush()
		return false

	Save.set_v(SECTION, KEY_BEST_PREFIX + trend_id, score)
	Save.flush()
	Log.info("TrendRegistry", "new best for '%s': %d (was %d)" % [
		trend_id, score, previous])
	return true


# ═════════════════════════════════════════════════════════════════════════
# VALIDATION
# ═════════════════════════════════════════════════════════════════════════
## Prove the roster is internally consistent. Returns [] when healthy.
static func validate() -> Array[String]:
	var problems: Array[String] = []

	var free_count: int = 0
	var orders: Dictionary = {}

	for id: String in TRENDS.keys():
		var entry: Dictionary = TRENDS[id]

		if str(entry.get("name", "")) == "":
			problems.append("%s: missing display name" % id)
		if int(entry.get("symbols", 0)) < 2:
			problems.append("%s: needs at least 2 symbols to discriminate" % id)
		if float(entry.get("tempo", 0.0)) <= 0.0:
			problems.append("%s: tempo must be > 0" % id)
		var score: int = int(entry.get("popularity_score", -1))
		if score < 0 or score > 100:
			problems.append("%s: popularity_score %d outside 0-100" % [id, score])

		if bool(entry.get("free", false)):
			free_count += 1

		var order: int = int(entry.get("order", -1))
		if orders.has(order):
			problems.append("%s: duplicate order %d (display order is ambiguous)"
				% [id, order])
		orders[order] = true

	# Capacity and the free/paid split are contractual, not incidental: the
	# hub advertises a weekly roster, and a miscount means either a player
	# sees fewer channels than promised or a paid channel is quietly free.
	if TRENDS.size() != TARGET_CATEGORY_COUNT:
		problems.append("expected %d categories, found %d" % [
			TARGET_CATEGORY_COUNT, TRENDS.size()])
	if free_count != FREE_CATEGORY_COUNT:
		problems.append("expected %d free categories, found %d" % [
			FREE_CATEGORY_COUNT, free_count])

	# Display order must be a dense 0..N-1 run. A gap means an id was removed
	# without renumbering, and the list silently reorders around the hole.
	for expected: int in range(TRENDS.size()):
		if not orders.has(expected):
			problems.append("display order %d is missing" % expected)

	# A free channel must never be harder than a paid one, or the unlock is a
	# downgrade. Compare the hardest free against the easiest paid.
	var hardest_free: int = 0
	var easiest_paid: int = 9999
	for id: String in TRENDS.keys():
		var symbols: int = int(TRENDS[id].get("symbols", 0))
		if bool(TRENDS[id].get("free", false)):
			hardest_free = maxi(hardest_free, symbols)
		else:
			easiest_paid = mini(easiest_paid, symbols)
	if easiest_paid < 9999 and hardest_free > easiest_paid:
		problems.append("a free category (%d symbols) is denser than a paid one (%d)"
			% [hardest_free, easiest_paid])

	return problems
