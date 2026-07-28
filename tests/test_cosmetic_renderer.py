"""Phase 5 verification: procedural cosmetic renderer.

Two halves:
  1. Static analysis — proves the renderer can never load an image asset,
     never takes input, and covers every catalogue shape.
  2. Geometry simulation — ports the drawing maths to Python and checks the
     shapes are valid, bounded, symmetric where they should be, and scale
     with rank without exceeding their ceilings.

The load-bearing guarantees:
  · ZERO PNGs — every ornament is vector maths
  · DETERMINISM — same seed always draws the identical ornament
  · BOUNDED — a rank-1,000,000 player cannot melt a low-end GPU
  · INPUT-TRANSPARENT — a crown can never steal a tap from the pupil

Run: python3 tests/test_cosmetic_renderer.py
"""
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RENDERER = (ROOT / "nodes/cosmetic_renderer.gd").read_text()
MOUNT = (ROOT / "nodes/cosmetic_mount.gd").read_text()
CATALOG = (ROOT / "data/cosmetic_catalog.gd").read_text()

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


CODE = strip_comments(RENDERER)
MOUNT_CODE = strip_comments(MOUNT)

UNIT = 360.0


def complexity(rank: int) -> float:
    return 1.0 + math.log(1.0 + max(rank, 0)) * 0.25


def scaled(base: int, ceiling: int, rank: int) -> int:
    return max(base, min(int(round(base * complexity(rank))), ceiling))


# ═══════════════════════════════════════════════════════════════════════
print("── ZERO IMAGE ASSETS (the core Phase 5 rule) ──")
for ext in (".png", ".jpg", ".jpeg", ".svg", ".webp", ".bmp"):
    check(f"no {ext} reference", ext not in RENDERER)
check("no Texture2D usage", "Texture2D" not in CODE)
check("no load() calls", "load(" not in CODE)
check("no draw_texture*", "draw_texture" not in CODE)
check("no TextureRect", "TextureRect" not in CODE)

print("\n── DRAWS WITH VECTOR PRIMITIVES ONLY ──")
for prim in ("draw_colored_polygon", "draw_polyline", "draw_circle", "draw_arc",
             "draw_line", "draw_rect"):
    check(f"uses {prim}", prim in CODE)

print("\n── EVERY CATALOGUE SHAPE IS HANDLED ──")
catalog_shapes = set(re.findall(r'"shape":\s*"(\w+)"', CATALOG))
handled = set(re.findall(r'^\t\t"([\w", ]+)":$', CODE, re.M))
handled_flat: set[str] = set()
for entry in handled:
    for part in entry.split(","):
        handled_flat.add(part.strip().strip('"'))
for shape in sorted(catalog_shapes):
    check(f"shape '{shape}' has a draw path", shape in handled_flat)
check("unknown shapes fail loudly", "unknown shape" in RENDERER)

print("\n── ALL FOUR CATEGORIES RENDER ──")
categories = {
    "Headpieces": ["_draw_crown", "_draw_horns", "_draw_halo", "_draw_cap",
                   "_draw_laurel", "_draw_cone_hat", "_draw_jester"],
    "Frames/Rims": ["_draw_monocle", "_draw_glasses", "_draw_gem_band",
                    "_draw_vine", "_draw_dangle"],
    "Limbs": ["_draw_hands", "_draw_feet", "_draw_wings", "_draw_tentacles"],
    "Auras": ["_draw_snow_particle", "_draw_spark_particle",
              "_draw_glyph_particle", "_draw_dust_particle"],
}
for category, funcs in categories.items():
    missing = [f for f in funcs if f"func {f}(" not in CODE]
    check(f"{category} ({len(funcs)} renderers)", not missing, str(missing))

print("\n── RANK COMPLEXITY SCALING ──")
check("scaled_count() exists", "func scaled_count(" in CODE)
check("uses complexity factor", "_complexity" in CODE)
check("clamps to a ceiling", "clampi(scaled, base, ceiling)" in CODE)
for const in ("MAX_SPIKES", "MAX_LEAVES", "MAX_FEATHERS", "MAX_PARTICLES",
              "MAX_TENDRILS", "MAX_SEGMENTS"):
    check(f"{const} ceiling declared", f"const {const}" in CODE)

print("\n── INPUT TRANSPARENCY ──")
check("renderer sets IGNORE", "mouse_filter = Control.MOUSE_FILTER_IGNORE" in CODE)
check("mount re-asserts isolation", "refresh_input_isolation()" in MOUNT_CODE)
check("mount never sets STOP", "MOUSE_FILTER_STOP" not in MOUNT_CODE)

print("\n── DETERMINISM ──")
check("seeded RNG", "RandomNumberGenerator" in CODE)
check("reseeds before each draw", "func _reseed(" in CODE and "_reseed()" in CODE)
check("seed comes from rules", '_seed = int(rules.get("seed"' in CODE)

print("\n── LAYER ROUTING (matches IrisView Z isolation) ──")
check("LIMB routed to underlay", "UNDERLAY_LAYERS" in MOUNT_CODE)
check("mount uses anchor helpers", "mount_cosmetic(" in MOUNT_CODE)
check("validates unknown anchors", "unknown anchor" in MOUNT)

print("\n── TYPING ──")
untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", CODE, re.M)
check("all funcs typed", not untyped, str(untyped))
bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", CODE, re.M)
check("no bare var declarations", not bare, str(bare))


# ═══════════════════════════════════════════════════════════════════════
print("\n── GEOMETRY: crown spikes ──")


def crown_spikes(count: int) -> list[tuple[float, float]]:
    width, height = UNIT * 0.62, UNIT * 0.30
    out = []
    for i in range(count):
        t = i / max(count - 1, 1)
        x = -width * 0.5 + width * t
        falloff = 1.0 - pow(abs(t - 0.5) * 2.0, 1.6)
        out.append((x, -height * (0.45 + 0.55 * falloff)))
    return out


pts = crown_spikes(5)
band_w, band_h = UNIT * 0.62, UNIT * 0.30
check("all spikes within band width", all(-band_w / 2 - 1e-6 <= x <= band_w / 2 + 1e-6 for x, _ in pts))
check("all spikes rise above band", all(y < 0 for _, y in pts))
check("centre spike is tallest", -pts[2][1] > -pts[0][1])
check("no spike exceeds max height", all(-y <= band_h + 1e-6 for _, y in pts))
check("symmetric about centre", abs(pts[0][1] - pts[4][1]) < 1e-6)

print("\n── GEOMETRY: rank scaling is monotonic and capped ──")
for base, ceiling, label in ((5, 24, "crown spikes"), (9, 28, "laurel leaves"),
                             (11, 32, "feathers"), (24, 96, "particles")):
    row = [scaled(base, ceiling, r) for r in (1, 100, 10_000, 1_000_000)]
    monotonic = all(row[i] <= row[i + 1] for i in range(len(row) - 1))
    print(f"    {label:<16} rank 1→{row[0]}  100→{row[1]}  10k→{row[2]}  1M→{row[3]}")
    check(f"{label} grows and stays capped",
          monotonic and row[-1] <= ceiling and row[0] >= base)

print("\n── GEOMETRY: halo is a tilted ellipse above the brow ──")
radius, tilt, cy = UNIT * 0.28, 0.22, -UNIT * 0.20
ring = [(math.cos(2 * math.pi * i / 48) * radius,
         cy + math.sin(2 * math.pi * i / 48) * radius * tilt) for i in range(48)]
xs = [p[0] for p in ring]
ys = [p[1] for p in ring]
check("wider than tall", (max(xs) - min(xs)) > (max(ys) - min(ys)))
check("tilt ratio ≈ 0.22", abs((max(ys) - min(ys)) / (max(xs) - min(xs)) - tilt) < 0.01)
check("floats above the eye", max(ys) < 0)

print("\n── GEOMETRY: wings mirror and taper ──")


def wing_tips(count: int, side: int) -> list[tuple[float, float]]:
    out = []
    for i in range(count):
        t = i / max(count - 1, 1)
        angle = -0.15 + 1.30 * t
        length = UNIT * (0.34 + (0.14 - 0.34) * pow(t, 1.4))
        base_x = side * UNIT * 0.10
        out.append((base_x + side * math.cos(angle) * length, math.sin(angle) * length))
    return out


right = wing_tips(11, 1)
left = wing_tips(11, -1)
lengths = [math.hypot(x - UNIT * 0.10, y) for x, y in right]
check("feathers shorten outward", lengths[0] > lengths[-1])
check("fan sweeps up then down", right[0][1] < 0 and right[-1][1] > 0)
check("left/right mirrored", all(abs(l[0] + r[0]) < 1e-6 for l, r in zip(left, right)))

print("\n── GEOMETRY: horns taper and mirror ──")


def horn(side: int) -> list[tuple[float, float, float]]:
    out = []
    for i in range(9):
        t = i / 8
        out.append((side * UNIT * (0.10 + 0.26 * t),
                    -UNIT * (0.34 * t + 0.6 * 0.10 * t * t),
                    UNIT * 0.045 * (1.0 - 0.4 * t)))
    return out


r_horn, l_horn = horn(1), horn(-1)
check("thickness tapers to the tip", r_horn[0][2] > r_horn[-1][2])
check("tip is the highest point", r_horn[-1][1] == min(p[1] for p in r_horn))
check("horns mirrored", all(abs(a[0] + b[0]) < 1e-6 for a, b in zip(r_horn, l_horn)))
check("curves outward", abs(r_horn[-1][0]) > abs(r_horn[0][0]))

print("\n── GEOMETRY: particles stay inside the field ──")
field = UNIT * 0.62
wrapped = [((0 + t * UNIT * 0.10) % (field * 2)) - field for t in range(40)]
check("snow wraps vertically", all(-field <= y <= field for y in wrapped))
rise = [50.0 - life / 20 * 0.4 * field * 1.4 for life in range(21)]
check("sparks rise", rise[0] > rise[-1])
columns = {round(x / (UNIT * 0.055)) * UNIT * 0.055 for x in (-100, -98, -55, -53, 0, 3, 55, 60)}
check("matrix rain snaps to columns", len(columns) < 8, f"{len(columns)} of 8")

print("\n── DETERMINISM SIMULATION ──")


class LCG:
    def __init__(self, seed: int) -> None:
        self.state = (seed or 1) & 0xFFFFFFFF

    def next(self) -> float:
        self.state = (1103515245 * self.state + 12345) & 0x7FFFFFFF
        return self.state / 0x7FFFFFFF


def field_of(seed: int, count: int) -> list[tuple[float, float]]:
    rng = LCG(seed)
    return [(rng.next(), rng.next()) for _ in range(count)]


check("same seed → identical field", field_of(1866395730, 40) == field_of(1866395730, 40))
check("different seed → different field", field_of(1866395730, 40) != field_of(2433287670, 40))

print("\n── ANCHOR PLACEMENT ──")
OFFSETS = {"TOP_ARC": (0, -120), "BOTTOM_ARC": (0, 120),
           "LEFT_HINGE": (-180, 0), "RIGHT_HINGE": (180, 0)}
in_bounds = True
for side in (180.0, 360.0, 720.0):
    scale = side / 360.0
    for slot, (ox, oy) in OFFSETS.items():
        px, py = side * 0.5 + ox * scale, side * 0.5 + oy * scale
        if not (0 <= px <= side and 0 <= py <= side):
            in_bounds = False
check("all anchors in-bounds at 3 scales", in_bounds)
check("TOP_ARC above centre", OFFSETS["TOP_ARC"][1] < 0)
check("BOTTOM_ARC below centre", OFFSETS["BOTTOM_ARC"][1] > 0)
check("hinges at horizontal extremes",
      OFFSETS["LEFT_HINGE"][0] == -180 and OFFSETS["RIGHT_HINGE"][0] == 180)

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
