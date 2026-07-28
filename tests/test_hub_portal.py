"""Phase 3 verification: Hub Portal scene, compass wiring, share, read-only.

Static analysis of nodes/hub_portal_controller.gd and screens/hub_portal.tscn.

The load-bearing guarantee here is READ-ONLY. The hub renders IrisState and may
touch only transient interaction drivers (gaze, dilation, hover, portal
progress) — never seeds, rentals, XP, or Save. Customisation belongs to the
Wardrobe. If that erodes, the hub silently becomes a second economy surface.

Also guards the compass boundary that v1 violated: the eye reported intent,
this controller maps intent to a route, Router owns the swap. No layer knows
more than its own job.

Run: python3 tests/test_hub_portal.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GD = (ROOT / "nodes/hub_portal_controller.gd").read_text()
TSCN = (ROOT / "screens/hub_portal.tscn").read_text()
ROUTER = (ROOT / "core/router.gd").read_text()
BUS = (ROOT / "core/bus.gd").read_text()

# Every .gd in the project, comments stripped, for whole-codebase contract
# checks. A signal's subscriber may live in any script, so an orphan can only
# be detected by looking at all of them at once.
ALL_GD = "\n".join(
    f.read_text()
    for f in sorted(ROOT.rglob("*.gd"))
    if "legacy_reference" not in f.parts and ".godot" not in f.parts
)

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def strip_comments(src: str) -> str:
    """Remove ## docs and # comments so prose can't satisfy or fail a check."""
    out = []
    for line in src.split("\n"):
        out.append(re.sub(r"#.*$", "", line))
    return "\n".join(out)


CODE = strip_comments(GD)


def const_block(name: str) -> str:
    """Isolate a single `const NAME ... {...}` block."""
    start = CODE.index(f"const {name}")
    return CODE[start : CODE.index("}", start)]


print("── COMPASS MAPPING: shard id -> route ──")
routes_block = const_block("SHARD_ROUTES")
routes = dict(re.findall(r"IrisState\.CompassShard\.(\w+):\s*\"(\w+)\"", routes_block))
EXPECTED = {
    "NORTH_TRIALS": "trial",
    "EAST_PROGRESS": "progress",
    "SOUTH_DAILY": "daily",
    "WEST_PROFILE": "visage",
    "NORTHEAST_TREND": "trend_hub",
}
for shard, route in EXPECTED.items():
    check(f"{shard} -> '{route}'", routes.get(shard) == route, f"got {routes.get(shard)}")
check("exactly 5 shards mapped", len(routes) == 5, str(len(routes)))

# The count above is a tripwire, not the real invariant. What actually matters
# is that the three shard tables AGREE: a shard with a route but no label is
# an unnamed portal, and one with a direction but no route is a dead zone the
# eye tracks toward and then refuses to open. v1 kept these in separate files
# and they disagreed.
labels = dict(re.findall(r"IrisState\.CompassShard\.(\w+):\s+\"([^\"]+)\"",
                         CODE.split("SHARD_LABELS")[1].split("}")[0]))
directions = set(re.findall(r"IrisState\.CompassShard\.(\w+):\s+Vector2",
                            CODE.split("SHARD_DIRECTIONS")[1].split("}")[0]))
check("every routed shard has a label", set(routes) == set(labels),
      f"routes={sorted(routes)} labels={sorted(labels)}")
check("every routed shard has a direction", set(routes) == directions,
      f"routes={sorted(routes)} dirs={sorted(directions)}")

declared = set(re.findall(r"\"(\w+)\":\s+\"res://", ROUTER))
for route in EXPECTED.values():
    check(f"Router.ROUTES declares '{route}'", route in declared)
check("'hub' route registered", "hub" in declared)
check("'hub' is a ROOT route", re.search(r"ROOT_ROUTES\s*:=\s*\[[^\]]*\"hub\"", ROUTER) is not None)

print("\n── READ-ONLY VIEW MODEL (the critical constraint) ──")
assignments = re.findall(r"_state\.(\w+)\s*=(?!=)", CODE)
check("no direct field assignment on _state", not assignments, str(assignments))

# The hub may write TRANSIENT interaction state and nothing else. Every name
# here is excluded from to_dict(), so none of them can reach the save file —
# that exclusion is asserted by tools/vision_gate_flow.gd rather than assumed.
#
# set_nav_unlocked mirrors Save.has_returned_from_trial() into the view model
# so the renderer and the controller read one value; the AUTHORITY is still
# Save, and the hub never writes it back.
ALLOWED_WRITES = {
    "set_compass_shard", "set_dilation", "set_portal_transition",
    "set_gaze", "clear_interaction",
    "set_vision", "set_nav_unlocked",
}
called = set(re.findall(r"_state\.(\w+)\(", CODE))
writes = {c for c in called if c.split("_")[0] in ("set", "grant", "add", "register", "roll", "map")}
check("only transient setters used", writes <= ALLOWED_WRITES, str(writes - ALLOWED_WRITES))

for forbidden in ("grant_seed", "grant_rental", "register_ad_watch",
                  "add_rank_xp", "map_legacy_profile_data", "prune_expired_rentals"):
    check(f"never calls {forbidden}()", forbidden not in CODE)

check("no Save writes", re.search(r"Save\.(set_v|flush|write_|set_setting|wipe)", CODE) is None)

print("\n── BUS CONTRACT ──")
for sig in ("surprise_drop_earned",):
    check(f"Bus declares {sig}", re.search(rf"signal {sig}\(", BUS) is not None)
for sig in ("iris_shard_hovered", "iris_shard_committed", "iris_tapped",
            "surprise_drop_earned"):
    check(f"subscribes to {sig}", f"Bus.{sig}.connect" in CODE)

# REGRESSION: the hub carried a "Share Iris" button for the entire life of
# the project that did nothing. It emitted iris_share_requested into the Bus,
# and NOTHING was ever connected to that signal — the "capture service" its
# comment described was never written. The old tests here asserted the signal
# was DECLARED and that the emit line APPEARED IN SOURCE, both of which were
# true of a button that visibly did nothing when pressed.
#
# Existence is not behaviour. Scoped deliberately to signals a BUTTON PRESS
# emits: those promise the player something happened, so an orphan is a
# visibly broken control. 15 other Bus signals are currently unsubscribed —
# they are observation points (level_changed, trial_completed, route_changed)
# that a future analytics or achievement listener will attach to, and an
# unheard notification is inert rather than misleading. Asserting on those
# would be noise; asserting on this one would have caught the Share button.
# The precise property: a handler whose ONLY observable effect is an
# unheard Bus signal. A handler that also toasts, navigates, plays audio or
# writes state is giving the player feedback through that other path —
# lumina_awarded has no listener yet, but the claim button that emits it
# also fires Bus.toast and a reward sound, so the press is not silent.
SUBSCRIBED = set(re.findall(r"Bus\.(\w+)\.connect", ALL_GD))
OTHER_EFFECT = re.compile(
    r"Router\.|AudioManager\.|HapticsManager\.|Save\.|"
    r"Bus\.toast\.emit|\.text\s*=|\.visible\s*=|\.disabled\s*="
)
dead_buttons: list[str] = []
for m in re.finditer(r"func (_on_\w*(?:pressed|tapped|clicked)\w*)\([^)]*\)[^:]*:", ALL_GD):
    body = ALL_GD[m.end():].split("\nfunc ")[0]
    emitted = set(re.findall(r"Bus\.(\w+)\.emit", body))
    if not emitted:
        continue
    if emitted - SUBSCRIBED and not OTHER_EFFECT.search(body):
        dead_buttons.append(
            "%s -> %s" % (m.group(1), sorted(emitted - SUBSCRIBED)))
check("no button press is silently inert", not dead_buttons, str(dead_buttons))

connected = set(re.findall(r"Bus\.(\w+)\.connect", CODE))
disconnected = set(re.findall(r"Bus\.(\w+)\.disconnect", CODE))
check("every connect has a disconnect", connected <= disconnected, str(connected - disconnected))
check("calls super() in _exit_tree", re.search(r"_exit_tree\(\)\s*->\s*void:\s*\n\s*super\(\)", CODE) is not None)

print("\n── NO DEAD SHARE PATH ──")
# The real share lives on the ChronoPulse result card, where it copies a
# spoiler-checked string to the clipboard and reports honestly when the
# platform has none. The hub never had one that worked.
for dead in ("build_share_snapshot", "_collect_equipped_ids",
             "iris_share_requested", "chrome_visibility_requested"):
    check(f"hub carries no dead '{dead}'", dead not in CODE)
check("hub scene has no Share button", "ShareButton" not in TSCN)

print("\n── NAVIGATION BOUNDARY ──")
check("no change_scene_to_* in code", "change_scene" not in CODE)
check("navigates through Router.go", "Router.go(" in CODE)
check("single navigation exit point", CODE.count("Router.go(") == 1, str(CODE.count("Router.go(")))
check("clears interaction before leaving", "clear_interaction()" in CODE)

print("\n── SCENE WIRING ──")
for node in ("Background", "IrisView", "ShardMarkers", "Chrome",
             "TitleLabel", "HintLabel", "RankLabel"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} marked unique", re.search(pattern, TSCN) is not None)
check("IrisView instanced from nodes/", 'path="res://nodes/iris_view.tscn"' in TSCN)

print("\n── INPUT PASS-THROUGH (no shard can steal a tap) ──")
check("marker container ignores input", "_markers.mouse_filter = Control.MOUSE_FILTER_IGNORE" in CODE)
check("marker labels ignore input", "label.mouse_filter = Control.MOUSE_FILTER_IGNORE" in CODE)
check("scene chrome is pass-through", TSCN.count("mouse_filter = 2") >= 6, str(TSCN.count("mouse_filter = 2")))

print("\n── TYPING ──")
untyped_funcs = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", CODE, re.M)
check("every func has a return type", not untyped_funcs, str(untyped_funcs))
bare_vars = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", CODE, re.M)
check("no bare 'var x =' declarations", not bare_vars, str(bare_vars))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
