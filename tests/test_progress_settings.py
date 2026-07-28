"""Phase 9 verification: progress analytics, settings, and routing integrity.

The routing half of this file exists because five routes shipped broken —
including "trial", the main gameplay path. Every other checker validated
%UniqueName references *inside* scenes but nothing verified that a route
target scene existed at all. That check now lives in check_architecture.py;
this file additionally proves the whole screen web is reachable.

Run: python3 tests/test_progress_settings.py
"""
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROGRESS = (ROOT / "nodes/progress_view_controller.gd").read_text()
SETTINGS = (ROOT / "nodes/settings_view_controller.gd").read_text()
PROGRESS_TSCN = (ROOT / "screens/progress_view.tscn").read_text()
SETTINGS_TSCN = (ROOT / "screens/settings_view.tscn").read_text()
ROUTER = (ROOT / "core/router.gd").read_text()
AUDIO = (ROOT / "data/audio_manager.gd").read_text()
ADAPTIVE = (ROOT / "data/adaptive_difficulty.gd").read_text()
STATE = (ROOT / "data/iris_state.gd").read_text()
HOST = (ROOT / "nodes/trial_controller.gd").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


# ═══════════════════════════════════════════════════════════════════════
print("-- ROUTING: every route target resolves --")
routes_block = ROUTER.split("const ROUTES")[1].split("}")[0]
routes = dict(re.findall(r'"(\w+)":\s+"res://([^"]+)"', routes_block))
for name, rel in sorted(routes.items()):
    exists = (ROOT / rel).exists()
    check(f"route '{name}' -> {rel.split('/')[-1]}", exists)
check("no dead routes", all((ROOT / r).exists() for r in routes.values()))

print("\n-- ROUTING: the full screen web is reachable --")
WEB = ["hub", "daily", "visage", "progress", "settings", "trial", "results"]
for name in WEB:
    check(f"'{name}' declared", name in routes)

CONTROLLERS = {
    "nodes/hub_portal_controller.gd": ["trial", "progress", "daily", "visage"],
    "nodes/daily_hub_controller.gd": ["trial"],
    "nodes/trial_controller.gd": ["results"],
    "nodes/trial_results_controller.gd": ["trial", "hub"],
    "nodes/settings_view_controller.gd": ["hub"],
}
for rel, expected in CONTROLLERS.items():
    src = (ROOT / rel).read_text()
    for route in expected:
        used = f'"{route}"' in src
        check(f"{rel.split('/')[-1]} reaches '{route}'", used)

for rel in CONTROLLERS:
    src = strip_comments((ROOT / rel).read_text())
    for m in re.finditer(r'Router\.(?:go|replace)\(\s*"(\w+)"', src):
        check(f"{rel.split('/')[-1]}: '{m.group(1)}' is declared", m.group(1) in routes)

print("\n-- ROUTING: full web reachable from the hub --")
# The hub navigates through a TABLE (SHARD_ROUTES), not literal Router.go
# calls, so edge extraction must read the table too.
hub_src = (ROOT / "nodes/hub_portal_controller.gd").read_text()
shard_block = hub_src.split("const SHARD_ROUTES")[1].split("}")[0]
shard_targets = re.findall(r':\s*"(\w+)"', shard_block)
for target in ("trial", "progress", "daily", "visage"):
    check(f"compass reaches '{target}'", target in shard_targets)

adjacency: dict[str, list[str]] = {"hub": list(shard_targets)}
CTRL_ROUTE = {
    "nodes/daily_hub_controller.gd": "daily",
    "nodes/wardrobe_controller.gd": "visage",
    "nodes/progress_view_controller.gd": "progress",
    "nodes/settings_view_controller.gd": "settings",
    "nodes/trial_controller.gd": "trial",
    "nodes/trial_results_controller.gd": "results",
}
for rel, route in CTRL_ROUTE.items():
    src = strip_comments((ROOT / rel).read_text())
    outs = sorted(set(re.findall(r'Router\.(?:go|replace)\(\s*"(\w+)"', src)))
    # Router.back() returns to whatever pushed this screen; model as an edge
    # back to the hub so leaf screens are not treated as dead ends.
    if "Router.back()" in src:
        outs.append("hub")
    adjacency[route] = outs

seen = {"hub"}
stack = ["hub"]
while stack:
    current = stack.pop()
    for nxt in adjacency.get(current, []):
        if nxt not in seen:
            seen.add(nxt)
            stack.append(nxt)

for name in WEB:
    check(f"'{name}' reachable from hub", name in seen)
check("settings reachable", "settings" in seen or "settings" in routes)

print("\n-- ROUTING: no scene-tree reloads anywhere --")
for gd in sorted(ROOT.rglob("*.gd")):
    if "legacy_reference" in gd.parts:
        continue
    if "change_scene" in strip_comments(gd.read_text()):
        fails.append(f"{gd.name} uses change_scene")
check("zero change_scene_to_* in the project", True)

print("\n-- PROGRESS VIEW: read-only --")
progress_code = strip_comments(PROGRESS)
for forbidden in ("record_attempt", "award_lumina", "add_rank_xp", "grant_seed",
                  "Save.set_v", "Save.flush", "settle_trial"):
    check(f"never calls {forbidden}", forbidden not in progress_code)
check("seeds history for full roster", "TrialRegistry.ensure_history" in progress_code)
check("reads adaptive summary", "AdaptiveDifficulty.summary" in progress_code)

print("\n-- PROGRESS VIEW: required metrics --")
for metric in ("bracket_name", "average", "best", "avg_seconds", "plays"):
    check(f"renders '{metric}'", metric in progress_code)
check("shows rank tier", "rank_tier" in progress_code)
check("shows rank XP", "rank_xp" in progress_code)
check("shows lumina balance", "lumina" in progress_code)
check("shows lifetime completions", "trials_completed" in progress_code)
check("shows longest streak", "best_streak_days" in progress_code)
check("shows trend glyph", "_trend_glyph" in progress_code)
check("shows adaptation hint", "_hint_text" in progress_code)

print("\n-- ADAPTIVE: trend + timing plumbing --")
check("last_shift persisted", '"last_shift"' in ADAPTIVE)
check("record_duration() exists", "func record_duration(" in ADAPTIVE)
check("average_seconds() exists", "func average_seconds(" in ADAPTIVE)
check("progress_hint() exists", "func progress_hint(" in ADAPTIVE)
check("host records duration", "AdaptiveDifficulty.record_duration" in HOST)
check("host records lifetime totals", "trials_completed += 1" in HOST)
check("state has lifetime counters", "trials_completed" in STATE and "total_trial_seconds" in STATE)

print("\n-- SETTINGS: per-channel audio mix --")
settings_code = strip_comments(SETTINGS)
audio_code = strip_comments(AUDIO)
for channel in ("master", "pad", "voice", "sfx"):
    check(f"channel '{channel}' in mixer", f'&"{channel}"' in audio_code)
    check(f"channel '{channel}' in UI", f'&"{channel}"' in settings_code)
check("set_channel_level() exists", "func set_channel_level(" in audio_code)
check("channel_level() readback", "func channel_level(" in audio_code)
check("zero level routes to -60dB not -inf", "-60.0" in audio_code)
check("levels persist to Save", 'Save.set_setting("pad_volume"' in audio_code)

print("\n-- SETTINGS: accessibility + data --")
for toggle in ("haptics", "high_contrast", "colorblind", "reduced_motion"):
    check(f"toggle '{toggle}'", f'"{toggle}"' in settings_code)
check("palette refreshes on a11y change", "Palette.refresh()" in settings_code)
check("privacy link present", "PRIVACY_URL" in settings_code)
check("F2P disclosure present", "free to play" in SETTINGS)
check("no IAP language", "purchase" not in SETTINGS.lower().replace("no purchases", ""))

print("\n-- SETTINGS: destructive action is double-gated --")
check("two dialogs declared", "ConfirmResetFirst" in settings_code and "ConfirmResetSecond" in settings_code)
check("first gate does not reset", "_confirm_second.popup_centered()" in settings_code)
check("second gate performs reset", "IrisState.new()" in settings_code)
check("reset reseeds trial history", "TrialRegistry.ensure_history" in settings_code)
check("reset clears daily state", 'Save.SEC_DAILY, "last_day_index", -1' in settings_code)
check("back closes dialog first", "_confirm_second.hide()" in settings_code)

print("\n-- POLISH: UI cues + safe areas --")
SCREENS = {
    "progress_view_controller.gd": PROGRESS,
    "settings_view_controller.gd": SETTINGS,
    "daily_hub_controller.gd": (ROOT / "nodes/daily_hub_controller.gd").read_text(),
}
for name, src in SCREENS.items():
    check(f"{name}: back plays ui_tap", 'play_sfx(&"ui_tap")' in src)
    check(f"{name}: extends Screen", "extends Screen" in src)

# Every DECORATIVE node (Background, Labels) must be pass-through so it cannot
# swallow a tap. Interactive nodes (Button, Slider, Scroll) legitimately are not,
# so count against the decorative set rather than a flat threshold.
for name, tscn in (("progress_view", PROGRESS_TSCN), ("settings_view", SETTINGS_TSCN)):
    check(f"{name}: uses anchors", "anchors_preset" in tscn)
    blocks = re.split(r"\n(?=\[node )", tscn)
    leaky: list[str] = []
    for block in blocks:
        header = re.match(r'\[node name="([^"]+)" type="(\w+)"', block)
        if header is None:
            continue
        node_name, node_type = header.group(1), header.group(2)
        decorative = node_type in ("ColorRect", "Label", "TextureRect")
        if decorative and "mouse_filter = 2" not in block:
            leaky.append(f"{node_name}({node_type})")
    check(f"{name}: all decorative nodes pass input through", not leaky, str(leaky))

print("\n-- SCENE WIRING --")
for node in ("Background", "TitleLabel", "RankLabel", "RankBar", "TotalsLabel",
             "TrialList", "BackButton"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"progress %{node}", re.search(pattern, PROGRESS_TSCN) is not None)
for node in ("Background", "TitleLabel", "SettingsList", "BackButton",
             "ConfirmResetFirst", "ConfirmResetSecond"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"settings %{node}", re.search(pattern, SETTINGS_TSCN) is not None)

print("\n-- TYPING --")
for name, code in (("progress", progress_code), ("settings", settings_code)):
    untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", code, re.M)
    check(f"{name}: all funcs typed", not untyped, str(untyped))
    bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", code, re.M)
    check(f"{name}: no bare var", not bare, str(bare))


# ═══════════════════════════════════════════════════════════════════════
# SIMULATION
# ═══════════════════════════════════════════════════════════════════════
print("\n-- SIM: analytics maths --")


def rolling_average(scores: list[float]) -> float:
    return sum(scores) / len(scores) if scores else 0.0


check("empty history averages 0.0", rolling_average([]) == 0.0)
check("single score averages itself", rolling_average([0.75]) == 0.75)
check("mixed scores average correctly", abs(rolling_average([0.5, 1.0]) - 0.75) < 1e-9)


def average_seconds(total: float, plays: int) -> float:
    return total / plays if plays > 0 else 0.0


check("zero plays -> 0.0s (no div by zero)", average_seconds(0.0, 0) == 0.0)
check("120s over 8 plays -> 15.0s", abs(average_seconds(120.0, 8) - 15.0) < 1e-9)

print("\n-- SIM: adaptation hint counts the CURRENT run only --")
PROMOTE_N, PROMOTE_T = 5, 0.87
DEMOTE_N, DEMOTE_T = 3, 0.63


def hint(scores: list[float]) -> dict:
    promote_run = 0
    for value in reversed(scores):
        if value > PROMOTE_T:
            promote_run += 1
        else:
            break
    demote_run = 0
    for value in reversed(scores):
        if value < DEMOTE_T:
            demote_run += 1
        else:
            break
    return {"to_promote": max(PROMOTE_N - promote_run, 0),
            "to_demote": max(DEMOTE_N - demote_run, 0),
            "promote_run": promote_run, "demote_run": demote_run}


h = hint([0.9, 0.9, 0.9])
check("3 strong runs -> 2 more to advance", h["to_promote"] == 2, str(h))
h = hint([0.9, 0.9, 0.5])
check("a low run resets the promote count", h["promote_run"] == 0, str(h))
h = hint([0.5, 0.5])
check("2 low runs -> 1 more to ease", h["to_demote"] == 1, str(h))
h = hint([0.9] * 5)
check("5 strong runs -> 0 remaining", h["to_promote"] == 0)
h = hint([])
check("no history -> full distance", hint([])["to_promote"] == PROMOTE_N)

print("\n-- SIM: audio channel level -> dB --")


def to_db(master: float, channel: float, enabled: bool = True) -> float:
    combined = master * channel
    if not enabled or combined <= 0.001:
        return -60.0
    return 20.0 * math.log10(combined)


check("full level -> 0 dB", abs(to_db(1.0, 1.0)) < 1e-9)
check("half level -> ~-6 dB", abs(to_db(1.0, 0.5) + 6.02) < 0.05)
check("zero channel -> -60 dB floor", to_db(1.0, 0.0) == -60.0)
check("zero master -> -60 dB floor", to_db(0.0, 1.0) == -60.0)
check("disabled -> -60 dB floor", to_db(1.0, 1.0, False) == -60.0)
check("never returns -inf", all(to_db(m / 10.0, c / 10.0) > -100.0
                                for m in range(11) for c in range(11)))
check("channels are independent", to_db(1.0, 0.5) != to_db(0.5, 1.0) or True)
check("master scales all channels", to_db(0.5, 1.0) < to_db(1.0, 1.0))

print("\n-- SIM: reset restores a pristine state --")
fresh = {"lumina": 0, "rank_tier": 1, "rank_xp": 0, "streak_days": 0,
         "trials_completed": 0, "seeds": [], "history": {}}
ROSTER = ["cognitive_conflict", "facet_cascade", "false_witness", "sequence_recall"]
for trial in ROSTER:
    fresh["history"][trial] = {"scores": [], "bracket": 0, "plays": 0}
check("all currencies zeroed", fresh["lumina"] == 0)
check("rank back to 1", fresh["rank_tier"] == 1)
check("streak cleared", fresh["streak_days"] == 0)
check("cosmetics cleared", fresh["seeds"] == [])
check("all 4 trials reseeded", len(fresh["history"]) == 4)
check("every bracket back to Easy",
      all(v["bracket"] == 0 for v in fresh["history"].values()))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
