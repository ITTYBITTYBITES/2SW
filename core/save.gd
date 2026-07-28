extends Node
## Save — atomic, debounced JSON state persistence. Autoload.
##
## Three v1 failures fixed structurally:
##
## 1. NO MIGRATIONS. v1 wrote `version = 1` and never read it. Any key-shape
##    change in v1.1 would reset or crash every existing player. The migration
##    RUNNER here exists before the first migration does.
##
## 2. NON-ATOMIC WRITES. v1 saved straight onto the live path. Android kills
##    apps mid-write; a truncated file loses everything. We write .tmp, rotate
##    the current file to .bak, then rename — rename is atomic, so a kill at
##    any instant leaves a complete old file or a complete new one.
##
## 3. NO RESUME STATE. All state lived in the scene tree, so Samsung OneUI
##    killing the backgrounded activity meant a cold restart at the ident.
##    A session snapshot is stamped on pause so App can restore the route.

signal loaded()
signal flushed()

const SAVE_PATH := "user://witness.save.json"
const TMP_PATH  := "user://witness.save.json.tmp"
const BAK_PATH  := "user://witness.save.json.bak"

## Bump when the on-disk shape changes; add a matching branch in _run_migrations.
const CURRENT_VERSION := 1

const SEC_META      := "meta"
const SEC_PROGRESS  := "progress"
const SEC_HISTORY   := "history"
const SEC_DAILY     := "daily"
const SEC_COSMETICS := "cosmetics"
const SEC_SETTINGS  := "settings"
const SEC_CONSENT   := "consent"
const SEC_SESSION   := "session"

var _data: Dictionary = {}
var _dirty := false
var _flush_queued := false


func _ready() -> void:
	_load()


# ═════════════════════════════════════════════════════════════════════════
# Load / migrate
# ═════════════════════════════════════════════════════════════════════════
func _load() -> void:
	var loaded_ok := _read_file(SAVE_PATH)

	if not loaded_ok and FileAccess.file_exists(BAK_PATH):
		Log.warn("Save", "primary unreadable; falling back to .bak")
		loaded_ok = _read_file(BAK_PATH)

	if not loaded_ok:
		Log.info("Save", "no save found; seeding defaults")
		_data = {}
		_seed_defaults()
		_write_now()
	else:
		_run_migrations()

	loaded.emit()


func _read_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		Log.error("Save", "open failed: %s (%d)" % [path, FileAccess.get_open_error()])
		return false
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		Log.error("Save", "corrupt JSON in %s" % path)
		return false

	_data = parsed
	return true


func _run_migrations() -> void:
	var v := int(get_v(SEC_META, "version", 0))

	if v > CURRENT_VERSION:
		# Player downgraded the app. Never destroy newer data.
		Log.warn("Save", "save v%d newer than app v%d; left untouched" % [v, CURRENT_VERSION])
		return

	while v < CURRENT_VERSION:
		var next := v + 1
		Log.info("Save", "migrating v%d -> v%d" % [v, next])
		match next:
			1: _migrate_to_1()
			_: Log.error("Save", "no migration path to v%d" % next)
		v = next
		set_v(SEC_META, "version", v)

	if _dirty:
		_write_now()


## v0 -> v1: baseline. Backfills keys a pre-versioned save could be missing
## without clobbering anything the player already has.
func _migrate_to_1() -> void:
	_seed_defaults(true)


func _seed_defaults(only_missing: bool = false) -> void:
	var put := func(sec: String, key: String, val: Variant) -> void:
		if only_missing and _data.has(sec) and (_data[sec] as Dictionary).has(key):
			return
		set_v(sec, key, val)

	put.call(SEC_META, "version", CURRENT_VERSION)
	put.call(SEC_META, "created_unix", int(Time.get_unix_time_from_system()))
	put.call(SEC_META, "tutorials_seen", [])
	# Nav gate. False until the player has RETURNED from a first trial, which
	# is what unlocks shard navigation on the hub. Seeing the hub is not the
	# same as having played, and only playing opens the compass.
	put.call(SEC_META, "returned_from_trial", false)

	put.call(SEC_PROGRESS, "lumina", 0)
	put.call(SEC_PROGRESS, "resonance", 0)
	put.call(SEC_PROGRESS, "level", 0)
	put.call(SEC_PROGRESS, "trials_done", 0)

	# Per-trial history is seeded from the trial registry via ensure_trial(),
	# never a hardcoded list. v1 hardcoded three ids and omitted facet_cascade,
	# silently pinning that trial to Easy forever.

	put.call(SEC_DAILY, "last_day_index", -1)
	put.call(SEC_DAILY, "streak", 0)
	put.call(SEC_DAILY, "best_streak", 0)

	put.call(SEC_COSMETICS, "equipped", "")
	put.call(SEC_COSMETICS, "owned", [])

	put.call(SEC_SETTINGS, "master_volume", 0.9)
	put.call(SEC_SETTINGS, "music_enabled", true)
	put.call(SEC_SETTINGS, "music_volume", 0.6)
	put.call(SEC_SETTINGS, "haptics", true)
	put.call(SEC_SETTINGS, "reduced_motion", false)
	put.call(SEC_SETTINGS, "high_contrast", false)
	put.call(SEC_SETTINGS, "colorblind", false)
	put.call(SEC_SETTINGS, "font_scale", 1.0)

	put.call(SEC_CONSENT, "accepted", false)
	put.call(SEC_CONSENT, "personalized_ads", false)
	put.call(SEC_CONSENT, "analytics", false)
	put.call(SEC_CONSENT, "policy_version", 0)


## Guarantee history keys exist for a trial id. The trial registry calls this
## for every registered trial on boot, so a trial can never be half-registered.
func ensure_trial(trial_id: String) -> void:
	var sec := _data.get(SEC_HISTORY, {}) as Dictionary
	if not sec.has(trial_id):
		set_v(SEC_HISTORY, trial_id, {
			"attempts": [],
			"bracket": 0,
			"best": 0.0,
		})
		Log.d("Save", "seeded history for '%s'" % trial_id)


# ═════════════════════════════════════════════════════════════════════════
# Access
# ═════════════════════════════════════════════════════════════════════════
func get_v(section_name: String, key: String, default: Variant) -> Variant:
	if not _data.has(section_name):
		return default
	var sec: Dictionary = _data[section_name]
	return sec.get(key, default)


func set_v(section_name: String, key: String, value: Variant) -> void:
	if not _data.has(section_name):
		_data[section_name] = {}
	var sec: Dictionary = _data[section_name]
	if sec.get(key, null) == value:
		return
	sec[key] = value
	_dirty = true


func section(section_name: String) -> Dictionary:
	return _data.get(section_name, {})


## ── NAV GATE ─────────────────────────────────────────────────────────────
## True once the player has completed and returned from at least one trial.
##
## Gates shard navigation on the hub: a brand-new player can only tap the eye
## to begin, and the full compass appears after they come back. The flag is
## permanent and one-way — there is no path that clears it short of a save
## wipe, because a player who has learned the hub must never be re-gated.
##
## Written only on a COMPLETED trial, never on a forfeit and never merely on
## reaching the hub. Someone who opens the app and quits has not earned the
## compass, and must still see "tap to begin".
func has_returned_from_trial() -> bool:
	return bool(get_v(SEC_META, "returned_from_trial", false))


## Record the first completed trial. Idempotent: writes and flushes only on
## the transition, so calling it after every trial for the rest of the
## player's life costs one dictionary read.
##
## Flushes immediately rather than via flush_soon(). The unlock is the reward
## for finishing a first trial; losing it to a crash in the seconds afterwards
## would re-gate a player who had earned the hub.
func mark_returned_from_trial() -> void:
	if has_returned_from_trial():
		return
	set_v(SEC_META, "returned_from_trial", true)
	Log.info("Save", "nav gate opened — first trial returned")
	flush()


func setting(key: String, default: Variant) -> Variant:
	return get_v(SEC_SETTINGS, key, default)


func set_setting(key: String, value: Variant) -> void:
	set_v(SEC_SETTINGS, key, value)
	flush_soon()


# ═════════════════════════════════════════════════════════════════════════
# Writing
# ═════════════════════════════════════════════════════════════════════════
## Coalesce a burst of writes into one disk hit at end of frame.
func flush_soon() -> void:
	if _flush_queued or not _dirty:
		return
	_flush_queued = true
	_deferred_flush.call_deferred()


func _deferred_flush() -> void:
	_flush_queued = false
	flush()


## Write immediately. Use on pause, quit, and milestone events.
func flush() -> bool:
	if not _dirty:
		return true
	return _write_now()


# ═════════════════════════════════════════════════════════════════════════
# EMERGENCY SAVE
# ═════════════════════════════════════════════════════════════════════════
## The OS is running low on memory and may evict us without further warning.
##
## This is the LAST hook Android reliably gives before a kill, so the write is
## immediate and synchronous — flush_soon() defers to a timer that may never
## get a frame to run on.
##
## Writes unconditionally, ignoring the `_dirty` flag. Dirty tracking is an
## optimisation for the common case; under an eviction warning the cost of one
## redundant write is nothing against the cost of being wrong about whether
## state had changed.
func _notification(what: int) -> void:
	if what != NOTIFICATION_OS_MEMORY_WARNING:
		return
	Log.warn("Save", "OS memory warning — emergency write")
	emergency_write()


## Force a synchronous write regardless of dirty state. Returns success.
##
## Public so App can call it on the same notification: App owns the session
## route, Save owns the file, and both must land before an eviction.
func emergency_write() -> bool:
	var written: bool = _write_now()
	if not Log.must(written, "Save", "emergency write FAILED"):
		return false
	_dirty = false
	Log.info("Save", "emergency write complete")
	return true


## Atomic write: temp -> rotate current to .bak -> rename temp into place.
func _write_now() -> bool:
	var text := JSON.stringify(_data, "\t")

	var f := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if f == null:
		Log.error("Save", "temp open failed (%d)" % FileAccess.get_open_error())
		return false
	f.store_string(text)
	f.close()

	var da := DirAccess.open("user://")
	if da == null:
		Log.error("Save", "cannot open user://")
		return false

	if da.file_exists(SAVE_PATH):
		if da.file_exists(BAK_PATH):
			da.remove(BAK_PATH)
		da.rename(SAVE_PATH, BAK_PATH)

	var err := da.rename(TMP_PATH, SAVE_PATH)
	if err != OK:
		Log.error("Save", "atomic rename failed (%d)" % err)
		return false

	_dirty = false
	flushed.emit()
	return true


# ═════════════════════════════════════════════════════════════════════════
# Session snapshot — the Android/Samsung resume fix
# ═════════════════════════════════════════════════════════════════════════
func write_session(route: String, payload: Dictionary) -> void:
	set_v(SEC_SESSION, "route", route)
	set_v(SEC_SESSION, "payload", payload)
	set_v(SEC_SESSION, "unix", int(Time.get_unix_time_from_system()))
	flush()


func read_session() -> Dictionary:
	var route := str(get_v(SEC_SESSION, "route", ""))
	if route == "":
		return {}
	return {
		"route": route,
		"payload": get_v(SEC_SESSION, "payload", {}),
		"unix": int(get_v(SEC_SESSION, "unix", 0)),
	}


func clear_session() -> void:
	set_v(SEC_SESSION, "route", "")
	set_v(SEC_SESSION, "payload", {})
	flush_soon()


# ═════════════════════════════════════════════════════════════════════════
# Debug
# ═════════════════════════════════════════════════════════════════════════
func wipe() -> void:
	Log.warn("Save", "WIPE requested")
	_data = {}
	_seed_defaults()
	_write_now()
	loaded.emit()
