# Iris — System Connection Map & Interface Contract

Derived strictly from the v1 source, now archived on the `legacy-v1` branch:
`scripts/IrisCore.gd` (801 lines), `autoloads/IrisAmbient.gd`, `IrisTraits.gd`
and `docs/IA_MAP.md` under `legacy_reference/`. Retrieve with
`git show legacy-v1-archive:legacy_reference/scripts/IrisCore.gd`.

**Purpose:** define what drives the Iris and what it emits, so the v2 eye can be
a pure shader-driven view with no knowledge of the app around it.

**Status:** analysis only. No code, no scenes.

---

## 1. INPUT DATA & EVENTS — what drives the Iris

### 1a. Progression metrics (persistent, earned)

| Input | v1 source | Effect on visual state | v1 delivery |
|---|---|---|---|
| **Evolution stage** (0–7) | `IrisProgression.evolution_stage_for_level()` | Selects base texture + `u_evolve_tint`; drives `u_tint_amount` (0.10 + stage×0.04, cap 0.55), `u_glow` (1.0 + stage×0.12), `u_highlight` | `GameState.iris_evolved` → `_apply_stage()` |
| **Stage cycle** (stage ÷ 8) | derived, for Lv 80+ | Infinite escalation past stage 7: `cycle_glow` +0.35/cycle, `cycle_shimmer` +0.06/cycle, `u_time_scale` +0.1/cycle (cap 2.0) | same |
| **Level up** | `GameState.level_up` | One-shot `widen()` — dilation → 0.22 over 0.25s (TRANS_BACK), release over 0.5s | signal |
| **Lumina awarded** | `IrisProgression.lumina_awarded` | One-shot `pupil_pulse(0.16)` | signal |
| **Traits unlocked** | `IrisTraits.unlocked_traits()` | Compositing layer — see 1b below | `IrisTraits.trait_unlocked` |
| **Rank tier** | `ThemeSystem.accent()` | Tints the nav shard markers only (not the eye body) | polled at draw |
| **Equipped cosmetic** | `Cosmetics.equipped_art()` / `hat_position()` / `fit_for()` | Positions a hat sprite on the mount arc | `Cosmetics.equipped` |

**Resonance:** does **not** reach the Iris in v1. It is a Visage shop currency
only. Worth deciding deliberately in v2 rather than inheriting by accident.

### 1b. Trait compositing (the "collectible eye" layer)

Seven trait kinds map to distinct shader inputs, with hard caps:

| Kind | Cap | Shader payload | Visual |
|---|---|---|---|
| `FLECK` | 8 | `u_flecks[8]` (vec4 x,y,size,1) + `u_fleck_colors[8]` | Coloured specks at random angle/radius (0.05–0.16) |
| `FIBER` | 6 | `u_fibers[6]` (vec3 angle,len,width) + `u_fiber_colors[6]` | Bright radial strands |
| `RING` | 4 | `u_rings[4]` (vec3 radius,strength,0) + `u_ring_colors[4]` | Concentric arcs, radius 0.5 + i×0.18 |
| `VEIN` | — | `u_vein_amount` (+0.4 each, cap 1.0), `u_vein_color` | Sclera veining |
| `WISP` | — | `_wisp_count` → particle amount | Orbiting GPU particles |
| `GLOW` | — | `u_glow` += 0.25 each | Overall luminance |
| `BLINK` | — | *declared but unused* | — |

⚠ **Bug to not carry forward:** fleck/fiber positions are generated with
`_rng.randf_range()` on every `_apply_traits()` call, so the eye's freckles
**move every time a trait unlocks or the app relaunches**. They should be
deterministic per trait id — a fleck is a permanent feature of *your* eye.

### 1c. Environmental & time metrics (atmosphere, not progression)

All from `IrisAmbient`, computed once on boot:

| Input | Derivation | Effect |
|---|---|---|
| **Per-day mood tint** | RNG seeded on `day_index × 2654435761` — deterministic within a day, shifts daily | Blends 20% into stage tint; hue drift ±0.05, sat 0.92–1.05 |
| **Per-day shimmer** | same seed | `u_shimmer` 0.28–0.42 |
| **Time of day (local)** | hour ≥21 or <6 → 1.0; ≥18 → 0.6; else 0.0 | Lerps tint 15% toward amber at night |
| **Days absent** | `(now − last_open) / 86400` | ≥2 days sets `missed_you` |
| **"Missed you" greeting** | `missed_you` | `u_glow` bonus 0.15 + days×0.03, cap 0.5 |
| **Reduced motion** | `SaveSystem.get_setting()` | `u_reduced_motion`; suppresses breathing, idle gaze, micro-saccades; blink interval 2.5–5.5s → 8–14s; particles 40 → 24 |

**Streak days:** despite the IA map listing streaks prominently, the Iris
**never reads them**. Only `days_absent` matters. A deliberate v2 decision point.

### 1d. Real-time interaction

| Input | Mechanism | Effect |
|---|---|---|
| **Pointer position** (drag) | `_on_eye_input` → `look_toward(pos)` | `u_look_offset` = normalised direction, clamped to `LOOK_MAX` 0.10, eased at `delta × 8.0` |
| **Directional intent** | dot product vs 4 compass dirs, threshold **0.55** | Once committed, gaze snaps to the *shard direction*, not the raw finger — makes the preview feel intentional |
| **Centre dead-zone** | `dist < _side × 0.14` | Unambiguous "no selection"; a tap here starts a trial |
| **Press / release** | touch or mouse | Press begins tracking; release commits or cancels |
| **Tap (no nav)** | `nav_enabled == false` | `react_tap()` → `pupil_pulse(0.12)` + voice, then emit |
| **Focus dilate** | `focus_dilate(bool)` | Dilation → 0.14 over 0.18s |

**Autonomous life (no input):** idle gaze retarget every 1.2–3.2s (35% chance of
recentre), micro-saccade jitter at `LOOK_MAX × 0.05` per frame, breathing
`sin(phase × 1.1) × 0.16`, blink every 2.5–5.5s with an 18% chance of a
double-blink 0.28s later.

That micro-saccade + breathing combination is the single most important thing to
preserve — it's what reads as "alive."

---

## 2. OUTPUT EVENTS — what the Iris triggers

v1 emitted exactly three signals:

| Signal | Fired when | Payload | Consumer |
|---|---|---|---|
| `eye_tapped()` | Tap in dead-zone, or any tap when `nav_enabled == false`, or release with no shard hovered | — | `Console._on_eye_tapped()` → starts a trial |
| `previewing(id: String)` | Hover enters/leaves a shard. `""` = cleared | destination id | `Console._on_nav_previewing()` → updates hint text |
| `navigate(id: String)` | Release while a vision is visible | destination id | `Console._on_nav_commit()` → zoom transition + scene change |

### Public methods callers used as commands

| Method | Purpose |
|---|---|
| `blink()` · `pupil_pulse(s)` · `widen()` · `flare()` · `celebrate_burst()` | One-shot expressions |
| `look_toward(pt)` · `look_reset()` · `focus_dilate(on)` | Gaze control |
| `show_vision(path)` · `hide_vision()` · `vision_visible()` | Nav preview |
| `refresh_from_save()` · `set_boot_seed_state()` | State sync |
| `set_nav_enabled(on)` · `is_previewing()` | Mode gating |
| `arc_point(t)` · `arc_tilt(t)` · `refresh_adornment_position()` | Hat mounting |

**Never emitted but should be:** evolution-complete, blink-occurred, and
expression-finished. Callers currently guess at timing with their own tweens.

---

## 3. DECOUPLING ANALYSIS

### What IrisCore is actually doing

Nine distinct responsibilities in one 801-line file:

| # | Responsibility | Lines | Verdict |
|---|---|---|---|
| 1 | Shader eye rendering | ~120 | ✅ **Keep** — this is the eye |
| 2 | Autonomous life (breathe/blink/saccade) | ~80 | ✅ **Keep** — the soul of it |
| 3 | Gaze tracking | ~40 | ✅ **Keep** |
| 4 | Trait compositing | ~90 | ⚠️ **Split** — view renders, data comes in |
| 5 | Lid geometry | ~30 | ✅ **Keep** (rebuild — v1 used flat rects) |
| 6 | Particle wisps | ~35 | ✅ **Keep** |
| 7 | **Navigation routing** | ~150 | ❌ **STRIP** |
| 8 | **Hat mounting + arc math** | ~70 | ❌ **EXTRACT** |
| 9 | **Toast notifications** | ~30 | ❌ **STRIP** |

### ❌ BLOAT 1 — Navigation (the big one, ~150 lines)

The eye currently owns the entire nav interaction: a hardcoded `NAV_SHARDS`
table with **hardcoded scene-asset paths**, hit-testing, hover state, shard
diamond drawing, vision preview loading with its own texture cache and inline
circle-mask shader, and `AudioSystem.play("menu_open")` on hover.

**Why it's wrong:** the eye knows destination *names* (`"trials"`, `"profile"`)
and their *artwork paths*. Add a screen and you edit the eye. This is precisely
the coupling `Router` exists to remove.

**v2:** the eye exposes gaze and a hit-test surface. A separate `IrisNavigator`
(or Home itself) owns the compass mapping, and commit goes
`Bus.iris_navigate_requested(id)` → `Router.go(id)`. The eye never learns a
route name.

### ❌ BLOAT 2 — Hat mounting (~70 lines)

`arc_point()`, `arc_tilt()`, `_position_adornment()`, and direct calls to
`Cosmetics.equipped_art()` / `hat_position()` / `fit_for()`.

**Why it's wrong:** the eye reaches into the cosmetics system and does sprite
layout. It's a mount *point* provider, not a mount *manager*.

**v2:** the eye exposes `arc_point(t) -> Vector2` as pure geometry. An
`AdornmentMount` sibling node subscribes to `Bus.cosmetic_equipped` and does the
positioning.

### ❌ BLOAT 3 — Toasts (~30 lines)

The eye builds a `Label`, listens for `IrisTraits.trait_unlocked`, and animates
notification text.

**Why it's wrong:** v2's `App` already has a global toast overlay
(`Bus.toast`). An eye should not be a notification system.

**v2:** `IrisTraits` emits `Bus.toast(...)` directly. The eye only reacts
visually — pulse, burst.

### ⚠️ COUPLING — direct autoload reads

v1 IrisCore touches **nine** globals: `GameState`, `IrisProgression`,
`IrisTraits`, `Cosmetics`, `IrisAmbient`, `SaveSystem`, `ThemeSystem`,
`AudioSystem`, `IrisVoice`.

`react_tap()` calling `IrisVoice.utter("acknowledge")` and `_set_hover()` calling
`AudioSystem.play("menu_open")` mean **the eye triggers audio**. A view should
not.

**v2:** the eye reads **zero** autoloads except `Palette` (Rule D). Everything
else arrives as a typed state object or a `Bus` signal. Audio is a listener's
job.

### ⚠️ Data-shape problems

- Trait positions randomised per call (see 1b) — must become deterministic.
- `STAGE_TINTS` hardcoded in the eye; belongs in `Palette.TIER_ACCENTS`.
- `_tex_cache` hand-rolled inside the view.
- Inline shader source built from a GDScript string literal.

---

## 4. PROPOSED v2 CONTRACT

```
        PROGRESSION          AMBIENT           INPUT
             │                  │                │
             ▼                  ▼                ▼
      ┌──────────────────────────────────────────────┐
      │  IrisState  (typed Resource — Phase 1)       │
      │  stage · tier · traits[] · mood · warmth ·   │
      │  glow_bonus · reduced_motion                 │
      └───────────────────┬──────────────────────────┘
                          │  one typed object in
                          ▼
      ┌──────────────────────────────────────────────┐
      │  IrisView  (pure shader view — Phase 3)      │
      │  · renders                                   │
      │  · lives autonomously (breathe/blink/saccade)│
      │  · knows NOTHING about routes, audio, saves  │
      │  · reads only Palette                        │
      └───────────────────┬──────────────────────────┘
                          │  emits
                          ▼
      gaze_changed(dir) · tapped(zone) · expression_finished(kind)
                          │
                          ▼
              Bus ──► Router / Audio / Home
```

**Inbound API (commands):**
`apply_state(s: IrisState)` · `express(kind: StringName, intensity: float)` ·
`look_at(dir: Vector2)` · `set_interactive(bool)` · `arc_point(t) -> Vector2`

**Outbound (via Bus):**
`iris_tapped(zone: StringName)` · `iris_gaze_changed(dir: Vector2)` ·
`iris_expression_finished(kind: StringName)`

**Net effect:** ~250 lines of bloat leave the eye. What remains is rendering and
autonomous life — the two things that actually make it feel alive, and the two
things v1 did well.

---

## 5. OPEN DECISIONS FOR PHASE 1

1. **Resonance → Iris?** Currently invisible on the eye. Should spending or
   holding Resonance change it?
2. **Streak → Iris?** Only absence registers today. Should a 7-day streak show?
3. **Keep the iris-compass?** Beautiful but undiscoverable — every destination
   needed a duplicate TabBar button. Keep, cut, or redesign?
4. **Trait determinism** — confirm flecks become fixed per trait id.
5. **Stage count** — keep 8 textures + infinite cycling, or go fully procedural
   (no textures, unlimited stages)? Procedural removes 9.3 MB.


---

## IMPLEMENTATION STATUS

| Phase | Deliverable | State |
|---|---|---|
| 1 | `data/iris_state.gd` — typed view model, infinite rank engine | ✅ approved |
| 2 | `shaders/iris_procedural.gdshader` + `nodes/iris_view.gd` | ✅ approved |
| 3 | `screens/hub_portal.tscn` + `nodes/hub_portal_controller.gd` | ✅ complete |

### The compass boundary, as built

```
IrisView                 HubPortalController          Router
─────────                ───────────────────          ──────
hit-tests direction  →   SHARD_ROUTES[shard]      →   ROUTES[route]
emits shard id           maps id -> route name        swaps the scene

knows no route names     knows no rendering           knows no shards
```

v1 collapsed all three into `IrisCore.gd`, which held route names *and* asset
paths and called `change_scene_to_file()` itself. Adding a screen meant editing
the eye. Changing a destination is now one line in `SHARD_ROUTES`.

### Read-only enforcement

`tests/test_hub_portal.py` fails the build if the hub ever:
- assigns any `_state` field directly,
- calls a mutator outside the transient set (`set_compass_shard`,
  `set_dilation`, `set_portal_transition`, `set_gaze`, `clear_interaction`),
- calls `grant_seed`, `grant_rental`, `register_ad_watch`, `add_rank_xp`,
  `map_legacy_profile_data`, or `prune_expired_rentals`,
- writes to `Save`.

Those transient fields are excluded from `IrisState.to_dict()`, so hub
interaction can never reach disk.

### Decisions resolved

1. **Resonance → Iris:** yes. `lens_shimmer` drives a chromatic sheen through
   the stroma, so the currency is visibly worn.
2. **Streak → Iris:** deferred to Phase 4 (progression owns streak logic).
3. **Iris-compass:** kept, with labelled markers ringing the eye so the gesture
   is discoverable. A dead-zone tap still starts a trial for players who never
   learn the drag.
4. **Trait determinism:** resolved — seeds derive from FNV-1a of the SKU.
5. **Procedural vs textures:** fully procedural. 9.3 MB removed.
