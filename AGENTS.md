# AGENTS.md — Workspace Architecture & Agent Workflow

**Project:** Two Second Witness (v2)
**Engine:** Godot 4.6 · GDScript 2.0
**Audience:** every contributor, human or AI.

Read this before writing a line of code. These are not style preferences — they
are load-bearing constraints, and **most are mechanically enforced** by
`tests/check_architecture.py`. CI fails on violation.

Each rule exists because its absence caused a specific, shipped bug in v1. The
"Why" notes are the receipts.

---

## CORE DIRECTIVES

You are a Godot 4.6 System Architect working directly in this workspace. You
build clean, decoupled, production-ready GDScript.

You are **strictly forbidden** from:
- writing code in a single monolithic dump,
- making unverified assumptions about existing structure,
- skipping a phase of the workflow below.

Read the file before you edit it. Check `PROJECT_INDEX.md` for what already
exists. When a fact is checkable in the workspace, check it rather than assume.

---

## MANDATORY 3-PHASE FEATURE WORKFLOW

Every feature, refactor, or mechanic migration runs in three phases.
**STOP and request user approval after each phase before continuing.**

Do not begin Phase 2 while Phase 1 is unapproved. Do not build UI for a
controller the user hasn't signed off on.

### PHASE 1 — Data Model & Contract

Pure data. No behaviour, no UI.

- Extract raw math, formulas, and state rules (from the archived v1 source when
  migrating).
- Write strongly-typed `Resource` or data scripts under `res://data/`
  (game content: trial definitions, cosmetics, achievements) or `res://core/`
  (engine-level contracts).
- **No UI, no scenes, no node accessors.** No `$Node`, no `%Unique`, no
  `get_node()`. If it touches the scene tree it belongs in Phase 3.
- Explicit types on every variable, parameter, and return value.
- Prefer `Resource` + `@export` so designers tune values in the inspector
  instead of editing code.

> **STOP.** Present the data model. Request approval.

### PHASE 2 — Logic Controller & Signal Contract

Behaviour, still headless.

- Create controller logic under `res://systems/` (gameplay systems: progression,
  trial host, economy) or `res://core/` (autoload singletons).
- Register every cross-system event in `res://core/bus.gd`, with the emitter
  named in a comment.
- Read balance and timing tokens from `Palette` or `Cfg`. Never inline a
  magic number that a designer might want to change.
- Write a test under `res://tests/` that verifies the logic and math **without
  opening a scene**. Formulas, inverses, boundary conditions, state transitions.
- Run `./tests/run_all.sh` and include the results.

> **STOP.** Present the controller and test output. Request approval.

### PHASE 3 — Scene & UI Attachment

Now, and only now, pixels.

- Build scenes under `res://ui/` (reusable widgets, dialogs) or
  `res://screens/` (full-screen views extending `ui/screen.gd`).
- Reference child nodes **only** via `%UniqueName`.
- Connect UI inputs to `Bus` signals — never call a method on a parent or
  sibling node.
- Route every screen transition through `Router`.
- Add the route to `Router.ROUTES` if it's a new screen.

> **STOP.** Present the final feature structure for sign-off.

### Feature notes

Each feature gets a note in `res://docs/features/<feature>.md` written at
Phase 1 and updated as phases land. Template lives in that folder's README.

---

## THE FIVE CONSTRAINTS

### 1. Strict Static Typing

```gdscript
# ✅ correct
var count: int = 0
var accent := Palette.accent()              # inferred, still static
func apply(amount: int, silent: bool) -> void:
func level_for(lumina: int) -> int:

# ❌ rejected by CI
var count = 0                               # bare '=' → Variant
func apply(amount, silent):                 # untyped params, no return type
func helper():                              # no return type
```

- `var x: Type = value` or `var x := value`. Never bare `var x = value`.
- Every `func` declares a return type, including `-> void`.
- Every parameter typed. Unused ones take a leading underscore: `_delta: float`.

**Why:** untyped GDScript boxes to `Variant`, costs performance in hot paths
(the trial tick and Iris shader update run every frame), and defers type errors
to a player's device instead of CI.

### 2. Scene Unique Node References

```gdscript
# ✅ correct — node marked unique_name_in_owner in the .tscn
@onready var _toasts: VBoxContainer = %Toasts

# ❌ rejected by CI
@onready var _toasts = $Overlay/Toasts
@onready var _player = get_node("../../Player")
var hud := get_node("/root/Main/UI/HUD")
```

- Any `$Node` or `$Node/Child` lookup is a violation.
- No `../` traversal, no `/root/` absolute paths.
- CI verifies each `%Name` **is actually marked** `unique_name_in_owner = true`
  in some `.tscn` — a typo fails the build instead of returning `null` at runtime.

**Why:** `$Overlay/Toasts` breaks silently the moment anyone reparents a node.
`%Toasts` survives any tree reshuffle. This rule caught four real violations in
`app.gd` the day it was written.

### 3. Decoupled Signaling via `Bus`

```gdscript
# ✅ correct
func _ready() -> void:
    Bus.trial_finished.connect(_on_trial_finished)

func _exit_tree() -> void:
    if Bus.trial_finished.is_connected(_on_trial_finished):
        Bus.trial_finished.disconnect(_on_trial_finished)

Bus.lumina_awarded.emit(amount, new_total)

# ❌ rejected
get_parent().get_parent().update_score(n)
get_node("../../HUD").refresh()
```

- Systems never reach into each other's node trees.
- Subscribe in `_ready()`, **disconnect in `_exit_tree()`**. CI pairs every
  `Bus.x.connect()` with a matching `disconnect()` in the same file.
- New signals declared in `core/bus.gd` with the emitter named in a comment.
- `Bus` holds **zero state, zero logic** — a hub, so anything may depend on it
  without forming a cycle.

**Why:** v1 hung gameplay signals off `GameState`, which also owned the state
machine and half of navigation. Three jobs in one file meant every system knew
about every other. Unpaired connections leaked: freed screens kept firing.

### 4. Navigation Strictly Through `Router`

```gdscript
# ✅ correct
Router.go("results", {"score": final})     # push onto the back stack
Router.replace("hub")                      # swap without growing the stack
var consumed: bool = await Router.back()   # pop

# ❌ rejected by CI
get_tree().change_scene_to_file("res://screens/hub_portal.tscn")
get_tree().change_scene_to_packed(scene)
```

- `change_scene_to_file` / `change_scene_to_packed` appear **nowhere**,
  including inside `Router` — it swaps child nodes under the persistent `App`
  root and never reloads the tree.
- Screens extend `ui/screen.gd` and receive arguments via `configure(payload)`,
  which runs **before** `_ready()`.
- Intercept back by overriding `on_back_requested() -> bool`.
- Route names are keys in `Router.ROUTES`, the single scene-path table.

**Why:** two shipped v1 bugs. `quit_on_go_back` was left at its default `true`
and no trial scene handled the back notification, so **back exited the app
mid-run**. And because every transition was `change_scene_to_file()`, all state
lived in the current scene — so when Samsung OneUI killed the backgrounded
activity, **the whole game reloaded** from the startup splash.

### 5. Colors and Sizes Strictly From `Palette`

```gdscript
# ✅ correct
bg.color = Palette.COLOR_BACKGROUND
label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))
tween.tween_property(node, "modulate:a", 1.0, Palette.duration(Palette.DURATION_MED))

# ❌ rejected by CI
bg.color = Color(0.03, 0.04, 0.08)
label.add_theme_font_size_override("font_size", 24)
tween.tween_property(node, "modulate:a", 1.0, 0.25)
```

- No literal `Color(...)` outside `design/palette.gd`.
- No literal font sizes — `Palette.font(Palette.FONT_*)` applies the user's
  text-size setting.
- No literal durations — `Palette.duration(Palette.DURATION_*)` collapses under
  reduced-motion.
- Accessibility resolves centrally: `Palette.success()` / `Palette.danger()`
  return colourblind-safe substitutes automatically.

**Why:** v1 scattered literals like `Color(0.03, 0.04, 0.08, 1)` through 12
scripts and every `.tscn`, so "it's too bright" meant hunting every call site,
and reduced-motion had to be re-implemented per screen. This checker caught six
violations in freshly written procedural eye-drawing code — proof the rule
erodes without enforcement.

---

## SELF-AUDIT CHECKLIST

Run through this **before presenting any code**. Do not delegate it to CI —
catch it yourself first.

1. **Strict Typing** — any untyped `var x`, untyped parameter, or `func` missing
   a return type? Fix before showing.
2. **Node References** — any hardcoded `$Path/To/Node`? Convert to `%UniqueName`
   and mark the node unique in its `.tscn`.
3. **Navigation** — any `change_scene_to_file()` / `change_scene_to_packed()`?
   Convert to `Router.go()` / `Router.replace()`.
4. **Decoupling** — any scene calling a method on a parent or sibling node?
   Refactor to emit via `Bus`.

Then run the machine check:

```bash
./tests/run_all.sh
```

Green means: GDScript lints, every cross-reference resolves, all constraints
hold, and the navigation/resume behaviour tests pass. No Godot binary required.

---

## LEGACY CODE MIGRATION PROTOCOL

**The v1 source is no longer in the working tree.** It was 37 GDScript files
(~7,600 lines) plus 9 documents under `legacy_reference/`, kept through the
rebuild so formulas could be re-derived and every v1 defect catalogued. That
job is done: the numbers now live in `data/` and `core/` with tests, so the
folder was archived rather than carried forever.

Retrieve it when a v1 defect resurfaces:

```bash
git show legacy-v1-archive:legacy_reference/scripts/IrisCore.gd
git checkout legacy-v1 -- legacy_reference/      # restore the whole tree
git log legacy-v1 -- legacy_reference/           # its history
```

The `legacy-v1` branch and the annotated `legacy-v1-archive` tag both point at
the last commit that contained it. Nothing was deleted, only moved out of the
way — the protocol below still governs anything extracted from it.

**Treat it ONLY as a reference for math formulas, scoring, and state rules.**

| Take | Never take |
|---|---|
| Level curves and XP formulas | Node structures and scene layouts |
| Difficulty tables per bracket | `$Path/To/Node` lookups |
| Scoring and accuracy rules | Untyped GDScript |
| Economy numbers, reward values | `change_scene_to_file()` calls |
| Progression checkpoints | Hardcoded `Color()` values |
| Timing constants | Silent fallbacks and empty error branches |

Migration is not copy-paste. Every extracted number gets **retyped**, re-homed
into `data/` or `design/palette.gd`, and **covered by a test** before it counts
as migrated. If a formula can't be justified, it doesn't come across.

Known v1 defects are documented in the archived `legacy_reference/README.md`
(`git show legacy-v1-archive:legacy_reference/README.md`) and summarised per
rule in this file — do not carry them forward.

---

## SECRETS

- All secrets resolve through `Cfg`, reading gitignored `build_config.cfg`
  (CI injects it at build time). Template: `build_config.example.cfg`.
- **A debug build cannot serve live ads.** `Cfg.use_test_ads` derives from
  `OS.is_debug_build()` and has no setter.
- CI scans source for live `ca-app-pub-` publisher ids and `AIza` API keys.

**Why:** v1 committed a live Firebase API key and live AdMob publisher ids to a
public repo. Public ad units invite invalid-traffic attacks that get AdMob
accounts suspended. v1 also gated release behind a human checklist item —
"remember to flip `USE_TEST_ADS := false`" — with revenue riding on memory.

---

## ERROR HANDLING

```gdscript
# ✅ invariant: halts in debug, breadcrumbs in release
if not Log.must(_host != null, "Router", "no host bound"):
    return

Log.warn("Save", "primary unreadable; falling back to .bak")

# ❌ silent failure
if resource == null:
    return
```

- `Log.must(cond, tag, msg) -> bool` asserts in debug, logs a breadcrumb in
  release. Use it for every system assumption.
- Never return early from an error branch without a `Log` call. CI flags it.
- Returning a *value* (`return null`, `return false`) as a legitimate query
  result is fine — that's an answer, not a swallowed error.

**Why:** v1 had **one** assert in 7,604 lines. A missing trial scene silently
awarded a neutral score and continued, so a typo'd path looked like working
software.

---

## WORKSPACE LAYOUT

```
res://
├── app/                Persistent root shell (app.tscn) — never unloaded
├── core/               Autoloads: log, cfg, bus, save, router
├── data/               Typed Resources: trial defs, cosmetics, achievements
├── systems/            Headless gameplay controllers
├── design/             palette.gd — colour, spacing, type, motion tokens
├── ui/                 screen.gd base class, reusable widgets, dialogs
├── screens/            Full-screen views, one folder each
├── art/                8 KB today; hard CI budget 20 MB
├── docs/features/      One design note per feature
└── tests/              Headless; no Godot binary required
```

v1 source lives on the `legacy-v1` branch / `legacy-v1-archive` tag, not in
the working tree.

```
```

Autoload registration order is dependency-driven — see `PROJECT_INDEX.md`.

---

## DEFINITION OF DONE

- All three phases approved by the user.
- Self-audit checklist clean.
- `./tests/run_all.sh` green.
- Feature note in `docs/features/` current.
- New logic covered by a headless test.

If you must violate a rule, change the rule **and its checker** in the same
commit, with the reason in the message. Silent exceptions are how v1 happened.
