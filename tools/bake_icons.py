#!/usr/bin/env python3
"""Bake the four launcher-icon variants from one 1024x1024 source.

WHY THIS EXISTS. The first icon set was produced ad-hoc, by hand, with no
recorded derivation. When the "I" had to be removed there was no way to
reproduce the 192px, adaptive-foreground and adaptive-background variants
except to eyeball them again. This script makes the derivation a single
auditable command, so the next correction is one regeneration away.

THE FOUR OUTPUTS, and the constraint each one answers:

    icon_512.png          512x512  RGB   store listing + application/config/icon.
                                         Google Play rejects SVG outright and
                                         wants 512 square, so this is the
                                         canonical raster.

    icon_192.png          192x192  RGB   Android legacy (pre-adaptive) launcher.

    icon_adaptive_fg.png  432x432  RGBA  Android adaptive foreground. Android
                                         masks the outer third of this layer to
                                         whatever shape the launcher uses, so
                                         the emblem is INSET to ADAPTIVE_INSET
                                         of the frame. Drawing to the edges
                                         gets the badge's spikes clipped.

    icon_adaptive_bg.png  432x432  RGB   Android adaptive background plate. A
                                         flat fill sampled from the source's
                                         own corners, so the two layers cannot
                                         disagree about the backdrop colour.

Run:  python3 tools/bake_icons.py <source.png>
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

# Android masks an adaptive icon down to a guaranteed-visible circle of 66dp
# within the 108dp layer — 61.1% of the frame's diameter. Anything outside it
# may be clipped by the launcher's mask shape.
#
# MEASURED, NOT GUESSED. The first pass used 0.62, which was carried over from
# the previous icon set. Rasterising it and measuring the badge's real extent
# showed its outermost pixel at radius 163 of a 132 safe radius: the spike tips
# at every compass point sat OUTSIDE the circle and would have been shaved off
# on a circular-mask launcher. Solving 0.62 * 132 / 163 gives 0.502.
#
# Settled at 0.49: _assert_inside_safe_circle() rejected 0.502 by a single
# pixel. That guard runs on every bake, so a future source drawn with wider
# spikes fails the build loudly rather than shipping clipped.
ADAPTIVE_INSET = 0.49

# Android's guaranteed-visible fraction of an adaptive icon's diameter.
ADAPTIVE_SAFE_FRACTION = 0.611

ADAPTIVE_SIZE = 432
STORE_SIZE = 512
LEGACY_SIZE = 192

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "art" / "branding"


def _backdrop(src: Image.Image) -> tuple[int, int, int]:
    """Average the four corners of the source for the adaptive backdrop.

    Sampling the art rather than hardcoding a colour means the background
    plate always matches the foreground's own backdrop, even if the source is
    regenerated with a different stone tone.
    """
    w, h = src.size
    pad = max(w // 64, 1)
    corners = [
        src.getpixel((pad, pad)),
        src.getpixel((w - 1 - pad, pad)),
        src.getpixel((pad, h - 1 - pad)),
        src.getpixel((w - 1 - pad, h - 1 - pad)),
    ]
    channels = [sum(c[i] for c in corners) // len(corners) for i in range(3)]
    return (channels[0], channels[1], channels[2])


def _assert_inside_safe_circle(fg: Image.Image) -> None:
    """Fail the bake if any badge pixel falls outside Android's safe circle.

    Without this the inset is just a number in a comment. With it, a source
    whose emblem is drawn wider than the mask allows stops the build instead of
    shipping an icon with its spikes shaved off on circular-mask launchers.
    """
    size = fg.size[0]
    centre = size / 2.0
    safe_radius = size * ADAPTIVE_SAFE_FRACTION / 2.0
    pixels = fg.load()

    worst = 0.0
    offenders = 0
    for y in range(size):
        dy = y - centre
        for x in range(size):
            r, g, b, a = pixels[x, y]
            # The badge proper: opaque and brighter than the stone backdrop.
            # The knocked-out surround and the dark plate are not the emblem.
            if a <= 200 or (r + g + b) / 3 <= 40:
                continue
            radius = ((x - centre) ** 2 + dy * dy) ** 0.5
            worst = max(worst, radius)
            if radius > safe_radius:
                offenders += 1

    print(f"  badge extent {worst:.0f}px / safe {safe_radius:.0f}px"
          f"  ({offenders} px outside)")
    if offenders:
        raise SystemExit(
            f"FAIL: {offenders} badge pixels fall outside Android's "
            f"guaranteed-visible circle (extent {worst:.0f}px > "
            f"{safe_radius:.0f}px). Lower ADAPTIVE_INSET to "
            f"{ADAPTIVE_INSET * safe_radius / worst:.3f}.")


def bake(source_path: Path) -> None:
    src = Image.open(source_path).convert("RGB")
    if src.size[0] != src.size[1]:
        raise SystemExit(f"source must be square, got {src.size}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ── Store + config icon ──────────────────────────────────────────────
    src.resize((STORE_SIZE, STORE_SIZE), Image.LANCZOS).save(
        OUT_DIR / "icon_512.png", optimize=True)

    # ── Android legacy launcher ──────────────────────────────────────────
    src.resize((LEGACY_SIZE, LEGACY_SIZE), Image.LANCZOS).save(
        OUT_DIR / "icon_192.png", optimize=True)

    # ── Adaptive foreground: emblem inset, transparent surround ──────────
    inner = int(ADAPTIVE_SIZE * ADAPTIVE_INSET)
    fg = Image.new("RGBA", (ADAPTIVE_SIZE, ADAPTIVE_SIZE), (0, 0, 0, 0))
    emblem = src.resize((inner, inner), Image.LANCZOS).convert("RGBA")

    # Knock the flat backdrop out of the emblem so the adaptive background
    # plate shows through instead of a visible dark square inside the mask.
    back = _backdrop(src)
    pixels = emblem.load()
    for y in range(inner):
        for x in range(inner):
            r, g, b, _ = pixels[x, y]
            # Distance from the backdrop tone, normalised. Anything close to
            # the plate colour becomes transparent; the metal and the glow,
            # which are far from it, stay fully opaque.
            dist = abs(r - back[0]) + abs(g - back[1]) + abs(b - back[2])
            alpha = min(255, int(dist * 255 / 48)) if dist < 48 else 255
            pixels[x, y] = (r, g, b, alpha)

    offset = (ADAPTIVE_SIZE - inner) // 2
    fg.paste(emblem, (offset, offset), emblem)
    fg.save(OUT_DIR / "icon_adaptive_fg.png", optimize=True)

    _assert_inside_safe_circle(fg)

    # ── Adaptive background: flat plate in the source's own backdrop ─────
    Image.new("RGB", (ADAPTIVE_SIZE, ADAPTIVE_SIZE), back).save(
        OUT_DIR / "icon_adaptive_bg.png", optimize=True)

    total = 0
    for name in ("icon_512", "icon_192", "icon_adaptive_fg", "icon_adaptive_bg"):
        path = OUT_DIR / f"{name}.png"
        size = path.stat().st_size
        total += size
        print(f"  {name+'.png':24s} {size/1024:8.1f} KB  {Image.open(path).size}")
    print(f"  {'branding total':24s} {total/1024:8.1f} KB")
    print(f"  adaptive backdrop RGB{back}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    bake(Path(sys.argv[1]))
