extends Node
## Router — the single owner of "what is on screen", with a real back stack.
##
## THE V1 BUG THIS KILLS:
## v1 had 19 hardcoded change_scene_to_file() calls across 12 scripts, and
## `quit_on_go_back` left at its default of true. So the Android back button
## quit the app outright from any screen that didn't hand-roll a
## NOTIFICATION_WM_GO_BACK_REQUEST handler — and no trial scene did. Back
## during a trial = instant app exit, losing the run.
##
## Here: back is a stack pop. Screens declare their own back policy. The only
## place that can quit the app is a confirmed back press at the root.
##
## Screens are swapped as children of a persistent host (App), NOT via
## change_scene_to_file(). That means autoloads and the App shell survive every
## transition, transitions can cross-fade, and there is exactly one place that
## knows how a screen is born and how it dies.

signal navigated(route: String, payload: Dictionary)

## Route table. The ONLY mapping from name to scene.
const ROUTES := {
	"splash":   "res://screens/splash/splash.tscn",
	"consent":  "res://screens/consent/consent.tscn",
	"hub":      "res://screens/hub_portal.tscn",
	"trial":    "res://screens/trial_host.tscn",
	"results":  "res://screens/trial_results.tscn",
	"progress": "res://screens/progress_view.tscn",
	"visage":   "res://screens/wardrobe.tscn",
	"daily":    "res://screens/daily_hub.tscn",
	"chrono_card": "res://screens/chrono_pulse/result_card.tscn",
	"trend_hub": "res://screens/trend_hub.tscn",
	"settings": "res://screens/settings_view.tscn",
}

## Routes that reset the stack rather than pushing onto it. Reaching one of
## these means "you are home now"; back from here exits (with confirm).
const ROOT_ROUTES := ["hub", "splash", "consent"]

## Set by App on ready. Router never touches the tree directly.
var _host: Node = null

var _stack: Array[Dictionary] = []
var _navigating := false

var current_route: String = ""
var current_payload: Dictionary = {}


func bind_host(host: Node) -> void:
	_host = host
	Log.info("Router", "host bound")


# ─────────────────────────────────────────────────────────────────────────
# Navigation
# ─────────────────────────────────────────────────────────────────────────
## Go to a route, pushing the current one onto the back stack.
func go(route: String, payload: Dictionary = {}) -> void:
	if not Log.must(ROUTES.has(route), "Router", "unknown route '%s'" % route):
		return
	if _navigating:
		Log.warn("Router", "ignored re-entrant go('%s')" % route)
		return

	if route in ROOT_ROUTES:
		_stack.clear()
	elif current_route != "":
		_stack.push_back({"route": current_route, "payload": current_payload})

	await _swap(route, payload)


## Replace the current screen without growing the stack (e.g. splash→hub).
func replace(route: String, payload: Dictionary = {}) -> void:
	if not Log.must(ROUTES.has(route), "Router", "unknown route '%s'" % route):
		return
	if _navigating:
		return
	await _swap(route, payload)


## Handle a back request. Returns true if consumed, false if the app should
## consider exiting. App owns the exit confirmation, not Router.
func back() -> bool:
	if _navigating:
		return true

	# The active screen gets first refusal — a trial can intercept to show
	# "forfeit this run?" instead of leaving.
	var screen := current_screen()
	if screen and screen.has_method("on_back_requested"):
		if bool(screen.on_back_requested()):
			return true  # screen consumed it

	if _stack.is_empty():
		return false  # at root: App decides (confirm + quit)

	var prev: Dictionary = _stack.pop_back()
	await _swap(str(prev.route), prev.payload)
	return true


func can_go_back() -> bool:
	return not _stack.is_empty()


func current_screen() -> Node:
	if _host == null or _host.get_child_count() == 0:
		return null
	return _host.get_child(_host.get_child_count() - 1)


# ─────────────────────────────────────────────────────────────────────────
# Internals
# ─────────────────────────────────────────────────────────────────────────
func _swap(route: String, payload: Dictionary) -> void:
	if not Log.must(_host != null, "Router", "no host bound"):
		return

	_navigating = true
	var path: String = ROUTES[route]

	# Fail loudly in debug if a route points at a missing scene. v1 silently
	# awarded a neutral trial result when a scene was missing, which hid typos.
	if not Log.must(ResourceLoader.exists(path), "Router", "missing scene %s" % path):
		_navigating = false
		return

	var packed: PackedScene = load(path)
	var next: Node = packed.instantiate()

	# Hand the screen its arguments BEFORE it enters the tree, so _ready() can
	# rely on them. v1 screens read globals in _ready() and raced.
	if next.has_method("configure"):
		next.configure(payload)

	var prev := current_screen()
	_host.add_child(next)

	if prev != null:
		await _crossfade(prev, next)
		prev.queue_free()

	current_route = route
	current_payload = payload
	_navigating = false

	Save.write_session(route, payload)
	navigated.emit(route, payload)
	Bus.route_changed.emit(route, payload)
	Log.d("Router", "-> %s (stack %d)" % [route, _stack.size()])


func _crossfade(prev: Node, next: Node) -> void:
	# Rule D: duration comes from Palette, which already collapses it under
	# the reduced-motion accessibility setting.
	var dur := Palette.duration(Palette.TRANSITION_SPEED)

	if next is CanvasItem:
		(next as CanvasItem).modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	if next is CanvasItem:
		tw.tween_property(next, "modulate:a", 1.0, dur)
	if prev is CanvasItem:
		tw.tween_property(prev, "modulate:a", 0.0, dur)
	await tw.finished
