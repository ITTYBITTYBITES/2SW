extends Node
## Bus — the one place every cross-system signal is declared.
##
## v1 hung gameplay signals off GameState, which also owned the state machine,
## which also half-owned navigation. Three jobs, one file, and systems reached
## into each other to connect. Here the signal hub is deliberately dumb: it has
## no state and no logic, so anything may depend on it without creating a cycle.
##
## Rule: emitters are named in the comment. If you want to emit something not
## listed as yours, you probably want a new signal instead.

# ── Progression (emitter: Progression) ───────────────────────────────────
@warning_ignore("unused_signal")
signal lumina_awarded(amount: int, new_total: int)
@warning_ignore("unused_signal")
signal resonance_awarded(amount: int, new_total: int)
@warning_ignore("unused_signal")
signal level_changed(old_level: int, new_level: int)
@warning_ignore("unused_signal")
signal stage_changed(old_stage: int, new_stage: int)

# ── Trial lifecycle (emitter: TrialHost) ─────────────────────────────────
@warning_ignore("unused_signal")
signal trial_started(trial_id: String, bracket: int)
@warning_ignore("unused_signal")
signal trial_finished(trial_id: String, result: Dictionary)
@warning_ignore("unused_signal")
signal trial_forfeited(trial_id: String)
## Full settlement summary: lumina, xp, resonance, rank change, metrics.
@warning_ignore("unused_signal")
signal trial_completed(summary: Dictionary)

## The answer window has dropped into its final quarter, or recovered out of
## it. Emitted on the EDGE, not per frame: a listener wants "urgency began",
## not sixty notifications a second.
##
## Exists because urgency was computed privately inside false_witness._draw()
## to tint the timer arc, and nothing outside could react to it. A pressure
## cue that only the renderer knows about cannot become a sound.
@warning_ignore("unused_signal")
signal trial_urgency_changed(urgent: bool)

# ── Iris expression (emitter: anyone; listener: IrisView) ────────────────
## Drives the eye's emotional response without coupling it to game logic.
## kind: "focus" | "reward" | "miss" | "evolve" | "greet" | "sleep"
@warning_ignore("unused_signal")
signal iris_express(kind: String, intensity: float)

# ── Iris interaction intent (emitter: IrisView) ──────────────────────────
## The eye reports WHAT happened; it never decides what it means. A listener
## (Home) maps a shard id to a route and calls Router. This is the boundary
## that v1 violated: its IrisCore held a NAV_SHARDS table containing route
## names AND asset paths, so adding a screen meant editing the eye.
##
## shard_id values are IrisState.CompassShard.
@warning_ignore("unused_signal")
signal iris_tapped(shard_id: int)
@warning_ignore("unused_signal")
signal iris_shard_hovered(shard_id: int)
@warning_ignore("unused_signal")
signal iris_shard_committed(shard_id: int)
## Fires when a one-shot expression completes, so callers can sequence
## animation without hardcoding durations. v1 never provided this and every
## caller guessed with its own tween.
@warning_ignore("unused_signal")
signal iris_expression_finished(kind: StringName)

# ── Navigation (emitter: Router) ─────────────────────────────────────────
@warning_ignore("unused_signal")
signal route_changed(route: String, payload: Dictionary)

# ── Monetization (emitter: ad system; listener: HubPortalController) ─────
## An ad-watch milestone landed and the player has earned a surprise drop.
## Payload: { seed: int, tier: String, label: String }
@warning_ignore("unused_signal")
signal surprise_drop_earned(drop: Dictionary)

# ── App lifecycle (emitter: App) ─────────────────────────────────────────
## Fires on genuine focus loss/return, debounced so a notification shade pull
## doesn't look like a session end.
@warning_ignore("unused_signal")
signal app_paused()
@warning_ignore("unused_signal")
signal app_resumed(away_seconds: int)

# ── Theme (emitter: Palette) ─────────────────────────────────────────────
@warning_ignore("unused_signal")
signal palette_changed(tier: int)

# ── Voice (emitter: AudioManager) ────────────────────────────────────────
## The Iris spoke. Payload carries the context and the chosen line so a caller
## can subtitle it — meaning lives on screen, the audio conveys only tone.
@warning_ignore("unused_signal")
signal iris_spoke(context: StringName, line: String)

# ── Consent (emitter: ConsentController) ─────────────────────────────────
## Privacy choices changed. Ad and analytics layers subscribe so a withdrawal
## takes effect immediately rather than at next launch.
@warning_ignore("unused_signal")
signal consent_changed(personalized_ads: bool, analytics: bool)

# ── ChronoPulse / daily anomaly (emitter: ChronoPulseController) ─────────
## Today's anomaly was completed. Carries the finished record — seed id, tier,
## latency, bars, streak — so a listener can react without re-reading Save.
@warning_ignore("unused_signal")
signal chrono_pulse_completed(record: Dictionary)

## A lapsed streak was bought back, by Lumina or by rewarded ad. `method` is
## "lumina" or "ad" so analytics and the UI can tell the two apart without
## inferring it from the balance delta.
@warning_ignore("unused_signal")
signal chrono_streak_recovered(streak: int, method: String)

# ── Toasts / feedback (emitter: anyone; listener: App overlay) ───────────
@warning_ignore("unused_signal")
signal toast(text: String, icon: String)
