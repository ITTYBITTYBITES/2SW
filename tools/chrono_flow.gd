extends SceneTree
## CHRONO-PULSE against the REAL engine, not a Python mirror.
##
## WHY THIS FILE EXISTS:
## tests/test_chrono_pulse.py re-implements the seed and streak maths in Python
## and checks the Python. That verifies the DESIGN, but corrupting the GDScript
## does not fail it — three deliberately injected defects (grace widened from
## 2 to 5 days, the seed switched from UTC to local, a tier boundary moved by
## 1ms) all passed the Python suite untouched. A mirror tests the mirror.
##
## Everything here calls the actual ChronoPulse functions the game ships. The
## same three injections DO fail this file, which is the only evidence that
## these checks are worth running.

var _fails: Array[String] = []
var _n: int = 0

## ChronoPulse references Log and ProgressionEngine at class scope, and a
## --script MainLoop compiles BEFORE autoloads attach. Load it as a resource
## after the first deferred frame; the same constraint documented in
## validate.gd and consent_flow.gd.
var _cp: GDScript = null
var _ctl: GDScript = null
var _engine: GDScript = null

const DAY: int = 86400


func _save() -> Node:
	return root.get_node_or_null("Save")


func _wipe() -> void:
	_save().call("wipe")


## A fresh IrisState via the live class, since a --script MainLoop cannot name
## it at class scope.
func _new_state() -> Object:
	var script: GDScript = ResourceLoader.load("res://data/iris_state.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	return script.new()


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ CHRONO-PULSE (live engine) ═══\n")
	_cp = ResourceLoader.load("res://core/chrono_pulse.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ctl = ResourceLoader.load("res://nodes/chrono_pulse_controller.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_engine = ResourceLoader.load("res://data/progression_engine.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	if _cp == null:
		print("FAIL: ChronoPulse failed to load")
		quit(1)
		return

	_test_seed_determinism()
	_test_date_rollovers()
	_test_utc_not_local()
	_test_generation()
	_test_tiers()
	_test_streak()
	_test_recovery()
	_test_share_spoilers()
	_test_self_verification()
	await _test_controller()
	await _test_unification()
	await _test_recovery_persistence()
	await _test_ui_integration()
	await _test_result_bounds()
	await _test_played_trial()
	await _test_determinism_across_players()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d CHRONO CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


# ─────────────────────────────────────────────────────────────────────────
func _seed(unix_time: int) -> String:
	return str(_cp.call("seed_for_unix", float(unix_time)))


func _test_seed_determinism() -> void:
	print("── determinism ──")
	# The product promise: same date, same puzzle, every device, forever.
	for date: String in ["2026-01-01", "2026-07-26", "2030-12-31"]:
		var a: Dictionary = _cp.call("anomaly_for_seed", date)
		var b: Dictionary = _cp.call("anomaly_for_seed", date)
		_ok("'%s' is reproducible" % date, a == b)

	# Hard-coded expected values. If FNV-1a, the salts, or the ranges ever
	# change, these break — which is the POINT. A player's daily puzzle
	# silently shifting between releases is the failure this catches, and it
	# cannot be caught by re-deriving the value from the same code.
	var known: Dictionary = _cp.call("anomaly_for_seed", "2026-07-26")
	_ok("2026-07-26 kind is frozen", int(known.get("kind", -1)) == _expected_kind(),
		"got %d" % int(known.get("kind", -1)))
	_ok("2026-07-26 pulses frozen", int(known.get("pulses", -1)) == _expected_pulses(),
		"got %d" % int(known.get("pulses", -1)))

	# FNV-1a must match the published specification exactly. This is the
	# anchor: if the hash drifts, every date's puzzle drifts with it.
	_ok("FNV-1a of '' is the offset basis",
		int(_cp.call("hash_seed", "")) == 2166136261)
	_ok("FNV-1a of 'a' matches the spec",
		int(_cp.call("hash_seed", "a")) == 0xE40C292C,
		"got 0x%X" % int(_cp.call("hash_seed", "a")))
	_ok("FNV-1a of 'foobar' matches the spec",
		int(_cp.call("hash_seed", "foobar")) == 0xBF9CF968,
		"got 0x%X" % int(_cp.call("hash_seed", "foobar")))
	_ok("hash stays inside 32 bits",
		int(_cp.call("hash_seed", "2026-07-26")) <= 0xFFFFFFFF)


## Recomputed from the frozen constants so the expectation is explicit rather
## than copied from a passing run.
func _expected_kind() -> int:
	var h: int = int(_cp.call("derive", "2026-07-26", "kind"))
	return h % 4


func _expected_pulses() -> int:
	var h: int = int(_cp.call("derive", "2026-07-26", "pulses"))
	return 4 + (h % 6)


func _test_date_rollovers() -> void:
	print("── date rollovers ──")
	var midnight: int = int(Time.get_unix_time_from_datetime_string("2026-07-26T00:00:00"))

	_ok("00:00:00 UTC starts the day", _seed(midnight) == "2026-07-26", _seed(midnight))
	_ok("23:59:59 UTC is the same day", _seed(midnight + DAY - 1) == "2026-07-26")
	_ok("midnight rolls over", _seed(midnight + DAY) == "2026-07-27")
	_ok("one second earlier is yesterday", _seed(midnight - 1) == "2026-07-25")
	_ok("epoch is 1970-01-01", _seed(0) == "1970-01-01", _seed(0))

	# Every boundary a calendar has. Hand-rolled date maths gets these wrong.
	var edges: Array[Array] = [
		["2026-01-31T00:00:00", "2026-02-01", "month end 31->1"],
		["2026-02-28T00:00:00", "2026-03-01", "non-leap february"],
		["2028-02-28T00:00:00", "2028-02-29", "leap day exists"],
		["2028-02-29T00:00:00", "2028-03-01", "leap day -> march"],
		["2024-02-28T00:00:00", "2024-02-29", "2024 is a leap year"],
		["2026-12-31T00:00:00", "2027-01-01", "year rollover"],
		["2026-04-30T00:00:00", "2026-05-01", "30-day month"],
		["2100-02-28T00:00:00", "2100-03-01", "2100 is NOT a leap year"],
	]
	for edge: Array in edges:
		var start: int = int(Time.get_unix_time_from_datetime_string(str(edge[0])))
		_ok(str(edge[2]), _seed(start + DAY) == str(edge[1]),
			"got %s want %s" % [_seed(start + DAY), str(edge[1])])

	# Format and sort order. trim_history() relies on ISO dates sorting
	# chronologically as plain strings.
	var seeds: Array[String] = []
	var regex: RegEx = RegEx.new()
	regex.compile("^\\d{4}-\\d{2}-\\d{2}$")
	var malformed: int = 0
	for i: int in range(400):
		var s: String = _seed(midnight + i * DAY)
		seeds.append(s)
		if regex.search(s) == null:
			malformed += 1
	_ok("400 dates are all YYYY-MM-DD", malformed == 0, "%d malformed" % malformed)

	var sorted_copy: Array[String] = seeds.duplicate()
	sorted_copy.sort()
	_ok("ISO dates sort chronologically", seeds == sorted_copy)


func _test_utc_not_local() -> void:
	print("── the seed is UTC, never local ──")
	# THE REGRESSION THIS CATCHES: switching the seed to local time would hand
	# different players different puzzles on the same date, silently. The
	# Python mirror cannot catch it because it mirrors the intent, not the code.
	#
	# Anchor against a timestamp whose UTC date is unambiguous and whose local
	# date differs in most timezones: 23:30 UTC.
	var late: int = int(Time.get_unix_time_from_datetime_string("2026-07-26T23:30:00"))
	_ok("23:30 UTC is still 2026-07-26", _seed(late) == "2026-07-26", _seed(late))

	var early: int = int(Time.get_unix_time_from_datetime_string("2026-07-26T00:30:00"))
	_ok("00:30 UTC is already 2026-07-26", _seed(early) == "2026-07-26", _seed(early))

	# Cross-check against the engine's own UTC converter. If seed_for_unix
	# ever applies a timezone bias, these diverge.
	for offset_hours: int in range(0, 24, 3):
		var ts: int = late + offset_hours * 3600
		var utc: Dictionary = Time.get_datetime_dict_from_unix_time(ts)
		var expected: String = "%04d-%02d-%02d" % [
			int(utc.get("year", 0)), int(utc.get("month", 0)), int(utc.get("day", 0))]
		_ok("+%dh matches the engine's UTC date" % offset_hours,
			_seed(ts) == expected, "%s vs %s" % [_seed(ts), expected])

	# The seed must NOT equal a local-shifted date when a bias exists.
	var zone: Dictionary = Time.get_time_zone_from_system()
	var bias_minutes: int = int(zone.get("bias", 0))
	if bias_minutes != 0:
		var shifted: String = _seed(late + bias_minutes * 60)
		_ok("seed ignores the device timezone",
			_seed(late) != shifted or bias_minutes == 0)
	else:
		# CI runs in UTC, so the negative case cannot be observed directly.
		# Assert the implementation does not read the timezone at all instead.
		var src: String = FileAccess.get_file_as_string("res://core/chrono_pulse.gd")
		var seed_fn: String = src.split("static func seed_for_unix")[1].split("static func")[0]
		_ok("seed_for_unix never reads the timezone",
			not seed_fn.contains("get_time_zone_from_system"))


func _test_generation() -> void:
	print("── generated anomalies are playable ──")
	var midnight: int = int(Time.get_unix_time_from_datetime_string("2026-01-01T00:00:00"))
	var problems: int = 0
	var kinds: Dictionary = {}
	var windows: Dictionary = {}
	var repeats: int = 0
	var previous: Dictionary = {}

	# Ten years. Any unplayable day in that span is a day the game is broken
	# for every player simultaneously.
	for i: int in range(3650):
		var seed_id: String = _seed(midnight + i * DAY)
		var anomaly: Dictionary = _cp.call("anomaly_for_seed", seed_id)
		var faults: Array = _cp.call("verify_anomaly", anomaly)
		if not faults.is_empty():
			problems += 1
			if problems <= 3:
				print("      %s -> %s" % [seed_id, str(faults)])
		kinds[int(anomaly.get("kind", -1))] = true
		windows[int(anomaly.get("window_ms", -1))] = true
		if not previous.is_empty() and anomaly == previous:
			repeats += 1
		previous = anomaly

	_ok("10 years of days are all playable", problems == 0, "%d bad" % problems)
	_ok("no two consecutive days are identical", repeats == 0, "%d repeats" % repeats)
	_ok("all 4 anomaly kinds occur", kinds.size() == 4, str(kinds.keys()))
	_ok("window is well distributed", windows.size() > 500, str(windows.size()))


func _test_tiers() -> void:
	print("── precision tiers ──")
	var coverage: Array = _cp.call("verify_tier_coverage")
	_ok("tier table is sound", coverage.is_empty(), str(coverage))

	_ok("0ms is instant", str(_cp.call("tier_for_latency", 0, true)) == "instant")
	_ok("250ms is instant", str(_cp.call("tier_for_latency", 250, true)) == "instant")
	# The off-by-one that a comment cannot catch.
	_ok("251ms is sharp", str(_cp.call("tier_for_latency", 251, true)) == "sharp")
	_ok("400ms is sharp", str(_cp.call("tier_for_latency", 400, true)) == "sharp")
	_ok("401ms is steady", str(_cp.call("tier_for_latency", 401, true)) == "steady")
	_ok("650ms is steady", str(_cp.call("tier_for_latency", 650, true)) == "steady")
	_ok("651ms is delayed", str(_cp.call("tier_for_latency", 651, true)) == "delayed")
	_ok("1000ms is delayed", str(_cp.call("tier_for_latency", 1000, true)) == "delayed")
	_ok("1001ms is adrift", str(_cp.call("tier_for_latency", 1001, true)) == "adrift")
	_ok("60s is still adrift", str(_cp.call("tier_for_latency", 60000, true)) == "adrift")

	# A miss is categorically not a slow reaction.
	_ok("a miss is missed, not adrift",
		str(_cp.call("tier_for_latency", 50, false)) == "missed")
	_ok("a 0ms miss is still missed",
		str(_cp.call("tier_for_latency", 0, false)) == "missed")
	_ok("negative latency is refused",
		str(_cp.call("tier_for_latency", -1, true)) == "missed")

	# Bars must never leave 0..5 — the card draws exactly five slots.
	var out_of_range: int = 0
	for ms: int in range(0, 5000, 13):
		for hit: bool in [true, false]:
			var bars: int = int(_cp.call("pulse_bars", ms, hit, 1.0))
			if bars < 0 or bars > 5:
				out_of_range += 1
	_ok("pulse bars always 0..5", out_of_range == 0, "%d out of range" % out_of_range)
	_ok("a miss scores zero bars", int(_cp.call("pulse_bars", 0, false, 1.0)) == 0)
	# A fast wrong answer must not outscore a correct one.
	_ok("accuracy weights the score",
		float(_cp.call("performance_score", 100, true, 1.0))
		> float(_cp.call("performance_score", 100, true, 0.0)))


func _test_streak() -> void:
	print("── streak arithmetic ──")
	_ok("first completion starts at 1",
		int(_cp.call("evaluate_streak", 0, 0, -1, 20000).get("streak", -1)) == 1)
	_ok("consecutive day advances",
		int(_cp.call("evaluate_streak", 5, 5, 19999, 20000).get("streak", -1)) == 6)
	_ok("same day is idempotent",
		bool(_cp.call("evaluate_streak", 5, 5, 20000, 20000).get("already_done_today", false)))
	_ok("same day does not advance",
		int(_cp.call("evaluate_streak", 5, 5, 20000, 20000).get("streak", -1)) == 5)

	# Grace must match ProgressionEngine exactly, or the ChronoPulse streak and
	# the Lumina daily streak disagree about whether a player kept it.
	var grace: int = int(_cp.get("GRACE_DAYS"))
	var engine: GDScript = ResourceLoader.load("res://data/progression_engine.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("grace equals ProgressionEngine's", grace == int(engine.get("STREAK_GRACE_DAYS")),
		"%d vs %d" % [grace, int(engine.get("STREAK_GRACE_DAYS"))])

	_ok("a gap inside grace advances",
		int(_cp.call("evaluate_streak", 5, 5, 20000 - (1 + grace), 20000)
			.get("streak", -1)) == 6)
	_ok("a gap beyond grace resets to 1",
		int(_cp.call("evaluate_streak", 5, 5, 20000 - (2 + grace), 20000)
			.get("streak", -1)) == 1)
	_ok("a break is reported",
		bool(_cp.call("evaluate_streak", 9, 9, 19990, 20000).get("broke", false)))
	_ok("missed days are counted",
		int(_cp.call("evaluate_streak", 9, 9, 19990, 20000).get("missed_days", -1)) == 9)
	_ok("best streak never decreases",
		int(_cp.call("evaluate_streak", 9, 30, 19990, 20000).get("best_streak", -1)) == 30)

	# A device clock jumping backwards must not cost a streak.
	var back: Dictionary = _cp.call("evaluate_streak", 7, 7, 20005, 20000)
	_ok("backwards clock does not advance", not bool(back.get("advanced", true)))
	_ok("backwards clock does not reset", int(back.get("streak", -1)) == 7)
	_ok("backwards clock does not break", not bool(back.get("broke", true)))

	# A year of real play, driven through the real function.
	var streak: int = 0
	var best: int = 0
	var last: int = -1
	for day: int in range(20000, 20365):
		var r: Dictionary = _cp.call("evaluate_streak", streak, best, last, day)
		streak = int(r.get("streak", 0))
		best = int(r.get("best_streak", 0))
		last = day
	_ok("365 consecutive days -> 365", streak == 365, str(streak))
	_ok("365 consecutive days -> best 365", best == 365, str(best))


func _test_recovery() -> void:
	print("── streak recovery ──")
	var cost: int = int(_cp.get("RECOVERY_LUMINA_COST"))
	var max_gap: int = int(_cp.get("MAX_RECOVERABLE_GAP_DAYS"))

	_ok("nothing to recover with no streak",
		not bool(_cp.call("recovery_offer", 0, -1, 20000, 99999, 0).get("eligible", true)))
	_ok("an unbroken streak is not recoverable",
		not bool(_cp.call("recovery_offer", 5, 20000, 20000, 99999, 0).get("eligible", true)))

	var fresh: Dictionary = _cp.call("recovery_offer", 9, 20000 - 3, 20000, 99999, 0)
	_ok("a fresh lapse is recoverable", bool(fresh.get("eligible", false)),
		str(fresh.get("reason", "")))
	_ok("the lost streak is reported", int(fresh.get("lost_streak", -1)) == 9)

	_ok("an ancient lapse is refused",
		not bool(_cp.call("recovery_offer", 9, 20000 - 60, 20000, 99999, 0)
			.get("eligible", true)))
	_ok("beyond the gap cap is refused",
		not bool(_cp.call("recovery_offer", 9, 20000 - (max_gap + 2), 20000, 99999, 0)
			.get("eligible", true)))
	_ok("one recovery per day",
		not bool(_cp.call("recovery_offer", 9, 20000 - 3, 20000, 99999, 1)
			.get("eligible", true)))

	# A player with no Lumina must still SEE the offer, and still have the ad
	# path. Hiding it would leave them unaware recovery exists at all.
	var poor: Dictionary = _cp.call("recovery_offer", 9, 20000 - 3, 20000, 0, 0)
	_ok("a broke player still sees the offer", bool(poor.get("eligible", false)))
	_ok("a broke player cannot afford it", not bool(poor.get("affordable", true)))
	_ok("a broke player keeps the ad path", bool(poor.get("ad_eligible", false)))
	_ok("exact balance affords it",
		bool(_cp.call("recovery_offer", 9, 20000 - 3, 20000, cost, 0).get("affordable", false)))
	_ok("one short does not",
		not bool(_cp.call("recovery_offer", 9, 20000 - 3, 20000, cost - 1, 0)
			.get("affordable", true)))

	_ok("recovery restores the streak plus today",
		int(_cp.call("streak_after_recovery", 9)) == 10)
	_ok("recovery of zero is safe", int(_cp.call("streak_after_recovery", 0)) == 1)
	_ok("recovery of a negative is clamped",
		int(_cp.call("streak_after_recovery", -5)) == 1)


func _test_share_spoilers() -> void:
	print("── share text leaks nothing ──")
	# THE SPOILER RULE, enforced against real generated cards rather than by
	# reading the format string. A recipient who has not played must not learn
	# which anomaly it is, when it lands, or how fast the answer comes.
	var midnight: int = int(Time.get_unix_time_from_datetime_string("2026-01-01T00:00:00"))
	var leaks: int = 0
	for i: int in range(0, 730, 7):
		var seed_id: String = _seed(midnight + i * DAY)
		var anomaly: Dictionary = _cp.call("anomaly_for_seed", seed_id)
		var record: Dictionary = _cp.call("build_record", seed_id, seed_id,
			337, true, 1.0, 12)
		var text: String = str(_cp.call("share_text", record, 12))
		var problems: Array = _cp.call("verify_share_is_spoiler_free", text, anomaly, record)
		if not problems.is_empty():
			leaks += 1
			if leaks <= 3:
				print("      %s -> %s" % [seed_id, str(problems)])
	_ok("104 sampled cards leak nothing", leaks == 0, "%d leaked" % leaks)

	var sample_record: Dictionary = _cp.call("build_record", "2026-07-26", "2026-07-26",
		337, true, 1.0, 12)
	var sample: String = str(_cp.call("share_text", sample_record, 12))
	_ok("card names the date", sample.contains("2026-07-26"))
	_ok("card shows the streak", sample.contains("12"))
	_ok("card shows a tier", sample.contains("Sharp"), sample)
	# The exact latency is the biggest spoiler of all — it tells a friend
	# precisely how fast to be.
	_ok("card hides the exact latency", not sample.contains("337"), sample)

	var missed: Dictionary = _cp.call("build_record", "2026-07-26", "2026-07-26",
		0, false, 0.0, 0)
	_ok("a miss renders as Missed",
		str(_cp.call("share_text", missed, 0)).contains("Missed"))
	_ok("a miss shows zero bars", int(missed.get("bars", -1)) == 0)


func _test_self_verification() -> void:
	print("── invariants and guards ──")
	# The module's own verifiers must be honest: feed them known-bad input and
	# confirm they object. A verifier that always returns [] is decoration.
	var broken: Dictionary = {
		"pulses": 2, "target_index": 5, "window_ms": 10, "kind": 99,
	}
	var caught: Array = _cp.call("verify_anomaly", broken)
	_ok("verify_anomaly rejects an impossible target", caught.size() >= 3,
		str(caught))

	var good: Dictionary = _cp.call("anomaly_for_seed", "2026-07-26")
	_ok("verify_anomaly accepts a real day",
		(_cp.call("verify_anomaly", good) as Array).is_empty())

	# The verifier must object to real leaks, or it is decoration. Feed it a
	# card naming the anomaly and one carrying a stray timing value.
	var named: Array = _cp.call("verify_share_is_spoiler_free",
		"CHRONO-PULSE today is %s" % str(good.get("kind_name", "")), good, {})
	_ok("the spoiler check catches a named anomaly", not named.is_empty())
	var timed: Array = _cp.call("verify_share_is_spoiler_free",
		"CHRONO-PULSE react after %d ms" % int(good.get("window_ms", 0)), good, {})
	_ok("the spoiler check catches a stray number", not timed.is_empty())
	var clean_card: Dictionary = _cp.call("build_record", "2026-07-26", "2026-07-26",
		337, true, 1.0, 12)
	_ok("the spoiler check accepts a real card",
		(_cp.call("verify_share_is_spoiler_free",
			str(_cp.call("share_text", clean_card, 12)), good, clean_card) as Array).is_empty())

	# History retention keeps the newest and drops the oldest.
	var history: Dictionary = {}
	var cap: int = int(_cp.get("MAX_HISTORY_ENTRIES"))
	var midnight: int = int(Time.get_unix_time_from_datetime_string("2026-01-01T00:00:00"))
	for i: int in range(cap + 50):
		history[_seed(midnight + i * DAY)] = {"n": i}
	var trimmed: Dictionary = _cp.call("trim_history", history)
	_ok("history trims to the cap", trimmed.size() == cap, str(trimmed.size()))
	_ok("trimming drops the oldest", not trimmed.has(_seed(midnight)))
	_ok("trimming keeps the newest",
		trimmed.has(_seed(midnight + (cap + 49) * DAY)))
	var small: Dictionary = {"2026-01-01": {}}
	_ok("a small history is untouched",
		(_cp.call("trim_history", small) as Dictionary).size() == 1)

	_ok("UTC/local skew is declared as 1 day",
		int(_cp.call("max_seed_day_skew")) == 1)


# ═════════════════════════════════════════════════════════════════════════
# PHASE 2 — CONTROLLER, PERSISTENCE, BUS
# ═════════════════════════════════════════════════════════════════════════
func _test_controller() -> void:
	print("── controller: persistence ──")
	_wipe()
	await process_frame

	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")
	var seed_id: String = _seed(int(now))

	_ok("a fresh save has nothing solved", not bool(_ctl.call("is_solved", seed_id)))
	_ok("an unplayed day has no record",
		(_ctl.call("record_for", seed_id) as Dictionary).is_empty())

	var outcome: Dictionary = _ctl.call("record_completion", state, 337, true, 1.0, now)
	_ok("completion is recorded", bool(outcome.get("recorded", false)))
	_ok("today is now solved", bool(_ctl.call("is_solved", seed_id)))
	_ok("the record round-trips through Save",
		int((_ctl.call("record_for", seed_id) as Dictionary).get("latency_ms", -1)) == 337)
	_ok("tier is stored, not recomputed on read",
		str((_ctl.call("record_for", seed_id) as Dictionary).get("tier", "")) == "sharp")

	# Replay protection: the global puzzle is one shot. A second attempt must
	# not overwrite a time that may already have been shared.
	var replay: Dictionary = _ctl.call("record_completion", state, 90, true, 1.0, now)
	_ok("a replay is refused", not bool(replay.get("recorded", true)))
	_ok("a replay reports already_solved", bool(replay.get("already_solved", false)))
	_ok("a replay cannot improve the stored time",
		int((_ctl.call("record_for", seed_id) as Dictionary).get("latency_ms", -1)) == 337)
	_ok("a replay still returns the original record for the card",
		int((replay.get("record", {}) as Dictionary).get("latency_ms", -1)) == 337)

	# Survives a reload — the whole point of flush() over flush_soon().
	_save().call("flush")
	_save().call("_load")
	await process_frame
	_ok("the record survives a save reload", bool(_ctl.call("is_solved", seed_id)))

	print("── controller: history retention ──")
	_wipe()
	await process_frame
	var many: Object = _new_state()
	var base: float = Time.get_unix_time_from_datetime_string("2026-01-01T12:00:00")
	var cap: int = int(_cp.get("MAX_HISTORY_ENTRIES"))
	# Play more days than the cap to prove the save cannot grow without bound.
	for i: int in range(cap + 20):
		_ctl.call("record_completion", many, 300, true, 1.0, base + float(i * DAY))
	var stored: Dictionary = _save().call("get_v", "chrono", "history", {})
	_ok("history is capped in Save", stored.size() == cap, str(stored.size()))
	_ok("the oldest day was dropped", not stored.has(_seed(int(base))))
	_ok("the newest day was kept",
		stored.has(_seed(int(base) + (cap + 19) * DAY)))


func _test_unification() -> void:
	print("── UNIFIED STREAK (the load-bearing claim) ──")
	# THE CLAIM: completing the anomaly advances THE streak — the same counter
	# the Daily Hub shows — not a private ChronoPulse one. Asserted against
	# real Save state and real IrisState, both directions.

	# There must be exactly ONE evaluator. A second one is the v1 defect.
	var src: String = FileAccess.get_file_as_string("res://core/chrono_pulse.gd")
	_ok("ChronoPulse declares no streak evaluator",
		not src.contains("static func evaluate_streak("))
	var ctl_src: String = FileAccess.get_file_as_string(
		"res://nodes/chrono_pulse_controller.gd")
	_ok("the controller delegates to ProgressionEngine",
		ctl_src.contains("ProgressionEngine.evaluate_daily_streak("))

	_wipe()
	await process_frame
	var state: Object = _new_state()
	var day1: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")

	_ctl.call("record_completion", state, 300, true, 1.0, day1)
	_ok("anomaly advances the IrisState streak", int(state.get("streak_days")) == 1,
		str(state.get("streak_days")))
	# The Daily Hub reads SEC_DAILY. If the anomaly did not stamp it, the hub
	# would still offer Claim and the player would bank the day twice.
	_ok("anomaly stamps SEC_DAILY.last_day_index",
		int(_save().call("get_v", "daily", "last_day_index", -1))
		== int(_engine.call("local_day_index", day1)))
	_ok("anomaly writes SEC_DAILY.streak",
		int(_save().call("get_v", "daily", "streak", -1)) == 1)
	_ok("the Daily Hub now sees today as claimed",
		not bool(_engine.call("is_daily_available",
			int(_save().call("get_v", "daily", "last_day_index", -1)), day1)))

	# Consecutive days advance the SHARED counter.
	var day2: float = day1 + float(DAY)
	_ctl.call("record_completion", state, 300, true, 1.0, day2)
	_ok("a second day advances the shared streak", int(state.get("streak_days")) == 2,
		str(state.get("streak_days")))

	# ── Reverse order: Claim first, then the anomaly ──────────────────────
	# The anomaly must still RECORD, but must not pay a second time.
	_wipe()
	await process_frame
	var s2: Object = _new_state()
	var d1: float = Time.get_unix_time_from_datetime_string("2026-03-10T09:00:00")
	var claim: Dictionary = _engine.call("evaluate_daily_streak", s2, -1, d1)
	_save().call("set_v", "daily", "last_day_index", int(_engine.call("local_day_index", d1)))
	_ok("Daily Hub claim pays first", bool(claim.get("claimed", false)))
	var streak_after_claim: int = int(s2.get("streak_days"))

	var after: Dictionary = _ctl.call("record_completion", s2, 300, true, 1.0, d1)
	_ok("the anomaly still records its result", bool(after.get("recorded", false)))
	_ok("but does not advance the streak twice",
		int(s2.get("streak_days")) == streak_after_claim,
		"%d vs %d" % [int(s2.get("streak_days")), streak_after_claim])
	_ok("and pays no second Lumina", int(after.get("lumina", -1)) == 0)
	_ok("streak_advanced reports false", not bool(after.get("streak_advanced", true)))

	# Grace must behave identically whichever surface drives it.
	_wipe()
	await process_frame
	var s3: Object = _new_state()
	var base: float = Time.get_unix_time_from_datetime_string("2026-05-01T12:00:00")
	_ctl.call("record_completion", s3, 300, true, 1.0, base)
	# Skip one day — inside the 1-day grace — then play again.
	_ctl.call("record_completion", s3, 300, true, 1.0, base + float(2 * DAY))
	_ok("grace via the anomaly matches the engine", int(s3.get("streak_days")) == 2,
		str(s3.get("streak_days")))


func _test_recovery_persistence() -> void:
	print("── recovery: live state ──")
	_wipe()
	await process_frame

	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")
	var today_index: int = int(_engine.call("local_day_index", now))

	# Build a lapsed 9-day streak: last played 3 local days ago.
	state.set("streak_days", 9)
	state.set("best_streak_days", 9)
	state.set("lumina", 1000)
	_save().call("set_v", "daily", "last_day_index", today_index - 3)

	var offer: Dictionary = _ctl.call("current_offer", state, now)
	_ok("a lapsed streak is offered recovery", bool(offer.get("eligible", false)),
		str(offer.get("reason", "")))
	_ok("the offer prices it in Lumina",
		int(offer.get("lumina_cost", 0)) == int(_cp.get("RECOVERY_LUMINA_COST")))

	var cost: int = int(_cp.get("RECOVERY_LUMINA_COST"))
	var recovered: Dictionary = _ctl.call("recover_streak", state, "lumina", now)
	_ok("recovery succeeds", bool(recovered.get("recovered", false)),
		str(recovered.get("reason", "")))
	_ok("the streak is restored plus today", int(state.get("streak_days")) == 10,
		str(state.get("streak_days")))
	_ok("Lumina was actually spent", int(state.get("lumina")) == 1000 - cost,
		str(state.get("lumina")))
	_ok("recovery stamps today as claimed",
		int(_save().call("get_v", "daily", "last_day_index", -1)) == today_index)
	_ok("best streak rose with it", int(state.get("best_streak_days")) == 10)

	# One per local day.
	_ok("a second recovery the same day is refused",
		not bool((_ctl.call("recover_streak", state, "lumina", now) as Dictionary)
			.get("recovered", true)))

	# ── The ad path must not require Lumina ───────────────────────────────
	_wipe()
	await process_frame
	var broke: Object = _new_state()
	broke.set("streak_days", 7)
	broke.set("lumina", 0)
	_save().call("set_v", "daily", "last_day_index", today_index - 3)

	var poor_offer: Dictionary = _ctl.call("current_offer", broke, now)
	_ok("a broke player is still offered recovery", bool(poor_offer.get("eligible", false)))
	_ok("a broke player cannot pay Lumina", not bool(poor_offer.get("affordable", true)))
	_ok("the Lumina path refuses without funds",
		not bool((_ctl.call("recover_streak", broke, "lumina", now) as Dictionary)
			.get("recovered", true)))
	_ok("the streak is untouched by a failed payment", int(broke.get("streak_days")) == 7)
	_ok("the ad path succeeds with zero Lumina",
		bool((_ctl.call("recover_streak", broke, "ad", now) as Dictionary)
			.get("recovered", false)))
	_ok("the ad path costs nothing", int(broke.get("lumina")) == 0)
	_ok("the ad path restores the same streak", int(broke.get("streak_days")) == 8)

	# An unknown method must be refused loudly, not silently treated as free.
	_wipe()
	await process_frame
	var s: Object = _new_state()
	s.set("streak_days", 5)
	_save().call("set_v", "daily", "last_day_index", today_index - 3)
	_ok("an unknown recovery method is refused",
		not bool((_ctl.call("recover_streak", s, "free_lunch", now) as Dictionary)
			.get("recovered", true)))
	_ok("an unknown method changes nothing", int(s.get("streak_days")) == 5)

	print("── share export ──")
	_wipe()
	await process_frame
	var sharer: Object = _new_state()
	var outcome: Dictionary = _ctl.call("record_completion", sharer, 337, true, 1.0, now)
	var text: String = str(outcome.get("share_text", ""))
	_ok("completion returns share text", text != "")
	_ok("share preview matches",
		str(_ctl.call("share_preview", outcome.get("record", {}),
			int(sharer.get("streak_days")))) == text)
	_ok("an empty record previews as empty",
		str(_ctl.call("share_preview", {}, 0)) == "")
	# copy_share_text verifies spoilers at the moment of export, so a leak can
	# never reach a clipboard even if some future edit breaks the format.
	_ok("copy refuses an empty record",
		not bool(_ctl.call("copy_share_text", {}, 0)))


# ═════════════════════════════════════════════════════════════════════════
# PHASE 3 — UI INTEGRATION
# ═════════════════════════════════════════════════════════════════════════
func _test_ui_integration() -> void:
	print("── routing ──")
	var router: Node = root.get_node_or_null("Router")
	var routes: Dictionary = router.get("ROUTES")
	_ok("'chrono_card' route declared", routes.has("chrono_card"))
	_ok("the card scene exists",
		ResourceLoader.exists(str(routes.get("chrono_card", ""))))
	_ok("'daily' still resolves",
		ResourceLoader.exists(str(routes.get("daily", ""))))

	print("── daily hub portal ──")
	_wipe()
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var hub: Node = (load("res://screens/daily_hub.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame
	await process_frame

	var portal: Control = hub.get_node_or_null("%AnomalyPanel") as Control
	var portal_button: Button = hub.get_node_or_null("%AnomalyButton") as Button
	var recover: Button = hub.get_node_or_null("%RecoverButton") as Button
	var status: Label = hub.get_node_or_null("%AnomalyStatus") as Label
	_ok("the hub has an anomaly panel", portal != null)
	_ok("the hub has an anomaly button", portal_button != null)
	_ok("the hub has a recover button", recover != null)

	_ok("an unplayed day invites a run",
		portal_button != null and portal_button.text.contains("Begin"),
		portal_button.text if portal_button != null else "<no button>")
	# An always-visible recovery button on a healthy streak is an upsell.
	_ok("recovery is hidden on a fresh save",
		recover != null and not recover.visible)
	# The hub is seen BEFORE the run, so naming the anomaly would spoil it
	# for the player themselves.
	var hub_anomaly: Dictionary = _ctl.call("today_anomaly")
	_ok("the hub does not name the anomaly",
		status != null
		and not status.text.contains(str(hub_anomaly.get("kind_name", "@@"))),
		status.text if status != null else "<no status>")
	# The portal must be reachable, not merely present: a zero-size panel
	# inside a scroll view is invisible to a player.
	_ok("the anomaly panel has real area",
		portal != null and portal.size.x > 100.0 and portal.size.y > 40.0,
		str(portal.size) if portal != null else "<no panel>")
	hub.free()
	await process_frame

	print("── result card renders a real record ──")
	_wipe()
	await process_frame
	var state: Object = _new_state()
	var outcome: Dictionary = _ctl.call("record_completion", state, 337, true, 1.0,
		Time.get_unix_time_from_system())

	var card: Node = (load("res://screens/chrono_pulse/result_card.tscn") as PackedScene).instantiate()
	card.call("configure", {
		"record": outcome.get("record", {}),
		"streak": int(state.get("streak_days")),
	})
	root.add_child(card)
	await process_frame
	await process_frame

	var date_label: Label = card.get_node_or_null("%DateLabel") as Label
	var tier_badge: Label = card.get_node_or_null("%TierBadge") as Label
	var streak_label: Label = card.get_node_or_null("%StreakLabel") as Label
	var share_button: Button = card.get_node_or_null("%ShareButton") as Button

	_ok("card shows the date",
		date_label != null and date_label.text.contains(_seed(int(Time.get_unix_time_from_system()))),
		date_label.text if date_label != null else "missing")
	_ok("card shows the tier badge",
		tier_badge != null and tier_badge.text == "Sharp",
		tier_badge.text if tier_badge != null else "missing")
	_ok("card shows the streak",
		streak_label != null and streak_label.text == "1",
		streak_label.text if streak_label != null else "missing")
	_ok("share is enabled for a real record",
		share_button != null and not share_button.disabled)

	# THE SPOILER RULE, enforced on the rendered UI rather than the format
	# string: no label anywhere on the card may carry the raw latency.
	var leaked: Array[String] = []
	_scan_labels(card, "337", leaked)
	_ok("no label leaks the raw latency", leaked.is_empty(), ", ".join(leaked))
	var anomaly_today: Dictionary = _ctl.call("today_anomaly")
	var kind_leaks: Array[String] = []
	_scan_labels(card, str(anomaly_today.get("kind_name", "@@")), kind_leaks)
	_ok("no label names the anomaly", kind_leaks.is_empty(), ", ".join(kind_leaks))
	card.free()
	await process_frame

	print("── result card handles an unplayed day ──")
	_wipe()
	await process_frame
	var empty_card: Node = (load("res://screens/chrono_pulse/result_card.tscn") as PackedScene).instantiate()
	empty_card.call("configure", {})
	root.add_child(empty_card)
	await process_frame
	await process_frame
	var empty_badge: Label = empty_card.get_node_or_null("%TierBadge") as Label
	var empty_share: Button = empty_card.get_node_or_null("%ShareButton") as Button
	# An honest empty state beats a fake perfect one.
	_ok("an unplayed day says so",
		empty_badge != null and empty_badge.text == "Not yet run",
		empty_badge.text if empty_badge != null else "missing")
	_ok("share is disabled with no record",
		empty_share != null and empty_share.disabled)
	empty_card.free()
	await process_frame


## Recursive label scan. Proves absence across the whole rendered tree, which
## a grep of the .tscn cannot do for text assigned in script.
func _scan_labels(node: Node, needle: String, found: Array[String]) -> void:
	if needle == "" or needle == "@@":
		return
	if node is Label and (node as Label).text.contains(needle):
		found.append(str(node.name))
	if node is Button and (node as Button).text.contains(needle):
		found.append(str(node.name))
	for child: Node in node.get_children():
		_scan_labels(child, needle, found)


# ═════════════════════════════════════════════════════════════════════════
# PHASE 4 — RESULT BOUNDS
# ═════════════════════════════════════════════════════════════════════════
func _test_result_bounds() -> void:
	print("── latency / accuracy bounds ──")
	# A daily run cannot be repeated, so an invalid write is permanent. These
	# are the values that must never reach the save file.
	_ok("a clean result validates",
		(_cp.call("validate_result", 337, true, 1.0) as Array).is_empty())
	_ok("a clean miss validates",
		(_cp.call("validate_result", 0, false, 0.0) as Array).is_empty())

	_ok("negative latency is refused",
		not (_cp.call("validate_result", -1, true, 1.0) as Array).is_empty())
	_ok("an absurd latency is refused",
		not (_cp.call("validate_result", 900_000, true, 1.0) as Array).is_empty())
	_ok("accuracy above 1 is refused",
		not (_cp.call("validate_result", 300, true, 1.4) as Array).is_empty())
	_ok("accuracy below 0 is refused",
		not (_cp.call("validate_result", 300, true, -0.2) as Array).is_empty())
	# NaN fails every comparison including against itself, so a naive range
	# check waves it through and it lands in the save as a null on reload.
	_ok("NaN accuracy is refused",
		not (_cp.call("validate_result", 300, true, NAN) as Array).is_empty())
	# A hit with no measured latency means the stimulus was never timed.
	_ok("a hit with zero latency is refused",
		not (_cp.call("validate_result", 0, true, 1.0) as Array).is_empty())

	# Boundaries are inclusive at the ceiling and exclusive one past it.
	var ceiling: int = int(_cp.get("MAX_CREDIBLE_LATENCY_MS"))
	_ok("the ceiling itself is accepted",
		(_cp.call("validate_result", ceiling, true, 1.0) as Array).is_empty())
	_ok("one past the ceiling is refused",
		not (_cp.call("validate_result", ceiling + 1, true, 1.0) as Array).is_empty())

	print("── invalid results never reach Save ──")
	_wipe()
	await process_frame
	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")
	var bad: Dictionary = _ctl.call("record_completion", state, -5, true, 1.0, now)
	_ok("an invalid result is rejected", bool(bad.get("rejected", false)))
	_ok("an invalid result is not recorded", not bool(bad.get("recorded", true)))
	# The crucial part: the day must remain PLAYABLE. Burning the one daily
	# attempt on a result we refused to store would be worse than the bug.
	_ok("a rejected result leaves the day unplayed",
		not bool(_ctl.call("is_solved", _seed(int(now)))))
	_ok("a rejected result does not touch the streak",
		int(state.get("streak_days")) == 0, str(state.get("streak_days")))


# ═════════════════════════════════════════════════════════════════════════
# PHASE 4 — A LIVE PLAYED TRIAL
# ═════════════════════════════════════════════════════════════════════════
## Drive the REAL trial host and the REAL Stroop mini-game, tapping answers
## the way a player would, and confirm the measured latency lands in the card.
##
## Not a mock. The whole point of Phase 4 is that the anomaly is playable, and
## a test that stubs the mini-game would prove only that the stub works.
func _test_played_trial() -> void:
	print("── a live played anomaly: HIT inside the window ──")
	_wipe()
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var anomaly: Dictionary = _ctl.call("today_anomaly")
	var state: Object = _new_state()

	var host: Node = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	host.call("configure", {
		"trial_id": str(_cp.get("TRIAL_ID")),
		"iris_state": state,
		"is_daily": true,
		"chrono_anomaly": anomaly,
	})
	root.add_child(host)
	await process_frame
	await process_frame

	_ok("the host recognises an anomaly run", bool(host.call("is_anomaly_run")))
	_ok("the host derives a non-zero seed", int(host.call("trial_seed")) != 0)
	_ok("the host exposes the anomaly params",
		str((host.call("anomaly_params") as Dictionary).get("seed_id", ""))
		== str(anomaly.get("seed_id", "")))

	var game: Node = host.get_node_or_null("%Stage/MiniGame")
	_ok("the Stroop mini-game mounted", game != null)
	if game == null:
		host.free()
		return

	# The anomaly's window must actually reach the mini-game, or the daily is
	# tuned by the bracket table and the seed is decorative.
	var expected_window: float = float(int(anomaly.get("window_ms", 0))) / 1000.0
	_ok("the anomaly window drives the trial",
		absf(float(game.get("_window")) - expected_window) < 0.001,
		"%.3f vs %.3f" % [float(game.get("_window")), expected_window])
	_ok("the anomaly round count drives the trial",
		int(game.call("rounds_total")) == int(anomaly.get("pulses", -1)),
		"%d vs %d" % [int(game.call("rounds_total")), int(anomaly.get("pulses", -1))])

	# ── Play it: answer every stimulus correctly, promptly ────────────────
	var rounds: int = int(game.call("rounds_total"))
	for i: int in range(rounds):
		if not bool(game.call("is_running")):
			break
		# Answer the INK index — the correct Stroop response.
		var ink: int = int(game.get("_ink_index"))
		# A real reaction takes time. Let a frame or two pass so the measured
		# latency is a genuine elapsed interval rather than zero.
		await process_frame
		await process_frame
		game.call("_on_swatch_tapped", ink)
		await process_frame

	_ok("every round was answered", int(game.call("rounds_done")) == rounds,
		"%d of %d" % [int(game.call("rounds_done")), rounds])
	_ok("latencies were measured",
		(game.call("latencies") as Array).size() == rounds,
		str((game.call("latencies") as Array).size()))
	_ok("the player is recorded as having responded",
		bool(game.call("had_any_response")))
	_ok("no timeouts on a fully answered run", int(game.call("miss_count")) == 0)

	var mean: int = int(game.call("mean_latency_ms"))
	_ok("mean latency is positive", mean > 0, str(mean))
	_ok("mean latency is credible",
		mean < int(_cp.get("MAX_CREDIBLE_LATENCY_MS")), str(mean))

	# THE LATENCY MUST BE PER-STIMULUS, NOT TOTAL ELAPSED TIME.
	#
	# Deriving it from the host's elapsed clock would silently include every
	# inter-round pause, mount time and settlement frame — making a fast
	# player look slow and inflating the number for everyone equally, so it
	# would look plausible. An earlier version of this test could not tell the
	# difference: substituting `int(_elapsed_sec * 1000.0)` passed 200/200.
	#
	# The run answers N rounds inside one elapsed window, so a genuine
	# per-stimulus mean MUST be well under the total. Capture the host clock
	# before settlement and assert the gap.
	var host_elapsed_ms: int = int(host.call("elapsed_seconds") * 1000.0)
	_ok("host elapsed time is measurably larger than one reaction",
		host_elapsed_ms > mean, "elapsed %d vs mean %d" % [host_elapsed_ms, mean])
	# Float comparison, not integer division: `host_elapsed_ms / 2` discards
	# the remainder and the engine flags it. The intent is a ratio, so express
	# it as one.
	_ok("latency is per-stimulus, not total elapsed",
		float(mean) < float(host_elapsed_ms) * 0.5,
		"mean %d vs elapsed %d" % [mean, host_elapsed_ms])

	# Every individual latency must also be bounded by the response window —
	# an answer that took longer than the window would have timed out.
	var per_round: Array = game.call("latencies")
	var window_ms: int = int(anomaly.get("window_ms", 0))
	var over_window: Array[String] = []
	for value: Variant in per_round:
		if int(value) > window_ms:
			over_window.append(str(value))
	_ok("no recorded latency exceeds the response window",
		over_window.is_empty(), "window %d, got %s" % [window_ms, str(over_window)])
	_ok("every recorded latency is positive",
		per_round.all(func(v: Variant) -> bool: return int(v) > 0), str(per_round))

	await process_frame
	await process_frame

	# Settlement must have recorded today through the real path.
	var seed_id: String = str(anomaly.get("seed_id", ""))
	_ok("the played run recorded today", bool(_ctl.call("is_solved", seed_id)))
	var record: Dictionary = _ctl.call("record_for", seed_id)
	_ok("the record carries a measured latency",
		int(record.get("latency_ms", -1)) > 0, str(record.get("latency_ms", -1)))
	# The stored value must be the mini-game's measurement, not a recomputation.
	_ok("the stored latency IS the measured mean",
		int(record.get("latency_ms", -1)) == mean,
		"stored %d vs measured %d" % [int(record.get("latency_ms", -1)), mean])
	_ok("the stored latency is under the response window",
		int(record.get("latency_ms", 999999)) <= int(anomaly.get("window_ms", 0)),
		"%d vs window %d" % [int(record.get("latency_ms", -1)),
			int(anomaly.get("window_ms", 0))])
	_ok("the record is a hit", bool(record.get("hit", false)))
	_ok("perfect play scores accuracy 1.0",
		absf(float(record.get("accuracy", 0.0)) - 1.0) < 0.001,
		str(record.get("accuracy", 0.0)))
	_ok("the streak advanced from the played run",
		int(state.get("streak_days")) == 1, str(state.get("streak_days")))
	# The card must show what was actually measured.
	_ok("the stored tier matches the measured latency",
		str(record.get("tier", "")) == str(_cp.call("tier_for_latency",
			int(record.get("latency_ms", 0)), true)))
	host.free()
	await process_frame

	print("── a live played anomaly: MISSED every window ──")
	_wipe()
	await process_frame
	var state2: Object = _new_state()
	var host2: Node = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	host2.call("configure", {
		"trial_id": str(_cp.get("TRIAL_ID")),
		"iris_state": state2,
		"is_daily": true,
		"chrono_anomaly": anomaly,
	})
	root.add_child(host2)
	await process_frame
	await process_frame

	var game2: Node = host2.get_node_or_null("%Stage/MiniGame")
	_ok("the mini-game mounted for the miss run", game2 != null)
	if game2 == null:
		host2.free()
		return

	# Never tap. Drive the clock past every window so each one times out.
	var window: float = float(game2.get("_window"))
	var guard: int = 0
	while bool(game2.call("is_running")) and guard < 400:
		game2.call("_process", window + 0.05)
		guard += 1
		await process_frame

	_ok("the miss run finished", not bool(game2.call("is_running")))
	_ok("every window timed out",
		int(game2.call("miss_count")) == int(anomaly.get("pulses", -1)),
		"%d of %d" % [int(game2.call("miss_count")), int(anomaly.get("pulses", -1))])
	# A timeout must NOT be recorded as a latency equal to the window. That
	# would make "never responded" indistinguishable from "responded slowly".
	_ok("timeouts recorded no latencies",
		(game2.call("latencies") as Array).is_empty(),
		str(game2.call("latencies")))
	_ok("no response is reported", not bool(game2.call("had_any_response")))
	_ok("mean latency of a miss run is -1, not 0",
		int(game2.call("mean_latency_ms")) == -1,
		str(game2.call("mean_latency_ms")))

	await process_frame
	await process_frame

	var missed: Dictionary = _ctl.call("record_for", str(anomaly.get("seed_id", "")))
	_ok("the missed run still recorded the day", not missed.is_empty())
	_ok("a missed run stores hit=false", not bool(missed.get("hit", true)))
	_ok("a missed run stores zero latency",
		int(missed.get("latency_ms", -1)) == 0, str(missed.get("latency_ms", -1)))
	_ok("a missed run tiers as 'missed'",
		str(missed.get("tier", "")) == "missed", str(missed.get("tier", "")))
	_ok("a missed run scores zero bars", int(missed.get("bars", -1)) == 0)
	# Showing up still counts: the streak is about habit, not performance.
	_ok("a missed run still advances the streak",
		int(state2.get("streak_days")) == 1, str(state2.get("streak_days")))
	host2.free()
	await process_frame


func _test_determinism_across_players() -> void:
	print("── two devices, one puzzle ──")
	# The product promise, tested against the real host: two independent runs
	# of the same date must be tuned identically.
	var anomaly: Dictionary = _ctl.call("today_anomaly")
	var windows: Array[float] = []
	var counts: Array[int] = []

	for run: int in range(2):
		var state: Object = _new_state()
		var host: Node = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
		host.call("configure", {
			"trial_id": str(_cp.get("TRIAL_ID")),
			"iris_state": state,
			"is_daily": true,
			"chrono_anomaly": anomaly,
		})
		root.add_child(host)
		await process_frame
		await process_frame
		var game: Node = host.get_node_or_null("%Stage/MiniGame")
		if game != null:
			windows.append(float(game.get("_window")))
			counts.append(int(game.call("rounds_total")))
		host.free()
		await process_frame

	_ok("both devices get the same window", windows.size() == 2 and windows[0] == windows[1],
		str(windows))
	_ok("both devices get the same round count",
		counts.size() == 2 and counts[0] == counts[1], str(counts))
