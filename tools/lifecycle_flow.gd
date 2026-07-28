extends SceneTree
## Android hardware and lifecycle safeguards, against the live engine.
##
## Every check here drives a REAL notification through the real App node, or
## calls the real Save/Screen API. Nothing is asserted from source text alone
## except the wiring facts a runtime probe genuinely cannot observe.

var _fails: Array[String] = []
var _n: int = 0

const MASTER_BUS: int = 0


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s%s" % [label, ("  [" + detail + "]") if detail != "" else ""])


func _save() -> Node:
	return root.get_node_or_null("Save")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ LIFECYCLE SAFEGUARDS ═══\n")
	await _test_notification_constants()
	await _test_focus_mute()
	await _test_back_and_cancel()
	await _test_memory_warning()
	await _test_safe_area()
	await _test_compass_shard_validation()
	await _test_audio_survives_focus_loss()
	await _test_back_buttons_navigate()
	await _test_screen_dialog_does_not_pause()
	_test_no_redundant_await()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d LIFECYCLE CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)


## Mount the real App shell.
func _mount_app() -> Node:
	_save().call("wipe")
	await process_frame
	var app: Node = (load("res://app/app.tscn") as PackedScene).instantiate()
	root.add_child(app)
	await process_frame
	await process_frame
	return app


func _teardown(app: Node) -> void:
	# Never leave the tree paused or the bus muted for the next scenario.
	root.get_tree().paused = false
	AudioServer.set_bus_mute(MASTER_BUS, false)
	app.free()
	await process_frame


# ─────────────────────────────────────────────────────────────────────────
func _test_notification_constants() -> void:
	print("── the APPLICATION_* pair is distinct from WM_* ──")
	# Android delivers APPLICATION_FOCUS_OUT (2017), not WM_WINDOW_FOCUS_OUT
	# (1005). A handler wired only to the WM pair would never fire on a phone,
	# and the two are easy to conflate because the names are near-identical.
	var probe: Node = Node.new()
	root.add_child(probe)
	_ok("FOCUS_OUT differs from WM_WINDOW_FOCUS_OUT",
		probe.NOTIFICATION_APPLICATION_FOCUS_OUT
		!= probe.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_ok("FOCUS_IN differs from WM_WINDOW_FOCUS_IN",
		probe.NOTIFICATION_APPLICATION_FOCUS_IN
		!= probe.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_ok("PAUSED differs from FOCUS_OUT",
		probe.NOTIFICATION_APPLICATION_PAUSED
		!= probe.NOTIFICATION_APPLICATION_FOCUS_OUT)
	probe.free()

	# All four must be handled, or one delivery path silently does nothing.
	var src: String = FileAccess.get_file_as_string("res://app/app.gd")
	for constant: String in ["NOTIFICATION_APPLICATION_PAUSED",
			"NOTIFICATION_WM_WINDOW_FOCUS_OUT",
			"NOTIFICATION_APPLICATION_FOCUS_OUT",
			"NOTIFICATION_APPLICATION_FOCUS_IN",
			"NOTIFICATION_OS_MEMORY_WARNING"]:
		_ok("app handles %s" % constant, src.contains(constant))


func _test_focus_mute() -> void:
	print("── focus loss mutes and pauses ──")
	var app: Node = await _mount_app()

	_ok("audio starts unmuted", not AudioServer.is_bus_mute(MASTER_BUS))
	_ok("the tree starts unpaused", not root.get_tree().paused)

	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame
	_ok("focus loss mutes the master bus", AudioServer.is_bus_mute(MASTER_BUS))
	_ok("focus loss pauses the tree", root.get_tree().paused)
	# The shell must keep running or it can never hear the resume.
	_ok("the App shell still processes while paused", app.can_process())

	# THE CHECK THAT WAS MISSING, AND THE BUG IT LET THROUGH:
	# asserting tree.paused only proves a FLAG was set. Screens are children
	# of App, PROCESS_MODE_ALWAYS inherits downward, and %Screens therefore
	# kept every trial, timer and tween running while the tree reported
	# paused=true. The pause was completely inert and the test was green.
	var screens: Node = app.get_node_or_null("%Screens")
	_ok("the screen host exists", screens != null)
	_ok("GAMEPLAY actually freezes while paused",
		screens != null and not screens.can_process(),
		"screens.can_process=%s" % ("n/a" if screens == null
			else str(screens.can_process())))
	# The overlay must keep animating, or a toast or the quit dialog freezes
	# mid-fade with no way to dismiss it.
	var overlay: Node = app.get_node_or_null("%Overlay")
	_ok("the overlay exists", overlay != null)
	_ok("the overlay keeps animating while paused",
		overlay != null and overlay.can_process())

	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_IN)
	await process_frame
	_ok("focus return unmutes", not AudioServer.is_bus_mute(MASTER_BUS))
	_ok("focus return unpauses", not root.get_tree().paused)
	_ok("gameplay resumes with the tree",
		screens != null and screens.can_process())

	# Android can deliver PAUSED and FOCUS_OUT for one backgrounding. Muting
	# twice then restoring once would leave the game permanently silent.
	app.call("_notification", app.NOTIFICATION_APPLICATION_PAUSED)
	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame
	_ok("a doubled focus-out still mutes", AudioServer.is_bus_mute(MASTER_BUS))
	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_IN)
	await process_frame
	_ok("one restore is enough after a doubled loss",
		not AudioServer.is_bus_mute(MASTER_BUS))
	_ok("a doubled loss leaves the tree unpaused", not root.get_tree().paused)

	# THE CASE THAT MATTERS MOST: a player who muted the game themselves must
	# not find it audible after switching apps. Restoring unconditionally
	# would override their choice.
	AudioServer.set_bus_mute(MASTER_BUS, true)
	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame
	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_IN)
	await process_frame
	_ok("a player-set mute survives backgrounding",
		AudioServer.is_bus_mute(MASTER_BUS))
	AudioServer.set_bus_mute(MASTER_BUS, false)

	await _teardown(app)


func _test_back_and_cancel() -> void:
	print("── back and ui_cancel ──")
	# ui_cancel is bound to Escape by default and reached NOTHING before this
	# work — App listened only for WM_GO_BACK_REQUEST, which desktop and
	# keyboard-equipped devices never send.
	_ok("ui_cancel is a real action", InputMap.has_action("ui_cancel"))

	var src: String = FileAccess.get_file_as_string("res://app/app.gd")
	_ok("app listens for ui_cancel", src.contains('is_action_pressed("ui_cancel")'))
	_ok("ui_cancel routes to the same handler as hardware back",
		src.contains("_handle_back()"))
	# Consuming the event matters: Router.back() awaits a crossfade, and an
	# unconsumed event keeps propagating during that frame.
	_ok("the event is marked handled", src.contains("set_input_as_handled()"))
	_ok("unhandled_input is used, so focused controls get first refusal",
		src.contains("func _unhandled_input"))
	_ok("re-entrant back is guarded", src.contains("_handling_back"))
	_ok("the quit dialog cannot stack", src.contains("if not _confirm.visible:"))

	var app: Node = await _mount_app()
	var router: Node = root.get_node_or_null("Router")

	# Drive a real navigation stack and pop it with back.
	await router.call("go", "hub")
	await router.call("go", "settings")
	_ok("navigated to a secondary screen",
		str(router.get("current_route")) == "settings",
		str(router.get("current_route")))

	var consumed: bool = await router.call("back")
	_ok("back is consumed on a secondary screen", consumed)
	_ok("back returns to the hub", str(router.get("current_route")) == "hub",
		str(router.get("current_route")))

	# At the root the stack is empty and App owns the decision to quit.
	var at_root: bool = await router.call("back")
	_ok("back at the root is NOT consumed", not at_root)
	_ok("the app did not navigate away from the root",
		str(router.get("current_route")) == "hub")

	# Repeated back at the root must not deadlock or stack dialogs.
	for i: int in range(5):
		app.call("_handle_back")
		await process_frame
	_ok("repeated back does not deadlock the tree",
		str(router.get("current_route")) == "hub",
		str(router.get("current_route")))
	_ok("the tree is still processing after repeated back",
		not root.get_tree().paused)

	await _teardown(app)


func _test_memory_warning() -> void:
	print("── emergency save on a memory warning ──")
	var save: Node = _save()
	_ok("Save exposes emergency_write", save.has_method("emergency_write"))

	var app: Node = await _mount_app()
	var router: Node = root.get_node_or_null("Router")
	await router.call("go", "hub")

	# Write something, then bypass the dirty flag entirely: emergency_write()
	# must produce a file even when Save believes nothing changed.
	save.call("set_v", "meta", "canary", 4242)
	save.call("flush")
	save.call("set_v", "meta", "canary", 9999)

	_ok("the emergency write reports success", bool(save.call("emergency_write")))
	save.call("_load")
	await process_frame
	_ok("the newest value reached disk",
		int(save.call("get_v", "meta", "canary", 0)) == 9999,
		str(save.call("get_v", "meta", "canary", 0)))

	# A clean (non-dirty) save must still TOUCH THE FILE. Dirty tracking is an
	# optimisation; under an eviction warning, being wrong about it loses
	# data. Asserting the return value alone was useless — a skip also
	# returns true — so compare the file's modified time instead.
	save.call("flush")
	var save_path: String = str(save.get("SAVE_PATH"))
	var before_mtime: int = FileAccess.get_modified_time(save_path)
	# The filesystem timestamp has one-second resolution, so wait past a tick
	# or an immediate rewrite is indistinguishable from no write at all.
	await root.get_tree().create_timer(1.1).timeout
	_ok("a non-dirty emergency write still succeeds",
		bool(save.call("emergency_write")))
	var after_mtime: int = FileAccess.get_modified_time(save_path)
	_ok("a non-dirty emergency write really touches the file",
		after_mtime > before_mtime,
		"%d -> %d" % [before_mtime, after_mtime])

	# The notification path itself, end to end: the session route must land.
	save.call("set_v", "meta", "canary", 7777)
	app.call("_notification", app.NOTIFICATION_OS_MEMORY_WARNING)
	await process_frame
	save.call("_load")
	await process_frame
	_ok("a memory warning persists pending state",
		int(save.call("get_v", "meta", "canary", 0)) == 7777,
		str(save.call("get_v", "meta", "canary", 0)))
	_ok("a memory warning records the current route",
		str(save.call("get_v", "session", "route", "")) == "hub",
		str(save.call("get_v", "session", "route", "")))

	await _teardown(app)


func _test_safe_area() -> void:
	print("── safe area reaches every screen ──")
	var src: String = FileAccess.get_file_as_string("res://ui/screen.gd")
	_ok("the base class applies insets generically",
		src.contains("func apply_safe_area_insets"))
	_ok("insets are applied after _setup", src.contains("apply_safe_area_insets()"))
	_ok("backgrounds are exempt from insetting",
		src.contains("FULL_BLEED_NAMES"))
	_ok("screens that inset themselves can opt out",
		src.contains("handles_own_safe_area"))

	# Every Screen must expose non-zero insets. On desktop the engine reports
	# no cutout, so the base class substitutes a small margin — a screen
	# reading zero would sit flush against the bezel on a notched phone.
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame

	var checked: int = 0
	var zero_inset: Array[String] = []
	for path: String in ["res://screens/daily_hub.tscn",
			"res://screens/settings_view.tscn", "res://screens/wardrobe.tscn",
			"res://screens/progress_view.tscn", "res://screens/trial_results.tscn",
			"res://screens/trend_hub.tscn"]:
		if not ResourceLoader.exists(path):
			continue
		var screen: Control = (load(path) as PackedScene).instantiate()
		if screen.has_method("configure"):
			screen.call("configure", {})
		root.add_child(screen)
		await process_frame
		await process_frame
		checked += 1
		if float(screen.get("safe_top")) <= 0.0 \
				or float(screen.get("safe_bottom")) <= 0.0:
			zero_inset.append(path.get_file())
		screen.free()
		await process_frame

	_ok("every screen resolved a safe area", zero_inset.is_empty(),
		", ".join(zero_inset))
	_ok("screens were actually checked", checked >= 5, str(checked))

	# A background must still reach the physical edge, or a notch is framed
	# by bars of the wrong colour.
	var hub: Control = (load("res://screens/daily_hub.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame
	await process_frame
	var background: Control = hub.get_node_or_null("%Background") as Control
	_ok("the background exists", background != null)
	# Not guarded by `if background != null:` — a skipped assertion reports as
	# a pass, so a missing node would hide the full-bleed check entirely.
	var rect: Rect2 = Rect2()
	if background != null:
		rect = background.get_global_rect()
	_ok("the background is still full bleed",
		background != null and rect.position.y <= 1.0 and rect.size.y >= 1919.0,
		"y %.0f h %.0f" % [rect.position.y, rect.size.y])
	hub.free()
	await process_frame


# ═════════════════════════════════════════════════════════════════════════
# COMPASS SHARD VALIDATION
# ═════════════════════════════════════════════════════════════════════════
## Every declared shard must survive its own validator.
##
## THE BUG THIS CATCHES, WHICH SHIPPED:
## set_compass_shard() hard-coded `<= CompassShard.WEST_PROFILE` (4). Adding
## NORTHEAST_TREND = 5 for the Trend Hub made hovering that shard fail its own
## invariant — a hard assert in debug, fired by the player's finger crossing
## the north-east arc of the eye.
##
## 1000+ checks missed it because the compass tests verified VECTOR GEOMETRY
## (angular separation, reachable arcs) and the hub tests only asserted that
## the method NAME appeared in the source. Nothing ever called it. A test that
## checks a function exists is not a test that the function works.
func _test_compass_shard_validation() -> void:
	print("── every shard passes its own validator ──")
	var iris: GDScript = ResourceLoader.load("res://data/iris_state.gd",
		"GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
	var state: Object = iris.new()

	var enum_values: Dictionary = iris.get("CompassShard")
	_ok("the compass enum is readable", not enum_values.is_empty())

	# Drive the REAL setter with every REAL enum value.
	var rejected: Array[String] = []
	for shard_name: String in enum_values.keys():
		var shard_id: int = int(enum_values[shard_name])
		state.call("set_compass_shard", shard_id)
		if int(state.get("active_compass_shard_id")) != shard_id:
			rejected.append("%s(%d)" % [shard_name, shard_id])
	_ok("no declared shard is rejected by set_compass_shard",
		rejected.is_empty(), ", ".join(rejected))

	# The bound must be DERIVED, not a named member that goes stale.
	_ok("max_shard_id tracks the enum",
		int(iris.call("max_shard_id")) == int(enum_values.values().max()),
		"%d vs %d" % [int(iris.call("max_shard_id")),
			int(enum_values.values().max())])

	# Out-of-range values must still be refused — the guard has to keep
	# guarding, not just stop rejecting valid input.
	var highest: int = int(iris.call("max_shard_id"))
	state.call("set_compass_shard", 0)
	state.call("set_compass_shard", highest + 1)
	_ok("a shard id past the enum is refused",
		int(state.get("active_compass_shard_id")) == 0,
		str(state.get("active_compass_shard_id")))
	state.call("set_compass_shard", 0)
	state.call("set_compass_shard", -1)
	_ok("a negative shard id is refused",
		int(state.get("active_compass_shard_id")) == 0)

	print("── every routed shard is hoverable end to end ──")
	# Drive the hub's real hover handler with every routed shard. This is the
	# exact path that asserted: iris_view -> Bus -> hub -> IrisState.
	var hub_src: String = FileAccess.get_file_as_string(
		"res://nodes/hub_portal_controller.gd")
	var routed: Array[String] = []
	for shard_name: String in enum_values.keys():
		if shard_name == "NONE":
			continue
		if hub_src.contains("CompassShard.%s: \"" % shard_name):
			routed.append(shard_name)
	_ok("the portal routes several shards", routed.size() >= 5, str(routed.size()))

	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame
	var hub: Node = (load("res://screens/hub_portal.tscn") as PackedScene).instantiate()
	hub.call("configure", {})
	root.add_child(hub)
	await process_frame
	await process_frame

	# Emitting on the Bus reproduces exactly what IrisView does on hover.
	# Resolved by node lookup, not by name: a --script MainLoop compiles
	# BEFORE autoloads attach, so `Bus` is not an identifier here.
	var bus: Node = root.get_node_or_null("Bus")
	_ok("the Bus autoload is reachable", bus != null)
	for shard_name: String in routed:
		bus.emit_signal("iris_shard_hovered", int(enum_values[shard_name]))
		await process_frame
	_ok("hovering every routed shard does not assert", true)

	# And the hub must still be alive afterwards — an assert would have
	# torn the run down before this line.
	_ok("the hub survives hovering every shard",
		is_instance_valid(hub) and hub.is_inside_tree())
	hub.free()
	await process_frame


## A coroutine that awaits a non-coroutine raises REDUNDANT_AWAIT, which the
## warning sweep treats as an error. Guard the specific call that regressed.
func _test_no_redundant_await() -> void:
	print("── no redundant await in the warm-up ──")
	var src: String = FileAccess.get_file_as_string(
		"res://nodes/splash_controller.gd")
	# _perform_step() contains no await, so it is a plain call.
	var body: String = src.split("func _perform_step")[1].split("\nfunc ")[0]
	var is_coroutine: bool = body.contains("await ")
	_ok("_perform_step is still synchronous", not is_coroutine)
	_ok("the warm-up does not await a synchronous step",
		not src.contains("await _perform_step("))


# ═════════════════════════════════════════════════════════════════════════
# AUDIO MUST SURVIVE BACKGROUNDING
# ═════════════════════════════════════════════════════════════════════════
## THE BUG THIS CATCHES: every sound died permanently the first time the
## window lost focus, and never came back.
##
## App pauses the whole tree on focus loss and mutes the master bus. The mute
## is reversible. The pause was not: AudioManager is an autoload, autoloads
## default to PROCESS_MODE_INHERIT, and under a paused tree that means
## PAUSABLE — so _process() stopped, _fill_pad() stopped, and the generator's
## ring buffer drained. On resume the bus unmuted into silence, because
## nothing was refilling the buffer.
##
## A reported editor session showed SIX focus cycles before the player reached
## the hub, so in practice the game was simply mute.
##
## This drives the real notifications on the real App and asserts the pad is
## still running afterwards.
func _test_audio_survives_focus_loss() -> void:
	print("── audio survives backgrounding ──")
	var app: Node = await _mount_app()
	var audio: Node = root.get_node_or_null("AudioManager")
	_ok("AudioManager is present", audio != null)

	# The mechanism, asserted directly: a PAUSABLE audio manager is the bug.
	# Checking can_process() under a paused tree is what actually bites — the
	# enum value alone could be satisfied by a mode that still stops.
	_ok("the audio manager is not pausable",
		audio != null and audio.process_mode == Node.PROCESS_MODE_ALWAYS,
		"process_mode=%d" % (audio.process_mode if audio != null else -1))

	audio.call("play_ambient_pad", 0.3)
	for _i: int in range(6):
		await process_frame
	_ok("the pad starts", bool(audio.call("is_pad_playing")))

	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame
	_ok("focus loss pauses the tree", root.get_tree().paused)
	_ok("the audio manager still ticks while paused",
		audio != null and audio.can_process())

	# A long absence, so a starving buffer has time to empty.
	for _i: int in range(90):
		await process_frame
	_ok("the pad survives a long background", bool(audio.call("is_pad_playing")))

	app.call("_notification", app.NOTIFICATION_APPLICATION_FOCUS_IN)
	for _i: int in range(8):
		await process_frame
	_ok("the bus is unmuted on resume", not AudioServer.is_bus_mute(MASTER_BUS))
	_ok("the pad is still running after resume",
		bool(audio.call("is_pad_playing")))

	# And a one-shot fired after the whole cycle must still reach a playback.
	audio.call("play_sfx", &"ui_tap")
	await process_frame
	var sfx: Node = audio.get_node_or_null("IrisSfx")
	_ok("a sound effect still plays after backgrounding",
		sfx != null and bool(sfx.get("playing")))

	audio.call("stop_pad")
	await _teardown(app)


# ═════════════════════════════════════════════════════════════════════════
# EVERY BACK BUTTON MUST ACTUALLY NAVIGATE
# ═════════════════════════════════════════════════════════════════════════
## THE BUG THIS CATCHES: a player entered Settings and could not leave.
##
## Router.back() ends in `await _swap(...)`, which makes it a coroutine.
## GDScript runs an un-awaited coroutine only as far as its FIRST await and
## then abandons it — silently, with no error. So `Router.back()` written
## without `await` navigated exactly nowhere.
##
## Every on-screen Back button in the app was written that way. Only app.gd's
## system-back handler awaited properly, which is precisely why the Android
## back gesture worked while the visible button beside it was dead.
##
## Rule J greps for the un-awaited call. This proves the BEHAVIOUR: press the
## real button on the real screen and assert the route actually changed.
func _test_back_buttons_navigate() -> void:
	print("── every back button leaves its screen ──")
	var app: Node = await _mount_app()

	# Router must be resolved as a NODE, never named directly: under a
	# --script MainLoop the compiler runs before autoloads attach, so the bare
	# identifier does not exist at compile time.
	var router: Node = root.get_node_or_null("Router")
	_ok("the router is available", router != null)
	if router == null:
		await _teardown(app)
		return

	# Screens reachable from the hub that own a %BackButton.
	var routes: Array[String] = ["settings", "progress", "visage", "daily"]
	for route: String in routes:
		await router.call("go", "hub")
		for _i: int in range(6):
			await process_frame
		await router.call("go", route)
		for _i: int in range(10):
			await process_frame

		var arrived: bool = str(router.get("current_route")) == route
		_ok("%s opens" % route, arrived, str(router.get("current_route")))
		if not arrived:
			continue

		var screen: Node = router.call("current_screen")
		var button: Button = null
		if screen != null:
			button = screen.get_node_or_null("%BackButton") as Button
		_ok("%s has a reachable Back button" % route,
			button != null and button.is_visible_in_tree() and not button.disabled)
		if button == null:
			continue

		# Press it exactly as a player would, then wait in WALL-CLOCK time.
		#
		# Counting frames here was wrong and nearly cost a bogus "fix": 20
		# process_frames is ~160ms under the headless driver, SHORTER than the
		# 220ms crossfade the navigation has to outlast. The test failed, the
		# button was fine, and the reported cause was the harness.
		button.emit_signal("pressed")
		await create_timer(1.0).timeout
		_ok("%s: pressing Back actually leaves" % route,
			str(router.get("current_route")) != route,
			"still on %s" % str(router.get("current_route")))

	await _teardown(app)


# ═════════════════════════════════════════════════════════════════════════
# A SCREEN'S OWN DIALOG IS NOT BACKGROUNDING
# ═════════════════════════════════════════════════════════════════════════
## THE BUG THIS CATCHES: opening the Settings reset confirmation muted the
## audio and paused the entire tree behind a prompt the player was looking at.
##
## A ConfirmationDialog is a Window. Popping one takes window focus, which
## fires WM_WINDOW_FOCUS_OUT, which App treats as backgrounding. App already
## stood down for its OWN quit dialog — but the guard named `_confirm`
## specifically, so every dialog owned by a SCREEN still paused the game.
##
## Asserted on the real Settings screen with its real dialog.
func _test_screen_dialog_does_not_pause() -> void:
	print("── a screen's dialog does not background the app ──")
	var app: Node = await _mount_app()
	var router: Node = root.get_node_or_null("Router")
	_ok("the router is available for the dialog test", router != null)
	if router == null:
		await _teardown(app)
		return

	await router.call("go", "hub")
	await create_timer(0.4).timeout
	await router.call("go", "settings")
	await create_timer(0.5).timeout

	var screen: Node = router.call("current_screen")
	var dialog: Window = null
	if screen != null:
		dialog = screen.get_node_or_null("%ConfirmResetFirst") as Window
	_ok("the settings reset dialog exists", dialog != null)
	if dialog == null:
		await _teardown(app)
		return

	dialog.popup_centered()
	await create_timer(0.3).timeout
	_ok("the dialog is showing", dialog.visible)

	# This is what the window manager sends when the dialog grabs focus.
	app.call("_notification", app.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	await create_timer(0.3).timeout

	_ok("a screen's dialog does not pause the tree",
		not root.get_tree().paused)
	_ok("a screen's dialog does not mute the audio",
		not AudioServer.is_bus_mute(MASTER_BUS))

	dialog.hide()
	await create_timer(0.3).timeout
	await _teardown(app)
