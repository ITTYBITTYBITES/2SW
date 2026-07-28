#!/usr/bin/env python3
"""Bake the splash centerpieces from generated source art.

WHY THIS EXISTS
---------------
Same reason as tools/bake_icons.py: the derivation has to be a command, not a
memory. When one of these marks is regenerated, the crop, the alpha cut, the
resize and the budget check all have to happen the same way again.

WHAT IT PRODUCES

    sponsor_mark.png    Act 1 centerpiece — the runic aperture badge
    title_plate.png     Act 2 centerpiece — the carved "2SW" nameplate

THE ALPHA CUT IS THE HARD PART, AND A LUMINANCE THRESHOLD DOES NOT WORK.
That was already learned once on the hero housing: thresholding on brightness
cut the wrong pixels both ways, because the darkest region of the art is a
FEATURE (there, the pupil; here, the shadowed metal between the aperture
blades) while the backdrop is not uniformly black either.

So the cut is geometric first and photometric only at the margin:

    sponsor  a radial mask — the badge is a disc, so anything outside its
             radius goes, and only the soft falloff band is refined by
             luminance.
    title    a rectangular mask on the measured plate bounds, feathered at
             the edge, because the plate is a rectangle and a radial mask
             would clip its corners.

Both marks are composited over a procedural bloom at runtime, so their
backdrop MUST be transparent. A baked-in black square would punch a hole in
the halo — exactly the bug the iris lid mask caused in the previous pass.

Run:  python3 tools/bake_splash_art.py
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageFilter

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC_DIR = pathlib.Path("/home/user/2sw_previews/v3")
OUT_DIR = REPO / "art" / "branding" / "splash"

# Output sizes, CHOSEN BY MEASUREMENT.
#
# 512/640 blew the allowance at 945 KB. The obvious lever was colour
# quantisation, and it was measured and REJECTED for the same reason it was
# rejected on the hero housing: at 256 colours the sponsor mark lost 8.4% of
# its saturation and the title plate 15.1%, visibly draining the metal, for
# roughly the same bytes a modest downscale saves.
#
# Downscaling costs almost nothing by comparison — the sponsor holds 0.322
# saturation against a 0.323 baseline at 384px. So the marks are smaller and
# full-colour rather than large and washed out.
#
# Both still oversample the screen. The sponsor mark lays out at ~46% of a
# 1080px width (≈500px) and the title plate at ~62% (≈670px wide), so at a
# 1440p device's 1.33x these are close to native and well above it on 1080p.
SPONSOR_SIZE = 384
TITLE_W = 512
TITLE_H = 256

# The whole point of the cap is total shipped bitmap weight. Both marks
# together must stay well inside the headroom that was measured before this
# work started (1.78 MB).
SPLASH_BUDGET_KB = 900.0


def _radial_alpha(img: Image.Image, inner: float, outer: float) -> Image.Image:
    """Disc mask: opaque inside `inner`, transparent past `outer`.

    Between the two the alpha ramps AND is modulated by luminance, so faint
    backdrop texture inside the falloff band drops out while a bright metal
    spike crossing the same band survives.
    """
    w, h = img.size
    cx, cy = w / 2.0, h / 2.0
    px = img.load()
    alpha = Image.new("L", (w, h), 0)
    ap = alpha.load()
    span = max(outer - inner, 1e-6)

    for y in range(h):
        dy = (y - cy) / cy
        for x in range(w):
            dx = (x - cx) / cx
            r = (dx * dx + dy * dy) ** 0.5
            if r <= inner:
                ap[x, y] = 255
                continue
            if r >= outer:
                ap[x, y] = 0
                continue
            t = 1.0 - (r - inner) / span
            red, green, blue = px[x, y][:3]
            lum = (red + green + blue) / 3.0
            # Bright pixels hold on through the falloff; dark backdrop does not.
            keep = min(lum / 90.0, 1.0)
            ap[x, y] = int(255 * t * (0.25 + 0.75 * keep))
    return alpha


def _luma_alpha(img: Image.Image, floor_v: int, ceil_v: int,
                feather: int) -> Image.Image:
    """Keep the lit object, drop the unlit stone backdrop behind it.

    THIS REPLACED A PLAIN RECTANGLE MASK, WHICH WAS WRONG.

    The rectangle kept the entire crop, so 52.5% of the title plate shipped as
    OPAQUE DARK STONE — the generated backdrop the plate was painted on. Its
    corners were transparent, so the corner probe passed, and the defect only
    became visible when the plate was composited over the bloom in a render:
    a hard black slab across the halo.

    The plate is a lit metal object on an unlit backdrop, and that is a
    luminance separation, not a geometric one. Anything at or below `floor_v`
    is backdrop and goes; anything at or above `ceil_v` is the object and
    stays; between them the alpha ramps. The result is blurred so the cut is
    not a jagged per-pixel edge.

    A luminance cut was rejected for the hero housing because its DARKEST
    region was a feature (the pupil). That does not apply here: the plate has
    no interior black feature — its darkest parts are the runic grooves, which
    sit inside the plate body and are protected by the fill step below.
    """
    grey = img.convert("L")
    span = max(ceil_v - floor_v, 1)

    def ramp(v: int) -> int:
        if v <= floor_v:
            return 0
        if v >= ceil_v:
            return 255
        return int(255 * (v - floor_v) / span)

    alpha = grey.point(ramp)

    # Fill interior holes: the engraved grooves and rivet shadows are darker
    # than the cut, and punching them out would make the plate look moth-eaten.
    # A max-filter closes them, then the blur softens the outer edge.
    alpha = alpha.filter(ImageFilter.MaxFilter(5))
    return alpha.filter(ImageFilter.GaussianBlur(feather))


def _content_box(img: Image.Image, threshold: int = 26):
    """Bounding box of everything visibly brighter than the stone backdrop."""
    grey = img.convert("L")
    mask = grey.point(lambda v: 255 if v > threshold else 0)
    box = mask.getbbox()
    return box if box is not None else (0, 0, *img.size)


def bake_sponsor() -> pathlib.Path:
    src = Image.open(SRC_DIR / "src_sponsor.png").convert("RGB")
    box = _content_box(src)
    # Square the crop around the badge's centre so the disc stays a disc.
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    half = max(box[2] - box[0], box[3] - box[1]) / 2
    half = min(half * 1.02, cx, cy, src.size[0] - cx, src.size[1] - cy)
    crop = src.crop((int(cx - half), int(cy - half),
                     int(cx + half), int(cy + half)))
    crop = crop.resize((SPONSOR_SIZE, SPONSOR_SIZE), Image.LANCZOS)

    out = crop.convert("RGBA")
    # Radial mask AND luminance cut, multiplied.
    #
    # The radial mask alone left 22.1% of the badge as opaque stone: the art's
    # square backdrop shows between the badge's spikes, well inside the disc's
    # radius, so no purely geometric mask can reach it. The luminance cut
    # removes the unlit stone; the radial mask still handles the outer corners
    # where the two would otherwise disagree.
    radial = _radial_alpha(crop, 0.80, 1.0)
    luma = _luma_alpha(crop, floor_v=30, ceil_v=62,
                       feather=max(int(SPONSOR_SIZE * 0.006), 1))
    combined = Image.new("L", crop.size)
    rp, lp, cp = radial.load(), luma.load(), combined.load()
    for y in range(crop.size[1]):
        for x in range(crop.size[0]):
            cp[x, y] = rp[x, y] * lp[x, y] // 255
    out.putalpha(combined)
    path = OUT_DIR / "sponsor_mark.png"
    out.save(path, optimize=True)
    return path


def bake_title() -> pathlib.Path:
    src = Image.open(SRC_DIR / "src_title2.png").convert("RGB")
    box = _content_box(src)
    pad = int((box[2] - box[0]) * 0.02)
    crop = src.crop((max(box[0] - pad, 0), max(box[1] - pad, 0),
                     min(box[2] + pad, src.size[0]),
                     min(box[3] + pad, src.size[1])))
    crop = crop.resize((TITLE_W, TITLE_H), Image.LANCZOS)

    out = crop.convert("RGBA")
    out.putalpha(_luma_alpha(crop, floor_v=46, ceil_v=80,
                             feather=max(int(TITLE_H * 0.008), 1)))
    path = OUT_DIR / "title_plate.png"
    out.save(path, optimize=True)
    return path


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total = 0.0
    for path in (bake_sponsor(), bake_title()):
        kb = path.stat().st_size / 1024
        total += kb
        img = Image.open(path)
        print(f"  {path.name:20s} {kb:8.1f} KB  {img.size}  {img.mode}")
    print(f"  {'splash total':20s} {total:8.1f} KB "
          f"of {SPLASH_BUDGET_KB:.0f} KB allowance")
    if total > SPLASH_BUDGET_KB:
        raise SystemExit(
            f"FAIL: splash art is {total:.1f} KB, over the "
            f"{SPLASH_BUDGET_KB:.0f} KB allowance")

    # Corners must be transparent. These marks sit over a procedural bloom; a
    # baked-in opaque backdrop would punch a dark square through the halo.
    for name in ("sponsor_mark.png", "title_plate.png"):
        im = Image.open(OUT_DIR / name).convert("RGBA")
        w, h = im.size
        corners = [im.getpixel(p)[3] for p in
                   ((1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2))]
        print(f"  {name:20s} corner alpha {corners}")
        if max(corners) > 8:
            raise SystemExit(
                f"FAIL: {name} has an opaque corner (alpha {max(corners)}); "
                f"it would block the bloom behind it")

        # ── AND NO OPAQUE STONE AROUND THE EDGE ──────────────────────────
        # Transparent corners are NOT enough. The title plate's first bake had
        # clean corners and still shipped 52.5% of its area as opaque dark
        # backdrop, which rendered as a black slab across the bloom.
        #
        # MEASURE THE MARGIN, NOT THE WHOLE IMAGE. A first attempt counted
        # every dark opaque pixel and flagged the sponsor badge at 21%, which
        # was WRONG: that art's dark pixels are concentrated at its CENTRE
        # (radius 0.0-0.7), because the shadowed metal between the aperture
        # blades is a feature. Measured by ring, the badge's outer margin was
        # already 0.0% — it was clean, and the check was lying.
        #
        # The stone backdrop, when it survives, is by definition at the EDGE
        # of the crop. So that is where to look.
        px = im.load()
        margin_x = max(int(w * 0.06), 2)
        margin_y = max(int(h * 0.06), 2)
        dark_opaque = 0
        counted = 0
        for y in range(0, h, 2):
            for x in range(0, w, 2):
                edge = (x < margin_x or x >= w - margin_x
                        or y < margin_y or y >= h - margin_y)
                if not edge:
                    continue
                r, g, bl, al = px[x, y]
                counted += 1
                if al > 200 and (r + g + bl) / 3 < 40:
                    dark_opaque += 1
        share = dark_opaque / max(counted, 1)
        print(f"  {name:20s} margin opaque-dark {share * 100:5.1f}%")
        if share > 0.10:
            raise SystemExit(
                f"FAIL: {name} has {share * 100:.1f}% opaque dark pixels in "
                f"its margin — the generated stone backdrop was not cut away, "
                f"and it will render as a slab over the bloom")


if __name__ == "__main__":
    main()
