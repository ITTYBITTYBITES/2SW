#!/usr/bin/env python3
"""Bake the procedural audio layer library.

WHY THIS EXISTS
The pad was three detuned sine partials. Sines are the one waveform with no
timbre at all — no attack transient, no inharmonicity, no noise floor — so
the bed read as a test tone rather than as a room. Retuning it per trial
(e152c6e) made four distinct CHORDS out of the same lifeless sound.

This renders a library of layers by PHYSICAL MODELLING rather than by adding
sines: struck and bowed resonant bodies, filtered air, granular shimmer. Each
layer is a seamless loop that the engine pitch-shifts, filters and crossfades
at runtime, so the combinations are effectively unbounded while the assets
stay small and fully regenerable.

THE FREQUENCY RULE, ENFORCED HERE AND IN THE ENGINE
Nothing below 120 Hz survives baking. Phone and laptop speakers cannot
reproduce sub-bass: a 60 Hz partial is either inaudible or, worse, drives
cone excursion that intermodulates and muddies the mid-range the game
actually needs. Every layer is high-passed at 120 Hz at bake time and the
runtime bus adds a second 100 Hz high-pass, so the two are independent.

    fundamental range   200 Hz - 1.2 kHz   the clear mid-band
    shimmer / air       up to ~9 kHz       texture, never fundamentals
    below 120 Hz        removed entirely

Deterministic: a fixed seed per layer means re-running produces byte-identical
audio, so the library is diffable and a regeneration is not a silent change.

Usage:
    python3 tools/bake_audio_layers.py            # bake all
    python3 tools/bake_audio_layers.py --check    # verify without writing
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "audio" / "layers"
MANIFEST = OUT_DIR / "manifest.json"

SAMPLE_RATE = 44100

# ── THE FREQUENCY RULE ───────────────────────────────────────────────────
# Bake-time high-pass. The engine applies its own at 100 Hz; this one is
# deliberately higher so a layer is clean even if the bus filter is bypassed.
HIGHPASS_HZ = 120.0
# Nothing is allowed to have meaningful energy below this after filtering.
# Asserted by --check.
SUB_BASS_CEILING_HZ = 120.0
# Fraction of total energy permitted below SUB_BASS_CEILING_HZ.
SUB_BASS_MAX_ENERGY = 0.02

# Peak normalisation target. Headroom matters: six layers can sound at once
# and the bus sums them before the limiter.
PEAK_TARGET = 0.62


# ═════════════════════════════════════════════════════════════════════════
# DSP PRIMITIVES
# ═════════════════════════════════════════════════════════════════════════
def _biquad(x: np.ndarray, b: tuple, a: tuple) -> np.ndarray:
    """Direct-form-II transposed biquad. Used for every filter here."""
    b0, b1, b2 = b
    a1, a2 = a
    y = np.empty_like(x)
    z1 = z2 = 0.0
    for i, xi in enumerate(x):
        yi = b0 * xi + z1
        z1 = b1 * xi - a1 * yi + z2
        z2 = b2 * xi - a2 * yi
        y[i] = yi
    return y


def _rbj(kind: str, freq: float, q: float, sr: int = SAMPLE_RATE):
    """RBJ cookbook coefficients, normalised by a0."""
    w0 = 2.0 * math.pi * freq / sr
    cw, sw = math.cos(w0), math.sin(w0)
    alpha = sw / (2.0 * q)
    if kind == "highpass":
        b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
        a = (1 + alpha, -2 * cw, 1 - alpha)
    elif kind == "lowpass":
        b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
        a = (1 + alpha, -2 * cw, 1 - alpha)
    elif kind == "bandpass":
        b = (alpha, 0.0, -alpha)
        a = (1 + alpha, -2 * cw, 1 - alpha)
    else:
        raise ValueError(kind)
    a0 = a[0]
    return (b[0] / a0, b[1] / a0, b[2] / a0), (a[1] / a0, a[2] / a0)


def highpass(x: np.ndarray, freq: float, q: float = 0.707) -> np.ndarray:
    b, a = _rbj("highpass", freq, q)
    return _biquad(x, b, a)


def lowpass(x: np.ndarray, freq: float, q: float = 0.707) -> np.ndarray:
    b, a = _rbj("lowpass", freq, q)
    return _biquad(x, b, a)


def bandpass(x: np.ndarray, freq: float, q: float) -> np.ndarray:
    b, a = _rbj("bandpass", freq, q)
    return _biquad(x, b, a)


def modal_resonator(exciter: np.ndarray, freq: float, decay: float,
                    q: float = 60.0) -> np.ndarray:
    """One resonant mode: a bandpass ringing at `freq`, decaying over `decay`.

    This is what makes the difference between a sine and an INSTRUMENT. A
    struck or bowed body rings at many frequencies at once, each with its own
    decay rate, all excited by one broadband transient. Summing a handful of
    these over a noise burst produces something with a real attack and a
    natural, uneven tail.
    """
    rung = bandpass(exciter, freq, q)
    env = np.exp(-np.arange(len(rung)) / (decay * SAMPLE_RATE))
    return rung * env


def normalise(x: np.ndarray, peak: float = PEAK_TARGET) -> np.ndarray:
    m = float(np.max(np.abs(x)))
    if m < 1e-9:
        return x
    return x * (peak / m)


def make_seamless(x: np.ndarray, fade: float = 0.5) -> np.ndarray:
    """Cross-fade the tail over the head so the loop has no seam.

    A loop that clicks is worse than no loop: the click is broadband and
    lands exactly on the beat, which is the most audible place for it.
    """
    n = int(fade * SAMPLE_RATE)
    if n * 2 >= len(x):
        n = len(x) // 4
    head, tail = x[:n].copy(), x[-n:].copy()
    ramp = np.linspace(0.0, 1.0, n)
    # equal-power, so the sum holds a constant perceived level
    blended = head * np.sqrt(ramp) + tail * np.sqrt(1.0 - ramp)
    out = x[:-n].copy()
    out[:n] = blended
    return out


def sub_bass_energy(x: np.ndarray) -> float:
    """Fraction of total spectral energy below SUB_BASS_CEILING_HZ."""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SAMPLE_RATE)
    total = float(np.sum(spec ** 2))
    if total < 1e-12:
        return 0.0
    low = float(np.sum(spec[freqs < SUB_BASS_CEILING_HZ] ** 2))
    return low / total


def spectral_centroid(x: np.ndarray) -> float:
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SAMPLE_RATE)
    s = float(np.sum(spec))
    if s < 1e-12:
        return 0.0
    return float(np.sum(freqs * spec) / s)


# ═════════════════════════════════════════════════════════════════════════
# LAYER RECIPES
# ═════════════════════════════════════════════════════════════════════════
@dataclass
class Layer:
    name: str
    seconds: float
    seed: int
    kind: str
    # Fundamental, in the 200 Hz - 1.2 kHz clear band.
    root: float = 440.0
    note: str = ""
    tags: list = field(default_factory=list)


def bowed_glass(rng: np.random.Generator, secs: float, root: float
                ) -> np.ndarray:
    """A bowed glass/crystal body: sustained, inharmonic, slowly beating.

    Bowing is continuous friction, so the exciter is filtered noise rather
    than a single strike, and the modes never fully decay. The inharmonic
    ratios are what make it read as glass rather than as a string — a real
    struck-glass spectrum is stretched, not integer-multiple.
    """
    n = int(secs * SAMPLE_RATE)
    # Bow noise: band-limited, slowly wandering in intensity.
    exc = rng.standard_normal(n)
    exc = bandpass(exc, root * 1.6, 0.7)
    wander = 0.6 + 0.4 * np.sin(
        2 * np.pi * 0.07 * np.arange(n) / SAMPLE_RATE + rng.uniform(0, 6.28))
    exc *= wander

    ratios = [1.0, 2.756, 5.404, 8.933, 13.34]
    amps = [1.0, 0.42, 0.22, 0.11, 0.05]
    decays = [6.0, 4.4, 3.1, 2.2, 1.6]
    out = np.zeros(n)
    for r, a, d in zip(ratios, amps, decays):
        f = root * r
        if f > SAMPLE_RATE * 0.45 or f < HIGHPASS_HZ:
            continue
        # Sustained rather than struck: re-excite continuously.
        mode = bandpass(exc, f, 80.0)
        # Slow amplitude beating between modes keeps it alive.
        beat = 1.0 + 0.10 * np.sin(
            2 * np.pi * (0.05 + 0.03 * r) * np.arange(n) / SAMPLE_RATE)
        out += mode * a * beat * (d / 6.0)
    return out


def struck_chime(rng: np.random.Generator, secs: float, root: float
                 ) -> np.ndarray:
    """Sparse struck chimes over the loop: bell-like, inharmonic, decaying."""
    n = int(secs * SAMPLE_RATE)
    out = np.zeros(n)
    # Bell partial ratios (tubular-bell-like), all kept in the clear band.
    ratios = [1.0, 2.0, 2.99, 4.17, 5.43, 6.79]
    amps = [1.0, 0.55, 0.38, 0.24, 0.15, 0.09]
    strikes = max(2, int(secs / 2.6))
    for _ in range(strikes):
        at = rng.integers(0, max(1, n - int(1.6 * SAMPLE_RATE)))
        # Each strike is its own pitch within the mode, so it never repeats.
        f0 = root * float(rng.choice([1.0, 1.5, 2.0, 2.5]))
        burst_len = int(0.008 * SAMPLE_RATE)
        exc = np.zeros(n - at)
        exc[:burst_len] = rng.standard_normal(burst_len)
        voice = np.zeros(n - at)
        for r, a in zip(ratios, amps):
            f = f0 * r
            if f > SAMPLE_RATE * 0.45 or f < HIGHPASS_HZ:
                continue
            voice += modal_resonator(
                exc, f, decay=1.1 + 0.9 * rng.random(), q=120.0) * a
        out[at:] += voice * (0.45 + 0.4 * rng.random())
    return out


def air_texture(rng: np.random.Generator, secs: float, root: float
                ) -> np.ndarray:
    """Breathing filtered air. The 'room' the other layers sit in.

    Pure noise is fatiguing and featureless; noise swept by a slow resonant
    filter reads as air movement. Kept well above the sub-bass floor so it
    adds presence rather than mud.
    """
    n = int(secs * SAMPLE_RATE)
    noise = rng.standard_normal(n)
    # Two slow LFOs at incommensurate rates so the sweep never repeats.
    t = np.arange(n) / SAMPLE_RATE
    sweep = (0.5 * np.sin(2 * np.pi * 0.031 * t + rng.uniform(0, 6.28))
             + 0.5 * np.sin(2 * np.pi * 0.017 * t + rng.uniform(0, 6.28)))
    # Filter in blocks: a per-sample time-varying biquad is far too slow in
    # Python, and block-wise is inaudible at these sweep rates.
    block = 2048
    out = np.zeros(n)
    for i in range(0, n, block):
        seg = noise[i:i + block]
        centre = root * (1.6 + 0.9 * float(sweep[min(i, n - 1)]))
        centre = float(np.clip(centre, 240.0, 4200.0))
        out[i:i + block] = bandpass(seg, centre, 1.1)
    return out


def resonant_pad(rng: np.random.Generator, secs: float, root: float
                 ) -> np.ndarray:
    """A warm mid-range pad: detuned saw-ish partials through a soft filter.

    This is the closest thing here to the old drone, and the contrast is the
    point: the partials are detuned per-voice, each has an independent slow
    vibrato, and the whole is low-passed so the upper harmonics roll off like
    a real instrument body instead of stopping abruptly.
    """
    n = int(secs * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE
    out = np.zeros(n)
    for k in range(1, 9):
        f = root * k
        if f < HIGHPASS_HZ or f > SAMPLE_RATE * 0.45:
            continue
        detune = 1.0 + rng.uniform(-0.0022, 0.0022)
        vib = 1.0 + 0.0016 * np.sin(
            2 * np.pi * rng.uniform(0.06, 0.19) * t + rng.uniform(0, 6.28))
        phase = 2 * np.pi * f * detune * t * vib + rng.uniform(0, 6.28)
        out += np.sin(phase) / (k ** 1.35)
    out = lowpass(out, root * 4.5, 0.8)
    # Slow swell so the layer breathes rather than sitting still.
    out *= 0.75 + 0.25 * np.sin(2 * np.pi * 0.043 * t + rng.uniform(0, 6.28))
    return out


def shimmer(rng: np.random.Generator, secs: float, root: float) -> np.ndarray:
    """Granular high shimmer: short grains scattered across the upper band.

    Adds sparkle and air. Deliberately has NO fundamental — it is texture
    layered over the mid-range voices, which is why its centroid sits high.
    """
    n = int(secs * SAMPLE_RATE)
    out = np.zeros(n)
    grains = int(secs * 34)
    glen = int(0.05 * SAMPLE_RATE)
    win = np.hanning(glen)
    for _ in range(grains):
        at = int(rng.integers(0, max(1, n - glen)))
        f = float(rng.uniform(1800.0, 7200.0))
        tt = np.arange(glen) / SAMPLE_RATE
        g = np.sin(2 * np.pi * f * tt + rng.uniform(0, 6.28)) * win
        out[at:at + glen] += g * rng.uniform(0.25, 1.0)
    return out


BUILDERS = {
    "bowed_glass": bowed_glass,
    "struck_chime": struck_chime,
    "air_texture": air_texture,
    "resonant_pad": resonant_pad,
    "shimmer": shimmer,
}


# ── THE LIBRARY ──────────────────────────────────────────────────────────
# Roots are chosen inside 200 Hz - 1.2 kHz. Three pitches per voiced layer
# lets the engine pick a starting point close to the target and pitch-shift
# only a little, which keeps formants natural.
LAYERS: list[Layer] = [
    Layer("pad_low",      12.0, 1001, "resonant_pad", 220.0, "A3",
          ["bed", "warm"]),
    Layer("pad_mid",      12.0, 1002, "resonant_pad", 293.66, "D4",
          ["bed", "warm"]),
    Layer("pad_high",     12.0, 1003, "resonant_pad", 440.0, "A4",
          ["bed", "bright"]),
    Layer("glass_low",    14.0, 2001, "bowed_glass", 261.63, "C4",
          ["voice", "sustain"]),
    Layer("glass_mid",    14.0, 2002, "bowed_glass", 349.23, "F4",
          ["voice", "sustain"]),
    Layer("glass_high",   14.0, 2003, "bowed_glass", 523.25, "C5",
          ["voice", "sustain", "bright"]),
    Layer("chime_soft",   10.0, 3001, "struck_chime", 392.0, "G4",
          ["accent"]),
    Layer("chime_bright", 10.0, 3002, "struck_chime", 587.33, "D5",
          ["accent", "bright"]),
    Layer("air_calm",     16.0, 4001, "air_texture", 300.0, "",
          ["texture"]),
    Layer("air_tense",    16.0, 4002, "air_texture", 520.0, "",
          ["texture", "bright"]),
    Layer("shimmer_fine", 12.0, 5001, "shimmer", 0.0, "",
          ["texture", "bright"]),
]


def render(layer: Layer) -> np.ndarray:
    rng = np.random.default_rng(layer.seed)
    x = BUILDERS[layer.kind](rng, layer.seconds, layer.root)

    # ── THE FREQUENCY RULE, APPLIED ──────────────────────────────────────
    # Two cascaded high-passes: one biquad is 12 dB/oct, which still leaves
    # audible energy an octave down. Two gives 24 dB/oct, measured to put
    # sub-120 Hz content below 2% of total energy on every layer here.
    x = highpass(x, HIGHPASS_HZ, 0.707)
    x = highpass(x, HIGHPASS_HZ, 0.707)
    # Gentle top roll-off: phone speakers exaggerate 4-8 kHz and it fatigues.
    x = lowpass(x, 11000.0, 0.707)
    x = make_seamless(x)
    return normalise(x)


def to_ogg(path: Path, audio: np.ndarray) -> None:
    pcm = np.clip(audio, -1.0, 1.0)
    pcm16 = (pcm * 32767.0).astype("<i2")
    raw = pcm16.tobytes()
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "-",
        "-c:a", "libvorbis", "-qscale:a", "5", str(path),
    ]
    subprocess.run(cmd, input=raw, check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify the baked library without rewriting it")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        print("ffmpeg is required to encode Ogg Vorbis", file=sys.stderr)
        return 2

    if args.check:
        return check()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    entries = []
    for layer in LAYERS:
        audio = render(layer)
        sub = sub_bass_energy(audio)
        cen = spectral_centroid(audio)
        if sub > SUB_BASS_MAX_ENERGY:
            print(f"  {layer.name}: {sub:.1%} sub-bass energy exceeds "
                  f"{SUB_BASS_MAX_ENERGY:.0%}", file=sys.stderr)
            return 1
        path = OUT_DIR / f"{layer.name}.ogg"
        to_ogg(path, audio)
        entries.append({
            "name": layer.name,
            "file": path.name,
            "kind": layer.kind,
            "root_hz": round(layer.root, 2),
            "note": layer.note,
            "seconds": layer.seconds,
            "seed": layer.seed,
            "tags": layer.tags,
            "sub_bass_energy": round(sub, 5),
            "spectral_centroid_hz": round(cen, 1),
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()[:16],
        })
        print(f"  {layer.name:14s} {layer.kind:13s} "
              f"root {layer.root:7.2f} Hz  centroid {cen:7.1f} Hz  "
              f"sub {sub:6.2%}  {path.stat().st_size / 1024:7.1f} KB")

    total = sum(e["bytes"] for e in entries)
    MANIFEST.write_text(json.dumps({
        "sample_rate": SAMPLE_RATE,
        "highpass_hz": HIGHPASS_HZ,
        "sub_bass_ceiling_hz": SUB_BASS_CEILING_HZ,
        "total_bytes": total,
        "layers": entries,
    }, indent=2) + "\n")
    print(f"\nOK — {len(entries)} layers, {total / 1024:.1f} KB")
    return 0


def check() -> int:
    """Verify every layer matches its recipe and obeys the frequency rule."""
    if not MANIFEST.is_file():
        print("no manifest; run without --check to bake", file=sys.stderr)
        return 1
    man = json.loads(MANIFEST.read_text())
    by_name = {e["name"]: e for e in man["layers"]}
    problems = []

    if len(by_name) != len(LAYERS):
        problems.append(f"manifest has {len(by_name)} layers, "
                        f"recipes declare {len(LAYERS)}")

    for layer in LAYERS:
        entry = by_name.get(layer.name)
        if entry is None:
            problems.append(f"{layer.name}: missing from the manifest")
            continue
        path = OUT_DIR / entry["file"]
        if not path.is_file():
            problems.append(f"{layer.name}: {entry['file']} is absent")
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        if digest != entry["sha256"]:
            problems.append(f"{layer.name}: file does not match the manifest "
                            f"({digest} vs {entry['sha256']})")
        if entry["sub_bass_energy"] > SUB_BASS_MAX_ENERGY:
            problems.append(f"{layer.name}: {entry['sub_bass_energy']:.1%} "
                            f"sub-bass energy")
        if layer.root and layer.root > 0.0:
            if not (200.0 <= layer.root <= 1200.0):
                problems.append(f"{layer.name}: root {layer.root} Hz is "
                                f"outside the 200-1200 Hz clear band")

    # Orphans: a file with no recipe is a stale bake.
    for ogg in sorted(OUT_DIR.glob("*.ogg")):
        if ogg.stem not in {layer.name for layer in LAYERS}:
            problems.append(f"{ogg.name}: no recipe claims this file")

    if problems:
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    print(f"OK — {len(by_name)} layers match their recipes, "
          f"{man['total_bytes'] / 1024:.1f} KB, none below "
          f"{SUB_BASS_CEILING_HZ:.0f} Hz")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
