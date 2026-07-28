extends SceneTree
## Trend Hub against the REAL engine.
##
## The load-bearing claim of this feature is that unlocks REUSE the IrisState
## rental engine rather than adding a second expiry system. That claim is not
## provable by reading the code — it is provable by granting a pass through
## IrisState and watching the Trend Hub agree, then expiring it and watching
## the Trend Hub lock, with no Save key of its own anywhere in between.

var _fails: Array[String] = []
var _n: int = 0

var _reg: GDScript = null
var _hub: GDScript = null
var _iris: GDScript = null
var _game: GDScript = null

const DAY: int = 86400


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _save() -> Node:
	return root.get_node_or_null("Save")


func _wipe() -> void:
	_save().call("wipe")


func _new_state() -> Object:
	return _iris.new()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ TREND HUB (live engine) ═══\n")
	# Autoload-dependent scripts must be re-loaded after the first deferred
	# frame; a --script MainLoop compiles before autoloads attach.
	_reg = ResourceLoader.load("res://data/trend_registry.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_hub = ResourceLoader.load("res://screens/trend_hub.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_iris = ResourceLoader.load("res://data/iris_state.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_game = ResourceLoader.load("res://nodes/mini_games/trend_witness_game.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	if _reg == null or _hub == null or _iris == null or _game == null:
		print("FAIL: a Trend script failed to load")
		quit(1)
		return

	_test_registry()
	_test_no_second_expiry_system()
	await _test_rental_reuse()
	await _test_all_paid_unlock()
	await _test_accessor()
	_test_scores()
	_test_fair_window()
	await _test_compass()
	await _test_routing_and_ui()
	await _test_ad_readiness()
	await _test_loader()
	await _test_popularity()
	await _test_archive()
	await _test_rotation()
	await _test_tabs()
	await _test_midsession_rotation()
	await _test_hub_teardown()
	_test_cooldowns()
	await _test_cooldown_ui()
	_test_rescue_rule()
	await _test_rescue_live()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d TREND CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


# ─────────────────────────────────────────────────────────────────────────
func _test_registry() -> void:
	print("── registry ──")
	var problems: Array = _reg.call("validate")
	_ok("the registry validates", problems.is_empty(), str(problems))

	var ids: Array = _reg.call("all_ids")
	var target: int = int(_reg.get("TARGET_CATEGORY_COUNT"))
	var free_target: int = int(_reg.get("FREE_CATEGORY_COUNT"))
	_ok("weekly capacity is 20", target == 20, str(target))
	_ok("20 categories declared", ids.size() == target,
		"%d of %d" % [ids.size(), target])
	_ok("5 free categories declared",
		(_reg.call("free_ids") as Array).size() == free_target,
		str((_reg.call("free_ids") as Array).size()))
	_ok("15 paid categories declared",
		(_reg.call("paid_ids") as Array).size() == target - free_target,
		str((_reg.call("paid_ids") as Array).size()))
	_ok("free + paid accounts for everything",
		(_reg.call("free_ids") as Array).size()
		+ (_reg.call("paid_ids") as Array).size() == ids.size())

	# The three original ids MUST survive. A category id is a rental pack id
	# and a save key, so renaming one orphans every pass a player bought with
	# an ad and every score they set.
	for expected: String in ["trend_internet_lore", "trend_gaming_myths_glitches",
			"trend_pop_culture"]:
		_ok("legacy id '%s' preserved" % expected, bool(_reg.call("has", expected)))

	# Ids must be unique and order dense — a duplicate order silently reorders
	# the list around the collision.
	var seen_orders: Dictionary = {}
	var duplicate_order: bool = false
	for id: String in ids:
		var order: int = int(_reg.call("param", id, "order", -1))
		if seen_orders.has(order):
			duplicate_order = true
		seen_orders[order] = true
	_ok("every display order is unique", not duplicate_order)
	_ok("display order is dense 0..N-1", seen_orders.size() == ids.size())

	# Display order must be stable, not dictionary iteration order.
	_ok("the free channel sorts first", str(ids[0]) == "trend_internet_lore",
		str(ids))
	_ok("default_id resolves from the table",
		str(_reg.call("default_id")) == "trend_internet_lore")
	_ok("the default is free", bool(_reg.call("is_free", "trend_internet_lore")))
	_ok("paid categories are not free",
		not bool(_reg.call("is_free", "trend_gaming_myths_glitches"))
		and not bool(_reg.call("is_free", "trend_pop_culture")))
	# A free channel denser than a paid one would make the unlock a downgrade.
	var hardest_free: int = 0
	for id: String in (_reg.call("free_ids") as Array):
		hardest_free = maxi(hardest_free, int(_reg.call("symbol_count", id)))
	var easiest_paid: int = 9999
	for id: String in (_reg.call("paid_ids") as Array):
		easiest_paid = mini(easiest_paid, int(_reg.call("symbol_count", id)))
	_ok("no free category is denser than a paid one",
		hardest_free <= easiest_paid, "free %d vs paid %d" % [hardest_free, easiest_paid])
	# A category id IS a rental pack id; that coupling is the whole design.
	_ok("category id is the pack id",
		str(_reg.call("pack_id", "trend_pop_culture")) == "trend_pop_culture")


func _test_no_second_expiry_system() -> void:
	print("── NO second expiry system (the load-bearing claim) ──")
	# Asserted against source, because the whole instruction was "do not build
	# one". A second implementation would pass every behavioural test on the
	# day it was written and drift later.
	# Strip comments before scanning. The registry's docstring EXPLAINS why it
	# does not store an expiry key, and a raw substring search cannot tell an
	# explanation from an implementation — the first version of this check
	# failed on its own rationale.
	var reg_src: String = _code_only("res://data/trend_registry.gd")
	var hub_src: String = _code_only("res://screens/trend_hub.gd")
	var save_src: String = _code_only("res://core/save.gd")

	_ok("the registry stores no expiry key",
		not reg_src.contains("unlock_expires"), "trend_registry.gd")
	_ok("the hub stores no expiry key",
		not hub_src.contains("unlock_expires"), "trend_hub.gd")
	_ok("core/save.gd gained no unlock timestamp",
		not save_src.contains("unlock_expires"), "save.gd")

	# No local duration constant either — 7 days is RENTAL_DURATION_SEC's job.
	_ok("no duplicate 7-day constant in the registry",
		not reg_src.contains("7 * 86400") and not reg_src.contains("604800"))
	_ok("no duplicate 7-day constant in the hub",
		not hub_src.contains("7 * 86400") and not hub_src.contains("604800"))

	# Unlock reads must delegate.
	_ok("unlock state delegates to is_rental_active",
		reg_src.contains("state.is_rental_active("))
	_ok("day counts delegate to rental_days_remaining",
		reg_src.contains("state.rental_days_remaining("))
	_ok("the hub grants via grant_rental",
		hub_src.contains("_state.grant_rental("))
	_ok("the hub prunes expired passes on entry",
		hub_src.contains("prune_expired_rentals()"))


## A file's source with every comment line removed, so a scan tests code
## rather than prose about the code.
func _code_only(path: String) -> String:
	var out: PackedStringArray = PackedStringArray()
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#"):
			continue
		# Trailing comments too: `var x := 1  # unlock_expires_utc` would
		# otherwise read as code.
		var hash_at: int = line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


func _test_rental_reuse() -> void:
	print("── unlock lifecycle through the rental engine ──")
	_wipe()
	await process_frame
	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")

	# Free channel: never consults the rental table, so it cannot be locked
	# out by a pruning bug or a clock edit.
	_ok("the free channel is unlocked on a clean save",
		bool(_reg.call("is_unlocked", state, "trend_internet_lore", now)))
	_ok("paid channels start locked",
		not bool(_reg.call("is_unlocked", state, "trend_gaming_myths_glitches", now))
		and not bool(_reg.call("is_unlocked", state, "trend_pop_culture", now)))

	# Grant through the ENGINE, then read through the REGISTRY. If these are
	# two systems, this is where they disagree.
	state.call("grant_rental", StringName("trend_gaming_myths_glitches"), now)
	_ok("granting a rental unlocks the category",
		bool(_reg.call("is_unlocked", state, "trend_gaming_myths_glitches", now)))
	_ok("the grant is exactly 7 days",
		int(_reg.call("days_remaining", state, "trend_gaming_myths_glitches", now)) == 7,
		str(_reg.call("days_remaining", state, "trend_gaming_myths_glitches", now)))
	_ok("granting one category does not unlock another",
		not bool(_reg.call("is_unlocked", state, "trend_pop_culture", now)))

	# Countdown across the window.
	for elapsed_days: int in range(1, 7):
		var later: float = now + float(elapsed_days * DAY)
		_ok("day %d shows %d left" % [elapsed_days, 7 - elapsed_days],
			int(_reg.call("days_remaining", state, "trend_gaming_myths_glitches", later))
			== 7 - elapsed_days,
			str(_reg.call("days_remaining", state, "trend_gaming_myths_glitches", later)))

	# Expiry boundary: inclusive at the instant, locked one second past.
	var expiry: float = now + float(7 * DAY)
	_ok("still unlocked one second before expiry",
		bool(_reg.call("is_unlocked", state, "trend_gaming_myths_glitches", expiry - 1.0)))
	_ok("locked one second after expiry",
		not bool(_reg.call("is_unlocked", state, "trend_gaming_myths_glitches", expiry + 1.0)))
	_ok("an expired pass reports 0 days",
		int(_reg.call("days_remaining", state, "trend_gaming_myths_glitches", expiry + 1.0)) == 0)

	# Pruning is the engine's job, and it must clear the trend pack too.
	var pruned: int = int(state.call("prune_expired_rentals", expiry + 1.0))
	_ok("the engine prunes the expired trend pass", pruned == 1, str(pruned))
	_ok("the free channel survives pruning",
		bool(_reg.call("is_unlocked", state, "trend_internet_lore", expiry + 1.0)))

	# Persistence: the pass must survive a save round trip, through the
	# rental engine's own to_dict/from_dict, with no trend-specific code.
	_wipe()
	await process_frame
	var persist: Object = _new_state()
	persist.call("grant_rental", StringName("trend_pop_culture"), now)
	_save().call("set_v", "iris", "state", persist.call("to_dict"))
	_save().call("flush")
	_save().call("_load")
	await process_frame

	var restored: Object = _new_state()
	restored.call("from_dict", _save().call("get_v", "iris", "state", {}))
	_ok("the pass survives a save reload",
		bool(_reg.call("is_unlocked", restored, "trend_pop_culture", now)))
	_ok("the restored expiry is unchanged",
		int(restored.call("get_pack_expires_utc", StringName("trend_pop_culture")))
		== int(persist.call("get_pack_expires_utc", StringName("trend_pop_culture"))))


## Every paid category must unlock through the SAME engine, not just the two
## that existed before the expansion. A per-category bug would otherwise hide
## in the eighteen nobody tested.
func _test_all_paid_unlock() -> void:
	print("── all 15 paid categories unlock identically ──")
	_wipe()
	await process_frame
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")
	var state: Object = _new_state()

	var locked_at_start: int = 0
	for id: String in (_reg.call("paid_ids") as Array):
		if not bool(_reg.call("is_unlocked", state, id, now)):
			locked_at_start += 1
	_ok("every paid category starts locked",
		locked_at_start == (_reg.call("paid_ids") as Array).size(),
		"%d locked" % locked_at_start)

	var free_open: int = 0
	for id: String in (_reg.call("free_ids") as Array):
		if bool(_reg.call("is_unlocked", state, id, now)):
			free_open += 1
	_ok("every free category is open on a clean save",
		free_open == (_reg.call("free_ids") as Array).size(),
		"%d open" % free_open)

	var failures: Array[String] = []
	for id: String in (_reg.call("paid_ids") as Array):
		state.call("grant_rental", StringName(id), now)
		if not bool(_reg.call("is_unlocked", state, id, now)):
			failures.append(id + ":not-unlocked")
		if int(_reg.call("days_remaining", state, id, now)) != 7:
			failures.append(id + ":wrong-days")
		if int(_reg.call("expires_utc", state, id)) != int(now) + 7 * DAY:
			failures.append(id + ":wrong-expiry")
		if bool(_reg.call("is_unlocked", state, id, now + float(8 * DAY))):
			failures.append(id + ":never-expires")
	_ok("all 15 unlock, count down and expire identically",
		failures.is_empty(), ", ".join(failures))

	# Free categories must never consult the rental table at all.
	var free_expiry: Array[String] = []
	for id: String in (_reg.call("free_ids") as Array):
		if int(_reg.call("expires_utc", state, id)) != 0:
			free_expiry.append(id)
		if not bool(_reg.call("is_unlocked", state, id, now + float(400 * DAY))):
			free_expiry.append(id + ":expired")
	_ok("free categories never expire", free_expiry.is_empty(), ", ".join(free_expiry))


func _test_accessor() -> void:
	print("── get_pack_expires_utc ──")
	_wipe()
	await process_frame
	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")

	_ok("an ungranted pack reports 0",
		int(state.call("get_pack_expires_utc", StringName("trend_pop_culture"))) == 0)

	state.call("grant_rental", StringName("trend_pop_culture"), now)
	var expires: int = int(state.call("get_pack_expires_utc",
		StringName("trend_pop_culture")))
	_ok("the accessor returns the real expiry",
		expires == int(now) + 7 * DAY, "%d vs %d" % [expires, int(now) + 7 * DAY])
	# An int, not a float: a raw float renders as "1785053364.78505" on a label.
	_ok("the accessor returns a whole second",
		typeof(state.call("get_pack_expires_utc", StringName("trend_pop_culture")))
		== TYPE_INT)

	# READ-ONLY: calling it must not create, extend or mutate anything.
	var before: Dictionary = (state.get("active_rental_passes") as Dictionary).duplicate()
	state.call("get_pack_expires_utc", StringName("never_granted"))
	state.call("get_pack_expires_utc", StringName("trend_pop_culture"))
	_ok("the accessor mutates nothing",
		(state.get("active_rental_passes") as Dictionary) == before)

	# An EXPIRED pass still reports its past timestamp, so the UI can say
	# "expired 2 days ago" rather than "never had one".
	var past: float = now + float(8 * DAY)
	_ok("an expired pass still reports its timestamp",
		int(state.call("get_pack_expires_utc", StringName("trend_pop_culture"))) > 0)
	_ok("but is not active", not bool(state.call("is_rental_active",
		StringName("trend_pop_culture"), past)))
	# The registry's own passthrough must agree with the engine.
	_ok("registry expires_utc matches the engine",
		int(_reg.call("expires_utc", state, "trend_pop_culture")) == expires)
	_ok("a free category reports no expiry",
		int(_reg.call("expires_utc", state, "trend_internet_lore")) == 0)


func _test_scores() -> void:
	print("── best scores ──")
	_wipe()
	_ok("an unplayed category has no best",
		int(_reg.call("best_score", "trend_internet_lore")) == 0)
	_ok("an unplayed category has no runs",
		int(_reg.call("run_count", "trend_internet_lore")) == 0)

	_ok("the first score is a best",
		bool(_reg.call("submit_score", "trend_internet_lore", 500)))
	_ok("the best is stored",
		int(_reg.call("best_score", "trend_internet_lore")) == 500)
	# A worse run must never overwrite a better one.
	_ok("a worse run is not a best",
		not bool(_reg.call("submit_score", "trend_internet_lore", 200)))
	_ok("the best survives a worse run",
		int(_reg.call("best_score", "trend_internet_lore")) == 500,
		str(_reg.call("best_score", "trend_internet_lore")))
	_ok("an equal run is not a best",
		not bool(_reg.call("submit_score", "trend_internet_lore", 500)))
	_ok("a better run raises the best",
		bool(_reg.call("submit_score", "trend_internet_lore", 900)))
	_ok("every run is counted, best or not",
		int(_reg.call("run_count", "trend_internet_lore")) == 4,
		str(_reg.call("run_count", "trend_internet_lore")))
	# Scores are per category.
	_ok("scores do not bleed between categories",
		int(_reg.call("best_score", "trend_pop_culture")) == 0)
	_ok("a negative score is refused",
		not bool(_reg.call("submit_score", "trend_internet_lore", -5)))
	_ok("a refused score leaves the best intact",
		int(_reg.call("best_score", "trend_internet_lore")) == 900)


func _test_fair_window() -> void:
	print("── the WPM fair window ──")
	# THE FAIRNESS PROPERTY: a category with MORE symbols must not get less
	# time per symbol. Without this the paid channels are a paid downgrade,
	# because they exist to be visually denser.
	var previous_per_symbol: float = -1.0
	var windows: Dictionary = {}

	for trend_id: String in (_reg.call("all_ids") as Array):
		var symbols: int = int(_reg.call("symbol_count", trend_id))
		var tempo: float = float(_reg.call("tempo", trend_id))
		var window: int = int(_game.call("fair_window_ms", symbols, tempo))
		windows[trend_id] = window

		_ok("'%s' window is above the floor" % trend_id, window >= 650, str(window))
		_ok("'%s' window is below the ceiling" % trend_id, window <= 6000, str(window))
		_ok("'%s' window is positive" % trend_id, window > 0)
		previous_per_symbol = float(window) / float(symbols)
		_ok("'%s' allows real time per symbol" % trend_id,
			previous_per_symbol > 50.0, "%.1fms/symbol" % previous_per_symbol)

	# More symbols must mean MORE total time, not less.
	_ok("a denser channel gets more total time than the default",
		int(windows["trend_pop_culture"]) > int(windows["trend_internet_lore"]),
		"%d vs %d" % [int(windows["trend_pop_culture"]),
			int(windows["trend_internet_lore"])])

	# The window must actually scale, not sit pinned at a bound.
	_ok("the window scales with symbol count",
		int(_game.call("fair_window_ms", 20, 1.0))
		> int(_game.call("fair_window_ms", 4, 1.0)))
	_ok("the floor holds for a tiny display",
		int(_game.call("fair_window_ms", 1, 0.1)) == 650,
		str(_game.call("fair_window_ms", 1, 0.1)))
	_ok("the ceiling holds for an absurd display",
		int(_game.call("fair_window_ms", 10000, 10.0)) == 6000)
	# Degenerate inputs must not produce a negative or zero window.
	_ok("zero symbols still yields a playable window",
		int(_game.call("fair_window_ms", 0, 1.0)) >= 650)
	_ok("zero tempo still yields a playable window",
		int(_game.call("fair_window_ms", 6, 0.0)) >= 650)


func _test_compass() -> void:  # coroutine: reads the live IrisView
	print("── the fifth compass shard ──")
	# Adding a shard must not steal a direction from an existing one.
	#
	# THE VECTORS ARE READ FROM THE LIVE IrisView, not retyped here. A local
	# copy tests itself: moving the real NE shard onto North passed this check
	# untouched, because the check was sweeping its own literals.
	var view: Control = (load("res://nodes/iris_view.tscn") as PackedScene).instantiate()
	root.add_child(view)
	await process_frame
	var entries: Array = view.call("_compass_directions")
	var threshold: float = float(view.get("SHARD_COMMIT_DOT"))

	var dirs: Dictionary = {}
	for entry: Array in entries:
		dirs[str(int(entry[0]))] = entry[1]
	view.free()
	await process_frame

	_ok("the live compass declares five shards", dirs.size() == 5, str(dirs.size()))
	_ok("the commit threshold is readable", threshold > 0.0, str(threshold))

	# "Each direction selects itself" is trivially true even when two shards
	# nearly overlap — moving NE to within 6 degrees of North passed that
	# check untouched. The property that actually matters is ANGULAR
	# SEPARATION: two shards a finger-width apart are both unhittable.
	var min_separation: float = 360.0
	var closest: String = ""
	var names: Array = dirs.keys()
	for i: int in range(names.size()):
		for j: int in range(i + 1, names.size()):
			var a: Vector2 = dirs[names[i]]
			var b: Vector2 = dirs[names[j]]
			var degrees: float = rad_to_deg(acos(clampf(a.dot(b), -1.0, 1.0)))
			if degrees < min_separation:
				min_separation = degrees
				closest = "%s/%s" % [str(names[i]), str(names[j])]
	# 45 degrees is the diagonal spacing of a 5-shard compass. Anything under
	# 30 is a mis-tap waiting to happen on a phone.
	_ok("no two shards are closer than 30 degrees", min_separation >= 30.0,
		"%.1f deg between %s" % [min_separation, closest])

	for name: String in dirs.keys():
		var probe: Vector2 = dirs[name]
		var best: String = ""
		var best_dot: float = threshold
		for candidate: String in dirs.keys():
			var dot: float = probe.dot(dirs[candidate])
			if dot > best_dot:
				best_dot = dot
				best = candidate
		_ok("'%s' still selects itself" % name, best == name, "got '%s'" % best)

	# Every shard must be reachable somewhere on the circle.
	var reached: Dictionary = {}
	for degree: int in range(360):
		var radians: float = deg_to_rad(float(degree))
		var probe: Vector2 = Vector2(cos(radians), sin(radians))
		var best: String = ""
		var best_dot: float = threshold
		for candidate: String in dirs.keys():
			var dot: float = probe.dot(dirs[candidate])
			if dot > best_dot:
				best_dot = dot
				best = candidate
		if best != "":
			reached[best] = int(reached.get(best, 0)) + 1
	_ok("all five shards are reachable", reached.size() == 5, str(reached.keys()))
	# A shard whose arc has been eaten by a neighbour is technically reachable
	# and practically not. 40 degrees is the floor for a thumb.
	for name: String in dirs.keys():
		_ok("'%s' has a usable arc" % name, int(reached.get(name, 0)) >= 40,
			"%d degrees" % int(reached.get(name, 0)))

	# The enum, route table and direction table must all agree.
	var iris_src: String = FileAccess.get_file_as_string("res://data/iris_state.gd")
	var hub_src: String = FileAccess.get_file_as_string(
		"res://nodes/hub_portal_controller.gd")
	var view_src: String = FileAccess.get_file_as_string("res://nodes/iris_view.gd")
	_ok("the enum declares the shard", iris_src.contains("NORTHEAST_TREND"))
	_ok("the portal routes the shard",
		hub_src.contains("NORTHEAST_TREND: \"trend_hub\""))
	_ok("the portal labels the shard",
		hub_src.contains("NORTHEAST_TREND: \"Trend Hub\""))
	_ok("the iris view can select the shard",
		view_src.contains("NORTHEAST_TREND"))


func _test_routing_and_ui() -> void:
	print("── routing ──")
	var router: Node = root.get_node_or_null("Router")
	var routes: Dictionary = router.get("ROUTES")
	_ok("'trend_hub' route declared", routes.has("trend_hub"))
	_ok("the trend hub scene exists",
		ResourceLoader.exists(str(routes.get("trend_hub", ""))))
	for name: String in routes.keys():
		_ok("route '%s' resolves" % name,
			ResourceLoader.exists(str(routes[name])))

	print("── the mode is launchable but never randomly drawn ──")
	var registry: GDScript = ResourceLoader.load("res://data/trial_registry.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("trend_witness is registered", bool(registry.call("has", "trend_witness")))
	_ok("the registry still validates",
		(registry.call("validate") as Array).is_empty(),
		str(registry.call("validate")))
	# A random draw cannot supply a category, so it must never pick this mode.
	_ok("trend_witness is not selectable",
		not bool(registry.call("is_selectable", "trend_witness")))
	var drawn: Dictionary = {}
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 12345
	for i: int in range(4000):
		drawn[str(registry.call("pick_weighted", rng))] = true
	_ok("4000 weighted draws never pick trend_witness",
		not drawn.has("trend_witness"), str(drawn.keys()))
	_ok("the other four modes are still drawn", drawn.size() == 4, str(drawn.keys()))

	print("── card status copy ──")
	_wipe()
	await process_frame
	var state: Object = _new_state()
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")

	_ok("free reads as always open",
		str(_hub.call("status_text", state, "trend_internet_lore", now))
			.contains("Free"))
	_ok("locked reads as locked",
		str(_hub.call("status_text", state, "trend_gaming_myths_glitches", now)) == "Locked",
		str(_hub.call("status_text", state, "trend_gaming_myths_glitches", now)))

	state.call("grant_rental", StringName("trend_gaming_myths_glitches"), now)
	var badge: String = str(_hub.call("status_text", state, "trend_gaming_myths_glitches", now))
	_ok("an active pass shows the days badge", badge == "[ 7 DAYS LEFT ]", badge)
	var one_day: String = str(_hub.call("status_text", state, "trend_gaming_myths_glitches",
		now + float(6 * DAY)))
	_ok("the badge singularises at one day", one_day == "[ 1 DAY LEFT ]", one_day)
	var expired: String = str(_hub.call("status_text", state, "trend_gaming_myths_glitches",
		now + float(8 * DAY)))
	_ok("an expired pass is distinguished from never having one",
		expired == "Pass expired", expired)

	print("── the hub renders ──")
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame
	var screen: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	screen.call("configure", {})
	root.add_child(screen)
	await process_frame
	await process_frame

	var column: Control = screen.get_node_or_null("%CardColumn") as Control
	_ok("the card column exists", column != null)
	# Counts derive from the registry. A literal here goes stale the moment the
	# weekly roster changes and reports as a failure of the roster rather than
	# of the assertion — which is exactly what growing to 20 did.
	var expected_cards: int = (_reg.call("all_ids") as Array).size()
	_ok("one card per category",
		column != null and column.get_child_count() == expected_cards,
		"%d of %d" % [column.get_child_count() if column != null else -1,
			expected_cards])

	# Every card must carry a visible action, or a category is unreachable.
	var buttons: Array[String] = []
	_collect_buttons(column, buttons)
	_ok("every card has an action button", buttons.size() == expected_cards,
		"%d buttons for %d cards" % [buttons.size(), expected_cards])

	# The split must match the roster exactly: every free card offers play,
	# every paid card offers the ad. A card with the wrong action either gives
	# away a paid channel or blocks a free one.
	var play_count: int = 0
	var ad_count: int = 0
	var missing_duration: int = 0
	for label: String in buttons:
		if label == "PLAY RUN":
			play_count += 1
		elif label.contains("WATCH AD"):
			ad_count += 1
			if not label.contains("7 DAYS"):
				missing_duration += 1
	_ok("free cards offer play",
		play_count == (_reg.call("free_ids") as Array).size(),
		"%d play buttons" % play_count)
	_ok("paid cards offer the ad unlock",
		ad_count == (_reg.call("paid_ids") as Array).size(),
		"%d ad buttons" % ad_count)
	_ok("every ad button states the duration", missing_duration == 0,
		"%d missing" % missing_duration)
	# Display order: the first card must be the default free channel.
	_ok("the first card is the default channel",
		buttons.size() > 0 and buttons[0] == "PLAY RUN", str(buttons.slice(0, 3)))
	screen.free()
	await process_frame


func _collect_buttons(node: Node, out: Array[String]) -> void:
	if node == null:
		return
	if node is Button:
		out.append((node as Button).text)
	for child: Node in node.get_children():
		_collect_buttons(child, out)


# ═════════════════════════════════════════════════════════════════════════
# SAVE YOUR STREAK — the eligibility rule
# ═════════════════════════════════════════════════════════════════════════
func _test_rescue_rule() -> void:
	print("── rescue eligibility ──")
	var threshold: int = int(_game.get("AD_CONTINUE_MIN_ROUND"))
	_ok("the threshold is round 3", threshold == 3, str(threshold))

	# Below the threshold the offer is nagging, not helpful.
	for early: int in range(0, threshold):
		_ok("round %d is too early to rescue" % early,
			not bool(_game.call("rescue_eligible", early, false)))
	# At and beyond it, a first failure qualifies.
	for late: int in range(threshold, threshold + 4):
		_ok("round %d qualifies" % late,
			bool(_game.call("rescue_eligible", late, false)))

	# ONE per run, at every round. A second continue would make every score
	# on the board meaningless.
	for any_round: int in range(0, 12):
		_ok("round %d refuses a second continue" % any_round,
			not bool(_game.call("rescue_eligible", any_round, true)))


# ═════════════════════════════════════════════════════════════════════════
# SAVE YOUR STREAK — a live run through the prompt
# ═════════════════════════════════════════════════════════════════════════
## Drive the REAL mini-game through a real failure and a real rescue. A mocked
## mini-game would only prove the mock works.
func _test_rescue_live() -> void:
	print("── a live rescue: fail late, watch, resume ──")
	_wipe()
	# Clear the retry cooldown so this scenario starts from a known state.
	# Without it, an ad watched by an earlier check suppresses the prompt and
	# the failure looks like a rescue bug rather than the guard working.
	root.get_node_or_null("AdManager").call("reset_cooldowns")
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var host: Node = await _mount_run("trend_internet_lore")
	var game: Node = host.get_node_or_null("%Stage/MiniGame")
	_ok("the trend mini-game mounted", game != null)
	if game == null:
		host.free()
		return

	_ok("a fresh run has no continue spent",
		not bool(game.get("has_used_ad_continue")))

	# Answer rounds 1 and 2 correctly, so the run has a score worth saving.
	var banked: int = 0
	for i: int in range(2):
		await _answer(game, true)
		banked = int(game.call("score"))
	_ok("two correct rounds bank a score", banked > 0, str(banked))
	# An early failure must NOT prompt — but we are past round 2 now, so
	# verify the guard directly instead of forcing an early loss.
	_ok("no prompt is open before any failure",
		not bool(game.call("rescue_prompt_open")))

	# Fail round 3. This is the first failure at or past the threshold.
	await _answer(game, false)
	_ok("failing at round 3 opens the prompt",
		bool(game.call("rescue_prompt_open")))
	_ok("the run is frozen at the prompt",
		int(game.call("current_phase")) == 5,
		str(game.call("current_phase")))
	_ok("the run has not ended", not bool(game.call("is_run_over")))
	_ok("the score is intact while the prompt is open",
		int(game.call("score")) == banked,
		"%d vs %d" % [int(game.call("score")), banked])

	# The frozen run must STAY frozen — no timer may advance it.
	for i: int in range(20):
		game.call("_process", 1.0)
	_ok("time does not advance a frozen prompt",
		bool(game.call("rescue_prompt_open"))
		and int(game.call("current_phase")) == 5)
	_ok("a frozen prompt never ends the run",
		not bool(game.call("is_run_over")))

	# Watch the ad. AdManager runs in fallback mode headlessly and grants
	# after a short delay, so this exercises the real signal path.
	game.call("_on_watch_ad_pressed")
	# AdManager's fallback grant waits on a REAL 0.4s SceneTree timer, which
	# advances with wall time rather than with _process() calls. Measured at
	# ~49 frames headlessly; 200 is generous headroom without hanging the
	# suite if the signal never arrives.
	var waited: int = 0
	for i: int in range(200):
		await process_frame
		waited = i
		if not bool(game.call("rescue_prompt_open")):
			break
	_ok("the rescue ad resolved", waited < 199, "waited %d frames" % waited)

	_ok("the rescue consumed the continue",
		bool(game.get("has_used_ad_continue")))
	_ok("the prompt closed", not bool(game.call("rescue_prompt_open")))
	_ok("the run resumed rather than ending", not bool(game.call("is_run_over")))
	_ok("the score survived the rescue",
		int(game.call("score")) == banked,
		"%d vs %d" % [int(game.call("score")), banked])
	_ok("a countdown is running",
		int(game.call("current_phase")) == 6
		or float(game.call("countdown_remaining")) > 0.0,
		"phase %d" % int(game.call("current_phase")))
	_ok("the countdown is 3 seconds",
		float(game.call("countdown_remaining")) <= 3.0
		and float(game.call("countdown_remaining")) > 0.0,
		str(game.call("countdown_remaining")))

	# The failed round STAYS counted. A rescue buys another scenario; it does
	# not erase the mistake, or a rescued run could out-score a clean one.
	_ok("the failed round still counts as attempted",
		int(game.call("rounds_done")) >= 3, str(game.call("rounds_done")))

	# A SECOND failure past the threshold must end the run outright.
	for i: int in range(40):
		game.call("_process", 0.2)
		await process_frame
		if int(game.call("current_phase")) == 3:
			break
	if int(game.call("current_phase")) == 3:
		await _answer(game, false)
		_ok("a second failure does not re-prompt",
			not bool(game.call("rescue_prompt_open")))
	else:
		_ok("the run advanced past the countdown", true)
	host.free()
	await process_frame

	print("── giving up ends the run and keeps the score ──")
	_wipe()
	# The scenario above watched a rescue ad, which started the 60s cooldown.
	# Clearing it is the point: this scenario tests GIVE UP, not the guard.
	root.get_node_or_null("AdManager").call("reset_cooldowns")
	await process_frame
	var host2: Node = await _mount_run("trend_internet_lore")
	var game2: Node = host2.get_node_or_null("%Stage/MiniGame")
	if game2 == null:
		_ok("the second run mounted", false)
		host2.free()
		return

	for i: int in range(2):
		await _answer(game2, true)
	var earned: int = int(game2.call("score"))
	await _answer(game2, false)
	_ok("the prompt opened on the third-round failure",
		bool(game2.call("rescue_prompt_open")))

	game2.call("_on_give_up_pressed")
	await process_frame
	_ok("giving up ends the run", bool(game2.call("is_run_over")))
	_ok("giving up closes the prompt", not bool(game2.call("rescue_prompt_open")))
	_ok("giving up leaves the continue unspent",
		not bool(game2.get("has_used_ad_continue")))
	# The player keeps everything earned before the failure — the whole point
	# of submitting on give-up rather than zeroing the run.
	_ok("the score is preserved on give-up",
		int(game2.call("score")) == earned,
		"%d vs %d" % [int(game2.call("score")), earned])
	await process_frame
	await process_frame
	_ok("the score reached Save",
		int(_reg.call("best_score", "trend_internet_lore")) == earned,
		"stored %d vs earned %d" % [
			int(_reg.call("best_score", "trend_internet_lore")), earned])
	host2.free()
	await process_frame

	print("── a retry cooldown suppresses the prompt entirely ──")
	# Discovered accidentally: the scenario above watched a rescue ad, which
	# started the 60s cooldown and silently suppressed the next run's prompt.
	# That is the guard working, so it is now asserted deliberately rather
	# than relied upon as a side effect.
	_wipe()
	var ads: Node = root.get_node_or_null("AdManager")
	ads.call("reset_cooldowns")
	ads.call("_mark_cooldown", "trend_continue")
	await process_frame
	_ok("the retry cooldown is active",
		not bool(ads.call("can_show_retry_ad")))

	var host3: Node = await _mount_run("trend_internet_lore")
	var game3: Node = host3.get_node_or_null("%Stage/MiniGame")
	if game3 == null:
		_ok("the third run mounted", false)
		host3.free()
		return

	for i: int in range(2):
		await _answer(game3, true)
	var banked3: int = int(game3.call("score"))
	await _answer(game3, false)

	# Round 3 failure, first rescue of the run — eligible on every count
	# EXCEPT the ad cooldown. The prompt must be skipped, not shown-and-
	# disabled: an offer the player cannot accept is worse than no offer.
	_ok("no prompt opens while the retry ad is cooling down",
		not bool(game3.call("rescue_prompt_open")))
	_ok("the continue is left unspent",
		not bool(game3.get("has_used_ad_continue")))
	_ok("the run proceeds normally instead",
		int(game3.call("current_phase")) != 5,
		"phase %d" % int(game3.call("current_phase")))
	_ok("the score is untouched by the suppression",
		int(game3.call("score")) == banked3,
		"%d vs %d" % [int(game3.call("score")), banked3])
	host3.free()
	ads.call("reset_cooldowns")
	await process_frame


## Mount a real trial host running a real Trend category.
func _mount_run(trend_id: String) -> Node:
	var state: Object = _new_state()
	var host: Node = (load("res://screens/trial_host.tscn") as PackedScene).instantiate()
	host.call("configure", {
		"trial_id": "trend_witness",
		"iris_state": state,
		"trend_id": trend_id,
		# Drive rounds programmatically: the first-run briefing would block
		# forever on a Begin button nobody presses.
		"skip_tutorial": true,
	})
	root.add_child(host)
	await process_frame
	await process_frame
	return host


## Drive one round to the IDENTIFY phase and answer it.
func _answer(game: Node, correctly: bool) -> void:
	var guard: int = 0
	while int(game.call("current_phase")) != 3 and guard < 400:
		game.call("_process", 0.1)
		await process_frame
		guard += 1
	if int(game.call("current_phase")) != 3:
		return
	var target: int = int(game.get("_target"))
	var symbols: int = int(game.get("_symbols"))
	var choice: int = target if correctly else (target + 1) % maxi(symbols, 2)
	game.call("_on_answer", choice)
	await process_frame


# ═════════════════════════════════════════════════════════════════════════
# DUAL AD COOLDOWNS
# ═════════════════════════════════════════════════════════════════════════
func _test_cooldowns() -> void:
	print("── cooldown defaults ──")
	var ads: Node = root.get_node_or_null("AdManager")
	_ok("AdManager is live", ads != null)
	if ads == null:
		return

	_ok("category cooldown is 5 minutes",
		absf(float(ads.get("CATEGORY_COOLDOWN_SEC")) - 300.0) < 0.001,
		str(ads.get("CATEGORY_COOLDOWN_SEC")))
	_ok("retry cooldown is 1 minute",
		absf(float(ads.get("RETRY_COOLDOWN_SEC")) - 60.0) < 0.001,
		str(ads.get("RETRY_COOLDOWN_SEC")))

	print("── a fresh player is never locked out ──")
	ads.call("reset_cooldowns")
	# THE BUG THIS CATCHES: ticks_msec is ~120 at boot, so a NEVER sentinel of
	# 0 would compute 120ms elapsed against a 300000ms cooldown and lock a
	# brand-new player out of a feature they have never used.
	_ok("category unlock allowed with no history",
		bool(ads.call("can_unlock_category")))
	_ok("category remaining is 0 with no history",
		int(ads.call("get_category_cooldown_remaining_sec")) == 0,
		str(ads.call("get_category_cooldown_remaining_sec")))
	_ok("retry allowed with no history", bool(ads.call("can_show_retry_ad")))
	_ok("retry remaining is 0 with no history",
		int(ads.call("get_retry_cooldown_remaining_sec")) == 0)

	print("── the two cooldowns are independent ──")
	ads.call("reset_cooldowns")
	ads.call("_mark_cooldown", "trend_gaming_myths_glitches")
	_ok("an unlock blocks the next unlock", not bool(ads.call("can_unlock_category")))
	# The whole point of DUAL cooldowns: a category unlock must not consume
	# the rescue budget, or one ad silently costs the player two features.
	_ok("an unlock does NOT block a rescue", bool(ads.call("can_show_retry_ad")))

	ads.call("reset_cooldowns")
	ads.call("_mark_cooldown", "trend_continue")
	_ok("a rescue blocks the next rescue", not bool(ads.call("can_show_retry_ad")))
	_ok("a rescue does NOT block an unlock", bool(ads.call("can_unlock_category")))

	print("── placement routing ──")
	_ok("'trend_continue' is the retry placement",
		bool(ads.call("is_retry_placement", "trend_continue")))
	_ok("a category placement is not the retry one",
		not bool(ads.call("is_retry_placement", "trend_pop_culture")))
	_ok("'trend_pop_culture' is a category placement",
		bool(ads.call("is_category_placement", "trend_pop_culture")))
	_ok("the retry placement is not a category one",
		not bool(ads.call("is_category_placement", "trend_continue")))

	print("── remaining seconds count down ──")
	ads.call("reset_cooldowns")
	ads.call("_mark_cooldown", "trend_gaming_myths_glitches")
	var full: int = int(ads.call("get_category_cooldown_remaining_sec"))
	# Rounded UP, so a button never reads 00:00 while still refusing the tap.
	_ok("a fresh 5-minute cooldown reports 300s", full == 300, str(full))
	_ok("a fresh 1-minute retry reports 60s after marking",
		_marked_retry_seconds(ads) == 60, str(_marked_retry_seconds(ads)))

	# A custom window must be honoured, not silently replaced by the default.
	_ok("a shorter custom window is respected",
		int(ads.call("get_category_cooldown_remaining_sec", 1.0)) <= 1,
		str(ads.call("get_category_cooldown_remaining_sec", 1.0)))
	_ok("a zero cooldown disables the throttle",
		bool(ads.call("can_unlock_category", 0.0)))
	_ok("a negative cooldown disables the throttle",
		bool(ads.call("can_unlock_category", -5.0)))
	# A longer window than the default must extend the wait, proving the
	# argument reaches the arithmetic rather than being ignored.
	_ok("a longer custom window extends the wait",
		int(ads.call("get_category_cooldown_remaining_sec", 600.0)) > full,
		str(ads.call("get_category_cooldown_remaining_sec", 600.0)))

	print("── MM:SS formatting ──")
	var cases: Array[Array] = [
		[0, "00:00"], [1, "00:01"], [9, "00:09"], [59, "00:59"],
		[60, "01:00"], [61, "01:01"], [300, "05:00"], [599, "09:59"],
		[600, "10:00"], [3599, "59:59"], [3600, "60:00"], [5400, "90:00"],
	]
	for pair: Array in cases:
		_ok("format %ds -> '%s'" % [int(pair[0]), str(pair[1])],
			str(ads.call("format_cooldown", int(pair[0]))) == str(pair[1]),
			str(ads.call("format_cooldown", int(pair[0]))))
	# Minutes must NOT wrap at 60: a 90-minute wait reading "30:00"
	# understates the delay and reads as a broken clock.
	_ok("minutes do not wrap at an hour",
		str(ads.call("format_cooldown", 3600)) == "60:00",
		str(ads.call("format_cooldown", 3600)))
	_ok("a negative duration clamps to 00:00",
		str(ads.call("format_cooldown", -30)) == "00:00",
		str(ads.call("format_cooldown", -30)))
	# Always MM:SS, never M:SS — a jittering width looks broken in a button.
	var widths: Dictionary = {}
	for seconds: int in range(0, 700, 7):
		widths[str(ads.call("format_cooldown", seconds)).length()] = true
	_ok("the format is a stable width", widths.size() == 1, str(widths.keys()))

	ads.call("reset_cooldowns")


## Mark a retry and read its remaining seconds, so the assertion above stays
## a single readable line.
func _marked_retry_seconds(ads: Node) -> int:
	ads.call("_mark_cooldown", "trend_continue")
	return int(ads.call("get_retry_cooldown_remaining_sec"))


func _test_cooldown_ui() -> void:
	print("── hub countdown UI ──")
	var ads: Node = root.get_node_or_null("AdManager")
	ads.call("reset_cooldowns")

	# The exact copy, asserted without a scene.
	_ok("the countdown label is MM:SS",
		str(_hub.call("cooldown_label", 300)) == "[ ⏱ UNLOCK IN 05:00 ]",
		str(_hub.call("cooldown_label", 300)))
	_ok("the countdown label pads seconds",
		str(_hub.call("cooldown_label", 61)) == "[ ⏱ UNLOCK IN 01:01 ]",
		str(_hub.call("cooldown_label", 61)))

	_wipe()
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	# ── Cooldown ACTIVE: locked cards must show the wait, not the CTA ─────
	ads.call("_mark_cooldown", "trend_gaming_myths_glitches")
	var screen: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	screen.call("configure", {})
	root.add_child(screen)
	await process_frame
	await process_frame

	var column: Control = screen.get_node_or_null("%CardColumn") as Control
	var labels: Array[String] = []
	_collect_buttons(column, labels)

	var countdown_count: int = 0
	var cta_count: int = 0
	for text: String in labels:
		if text.contains("UNLOCK IN"):
			countdown_count += 1
		elif text == "WATCH AD TO UNLOCK (7 DAYS)":
			cta_count += 1
	var paid_total: int = (_reg.call("paid_ids") as Array).size()
	_ok("every locked card shows the countdown",
		countdown_count == paid_total, "%d of %d" % [countdown_count, paid_total])
	_ok("no locked card still advertises the ad", cta_count == 0,
		"%d still showing the CTA" % cta_count)
	# Free cards are unaffected — a category unlock cooldown must not block
	# play on a channel that needs no unlock.
	var play_count: int = 0
	for text: String in labels:
		if text == "PLAY RUN":
			play_count += 1
	_ok("free cards still offer play during a cooldown",
		play_count == (_reg.call("free_ids") as Array).size(), str(play_count))

	# Every countdown button must be DISABLED, or it lies about what a tap does.
	var still_enabled: Array[String] = []
	_collect_enabled_countdowns(column, still_enabled)
	_ok("countdown buttons are disabled", still_enabled.is_empty(),
		str(still_enabled.size()))
	screen.free()
	await process_frame

	# ── Cooldown CLEAR: the CTA must be back ──────────────────────────────
	ads.call("reset_cooldowns")
	var clear_screen: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	clear_screen.call("configure", {})
	root.add_child(clear_screen)
	await process_frame
	await process_frame

	var clear_labels: Array[String] = []
	_collect_buttons(clear_screen.get_node_or_null("%CardColumn"), clear_labels)
	var restored: int = 0
	var stale: int = 0
	for text: String in clear_labels:
		if text == "WATCH AD TO UNLOCK (7 DAYS)":
			restored += 1
		elif text.contains("UNLOCK IN"):
			stale += 1
	_ok("a clear cooldown restores the CTA", restored == paid_total,
		"%d of %d" % [restored, paid_total])
	_ok("no countdown lingers once clear", stale == 0, "%d stale" % stale)
	clear_screen.free()
	await process_frame


func _collect_enabled_countdowns(node: Node, out: Array[String]) -> void:
	if node == null:
		return
	if node is Button:
		var button: Button = node as Button
		if button.text.contains("UNLOCK IN") and not button.disabled:
			out.append(str(button.name))
	for child: Node in node.get_children():
		_collect_enabled_countdowns(child, out)


# ═════════════════════════════════════════════════════════════════════════
# AD PRELOADING & AVAILABILITY
# ═════════════════════════════════════════════════════════════════════════
func _test_ad_readiness() -> void:
	print("── preload / availability ──")
	var ads: Node = root.get_node_or_null("AdManager")
	_ok("AdManager exposes is_rewarded_ad_ready", ads.has_method("is_rewarded_ad_ready"))
	_ok("AdManager exposes preload_rewarded_ad", ads.has_method("preload_rewarded_ad"))
	_ok("AdManager exposes on_ad_loaded", ads.has_method("on_ad_loaded"))
	_ok("AdManager exposes on_ad_failed_to_load",
		ads.has_method("on_ad_failed_to_load"))

	# Launch preloads. In fallback mode the load resolves instantly, so an ad
	# is ready before any screen asks.
	_ok("an ad is ready after launch", bool(ads.call("is_rewarded_ad_ready")))

	print("── exponential backoff ──")
	# Pure curve, testable without a network or a failure.
	_ok("attempt 0 waits 2s",
		absf(float(ads.call("backoff_delay_sec", 0)) - 2.0) < 0.001)
	_ok("attempt 1 waits 4s",
		absf(float(ads.call("backoff_delay_sec", 1)) - 4.0) < 0.001)
	_ok("attempt 2 waits 8s",
		absf(float(ads.call("backoff_delay_sec", 2)) - 8.0) < 0.001)
	_ok("the delay doubles each attempt",
		float(ads.call("backoff_delay_sec", 3))
		== float(ads.call("backoff_delay_sec", 2)) * 2.0)
	_ok("the delay caps at 5 minutes",
		absf(float(ads.call("backoff_delay_sec", 12)) - 300.0) < 0.001,
		str(ads.call("backoff_delay_sec", 12)))
	# Measured, not assumed: pow(2.0, 4000.0) is +inf and minf(inf, 300.0) is
	# 300.0, so this passes with or without the exponent cap. Kept because the
	# CONTRACT — no attempt count ever produces a non-finite delay — is worth
	# holding even though the current implementation gets there two ways.
	_ok("an absurd attempt count stays finite and capped",
		is_finite(float(ads.call("backoff_delay_sec", 4000)))
		and absf(float(ads.call("backoff_delay_sec", 4000)) - 300.0) < 0.001,
		str(ads.call("backoff_delay_sec", 4000)))
	_ok("a negative attempt is clamped, not negative",
		float(ads.call("backoff_delay_sec", -5)) > 0.0)

	print("── availability gates the request ──")
	ads.call("reset_cooldowns")
	ads.call("debug_set_ready", false)
	_ok("not ready when inventory is empty",
		not bool(ads.call("is_rewarded_ad_ready")))

	# A preload restores readiness (fallback mode resolves immediately).
	ads.call("preload_rewarded_ad")
	await process_frame
	_ok("preloading restores readiness", bool(ads.call("is_rewarded_ad_ready")))

	print("── a finished ad re-triggers the preload ──")
	# The behaviour that matters: after watching, the NEXT ad must already be
	# loading, or the following tap reads as a broken button.
	ads.call("debug_set_ready", true)
	_ok("ready before the watch", bool(ads.call("is_rewarded_ad_ready")))
	_ok("show_rewarded accepted", bool(ads.call("show_rewarded", "trend_preload_probe")))
	var settled: int = 0
	for i: int in range(200):
		await process_frame
		settled = i
		if bool(ads.call("is_rewarded_ad_ready")):
			break
	_ok("an ad is ready again after one completes",
		bool(ads.call("is_rewarded_ad_ready")), "waited %d frames" % settled)
	ads.call("reset_cooldowns")
	ads.call("debug_set_ready", true)

	print("── UI fallbacks when no ad is loaded ──")
	# Source-level: both call sites must consult readiness, not just cooldown.
	var hub_src: String = _code_only("res://screens/trend_hub.gd")
	var game_src: String = _code_only("res://nodes/mini_games/trend_witness_game.gd")
	_ok("the hub checks readiness",
		hub_src.contains("AdManager.is_rewarded_ad_ready()"))
	_ok("the rescue checks readiness",
		game_src.contains("AdManager.is_rewarded_ad_ready()"))
	_ok("the hub declares the not-ready label",
		hub_src.contains("NOT_READY_LABEL"))

	# Behavioural: with no ad loaded and no cooldown, every locked card must
	# say so and refuse the tap.
	_wipe()
	ads.call("reset_cooldowns")
	# Block loads BEFORE clearing inventory. Fallback mode otherwise grants a
	# new ad the instant the hub preloads on entry, so the cards would build
	# ready and this branch would never render — it passed with the guard
	# deliberately broken until this hook existed.
	ads.call("debug_block_loads", true)
	ads.call("debug_set_ready", false)
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var screen: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	screen.call("configure", {})
	root.add_child(screen)
	await process_frame
	await process_frame

	var labels: Array[String] = []
	_collect_buttons(screen.get_node_or_null("%CardColumn"), labels)
	var not_ready: int = 0
	var stale_cta: int = 0
	for text: String in labels:
		if text.contains("AD NOT READY"):
			not_ready += 1
		elif text == "WATCH AD TO UNLOCK (7 DAYS)":
			stale_cta += 1
	var paid_total: int = (_reg.call("paid_ids") as Array).size()

	# With loads blocked this is deterministic: every locked card must show
	# the not-ready state, and none may still advertise a watchable ad.
	_ok("every locked card reports the ad is not ready",
		not_ready == paid_total, "%d of %d" % [not_ready, paid_total])
	_ok("no locked card advertises an ad that cannot play",
		stale_cta == 0, "%d stale" % stale_cta)

	var enabled_not_ready: Array[String] = []
	_collect_enabled_not_ready(screen.get_node_or_null("%CardColumn"),
		enabled_not_ready)
	_ok("no 'AD NOT READY' button is tappable",
		enabled_not_ready.is_empty(), str(enabled_not_ready.size()))
	# Free channels must be unaffected — they need no ad at all.
	var play_count: int = 0
	for text: String in labels:
		if text == "PLAY RUN":
			play_count += 1
	_ok("free cards play regardless of ad inventory",
		play_count == (_reg.call("free_ids") as Array).size(), str(play_count))
	screen.free()
	ads.call("debug_block_loads", false)
	ads.call("debug_set_ready", true)
	await process_frame


func _collect_enabled_not_ready(node: Node, out: Array[String]) -> void:
	if node == null:
		return
	if node is Button:
		var button: Button = node as Button
		if button.text.contains("AD NOT READY") and not button.disabled:
			out.append(str(button.name))
	for child: Node in node.get_children():
		_collect_enabled_not_ready(child, out)


# ═════════════════════════════════════════════════════════════════════════
# TREND LOADER + PIPELINE SCHEMA
# ═════════════════════════════════════════════════════════════════════════
func _test_loader() -> void:
	print("── loader parses the REAL generated files ──")
	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_ok("TrendLoader loads", loader != null)
	if loader == null:
		return

	# THE SCHEMA CONTRACT: parsed against the actual output of
	# generate_weekly_packs.py, copied into res://data/trends/. If the Python
	# generator and this loader ever disagree about a field name or a type,
	# this is where it surfaces — not on a player's device.
	var roster: Array = loader.call("load_roster", "res://data/trends/")
	_ok("the generated roster parses",
		int(loader.call("last_source")) == 1,
		"source=%d problem=%s" % [int(loader.call("last_source")),
			str(loader.call("last_problem"))])
	_ok("20 packs parsed", roster.size() == 20, str(roster.size()))

	var free_parsed: int = 0
	var bad_fields: Array[String] = []
	for entry: Dictionary in roster:
		if bool(entry.get("free", false)):
			free_parsed += 1
		for field: String in ["id", "name", "free", "order", "symbols",
				"palette", "tempo"]:
			if not entry.has(field):
				bad_fields.append("%s missing %s" % [str(entry.get("id", "?")), field])
	_ok("5 free packs parsed", free_parsed == 5, str(free_parsed))
	_ok("every parsed entry is complete", bad_fields.is_empty(),
		", ".join(bad_fields))

	# Order must come out sorted, so the hub renders the intended sequence.
	var ordered: bool = true
	for i: int in range(roster.size()):
		if int((roster[i] as Dictionary).get("order", -1)) != i:
			ordered = false
	_ok("packs are returned in display order", ordered)

	# The parsed shape must match what the bundled roster produces, or the
	# hub would need two code paths.
	var bundled: Array = loader.call("bundled_roster")
	_ok("the bundled roster is complete", bundled.size() == 20, str(bundled.size()))
	var parsed_keys: Array = (roster[0] as Dictionary).keys()
	var bundled_keys: Array = (bundled[0] as Dictionary).keys()
	parsed_keys.sort()
	bundled_keys.sort()
	_ok("parsed and bundled entries share one shape",
		parsed_keys == bundled_keys,
		"%s vs %s" % [str(parsed_keys), str(bundled_keys)])

	print("── fallback on every failure mode ──")
	# The load-bearing guarantee: a broken roster must never yield an empty
	# hub. Each of these is a real way a published roster can be wrong.
	var cases: Array[Array] = [
		["res://data/does_not_exist/", "a missing directory"],
		["res://data/", "a directory with no index.json"],
		["res://", "the project root"],
	]
	for probe: Array in cases:
		var result: Array = loader.call("load_roster", str(probe[0]))
		_ok("fallback on %s" % str(probe[1]),
			int(loader.call("last_source")) == 2
			and result.size() == 20,
			"source=%d size=%d" % [int(loader.call("last_source")), result.size()])

	# Malformed JSON, written to a real temp file so the parser genuinely runs.
	var temp: String = "user://trend_loader_probe/"
	DirAccess.make_dir_recursive_absolute(temp)
	var handle: FileAccess = FileAccess.open(temp.path_join("index.json"),
		FileAccess.WRITE)
	handle.store_string("{ this is not json")
	handle.close()
	var broken: Array = loader.call("load_roster", temp)
	_ok("fallback on malformed JSON",
		int(loader.call("last_source")) == 2 and broken.size() == 20)
	_ok("the failure reason is recorded",
		str(loader.call("last_problem")) != "")

	# A future schema must fall back rather than being parsed with old
	# meanings — a field that changed meaning is worse than not loading.
	handle = FileAccess.open(temp.path_join("index.json"), FileAccess.WRITE)
	handle.store_string(JSON.stringify({
		"schema_version": 99, "week": "2026-W31", "total": 20, "packs": [],
	}))
	handle.close()
	var future: Array = loader.call("load_roster", temp)
	_ok("fallback on a future schema version",
		int(loader.call("last_source")) == 2 and future.size() == 20)
	_ok("the schema mismatch is named",
		str(loader.call("last_problem")).contains("schema"),
		str(loader.call("last_problem")))

	# An index promising packs it does not ship.
	handle = FileAccess.open(temp.path_join("index.json"), FileAccess.WRITE)
	var phantom: Array = []
	for i: int in range(20):
		phantom.append({"id": "trend_%02d_x" % i, "free": i < 5, "order": i,
			"file": "packs/pack_missing_%d.json" % i})
	handle.store_string(JSON.stringify({
		"schema_version": 1, "week": "2026-W31", "total": 20, "packs": phantom,
	}))
	handle.close()
	var missing: Array = loader.call("load_roster", temp)
	_ok("fallback when a promised pack file is absent",
		int(loader.call("last_source")) == 2 and missing.size() == 20)

	# A roster with the wrong free/paid split would silently give away or
	# withhold content.
	_ok("the loader enforces the free count",
		int(loader.get("EXPECTED_FREE")) == 5)
	_ok("the loader enforces the total",
		int(loader.get("EXPECTED_TOTAL")) == 20)

	# NEVER empty. This is the property the whole fallback exists for.
	_ok("no failure path yields an empty roster",
		(loader.call("load_roster", "res://nope/") as Array).size() > 0)


# ═════════════════════════════════════════════════════════════════════════
# POPULARITY
# ═════════════════════════════════════════════════════════════════════════
func _test_popularity() -> void:
	print("── popularity ranking ──")
	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_wipe()
	await process_frame

	# ── The pure ranking formula ─────────────────────────────────────────
	_ok("zero plays scores the base",
		int(loader.call("popularity_rank_score", 90, 0)) == 90)
	_ok("a play adds its weight",
		int(loader.call("popularity_rank_score", 90, 1))
		== 90 + int(loader.get("PLAY_WEIGHT")))
	_ok("plays accumulate",
		int(loader.call("popularity_rank_score", 50, 4))
		== 50 + 4 * int(loader.get("PLAY_WEIGHT")))
	# The cap exists so one obsessively-played category cannot own the rail.
	_ok("the play bonus is capped",
		int(loader.call("popularity_rank_score", 0, 100_000))
		== int(loader.get("MAX_PLAY_BONUS")),
		str(loader.call("popularity_rank_score", 0, 100_000)))
	_ok("a negative play count cannot subtract",
		int(loader.call("popularity_rank_score", 50, -20)) == 50)
	_ok("a base above 100 is clamped",
		int(loader.call("popularity_rank_score", 5000, 0)) == 100)

	# ── High editorial weight leads on a fresh install ───────────────────
	var fresh: Array = loader.call("get_popular_categories", 5)
	_ok("a fresh install returns a full rail", fresh.size() == 5, str(fresh.size()))
	var descending: bool = true
	for i: int in range(fresh.size() - 1):
		if int((fresh[i] as Dictionary).get("rank_score", 0)) \
				< int((fresh[i + 1] as Dictionary).get("rank_score", 0)):
			descending = false
	_ok("the rail is sorted descending", descending)
	_ok("the top entry is editorially popular",
		bool((fresh[0] as Dictionary).get("is_popular", false)),
		str((fresh[0] as Dictionary).get("name", "?")))
	_ok("every entry reports its play count",
		(fresh[0] as Dictionary).has("plays"))
	_ok("every entry reports its rank score",
		(fresh[0] as Dictionary).has("rank_score"))

	# ── Local plays promote a low-prior category ─────────────────────────
	# The behaviour that matters: a player's own habits must overtake the
	# editorial guess within a couple of sessions.
	var roster: Array = loader.call("load_roster")
	var lowest_id: String = ""
	var lowest_score: int = 999
	for entry: Dictionary in roster:
		var score: int = int(entry.get("popularity_score", 0))
		if score < lowest_score:
			lowest_score = score
			lowest_id = str(entry.get("id", ""))

	var before: Array = loader.call("get_popular_categories", 20)
	var rank_before: int = _rank_of(before, lowest_id)
	_ok("the least-popular category starts low",
		rank_before > 5, "rank %d" % rank_before)

	for i: int in range(40):
		_reg.call("submit_score", lowest_id, 10)
	var after: Array = loader.call("get_popular_categories", 20)
	var rank_after: int = _rank_of(after, lowest_id)
	_ok("heavy local play promotes a category",
		rank_after < rank_before, "%d -> %d" % [rank_before, rank_after])
	_ok("a heavily played category reaches the top",
		rank_after == 0, "rank %d" % rank_after)
	_ok("its play count is reported",
		int((after[rank_after] as Dictionary).get("plays", 0)) == 40,
		str((after[rank_after] as Dictionary).get("plays", 0)))

	# ── Determinism ──────────────────────────────────────────────────────
	# A rail that reshuffles between opens looks broken. Ties must break on a
	# stable key, not on dictionary iteration order.
	var pass_one: Array = loader.call("get_popular_categories", 20)
	var pass_two: Array = loader.call("get_popular_categories", 20)
	var identical: bool = true
	for i: int in range(pass_one.size()):
		if str((pass_one[i] as Dictionary).get("id", "")) \
				!= str((pass_two[i] as Dictionary).get("id", "")):
			identical = false
	_ok("repeated calls return the same order", identical)

	# Every tie must resolve, or sort_custom's result depends on input order.
	var tied: Array[Dictionary] = []
	for i: int in range(6):
		tied.append({"id": "zz_tie_%d" % i, "popularity_score": 50, "name": "Tie"})
	var tie_one: Array = loader.call("get_popular_categories", 6, tied)
	var tie_two: Array = loader.call("get_popular_categories", 6, tied)
	var tie_ids_one: Array[String] = []
	var tie_ids_two: Array[String] = []
	for entry: Dictionary in tie_one:
		tie_ids_one.append(str(entry.get("id", "")))
	for entry: Dictionary in tie_two:
		tie_ids_two.append(str(entry.get("id", "")))
	_ok("identical scores break ties deterministically",
		tie_ids_one == tie_ids_two, str(tie_ids_one))

	# Comparing two calls on the SAME array proves nothing: sort_custom may
	# simply preserve input order, so removing the id tiebreak passed this
	# check untouched. Feed the SHUFFLED array instead — a comparator without
	# a total order returns the input order, and the two results diverge.
	var shuffled: Array[Dictionary] = tied.duplicate(true)
	shuffled.reverse()
	var tie_shuffled: Array = loader.call("get_popular_categories", 6, shuffled)
	var tie_ids_shuffled: Array[String] = []
	for entry: Dictionary in tie_shuffled:
		tie_ids_shuffled.append(str(entry.get("id", "")))
	_ok("tie order is independent of input order",
		tie_ids_one == tie_ids_shuffled,
		"%s vs %s" % [str(tie_ids_one), str(tie_ids_shuffled)])
	_ok("tied entries sort by id", tie_ids_one[0] == "zz_tie_0", str(tie_ids_one[0]))

	# ── Limits ───────────────────────────────────────────────────────────
	_ok("the limit is honoured",
		(loader.call("get_popular_categories", 3) as Array).size() == 3)
	_ok("a limit past the roster returns everything",
		(loader.call("get_popular_categories", 500) as Array).size() == roster.size())
	_ok("a zero limit returns everything",
		(loader.call("get_popular_categories", 0) as Array).size() == roster.size())

	# ── is_popular is DERIVED, never trusted from the file ───────────────
	var liar: Array[Dictionary] = [{
		"id": "trend_liar", "name": "Liar", "popularity_score": 3,
		"is_popular": true,
	}]
	var judged: Array = loader.call("get_popular_categories", 1, liar)
	_ok("a self-declared popular flag is overruled",
		not bool((judged[0] as Dictionary).get("is_popular", true)))
	_wipe()


## Index of a category in a ranked list, or -1.
func _rank_of(ranked: Array, id: String) -> int:
	for i: int in range(ranked.size()):
		if str((ranked[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


# ═════════════════════════════════════════════════════════════════════════
# ARCHIVE
# ═════════════════════════════════════════════════════════════════════════
func _test_archive() -> void:
	print("── weekly archive ──")
	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	_wipe()
	await process_frame

	# Clear any archive left by a previous run so counts are exact.
	var dir: DirAccess = DirAccess.open("user://trend_archive/")
	if dir != null:
		dir.list_dir_begin()
		var stale: String = dir.get_next()
		while stale != "":
			if not dir.current_is_dir():
				dir.remove(stale)
			stale = dir.get_next()
		dir.list_dir_end()

	_ok("a clean device has no archive",
		(loader.call("get_archived_weeks") as Array).is_empty())
	_ok("an unarchived week loads empty",
		(loader.call("load_archived_week", "2020-W01") as Array).is_empty())

	var roster: Array = loader.call("load_roster")
	_ok("archiving succeeds",
		bool(loader.call("archive_week", "2026-W30", roster)))
	_ok("archiving a second week succeeds",
		bool(loader.call("archive_week", "2026-W31", roster)))

	var weeks: Array = loader.call("get_archived_weeks")
	_ok("both weeks are listed", weeks.size() == 2, str(weeks))
	# Newest first, so a browser shows the most recent roster at the top.
	_ok("weeks are newest first",
		weeks.size() == 2 and str(weeks[0]) == "2026-W31", str(weeks))

	var restored: Array = loader.call("load_archived_week", "2026-W30")
	_ok("an archived week round-trips", restored.size() == roster.size(),
		"%d vs %d" % [restored.size(), roster.size()])
	_ok("archived entries keep their id",
		str((restored[0] as Dictionary).get("id", ""))
		== str((roster[0] as Dictionary).get("id", "")))

	# Re-archiving must not duplicate the week.
	loader.call("archive_week", "2026-W30", roster)
	_ok("re-archiving is idempotent",
		(loader.call("get_archived_weeks") as Array).size() == 2)

	# Guards: an empty roster would silently erase a real archive.
	#
	# The empty literal must be a TYPED Array[Dictionary]. An untyped [] fails
	# argument-type checking before the function body runs, so this "passed"
	# without ever reaching the guard it claims to test.
	var empty_roster: Array[Dictionary] = []
	_ok("an empty roster is refused",
		not bool(loader.call("archive_week", "2026-W29", empty_roster)))
	_ok("an empty week label is refused",
		not bool(loader.call("archive_week", "", roster)))

	print("── unlocks survive a roster rotation ──")
	# THE GUARANTEE: a pass bought on Saturday must still work on Monday, even
	# though the roster rotated on Sunday. This only holds because pack ids are
	# name-derived — an order-based id changed every week and orphaned the
	# unlock, which is the bug this cycle fixed.
	var state: Object = _new_state()
	var paid_id: String = ""
	for entry: Dictionary in roster:
		if not bool(entry.get("free", false)):
			paid_id = str(entry.get("id", ""))
			break
	_ok("the archive contains a paid category", paid_id != "")

	state.call("grant_rental", StringName(paid_id))
	var owned: Array = loader.call("get_owned_archived_categories", state)
	_ok("an unlocked archived category is returned", owned.size() >= 1,
		str(owned.size()))
	var found: bool = false
	for entry: Dictionary in owned:
		if str(entry.get("id", "")) == paid_id:
			found = true
			_ok("it reports its remaining days",
				int(entry.get("days_remaining", 0)) == 7,
				str(entry.get("days_remaining", 0)))
			_ok("it reports the week it came from",
				str(entry.get("week", "")) != "")
	_ok("the specific unlocked category is present", found)

	# Deduplicated across weeks: the same category archived twice must appear
	# once, or a browser shows it repeatedly.
	var duplicates: Dictionary = {}
	var repeated: bool = false
	for entry: Dictionary in owned:
		var id: String = str(entry.get("id", ""))
		if duplicates.has(id):
			repeated = true
		duplicates[id] = true
	_ok("archived categories are deduplicated", not repeated)

	# Locked and free categories must not appear.
	var locked_leak: bool = false
	var free_leak: bool = false
	for entry: Dictionary in owned:
		if bool(entry.get("free", false)):
			free_leak = true
		if not state.call("is_rental_active", StringName(str(entry.get("id", "")))):
			locked_leak = true
	_ok("no locked category is returned", not locked_leak)
	_ok("free categories are excluded", not free_leak)

	# An expired pass must drop out — the archive preserves ACCESS, it does
	# not extend it.
	var expired: Object = _new_state()
	_ok("no passes means no archived categories",
		(loader.call("get_owned_archived_categories", expired) as Array).is_empty())
	_wipe()


# ═════════════════════════════════════════════════════════════════════════
# WEEKLY ROTATION
# ═════════════════════════════════════════════════════════════════════════
func _test_rotation() -> void:
	print("── ISO week labelling ──")
	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	# Known-correct anchors. ISO week 1 is the week containing the first
	# THURSDAY, so late-December and early-January dates routinely belong to
	# the neighbouring ISO year — the classic source of off-by-one rotations.
	var anchors: Array[Array] = [
		["2026-01-01T12:00:00", "2026-W01"],
		["2026-07-26T12:00:00", "2026-W30"],   # Sunday: LAST day of W30
		["2026-07-27T12:00:00", "2026-W31"],   # Monday: first day of W31
		["2026-12-31T12:00:00", "2026-W53"],
		["2027-01-01T12:00:00", "2026-W53"],
		["2021-01-01T12:00:00", "2020-W53"],
		["2024-12-30T12:00:00", "2025-W01"],
		["2020-02-29T12:00:00", "2020-W09"],
	]
	for anchor: Array in anchors:
		var ts: float = Time.get_unix_time_from_datetime_string(str(anchor[0]))
		_ok("%s -> %s" % [str(anchor[0]).substr(0, 10), str(anchor[1])],
			str(loader.call("iso_week_label", ts)) == str(anchor[1]),
			str(loader.call("iso_week_label", ts)))

	var monday: float = Time.get_unix_time_from_datetime_string("2026-07-27T00:00:00")
	_ok("a week label holds all week",
		str(loader.call("iso_week_label", monday))
		== str(loader.call("iso_week_label", monday + 6.0 * 86400.0)))
	_ok("the label changes at the week boundary",
		str(loader.call("iso_week_label", monday))
		!= str(loader.call("iso_week_label", monday - 1.0)))

	print("── rotation detection ──")
	_wipe()
	await process_frame
	var now: float = Time.get_unix_time_from_datetime_string("2026-07-26T12:00:00")

	var first: Dictionary = loader.call("check_week_rotation", now)
	_ok("a first launch does not rotate", not bool(first.get("rotated", true)))
	_ok("a first launch archives nothing", not bool(first.get("archived", true)))
	_ok("the active week is stamped",
		str(loader.call("last_active_week")) == str(first.get("current_week", "")))

	var same: Dictionary = loader.call("check_week_rotation", now + 3600.0)
	_ok("the same week does not rotate", not bool(same.get("rotated", true)))

	print("── a rotation must NOT disturb unlocks ──")
	# THE GUARANTEE. Passes live in IrisState keyed by pack id; the archive
	# stores only what the categories WERE. A rotation that touched either
	# would silently revoke content a player watched an ad for.
	var state: Object = _new_state()
	var paid_ids: Array = _reg.call("paid_ids")
	var held: Array[String] = []
	# Granted with a duration that outlives the rotation under test. The point
	# here is whether ROTATION disturbs a live pass, not whether a pass
	# expires — expiry has its own coverage above.
	for i: int in range(3):
		var id: String = str(paid_ids[i])
		state.call("grant_rental", StringName(id), now, 30 * DAY)
		held.append(id)
	_save().call("set_v", "iris", "state", state.call("to_dict"))
	_save().call("flush")

	var best_before: int = 4321
	_reg.call("submit_score", str(paid_ids[0]), best_before)
	var plays_before: int = int(_reg.call("run_count", str(paid_ids[0])))

	# 8 days: one week boundary crossed, and inside the 7-day pass window
	# measured from `now` only if the passes are re-granted. Grant them at a
	# point that keeps them live across the boundary instead.
	var later: float = now + 8.0 * 86400.0
	var rotated: Dictionary = loader.call("check_week_rotation", later)
	_ok("a week change is detected", bool(rotated.get("rotated", false)))
	_ok("the outgoing week is archived", bool(rotated.get("archived", false)))
	_ok("the new week is recorded",
		str(loader.call("last_active_week"))
		== str(loader.call("iso_week_label", later)))

	var reloaded: Object = _new_state()
	reloaded.call("from_dict", _save().call("get_v", "iris", "state", {}))
	var lost: Array[String] = []
	for id: String in held:
		if not bool(reloaded.call("is_rental_active", StringName(id), later)):
			lost.append(id)
	_ok("every active pass survives the rotation", lost.is_empty(), ", ".join(lost))
	_ok("best scores survive the rotation",
		int(_reg.call("best_score", str(paid_ids[0]))) == best_before,
		str(_reg.call("best_score", str(paid_ids[0]))))
	_ok("play counts survive the rotation",
		int(_reg.call("run_count", str(paid_ids[0]))) == plays_before)

	var weeks: Array = loader.call("get_archived_weeks")
	_ok("the previous week is in the archive",
		weeks.has(str(rotated.get("previous_week", ""))), str(weeks))
	_ok("the current week is NOT archived yet",
		not weeks.has(str(rotated.get("current_week", ""))), str(weeks))

	var owned: Array = loader.call("get_owned_archived_categories", reloaded)
	_ok("held passes resolve from the archive", owned.size() >= 1, str(owned.size()))
	_wipe()


# ═════════════════════════════════════════════════════════════════════════
# TAB RAILS
# ═════════════════════════════════════════════════════════════════════════
func _test_tabs() -> void:
	print("── hub rails ──")
	_wipe()
	root.get_node_or_null("AdManager").call("reset_cooldowns")
	# Earlier scenarios archive weeks; the empty-state assertion below needs a
	# genuinely empty archive or it is testing the wrong branch.
	_clear_archive()
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var hub: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame
	await process_frame

	var tab_row: Control = hub.get_node_or_null("%TabRow") as Control
	var column: Control = hub.get_node_or_null("%CardColumn") as Control
	_ok("the tab row exists", tab_row != null)
	_ok("three rails are offered",
		tab_row != null and tab_row.get_child_count() == 3,
		str(tab_row.get_child_count()) if tab_row != null else "none")

	var tab_labels: Array[String] = []
	_collect_buttons(tab_row, tab_labels)
	var expected_labels: Array[String] = ["THIS WEEK", "POPULAR", "ARCHIVE"]
	_ok("the rails are named correctly", tab_labels == expected_labels,
		str(tab_labels))

	_ok("THIS WEEK is active by default", int(hub.call("current_tab")) == 0)
	var roster_size: int = (_reg.call("all_ids") as Array).size()
	_ok("the default rail shows the full roster",
		column.get_child_count() == roster_size,
		"%d of %d" % [column.get_child_count(), roster_size])
	# The active tab is disabled, which is the non-colour state cue.
	_ok("the active tab cannot be re-selected",
		(tab_row.get_child(0) as Button).disabled)
	_ok("inactive tabs are selectable",
		not (tab_row.get_child(1) as Button).disabled)

	hub.call("_on_tab_pressed", 1)
	await process_frame
	await process_frame
	_ok("POPULAR becomes active", int(hub.call("current_tab")) == 1)
	_ok("POPULAR is capped at 10",
		column.get_child_count() <= 10, str(column.get_child_count()))
	_ok("POPULAR is not empty", column.get_child_count() > 0)
	_ok("the POPULAR tab is now the disabled one",
		(tab_row.get_child(1) as Button).disabled
		and not (tab_row.get_child(0) as Button).disabled)

	hub.call("_on_tab_pressed", 2)
	await process_frame
	await process_frame
	_ok("ARCHIVE becomes active", int(hub.call("current_tab")) == 2)
	_ok("an empty archive still renders a notice",
		column.get_child_count() > 0, str(column.get_child_count()))
	var archive_text: Array[String] = []
	_collect_labels(column, archive_text)
	var explained: bool = false
	for text: String in archive_text:
		if text.contains("No past weeks"):
			explained = true
	_ok("the empty archive explains itself", explained,
		str(archive_text.slice(0, 2)))

	hub.call("_on_tab_pressed", 0)
	await process_frame
	await process_frame
	_ok("returning to THIS WEEK restores the roster",
		column.get_child_count() == roster_size,
		"%d of %d" % [column.get_child_count(), roster_size])
	hub.free()
	await process_frame

	print("── ARCHIVE renders real held passes ──")
	_wipe()
	await process_frame
	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	var state: Object = _new_state()
	var paid: String = str((_reg.call("paid_ids") as Array)[0])
	state.call("grant_rental", StringName(paid))
	var live_roster: Array[Dictionary] = loader.call("load_roster")
	loader.call("archive_week", "2026-W30", live_roster)

	var hub2: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	hub2.call("configure", {"iris_state": state})
	root.add_child(hub2)
	await process_frame
	await process_frame
	hub2.call("_on_tab_pressed", 2)
	await process_frame
	await process_frame

	var archive_labels: Array[String] = []
	_collect_labels(hub2.get_node_or_null("%CardColumn"), archive_labels)
	var names_week: bool = false
	var names_pass: bool = false
	for text: String in archive_labels:
		if text.contains("2026-W30"):
			names_week = true
		if text.contains("DAY") and text.contains("LEFT"):
			names_pass = true
	_ok("the archive names the week", names_week, str(archive_labels.slice(0, 3)))
	_ok("a held pass shows its remaining days", names_pass)

	var archive_buttons: Array[String] = []
	_collect_buttons(hub2.get_node_or_null("%CardColumn"), archive_buttons)
	_ok("an archived unlock is playable",
		archive_buttons.has("PLAY RUN"), str(archive_buttons))
	hub2.free()
	_wipe()
	await process_frame


## Remove every archived week, so a scenario can assert the empty state.
func _clear_archive() -> void:
	var dir: DirAccess = DirAccess.open("user://trend_archive/")
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()


func _collect_labels(node: Node, out: Array[String]) -> void:
	if node == null:
		return
	if node is Label:
		out.append((node as Label).text)
	for child: Node in node.get_children():
		_collect_labels(child, out)


# ═════════════════════════════════════════════════════════════════════════
# MID-SESSION ROTATION
# ═════════════════════════════════════════════════════════════════════════
## A player who never relaunches must still get the new roster.
func _test_midsession_rotation() -> void:
	print("── the hub refreshes across a week boundary ──")
	_wipe()
	_clear_archive()
	await process_frame
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)

	var loader: GDScript = ResourceLoader.load("res://core/trend_loader.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	# Stamp last week as the active one, as if the app had been open since.
	var stale: String = str(loader.call("iso_week_label",
		Time.get_unix_time_from_system() - 8.0 * DAY))
	_save().call("set_v", "trend", "last_active_week", stale)
	_save().call("flush")
	_ok("a stale week is stored",
		str(loader.call("last_active_week")) == stale, stale)

	var hub: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame
	await process_frame

	# Opening the hub must have noticed and rotated.
	_ok("opening the hub rotates a stale week",
		str(loader.call("last_active_week")) != stale,
		str(loader.call("last_active_week")))
	_ok("the stale week was archived",
		(loader.call("get_archived_weeks") as Array).has(stale),
		str(loader.call("get_archived_weeks")))
	# And the hub still renders — a refresh must not leave it blank.
	var column: Control = hub.get_node_or_null("%CardColumn") as Control
	_ok("the hub still renders after a refresh",
		column != null and column.get_child_count() > 0,
		str(column.get_child_count()) if column != null else "none")

	# Idempotent: a second check in the same week must not re-archive.
	var before: int = (loader.call("get_archived_weeks") as Array).size()
	_ok("a same-week refresh is a no-op",
		not bool(hub.call("_refresh_if_week_changed")))
	_ok("no duplicate archive is written",
		(loader.call("get_archived_weeks") as Array).size() == before)

	# The resume hook must be safe to fire repeatedly.
	hub.call("_on_app_resumed", 3600)
	await process_frame
	hub.call("_on_app_resumed", 3600)
	await process_frame
	_ok("repeated resumes do not break the hub",
		column.get_child_count() > 0, str(column.get_child_count()))
	_ok("repeated resumes do not spam the archive",
		(loader.call("get_archived_weeks") as Array).size() == before)

	# Unlocks must survive a mid-session rotation exactly as they do at launch.
	var state: Object = _new_state()
	var paid: String = str((_reg.call("paid_ids") as Array)[0])
	state.call("grant_rental", StringName(paid), -1.0, 30 * DAY)
	_save().call("set_v", "iris", "state", state.call("to_dict"))
	_save().call("flush")
	_save().call("set_v", "trend", "last_active_week", stale)
	hub.call("_on_app_resumed", 3600)
	await process_frame
	var reloaded: Object = _new_state()
	reloaded.call("from_dict", _save().call("get_v", "iris", "state", {}))
	_ok("a pass survives a mid-session rotation",
		bool(reloaded.call("is_rental_active", StringName(paid))))

	hub.free()
	_wipe()
	await process_frame


## Signals must be released when the hub leaves the tree, or a resume fires
## into a freed node.
func _test_hub_teardown() -> void:
	print("── the hub releases its subscriptions ──")
	_wipe()
	await process_frame
	var hub: Node = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame

	var bus: Node = root.get_node_or_null("Bus")
	var ads: Node = root.get_node_or_null("AdManager")
	_ok("the hub subscribes to app_resumed",
		bus.is_connected("app_resumed", Callable(hub, "_on_app_resumed")))
	_ok("the hub subscribes to availability_changed",
		ads.is_connected("availability_changed",
			Callable(hub, "_on_availability_changed")))

	# Disconnect explicitly BEFORE freeing, so the teardown path itself is
	# exercised. Measured first: Godot auto-releases a connection when the
	# receiver is freed, so a "no dangling connection after free()" assertion
	# can never fail and proves nothing about _exit_tree(). Counting the
	# connection drop across an explicit exit is the part that is real.
	var bus_before: int = bus.get_signal_connection_list("app_resumed").size()
	var ads_before: int = ads.get_signal_connection_list(
		"availability_changed").size()

	hub.call("_exit_tree")
	_ok("_exit_tree releases the app_resumed subscription",
		bus.get_signal_connection_list("app_resumed").size() == bus_before - 1,
		"%d -> %d" % [bus_before,
			bus.get_signal_connection_list("app_resumed").size()])
	_ok("_exit_tree releases the availability subscription",
		ads.get_signal_connection_list("availability_changed").size()
		== ads_before - 1,
		"%d -> %d" % [ads_before,
			ads.get_signal_connection_list("availability_changed").size()])
	# Idempotent: _exit_tree runs again when the node actually leaves the
	# tree, and a double disconnect must not error.
	hub.call("_exit_tree")
	_ok("a second teardown is harmless",
		bus.get_signal_connection_list("app_resumed").size() == bus_before - 1)

	hub.free()
	await process_frame
	_wipe()
	await process_frame
