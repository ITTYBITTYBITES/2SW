extends SceneTree
## Headless validation. Run:
##   godot --headless --path . --script res://tools/validate.gd
##
## Compiles every script, instantiates every scene, and exercises the pure
## logic layers. Exits non-zero on any failure so CI can gate on it.

var _failures: Array[String] = []
var _checks: int = 0

## Autoloads are resolved at RUNTIME, not by identifier. A --script MainLoop is
## compiled before autoload nodes attach, so naming Router/Log/etc. directly is
## a hard compile error ("Identifier not found"). This is the single most
## surprising thing about headless validation in Godot.
func _auto(node_name: String) -> Node:
	return root.get_node_or_null(NodePath(node_name))


## ── AUTOLOAD-DEPENDENT CLASS LOADING ──────────────────────────────────────
## Under `--script`, the MainLoop is compiled BEFORE autoloads attach. Any
## class_name script that references an autoload at class scope (Log, Save,
## Palette...) therefore fails to compile, and load() returns a GDScript whose
## .new() and static methods are unavailable.
##
## Godot 4.6.3 enforces this more strictly than 4.3, where it silently worked.
##
## The fix: re-load the script AFTER the first deferred frame, once autoloads
## exist. ResourceLoader.CACHE_MODE_IGNORE forces a fresh compile rather than
## returning the failed one from cache.
func _load_class(path: String) -> GDScript:
	var script: GDScript = ResourceLoader.load(
		path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	if script == null:
		push_error("could not load %s" % path)
	return script



func _log(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	var mark: String = "PASS" if ok else "FAIL"
	var suffix: String = ("  [" + detail + "]") if (detail != "" and not ok) else ""
	print("  %s  %s%s" % [mark, label, suffix])
	if not ok:
		_failures.append(label)


## Autoloads do not exist during _init() when run via --script: the SceneTree
## is constructed before the autoload nodes are attached. Deferring to the
## first idle frame is what makes Log/Save/Router (and every class_name that
## touches them) resolvable.
func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ GODOT HEADLESS VALIDATION ═══\n")
	_validate_scripts()
	_validate_scenes()
	_validate_autoloads()
	_validate_registries()
	_validate_node_paths()
	_validate_logic()
	await _validate_boot()
	_report()


## Every .gd file must compile. A GDScript that fails to load returns null.
func _validate_scripts() -> void:
	print("── SCRIPT COMPILATION ──")
	var paths: Array[String] = _collect("res://", ".gd")
	var failed: Array[String] = []
	for path: String in paths:
		var script: Resource = load(path)
		if script == null or not (script is GDScript):
			failed.append(path)
	_log("%d scripts compile" % paths.size(), failed.is_empty(), str(failed))


## Every .tscn must instantiate without error.
func _validate_scenes() -> void:
	print("\n── SCENE INSTANTIATION ──")
	var paths: Array[String] = _collect("res://", ".tscn")
	for path: String in paths:
		var packed: Resource = load(path)
		if packed == null or not (packed is PackedScene):
			_log("load %s" % path.get_file(), false, "not a PackedScene")
			continue
		var instance: Node = (packed as PackedScene).instantiate()
		var ok: bool = instance != null
		_log("instantiate %s" % path.get_file(), ok)
		if instance != null:
			instance.free()


func _validate_autoloads() -> void:
	print("\n── AUTOLOADS ──")
	for name: String in ["Log", "Cfg", "Bus", "Save", "Palette", "Router", "AudioManager"]:
		_log("%s present" % name, root.has_node(name))


## The registries must agree with themselves and with the filesystem.
func _validate_registries() -> void:
	print("\n── REGISTRIES ──")
	var registry_script: GDScript = _load_class("res://data/trial_registry.gd")
	var trial_problems: Array = registry_script.call("validate")
	_log("TrialRegistry validates", trial_problems.is_empty(), str(trial_problems))
	# Count derived from the registry, not hardcoded. A literal here goes stale
	# the moment a mode is added and reports as a failure of the new mode
	# rather than of the assertion — which is exactly what adding
	# trend_witness did.
	var roster: Array = registry_script.call("all_ids")
	_log("the roster is non-empty", roster.size() > 0, str(roster.size()))
	# The four core modes must survive any future addition.
	for core_id: String in ["false_witness", "sequence_recall",
			"cognitive_conflict", "facet_cascade"]:
		_log("core trial '%s' registered" % core_id,
			bool(registry_script.call("has", core_id)))
	# Selection weights are what must total 100; a non-selectable mode is
	# excluded from the draw and therefore from the total.
	_log("selectable weights total 100",
		int(registry_script.call("total_weight")) == 100,
		str(registry_script.call("total_weight")))

	var dialogue_script: GDScript = _load_class("res://data/dialogue_manifest.gd")
	var dialogue_problems: Array = dialogue_script.call("validate")
	_log("DialogueManifest validates", dialogue_problems.is_empty(), str(dialogue_problems))

	# Every route target must exist on disk.
	var router: Node = _auto("Router")
	var routes: Dictionary = router.get("ROUTES") if router != null else {}
	var broken: Array[String] = []
	for route: String in routes.keys():
		if not ResourceLoader.exists(str(routes[route])):
			broken.append(route)
	_log("all routes resolve", broken.is_empty(), str(broken))
	_log("route table populated", routes.size() > 0)

	# Every mini-game script must load.
	for trial_id: String in (registry_script.call("all_ids") as Array):
		var path: String = str(registry_script.call("script_path", trial_id))
		_log("mini-game '%s' loads" % trial_id, ResourceLoader.exists(path) and load(path) != null)


## Exercise the pure logic against the real engine, not a Python port.
func _validate_logic() -> void:
	print("\n── LOGIC (live GDScript) ──")
	var iris_script: GDScript = _load_class("res://data/iris_state.gd")
	var progression: GDScript = _load_class("res://data/progression_engine.gd")
	var adaptive: GDScript = _load_class("res://data/adaptive_difficulty.gd")
	var registry: GDScript = _load_class("res://data/trial_registry.gd")
	var dialogue: GDScript = _load_class("res://data/dialogue_manifest.gd")
	var catalog: GDScript = _load_class("res://data/cosmetic_catalog.gd")

	_log("IrisState compiles with autoloads live", iris_script != null)
	if iris_script == null:
		return
	var state: Variant = iris_script.new()
	_log("IrisState constructs", state != null)

	# Infinite rank inverse.
	var inverse_ok: bool = true
	for rank: int in [1, 2, 100, 1000, 100000]:
		if state.rank_for_total_xp(state.cumulative_xp_for_rank(rank)) != rank:
			inverse_ok = false
	_log("rank inverse exact to 100k", inverse_ok)

	# Economy safety.
	state.lumina = 100
	_log("overspend rejected", not state.spend_lumina(500) and state.lumina == 100)
	_log("negative award rejected", int(progression.call("award_lumina", state, -50)) == 0)

	# Adaptive thresholds.
	_log("3 low scores demote",
		int(adaptive.call("evaluate_bracket", [0.5, 0.5, 0.5], 1)) == 0)
	_log("5 high scores promote",
		int(adaptive.call("evaluate_bracket", [0.9, 0.9, 0.9, 0.9, 0.9], 1)) == 2)
	_log("exactly 0.63 does not demote",
		int(adaptive.call("evaluate_bracket", [0.63, 0.63, 0.63], 1)) == 1)

	# History covers the whole roster.
	registry.call("ensure_history", state)
	_log("every registered trial is seeded",
		state.trial_history.size() == (registry.call("all_ids") as Array).size(),
		"%d history vs %d registered" % [state.trial_history.size(),
			(registry.call("all_ids") as Array).size()])
	_log("facet_cascade tracked", state.trial_history.has("facet_cascade"))

	# Serialisation round-trip.
	state.lumina = 4242
	state.streak_days = 9
	var restored: Variant = iris_script.new()
	restored.from_dict(state.to_dict())
	_log("save round-trip preserves lumina", restored.lumina == 4242)
	_log("save round-trip preserves streak", restored.streak_days == 9)

	# Shuffle bag: no back-to-back repeats.
	dialogue.call("reset_bags")
	var previous: String = ""
	var repeats: int = 0
	for i: int in range(200):
		var line: String = str(dialogue.call("next_line", dialogue.get("HUB_GREET")))
		if line == previous:
			repeats += 1
		previous = line
	_log("200 voice draws, zero repeats", repeats == 0, str(repeats))

	# Cosmetic seeds are stable.
	_log("FNV seed deterministic",
		int(iris_script.call("derive_seed_from_sku", "crown"))
		== int(iris_script.call("derive_seed_from_sku", "crown")))
	_log("distinct skus differ",
		int(iris_script.call("derive_seed_from_sku", "crown"))
		!= int(iris_script.call("derive_seed_from_sku", "halo")))
	_log("catalogue populated", (catalog.call("all") as Array).size() > 0)


## Every %UniqueName a script references must resolve in its own scene, and
## every scene's script reference must load. This is the check that would have
## caught the five broken routes and the $Overlay/Toasts paths.
func _validate_node_paths() -> void:
	print("\n── NODE PATHS & SCRIPT BINDINGS ──")
	var scenes: Array[String] = _collect("res://", ".tscn")

	for path: String in scenes:
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			continue
		var state: SceneState = packed.get_state()

		# Every ext_resource script on this scene must load.
		var missing_scripts: Array[String] = []
		for i: int in range(state.get_node_count()):
			for prop: int in range(state.get_node_property_count(i)):
				if str(state.get_node_property_name(i, prop)) != "script":
					continue
				var value: Variant = state.get_node_property_value(i, prop)
				if value == null:
					missing_scripts.append(str(state.get_node_name(i)))
		if not missing_scripts.is_empty():
			_log("%s: scripts bind" % path.get_file(), false, str(missing_scripts))

		# Instantiate and confirm every %UniqueName used by the script exists.
		var instance: Node = packed.instantiate()
		if instance == null:
			continue
		var script: Script = instance.get_script() as Script
		if script != null:
			var unresolved: Array[String] = _unresolved_unique_names(
				script.get_source_code(), instance)
			_log("%s: unique names resolve" % path.get_file(),
				unresolved.is_empty(), str(unresolved))
		instance.free()


## Find %UniqueName references that do not resolve in `instance`.
##
## Only @onready declarations are scanned. A naive scan for "%Word" also hits
## printf specifiers (%s, %d) inside strings, which produced a wall of false
## failures the first time this ran — the format specifier is by far the most
## common percent sign in this codebase.
func _unresolved_unique_names(source: String, instance: Node) -> Array[String]:
	var unresolved: Array[String] = []
	var regex: RegEx = RegEx.new()
	regex.compile("@onready\\s+var\\s+\\w+\\s*:\\s*[\\w.]+\\s*=\\s*%([A-Za-z_]\\w*)")
	for m: RegExMatch in regex.search_all(source):
		var unique_name: String = m.get_string(1)
		if instance.get_node_or_null(NodePath("%" + unique_name)) == null:
			unresolved.append(unique_name)
	return unresolved


## Boot the real main scene and confirm it reaches a screen without error.
func _validate_boot() -> void:
	print("\n── BOOT: res://app/app.tscn ──")
	var main_scene: String = str(ProjectSettings.get_setting(
		"application/run/main_scene", ""))
	_log("main scene declared", main_scene != "")
	_log("main scene is app/app.tscn", main_scene == "res://app/app.tscn", main_scene)
	_log("main scene exists", ResourceLoader.exists(main_scene))

	# IMPORTANT: --script REPLACES the main loop, so the declared main scene is
	# never auto-instantiated. Boot it by hand to prove it actually runs.
	var packed: PackedScene = load(main_scene) as PackedScene
	_log("main scene loads as PackedScene", packed != null)
	if packed == null:
		return
	var app: Node = packed.instantiate()
	_log("main scene instantiates", app != null)
	if app == null:
		return
	root.add_child(app)

	# Let the boot chain run: _ready -> _boot -> Router.go -> screen _ready.
	for i: int in range(10):
		await process_frame

	var router: Node = _auto("Router")
	_log("Router autoload live", router != null)
	if router == null:
		return
	var current: String = str(router.get("current_route"))
	var routes: Dictionary = router.get("ROUTES")
	_log("Router reached a route", current != "", current)
	_log("route is declared", routes.has(current), current)
	var screen: Node = router.call("current_screen")
	_log("a screen is mounted", screen != null)
	if screen != null:
		_log("mounted screen is a Control", screen is Control)
		_log("screen has a script", screen.get_script() != null)
	app.queue_free()


func _collect(dir_path: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "legacy_reference":
				out.append_array(_collect(full, suffix))
		elif entry.ends_with(suffix):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


func _report() -> void:
	print("\n═══════════════════════════════════")
	if _failures.is_empty():
		print("ALL %d CHECKS PASSED" % _checks)
		quit(0)
	else:
		print("%d of %d FAILED:" % [_failures.size(), _checks])
		for failure: String in _failures:
			print("  · " + failure)
		quit(1)
