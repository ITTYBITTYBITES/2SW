extends Control
## App — the persistent root. Lives for the whole process; never reloaded.
##
## THE V1 BUGS THIS KILLS:
##
## 1. "Samsung: leave the app and come back, the whole game reloads."
##    v1 navigated with change_scene_to_file(), so ALL state lived in the
##    current scene. OneUI kills backgrounded activities aggressively; on
##    return Godot cold-boots to the main scene and the player is dumped back
##    at the startup splash having lost their run.
##    Fix, two parts:
##      a) Screens are children of this node, so navigation never destroys the
##         shell — an in-process background/foreground keeps everything.
##      b) A genuine process kill is caught on boot by reading Save's session
##         snapshot and resuming to that route instead of replaying the intro.
##
## 2. "Back exits the app from inside a game."
##    quit_on_go_back is now false and every back press lands here, then goes
##    to Router.back(). Only a confirmed back at the root can quit.

## If the player was away longer than this, treat it as a fresh session
## (show the intro again). Shorter, and we restore silently.
const RESUME_GRACE_SEC := 90 * 60

## Routes we never resume into — they're transient or mid-flight.
const NO_RESUME := ["splash", "results", "trial"]

## Index of the Master audio bus. Always 0 in Godot, named for legibility.
const MASTER_BUS: int = 0

@onready var _screens: Control = %Screens
## Needed again: the overlay must keep animating while the tree is paused, so
## a toast or the quit dialog is not frozen mid-fade.
@onready var _overlay: CanvasLayer = %Overlay
@onready var _toasts: VBoxContainer = %Toasts
@onready var _confirm: ConfirmationDialog = %ConfirmQuit

var _paused_at: int = 0
var _has_focus := true

## Master-bus mute state captured before WE muted it, so restoring cannot
## un-mute a player who had muted the game themselves.
var _mute_was_set: bool = false
var _mute_applied: bool = false

## True while a back navigation is mid-flight. Router.back() awaits a
## crossfade, so without this a rapid double-press could start two
## navigations and leave the stack inconsistent.
var _handling_back: bool = false


func _ready() -> void:
	# PROCESS_MODE_ALWAYS on THIS node only, plus the overlay.
	#
	# THE BUG THIS FIXES: setting it here alone made the pause completely
	# inert. Screens are children of App, ALWAYS inherits downward, and
	# %Screens therefore kept every trial, timer and tween running while the
	# tree reported paused=true. Measured: with tree.paused true, the mounted
	# mini-game still returned can_process()==true.
	#
	# App needs ALWAYS so it can hear the resume; the overlay needs it so a
	# toast or the quit dialog still animates. %Screens must NOT have it, or
	# there is nothing left for the pause to stop.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_screens.process_mode = Node.PROCESS_MODE_PAUSABLE
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS

	# We handle every back press and close request ourselves.
	get_tree().set_auto_accept_quit(false)

	Router.bind_host(_screens)
	# Rule B: subscribe here, disconnect in _exit_tree.
	Bus.toast.connect(_on_toast)

	_confirm.confirmed.connect(_do_quit)
	_confirm.dialog_text = "Leave Witness?"
	_confirm.title = "Confirm"

	_boot()


func _exit_tree() -> void:
	if Bus.toast.is_connected(_on_toast):
		Bus.toast.disconnect(_on_toast)


# ─────────────────────────────────────────────────────────────────────────
# Boot / resume
# ─────────────────────────────────────────────────────────────────────────
func _boot() -> void:
	# CONSENT GATE FIRST — always. A resumable session must never route around
	# it, or a player who force-quit on the consent screen comes back straight
	# into the game having never accepted. (Caught by test_boot.py.)
	# Consent is gated on policy VERSION, not a bare boolean, so a material
	# change re-prompts. The SPLASH resolves the destination (consent / intro /
	# hub) once its warm-up finishes, so a first-time player still sees the
	# ident before the legal gate rather than being met by a wall of text.
	if not ConsentController.is_satisfied():
		Log.info("App", "consent required; splash will route to it")
		await Router.go("splash")
		return

	var session := Save.read_session()
	var resumed := false

	if not session.is_empty():
		var route := str(session.get("route", ""))
		var away := int(Time.get_unix_time_from_system()) - int(session.get("unix", 0))
		# A stored route can outlive the screen it names. Sessions persist
		# across updates, so an install whose last session was on a route we
		# later deleted would call Router.go() with an id the table no longer
		# has — and Router guards that with Log.must(), which hard-asserts in
		# a debug build. Verified reachable: `home` was a live session route
		# before it was removed.
		#
		# Checked HERE rather than trusted, because the alternative is an
		# update that crashes on first launch for exactly the players who were
		# mid-session when they updated.
		var known: bool = Router.ROUTES.has(route)
		if not known and route != "":
			Log.info("App", "dropping stale session route '%s'" % route)

		if known and route not in NO_RESUME and away < RESUME_GRACE_SEC:
			Log.info("App", "resuming '%s' after %ds away" % [route, away])
			await Router.go(route, session.get("payload", {}))
			resumed = true
		else:
			Log.d("App", "session not resumable (route=%s away=%ds)" % [route, away])

	if not resumed:
		# Cold start with consent already granted -> full startup sequence.
		await Router.go("splash")


# ─────────────────────────────────────────────────────────────────────────
# Android lifecycle
# ─────────────────────────────────────────────────────────────────────────
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_handle_back()

		NOTIFICATION_WM_CLOSE_REQUEST:
			_persist("close")
			_do_quit()

		# FOUR distinct notifications, not two. APPLICATION_FOCUS_OUT (2017) is
		# a different constant from WM_WINDOW_FOCUS_OUT (1005), and Android
		# delivers the APPLICATION_* pair — a handler that only listened for
		# the WM_* pair would never fire on a phone. Verified against the
		# engine rather than assumed.
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT, \
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_on_focus_lost()

		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_WM_WINDOW_FOCUS_IN, \
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_on_focus_gained()

		# The OS is about to start evicting processes. This is the last hook
		# we are guaranteed before a kill, so the write is immediate and
		# synchronous — a deferred flush may never run.
		# Save handles this notification too, for its own data. App adds the
		# session route, which Save does not know about — both must land, and
		# an emergency_write() forces the file out regardless of dirty state.
		NOTIFICATION_OS_MEMORY_WARNING:
			Log.warn("App", "memory warning; forcing an emergency save")
			if Router.current_route != "":
				Save.write_session(Router.current_route, Router.current_payload)
			Save.emergency_write()


## Focus lost: silence the game and freeze play.
##
## MUTING THE BUS, NOT THE MIXER: AudioManager's levels are the player's
## settings and must survive backgrounding untouched. Muting the Master bus
## leaves every stored level intact, so restoring is a single flag rather than
## a re-application of state that may have changed while we were away.
##
## Idempotent by guard: Android can deliver PAUSED and FOCUS_OUT for the same
## backgrounding, and muting twice then restoring once would leave the game
## silent.
func _on_focus_lost() -> void:
	if not _has_focus:
		return

	# AN IN-APP DIALOG IS NOT BACKGROUNDING.
	#
	# Popping the quit confirmation takes window focus, which fires
	# WM_WINDOW_FOCUS_OUT — so the game muted itself and paused the tree
	# behind its own prompt, and stayed that way because the matching
	# FOCUS_IN never arrived while the dialog held focus. Reproduced directly:
	# three back presses at the root left `paused=true` with the route
	# unchanged.
	#
	# A visible exclusive dialog means the player is still in the app, so the
	# lifecycle handler must stand down.
	#
	# ANY of our dialogs, not just App's own. The original guard checked only
	# `_confirm`, which meant a dialog owned by a SCREEN — the two Settings
	# reset confirmations, the trial forfeit prompt, the wardrobe drop modal —
	# took window focus, fired WM_WINDOW_FOCUS_OUT, and App dutifully muted the
	# audio and paused the entire tree behind a prompt the player was actively
	# looking at.
	#
	# That is the same fault already fixed once for App's own quit dialog; it
	# was simply never generalised to the screens. Found while investigating a
	# report of being stuck in Settings.
	if _any_dialog_visible():
		Log.d("App", "focus taken by our own dialog; not backgrounding")
		return

	_has_focus = false
	_paused_at = int(Time.get_unix_time_from_system())

	# Remember whether the bus was ALREADY muted. A player who muted the game
	# deliberately must not find it audible again after switching apps.
	_mute_was_set = AudioServer.is_bus_mute(MASTER_BUS)
	if not _mute_was_set:
		AudioServer.set_bus_mute(MASTER_BUS, true)
		_mute_applied = true

	# Freeze gameplay. The tree pause stops _process on anything that has not
	# opted out; App itself keeps running so it can hear the resume.
	get_tree().paused = true

	_persist("pause")
	Bus.app_paused.emit()
	Log.d("App", "focus lost — audio muted, tree paused")


## Is ANY of our own dialogs on screen?
##
## Walks the live tree for a visible Window rather than keeping a registry:
## screens create and free their own dialogs, and a registry would need every
## screen to remember to sign up — which is exactly the kind of bookkeeping
## that gets forgotten and reintroduces the bug.
func _any_dialog_visible() -> bool:
	if _confirm != null and _confirm.visible:
		return true
	return _has_visible_window(get_tree().root)


func _has_visible_window(node: Node) -> bool:
	for child: Node in node.get_children():
		if child is Window and (child as Window).visible:
			return true
		if _has_visible_window(child):
			return true
	return false


## Focus regained: restore exactly what we changed, and nothing else.
func _on_focus_gained() -> void:
	if _has_focus:
		return
	_has_focus = true

	# Only un-mute if WE muted. Restoring unconditionally would override a
	# player who had the game muted before they left.
	if _mute_applied:
		AudioServer.set_bus_mute(MASTER_BUS, false)
		_mute_applied = false

	get_tree().paused = false

	var away := int(Time.get_unix_time_from_system()) - _paused_at
	Log.d("App", "resumed after %ds — audio restored" % away)
	Bus.app_resumed.emit(away)


## Flush everything that must survive a kill. Called on pause, close, and an
## OS memory warning — these are the only reliable hooks Android gives us.
func _persist(reason: String) -> void:
	if Router.current_route != "":
		Save.write_session(Router.current_route, Router.current_payload)
	Save.flush()
	Log.d("App", "persisted (%s)" % reason)


## Escape / ui_cancel routes to the SAME path as the hardware back button.
##
## Android delivers WM_GO_BACK_REQUEST, but a desktop build, a Chromebook, or
## a phone with a physical keyboard delivers ui_cancel instead — which reached
## nothing at all before this. Verified: ui_cancel is bound to Escape by
## default and no handler existed.
##
## _unhandled_input, not _input: a focused LineEdit or an open dialog gets
## first refusal, so Escape dismisses the control the player is actually
## looking at rather than navigating out from under them.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# Mark it consumed BEFORE the await. Router.back() yields on the
	# crossfade, and an unconsumed event would keep propagating during that
	# frame — the deadlock risk is a second back arriving mid-transition.
	get_viewport().set_input_as_handled()
	_handle_back()


## The single back path. Re-entrancy is the hazard here: a second press
## arriving while a crossfade is still running would stack two navigations,
## so Router guards it internally and this guards the confirm dialog.
func _handle_back() -> void:
	if _handling_back:
		Log.d("App", "back ignored; one is already in flight")
		return
	_handling_back = true

	var consumed: bool = await Router.back()
	_handling_back = false
	if not consumed:
		# At the root of the stack. Ask before killing the process — but only
		# once; a repeated back must not stack dialogs on top of each other.
		if not _confirm.visible:
			_confirm.popup_centered()


func _do_quit() -> void:
	_persist("quit")
	get_tree().quit()


# ─────────────────────────────────────────────────────────────────────────
# Toasts
# ─────────────────────────────────────────────────────────────────────────
func _on_toast(text: String, icon: String) -> void:
	var label := Label.new()
	label.text = ("%s  %s" % [icon, text]) if icon != "" else text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_HEADING))
	label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	label.modulate.a = 0.0
	_toasts.add_child(label)

	var tw := create_tween()
	tw.tween_property(label, "modulate:a", 1.0, Palette.duration(Palette.DURATION_FAST))
	tw.tween_interval(1.9)
	tw.tween_property(label, "modulate:a", 0.0, Palette.duration(Palette.DURATION_SLOW))
	tw.tween_callback(label.queue_free)
