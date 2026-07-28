extends SceneTree
## Proves the consent gate end-to-end against the real engine.

var _fails: Array[String] = []
var _n: int = 0

## ConsentController cannot be named statically here: a --script MainLoop is
## compiled BEFORE autoloads attach, and the controller references Log at class
## scope. Load it as a resource at runtime instead. Same constraint that
## applies to autoload identifiers in validate.gd.
var _cc: GDScript = null


## Test the RELEASE path. is_satisfied() intentionally returns true in a debug
## build so the editor is never gated; is_recorded() is the underlying truth.
func _consent_ok() -> bool:
	return bool(_cc.call("is_recorded"))


func _debug_bypass_active() -> bool:
	return bool(_cc.call("is_satisfied"))

func _ads_ok() -> bool:
	return bool(_cc.call("personalized_ads_allowed"))

func _analytics_ok() -> bool:
	return bool(_cc.call("analytics_allowed"))

func _policy_version() -> int:
	return int(_cc.get("POLICY_VERSION"))

func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	print("  %s  %s%s" % ["PASS" if cond else "FAIL", label,
		("  [" + detail + "]") if (detail != "" and not cond) else ""])
	if not cond: _fails.append(label)

## Recursive type census over a live scene. Proves absence, which a grep of
## the .tscn cannot do for nodes created in script or nested subscenes.
func _count_type(node: Node, type_name: String) -> int:
	var total: int = 0
	if node.is_class(type_name):
		total += 1
	for child: Node in node.get_children():
		total += _count_type(child, type_name)
	return total


func _count_visible_buttons(node: Node) -> int:
	var total: int = 0
	if node is Button and (node as Button).visible:
		total += 1
	for child: Node in node.get_children():
		total += _count_visible_buttons(child)
	return total


func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	print("\n═══ CONSENT FLOW (live engine) ═══\n")
	# Re-load AFTER autoloads attach; see the note in validate.gd. A plain
	# load() here returns the compile-failed script from cache.
	_cc = ResourceLoader.load("res://nodes/consent_controller.gd", "GDScript",
		ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	var save: Node = root.get_node_or_null("Save")

	print("── fresh install ──")
	save.call("wipe")
	_ok("consent not satisfied on a clean save", not _consent_ok())
	_ok("ads default OFF", not _ads_ok())
	_ok("analytics default OFF", not _analytics_ok())

	print("\n── accept with both toggles off (tap-through) ──")
	var packed: PackedScene = load("res://screens/consent/consent.tscn")
	var screen: Node = packed.instantiate()
	screen.call("configure", {})
	root.add_child(screen)
	await process_frame
	screen.call("commit_consent")
	await process_frame

	_ok("consent now satisfied", _consent_ok())
	_ok("tap-through leaves ads OFF", not _ads_ok())
	_ok("tap-through leaves analytics OFF", not _analytics_ok())
	_ok("policy version stamped",
		int(save.call("get_v", "consent", "policy_version", 0)) == _policy_version())
	_ok("timestamp recorded",
		int(save.call("get_v", "consent", "accepted_unix", 0)) > 0)
	screen.queue_free()
	await process_frame

	print("\n── the gate has no switches to get wrong ──")
	# Strongest form of the opt-in guarantee: walk the instantiated scene and
	# assert no CheckButton exists anywhere in it. A grep can be fooled by a
	# node added in a subscene; the live tree cannot.
	var gate_scan: Node = packed.instantiate()
	gate_scan.call("configure", {})
	root.add_child(gate_scan)
	await process_frame
	await process_frame
	_ok("no CheckButton anywhere in the gate", _count_type(gate_scan, "CheckButton") == 0)
	_ok("exactly one primary action",
		_count_visible_buttons(gate_scan) == 3,
		"privacy + terms + accept, back hidden")
	gate_scan.queue_free()
	await process_frame

	print("\n── opt in from Settings (not from the gate) ──")
	# The switches live in Settings now, and write through this static entry
	# point. Exercising the real writer proves the Settings path stores what
	# the Settings UI claims it does.
	_cc.call("set_privacy_choice", "personalized_ads", true)
	_cc.call("set_privacy_choice", "analytics", true)
	await process_frame
	_ok("ads now allowed", _ads_ok())
	_ok("analytics now allowed", _analytics_ok())

	print("\n── a revisit must NOT reset a Settings opt-in ──")
	# The regression this guards: re-reading the terms silently reverting a
	# choice the player deliberately made would be a consent bug that looks
	# like a UI refresh.
	var revisit: Node = packed.instantiate()
	revisit.call("configure", {"revisit": true})
	root.add_child(revisit)
	await process_frame
	revisit.call("commit_consent")
	await process_frame
	_ok("revisit preserves the ads opt-in", _ads_ok())
	_ok("revisit preserves the analytics opt-in", _analytics_ok())
	_ok("revisit preserves acceptance", _consent_ok())
	revisit.queue_free()
	await process_frame

	print("\n── withdrawal must be possible ──")
	_cc.call("set_privacy_choice", "personalized_ads", false)
	_cc.call("set_privacy_choice", "analytics", false)
	await process_frame
	_ok("ads withdrawn", not _ads_ok())
	_ok("analytics withdrawn", not _analytics_ok())
	_ok("acceptance itself survives withdrawal", _consent_ok())

	print("\n── an unknown privacy key is rejected, not silently stored ──")
	_cc.call("set_privacy_choice", "not_a_real_key", true)
	await process_frame
	_ok("bogus key not written",
		not bool(save.call("get_v", "consent", "not_a_real_key", false)))

	print("\n── persistence across a reload ──")
	save.call("flush")
	save.call("_load")
	_ok("consent survives reload", _consent_ok())

	print("\n── material policy change re-prompts ──")
	save.call("set_v", "consent", "policy_version", 0)
	_ok("stale policy version re-prompts", not _consent_ok())
	save.call("set_v", "consent", "policy_version", _policy_version())
	_ok("current version satisfies again", _consent_ok())

	print("\n── debug bypass ──")
	save.call("set_v", "consent", "accepted", false)
	save.call("set_v", "consent", "policy_version", 0)
	_ok("release path correctly gates", not _consent_ok())
	_ok("debug build bypasses the gate", _debug_bypass_active())
	save.call("set_v", "consent", "accepted", true)
	save.call("set_v", "consent", "policy_version", 1)

	print("\n── deleted screens are unroutable ──")
	var r0: Node = root.get_node_or_null("Router")
	var all_routes: Dictionary = r0.get("ROUTES")
	for gone: String in ["sponsor", "loading"]:
		_ok("'%s' route removed" % gone, not all_routes.has(gone))
		_ok("screens/%s/ deleted" % gone,
			not DirAccess.dir_exists_absolute("res://screens/" + gone))
	for name: String in all_routes.keys():
		_ok("route '%s' resolves" % name,
			ResourceLoader.exists(str(all_routes[name])))

	print("\n── routing ──")
	var router: Node = root.get_node_or_null("Router")
	var routes: Dictionary = router.get("ROUTES")
	_ok("'consent' route declared", routes.has("consent"))
	_ok("consent scene exists", ResourceLoader.exists(str(routes.get("consent", ""))))
	_ok("consent is a ROOT route", "consent" in router.get("ROOT_ROUTES"))

	print("\n── first-run back is swallowed ──")
	var gate: Node = packed.instantiate()
	gate.call("configure", {})
	root.add_child(gate)
	await process_frame
	_ok("back blocked on the mandatory gate", bool(gate.call("on_back_requested")))
	gate.queue_free()
	await process_frame

	var rev2: Node = packed.instantiate()
	rev2.call("configure", {"revisit": true})
	root.add_child(rev2)
	await process_frame
	_ok("back allowed on a revisit", not bool(rev2.call("on_back_requested")))
	rev2.queue_free()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d CONSENT CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)
