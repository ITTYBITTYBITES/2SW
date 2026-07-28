# Two Second Witness — v2

A ground-up rebuild with **no dependency on v1** — not at runtime, not at
build time, not in the test harness. No v1 code was carried over; formulas
were re-derived, retyped and covered by tests.

The v1 source is archived on the `legacy-v1` branch and the `legacy-v1-archive`
tag if a historical question ever comes up:

```bash
git show legacy-v1-archive:legacy_reference/scripts/IrisCore.gd
git checkout legacy-v1 -- legacy_reference/
```

**Status:** feature-complete and playable end to end — splash, consent, intro,
hub, five trials, daily anomaly, trend hub, progression, wardrobe, settings.
1,237 checks green, zero compiler warnings across 56 scripts.

Not done: AdMob plugin not installed (ads run in fallback), export templates
not installed (no APK produced yet), haptics unverified on hardware.

---

## Why a rebuild

v1's bugs were not surface defects — each traced to a structural decision:

| Symptom | Root cause in v1 | Fixed by |
|---|---|---|
| Back button exits the app mid-game | `quit_on_go_back` left at default `true`; no trial scene handled `NOTIFICATION_WM_GO_BACK_REQUEST` | `Router` back stack + setting `false`; every back press routes through one handler |
| Samsung: leave app, return, game reloads | All state lived in the current scene; navigation was `change_scene_to_file()` | Persistent `App` root + session snapshot on pause |
| Gameplay feels funky / mistimed | Trials started after `await process_frame`, timing on tweens, input buffer papering over a race | Deterministic tick-driven trial loop *(next milestone)* |
| Eye doesn't feel alive | 8 static PNGs (9.3 MB) with tint swaps and a rect lid overlay | Procedural shader iris *(next milestone; previewed in Loading)* |
| Too bright / harsh | Literal colours scattered across 12 scripts and every `.tscn` | `design/Palette.gd` tokens, dark-room tuned |
| 69 MB of sprites | No asset budget; 16 hats at 1536×1024 | CI budget check; procedural art where possible |

---

## Architecture

```
App (persistent root — never destroyed)
├── Screens          ← Router swaps children here; autoloads survive
└── Overlay          ← toasts, quit confirm; above every screen

Autoloads (dependency-ordered, not convention-ordered)
  Log      res://core/log.gd       structured logging + debug invariants
  Cfg      res://core/cfg.gd       build constants, flags, secrets
  Bus      res://core/bus.gd       decoupled event hub, zero state
  Save     res://core/save.gd      atomic debounced JSON persistence
  Palette  res://design/palette.gd theme tokens, colour, motion timing
  Router   res://core/router.gd    centralized screen manager
```

### Mandatory rules — mechanically enforced

Rules are only real if they're checked. `tests/check_architecture.py` fails CI
on any violation, so these can't erode as the project grows.

| Rule | Requirement | Enforcement |
|---|---|---|
| **A** | Scene changes only via `Router.go/replace/back()`. Never `change_scene_to_*`. | grep across all `.gd` |
| **B** | No `$../` or `get_node("../")` traversal. Cross-system state via `Bus`. Every `Bus.x.connect()` needs a matching `disconnect()`. | AST-ish scan; connect/disconnect pairing |
| **C** | `Log.must(cond, tag, msg)` for invariants — halts in debug, breadcrumbs in release. No silent error returns. | flags bare `return` in error guards without a `Log` call |
| **D** | No hardcoded `Color()`, font size, or duration. Import from `Palette`. | literal scan, `design/palette.gd` exempt |
| **E** | Secrets only via `Cfg` ← gitignored `build_config.cfg`. | scans for live `ca-app-pub-` ids and `AIza` keys |
| — | snake_case filenames; required folders; all six autoloads registered | layout check |

The checker earned its keep immediately: it caught six Rule D violations in the
procedural eye-drawing code I'd just written, which is exactly the kind of thing
that becomes 12-scripts-of-scattered-literals if nobody's watching.

### Screen contract

Screens extend `ui/screen.gd`:
- `configure(payload)` runs **before** `_ready()` — no global-read races
- safe-area insets resolved once (v1 poked at hardcoded node names and silently
  did nothing when they didn't match)
- `on_back_requested() -> bool` to intercept back (e.g. "forfeit this run?")
- `_exit_tree()` disconnects Bus subscriptions; subclasses call `super()`

---

## Boot chain

```
App._boot()
  │
  ├─ consent not accepted? ──────────────→ consent   (always gated first)
  │
  ├─ resumable session?     ──────────────→ that route
  │     route ∉ {splash,results,trial}
  │     and away < 90 min
  │
  └─ otherwise ─────→ splash ─replace→ {consent | intro | hub}
```

`replace()` rather than `go()` through the intro, so back at the hub cannot
walk backwards into the ident.

---

## Screens built so far

**Sponsor** — procedural studio ident. Zero art bytes: the mark is drawn in
`_draw()` with breathing arcs and orbiting flecks. Skippable on tap (never trap
a returning player). ~2.0 s total, or near-instant under reduced motion.

**Loading** — does real work instead of faking a timer. Threaded-loads Home and
TrialHost, reports true `ResourceLoader` progress, and enforces a 1.0 s minimum
on-screen time so fast devices don't strobe. The progress indicator *is* an eye
opening — dead time becomes the first story beat, and it previews the
procedural iris technique the real Iris will use.

---

## Tests

No Godot binary needed; runs in CI.

```bash
./tests/run_all.sh
```

- `lint_gdscript.py` — indentation, block structure, duplicate declarations
- `check_xrefs.py` — every `Autoload.member` reference resolves
- `check_architecture.py` — the six mandatory rules above
- `test_boot.py` — back stack and boot/resume rules, each named for the v1 bug
  it prevents

These already earned their keep: `test_boot.py` caught that a resumable session
skipped the consent gate — a Play Store compliance failure — before it shipped.

---

## Next milestones

1. **The Iris** — procedural shader eye: parallax limbal ring, refracted
   stroma, real caustic catchlight, saccades + microsaccades, lid geometry that
   follows a curve rather than a rect. This is the "feels alive" work.
2. **Trial loop** — fixed-timestep host, deterministic seeds, input sampled on
   tick rather than buffered around a race.
3. **Home** — the console, with the Iris as the centrepiece.
4. **Progression / Save v2** — currencies, brackets seeded from the trial
   registry (never a hardcoded list).

---

## Layout

```
res://
├── app/        persistent root shell (app.tscn)
├── core/       autoloads: log, cfg, bus, save, router
├── design/     palette — colour, spacing, type, motion tokens
├── ui/         screen base class, reusable widgets, dialogs
├── screens/    full-screen views, one folder each
├── art/        8 KB today; hard CI budget of 20 MB
└── tests/      headless, no Godot binary required
```
