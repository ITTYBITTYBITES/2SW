#!/usr/bin/env python3
"""Rasterize iris_procedural.gdshader on the CPU.

WHY THIS EXISTS
---------------
The sandbox has no display server, so Godot cannot open a window and no
screenshot can ever be taken here. That gap is exactly how the invisible-Iris
bug survived a 1000+ check suite: every test asked about node state, and node
state looked perfect while the GPU drew nothing.

This is a faithful line-by-line port of the shader's fragment() to numpy. It is
NOT a test and it is not authoritative about the GPU — float precision and
derivative behaviour differ. It answers one question the test suite cannot:
"if a human looked at this, would there be an eye there?"

OUTPUT GOES OUTSIDE THE PROJECT. Writing PNGs under res:// makes Godot
import them, which generates .import files, which get committed — and this
project's rule 9 is zero assets. That is exactly what happened in ce886d7.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

# ── Uniform defaults, copied from the shader's declarations ──────────────
GAZE = np.array([0.0, 0.0])
PUPIL_DILATION = 0.5
SHIMMER_RESONANCE = 0.0
COMPLEXITY = 1.2
BLINK = 0.0
GLOW = 1.0
PORTAL = 0.0
TIME = 3.0

def _boost(rgb, sat_mul=1.45, val_mul=1.12):
    import colorsys
    h,l,ss = colorsys.rgb_to_hls(*rgb)
    # approximate HSV boost the way Color.s / Color.v behave
    r,g,b = colorsys.hls_to_rgb(h, min(l*val_mul,1.0), min(ss*sat_mul,1.0))
    return np.array([r,g,b])

IRIS_COLOR = _boost(np.array([0.22, 0.72, 0.78]))
IRIS_DEEP = np.array([0.22,0.72,0.78]) * 0.20   # accent.darkened(0.80)
SCLERA_COLOR = np.array([0.055, 0.098, 0.105])   # COLOR_SCLERA_DEEP
LIMBAL_COLOR = np.array([0.02, 0.05, 0.09])
LID_COLOR = np.array([0.024, 0.031, 0.055])
GLINT_COLOR = np.array([1.0, 1.0, 1.0])

IRIS_RADIUS = 0.72
PUPIL_MIN = 0.20
PUPIL_MAX = 0.46
EYE_WIDTH = 1.32
EYE_HEIGHT = 0.98

BACKGROUND = np.array([0.024, 0.031, 0.055])  # Palette.COLOR_BACKGROUND


def fract(x):
    return x - np.floor(x)


def clamp(x, a, b):
    return np.clip(x, a, b)


def mix(a, b, t):
    return a + (b - a) * t


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0 + 1e-12), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def hash12(px, py):
    p3x, p3y, p3z = fract(px * 0.1031), fract(py * 0.1031), fract(px * 0.1031)
    d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x, p3y, p3z = p3x + d, p3y + d, p3z + d
    return fract((p3x + p3y) * p3z)


def hash22(px, py):
    p3x = fract(px * 0.1031)
    p3y = fract(py * 0.1030)
    p3z = fract(px * 0.0973)
    d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x, p3y, p3z = p3x + d, p3y + d, p3z + d
    return fract((p3x + p3x) * p3z), fract((p3y + p3z) * p3y)


def value_noise(px, py):
    ix, iy = np.floor(px), np.floor(py)
    fx, fy = fract(px), fract(py)
    ux = fx * fx * (3.0 - 2.0 * fx)
    uy = fy * fy * (3.0 - 2.0 * fy)
    a = hash12(ix, iy)
    b = hash12(ix + 1.0, iy)
    c = hash12(ix, iy + 1.0)
    d = hash12(ix + 1.0, iy + 1.0)
    return mix(mix(a, b, ux), mix(c, d, ux), uy)


def voronoi_fibres(px, py, density, t):
    sx, sy = px * density, py * density
    cx, cy = np.floor(sx), np.floor(sy)
    fx, fy = fract(sx), fract(sy)
    nearest = np.full_like(px, 8.0)
    second = np.full_like(px, 8.0)
    cell_id = np.zeros_like(px)
    for gy in (-1, 0, 1):
        for gx in (-1, 0, 1):
            ptx, pty = hash22(cx + gx, cy + gy)
            ptx = 0.5 + 0.42 * np.sin(t * 0.35 + 6.2831 * ptx)
            pty = 0.5 + 0.42 * np.sin(t * 0.35 + 6.2831 * pty)
            dx = gx + ptx - fx
            dy = gy + pty - fy
            d = np.sqrt(dx * dx + dy * dy)
            closer = d < nearest
            second = np.where(closer, nearest, np.where(d < second, d, second))
            cell_id = np.where(closer, hash12(cx + gx, cy + gy), cell_id)
            nearest = np.where(closer, d, nearest)
    return second - nearest, cell_id


def sd_eye_aperture(px, py, w, h, lid_close):
    upper_y = h * (1.0 - 1.06 * lid_close)
    lower_y = -h * (1.0 - 0.55 * lid_close)
    nx = clamp(px / max(w, 1e-4), -1.0, 1.0)
    curve = 1.0 - nx * nx
    d_upper = py - upper_y * curve
    d_lower = lower_y * curve - py
    d_sides = np.abs(px) - w
    return np.maximum(np.maximum(d_upper, d_lower), d_sides)


# ── Phase 3 optical constants, mirrored from the shader ────────────────
CORNEA_DEPTH = 0.045
CORNEA_BULGE_SCALE = 1.24
LID_SHADOW_REACH = 0.62
REFRACTION_STRENGTH = 1.0


def render(width: int, height: int, multiply_by_host_alpha: bool,
           host_alpha: float = 0.0, aspect_correct: bool = True,
           phase3: bool = True):
    """Render the eye.

    `multiply_by_host_alpha` reproduces the original invisible-Iris bug.
    `aspect_correct=False` reproduces the pre-fix `p = uv * 2.0`, which
    distorted the eye on every non-square host rect.
    """
    ux = (np.arange(width) + 0.5) / width
    uy = (np.arange(height) + 0.5) / height
    U, V = np.meshgrid(ux, uy)

    if aspect_correct:
        short_axis = max(min(width, height), 1)
        ax, ay = width / short_axis, height / short_axis
    else:
        ax, ay = 1.0, 1.0

    px = (U - 0.5) * 2.0 * ax
    py = (V - 0.5) * 2.0 * ay
    t = TIME

    gx, gy = GAZE[0] * 0.22, GAZE[1] * 0.22
    fx, fy = px - gx, py - gy

    if phase3:
        dome_r = IRIS_RADIUS * CORNEA_BULGE_SCALE
        dome_t = clamp(1.0 - (fx * fx + fy * fy) / (dome_r * dome_r), 0.0, 1.0)
        dome_h = np.sqrt(dome_t)
        nxd = fx / max(dome_r * dome_r, 1e-4)
        nyd = fy / max(dome_r * dome_r, 1e-4)
        ix = fx - nxd * dome_h * CORNEA_DEPTH * REFRACTION_STRENGTH
        iy = fy - nyd * dome_h * CORNEA_DEPTH * REFRACTION_STRENGTH
    else:
        ix, iy = fx, fy

    r = np.sqrt(ix * ix + iy * iy)
    plen = np.sqrt(px * px + py * py)

    pupil_r = mix(PUPIL_MIN, PUPIL_MAX, clamp(PUPIL_DILATION, 0.0, 1.0))
    pupil_r = mix(pupil_r, IRIS_RADIUS * 1.35, PORTAL)

    # 1. SCLERA
    sclera_shade = 1.0 - smoothstep(0.0, 1.35, plen)
    col = SCLERA_COLOR[None, None, :] * (0.55 + 0.45 * sclera_shade)[..., None]
    warm = SCLERA_COLOR * np.array([1.0, 0.93, 0.90])
    w_t = (smoothstep(0.35, 1.1, np.abs(px)) * 0.35)[..., None]
    col = mix(col, warm[None, None, :], w_t)
    col = col + (value_noise(px * 9.0, py * 9.0) - 0.5)[..., None] * 0.02

    # 2-4. IRIS BODY
    iris_mask = 1.0 - smoothstep(IRIS_RADIUS - 0.012, IRIS_RADIUS + 0.012, r)
    nr = clamp(r / max(IRIS_RADIUS, 1e-4), 0.0, 1.0)
    angle = np.arctan2(iy, ix)
    density = 5.0 + COMPLEXITY * 5.5
    vor_x, vor_y = voronoi_fibres(angle * 1.9, nr * 2.6, density, t)

    fibre_coarse = smoothstep(0.0, 0.42, vor_x) * (0.72 + 0.55 * vor_y)
    if phase3:
        vm_x, vm_y = voronoi_fibres(angle * 1.9 * 2.15 + 4.0, nr * 2.6 * 2.15 + 4.0, density, t * 0.7)
        fibre_mid = smoothstep(0.0, 0.34, vm_x) * (0.60 + 0.70 * vm_y)
        vf_x, _vf_y = voronoi_fibres(angle * 1.9 * 4.6 + 9.0, nr * 2.6 * 4.6 + 9.0, density, t * 0.45)
        fibre_fine = smoothstep(0.0, 0.26, vf_x)
        FIBRE_SPOKES = 26.0
        FIBRE_BURST_GAIN = 0.62
        spoke_seed = hash12(np.floor(angle * FIBRE_SPOKES), np.full_like(angle, 3.0))
        spoke_phase = angle * FIBRE_SPOKES + spoke_seed * 6.2831
        spokes = np.power(0.5 + 0.5 * np.sin(spoke_phase), 3.4)
        burst_reach = smoothstep(0.16, 0.42, nr) * (1.0 - smoothstep(0.62, 0.98, nr))
        burst = spokes * burst_reach
        fibre = (fibre_coarse * 0.44 + fibre_mid * 0.20 + fibre_fine * 0.11
                 + burst * FIBRE_BURST_GAIN)
        fibre = np.power(clamp(fibre, 0.0, 1.0), 0.78)
    else:
        fibre = fibre_coarse

    depth = smoothstep(0.0, 0.42, nr) * (1.0 - smoothstep(0.72, 1.0, nr))
    stroma = mix(IRIS_DEEP[None, None, :], IRIS_COLOR[None, None, :], depth[..., None])
    if phase3:
        stroma = stroma + IRIS_COLOR[None, None, :] * (fibre * 0.78 * depth)[..., None]
        stroma = stroma * (1.0 - ((1.0 - fibre) * 0.34 * depth))[..., None]
    else:
        stroma = stroma + IRIS_COLOR[None, None, :] * (fibre * 0.55 * depth)[..., None]

    collar_pos = pupil_r / max(IRIS_RADIUS, 1e-4) + 0.14
    collar = np.exp(-((nr - collar_pos) * 7.5) ** 2)
    stroma = stroma + IRIS_COLOR[None, None, :] * (collar * 0.42)[..., None]

    crypts = value_noise(angle * 1.9 * 3.1 + 11.0, nr * 2.6 * 3.1 + 11.0)
    if phase3:
        crypts_fine = value_noise(angle * 1.9 * 7.4 + 23.0, nr * 2.6 * 7.4 + 23.0)
        stroma = stroma * (0.80 + 0.26 * crypts + 0.10 * crypts_fine)[..., None]
        deep_pit = smoothstep(0.42, 0.0, crypts) * depth
        stroma = stroma * (1.0 - deep_pit * 0.30)[..., None]
    else:
        stroma = stroma * (0.82 + 0.30 * crypts)[..., None]

    limbal = smoothstep(0.80, 1.0, nr)
    stroma = mix(stroma, LIMBAL_COLOR[None, None, :], (limbal * 0.88)[..., None])
    col = mix(col, stroma, iris_mask[..., None])

    # 5. PUPIL
    pupil_d = r - pupil_r
    pupil_mask = 1.0 - smoothstep(-0.010, 0.010, pupil_d)
    pupil_col = IRIS_DEEP * 0.18
    pupil_col = mix(pupil_col, IRIS_COLOR * 1.4, PORTAL * 0.8)
    col = mix(col, pupil_col[None, None, :], pupil_mask[..., None])

    margin = smoothstep(0.0, 0.055, pupil_d) * (1.0 - smoothstep(0.055, 0.14, pupil_d))
    col = col * (1.0 - margin * 0.30)[..., None]

    # 7. CORNEA
    g1x, g1y = -0.20, 0.24
    if phase3:
        stretch = 1.0 + np.hypot(g1x, g1y) * 0.85
        adx = (px - g1x) / stretch
        ady = (py - g1y) * 1.22
        ad = np.sqrt(adx * adx + ady * ady)
        col = col + GLINT_COLOR[None, None, :] * (np.exp(-(ad * 11.0) ** 2) * 0.82)[..., None]
        col = col + GLINT_COLOR[None, None, :] * (np.exp(-(ad * 4.6) ** 2) * 0.14)[..., None]
        bdx = (px - g1x - 0.055) / stretch
        bdy = (py - g1y + 0.030) * 1.3
        bd = np.sqrt(bdx * bdx + bdy * bdy)
        col = col + GLINT_COLOR[None, None, :] * (np.exp(-(bd * 15.0) ** 2) * 0.34)[..., None]
        g2x, g2y = 0.26, -0.20
        c2 = np.sqrt(((px - g2x) * 1.35) ** 2 + ((py - g2y) / 1.15) ** 2)
        col = col + GLINT_COLOR[None, None, :] * (np.exp(-(c2 * 6.4) ** 2) * 0.17)[..., None]
    else:
        glint = np.exp(-(np.sqrt((px - g1x) ** 2 + (py - g1y) ** 2) * 9.5) ** 2)
        col = col + GLINT_COLOR[None, None, :] * (glint * 0.75)[..., None]
        g2x, g2y = 0.26, -0.20
        glint2 = np.exp(-(np.sqrt((px - g2x) ** 2 + (py - g2y) ** 2) * 6.0) ** 2)
        col = col + GLINT_COLOR[None, None, :] * (glint2 * 0.16)[..., None]

    rim = smoothstep(IRIS_RADIUS * 0.86, IRIS_RADIUS * 1.04, r) * (
        1.0 - smoothstep(IRIS_RADIUS * 1.04, IRIS_RADIUS * 1.20, r))
    col = col + IRIS_COLOR[None, None, :] * (rim * 0.28 * GLOW)[..., None]
    col = col * (0.86 + 0.20 * GLOW)

    # 8. EYELIDS
    aperture = sd_eye_aperture(px, py, EYE_WIDTH, EYE_HEIGHT, BLINK)
    lid_mask = smoothstep(-0.012, 0.012, aperture)

    if phase3:
        upper_edge = EYE_HEIGHT * (1.0 - 1.06 * BLINK)
        nxs = clamp(px / max(EYE_WIDTH, 1e-4), -1.0, 1.0)
        lid_curve = upper_edge * (1.0 - nxs * nxs)
        below = py + lid_curve
        contact = 1.0 - smoothstep(0.0, EYE_HEIGHT * 0.14, below)
        occl = 1.0 - smoothstep(0.0, EYE_HEIGHT * LID_SHADOW_REACH, below)
        occl = occl * occl
        globe = 1.0 - lid_mask
        shade = clamp(contact * 0.42 + occl * 0.78, 0.0, 1.0) * globe * (below >= 0.0)
        col = col * (1.0 - shade * 0.70)[..., None]
        menisc = (1.0 - smoothstep(0.0, EYE_HEIGHT * 0.05, below)) * (below >= 0.0) * globe
        col = col + GLINT_COLOR[None, None, :] * (menisc * 0.10)[..., None]

    lash = (1.0 - smoothstep(0.0, 0.085, np.abs(aperture))) * (1.0 - lid_mask)
    col = mix(col, (LID_COLOR * 0.55)[None, None, :], (lash * 0.55)[..., None])

    if phase3:
        lid_depth = smoothstep(0.0, 0.16, aperture) * lid_mask
        lid_shaded = mix((LID_COLOR * 0.72)[None, None, :],
                         (LID_COLOR * 1.35)[None, None, :], lid_depth[..., None])
        col = mix(col, lid_shaded, lid_mask[..., None])
    else:
        col = mix(col, LID_COLOR[None, None, :], lid_mask[..., None])

    # OUTPUT
    body_alpha = 1.0 - smoothstep(1.02, 1.20, plen)
    alpha = np.maximum(body_alpha, 1.0 - lid_mask)
    alpha = clamp(np.maximum(alpha, lid_mask * body_alpha), 0.0, 1.0)

    if multiply_by_host_alpha:
        alpha = alpha * host_alpha

    # Composite over the app background, which is what the player sees.
    out = mix(BACKGROUND[None, None, :], clamp(col, 0.0, 1.0), alpha[..., None])
    return clamp(out, 0.0, 1.0), alpha


def save(path: str, rgb):
    Image.fromarray((rgb * 255.0 + 0.5).astype(np.uint8)).save(path)


if __name__ == "__main__":
    import os
    out_dir = os.environ.get("PREVIEW_DIR", "/home/user/2sw_previews")
    os.makedirs(out_dir, exist_ok=True)

    W, H = 508, 694  # half the intro's 1016x1388 CoreEye rect

    fixed, a_fixed = render(W, H, multiply_by_host_alpha=False)
    save(os.path.join(out_dir, "iris_preview_fixed.png"), fixed)

    broken, a_broken = render(W, H, multiply_by_host_alpha=True, host_alpha=0.0)
    save(os.path.join(out_dir, "iris_preview_before.png"), broken)

    print("FIXED   alpha: min=%.3f max=%.3f mean=%.3f  nonzero=%.1f%%" % (
        a_fixed.min(), a_fixed.max(), a_fixed.mean(), 100.0 * (a_fixed > 0.01).mean()))
    print("BEFORE  alpha: min=%.3f max=%.3f mean=%.3f  nonzero=%.1f%%" % (
        a_broken.min(), a_broken.max(), a_broken.mean(),
        100.0 * (a_broken > 0.01).mean()))

    diff = np.abs(fixed - broken).max()
    print("max per-pixel difference between the two = %.3f" % diff)

    # How much of the frame is visibly distinct from the flat background?
    dist = np.abs(fixed - BACKGROUND[None, None, :]).max(axis=2)
    print("FIXED:  %.1f%% of pixels differ from the background by >2/255" % (
        100.0 * (dist > 2.0 / 255.0).mean()))
    dist_b = np.abs(broken - BACKGROUND[None, None, :]).max(axis=2)
    print("BEFORE: %.1f%% of pixels differ from the background by >2/255" % (
        100.0 * (dist_b > 2.0 / 255.0).mean()))
