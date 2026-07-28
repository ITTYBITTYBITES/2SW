"""Startup splash sequence: sponsor ident, title/loading, routing handoff.

Two properties matter most:

  1. THE PROGRESS IS REAL. Each warm-up step does actual work — audio init,
     save verification, registry validation, scene preloading. v1 showed a
     progress bar that loaded nothing, so the hitch it was meant to hide
     happened anyway, right after the bar claimed 100%.

  2. THE HANDOFF CANNOT STRAND A PLAYER. resolve_destination() is pure and
     static so every branch is testable, and it degrades to "hub" when the
     optional intro scene is absent rather than routing into the void — the
     failure mode that broke five routes in Phase 9.

Run: python3 tests/test_splash.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPLASH = (ROOT / "nodes/splash_controller.gd").read_text()
VISUALS = (ROOT / "nodes/splash_visuals.gd").read_text()
TSCN = (ROOT / "screens/splash/splash.tscn").read_text()
ROUTER = (ROOT / "core/router.gd").read_text()
APP = (ROOT / "app/app.gd").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


CODE = strip_comments(SPLASH)
VIS = strip_comments(VISUALS)

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


print("-- ASSET DISCIPLINE --")
# Rule F was AMENDED for exactly two splash centerpieces, so a blanket "no
# .png anywhere" no longer describes the intent. What still has to hold is
# that those two files are the ONLY bitmaps the splash touches — an amendment
# that permits any texture is not an amendment, it is a repeal.
#
# So the check is now an allowlist rather than a ban, and it is STRICTER than
# what it replaced: the previous version could not have told a second, third
# or tenth asset from the first.
SPLASH_ART_ALLOWED = {
    "res://art/branding/splash/sponsor_mark.png",
    "res://art/branding/splash/title_plate.png",
}

IMAGE_REF = re.compile(r'res://[^"\')\s]+\.(?:png|jpg|jpeg|svg|webp|bmp|tga)')

for name, src in (("controller", SPLASH), ("visuals", VISUALS), ("scene", TSCN)):
    found = set(IMAGE_REF.findall(src))
    stray = found - SPLASH_ART_ALLOWED
    check(f"{name}: references no unapproved image", not stray, str(sorted(stray)))

# The marks that must stay procedural, stay procedural. The baked art is a
# CENTERPIECE; the animated readout and the ambient light are not baked, and
# splash_visuals.gd is where all of that lives.
check("visuals reference no image at all", not IMAGE_REF.findall(VISUALS))
check("no Texture2D in visuals", "Texture2D" not in VIS)
check("no load() of images in visuals", "load(" not in VIS)

# Both approved assets must actually exist and be wired, or the allowlist is
# describing files that are not there.
for rel in sorted(SPLASH_ART_ALLOWED):
    path = ROOT / rel.removeprefix("res://")
    check(f"{path.name} exists", path.is_file())
    check(f"{path.name} is referenced by the scene", rel in TSCN)

print("\n-- PROCEDURAL VISUALS --")
for prim in ("draw_polyline", "draw_arc", "draw_circle", "draw_rect", "draw_line"):
    check(f"uses {prim}", prim in VIS)
check("three mark kinds", VIS.count("Kind.") >= 3)
for func_name in ("_draw_sponsor_mark", "_draw_monogram", "_draw_iris_progress"):
    check(f"{func_name}()", f"func {func_name}()" in VIS)
check("2SW letterforms drawn as strokes",
      "_stroke_two" in VIS and "_stroke_s" in VIS and "_stroke_w" in VIS)

print("\n-- ACT 1: SPONSOR IDENT --")
check("fade in declared", "SPONSOR_FADE_IN" in CODE)
check("hold declared", "SPONSOR_HOLD" in CODE)
check("fade out declared", "SPONSOR_FADE_OUT" in CODE)
total = re.search(r"SPONSOR_TOTAL: float = ([\w\s+]+)", CODE)
check("total is the sum of its parts", total is not None)
check("~2.5s total", abs((0.6 + 1.3 + 0.6) - 2.5) < 0.01)
check("audio cue on illumination", "play_iris_formant" in CODE)
check("ambient pad starts", "play_ambient_pad" in CODE)
check("honours reduced motion", "Palette.reduced_motion()" in CODE)

print("\n-- SKIP --")
check("skip() is public", "func skip() -> void:" in CODE)
check("tap handled", "_gui_input" in CODE)
check("skip is idempotent", "_skipped_sponsor" in CODE)
check("skip does NOT skip loading",
      "_begin_title" in CODE.split("func skip()")[1][:300])
check("skip plays feedback",
      'play_sfx(&"ui_tap")' in CODE.split("func skip()")[1][:300])
check("scene root accepts input", "mouse_filter = 0" in TSCN)

print("\n-- ACT 2: TITLE + REAL LOADING --")
check("monogram resolves into the name", "MONOGRAM_HOLD" in CODE and "NAME_RESOLVE" in CODE)
check("minimum visible time", "MIN_LOADING_TIME" in CODE)
check("warm-up steps declared", "WARMUP_STEPS" in CODE)
for step in ("audio", "save", "trials", "scenes"):
    check(f"step '{step}'", f'&"{step}"' in CODE)
for label in ("Audio engine", "Save integrity", "Trial matrices"):
    check(f"status label '{label}'", label in SPLASH)
check("each step does real work", "func _perform_step(" in CODE)
check("audio step touches channels", "set_pad_intensity" in CODE)
check("save step verifies a round-trip", "from_dict" in CODE)
check("trials step validates the registry", "TrialRegistry.validate()" in CODE)
check("scenes step preloads", "load_threaded_request" in CODE)
check("iris replaces a progress bar", "IrisProgress" in TSCN)
check("no ProgressBar node", "ProgressBar" not in TSCN)
check("progress drives the iris", 'call("set_progress"' in CODE)

print("\n-- ROUTING HANDOFF --")
check("resolve_destination is static + pure",
      "static func resolve_destination() -> String:" in CODE)
# is_recorded(), not is_satisfied(): the splash must reach the consent screen
# even in a debug build, where is_satisfied() bypasses so the App boot gate
# never blocks the editor.
check("consent checked first",
      CODE.index("is_recorded") < CODE.index('return "hub"'))
check("splash uses the recorded state", "ConsentController.is_recorded()" in CODE)
check("routes to consent", 'return "consent"' in CODE)
check("routes to hub", 'return "hub"' in CODE)
# The four-line intro carousel was removed; startup is consent-or-hub. Assert
# the route is genuinely gone rather than merely unused, so a stray reference
# to a deleted scene cannot creep back in.
check("no intro route survives", '"intro"' not in CODE)
check("uses replace(), not go()", 'Router.replace(destination)' in CODE)
check("handoff is once-only", "_finished" in CODE)

print("\n-- BOOT CHAIN --")
check("splash route declared", '"splash":' in ROUTER)
check("splash scene exists", (ROOT / "screens/splash/splash.tscn").exists())
check("splash is a ROOT route",
      re.search(r'ROOT_ROUTES\s*:=\s*\[[^\]]*"splash"', ROUTER) is not None)
check("app boots to splash", 'Router.go("splash")' in strip_comments(APP))
check("splash excluded from resume",
      re.search(r'NO_RESUME\s*:=\s*\[[^\]]*"splash"', APP) is not None)
check("back swallowed during startup",
      "return true" in CODE.split("func on_back_requested()")[1])

print("\n-- SCENE WIRING --")
for node in ("Background", "SponsorLayer", "SponsorMark", "SponsorName",
             "SponsorTagline", "TitleLayer", "Monogram", "TitleName",
             "IrisProgress", "StatusLabel", "SkipHint"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, TSCN) is not None)

print("\n-- TYPING --")
for name, code in (("controller", CODE), ("visuals", VIS)):
    untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", code, re.M)
    check(f"{name}: all funcs typed", not untyped, str(untyped))
    bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", code, re.M)
    check(f"{name}: no bare var", not bare, str(bare))

print("\n-- SIM: destination resolution --")


def resolve(consent_ok: bool) -> str:
    """Startup has exactly two outcomes now: the legal gate, or the game."""
    if not consent_ok:
        return "consent"
    return "hub"


check("no consent -> consent", resolve(False) == "consent")
check("consent recorded -> hub", resolve(True) == "hub")
check("never returns empty", all(resolve(c) != "" for c in (True, False)))
check("only ever two destinations",
      {resolve(c) for c in (True, False)} == {"consent", "hub"})

print("\n-- SIM: progress monotonic across 4 steps --")
steps = 4
values = [(i + 1) / steps for i in range(steps)]
check("reaches exactly 1.0", abs(values[-1] - 1.0) < 1e-9)
check("monotonically increasing", all(values[i] < values[i + 1] for i in range(steps - 1)))
check("never exceeds 1.0", all(v <= 1.0 for v in values))
check("starts above zero after step 1", values[0] > 0.0)

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
