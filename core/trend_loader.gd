extends RefCounted
class_name TrendLoader
## TrendLoader — parse a generated trend roster, with a guaranteed fallback.
##
## Reads the `index.json` + `packs/pack_*.json` set produced by
## `tools/trend_content_pipeline/scripts/generate_weekly_packs.py`, validates it
## against the schema the pipeline's own validate_output.py enforces, and
## returns entries in the shape TrendRegistry already uses.
##
## ═══════════════════════════════════════════════════════════════════════════
## THE FALLBACK IS THE POINT
## ═══════════════════════════════════════════════════════════════════════════
## Every failure — missing file, malformed JSON, wrong schema version, a pack
## the index promises but does not ship, a roster with the wrong free/paid
## split — resolves to the BUNDLED roster in TrendRegistry. The game is
## playable offline on first launch and stays playable if a bad roster is ever
## published.
##
## That is not defensive padding. A remote roster is content the player did
## not ask for and cannot repair; a hub with zero categories because a JSON
## file lost a brace is a broken game, and "fail loudly" is the wrong
## behaviour when a correct answer is already sitting in the binary.
##
## So: load() NEVER returns an empty roster and never propagates an error to
## the UI. It logs, it falls back, and `last_source()` records which path was
## taken so a test can prove the fallback fired rather than inferring it.
##
## NOTE ON NETWORKING: this loader is filesystem-only. Fetching a roster over
## HTTP would need a consent review (a network call is a data flow), a cache,
## a signature check and an offline story. None of that exists yet, so the
## pipeline's output is treated as content that ships WITH the build.

## Schema this loader understands. A mismatch is a hard fallback, never a
## best-effort parse — a field that moved between versions read with the old
## meaning is worse than not loading at all.
const SCHEMA_VERSION: int = 1

const EXPECTED_TOTAL: int = 20
const EXPECTED_FREE: int = 5

## Where a shipped roster lives inside the game.
const BUNDLED_DIR: String = "res://data/trends/"

## Archived rosters from previous weeks, written as they are superseded.
const ARCHIVE_DIR: String = "user://trend_archive/"

## A pack at or above this base score is editorially "popular". Mirrors
## POPULAR_THRESHOLD in the generator; the loader re-derives is_popular rather
## than trusting the flag, so a hand-edited file cannot promote itself.
const POPULAR_THRESHOLD: int = 70

## How much a single local play is worth against the editorial prior.
##
## The base score is 0-100 and a play is worth 6, so roughly 17 plays can lift
## an unlisted category past a top-tier one. That is the intended balance:
## the prior decides what a NEW player sees first, and their own behaviour
## takes over within a couple of sessions. A larger weight would make one
## curious tap outrank editorial judgement; a smaller one would mean a player
## never sees their own favourites rise.
const PLAY_WEIGHT: int = 6

## Ceiling on the play contribution, so a single obsessively-played category
## cannot permanently monopolise the rail.
const MAX_PLAY_BONUS: int = 180

enum Source { NONE = 0, PARSED = 1, FALLBACK = 2 }

static var _last_source: Source = Source.NONE
static var _last_problem: String = ""


## Which path the most recent load() took.
static func last_source() -> Source:
	return _last_source


## Why the last load fell back, or "" when it parsed cleanly.
static func last_problem() -> String:
	return _last_problem


## Load a roster from `dir_path`, falling back to the bundled registry.
##
## Returns an Array of Dictionaries in TrendRegistry's own entry shape, so a
## caller can treat parsed and bundled rosters identically.
static func load_roster(dir_path: String = BUNDLED_DIR) -> Array[Dictionary]:
	_last_problem = ""

	var parsed: Array[Dictionary] = _try_parse(dir_path)
	if not parsed.is_empty():
		_last_source = Source.PARSED
		Log.info("TrendLoader", "loaded %d packs from %s" % [parsed.size(), dir_path])
		return parsed

	_last_source = Source.FALLBACK
	Log.info("TrendLoader", "using the bundled roster (%s)" % _last_problem)
	return bundled_roster()


## The roster compiled into the build. Always complete, always valid — it is
## the same table validate() proves at boot.
static func bundled_roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in TrendRegistry.all_ids():
		out.append({
			"id": id,
			"name": TrendRegistry.display_name(id),
			"blurb": TrendRegistry.blurb(id),
			"free": TrendRegistry.is_free(id),
			"order": int(TrendRegistry.param(id, "order", 0)),
			"symbols": TrendRegistry.symbol_count(id),
			"palette": TrendRegistry.palette_index(id),
			"tempo": TrendRegistry.tempo(id),
			"popularity_score": int(TrendRegistry.param(id, "popularity_score", 0)),
			"is_popular": int(TrendRegistry.param(id, "popularity_score", 0))
				>= POPULAR_THRESHOLD,
		})
	return out


## Attempt a real parse. Returns [] on ANY problem, with _last_problem set.
static func _try_parse(dir_path: String) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []

	var index_path: String = dir_path.path_join("index.json")
	if not FileAccess.file_exists(index_path):
		_last_problem = "no index.json at %s" % dir_path
		return empty

	var index_text: String = FileAccess.get_file_as_string(index_path)
	if index_text.is_empty():
		_last_problem = "index.json is empty or unreadable"
		return empty

	var index_parsed: Variant = JSON.parse_string(index_text)
	if not (index_parsed is Dictionary):
		_last_problem = "index.json is not a JSON object"
		return empty
	var index: Dictionary = index_parsed as Dictionary

	if int(index.get("schema_version", -1)) != SCHEMA_VERSION:
		_last_problem = "schema %s != %d" % [
			str(index.get("schema_version", "?")), SCHEMA_VERSION]
		return empty

	var entries: Variant = index.get("packs", [])
	if not (entries is Array):
		_last_problem = "index.packs is not an array"
		return empty

	var listed: Array = entries as Array
	if listed.size() != EXPECTED_TOTAL:
		_last_problem = "index lists %d packs, expected %d" % [
			listed.size(), EXPECTED_TOTAL]
		return empty

	var out: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var orders: Dictionary = {}
	var free_count: int = 0

	for raw_entry: Variant in listed:
		if not (raw_entry is Dictionary):
			_last_problem = "an index entry is not an object"
			return empty
		var entry: Dictionary = raw_entry as Dictionary

		var pack_file: String = str(entry.get("file", ""))
		if pack_file.is_empty():
			_last_problem = "an index entry has no file"
			return empty

		var pack_path: String = dir_path.path_join(pack_file)
		if not FileAccess.file_exists(pack_path):
			_last_problem = "missing pack file %s" % pack_file
			return empty

		var pack_parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(pack_path))
		if not (pack_parsed is Dictionary):
			_last_problem = "%s is not a JSON object" % pack_file
			return empty
		var pack: Dictionary = pack_parsed as Dictionary

		var problem: String = _validate_pack(pack)
		if problem != "":
			_last_problem = "%s: %s" % [pack_file, problem]
			return empty

		var pack_id: String = str(pack["id"])
		if seen_ids.has(pack_id):
			_last_problem = "duplicate pack id '%s'" % pack_id
			return empty
		seen_ids[pack_id] = true

		# The index and the pack must agree. A disagreement means one was
		# written from stale state, and the hub would show a name or tier
		# that does not match what it actually loads.
		if str(entry.get("id", pack_id)) != pack_id:
			_last_problem = "index/pack id mismatch for '%s'" % pack_id
			return empty
		if bool(entry.get("free", pack["free"])) != bool(pack["free"]):
			_last_problem = "index/pack free mismatch for '%s'" % pack_id
			return empty

		var order: int = int(pack["order"])
		if orders.has(order):
			_last_problem = "duplicate display order %d" % order
			return empty
		orders[order] = true

		if bool(pack["free"]):
			free_count += 1

		# popularity_score and is_popular are OPTIONAL in schema v1: a roster
		# generated before they existed must still load. Absent means zero,
		# which ranks below everything editorial without failing the parse.
		var base_score: int = clampi(int(pack.get("popularity_score", 0)), 0, 100)

		out.append({
			"id": pack_id,
			"name": str(pack["name"]),
			"blurb": str(pack.get("blurb", "")),
			"free": bool(pack["free"]),
			"order": order,
			"symbols": int(pack["symbols"]),
			"palette": int(pack["palette"]),
			"tempo": float(pack["tempo"]),
			"popularity_score": base_score,
			# Derived, not read: the file does not get to declare itself
			# popular without a score that earns it.
			"is_popular": base_score >= POPULAR_THRESHOLD,
		})

	if free_count != EXPECTED_FREE:
		_last_problem = "%d free packs, expected %d" % [free_count, EXPECTED_FREE]
		return empty

	# Dense 0..N-1. A gap means the roster silently reorders around a hole.
	for expected: int in range(out.size()):
		if not orders.has(expected):
			_last_problem = "display order %d is missing" % expected
			return empty

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["order"]) < int(b["order"]))
	return out


# ═════════════════════════════════════════════════════════════════════════
# ISO WEEK
# ═════════════════════════════════════════════════════════════════════════
## Save keys for rotation tracking. Under the registry's own section so all
## trend state lives in one place.
const KEY_LAST_ACTIVE_WEEK: String = "last_active_week"

## The ISO-8601 week label for a timestamp, e.g. "2026-W31".
##
## Godot has no ISO week function and the boundaries are genuinely subtle:
## week 1 is the week containing the first THURSDAY, so 29-31 December can
## belong to week 1 of the NEXT year and 1-3 January to week 52/53 of the
## PREVIOUS one. Getting it wrong means a rotation fires on the wrong day, or
## twice, or not at all across New Year.
##
## Verified against Python's datetime.isocalendar() across ~11 years of daily
## timestamps in tests/test_trend_pipeline.py — every one of ~4000 days.
##
## UTC, matching the pipeline: the roster is global, so every device must
## agree on which week it is regardless of timezone.
static func iso_week_label(unix_time: float) -> String:
	var parts: Array = iso_year_week(unix_time)
	return "%04d-W%02d" % [int(parts[0]), int(parts[1])]


## [iso_year, iso_week] for a timestamp. The ISO YEAR is not always the
## calendar year — that is the whole difficulty.
static func iso_year_week(unix_time: float) -> Array:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix_time))
	var year: int = int(date.get("year", 1970))
	var month: int = int(date.get("month", 1))
	var day: int = int(date.get("day", 1))

	# Godot reports 0=Sunday..6=Saturday; ISO wants 1=Monday..7=Sunday.
	var weekday: int = int(date.get("weekday", 0))
	var iso_weekday: int = 7 if weekday == 0 else weekday

	var ordinal: int = _day_of_year(year, month, day)
	# The canonical formula: the week number of the Thursday in this week.
	@warning_ignore("integer_division")
	var week: int = (ordinal - iso_weekday + 10) / 7

	if week < 1:
		# Belongs to the last week of the previous ISO year.
		return [year - 1, _weeks_in_iso_year(year - 1)]
	if week > _weeks_in_iso_year(year):
		# Belongs to week 1 of the next ISO year.
		return [year + 1, 1]
	return [year, week]


## Days elapsed in the year, 1-366.
static func _day_of_year(year: int, month: int, day: int) -> int:
	var cumulative: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273,
		304, 334]
	var total: int = cumulative[clampi(month - 1, 0, 11)] + day
	if month > 2 and _is_leap_year(year):
		total += 1
	return total


static func _is_leap_year(year: int) -> bool:
	# Century years are leap ONLY when divisible by 400 — 1900 is not, 2000 is.
	if year % 4 != 0:
		return false
	if year % 100 != 0:
		return true
	return year % 400 == 0


## 52 or 53. A year has 53 ISO weeks when it starts on a Thursday, or is a
## leap year starting on a Wednesday.
static func _weeks_in_iso_year(year: int) -> int:
	if _jan_first_weekday(year) == 4:
		return 53
	if _is_leap_year(year) and _jan_first_weekday(year) == 3:
		return 53
	return 52


## ISO weekday (1=Mon..7=Sun) of 1 January, via Zeller-style arithmetic so it
## needs no engine call and works for any year.
static func _jan_first_weekday(year: int) -> int:
	var y: int = year - 1
	@warning_ignore("integer_division")
	var days: int = 365 * y + y / 4 - y / 100 + y / 400
	# 1 January of year 1 was a Monday in the proleptic Gregorian calendar.
	return (days % 7) + 1


# ═════════════════════════════════════════════════════════════════════════
# WEEKLY ROTATION
# ═════════════════════════════════════════════════════════════════════════
## The week the player last opened the app in, or "" on a first launch.
static func last_active_week() -> String:
	return str(Save.get_v(TrendRegistry.SECTION, KEY_LAST_ACTIVE_WEEK, ""))


## Detect a week change and archive the outgoing roster.
##
## Called once at launch, from the splash warm-up. Returns:
##   { rotated, previous_week, current_week, archived }
##
## WHAT THIS DOES NOT DO: it never touches unlock records. Passes live in
## IrisState.active_rental_passes, keyed by pack id, and rotation does not
## read or write them. The archive stores the ROSTER — what the categories
## were — so a pass bought last week still resolves to a real category this
## week. Verified explicitly: a rotation with active passes leaves every one
## of them intact.
static func check_week_rotation(now_unix: float = -1.0) -> Dictionary:
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var current: String = iso_week_label(now)
	var previous: String = last_active_week()

	var result: Dictionary = {
		"rotated": false,
		"previous_week": previous,
		"current_week": current,
		"archived": false,
	}

	if previous == current:
		return result

	# First launch: stamp the week, archive nothing. There is no outgoing
	# roster to preserve, and writing one would claim the player had played a
	# week they never saw.
	if previous.is_empty():
		Save.set_v(TrendRegistry.SECTION, KEY_LAST_ACTIVE_WEEK, current)
		Save.flush()
		Log.info("TrendLoader", "first launch; active week %s" % current)
		return result

	result["rotated"] = true

	# Archive the roster the player had, under the week they had it in.
	# load_roster() falls back to the bundled set, so this always has content.
	var outgoing: Array[Dictionary] = load_roster()
	result["archived"] = archive_week(previous, outgoing)

	Save.set_v(TrendRegistry.SECTION, KEY_LAST_ACTIVE_WEEK, current)
	Save.flush()
	Log.info("TrendLoader", "week rotated %s -> %s (archived=%s)" % [
		previous, current, str(result["archived"])])
	return result


# ═════════════════════════════════════════════════════════════════════════
# POPULARITY
# ═════════════════════════════════════════════════════════════════════════
## Combined ranking score for one category.
##
## base popularity + (local plays * PLAY_WEIGHT), capped.
##
## Static and pure — it takes the play count rather than reading Save — so
## every ordering case is testable without touching a save file.
static func popularity_rank_score(base_score: int, plays: int) -> int:
	var safe_base: int = clampi(base_score, 0, 100)
	var safe_plays: int = maxi(plays, 0)
	var bonus: int = mini(safe_plays * PLAY_WEIGHT, MAX_PLAY_BONUS)
	return safe_base + bonus


## Top categories by combined editorial prior and local play count.
##
## Returns entries in roster shape with `plays` and `rank_score` added, so a
## UI can show why something ranked without recomputing it.
##
## Ordering is fully deterministic: rank score, then play count, then base
## score, then id. Without that final id tiebreak two categories with
## identical scores would swap places between calls depending on dictionary
## iteration, and a "popular" rail that reshuffles on every open looks broken.
static func get_popular_categories(limit: int = 10,
		roster: Array[Dictionary] = []) -> Array[Dictionary]:
	var source: Array[Dictionary] = roster
	if source.is_empty():
		source = load_roster()

	var ranked: Array[Dictionary] = []
	for entry: Dictionary in source:
		var id: String = str(entry.get("id", ""))
		if id.is_empty():
			continue
		var base: int = int(entry.get("popularity_score", 0))
		var plays: int = TrendRegistry.run_count(id)
		var scored: Dictionary = entry.duplicate(true)
		scored["plays"] = plays
		scored["rank_score"] = popularity_rank_score(base, plays)
		# Re-derived, never trusted from the file: a hand-edited pack must not
		# be able to flag itself popular without earning the score.
		scored["is_popular"] = base >= POPULAR_THRESHOLD
		ranked.append(scored)

	ranked.sort_custom(_compare_popularity)

	if limit <= 0:
		return ranked
	return ranked.slice(0, mini(limit, ranked.size()))


## Descending rank, with deterministic tiebreaks all the way down to the id.
static func _compare_popularity(a: Dictionary, b: Dictionary) -> bool:
	var a_rank: int = int(a.get("rank_score", 0))
	var b_rank: int = int(b.get("rank_score", 0))
	if a_rank != b_rank:
		return a_rank > b_rank

	var a_plays: int = int(a.get("plays", 0))
	var b_plays: int = int(b.get("plays", 0))
	if a_plays != b_plays:
		return a_plays > b_plays

	var a_base: int = int(a.get("popularity_score", 0))
	var b_base: int = int(b.get("popularity_score", 0))
	if a_base != b_base:
		return a_base > b_base

	return str(a.get("id", "")) < str(b.get("id", ""))


# ═════════════════════════════════════════════════════════════════════════
# ARCHIVE
# ═════════════════════════════════════════════════════════════════════════
## Persist the current roster under its week label, so a player can return to
## a category they unlocked before the roster rotated.
##
## THE PROBLEM THIS SOLVES: an ad-bought pass lasts 7 days, but the weekly
## roster changes every Sunday. Without an archive a player who unlocked a
## category on Saturday would find it simply gone the next morning — with
## days left on a pass they paid attention for.
##
## Idempotent: re-archiving the same week overwrites with identical content.
static func archive_week(week: String, roster: Array[Dictionary]) -> bool:
	if not Log.must(week != "", "TrendLoader", "archive_week got an empty week"):
		return false
	if not Log.must(not roster.is_empty(), "TrendLoader",
			"refusing to archive an empty roster for %s" % week):
		return false

	var error: int = DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
	if error != OK and error != ERR_ALREADY_EXISTS:
		Log.warn("TrendLoader", "cannot create the archive directory (%d)" % error)
		return false

	var handle: FileAccess = FileAccess.open(_archive_path(week), FileAccess.WRITE)
	if handle == null:
		Log.warn("TrendLoader", "cannot write the archive for %s" % week)
		return false

	handle.store_string(JSON.stringify({
		"schema_version": SCHEMA_VERSION,
		"week": week,
		"packs": roster,
	}))
	handle.close()
	Log.info("TrendLoader", "archived %d packs for %s" % [roster.size(), week])
	return true


## Every archived week label, newest first.
##
## ISO week labels sort lexicographically in chronological order, which is why
## the format is "YYYY-Www" — a friendlier format would need date parsing here
## and would sort wrongly across a year boundary.
static func get_archived_weeks() -> Array[String]:
	var weeks: Array[String] = []
	var dir: DirAccess = DirAccess.open(ARCHIVE_DIR)
	if dir == null:
		return weeks

	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with("week_") \
				and entry.ends_with(".json"):
			weeks.append(entry.trim_prefix("week_").trim_suffix(".json"))
		entry = dir.get_next()
	dir.list_dir_end()

	weeks.sort()
	weeks.reverse()
	return weeks


## Load an archived roster. Returns [] when the week was never archived.
##
## Deliberately does NOT fall back to the bundled roster: a caller asking for
## a specific past week wants that week or an honest empty answer, not
## today's list wearing last month's label.
static func load_archived_week(week: String) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	var path: String = _archive_path(week)
	if not FileAccess.file_exists(path):
		return empty

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		Log.warn("TrendLoader", "archive for %s is not a JSON object" % week)
		return empty

	var body: Dictionary = parsed as Dictionary
	if int(body.get("schema_version", -1)) != SCHEMA_VERSION:
		Log.warn("TrendLoader", "archive for %s has schema %s" % [
			week, str(body.get("schema_version", "?"))])
		return empty

	var stored: Variant = body.get("packs", [])
	if not (stored is Array):
		return empty

	var out: Array[Dictionary] = []
	for raw: Variant in (stored as Array):
		if raw is Dictionary:
			out.append(raw as Dictionary)
	return out


## Categories the player still holds a pass for, across EVERY archived week.
##
## This is the guarantee the archive exists to make: an unlock is honoured for
## its full 7 days even after the roster that introduced it has rotated away.
## Free categories are excluded — they are always available from the live
## roster and would only pad the list.
static func get_owned_archived_categories(state: IrisState) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not Log.must(state != null, "TrendLoader",
			"get_owned_archived_categories got null state"):
		return out

	var seen: Dictionary = {}
	for week: String in get_archived_weeks():
		for entry: Dictionary in load_archived_week(week):
			var id: String = str(entry.get("id", ""))
			if id.is_empty() or seen.has(id):
				continue
			if bool(entry.get("free", false)):
				continue
			# The rental engine is the authority, exactly as everywhere else.
			# An id that survives a rotation is precisely why unlocks persist.
			if not state.is_rental_active(StringName(id)):
				continue
			seen[id] = true
			var owned: Dictionary = entry.duplicate(true)
			owned["week"] = week
			owned["days_remaining"] = state.rental_days_remaining(StringName(id))
			out.append(owned)
	return out


static func _archive_path(week: String) -> String:
	return ARCHIVE_DIR.path_join("week_%s.json" % week)


## Field-level checks for one pack. Returns "" when sound.
static func _validate_pack(pack: Dictionary) -> String:
	for field: String in ["schema_version", "id", "name", "free", "order",
			"symbols", "palette", "tempo"]:
		if not pack.has(field):
			return "missing field '%s'" % field

	if int(pack["schema_version"]) != SCHEMA_VERSION:
		return "schema %d != %d" % [int(pack["schema_version"]), SCHEMA_VERSION]
	if str(pack["name"]).strip_edges().is_empty():
		return "empty name"
	if int(pack["symbols"]) < 2 or int(pack["symbols"]) > 32:
		return "symbols %d out of range" % int(pack["symbols"])
	if float(pack["tempo"]) <= 0.0 or float(pack["tempo"]) > 2.0:
		return "tempo %f out of range" % float(pack["tempo"])
	if int(pack["palette"]) < 0:
		return "negative palette index"
	if int(pack["order"]) < 0:
		return "negative order"
	return ""
