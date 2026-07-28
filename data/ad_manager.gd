extends Node
## AdManager — rewarded ad lifecycle. Autoload.
##
## PHASE 11. Wraps the AdMob plugin behind a clean interface so no gameplay
## code touches plugin internals, and so the whole reward flow is testable
## without an ad network.
##
## AD UNIT IDs LIVE IN Cfg, NOT HERE. They are read from gitignored
## build_config.cfg. v1 hardcoded live publisher ids into a public repo —
## public ad units invite invalid-traffic attacks that get AdMob accounts
## suspended, which is a bigger practical risk than a leaked API key. CI fails
## the build if a live `ca-app-pub-` string appears in source.
##
## DEV MODE is derived, never assigned: a debug build cannot serve live ads.
## v1 gated this on a `const USE_TEST_ADS` that a human had to remember to flip
## before release — item #8 on a checklist, with revenue riding on memory.
##
## THE FALLBACK RULE:
## If the plugin is absent, offline, or the ad fails to load, the reward is
## granted anyway. Cosmetics are the only thing ads gate, and blocking a
## cosmetic because a network call failed punishes the player for our
## infrastructure. The ad is an opportunity to give, not a toll gate.

# ── Lifecycle signals ────────────────────────────────────────────────────
## A rewarded ad finished loading and can be shown.
signal ad_loaded()
## Load failed. `reason` is human-readable, for logs and QA.
signal ad_failed_to_load(reason: String)
## The user watched to completion and earned the reward. `placement` is the
## caller's tag (e.g. a cosmetic id) so listeners know what to credit.
signal ad_watched_successfully(placement: String)
## The user closed the ad early; no reward is owed by the network.
signal ad_dismissed_early(placement: String)
## Availability changed (loaded / consumed / offline / cap reached).
signal availability_changed(available: bool)

## Plugin singleton names, in priority order. Different Godot AdMob plugins
## expose different names; accept any of them rather than pinning to one.
const PLUGIN_NAMES: Array[String] = ["AdMob", "PoingGodotAdMob", "GodotAdMob"]

## Rewarded ads per UTC day. Generous, but bounded: an unbounded loop would
## let a player grind the entire catalogue in one sitting.
const MAX_REWARDED_PER_DAY: int = 12

## Simulated load time in fallback mode, so the UI exercises its real
## "loading…" path rather than resolving instantly and hiding jank.
const FALLBACK_LOAD_DELAY: float = 0.4

# ═════════════════════════════════════════════════════════════════════════
# COOLDOWNS
# ═════════════════════════════════════════════════════════════════════════
## Default gap between two CATEGORY UNLOCK ads, in seconds.
const CATEGORY_COOLDOWN_SEC: float = 300.0
## Default gap between two STREAK RESCUE ads, in seconds.
const RETRY_COOLDOWN_SEC: float = 60.0

## Sentinel for "no ad of this kind has been watched yet".
##
## NOT zero. Time.get_ticks_msec() is ~120 at boot, so an initial value of 0
## would make the very first unlock report 120ms elapsed against a 300000ms
## cooldown and lock a brand-new player out of a feature they have never used.
const NEVER: int = -1

# ═════════════════════════════════════════════════════════════════════════
# PRELOAD / BACKOFF
# ═════════════════════════════════════════════════════════════════════════
## Exponential backoff between failed load attempts, in seconds.
##
## Starts at 2s and doubles to a 5-minute ceiling. A fixed short retry hammers
## a network that is already failing and drains the battery of a player who is
## simply offline; no retry at all means a transient failure disables rewarded
## ads for the whole session.
const RETRY_BASE_SEC: float = 2.0
const RETRY_MAX_SEC: float = 300.0
## Give up after this many consecutive failures. At that point the network is
## not coming back on its own, and the next explicit load_rewarded() — a screen
## opening, an ad finishing — restarts the sequence.
const RETRY_MAX_ATTEMPTS: int = 6

var _plugin: Object = null
var _loaded: bool = false
var _showing: bool = false
var _pending_placement: String = ""
var _watches_today: int = 0
var _day_index: int = -1

## Monotonic timestamps of the last successful ad of each kind.
##
## WHY THESE ARE SESSION-SCOPED, AND DELIBERATELY NOT PERSISTED:
## Time.get_ticks_msec() counts from engine start, so it resets to ~0 on every
## launch. Writing it to Save and comparing it against a fresh boot's clock
## computes a garbage interval — the stored value would be larger than "now",
## the subtraction goes negative, and the cooldown either vanishes or locks
## forever depending on the sign convention. Persisting a monotonic clock is
## simply incorrect.
##
## The alternative — persisting unix time — survives a relaunch but is set by
## the player's own device clock, so it is bypassed by changing the date and
## it can strand a player whose clock jumps backwards.
##
## So these are a COURTESY THROTTLE, not an enforcement boundary: they stop
## accidental double-taps and rapid-fire watching inside one session. The hard
## limit is MAX_REWARDED_PER_DAY, which IS persisted, uses the local day index,
## and cannot be reset by relaunching.
var _last_category_unlock_msec: int = NEVER
var _last_retry_msec: int = NEVER

## True when no real plugin is present. Rewards resolve locally so headless
## builds, the editor, and offline devices never block progression.
var _fallback_mode: bool = true

## Consecutive failed load attempts. Reset on any success, and on an explicit
## load request, so a fresh screen never inherits a spent backoff.
var _retry_attempts: int = 0
## True while a retry is already scheduled, so overlapping failures cannot
## stack timers and produce a burst of simultaneous load calls.
var _retry_pending: bool = false
## True while a load is in flight. Without it, every card on a 20-item hub
## asking "are you ready?" could each kick off their own load.
var _loading: bool = false
## Test-only: suppresses the fallback mode instant-grant. See debug_block_loads().
var _loads_blocked: bool = false


func _ready() -> void:
	_restore_daily_counter()
	_try_bind_plugin()
	Log.info("Ad", "ready — dev=%s fallback=%s unit=%s" % [
		str(is_dev_mode()), str(_fallback_mode), _masked_unit()])
	# Preload at launch so the first unlock a player taps is instant.
	preload_rewarded_ad()


# ═════════════════════════════════════════════════════════════════════════
# MODE
# ═════════════════════════════════════════════════════════════════════════
## Derived from the build, never assigned. A debug build cannot serve live ads.
func is_dev_mode() -> bool:
	return Cfg.use_test_ads


func is_fallback_mode() -> bool:
	return _fallback_mode


## The unit currently in use. Cfg falls back to Google's test unit when the
## production id is missing, so this is never empty.
func rewarded_unit_id() -> String:
	return Cfg.rewarded_id()


## Log-safe: never print a full production unit id.
func _masked_unit() -> String:
	var unit: String = rewarded_unit_id()
	if unit.length() < 12:
		return unit
	return unit.substr(0, 12) + "…" + unit.right(4)


func _try_bind_plugin() -> void:
	for plugin_name: String in PLUGIN_NAMES:
		if Engine.has_singleton(plugin_name):
			_plugin = Engine.get_singleton(plugin_name)
			_fallback_mode = false
			Log.info("Ad", "bound plugin '%s'" % plugin_name)
			return
	_plugin = null
	_fallback_mode = true
	Log.info("Ad", "no AdMob plugin; running in fallback mode")


# ═════════════════════════════════════════════════════════════════════════
# DAILY CAP
# ═════════════════════════════════════════════════════════════════════════
## Uses the same LOCAL day index as the streak system, so "today" means the
## same thing everywhere in the game.
func _restore_daily_counter() -> void:
	_day_index = ProgressionEngine.local_day_index(Time.get_unix_time_from_system())
	var stored_day: int = int(Save.get_v("ads", "day_index", -1))
	if stored_day == _day_index:
		_watches_today = int(Save.get_v("ads", "watches", 0))
	else:
		_watches_today = 0
		_persist_counter()


func _persist_counter() -> void:
	Save.set_v("ads", "day_index", _day_index)
	Save.set_v("ads", "watches", _watches_today)
	Save.flush_soon()


## Roll the counter if the day changed while the app was open.
func _refresh_day() -> void:
	var today: int = ProgressionEngine.local_day_index(Time.get_unix_time_from_system())
	if today != _day_index:
		_day_index = today
		_watches_today = 0
		_persist_counter()
		_emit_availability()


func watches_remaining() -> int:
	_refresh_day()
	return maxi(MAX_REWARDED_PER_DAY - _watches_today, 0)


# ═════════════════════════════════════════════════════════════════════════
# COOLDOWN QUERIES
# ═════════════════════════════════════════════════════════════════════════
## Milliseconds elapsed since a monotonic mark, or -1 when never marked.
##
## clamped at zero because ticks_msec is monotonic within a session, so a
## negative interval would mean the clock ran backwards — impossible here, but
## returning a negative would silently invert every comparison below.
func _elapsed_since(mark_msec: int) -> int:
	if mark_msec == NEVER:
		return NEVER
	return maxi(Time.get_ticks_msec() - mark_msec, 0)


## May the player watch an ad to unlock a category right now?
func can_unlock_category(cooldown_sec: float = CATEGORY_COOLDOWN_SEC) -> bool:
	return get_category_cooldown_remaining_sec(cooldown_sec) <= 0


## Whole seconds left on the category cooldown, 0 when clear.
##
## Rounded UP, so a button never reads "0" while still refusing the tap — a
## countdown that hits zero and does nothing looks broken.
func get_category_cooldown_remaining_sec(
		cooldown_sec: float = CATEGORY_COOLDOWN_SEC) -> int:
	return _remaining_sec(_last_category_unlock_msec, cooldown_sec)


## May the player watch a rescue ad right now?
func can_show_retry_ad(cooldown_sec: float = RETRY_COOLDOWN_SEC) -> bool:
	return get_retry_cooldown_remaining_sec(cooldown_sec) <= 0


## Whole seconds left on the rescue cooldown, 0 when clear.
func get_retry_cooldown_remaining_sec(
		cooldown_sec: float = RETRY_COOLDOWN_SEC) -> int:
	return _remaining_sec(_last_retry_msec, cooldown_sec)


func _remaining_sec(mark_msec: int, cooldown_sec: float) -> int:
	# A non-positive cooldown disables the throttle entirely, which is what a
	# caller passing 0.0 means. Guarded so it cannot become a divide or a
	# permanent block.
	if cooldown_sec <= 0.0:
		return 0
	var elapsed: int = _elapsed_since(mark_msec)
	if elapsed == NEVER:
		return 0
	var remaining_ms: int = int(cooldown_sec * 1000.0) - elapsed
	if remaining_ms <= 0:
		return 0
	return int(ceil(float(remaining_ms) / 1000.0))


## MM:SS for a countdown label. Minutes are not capped at 59 — a 90-minute
## cooldown must read "90:00", not "30:00", because a wrapped clock understates
## the wait and reads as a bug.
func format_cooldown(total_seconds: int) -> String:
	var safe: int = maxi(total_seconds, 0)
	@warning_ignore("integer_division")
	var minutes: int = safe / 60
	var seconds: int = safe % 60
	return "%02d:%02d" % [minutes, seconds]


## Which cooldown a placement belongs to. Derived from the placement string so
## the two call sites cannot disagree with the manager about which throttle
## applies to them.
func is_retry_placement(placement: String) -> bool:
	return placement == "trend_continue"


func is_category_placement(placement: String) -> bool:
	return placement.begins_with("trend_") and not is_retry_placement(placement)


## Clear both cooldowns. Test-only affordance, and used by a full progress
## reset so a wiped save does not leave a stale throttle behind.
## Test affordance: force the ready state, so UI fallbacks can be exercised
## without a network. Never called by game code.
func debug_set_ready(is_ready: bool) -> void:
	_loaded = is_ready
	_loading = false
	_emit_availability()


## Test affordance: stop fallback mode from instantly satisfying a load.
##
## In fallback mode load_rewarded() grants immediately, so a screen that
## preloads on entry is ready again before its cards build — which made the
## "AD NOT READY" UI unreachable in tests even though it renders correctly on
## a real device with a slow network. Never called by game code.
func debug_block_loads(blocked: bool) -> void:
	_loads_blocked = blocked


func reset_cooldowns() -> void:
	_last_category_unlock_msec = NEVER
	_last_retry_msec = NEVER


# ═════════════════════════════════════════════════════════════════════════
# LOAD
# ═════════════════════════════════════════════════════════════════════════
## Request a rewarded ad. Safe to call repeatedly — already-loaded, in-flight
## and mid-show states all short-circuit.
##
## `manual` marks an explicit request (app launch, a screen opening, an ad
## finishing) as opposed to an automatic backoff retry. An explicit request
## resets the backoff, because the context has changed: the player has done
## something new and deserves a fresh attempt rather than inheriting a long
## wait from failures that happened minutes ago.
func load_rewarded(manual: bool = true) -> void:
	if _loaded or _showing:
		return
	if _loading:
		return

	if manual:
		_retry_attempts = 0

	if _loads_blocked:
		_loading = false
		return

	if _fallback_mode:
		_loaded = true
		_loading = false
		ad_loaded.emit()
		_emit_availability()
		return

	_loading = true
	if _plugin.has_method("load_rewarded"):
		_plugin.call("load_rewarded", rewarded_unit_id())
	elif _plugin.has_method("loadRewarded"):
		_plugin.call("loadRewarded", rewarded_unit_id())
	else:
		_fail("plugin exposes no rewarded load method")


## Explicit alias for the preload intent. Same operation as load_rewarded();
## named separately because "preload" is what the call sites mean, and a
## reader should not have to know they are identical.
func preload_rewarded_ad() -> void:
	load_rewarded(true)


## Is an ad loaded and actually showable right now?
##
## This is the UI's question, and it is deliberately STRICTER than "did the
## network return an ad": it also refuses when one is mid-show or the daily cap
## is spent. A button enabled on inventory alone would still fail on tap.
func is_rewarded_ad_ready() -> bool:
	return is_available()


## True while a load is in flight, so a spinner can be honest about waiting
## rather than showing "not ready" for something that is seconds away.
func is_loading() -> bool:
	return _loading


func retry_attempts() -> int:
	return _retry_attempts


## Seconds the NEXT backoff would wait. Exposed for tests and diagnostics.
func next_retry_delay_sec() -> float:
	return backoff_delay_sec(_retry_attempts)


## Exponential backoff: 2, 4, 8, 16 ... capped at RETRY_MAX_SEC.
##
## Pure and static so the curve is testable without a network, a timer, or a
## failure. attempt 0 is the first retry.
static func backoff_delay_sec(attempt: int) -> float:
	var safe: int = maxi(attempt, 0)
	# The exponent cap is defensive, not load-bearing: I assumed pow() would
	# overflow into something minf() could not clamp, and measured instead —
	# pow(2.0, 4000.0) returns +inf and minf(inf, 300.0) correctly returns
	# 300.0. The cap stays because computing 2^4000 to immediately discard it
	# is wasteful, but the clamp alone is already correct.
	var capped: int = mini(safe, 16)
	return minf(RETRY_BASE_SEC * pow(2.0, float(capped)), RETRY_MAX_SEC)


func is_available() -> bool:
	return _loaded and not _showing and watches_remaining() > 0


func _emit_availability() -> void:
	availability_changed.emit(is_available())


## The network reported a loaded ad. Public so a plugin callback can reach it.
func on_ad_loaded() -> void:
	_loaded = true
	_loading = false
	_retry_attempts = 0
	_retry_pending = false
	Log.d("Ad", "rewarded ad loaded")
	ad_loaded.emit()
	_emit_availability()


## The network reported a failure. Public so a plugin callback can reach it.
func on_ad_failed_to_load(reason: String) -> void:
	_fail(reason)


func _fail(reason: String) -> void:
	_loaded = false
	_loading = false
	Log.warn("Ad", "load failed: %s" % reason)
	ad_failed_to_load.emit(reason)
	_emit_availability()
	_schedule_retry()


## Queue the next attempt with exponential backoff.
##
## Never retries in fallback mode: there is no network to wait for, loads
## always succeed, and a timer there would be a permanent no-op wakeup.
func _schedule_retry() -> void:
	if _fallback_mode:
		return
	if _retry_pending:
		return
	if _retry_attempts >= RETRY_MAX_ATTEMPTS:
		Log.info("Ad", "giving up after %d attempts; will retry on next request"
			% _retry_attempts)
		return

	var delay: float = backoff_delay_sec(_retry_attempts)
	_retry_attempts += 1
	_retry_pending = true
	Log.d("Ad", "retry %d in %.0fs" % [_retry_attempts, delay])
	_run_retry(delay)


func _run_retry(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	_retry_pending = false
	# Conditions can change during the wait — an ad may have loaded from
	# another path, or one may now be showing. Re-check rather than assuming
	# the world is as it was when the timer started.
	if _loaded or _showing:
		return
	load_rewarded(false)


# ═════════════════════════════════════════════════════════════════════════
# SHOW
# ═════════════════════════════════════════════════════════════════════════
## Show a rewarded ad for `placement`. Returns false only when the daily cap
## is reached — every other failure path still grants the reward.
##
## `placement` is echoed back on the result signal so a listener can credit
## the right thing without tracking its own pending state.
func show_rewarded(placement: String) -> bool:
	_refresh_day()

	if watches_remaining() <= 0:
		Log.info("Ad", "daily cap reached (%d)" % MAX_REWARDED_PER_DAY)
		ad_failed_to_load.emit("daily cap reached")
		return false

	if _showing:
		Log.warn("Ad", "show called while an ad is already showing")
		return false

	_pending_placement = placement
	_showing = true

	if _fallback_mode or not _loaded:
		# No plugin, or nothing loaded. Grant anyway after a short beat so the
		# caller's loading state is exercised rather than skipped.
		_grant_after_delay()
		return true

	if _plugin.has_method("show_rewarded"):
		_plugin.call("show_rewarded")
	elif _plugin.has_method("showRewarded"):
		_plugin.call("showRewarded")
	else:
		_grant_after_delay()
	return true


func _grant_after_delay() -> void:
	await get_tree().create_timer(FALLBACK_LOAD_DELAY).timeout
	_on_reward_earned()


# ═════════════════════════════════════════════════════════════════════════
# PLUGIN CALLBACKS
# ═════════════════════════════════════════════════════════════════════════
## Called by the plugin (or the fallback) when the user earns the reward.
func _on_reward_earned() -> void:
	if not _showing:
		return
	var placement: String = _pending_placement
	_finish_show()

	_watches_today += 1
	_persist_counter()

	# Stamp the cooldown on a SUCCESSFUL reward, never on the request. An ad
	# the player dismissed gave them nothing, and charging a 5-minute lockout
	# for it would punish a mis-tap harder than a completed watch.
	_mark_cooldown(placement)

	Log.info("Ad", "reward earned for '%s' (%d/%d today)" % [
		placement, _watches_today, MAX_REWARDED_PER_DAY])
	ad_watched_successfully.emit(placement)

	# Immediately begin preloading the next one. A player who just watched an
	# ad is the likeliest person to want another, and a cold load at that
	# moment reads as the button being broken.
	preload_rewarded_ad()


## Record which throttle this placement just consumed.
func _mark_cooldown(placement: String) -> void:
	var now: int = Time.get_ticks_msec()
	if is_retry_placement(placement):
		_last_retry_msec = now
		Log.d("Ad", "retry cooldown started (%.0fs)" % RETRY_COOLDOWN_SEC)
	elif is_category_placement(placement):
		_last_category_unlock_msec = now
		Log.d("Ad", "category cooldown started (%.0fs)" % CATEGORY_COOLDOWN_SEC)


## Called when the user closes the ad before earning.
func _on_dismissed_early() -> void:
	if not _showing:
		return
	var placement: String = _pending_placement
	_finish_show()
	Log.info("Ad", "dismissed early for '%s'" % placement)
	ad_dismissed_early.emit(placement)
	# Preload after a dismissal too. The inventory was consumed either way.
	preload_rewarded_ad()


func _finish_show() -> void:
	_showing = false
	_loaded = false
	_pending_placement = ""
	_emit_availability()


# ═════════════════════════════════════════════════════════════════════════
# TEST HOOKS
# ═════════════════════════════════════════════════════════════════════════
## Force fallback mode. Lets a test drive the full flow deterministically
## without an ad network or a plugin.
func set_fallback_mode(enabled: bool) -> void:
	_fallback_mode = enabled
	if enabled:
		_plugin = null


## Simulate the plugin reporting a completed watch. Test-only.
func simulate_reward(placement: String) -> void:
	_pending_placement = placement
	_showing = true
	_on_reward_earned()


## Simulate the user closing the ad early. Test-only.
func simulate_dismiss(placement: String) -> void:
	_pending_placement = placement
	_showing = true
	_on_dismissed_early()


## Reset the daily counter. Test/QA only.
func reset_daily_counter() -> void:
	_watches_today = 0
	_persist_counter()
	_emit_availability()
