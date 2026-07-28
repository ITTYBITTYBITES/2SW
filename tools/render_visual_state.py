#!/usr/bin/env python3
"""Render the trial HUD and splash from LIVE measured state.

WHY THIS EXISTS
---------------
The sandbox has no display server, so Godot cannot open a window and no
screenshot can be taken here. The only honest substitute is to port the same
_draw() maths to Python and feed it geometry measured from the RUNNING tree.

THE RULE THIS FILE FOLLOWS: every number that describes WHERE something is or
HOW FAR a gauge has swept comes from tools/dump_visual_state.gd. Nothing is
positioned by eye and nothing is invented to make the picture look finished.
Two earlier previews in this project broke that rule — a "splash snapshot" that
showed a screen which did not exist, and an atmosphere render that drew the
motes flat when the real ones pulse with a halo. Both overstated the build.

GLOW IS DRAWN TO A SEPARATE LAYER AND BLURRED. Stacking opaque arcs to fake a
bloom is what produced the solid cyan disc in the earlier splash preview.
"""
from __future__ import annotations

import json
import math
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ── Palette tokens, mirrored from design/palette.gd ──────────────────────
BACKGROUND = (6, 8, 14)
BEZEL_PLATE = (9, 12, 18)
BEZEL_GROOVE = (3, 5, 8)
BEZEL_METAL = (71, 62, 46)
TEXT = (209, 219, 240)
TEXT_DIM = (150, 160, 180)
TEXT_FAINT = (120, 130, 150)
ACCENT = (42, 183, 200)
DANGER = (242, 102, 107)
PUPIL = (4, 5, 9)

BEZEL_ARC_FRAC = 0.075
BEZEL_TRACK_ALPHA = 0.14
BEZEL_ARC_ALPHA = 0.92
BEZEL_RIM_FRAC = 0.055
BEZEL_GROOVE_FRAC = 0.030

FEEDBACK_PULSE_REACH = 0.62
FEEDBACK_PULSE_RINGS = 3
FEEDBACK_PULSE_ALPHA = 0.44
FEEDBACK_ABRASION_SPREAD = 0.016
FEEDBACK_ABRASION_ALPHA = 0.30
FEEDBACK_ABRASION_BANDS = 7
FEEDBACK_ABRASION_REACH = 0.22
FEEDBACK_ABRASION_LINE = 0.004
FEEDBACK_ABRASION_LENGTH = 0.34

SPLASH_HALO_RINGS = 26
SPLASH_HALO_ALPHA = 0.018

SCALE = 0.5  # 1080x1920 -> 540x960, so the deliverable fits on screen


def _font(px: int) -> ImageFont.ImageFont:
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if pathlib.Path(path).exists():
            try:
                return ImageFont.truetype(path, px)
            except OSError:
                pass
    return ImageFont.load_default()


def S(v: float) -> float:
    return v * SCALE


# ═════════════════════════════════════════════════════════════════════════
# BEZEL — a CPU port of ui/hud_bezel.gd _draw()
# ═════════════════════════════════════════════════════════════════════════
def draw_bezel(base: Image.Image, glow: Image.Image, rect, fill: float) -> None:
    """rect = (x, y, w, h) in scaled pixels; fill = the live arc value."""
    x, y, w, h = rect
    d = ImageDraw.Draw(base, "RGBA")
    g = ImageDraw.Draw(glow, "RGBA")
    unit = min(w, h)

    # Plate + machined groove.
    d.rectangle([x, y, x + w, y + h], fill=BEZEL_PLATE)
    groove = unit * BEZEL_GROOVE_FRAC
    d.rectangle([x + groove, y + groove, x + w - groove, y + h - groove],
                outline=BEZEL_GROOVE, width=max(int(groove * 0.5), 1))

    # Chamfered corner nicks.
    nick = 10 * SCALE * 0.7
    metal = BEZEL_METAL + (140,)
    for a, b in (
        ((x, y + nick), (x + nick, y)),
        ((x + w - nick, y), (x + w, y + nick)),
        ((x + w, y + h - nick), (x + w - nick, y + h)),
        ((x + nick, y + h), (x, y + h - nick)),
    ):
        d.line([a, b], fill=metal, width=max(int(unit * 0.02), 1))

    # Lit top edge, shadowed bottom.
    rim = max(unit * BEZEL_RIM_FRAC, 1.0)
    d.line([(x, y), (x + w, y)], fill=BEZEL_METAL + (158,), width=max(int(rim), 1))
    d.line([(x, y + h), (x + w, y + h)], fill=(3, 4, 8, 200), width=max(int(rim), 1))
    d.line([(x, y + rim), (x + w, y + rim)], fill=ACCENT + (56,),
           width=max(int(rim * 0.4), 1))

    # ── The cyan arc: a stadium track with a filled sweep ────────────────
    thickness = max(unit * BEZEL_ARC_FRAC, 2.0)
    pad = thickness * 1.2
    radius = max(h * 0.5 - pad, thickness)
    cy = y + h * 0.5
    lx = x + pad + radius
    rx = x + w - pad - radius

    def capsule(target, x0, x1, colour, tw):
        if x1 <= x0:
            target.arc([x0 - radius, cy - radius, x0 + radius, cy + radius],
                       90, 270, fill=colour, width=max(int(tw), 1))
            return
        target.line([(x0, cy - radius), (x1, cy - radius)], fill=colour,
                    width=max(int(tw), 1))
        target.line([(x0, cy + radius), (x1, cy + radius)], fill=colour,
                    width=max(int(tw), 1))
        target.arc([x0 - radius, cy - radius, x0 + radius, cy + radius],
                   90, 270, fill=colour, width=max(int(tw), 1))
        target.arc([x1 - radius, cy - radius, x1 + radius, cy + radius],
                   270, 90, fill=colour, width=max(int(tw), 1))

    capsule(d, lx, rx, ACCENT + (int(255 * BEZEL_TRACK_ALPHA),), thickness)

    if fill > 0.001:
        tip = lx + (rx - lx) * fill
        # Glow goes to the blurred layer, never stacked opaquely on the plate.
        capsule(g, lx, tip, ACCENT + (90,), thickness * 2.2)
        capsule(d, lx, tip, ACCENT + (int(255 * BEZEL_ARC_ALPHA),), thickness)
        r = thickness * 0.7
        for yy in (cy - radius, cy + radius):
            d.ellipse([tip - r, yy - r, tip + r, yy + r], fill=ACCENT + (235,))
            g.ellipse([tip - r * 3, yy - r * 3, tip + r * 3, yy + r * 3],
                      fill=ACCENT + (70,))


# ═════════════════════════════════════════════════════════════════════════
# FEEDBACK — a CPU port of ui/trial_feedback.gd _draw()
# ═════════════════════════════════════════════════════════════════════════
def draw_pulse(glow: Image.Image, field, origin, phase: float) -> None:
    fx, fy, fw, fh = field
    ox, oy = origin
    g = ImageDraw.Draw(glow, "RGBA")
    unit = min(fw, fh)
    reach = unit * FEEDBACK_PULSE_REACH
    cx, cy = fx + ox, fy + oy

    for ring in range(FEEDBACK_PULSE_RINGS):
        t = phase - ring * 0.16
        if t <= 0.0 or t >= 1.0:
            continue
        eased = 1.0 - (1.0 - t) ** 2.4
        r = max(reach * eased, 1.0)
        a = int(255 * (1.0 - t) * FEEDBACK_PULSE_ALPHA)
        g.ellipse([cx - r, cy - r, cx + r, cy + r], outline=ACCENT + (a,),
                  width=max(int(unit * 0.010 * (1.0 - t * 0.5)), 1))

    core = max(1.0 - phase * 2.4, 0.0)
    if core > 0.0:
        r = unit * 0.045 * (1.0 + phase)
        g.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=ACCENT + (int(255 * core * FEEDBACK_PULSE_ALPHA),))


def draw_abrasion(base: Image.Image, field, origin, phase: float,
                  offsets) -> None:
    """Thin chromatic tear lines near the answered point.

    Ported from the REBUILT ui/trial_feedback.gd _draw_abrasion(). The first
    version filled full-width bands and this renderer is what exposed it.
    """
    fx, fy, fw, fh = field
    ox, oy = origin
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer, "RGBA")
    unit = min(fw, fh)
    strength = math.sin(max(min(phase, 1.0), 0.0) * math.pi)
    spread = unit * FEEDBACK_ABRASION_SPREAD * strength
    alpha = FEEDBACK_ABRASION_ALPHA * strength
    span = unit * FEEDBACK_ABRASION_REACH
    line_w = max(unit * FEEDBACK_ABRASION_LINE, 1.0)
    half_len = fw * FEEDBACK_ABRASION_LENGTH * 0.5
    bands = FEEDBACK_ABRASION_BANDS

    for i in range(bands):
        shift = spread * offsets[i % len(offsets)]
        t = (i / max(bands - 1, 1)) * 2.0 - 1.0
        y = fy + oy + t * span
        local = max(min(1.0 - abs(t), 1.0), 0.0)
        if local <= 0.01:
            continue
        a = int(255 * alpha * local)
        x0 = fx + ox - half_len * (0.5 + local * 0.5)
        x1 = fx + ox + half_len * (0.5 + local * 0.5)
        d.line([(x0 + shift, y), (x1 + shift, y)], fill=DANGER + (a,),
               width=max(int(line_w), 1))
        d.line([(x0 - shift, y + line_w), (x1 - shift, y + line_w)],
               fill=ACCENT + (a,), width=max(int(line_w), 1))

    seam = int(255 * alpha * 0.7)
    d.line([(fx + ox - half_len, fy + oy), (fx + ox + half_len, fy + oy)],
           fill=BACKGROUND + (seam,), width=max(int(line_w * 1.6), 1))
    base.alpha_composite(layer)


# ═════════════════════════════════════════════════════════════════════════
# ATMOSPHERE — vignette + motes, ported from ui/atmosphere.gd
# ═════════════════════════════════════════════════════════════════════════
def draw_atmosphere(base: Image.Image, glow: Image.Image) -> None:
    w, h = base.size
    unit = min(w, h)
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer, "RGBA")
    for i in range(12):
        t = i / 11.0
        r = unit * (0.55 + t * 0.9)
        d.ellipse([w / 2 - r, h / 2 - r, w / 2 + r, h / 2 + r],
                  outline=(0, 0, 0, int(255 * 0.16 * 0.5)),
                  width=max(int(unit * 0.05), 1))
    base.alpha_composite(layer)

    # Deterministic motes, matching MOTE_SEED's spirit: fixed field, halo not
    # a flat dot. The earlier atmosphere preview drew these opaque and was
    # called out for overstating them.
    import random
    rng = random.Random(0x2517)
    g = ImageDraw.Draw(glow, "RGBA")
    d2 = ImageDraw.Draw(base, "RGBA")
    for _ in range(34):
        mx, my = rng.random() * w, rng.random() * h
        r = rng.uniform(0.0016, 0.0052) * unit
        a = rng.uniform(0.10, 0.42)
        g.ellipse([mx - r * 4, my - r * 4, mx + r * 4, my + r * 4],
                  fill=ACCENT + (int(255 * a * 0.35),))
        d2.ellipse([mx - r, my - r, mx + r, my + r],
                   fill=ACCENT + (int(255 * a),))


# ═════════════════════════════════════════════════════════════════════════
# SPLASH BLOOM — a CPU port of ui/splash_bloom.gd _draw()
# ═════════════════════════════════════════════════════════════════════════
def draw_bloom(base: Image.Image, focus, reach: float) -> None:
    """Accumulate many faint discs, exactly as the shader-free bloom does."""
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    fx, fy = focus
    for i in range(SPLASH_HALO_RINGS):
        t = i / (SPLASH_HALO_RINGS - 1)
        r = max(reach * (1.0 - t * 0.94), 1.0)
        weight = t ** 0.6
        a = int(255 * SPLASH_HALO_ALPHA * (0.35 + weight))
        ring = Image.new("RGBA", base.size, (0, 0, 0, 0))
        ImageDraw.Draw(ring).ellipse([fx - r, fy - r, fx + r, fy + r],
                                     fill=ACCENT + (a,))
        layer.alpha_composite(ring)
    base.alpha_composite(layer)


def main() -> None:
    src = pathlib.Path(sys.argv[1])
    out_dir = pathlib.Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    data = json.loads(src.read_text())
    vw, vh = data["viewport"]
    W, H = int(S(vw)), int(S(vh))

    # ── (b) The active trial HUD ─────────────────────────────────────────
    t = data["trial"]
    nodes = {n["name"]: n for n in t["nodes"]}
    base = Image.new("RGBA", (W, H), BACKGROUND + (255,))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw_atmosphere(base, glow)

    fx, fy, fw, fh = [S(v) for v in t["field_rect"]]
    # The failure abrasion, drawn first at the point it really fired.
    draw_abrasion(base, (fx, fy, fw, fh),
                  (S(t["fail_origin"][0]), S(t["fail_origin"][1])),
                  0.5, [0.8, -0.5, 0.9, -0.3, 0.6, -0.7, 0.4])
    # The success pulse, at its real origin and a readable phase.
    draw_pulse(glow, (fx, fy, fw, fh),
               (S(t["feedback_origin"][0]), S(t["feedback_origin"][1])), 0.45)

    d = ImageDraw.Draw(base, "RGBA")
    ttl = nodes["TitleLabel"]
    d.text((W / 2, S(ttl["pos"][1]) + S(ttl["size"][1]) / 2), ttl["text"],
           font=_font(int(S(42))), fill=TEXT, anchor="mm")

    for name, fill in (("ScoreBezel", t["score_fill"]),
                       ("TimerBezel", t["timer_fill"])):
        n = nodes[name]
        draw_bezel(base, glow,
                   (S(n["pos"][0]), S(n["pos"][1]), S(n["size"][0]), S(n["size"][1])),
                   fill)
    for name in ("ScoreLabel", "TimerLabel"):
        n = nodes[name]
        d.text((W / 2, S(n["pos"][1]) + S(n["size"][1]) / 2), n["text"],
               font=_font(int(S(24))), fill=TEXT, anchor="mm")

    fb = nodes["FinishButton"]
    d.rounded_rectangle([S(fb["pos"][0]), S(fb["pos"][1]),
                         S(fb["pos"][0] + fb["size"][0]),
                         S(fb["pos"][1] + fb["size"][1])],
                        radius=int(S(14)), fill=(11, 14, 23, 224),
                        outline=ACCENT + (87,), width=2)
    d.text((W / 2, S(fb["pos"][1] + fb["size"][1] / 2)), fb["text"],
           font=_font(int(S(24))), fill=TEXT, anchor="mm")

    base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S(9))))
    base.convert("RGB").save(out_dir / "hud_trial.png")

    # ── (c) The splash, both acts ────────────────────────────────────────
    for act, fname in (("act1", "splash_act1.png"), ("act2", "splash_act2.png")):
        a = data["splash"][act]
        anodes = {n["name"]: n for n in a["nodes"]}
        b = Image.new("RGBA", (W, H), BACKGROUND + (255,))
        gl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        draw_atmosphere(b, gl)
        draw_bloom(b, (S(a["bloom_focus"][0]), S(a["bloom_focus"][1])),
                   S(a["bloom_reach"]))
        dd = ImageDraw.Draw(b, "RGBA")

        for nm, n in anodes.items():
            if n["cls"] != "Label" or not n["text"] or not n["visible"]:
                continue
            # Respect the EFFECTIVE alpha. TitleName is opaque in itself but
            # its TitleLayer parent is fully transparent during Act 1, so the
            # title must not appear over the sponsor ident.
            eff = n.get("modulate_a", 1.0)
            if eff <= 0.02:
                continue
            px = int(S(30)) if nm == "SponsorName" else int(S(19))
            colour = TEXT if nm == "SponsorName" else TEXT_FAINT
            if nm == "TitleName":
                colour = TEXT_DIM
            dd.text((W / 2, S(n["pos"][1]) + S(n["size"][1]) / 2), n["text"],
                    font=_font(px), fill=colour + (int(255 * eff),), anchor="mm")

        # ── The baked carved-metal centerpiece ───────────────────────
        # The REAL PNG the app loads, pasted at the REAL rect the live
        # SplashPlate reported. Nothing here is redrawn or approximated.
        plate = a.get("plate") or {}
        if plate.get("path"):
            art = Image.open(REPO / plate["path"].replace("res://", ""))
            art = art.convert("RGBA")
            pw, ph = int(S(plate["size"][0])), int(S(plate["size"][1]))
            art = art.resize((pw, ph), Image.LANCZOS)
            px, py = int(S(plate["pos"][0])), int(S(plate["pos"][1]))
            # Bloom behind the plate, as ui/splash_plate.gd draws it.
            cxp, cyp = px + pw / 2, py + ph / 2
            reach = math.hypot(pw, ph) * 0.5 * 1.15
            for i in range(18):
                t = i / 17.0
                rr = max(reach * (1.0 - t * 0.92), 1.0)
                lay = Image.new("RGBA", b.size, (0, 0, 0, 0))
                ImageDraw.Draw(lay).ellipse(
                    [cxp - rr, cyp - rr, cxp + rr, cyp + rr],
                    fill=ACCENT + (int(255 * 0.020 * (0.35 + t ** 0.6)),))
                b.alpha_composite(lay)
            b.alpha_composite(art, (px, py))

        # ── The iris progress readout: still procedural ──────────────
        if act == "act2":
            m = anodes["IrisProgress"]
            cx, cy = W / 2, S(m["pos"][1]) + S(m["size"][1]) / 2
            unit = min(S(m["size"][0]), S(m["size"][1]))
            prog = a["loader_progress"]
            open_v = prog ** 0.65
            ir = unit * 0.26
            for i in range(6):
                tt = i / 5.0
                r = ir * (0.30 + 0.70 * tt)
                dd.ellipse([cx - r, cy - r, cx + r, cy + r],
                           outline=ACCENT + (int(255 * (0.40 - 0.34 * tt) * open_v),),
                           width=max(int(unit * 0.008), 1))
            pr = unit * (0.045 + 0.05 * open_v)
            dd.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=PUPIL + (255,))
            ap = unit * (0.012 + 0.288 * open_v)
            LID_COVER, LID_FEATHER = 0.48, 0.22
            disc = unit * LID_COVER
            step = max(unit * 0.006, 1.0)
            lids = Image.new("RGBA", b.size, (0, 0, 0, 0))
            ld = ImageDraw.Draw(lids, "RGBA")
            off = ap
            while off < disc:
                half = math.sqrt(max(disc * disc - off * off, 0.0))
                outer = max(min((disc - off) / (disc * LID_FEATHER), 1.0), 0.0)
                inner = max(min((off - ap) / (disc * 0.16), 1.0), 0.0)
                aa = int(255 * outer * inner)
                ld.rectangle([cx - half, cy - off - step, cx + half, cy - off],
                             fill=BACKGROUND + (aa,))
                ld.rectangle([cx - half, cy + off, cx + half, cy + off + step],
                             fill=BACKGROUND + (aa,))
                off += step
            b.alpha_composite(lids)
            dd = ImageDraw.Draw(b, "RGBA")
            ar = unit * 0.44
            dd.arc([cx - ar, cy - ar, cx + ar, cy + ar], -90, -90 + 360 * prog,
                   fill=ACCENT + (140,), width=max(int(unit * 0.008), 2))

        b.alpha_composite(gl.filter(ImageFilter.GaussianBlur(S(11))))
        b.convert("RGB").save(out_dir / fname)

    print("wrote", out_dir / "hud_trial.png", out_dir / "splash_act1.png",
          out_dir / "splash_act2.png")


if __name__ == "__main__":
    main()
