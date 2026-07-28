"""Enforce the architectural directives mechanically.

Rules are only real if they're checked. This fails CI on any violation of the
mandatory rules, so they can't erode as the project grows.

  Rule A  no change_scene_to_file / change_scene_to_packed outside Router
  Rule B  no hardcoded node-path lookups ($../, get_node("../"))
          Bus subscriptions must have a matching disconnect
  Rule C  no silent error swallowing; invariants via Log.must
  Rule D  no hardcoded Color(...) / font sizes / durations / control sizes
  Rule E  no live secrets in source
  Rule F  zero binary assets: the game is 100% procedural
  Rule G  geometry belongs in _layout(), never in _setup()
  Rule H  zero dependency on the archived v1 source
  Rule I  no engine boot logo; splash colour matches the app background
  Layout  files live in the specified folders; filenames are snake_case

Run: python3 tests/check_architecture.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errs: list[str] = []
warns: list[str] = []

# legacy_reference/ was archived to the legacy-v1 branch once v2 was
# feature-complete (see AGENTS.md). It stays in this set so that restoring the
# folder for a v1 investigation does not bury CI in ~188 violations from code
# that is deliberately not being fixed.
EXCLUDED_DIRS = {"legacy_reference", ".godot", "art", "tools"}

GD_FILES = sorted(
    f for f in ROOT.rglob("*.gd")
    if not any(part in EXCLUDED_DIRS for part in f.relative_to(ROOT).parts)
)
REL = lambda p: str(p.relative_to(ROOT))


def strip_comments_and_strings(src: str) -> str:
    """Remove ## docs, # comments, and string literals so we don't match inside them."""
    out = []
    for line in src.split("\n"):
        line = re.sub(r'"[^"]*"', '""', line)
        line = re.sub(r"#.*$", "", line)
        out.append(line)
    return "\n".join(out)


# ── Rule A: Router owns scene switching ──────────────────────────────────
for f in GD_FILES:
    code = strip_comments_and_strings(f.read_text())
    for m in re.finditer(r"change_scene_to_(file|packed)", code):
        if REL(f) != "core/router.gd":
            line = code[: m.start()].count("\n") + 1
            errs.append(f"Rule A  {REL(f)}:{line}  change_scene_to_* outside Router")

# Router itself must not use change_scene either — it swaps children.
router_code = strip_comments_and_strings((ROOT / "core/router.gd").read_text())
if "change_scene_to_" in router_code:
    errs.append("Rule A  core/router.gd uses change_scene_*; it must swap child nodes")


# ── Rule B: no hardcoded node paths; use %UniqueName ─────────────────────
for f in GD_FILES:
    code = strip_comments_and_strings(f.read_text())
    for pat, desc in (
        (r"\$\.\./", "$../ parent traversal"),
        (r'get_node\(\s*"\.\./', 'get_node("../") traversal'),
        (r'get_node\(\s*"/root/', 'get_node("/root/...") absolute path'),
    ):
        for m in re.finditer(pat, code):
            line = code[: m.start()].count("\n") + 1
            errs.append(f"Rule B  {REL(f)}:{line}  {desc}")

    # Any $Node lookup is a hardcoded path. Scene Unique Names (%Node) survive
    # reparenting; $Overlay/Toasts silently breaks the moment the tree changes.
    for m in re.finditer(r"\$[A-Za-z_][\w/]*", code):
        line = code[: m.start()].count("\n") + 1
        errs.append(
            f"Rule B  {REL(f)}:{line}  '{m.group(0)}' hardcoded path; "
            f"use %UniqueName"
        )

# Every %UniqueName referenced must actually be marked unique in a .tscn.
unique_declared: set[str] = set()
for t in ROOT.rglob("*.tscn"):
    if any(part in EXCLUDED_DIRS for part in t.relative_to(ROOT).parts):
        continue
    text = t.read_text()
    for m in re.finditer(r'\[node name="([^"]+)"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true', text):
        unique_declared.add(m.group(1))

for f in GD_FILES:
    code = strip_comments_and_strings(f.read_text())
    for m in re.finditer(r"%([A-Za-z_]\w*)", code):
        if m.group(1) not in unique_declared:
            line = code[: m.start()].count("\n") + 1
            errs.append(
                f"Rule B  {REL(f)}:{line}  %{m.group(1)} is not marked "
                f"unique_name_in_owner in any .tscn"
            )

# Bus subscriptions need a matching disconnect somewhere in the same file.
for f in GD_FILES:
    src = f.read_text()
    if REL(f) == "core/bus.gd":
        continue
    connected = set(re.findall(r"Bus\.(\w+)\.connect\(", src))
    disconnected = set(re.findall(r"Bus\.(\w+)\.disconnect\(", src))
    for sig in connected - disconnected:
        errs.append(
            f"Rule B  {REL(f)}  subscribes to Bus.{sig} but never disconnects "
            f"(add to _exit_tree)"
        )


# ── Rule C: no silent failure ────────────────────────────────────────────
for f in GD_FILES:
    lines = f.read_text().split("\n")
    for i, ln in enumerate(lines, 1):
        s = ln.strip()
        # A bare `return` inside an error branch is the classic v1 silent
        # fallback. Flag `return` under an `== null` / `!= OK` guard with no
        # logging nearby.
        #
        # Returning a *value* (`return null`, `return false`, `return default`)
        # is an intentional query result, not a swallowed error — a function
        # like current_screen() legitimately reports "nothing here".
        if s == "return":
            window = "\n".join(lines[max(0, i - 4) : i])
            # `if not Log.must(x != null, ...):` already logged -- the guard IS
            # the log call. Only flag guards with no logging anywhere near.
            if re.search(r"(==\s*null|!=\s*OK)", window):
                # A guard helper (_operational/_has_material) logs internally,
                # so a call to one IS the log. Treat it as satisfying Rule C.
                logged = re.search(r"Log\.(warn|error|must|info|d)\(", window)
                helper = re.search(r"_(operational|has_material)\(", window)
                if not logged and not helper:
                    warns.append(
                        f"Rule C  {REL(f)}:{i}  early return in an error guard "
                        f"with no Log call"
                    )


# ── Rule D: visual literals must come from Palette ───────────────────────
ALLOWED_COLOR_FILES = {"design/palette.gd"}
for f in GD_FILES:
    if REL(f) in ALLOWED_COLOR_FILES:
        continue
    code = strip_comments_and_strings(f.read_text())
    for m in re.finditer(r"\bColor\s*\(\s*[\d.]", code):
        line = code[: m.start()].count("\n") + 1
        errs.append(f"Rule D  {REL(f)}:{line}  hardcoded Color(); use a Palette token")
    # Raw font sizes
    for m in re.finditer(r'add_theme_font_size_override\(\s*""\s*,\s*(\d+)', code):
        line = code[: m.start()].count("\n") + 1
        errs.append(
            f"Rule D  {REL(f)}:{line}  literal font size {m.group(1)}; "
            f"use Palette.font(Palette.FONT_*)"
        )
    # Raw tween durations
    for m in re.finditer(r"tween_property\([^)]*,\s*(\d*\.\d+)\s*\)", code):
        line = code[: m.start()].count("\n") + 1
        warns.append(
            f"Rule D  {REL(f)}:{line}  literal duration {m.group(1)}; "
            f"prefer Palette.duration(Palette.DURATION_*)"
        )


# ── Rule D2: control sizes must come from Palette ────────────────────────
#
# Rule D already bans literal colours, font sizes and durations. Control
# dimensions were the gap: heights of 48, 52, 56, 64 and a 220px label floor
# were scattered as bare literals across four controllers with nothing tying
# them to MIN_TOUCH_TARGET. A literal cannot be audited — raising the
# accessibility floor would silently leave every one of them behind, and a
# typo'd 46 would pass review.
#
# Only sizes that look like CONTROL dimensions are flagged. Small numbers are
# legitimate arithmetic (halves, ratios, indices), and a value already
# clamped against Palette.MIN_TOUCH_TARGET is by definition compliant.
CONTROL_SIZE_CALL = re.compile(
    r"custom_minimum_size\s*=\s*Vector2\s*\(([^)]*)\)"
)
LITERAL_ARG = re.compile(r"^\s*\d{2,}(?:\.\d+)?\s*$")

for f in GD_FILES:
    if REL(f) == "design/palette.gd":
        continue
    code = strip_comments_and_strings(f.read_text())
    for m in CONTROL_SIZE_CALL.finditer(code):
        args = m.group(1).split(",")
        for arg in args:
            if LITERAL_ARG.match(arg):
                line = code[: m.start()].count("\n") + 1
                errs.append(
                    f"Rule D  {REL(f)}:{line}  literal control size "
                    f"[{arg.strip()}] "
                    f"[use a Palette token: MIN_TOUCH_TARGET, CONTROL_HEIGHT_*]"
                )
                break


# Every named control height must clear the accessibility floor. Naming a
# token is only an improvement if the token itself is correct — a
# CONTROL_HEIGHT_SM of 44 would be a magic number with a respectable name.
_palette_src = (ROOT / "design" / "palette.gd").read_text()
_floor_m = re.search(r"const MIN_TOUCH_TARGET\s*:?=\s*([\d.]+)", _palette_src)
if _floor_m:
    _floor = float(_floor_m.group(1))
    for _m in re.finditer(r"const (CONTROL_HEIGHT_\w+)\s*:?=\s*([\d.]+)", _palette_src):
        _val = float(_m.group(2))
        if _val < _floor:
            errs.append(
                f"Rule D  design/palette.gd  {_m.group(1)} = {_val} is below "
                f"MIN_TOUCH_TARGET ({_floor})"
            )


# ── Rule E: no live secrets ──────────────────────────────────────────────
GOOGLE_TEST_PUB = "3940256099942544"
for f in list(GD_FILES) + list(ROOT.rglob("*.cfg")):
    if "build_config.cfg" == f.name:
        continue
    if any(part in EXCLUDED_DIRS for part in f.relative_to(ROOT).parts):
        continue
    try:
        src = f.read_text()
    except Exception:
        continue
    for m in re.finditer(r"ca-app-pub-(\d{10,})", src):
        if m.group(1) != GOOGLE_TEST_PUB:
            line = src[: m.start()].count("\n") + 1
            errs.append(f"Rule E  {REL(f)}:{line}  live AdMob publisher id in source")
    for m in re.finditer(r"AIza[0-9A-Za-z_\-]{30,}", src):
        line = src[: m.start()].count("\n") + 1
        errs.append(f"Rule E  {REL(f)}:{line}  Google API key in source")


# ── Strict static typing ─────────────────────────────────────────────────
# `var x: int = 0` and `func foo() -> void:`. Untyped GDScript silently boxes
# to Variant, costs performance, and defers real errors to runtime.
for f in GD_FILES:
    for i, ln in enumerate(f.read_text().split("\n"), 1):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue

        m = re.match(r"^(?:static\s+)?func\s+(\w+)\s*\((.*?)\)\s*(->\s*[\w\[\], ]+)?\s*:", s)
        if m:
            if not m.group(3):
                errs.append(
                    f"Typing {REL(f)}:{i}  func {m.group(1)}() has no return type"
                )
            params = m.group(2).strip()
            if params:
                for p in params.split(","):
                    p = p.strip()
                    if p and ":" not in p and not p.startswith("..."):
                        errs.append(
                            f"Typing {REL(f)}:{i}  param '{p}' in "
                            f"{m.group(1)}() is untyped"
                        )

        v = re.match(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+)?var\s+(\w+)\s*(:=|:|=)", s)
        if v and v.group(2) == "=":
            errs.append(
                f"Typing {REL(f)}:{i}  var {v.group(1)} uses bare '='; "
                f"use ':= value' or ': Type = value'"
            )


# ── Routing: every Router.ROUTES target must resolve ─────────────────────
# This class of bug shipped once: five routes pointed at scenes that did not
# exist, including "trial" — the main gameplay path. Nothing caught it because
# the other checks only validated %UniqueName references inside scenes.
router_src = (ROOT / "core/router.gd").read_text()
routes_block = router_src.split("const ROUTES")[1].split("}")[0] if "const ROUTES" in router_src else ""
declared_routes: dict[str, str] = dict(re.findall(r'"(\w+)":\s+"res://([^"]+)"', routes_block))

for route_name, rel_path in declared_routes.items():
    if not (ROOT / rel_path).exists():
        errs.append(f"Routing route '{route_name}' -> res://{rel_path} does not exist")

# Every route referenced in code must be declared in the table.
for f in GD_FILES:
    code = strip_comments_and_strings(f.read_text())
    raw = f.read_text()
    for m in re.finditer(r'Router\.(?:go|replace)\(\s*"(\w+)"', raw):
        if m.group(1) not in declared_routes:
            line = raw[: m.start()].count("\n") + 1
            errs.append(f"Routing {REL(f)}:{line} navigates to undeclared route '{m.group(1)}'")

# ── Test integrity: a check that can skip itself is not a check ──────────
# THE BUG THIS CATCHES: tools/chrono_flow.gd wrapped 15 assertions in
# `if node != null:`. When the scene failed to load, every one of them was
# skipped and the suite reported ALL PASSED — while two deliberately injected
# defects (a spoiler leak into a label, a faked empty state) went undetected.
# A conditional guard around an assertion converts a failure into a silence.
#
# SCOPE WIDENED. This originally globbed only tools/*_flow.gd, which left
# tools/polish_audit.gd — the single largest suite at 340 checks — completely
# unguarded. The omission was not theoretical: the trial-HUD checks added with
# the carved bezels went in with exactly this defect and the rule could not see
# them. Any file that calls _ok() is a test file and gets the same scrutiny.
_TEST_SOURCES = sorted(
    set(ROOT.glob("tools/*_flow.gd")) | set(ROOT.glob("tools/*_audit.gd"))
)
for f in _TEST_SOURCES:
    lines = f.read_text().split("\n")
    for i, ln in enumerate(lines, 1):
        guard = re.match(r"^\s*if\s+(\w+)\s*!=\s*null\s*:\s*$", ln)
        if not guard:
            continue
        indent = len(ln) - len(ln.lstrip("\t"))
        # Look at the guarded block; an _ok() inside it can silently vanish.
        for nxt in lines[i:]:
            if not nxt.strip():
                continue
            depth = len(nxt) - len(nxt.lstrip("\t"))
            if depth <= indent:
                break
            if re.search(r"\b_ok\(", nxt):
                errs.append(
                    f"Test    {REL(f)}:{i}  assertion inside `if {guard.group(1)} "
                    f"!= null:` — a skipped check reports as a pass; assert "
                    f"presence instead"
                )
                break


# ── Rule F: 100% procedural, zero binary assets ──────────────────────────
#
# AGENTS.md rule 9 says no PNGs, textures, audio files or fonts — everything
# is GDShaders, SDF math, _draw() geometry and PCM synthesis. That rule had
# NO mechanical check until now, and the gap bit immediately: ce886d7
# committed eight .import files generated when Godot indexed scratch PNGs
# that tools/raster_preview.py had written into the project root. The images
# themselves were gitignored, so `git status` looked clean while the sidecars
# went in.
#
# .import files are the tell. Godot writes one per imported resource, so an
# unexpected .import is proof a binary asset was placed under res:// even if
# the asset itself never reaches the repo.
BINARY_ASSET_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga",
    ".ttf", ".otf", ".woff", ".woff2",
    ".wav", ".mp3", ".ogg", ".flac", ".m4a",
    ".glb", ".gltf", ".fbx", ".obj",
}

# The single sanctioned exception, and why it is safe: the launcher icon must
# be a real file for the Android manifest, and it is SVG — vector text, not a
# raster asset. Anything else has to justify itself here.
# ── THE HERO EYE EXCEPTION ───────────────────────────────────────────────
# Rule F was written because v1 shipped 69 MB of unoptimised sprites: eight
# static PNGs for the eye alone, tinted per stage, at 9.3 MB. The rule's
# purpose is to prevent THAT — not to forbid a single deliberate hero asset.
#
# Amended by explicit product decision. The procedural shader could not reach
# the reference aesthetic: measured against it, the best procedural result
# hit 10.8% bright pixels and 0.559 saturation against targets of 8.3% and
# 0.726, and the metallic housing, gem facets and volumetric bloom are
# photographic qualities no fragment shader produces. Three attempts
# confirmed it.
#
# The exception is NARROW and audited:
#   * exactly two files, both under art/hero/
#   * a hard 4 MB combined budget, asserted below
#   * the shader still drives everything dynamic — pupil dilation, gaze,
#     shimmer, hover previews — composited over the baked art
#
# Anything outside art/hero/ still fails Rule F.
HERO_ASSET_DIR = "art/hero"
HERO_ASSET_BUDGET_MB = 4.0

# ── The voice pack, derived from the manifest rather than listed ─────────
#
# Reading dialogue_manifest.gd means the allowlist IS the authored script. A
# clip with no line is orphaned and a line with no clip is missing, and both
# are reported below — there is no hand-maintained list to fall out of date.
def _expected_voice_clips() -> set:
    manifest = ROOT / "data" / "dialogue_manifest.gd"
    if not manifest.is_file():
        return set()
    src = manifest.read_text()
    slugs = dict(re.findall(r'const (\w+): StringName = &"(\w+)"', src))
    try:
        body = src[src.index("const LINES"):]
        body = body[: re.search(r"^\}", body, re.M).end()]
    except (ValueError, AttributeError):
        return set()
    out = set()
    for m in re.finditer(r"(\w+):\s*\[(.*?)\n\t\]", body, re.S):
        slug = slugs.get(m.group(1))
        if slug is None:
            continue
        for i in range(len(re.findall(r'"[^"]+"', m.group(2)))):
            out.add(f"audio/dialogue/{slug}_{i + 1:02d}.ogg")
    return out


_VOICE_CLIPS = _expected_voice_clips()

ASSET_ALLOWLIST = {
    # The launcher icon must be a real file for the Android manifest, and it
    # is SVG — vector text, not a raster asset.
    "art/branding/icon.svg",
    # The 512x512 launcher icon. A store listing requires a raster PNG at a
    # fixed size — Google Play will not accept an SVG — so this is the one
    # place a bitmap is unavoidable rather than merely convenient. 434 KB,
    # counted against the same 4 MB budget as the hero art below.
    "art/branding/icon_512.png",
    # Android launcher variants. Google Play requires specific raster sizes:
    # 192x192 legacy, plus a 432x432 adaptive foreground/background pair
    # whose outer third is masked away per launcher shape.
    "art/branding/icon_192.png",
    "art/branding/icon_adaptive_fg.png",
    "art/branding/icon_adaptive_bg.png",
    # ── THE SPLASH CENTERPIECE EXCEPTION ─────────────────────────────────
    # Amended by explicit product decision, and for the same reason the hero
    # eye was: the target aesthetic is PHOTOGRAPHIC — carved pewter, runic
    # engraving, celtic knotwork, volumetric bloom — and a fragment shader
    # does not produce those. That was established on the eye after three
    # measured attempts, and the launcher icon set the bar the splash is now
    # being held to.
    #
    # The procedural marks these replace were honest vector work, but next to
    # the icon they read as flat line art. They are NOT deleted: the aperture,
    # monogram and iris drawings remain in splash_visuals.gd and still render
    # the loading readout, the ambient glow and every animated element.
    #
    # The exception is NARROW and audited:
    #   * exactly two files, both under art/branding/splash/
    #   * counted against the SAME 4 MB budget as everything else
    #   * both must have transparent corners, asserted by the splash suite,
    #     because they composite over a procedural bloom
    #   * tools/bake_splash_art.py is the only sanctioned way to produce them
    "art/branding/splash/sponsor_mark.png",
    "art/branding/splash/title_plate.png",
    # ── THE VOICE PACK EXCEPTION ─────────────────────────────────────────
    # Amended by explicit product decision, reversing the wordless design.
    # The Iris used to hum every line as a formant tone specifically to avoid
    # shipping audio and to sidestep localisation. She now speaks the authored
    # text aloud, which requires one rendered clip per line.
    #
    # This exception is the STRICTEST of the three. It is not a directory
    # allowlist: every clip must be claimed by a line in dialogue_manifest.gd,
    # checked below. An orphaned or stray .ogg fails the build, so the pack
    # cannot quietly accumulate files nothing plays.
    #
    #   * generated only by tools/generate_voice_lines.py, never by hand
    #   * counted against the SAME 4 MB budget as the art
    #   * the generator's --check proves each clip still matches its text
    *_VOICE_CLIPS,
    # A contact sheet of the 23 procedural cosmetics, for humans reading
    # docs/features/. Never loaded at runtime: nothing in .gd or .tscn
    # references it, and docs/* is excluded from every export preset.
    "docs/features/cosmetic_shapes_preview.svg",
}

_asset_scan_dirs = [d for d in ROOT.iterdir()
                    if d.is_dir() and d.name not in {".git", ".godot", "legacy_reference"}]
_asset_roots = _asset_scan_dirs + [ROOT]

_seen_assets: set[str] = set()
for _base in _asset_roots:
    _iter = _base.rglob("*") if _base is not ROOT else ROOT.glob("*")
    for f in _iter:
        if not f.is_file():
            continue
        rel = REL(f)
        if rel in _seen_assets:
            continue
        _seen_assets.add(rel)
        parts = f.relative_to(ROOT).parts
        if any(part in {".git", ".godot", "legacy_reference"} for part in parts):
            continue
        if rel in ASSET_ALLOWLIST:
            continue
        if rel.startswith(HERO_ASSET_DIR + "/"):
            continue
        if f.suffix.lower() in BINARY_ASSET_SUFFIXES:
            errs.append(
                f"Rule F  {rel}  binary asset under res:// "
                f"[the game is 100% procedural; write previews outside the project]"
            )
        if f.suffix == ".import":
            source = rel[: -len(".import")]
            if source.startswith(HERO_ASSET_DIR + "/"):
                continue
            if source not in ASSET_ALLOWLIST:
                errs.append(
                    f"Rule F  {rel}  .import sidecar means Godot indexed a binary "
                    f"asset [{source}]"
                )


# The hero exception is only tolerable while it stays small. A budget that is
# never checked is how 9.3 MB of v1 eye sprites happened in the first place.
# ── The voice pack must match the script exactly ─────────────────────────
#
# Two failure modes, both silent at runtime and both caught here:
#
#   MISSING  a line was added or reworded without regenerating. speak() falls
#            back to the formant hum, so the game does not break — it just
#            quietly stops speaking that line, which is precisely the kind of
#            regression that survives to release.
#   ORPHAN   a line was deleted or reordered and its clip was left behind.
#            Dead bytes against a hard 4 MB budget, and a clip nothing plays.
_voice_dir = ROOT / "audio" / "dialogue"
if _VOICE_CLIPS:
    _on_disk = {f"audio/dialogue/{f.name}"
                for f in _voice_dir.glob("*.ogg")} if _voice_dir.is_dir() else set()
    for _missing in sorted(_VOICE_CLIPS - _on_disk):
        errs.append(
            f"Rule F  {_missing}  authored line has no clip "
            f"[run tools/generate_voice_lines.py]"
        )
    for _orphan in sorted(_on_disk - _VOICE_CLIPS):
        errs.append(
            f"Rule F  {_orphan}  clip is not claimed by any line in "
            f"dialogue_manifest.gd [stale; regenerate]"
        )


_hero_dir = ROOT / HERO_ASSET_DIR
if _hero_dir.is_dir():
    _hero_bytes = sum(f.stat().st_size for f in _hero_dir.rglob("*")
                      if f.is_file() and f.suffix != ".import")
    # The launcher icon counts against the same budget: the point of the cap
    # is total shipped bitmap weight, and exempting a file by location would
    # make the number meaningless.
    _brand = ROOT / "art" / "branding"
    if _brand.is_dir():
        _hero_bytes += sum(f.stat().st_size for f in _brand.rglob("*.png")
                           if f.is_file())
    # The voice pack ships too. Exempting it by file type would make the cap
    # describe "some of the bytes", which is not a budget.
    if _voice_dir.is_dir():
        _hero_bytes += sum(f.stat().st_size for f in _voice_dir.glob("*.ogg")
                           if f.is_file())
    _hero_mb = _hero_bytes / (1024 * 1024)
    if _hero_mb > HERO_ASSET_BUDGET_MB:
        errs.append(
            f"Rule F  {HERO_ASSET_DIR}/  hero assets are {_hero_mb:.2f} MB, "
            f"over the {HERO_ASSET_BUDGET_MB} MB budget"
        )


# ── The adaptive launcher icon must survive Android's mask ───────────────
#
# Android composites an adaptive icon and then masks it to the launcher's own
# shape, guaranteeing only a central circle of 66dp within the 108dp layer —
# 61.1% of the frame's diameter. Emblem pixels outside that circle MAY be
# shaved off, and which ones depends on the device, so it never reproduces on
# the one phone you happen to test.
#
# The bake script asserts this at generation time. Asserting it again here
# catches the case that actually bites: someone drops a hand-made PNG into
# art/branding/ without running tools/bake_icons.py.
_adaptive_fg = ROOT / "art" / "branding" / "icon_adaptive_fg.png"
if _adaptive_fg.is_file():
    try:
        from PIL import Image as _PILImage

        _fg = _PILImage.open(_adaptive_fg).convert("RGBA")
        _w, _h = _fg.size
        if _w != _h:
            errs.append(
                f"Rule F  art/branding/icon_adaptive_fg.png  must be square, "
                f"got {_w}x{_h}"
            )
        else:
            _centre = _w / 2.0
            _safe = _w * 0.611 / 2.0
            _px = _fg.load()
            _outside = 0
            _worst = 0.0
            for _y in range(_h):
                _dy = _y - _centre
                for _x in range(_w):
                    _r, _g, _b, _a = _px[_x, _y]
                    # The badge proper: opaque and brighter than the backdrop.
                    if _a <= 200 or (_r + _g + _b) / 3 <= 40:
                        continue
                    _rad = ((_x - _centre) ** 2 + _dy * _dy) ** 0.5
                    if _rad > _worst:
                        _worst = _rad
                    if _rad > _safe:
                        _outside += 1
            if _outside:
                errs.append(
                    f"Rule F  art/branding/icon_adaptive_fg.png  {_outside} badge "
                    f"pixels fall outside Android's guaranteed-visible circle "
                    f"(extent {_worst:.0f}px > {_safe:.0f}px) — the launcher will "
                    f"clip them [re-run tools/bake_icons.py]"
                )
    except ImportError:
        pass


# ── Rule G: geometry work belongs in _layout(), not _setup() ─────────────
#
# Screen._ready() calls _setup() BEFORE the container pass has sized anything,
# so `size` there is whatever the .tscn declared rather than what the screen
# will occupy. Every controller that measured the rect in _setup() computed
# geometry from a stale value, and the bug always looked the same: an element
# sized for a screen that never existed.
#
# It shipped three times, each diagnosed from scratch:
#   hub_portal      a 508px Iris inside a 452px band, drawn through the hint
#   trial_results   296px buttons on a 360px screen, running off both edges
#   iris_view       _enforce_square() sizing from a rect not yet laid out
#
# Each was patched with a bespoke resized.connect + call_deferred pair. That
# is the fragile loop this rule ends: Screen now provides _layout(), called
# only once the rect is real and again on every resize, and this check makes
# using it mandatory rather than remembered.
GEOMETRY_READS = re.compile(r"\bsize\s*\.\s*[xy]\b|\bsize\s*\*|\bget_rect\s*\(")

for f in GD_FILES:
    src = f.read_text()
    if "extends Screen" not in src and "extends AspectRatioContainer" not in src:
        continue
    if "func _setup" not in src:
        continue
    # Isolate the body of _setup() up to the next top-level func.
    body = src.split("func _setup", 1)[1]
    body = re.split(r"\nfunc ", body, maxsplit=1)[0]
    body = strip_comments_and_strings(body)
    if GEOMETRY_READS.search(body):
        errs.append(
            f"Rule G  {REL(f)}  _setup() measures `size` "
            f"[geometry is not valid until _layout(); see ui/screen.gd]"
        )

# A screen that hand-rolls the lifecycle _layout() already provides is the
# same fragility wearing a different hat.
for f in GD_FILES:
    src = f.read_text()
    if "extends Screen" not in src:
        continue
    stripped = strip_comments_and_strings(src)
    if "resized.connect" in stripped and "func _layout" not in src:
        errs.append(
            f"Rule G  {REL(f)}  connects `resized` by hand "
            f"[override _layout() instead; Screen already wires resize + first frame]"
        )


# ── Rule H: nothing may depend on the archived v1 source ─────────────────
#
# legacy_reference/ was archived to the legacy-v1 branch, and the v1 repo that
# used to sit beside this one is gone. Both were reference material only, but
# "reference only" is a claim until something checks it — and a stale pointer
# is how a rebuild quietly grows a dependency on the thing it replaced.
#
# EXCLUSION IS NOT DEPENDENCY. The checkers still name "legacy_reference" in
# their skip lists so that restoring the folder for an investigation does not
# bury CI in the ~188 violations it carries by design. That is why this rule
# looks for RESOLUTION (loading a path, referencing the sibling repo), not for
# the mere appearance of the word.
V1_REPO_NAMES = ("2SW-Witness", "../witness")

# Anything that would actually reach for the archived tree at runtime.
LEGACY_RESOLVE = re.compile(
    r"(?:preload|load|ResourceLoader\.load|FileAccess\.open|DirAccess\.open)"
    r"\s*\(\s*[\"']([^\"']*legacy_reference[^\"']*)[\"']"
)

for f in GD_FILES:
    src = f.read_text()
    hit = LEGACY_RESOLVE.search(src)
    if hit:
        errs.append(
            f"Rule H  {REL(f)}  loads an archived v1 path [{hit.group(1)}] "
            f"[v2 has no v1 dependency; the source lives on the legacy-v1 branch]"
        )

# Scenes, shaders and project config must not point at it either.
for pattern in ("*.tscn", "*.gdshader", "*.godot"):
    for f in ROOT.rglob(pattern):
        parts = f.relative_to(ROOT).parts
        if any(part in {".git", ".godot", "legacy_reference"} for part in parts):
            continue
        text = f.read_text(errors="ignore")
        if "legacy_reference" in text:
            errs.append(
                f"Rule H  {REL(f)}  references res://legacy_reference/ "
                f"[archived to the legacy-v1 branch]"
            )

# And no file may point at the deleted sibling v1 repo.
_v1_scanned: set[str] = set()
for f in list(GD_FILES) + sorted(ROOT.rglob("*.md")):
    parts = f.relative_to(ROOT).parts
    if any(part in {".git", ".godot", "legacy_reference"} for part in parts):
        continue
    if not f.is_file() or REL(f) in _v1_scanned:
        continue
    _v1_scanned.add(REL(f))
    text = f.read_text(errors="ignore")
    for name in V1_REPO_NAMES:
        if name in text:
            errs.append(
                f"Rule H  {REL(f)}  points at the deleted v1 repo [{name}]"
            )
            break


# ── Rule J: a coroutine must be awaited ──────────────────────────────────
#
# THE BUG THIS CATCHES, WHICH SHIPPED AND TRAPPED A PLAYER:
#
# Router.back() and Router.go() both end in `await _swap(...)`, which makes
# them coroutines. GDScript runs an un-awaited coroutine only as far as its
# FIRST await, then abandons the rest — silently. No error, no warning, no
# log line.
#
# So `Router.back()` written without `await` ran up to the swap, stopped, and
# never navigated. Every on-screen Back button in the app was written that way
# — settings, wardrobe, progress, daily hub, trend hub, consent, chrono card.
# All seven looked correct, were visible, enabled, unobstructed, and did
# absolutely nothing when pressed. Only app.gd's system-back handler awaited
# properly, which is exactly why the Android back gesture worked while the
# button next to it was dead.
#
# A reviewer cannot see this. The call site looks identical either way. So it
# has to be mechanical.
ROUTER_COROUTINES = ("back", "go", "replace")

for f in GD_FILES:
    rel = REL(f)
    # core/router.gd defines them; tools/ are probes that manage their own flow.
    if rel == "core/router.gd" or rel.startswith("tools/"):
        continue
    code = strip_comments_and_strings(f.read_text())
    for m in re.finditer(r"(^|[^.\w])Router\.(\w+)\s*\(", code, re.MULTILINE):
        name = m.group(2)
        if name not in ROUTER_COROUTINES:
            continue
        line_no = code[: m.start()].count("\n") + 1
        line = code.split("\n")[line_no - 1]
        # The await may sit anywhere before the call on the same line:
        #   await Router.go(...)          var ok: bool = await Router.back()
        prefix = line[: line.find("Router.")]
        if "await" in prefix:
            continue
        errs.append(
            f"Rule J  {rel}:{line_no}  Router.{name}() called without await "
            f"[it is a coroutine; an un-awaited call stops at its first await "
            f"and silently never navigates]"
        )


# ── Rule I: the engine must not brand our boot ───────────────────────────
#
# Godot draws its own logo before the first game frame. At the defaults that
# is the Godot mark on a (0.14, 0.14, 0.14) grey, cutting to our
# (0.024, 0.031, 0.055) background — a logo we did not choose plus a grey
# flash, in front of a splash sequence whose whole job is to be the first
# thing the player sees.
#
# We cannot substitute our own image: a boot splash must be a real file, and
# rule 9 / Rule F make this project 100% procedural. So the mark is disabled
# and the splash colour is matched to the app background, which makes the
# pre-engine window indistinguishable from the first frame.
#
# This asserts BEHAVIOUR (the logo is off, the colours agree), not merely
# that the keys are present — a bg_color that drifted from COLOR_BACKGROUND
# would reintroduce the flash while still looking configured.
_proj = (ROOT / "project.godot").read_text()

if not re.search(r"^boot_splash/show_image\s*=\s*false", _proj, re.M):
    errs.append(
        "Rule I  project.godot  boot_splash/show_image must be false "
        "[the engine logo appears before our splash]"
    )

_splash_m = re.search(
    r"^boot_splash/bg_color\s*=\s*Color\(([^)]*)\)", _proj, re.M)
_bg_m = re.search(
    r"const COLOR_BACKGROUND\s*:?=\s*Color\(([^)]*)\)", _palette_src)
if _splash_m is None:
    errs.append(
        "Rule I  project.godot  boot_splash/bg_color is unset "
        "[the default grey flashes before the first frame]"
    )
elif _bg_m is not None:
    def _rgb(raw: str) -> list[float]:
        parts = [p.strip() for p in raw.split(",") if p.strip()]
        return [round(float(p), 4) for p in parts[:3]]

    _splash_rgb = _rgb(_splash_m.group(1))
    _bg_rgb = _rgb(_bg_m.group(1))
    if _splash_rgb != _bg_rgb:
        errs.append(
            f"Rule I  project.godot  boot_splash/bg_color {_splash_rgb} != "
            f"Palette.COLOR_BACKGROUND {_bg_rgb} [visible flash on launch]"
        )


# ── Layout: required folders and snake_case filenames ────────────────────
REQUIRED_DIRS = [
    "app", "core", "data", "design", "systems", "shaders", "nodes",
    "ui", "screens", "art", "tests", "docs/features",
]
for d in REQUIRED_DIRS:
    if not (ROOT / d).is_dir():
        errs.append(f"Layout  missing required directory res://{d}/")

REQUIRED_AUTOLOADS = {
    "Log": "res://core/log.gd",
    "Cfg": "res://core/cfg.gd",
    "Bus": "res://core/bus.gd",
    "Save": "res://core/save.gd",
    "Router": "res://core/router.gd",
    "Palette": "res://design/palette.gd",
}
proj = (ROOT / "project.godot").read_text()
autoload_block = proj.split("[autoload]")[1].split("[")[0] if "[autoload]" in proj else ""
for name, path in REQUIRED_AUTOLOADS.items():
    if not re.search(rf'^{name}="\*?{re.escape(path)}"', autoload_block, re.M):
        errs.append(f"Layout  autoload {name} not registered as {path}")

for f in GD_FILES:
    stem = f.stem
    if stem != stem.lower():
        errs.append(f"Layout  {REL(f)}  filename must be snake_case")

for f in ROOT.rglob("*.tscn"):
    if any(part in EXCLUDED_DIRS for part in f.relative_to(ROOT).parts):
        continue
    if f.stem != f.stem.lower():
        errs.append(f"Layout  {REL(f)}  filename must be snake_case")


# ── Report ───────────────────────────────────────────────────────────────
print(f"checked {len(GD_FILES)} .gd files against architectural directives")
for e in errs:
    print("  VIOLATION ", e)
for w in warns:
    print("  warn      ", w)
print(f"\n{len(errs)} violations, {len(warns)} warnings")
sys.exit(1 if errs else 0)
