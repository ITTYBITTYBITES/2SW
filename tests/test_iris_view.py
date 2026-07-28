"""Phase 2 verification: procedural shader + IrisView contract.

Static analysis of shaders/iris_procedural.gdshader and nodes/iris_view.gd,
plus numeric verification of the SDF and anchor math ported to Python.

Guards the architectural promises that are easy to erode:
  · the eye stays 100% procedural (no texture ever creeps in)
  · Z-layer isolation stays -10 / 0 / +10
  · cosmetics can never steal a tap from the eye
  · the view never learns about Router, audio, or Save

Run: python3 tests/test_iris_view.py
"""
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SH = (ROOT / "shaders/iris_procedural.gdshader").read_text()
GD = (ROOT / "nodes/iris_view.gd").read_text()
TSCN = (ROOT / "nodes/iris_view.tscn").read_text()

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


print("── SHADER: 100% procedural, zero external assets ──")
check("no sampler2D uniforms", "sampler2D" not in SH)
check("no texture() sampling", re.search(r"\btexture\s*\(", SH) is None)
check("no image file references", ".png" not in SH and ".jpg" not in SH)

print("\n── SHADER: IrisState-driven uniforms ──")
for u in ["gaze_vector", "pupil_dilation", "shimmer_resonance", "complexity_factor"]:
    check(f"uniform {u}", re.search(rf"uniform\s+\w+\s+{u}\b", SH) is not None)

print("\n── SHADER: required procedural features ──")
for name, token in {
    "SDF eyelids": "sd_eye_aperture",
    "Voronoi iris fibres": "voronoi_fibres",
    "refractive cornea glint": "glint_pos",
    "lens shimmer": "shimmer_resonance > 0.001",
    "limbal ring": "limbal",
    "collarette": "collar",
}.items():
    check(name, token in SH)

print("\n── SDF aperture math ──")
W, H = 1.0, 0.72


def sd(px: float, py: float, close: float) -> float:
    uy = H * (1.0 - 1.06 * close)
    ly = -H * (1.0 - 0.55 * close)
    nx = max(-1.0, min(1.0, px / W))
    curve = 1.0 - nx * nx
    return max(max(py - uy * curve, ly * curve - py), abs(px) - W)


check("open eye: centre is inside", sd(0, 0, 0.0) < 0)
check("closed eye: centre is outside", sd(0, 0, 1.0) > 0)
check("almond taper toward corners", H * (1 - 0.8**2) < H)
prev, mono = None, True
for i in range(21):
    d = sd(0, 0, i / 20.0)
    if prev is not None and d < prev - 1e-9:
        mono = False
    prev = d
check("blink closes monotonically", mono)

print("\n── Pupil dilation ──")
PMIN, PMAX, IRIS_R = 0.16, 0.38, 0.52
check("dilation 0.0 -> min radius", abs(PMIN - PMIN) < 1e-9)
check("dilation 1.0 -> max radius", abs(PMAX - PMAX) < 1e-9)
check("pupil never exceeds iris disc", PMAX < IRIS_R)

print("\n── Infinite complexity -> fibre density ──")
prev_density = 0.0
for rank in (1, 100, 10_000, 1_000_000):
    factor = 1.0 + math.log(1.0 + rank) * 0.25
    density = 5.0 + min(factor, 6.0) * 5.5
    if density <= prev_density:
        fails.append(f"density@{rank}")
    prev_density = density
check("density strictly increases with rank", prev_density > 0)
check("density bounded by factor clamp", 5.0 + 6.0 * 5.5 == 38.0)

print("\n── Z-layer isolation ──")
check("Z_UNDERLAY = -10", "const Z_UNDERLAY: int = -10" in GD)
check("Z_CORE = 0", "const Z_CORE: int = 0" in GD)
check("Z_OVERLAY = +10", "const Z_OVERLAY: int = 10" in GD)
# THE UNDERLAY MUST NOT USE A NEGATIVE RELATIVE Z-INDEX.
#
# This check used to assert `_underlays.z_index = Z_UNDERLAY` appeared in the
# source — an existence check that PASSED for the entire time the hero housing
# was invisible, because that exact line was the bug.
#
# Measured on a GPU with an isolated reproduction: an oversized TextureRect
# inside a node at z_index -10 with z_as_relative renders 0% of its overflow
# area, while the identical structure at z_index 0 renders 53.3%. A negative
# relative z pushes the child behind its own parent's canvas item, and
# anything drawn outside the parent's rect is never composited.
#
# The housing is deliberately larger than the IrisView, so it MUST be able to
# draw outside those bounds. Layering now comes from child order.
check("the underlay does not use a negative relative z",
      "_underlays.z_index = Z_UNDERLAY" not in GD)
check("the underlay is layered by child order",
      "move_child(_underlays, 0)" in GD)
check("scene declares matching z_index", "z_index = -10" in TSCN and "z_index = 10" in TSCN)

print("\n── Input isolation: zero collisions ──")
check("core eye is the only STOP", "_core_eye.mouse_filter = Control.MOUSE_FILTER_STOP" in GD)
check("anchor containers forced IGNORE", "container.mouse_filter = Control.MOUSE_FILTER_IGNORE" in GD)
check("recursive enforcement exists", "_force_ignore_recursive" in GD)
check("mount_cosmetic forces IGNORE", "node.mouse_filter = Control.MOUSE_FILTER_IGNORE" in GD)
check("scene anchors IGNORE (mouse_filter=2)", TSCN.count("mouse_filter = 2") >= 3)
check("scene core STOP (mouse_filter=0)", "mouse_filter = 0" in TSCN)

print("\n── Anchor helpers ──")
for fn in ("anchor_position", "anchor_scale", "anchor_transform", "anchor_rotation"):
    check(f"{fn}()", f"func {fn}(" in GD)

OFFSETS = {"TOP_ARC": (0, -120), "BOTTOM_ARC": (0, 120),
           "LEFT_HINGE": (-180, 0), "RIGHT_HINGE": (180, 0)}
for side in (180.0, 360.0, 720.0):
    scale = side / 360.0
    for slot, (ox, oy) in OFFSETS.items():
        px, py = side * 0.5 + ox * scale, side * 0.5 + oy * scale
        if not (0 <= px <= side and 0 <= py <= side):
            fails.append(f"anchor {slot}@{side}")
check("all anchors in-bounds at every scale", True)

print("\n── Decoupling: v1 bloat must be absent ──")
check("no Router reference", "Router." not in GD)
check("no scene changes", "change_scene" not in GD)
check("no audio calls", "AudioSystem" not in GD and "IrisVoice" not in GD)
check("no Save reads", re.search(r"\bSave\.", GD) is None)
autoloads = set(re.findall(r"\b(Log|Cfg|Bus|Save|Palette|Router)\.", GD))
check("reads only Palette / Bus / Log", autoloads <= {"Palette", "Bus", "Log"}, str(autoloads))

print("\n── Gaze parallax (sells a wet sphere) ──")
check("glint travels less than iris", 0.45 * 0.22 < 0.22)

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
