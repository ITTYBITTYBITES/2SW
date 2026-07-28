# PROJECT_INDEX.md

**Two Second Witness — v2** · Godot 4.6.3 · GDScript 2.0
Last updated: 25 July 2026

A map of the active project. For the rules that govern changes to it, see
[`AGENTS.md`](AGENTS.md).

---

## Autoloads

Registered in `project.godot` under `[autoload]`. **Order is dependency-driven** —
each singleton may only reference ones declared above it.

| # | Name | Path | Deps | Responsibility |
|---|------|------|------|----------------|
| 1 | `Log` | `res://core/log.gd` | — | Structured logging; `must()` invariants |
| 2 | `Cfg` | `res://core/cfg.gd` | Log | Build flags, env config, secret loading |
| 3 | `Bus` | `res://core/bus.gd` | — | Global signal hub (zero state, zero logic) |
| 4 | `Save` | `res://core/save.gd` | Log | Atomic JSON persistence, migrations, session |
| 5 | `Palette` | `res://design/palette.gd` | Save, Bus | Theme tokens, colour, motion timing |
| 6 | `Router` | `res://core/router.gd` | Log, Save, Bus, Palette | Screen manager + back stack |

`Router` is last because it touches all four. `Bus` has no dependencies by
design, so anything may depend on it without forming a cycle.

---

## Directory Structure

```
res://
├── app/                  Persistent root shell — never unloaded
│   ├── app.gd            Lifecycle, back handling, resume, toast host
│   └── app.tscn          %Screens · %Overlay · %Toasts · %ConfirmQuit
│
├── core/                 Autoload singletons
│   ├── log.gd            Levels, breadcrumb ring, must()
│   ├── cfg.gd            build_config.cfg reader; debug forces test ads
│   ├── bus.gd            All cross-system signals, emitter documented
│   ├── save.gd           Atomic JSON, versioned migrations, session snapshot
│   └── router.gd         ROUTES table, back stack, crossfade swap
│
├── data/                 Typed Resources — trial defs, cosmetics, achievements
│                         (Phase 1 output; empty until first feature lands)
│
├── systems/              Headless gameplay controllers
│                         (Phase 2 output; empty until first feature lands)
│
├── design/
│   └── palette.gd        COLOR_* · SPACE_* · FONT_* · DURATION_* · TIER_ACCENTS
│
├── ui/
│   └── screen.gd         Base class: configure(), safe area, on_back_requested()
│
├── screens/              One folder per full-screen view
│   ├── splash/           Studio ident + title/loading, one screen, two acts
│   ├── consent/          Privacy gate — single card, one button
│   ├── intro/            First-run introduction
│
├── art/
│   └── branding/icon.svg 8 KB total; hard CI budget 20 MB
│
├── docs/
│   └── features/         One design note per feature
│
├── tests/                Headless; no Godot binary required
│   ├── run_all.sh              Entry point
│   ├── lint_gdscript.py        Indentation, blocks, duplicate decls
│   ├── check_xrefs.py          Every Autoload.member resolves
│   ├── check_architecture.py   All AGENTS.md constraints
│   └── test_boot.py            Back stack + resume behaviour
```

### Where the v1 source went

`legacy_reference/` (37 .gd files, 9 docs) was archived once v2 became
feature-complete and every formula had been re-derived into `data/` and
`core/` with tests behind it. It lives on the `legacy-v1` branch and the
annotated `legacy-v1-archive` tag:

```bash
git show legacy-v1-archive:legacy_reference/README.md
git checkout legacy-v1 -- legacy_reference/
```

It was quarantined while present because those scripts reference deleted v1
autoloads (`GameState`, `SaveSystem`, `IrisProgression`) and would throw a
parse error on project open without `.gdignore`, and because they carry ~188
rule violations by design — they are the code being replaced.

Live AdMob ids in the v1 source were **redacted** during the original copy;
neither this repo nor the archive contains a live secret.

**Firebase:** v2 does not use it. Three archived store docs still contain
Firebase sections — strip them before reuse.

---

## Core Systems

### `Log` — `res://core/log.gd` · 79 lines
Levels `DEBUG/INFO/WARN/ERROR`; verbose in debug, `WARN`+ in release.
A 120-entry breadcrumb ring is retained for crash reports.

```gdscript
Log.must(cond: bool, tag: String, msg: String) -> bool
```
Hard-asserts in debug, logs and continues in release. Returns `cond` so it
reads inline as a guard.

### `Cfg` — `res://core/cfg.gd` · 62 lines
Reads gitignored `build_config.cfg` (template: `build_config.example.cfg`).
`use_test_ads` is **derived** from `OS.is_debug_build()` with no setter — a
debug build cannot serve live ads. Exposes `banner_id()`, `rewarded_id()`,
`app_id()`.

### `Bus` — `res://core/bus.gd` · 54 lines
Signal groups: progression, trial lifecycle, iris expression, navigation, app
lifecycle, palette, toasts. Each declares its emitter in a comment.
Subscribe in `_ready()`, disconnect in `_exit_tree()` — CI enforces the pairing.

### `Save` — `res://core/save.gd` · 289 lines
Atomic JSON at `user://witness.save.json`.

- **Atomic writes** — `.tmp` → rotate to `.bak` → rename. A kill mid-write
  leaves a complete old or new file, never a truncated one.
- **Versioned migrations** — `CURRENT_VERSION` with a runner loop. The runner
  exists before the first migration does; downgrades are left untouched.
- **`ensure_trial(id)`** — history seeded from the trial registry, never a
  hardcoded list. (v1 hardcoded three ids and omitted `facet_cascade`, pinning
  20% of trials to Easy forever.)
- **Session snapshot** — `write_session()` / `read_session()` powers resume.
- **Debounce** — `flush_soon()` coalesces a burst into one write; `flush()`
  forces it on pause/quit.

### `Palette` — `res://design/palette.gd` · 213 lines
Every visual constant. Dark-room tuned: backgrounds at L\* 6–12 (never pure
black — it smears on OLED and kills the Iris glow), text capped at 0.82 white.

Tokens: `COLOR_BACKGROUND` `COLOR_SURFACE` `COLOR_TEXT*` `TIER_ACCENTS[8]`
`COLOR_PUPIL` `COLOR_CATCHLIGHT` `SPACE_*` `FONT_*` `DURATION_*`
`TRANSITION_SPEED`.

Accessibility resolves centrally: `font()` applies text scale, `duration()`
collapses under reduced-motion, `success()`/`danger()` return colourblind-safe
variants, `accent()` honours high-contrast.

### `Router` — `res://core/router.gd` · 167 lines
The only owner of what's on screen. Swaps children under `%Screens`; **never**
calls `change_scene_to_*`, so autoloads and the shell survive every transition.

```gdscript
Router.go(route: String, payload: Dictionary = {}) -> void     # push
Router.replace(route: String, payload: Dictionary = {}) -> void # swap
Router.back() -> bool                                           # pop
```

`ROOT_ROUTES` (`hub`, `splash`, `consent`, `intro`) clear the stack.
`back()` offers the active screen first refusal via `on_back_requested()`,
then pops; returning `false` means the stack is empty and `App` confirms exit.

---

## Screen Contract — `res://ui/screen.gd`

```gdscript
extends Screen

func _setup() -> void:              # override instead of _ready()
func on_back_requested() -> bool:   # return true to consume back
func _on_palette_changed(t: int) -> void
```

- `configure(payload)` runs **before** `_ready()` — no global-read races.
- Safe-area insets (`safe_top/bottom/left/right`) resolved once, plus
  `make_safe_container()`.
- Base `_exit_tree()` disconnects the palette subscription; subclasses adding
  their own must call `super()`.

---

## Boot Chain

```
app.gd::_boot()
  │
  ├─ consent not accepted ──────────→ consent      (always gated first)
  │
  ├─ resumable session ─────────────→ that route
  │     route ∉ {splash, results, trial}
  │     AND away < 90 min
  │
  └─ otherwise ──→ splash ─replace→ {consent | intro | hub}
```

`replace()` through the intro means back at Home cannot walk into the ident.
The consent gate precedes the resume check — a bug `test_boot.py` caught before
it shipped.

---

## Development Workflow

Every feature runs through three approval-gated phases (see `AGENTS.md`):

| Phase | Output | Location | Gate |
|---|---|---|---|
| 1 | Typed data model / Resource | `data/` or `core/` | STOP → approval |
| 2 | Headless controller + test | `systems/` or `core/`, `tests/` | STOP → approval |
| 3 | Scene & UI attachment | `ui/` or `screens/` | STOP → sign-off |

No UI is built before its controller is approved; no controller before its data
model is approved.

---

## Verification

```bash
./tests/run_all.sh
```

| Check | Enforces |
|---|---|
| `lint_gdscript.py` | Tabs, block structure, duplicate declarations |
| `check_xrefs.py` | Every `Autoload.member` reference exists |
| `check_architecture.py` | All five AGENTS.md constraints + secrets + layout |
| `test_boot.py` | 14 back-stack / resume assertions |

CI additionally guards committed secrets, `.godot/` cache, and the 20 MB art
budget.

---

## Status

| Area | State |
|---|---|
| Shell, Router, Save, Palette | ✅ Complete, tested |
| Sponsor, Loading | ✅ Complete |
| Iris (procedural shader eye) | ✅ Complete |
| Hub Portal + compass routing | ✅ Complete |
| Wardrobe + cosmetic economy | ✅ Complete |
| Procedural cosmetic renderer | ✅ Complete |
| Progression + Lumina economy | ✅ Complete |
| 4 trial mini-games | ✅ Complete |
| Trial registry + adaptive difficulty | ✅ Complete |
| Dialogue, procedural audio, Daily hub | ✅ Complete |
| Progress analytics + Settings | ✅ Complete |
| Consent screen | ⬜ Required before store submission |
| AdMob integration | 🟡 Stubbed behind a clean boundary |
| Run in Godot | ⬜ **Never done — largest remaining risk** |

See `PROJECT_SUMMARY.md` for the full v1→v2 comparison and verification record.

**Next:** the Iris — parallax limbal ring, refracted stroma, saccades and
microsaccades, curve-based lid geometry. Rendering tokens are already in
`palette.gd`; the technique is previewed by the Iris progress mark in
`splash_visuals.gd`.
