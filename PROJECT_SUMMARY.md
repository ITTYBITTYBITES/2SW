# Two Second Witness v2 — Project Summary

**Status:** feature-complete; compiles and boots cleanly in a real engine
**Engine:** Godot 4.3 (verified) · GDScript 2.0
**Suites:** 15 · all green · 0 lint errors · 0 architecture violations
**Engine validation:** 70 structural + 21 consent checks pass headless

---

## Scale

| | v1 | v2 |
|---|---|---|
| Repo size | 160 MB | **148 KB** |
| Art assets | 69 MB | **8 KB** (one SVG icon) |
| GDScript | 7,604 lines | 9,096 lines |
| Automated tests | 0 | **2,688 lines, 13 static suites + 68 engine checks** |
| Asserts / invariants | 1 | ~180 `Log.must` guards |

The size difference is not compression — it is the absence of raster art.
The eye, every cosmetic, every trial visual, and all audio are generated at
runtime from maths.

---

## What was built

```
res://
├── app/          persistent shell (never unloaded)
├── core/         log · cfg · bus · save · router
├── data/         iris_state · progression_engine · adaptive_difficulty
│                 trial_registry · cosmetic_def/catalog
│                 dialogue_manifest · audio_manager
├── design/       palette (every colour, size, duration)
├── nodes/        iris_view · cosmetic_renderer/mount
│                 hub_portal · wardrobe · trial · results
│                 daily_hub · progress_view · settings_view
│                 trials/ (4 mini-games + base)
├── screens/      12 scenes
├── shaders/      iris_procedural.gdshader
└── tests/        13 headless suites, no Godot binary required
```

**Screen web:** Hub ⇄ Daily · Wardrobe ⇄ Settings · Progress · Trial → Results

---

## The v1 defects, and what replaced them

| v1 defect | Root cause | v2 |
|---|---|---|
| Back button quit the app mid-run | `quit_on_go_back` default; no trial handled the notification | Router back stack; trials intercept with a forfeit confirm |
| Samsung resume reloaded the game | All state in the scene tree; `change_scene_to_file` everywhere | Persistent `App` root + session snapshot |
| Eye felt dead | 8 static PNGs (9.3 MB) with tint swaps, rect lids | Procedural shader: Voronoi stroma, SDF lids, parallax glint, micro-saccades |
| Freckles moved every launch | `_apply_traits()` re-randomised positions | FNV-1a seeds, re-seeded before every draw |
| `facet_cascade` pinned to Easy forever | Trial identity spread across 4 tables; one omitted it | One `TrialRegistry`; `all_ids()` drives everything |
| No difficulty curve | Adaptation existed but never ran for 20% of trials | `AdaptiveDifficulty`, rolling 10, verified at boundaries |
| Same voice line twice in 4 seconds | 3 clips, `welcome` on two screens | Shuffle bag: **0 repeats in 6,000 draws** vs 1,028 naive |
| Committed Firebase key + live AdMob IDs | Secrets in source | `Cfg` + gitignored `build_config.cfg`; CI secret scan |
| 1 assert in 7,604 lines | Silent-fallback culture | `Log.must` crashes in debug, breadcrumbs in release |
| 69 MB of sprites | No asset budget | Procedural everything; CI budget of 20 MB |

---

## Rules enforced mechanically

`tests/check_architecture.py` fails CI on any violation:

| Rule | Enforcement |
|---|---|
| Strict static typing | Return types, typed params, no bare `var x =` |
| `%UniqueName` only | No `$Node`; referenced names must exist in a `.tscn` |
| `Router` owns navigation | No `change_scene_to_*` anywhere, including Router |
| `Bus` decoupling | Every `connect` needs a matching `disconnect` |
| `Palette` styling | No literal `Color()`, font size, or duration |
| Secrets | No live `ca-app-pub-` ids or `AIza` keys |
| **Routing** | Every route target must exist; every used route declared |
| Layout | snake_case, required dirs, autoloads registered |

The routing rule was added in Phase 9 after five broken routes shipped
undetected — see below.

---

## Bugs the tests caught

Not hypotheticals; each was found and fixed:

- **Five broken routes**, including `trial` — the compass North shard and every
  daily launch pointed at a scene that did not exist. Nothing caught it because
  checks validated `%UniqueName` *inside* scenes, never route targets.
- **Settings was orphaned** — no screen navigated to it. Found by a graph
  reachability test, not by reading code.
- **Consent gate bypassed on resume** — a resumable session skipped it entirely.
  A Play Store compliance failure.
- **Six Rule D violations** in freshly written eye-drawing code.
- **Four `$Node` paths** in `app.gd`, including `$Overlay/Toasts`.
- **`facet_cascade` missing entirely** from the v2 trial suite.
- **Cognitive Conflict shortened** from 8 rounds to 4 during a refactor.

Several test *failures* also turned out to be bugs in the tests themselves
(a regex matching `SHARD_LABELS` instead of `SHARD_ROUTES`; `%d` format
specifiers read as node accessors; a move-budget case that succeeded rather
than exhausting). Those were fixed in the tests — a suite that cries wolf
gets ignored.

---

## Verification highlights

| Property | Evidence |
|---|---|
| Infinite rank engine | XP↔rank exact inverses to **rank 1,000,000** |
| Economy cannot be exploited | Overspend, double-grant, expired-rental revocation all rejected |
| No integer overflow | 2,000 max awards stay in range; saturation credits 0 |
| Streak survives edge cases | Clock rewind neither claims nor resets; best preserved |
| Trial weights honoured | 200k draws within 0.6% of 35/25/20/20 |
| Match-3 correct | L/T unions share corners once; 900 boards start unmatched |
| Adaptive thresholds exact | 0.63/0.87 exclusive; window resets to stop runaway |
| Voice never repeats | 0 back-to-back in 6,000 draws |
| Audio cannot clip | Peak ≤ 0.72 across voice/pad/SFX; pad DC = 0.00003 |

---

## Engine validation

The project was previously never run in Godot — the largest open risk. That is
now resolved, and it found a project-breaking bug on the first attempt.

**The bug:** `iris_state.gd` declared

```gdscript
@export var active_rental_passes: Dictionary[StringName, float] = {}
```

Typed `Dictionary` is **Godot 4.4+ syntax**. On 4.3 it is a hard parse error,
and because `IrisState` is imported almost everywhere it cascaded — the trial
controller, wardrobe, results and settings controllers all failed to load. The
entire project was uncompilable.

No static checker caught it: the syntax is valid GDScript, just for a newer
engine. This is precisely the class of defect only the real compiler finds.

**Now passing, 68 checks:**

| Section | Coverage |
|---|---|
| Script compilation | all 35 `.gd` files load as `GDScript` |
| Scene instantiation | all 12 `.tscn` files instantiate |
| Autoloads | all 7 attach to the tree |
| Registries | self-validate; every route target resolves on disk |
| Node paths | every `@onready %UniqueName` resolves in its own scene |
| Live logic | rank inverse to 100k, overspend rejection, adaptive thresholds, save round-trip, 200 voice draws with 0 repeats |
| **Boot** | `app/app.tscn` instantiates, Router reaches a declared route, a `Control` is mounted |

Run with `./tools/godot_validate.sh`, or automatically via `tests/run_all.sh`
when an engine is reachable. CI caches the binary and gates on it.

Two headless gotchas, documented in `tools/validate.gd` because they cost real
time: `--script` **replaces** the main loop (the declared main scene never
auto-runs, so it must be instantiated by hand), and autoloads do not exist
during `_init()` (naming `Router` directly is a compile error; it must be
resolved by node lookup on a deferred frame).

---

## Build & export

`export_presets.cfg.template` carries six presets: Android debug APK and
release AAB (min SDK 24, target 35), Linux, Windows, macOS, and iOS. Godot
parses them cleanly — the only failure is missing export templates, an ~800 MB
download rather than a config fault.

Committed as a **template** on purpose: a real preset carries keystore paths
and sometimes passwords, the same leak class as v1's committed Firebase key.
`export_presets.cfg` itself stays gitignored and CI writes its own from
secrets.

---

## Consent

First-run gate at `screens/consent/consent.tscn`, re-openable from
Settings → Privacy → Privacy Choices.

- Accepting the terms is required; **ad personalisation and analytics are
  separate and default OFF**. Tapping straight through yields the most private
  configuration, not the most permissive. Pre-ticked consent is unlawful under
  GDPR and would make the Play data-safety declaration false.
- Gated on **policy version**, not a bare boolean, so a material policy change
  re-prompts instead of assuming the old agreement still covers it.
- Withdrawal is as easy as granting — a one-way opt-in is not meaningful consent.
- `app.gd` gates **before** reading the session snapshot. v1 let the resume path
  route around consent entirely.

Verified live: fresh install gates, tap-through leaves both off, opt-in and
withdrawal both persist across a save reload, stale policy version re-prompts,
back is swallowed on the mandatory gate but allowed on a revisit.

---

## Known gaps

1. **AdMob plugin not installed.** `AdManager` runs in fallback mode by
   design; shipping needs the plugin in `addons/` and the App ID in the
   Android manifest.
2. **All Phase 2 placeholder screens are gone.** `screens/sponsor/`,
   `screens/loading/` and `screens/home/` were deleted once the splash and
   Hub Portal superseded them. `app.gd` validates a stored session route
   against `Router.ROUTES` before resuming, so an install that updates while
   sitting on a deleted route falls back to the splash instead of
   hard-asserting.
3. **Haptics unverified on hardware.** `_detect_support()` is false on
   desktop and headless, so every pulse is suppressed in testing.
4. **No visual/audio review.** Compilation, layout and warnings are proven;
   whether the eye *looks* alive and the pad is pleasant at 2am still needs
   human eyes and ears.
5. **Export templates not installed**, so no APK has been produced yet.

---

## Recommended next steps

1. **Open it in Godot.** Fix what the maths cannot predict: layout on a real
   aspect ratio, shader compilation, audio levels by ear.
2. **Consent screen**, then remove the auto-accept.
3. **AdMob wiring** behind the existing `AdSystem` boundary.
4. **Device pass** — safe areas, back button, and Samsung resume on hardware.
