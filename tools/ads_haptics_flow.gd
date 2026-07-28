extends SceneTree
## Live-engine verification for AdManager and HapticsManager.
##
## Autoloads cannot be named statically in a --script MainLoop (compiled before
## they attach), so everything is resolved by node lookup at runtime.

var _fails: Array[String] = []
var _n: int = 0

func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	print("  %s  %s%s" % ["PASS" if cond else "FAIL", label,
		("  [" + detail + "]") if (detail != "" and not cond) else ""])
	if not cond:
		_fails.append(label)

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	print("\n═══ ADS + HAPTICS (live engine) ═══\n")
	var ads: Node = root.get_node_or_null("AdManager")
	var haptics: Node = root.get_node_or_null("HapticsManager")
	var cfg: Node = root.get_node_or_null("Cfg")
	var save: Node = root.get_node_or_null("Save")

	print("── autoloads ──")
	_ok("AdManager attached", ads != null)
	_ok("HapticsManager attached", haptics != null)
	if ads == null or haptics == null:
		_report()
		return

	print("\n── unit id resolution ──")
	var unit: String = str(ads.call("rewarded_unit_id"))
	var dev: bool = bool(ads.call("is_dev_mode"))
	_ok("dev mode derived from build", dev == bool(cfg.get("use_test_ads")))
	_ok("a unit id always resolves", unit != "")
	_ok("debug build uses Google test unit",
		not dev or unit.begins_with("ca-app-pub-3940256099942544"), unit)
	_ok("production ids loaded from Cfg",
		str(cfg.get("admob_rewarded_id")) != "", "build_config.cfg missing?")
	# Assert the SHAPE, not the value. Writing the literal here would leak it
	# into tracked source, which is exactly what build_config.cfg prevents.
	var prod_unit: String = str(cfg.get("admob_rewarded_id"))
	_ok("production id is well-formed",
		prod_unit.begins_with("ca-app-pub-") and prod_unit.contains("/"))
	_ok("production id is not a test unit",
		not prod_unit.contains("3940256099942544"))
	_ok("iOS falls back (no iOS units exist)",
		str(cfg.get("ios_rewarded_id")) == "")

	print("\n── fallback mode grants the reward ──")
	ads.call("set_fallback_mode", true)
	ads.call("reset_daily_counter")
	_ok("running in fallback", bool(ads.call("is_fallback_mode")))

	var got: Array[String] = []
	var dismissed: Array[String] = []
	ads.connect("ad_watched_successfully", func(p: String) -> void: got.append(p))
	ads.connect("ad_dismissed_early", func(p: String) -> void: dismissed.append(p))

	ads.call("simulate_reward", "wizard_hat")
	await process_frame
	_ok("reward signal carries the placement", got.size() == 1 and got[0] == "wizard_hat", str(got))
	_ok("watch counted against the cap",
		int(ads.call("watches_remaining")) == ads.get("MAX_REWARDED_PER_DAY") - 1)

	ads.call("simulate_dismiss", "vines")
	await process_frame
	_ok("dismissal signals separately", dismissed.size() == 1 and dismissed[0] == "vines")
	_ok("dismissal does NOT count as a watch",
		int(ads.call("watches_remaining")) == ads.get("MAX_REWARDED_PER_DAY") - 1)

	print("\n── daily cap ──")
	ads.call("reset_daily_counter")
	var cap: int = int(ads.get("MAX_REWARDED_PER_DAY"))
	for i: int in range(cap):
		ads.call("simulate_reward", "grind_%d" % i)
	await process_frame
	_ok("cap reached after %d watches" % cap, int(ads.call("watches_remaining")) == 0)
	_ok("show refused at the cap", not bool(ads.call("show_rewarded", "blocked")))
	ads.call("reset_daily_counter")
	_ok("reset restores availability", int(ads.call("watches_remaining")) == cap)

	print("\n── cap survives a reload ──")
	ads.call("simulate_reward", "persist_check")
	save.call("flush")
	_ok("counter persisted", int(save.call("get_v", "ads", "watches", 0)) >= 1)
	ads.call("reset_daily_counter")

	print("\n── haptics gate ──")
	haptics.call("set_supported_for_test", true)
	haptics.call("reset_counters")
	haptics.call("set_enabled", true)
	haptics.call("pulse", &"ui_tap")
	haptics.call("pulse", &"facet_match")
	_ok("enabled: pulses delivered", int(haptics.call("delivered_count")) == 2,
		str(haptics.call("delivered_count")))
	_ok("enabled: nothing suppressed", int(haptics.call("suppressed_count")) == 0)

	haptics.call("reset_counters")
	haptics.call("set_enabled", false)
	for event: StringName in [&"ui_tap", &"facet_match", &"sequence_step", &"error"]:
		haptics.call("pulse", event)
	_ok("disabled: ZERO delivered", int(haptics.call("delivered_count")) == 0,
		str(haptics.call("delivered_count")))
	_ok("disabled: all four suppressed", int(haptics.call("suppressed_count")) == 4)

	print("\n── haptics respects hardware ──")
	haptics.call("set_enabled", true)
	haptics.call("set_supported_for_test", false)
	haptics.call("reset_counters")
	haptics.call("pulse", &"ui_tap")
	_ok("unsupported device: suppressed", int(haptics.call("delivered_count")) == 0)
	_ok("suppression is recorded", int(haptics.call("suppressed_count")) == 1)

	print("\n── haptics persistence ──")
	haptics.call("set_supported_for_test", true)
	haptics.call("set_enabled", false)
	_ok("preference written to Save", not bool(save.call("setting", "haptics", true)))
	haptics.call("set_enabled", true)
	_ok("preference restored", bool(save.call("setting", "haptics", false)))

	print("\n── patterns ──")
	haptics.call("reset_counters")
	haptics.call("set_enabled", true)
	haptics.call("pattern", &"trial_complete")
	await process_frame
	_ok("multi-pulse pattern fires", int(haptics.call("delivered_count")) >= 1)

	print("\n── wardrobe integration ──")
	var wardrobe_src: String = FileAccess.get_file_as_string(
		"res://nodes/wardrobe_controller.gd")
	_ok("stub replaced by AdManager call", "AdManager.show_rewarded" in wardrobe_src)
	_ok("grant moved to the reward callback", "_on_ad_reward" in wardrobe_src)
	_ok("dismissal handled", "_on_ad_dismissed" in wardrobe_src)
	_ok("pending item tracked", "_pending_ad_def" in wardrobe_src)

	_report()

func _report() -> void:
	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d ADS/HAPTICS CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)
