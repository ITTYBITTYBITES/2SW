extends RefCounted
class_name ChronoPulseController
## ChronoPulseController — daily anomaly state, persistence and settlement.
##
## PHASE 2. Owns everything ChronoPulse writes to Save and every Bus event it
## emits. `core/chrono_pulse.gd` stays pure maths; this is the only place that
## touches stored state, so there is exactly one writer to audit.
##
## A RefCounted, not an autoload: nothing here needs to survive a screen
## change, and an autoload would be a tenth global for a feature that is read
## once when the Daily Hub opens. Every method is static and takes the state it
## operates on, which also means the whole controller is testable without a
## scene tree.
##
## ═══════════════════════════════════════════════════════════════════════════
## THE STREAK IS UNIFIED — THIS FILE DOES NOT OWN ONE
## ═══════════════════════════════════════════════════════════════════════════
## Completing the daily anomaly advances THE streak — the one IrisState holds,
## ProgressionEngine mutates, and the Daily Hub displays. There is no separate
## ChronoPulse streak counter, and adding one later would reintroduce the
## defect this design exists to avoid.
##
## record_completion() therefore calls ProgressionEngine.evaluate_daily_streak()
## rather than doing its own arithmetic. That function is idempotent against
## the stored local day index, which makes the two entry points safe in either
## order:
##
##   anomaly first  → streak advances, Lumina paid; Daily Hub then shows
##                    "Claimed today" and its button is disabled
##   Claim first    → streak advances, Lumina paid; the anomaly still records
##                    its result and share card, but does not pay twice
##
## The anomaly's OWN completion marker is separate from the streak claim, and
## keyed by UTC seed rather than local day. A player must not be able to replay
## today's global puzzle for a better time even after the streak is claimed.

# ═════════════════════════════════════════════════════════════════════════
# READ
# ═════════════════════════════════════════════════════════════════════════
## Has today's anomaly already been played?
##
## Keyed by UTC SEED, not local day: the puzzle is global, so "have you solved
## it" must be asked against the same calendar the puzzle was chosen from.
## Using the local day here would let a player near the date line replay the
## same anomaly twice.
static func is_solved(seed_id: String) -> bool:
	if not Log.must(seed_id != "", "ChronoPulse", "is_solved got empty seed"):
		return false
	return _history().has(seed_id)


static func is_solved_today() -> bool:
	return is_solved(ChronoPulse.current_seed())


## The stored record for a day, or {} if unplayed.
static func record_for(seed_id: String) -> Dictionary:
	var history: Dictionary = _history()
	var found: Variant = history.get(seed_id, {})
	if found is Dictionary:
		return found as Dictionary
	Log.warn("ChronoPulse", "history entry for '%s' is not a Dictionary" % seed_id)
	return {}


static func today_record() -> Dictionary:
	return record_for(ChronoPulse.current_seed())


## Today's puzzle parameters. Deterministic — every player gets this same set.
static func today_anomaly() -> Dictionary:
	return ChronoPulse.anomaly_for_seed(ChronoPulse.current_seed())


static func _history() -> Dictionary:
	var raw: Variant = Save.get_v(ChronoPulse.SECTION, ChronoPulse.KEY_HISTORY, {})
	if raw is Dictionary:
		return raw as Dictionary
	Log.warn("ChronoPulse", "history is not a Dictionary; treating as empty")
	return {}


## How many recoveries have been spent on the current local day. Stored as a
## date string rather than a counter so it self-resets at midnight without
## needing a scheduled wipe.
static func recoveries_used_today(now_unix: float = -1.0) -> int:
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var today: String = ChronoPulse.local_date_for_unix(now)
	var stored: String = str(Save.get_v(
		ChronoPulse.SECTION, ChronoPulse.KEY_RECOVERY_USED_DATE, ""))
	return 1 if stored == today else 0


# ═════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═════════════════════════════════════════════════════════════════════════
## Settle a finished run: persist the result, advance the unified streak, emit.
##
## `latency_ms` is the measured reaction time and `hit` whether the player
## reacted inside the window at all. Both come from the trial surface; this
## function does not measure anything, so it can be tested at any latency.
##
## Returns the full outcome:
##   { recorded, already_solved, record, streak, streak_advanced, lumina,
##     is_milestone, share_text }
##
## `recorded` is false when today was already played — replaying the global
## puzzle for a better time is not allowed, and the caller gets the ORIGINAL
## record back so the result card still renders.
static func record_completion(state: IrisState, latency_ms: int, hit: bool,
		accuracy: float, now_unix: float = -1.0) -> Dictionary:
	var outcome: Dictionary = {
		"recorded": false, "already_solved": false, "record": {},
		"streak": 0, "streak_advanced": false, "lumina": 0,
		"is_milestone": false, "share_text": "",
		"rejected": false, "faults": [],
	}

	if not Log.must(state != null, "ChronoPulse", "record_completion got null state"):
		return outcome

	# STRICT BOUNDS BEFORE ANY WRITE. A daily run cannot be repeated, so a bad
	# record is permanent — there is no second attempt to correct it. Rejecting
	# here means the player keeps an unplayed day they can still attempt,
	# which is strictly better than banking a nonsense result.
	var faults: Array[String] = ChronoPulse.validate_result(latency_ms, hit, accuracy)
	if not Log.must(faults.is_empty(), "ChronoPulse",
			"refusing to record an invalid result: %s" % str(faults)):
		outcome["rejected"] = true
		outcome["faults"] = faults
		return outcome

	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var seed_id: String = ChronoPulse.seed_for_unix(now)
	var local_date: String = ChronoPulse.local_date_for_unix(now)

	# Already played today. Return the stored result rather than overwriting
	# it — a second attempt must not be able to improve a shared time.
	if is_solved(seed_id):
		var existing: Dictionary = record_for(seed_id)
		outcome["already_solved"] = true
		outcome["record"] = existing
		outcome["streak"] = state.streak_days
		outcome["share_text"] = ChronoPulse.share_text(existing, state.streak_days)
		Log.info("ChronoPulse", "'%s' already solved; not re-recording" % seed_id)
		return outcome

	# ── Advance THE streak, through the one path that owns it ─────────────
	# Not a local copy of the rules. evaluate_daily_streak() is idempotent
	# against the stored day index, so if the Daily Hub's Claim button already
	# ran today this correctly reports claimed=false and pays nothing.
	var last_day_index: int = int(Save.get_v(Save.SEC_DAILY, "last_day_index", -1))
	var streak_result: Dictionary = ProgressionEngine.evaluate_daily_streak(
		state, last_day_index, now)

	var advanced: bool = bool(streak_result.get("claimed", false))
	if advanced:
		# Stamp the day index so the Daily Hub sees today as claimed.
		Save.set_v(Save.SEC_DAILY, "last_day_index",
			ProgressionEngine.local_day_index(now))
		Save.set_v(Save.SEC_DAILY, "streak", state.streak_days)
		Save.set_v(Save.SEC_DAILY, "best_streak", state.best_streak_days)

	# ── Persist the anomaly result ────────────────────────────────────────
	var record: Dictionary = ChronoPulse.build_record(
		seed_id, local_date, latency_ms, hit, accuracy, state.streak_days)

	var history: Dictionary = _history().duplicate(true)
	history[seed_id] = record
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_HISTORY,
		ChronoPulse.trim_history(history))
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_LAST_COMPLETED_DATE, local_date)
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_LAST_COMPLETED_DAY_INDEX,
		ProgressionEngine.local_day_index(now))
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_CURRENT_STREAK, state.streak_days)
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_BEST_STREAK, state.best_streak_days)
	Save.set_v("iris", "state", state.to_dict())

	# flush(), not flush_soon(): this is the one moment a day's result exists,
	# and a kill between here and the next autosave would erase a run the
	# player cannot repeat.
	Save.flush()

	outcome["recorded"] = true
	outcome["record"] = record
	outcome["streak"] = state.streak_days
	outcome["streak_advanced"] = advanced
	outcome["lumina"] = int(streak_result.get("lumina", 0))
	outcome["is_milestone"] = bool(streak_result.get("is_milestone", false))
	outcome["share_text"] = ChronoPulse.share_text(record, state.streak_days)

	Bus.chrono_pulse_completed.emit(record)
	Log.info("ChronoPulse", "recorded %s tier=%s streak=%d advanced=%s" % [
		seed_id, str(record.get("tier", "?")), state.streak_days, str(advanced)])
	return outcome


# ═════════════════════════════════════════════════════════════════════════
# RECOVERY
# ═════════════════════════════════════════════════════════════════════════
## The recovery offer for the current player, resolved against live state.
static func current_offer(state: IrisState, now_unix: float = -1.0) -> Dictionary:
	if not Log.must(state != null, "ChronoPulse", "current_offer got null state"):
		return ChronoPulse.recovery_offer(0, -1, 0, 0, 0)
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var last_day_index: int = int(Save.get_v(Save.SEC_DAILY, "last_day_index", -1))
	return ChronoPulse.recovery_offer(
		state.streak_days,
		last_day_index,
		ProgressionEngine.local_day_index(now),
		state.lumina,
		recoveries_used_today(now))


## Buy back a lapsed streak.
##
## `method` is "lumina" or "ad". The two differ ONLY in how they are paid for;
## everything downstream is identical, which is why they share one function
## rather than being two near-copies that could drift.
##
## Returns { recovered, streak, method, reason, lumina_spent }
static func recover_streak(state: IrisState, method: String,
		now_unix: float = -1.0) -> Dictionary:
	var result: Dictionary = {
		"recovered": false, "streak": 0, "method": method,
		"reason": "", "lumina_spent": 0,
	}

	if not Log.must(state != null, "ChronoPulse", "recover_streak got null state"):
		result["reason"] = "no state"
		return result

	if not Log.must(method == "lumina" or method == "ad", "ChronoPulse",
			"unknown recovery method '%s'" % method):
		result["reason"] = "unknown method"
		return result

	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var offer: Dictionary = current_offer(state, now)
	result["streak"] = state.streak_days

	if not bool(offer.get("eligible", false)):
		result["reason"] = str(offer.get("reason", "not eligible"))
		Log.info("ChronoPulse", "recovery refused: %s" % result["reason"])
		return result

	# Payment. spend_lumina() is atomic and refuses to overdraw, so a race or
	# a stale UI reading cannot drive the balance negative.
	if method == "lumina":
		if not state.spend_lumina(ChronoPulse.RECOVERY_LUMINA_COST):
			result["reason"] = "insufficient Lumina"
			Log.info("ChronoPulse", "recovery refused: insufficient Lumina")
			return result
		result["lumina_spent"] = ChronoPulse.RECOVERY_LUMINA_COST

	# ── Restore the streak ────────────────────────────────────────────────
	# Written straight to IrisState because this is a REPAIR, not a daily
	# claim: evaluate_daily_streak() would treat the lapse as real and reset
	# to 1, which is precisely what the player just paid to prevent.
	var restored: int = ChronoPulse.streak_after_recovery(
		int(offer.get("lost_streak", state.streak_days)))
	state.streak_days = restored
	state.best_streak_days = maxi(state.best_streak_days, restored)

	# Stamp today as claimed so the restored streak is not immediately
	# re-evaluated as lapsed by the next surface that reads it.
	var today_index: int = ProgressionEngine.local_day_index(now)
	Save.set_v(Save.SEC_DAILY, "last_day_index", today_index)
	Save.set_v(Save.SEC_DAILY, "streak", state.streak_days)
	Save.set_v(Save.SEC_DAILY, "best_streak", state.best_streak_days)

	# One recovery per local day, self-resetting at midnight.
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_RECOVERY_USED_DATE,
		ChronoPulse.local_date_for_unix(now))
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_CURRENT_STREAK, state.streak_days)
	Save.set_v(ChronoPulse.SECTION, ChronoPulse.KEY_BEST_STREAK, state.best_streak_days)
	Save.set_v("iris", "state", state.to_dict())
	Save.flush()

	result["recovered"] = true
	result["streak"] = restored
	result["reason"] = "recovered"

	Bus.chrono_streak_recovered.emit(restored, method)
	Log.info("ChronoPulse", "streak recovered to %d via %s" % [restored, method])
	return result


# ═════════════════════════════════════════════════════════════════════════
# SHARE
# ═════════════════════════════════════════════════════════════════════════
## Copy a result to the system clipboard.
##
## DisplayServer, not OS.set_clipboard: the latter is a no-op on some mobile
## builds and would fail silently, leaving the player tapping a button that
## appears to do nothing. Returns whether the copy was actually attempted so
## the UI can say "Copied" only when it is true.
static func copy_share_text(record: Dictionary, streak: int) -> bool:
	if not Log.must(not record.is_empty(), "ChronoPulse",
			"copy_share_text got an empty record"):
		return false

	var text: String = ChronoPulse.share_text(record, streak)

	# Verify before it leaves the device. A spoiler leak is unrecoverable —
	# once it is in someone's chat it cannot be taken back — so the check runs
	# on the real string at the moment of export, not only in tests.
	var anomaly: Dictionary = ChronoPulse.anomaly_for_seed(
		str(record.get("seed_id", "")))
	var leaks: Array[String] = ChronoPulse.verify_share_is_spoiler_free(
		text, anomaly, record)
	if not Log.must(leaks.is_empty(), "ChronoPulse",
			"share text leaked: %s" % str(leaks)):
		return false

	if not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		Log.warn("ChronoPulse", "clipboard unavailable on this platform")
		return false

	DisplayServer.clipboard_set(text)
	Log.info("ChronoPulse", "share text copied (%d chars)" % text.length())
	return true


## The share string without copying, for previewing on the card.
static func share_preview(record: Dictionary, streak: int) -> String:
	if record.is_empty():
		return ""
	return ChronoPulse.share_text(record, streak)
