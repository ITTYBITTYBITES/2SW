#!/usr/bin/env python3
"""Batch-render every authored dialogue line to a voice clip.

WHY THIS IS A SCRIPT AND NOT A FOLDER OF HAND-MADE FILES
--------------------------------------------------------
There are 56 lines across 9 contexts. Recording or downloading them one at a
time is not a task a human should ever do twice, and the moment a line is
reworded the audio silently stops matching the text. This reads the lines
straight out of `data/dialogue_manifest.gd` — the single source of truth — so
regenerating after an edit is one command and the audio cannot drift.

THE MANIFEST IS PARSED, NOT DUPLICATED. A second copy of the script in Python
would be one more thing to keep in sync, and the whole point is that there is
exactly one place the words live.

VOICE PROFILE
    en-US-JennyNeural at --rate=-8% --pitch=-4Hz.

    Jenny is the calmest of the neural US voices; slowing and lowering her
    pulls the delivery off the default assistant cadence into something
    watchful and deliberate, which is what the writing asks for ("I have been
    watching.", "Awake. Both of us."). The modifiers are small on purpose —
    past about -15% the neural model starts to slur.

OUTPUT
    Ogg Vorbis, mono, 22050 Hz, quality 3.

    Matches AudioManager.SAMPLE_RATE so nothing resamples at runtime. Mono
    because a UI voice has no stereo image to preserve, and it halves the
    bytes. Rule F counts every shipped byte against a hard 4 MB cap.

Run:  python3 tools/generate_voice_lines.py
      python3 tools/generate_voice_lines.py --check   (verify, generate nothing)
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = REPO / "data" / "dialogue_manifest.gd"
OUT_DIR = REPO / "audio" / "dialogue"
INDEX = OUT_DIR / "manifest.json"

VOICE = "en-US-JennyNeural"
RATE = "-8%"
PITCH = "-4Hz"

# Match AudioManager.SAMPLE_RATE so the engine never resamples.
SAMPLE_RATE = 22050
CHANNELS = 1
OGG_QUALITY = "3"

# Rule F's cap is 4 MB for ALL shipped binary assets. The art already uses
# 2.79 MB, so the voice pack has to stay well inside what is left.
VOICE_BUDGET_KB = 900.0


def parse_manifest() -> dict[str, list[str]]:
    """Pull the LINES table out of dialogue_manifest.gd.

    Deliberately parses the real file rather than importing a copy: if the
    parse breaks because the table was restructured, that is a signal worth
    stopping for, not something to paper over with a stale duplicate.
    """
    src = MANIFEST.read_text()
    start = src.index("const LINES")
    body = src[start:]
    # The table ends at the first line that is a bare closing brace.
    end = re.search(r"^\}", body, re.M)
    body = body[: end.end()]

    # Context constants are declared above the table as
    #   const HUB_GREET: StringName = &"hub_greet"
    slugs = dict(
        re.findall(r'const (\w+): StringName = &"(\w+)"', src)
    )

    out: dict[str, list[str]] = {}
    for match in re.finditer(r"(\w+):\s*\[(.*?)\n\t\]", body, re.S):
        const_name = match.group(1)
        slug = slugs.get(const_name)
        if slug is None:
            continue
        lines = re.findall(r'"([^"]+)"', match.group(2))
        if lines:
            out[slug] = lines
    return out


def clip_name(slug: str, index: int) -> str:
    return f"{slug}_{index + 1:02d}.ogg"


async def _render(text: str, mp3_path: pathlib.Path) -> None:
    import edge_tts

    speech = edge_tts.Communicate(text, VOICE, rate=RATE, pitch=PITCH)
    await speech.save(str(mp3_path))


def _to_ogg(mp3_path: pathlib.Path, ogg_path: pathlib.Path) -> None:
    """Transcode and normalise in one pass.

    `loudnorm` matters more than it looks: edge-tts returns wildly different
    peak levels for a one-word line and a seven-word one, and without this a
    clipped "Yes." would sit noticeably quieter than "The light finds you
    again." AudioManager mixes voice against a live pad, so an inconsistent
    level reads as a bug.
    """
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(mp3_path),
            # TRIM THE DEAD AIR, THEN NORMALISE.
            #
            # edge-tts pads every clip: measured ~0.22s of leading silence and
            # up to 1.16s trailing on short lines. "Yes." came back as a 1.78s
            # file containing 0.55s of speech. For a UI voice that is a pause
            # after every utterance, and it makes the 1.6s tap cooldown feel
            # far longer than it is.
            #
            # silenceremove at both ends, keeping a 40ms lead-in so the first
            # consonant is never clipped.
            "-af",
            "silenceremove=start_periods=1:start_silence=0.04:"
            "start_threshold=-45dB:detection=peak,"
            "areverse,"
            "silenceremove=start_periods=1:start_silence=0.06:"
            "start_threshold=-45dB:detection=peak,"
            "areverse,"
            "loudnorm=I=-18:TP=-2:LRA=11",
            "-ac", str(CHANNELS),
            "-ar", str(SAMPLE_RATE),
            "-c:a", "libvorbis", "-q:a", OGG_QUALITY,
            str(ogg_path),
        ],
        check=True,
    )


def _duration(path: pathlib.Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


async def generate(contexts: dict[str, list[str]]) -> dict:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path("/tmp/2sw_tts")
    scratch.mkdir(exist_ok=True)

    index: dict = {"voice": VOICE, "rate": RATE, "pitch": PITCH,
                   "sample_rate": SAMPLE_RATE, "contexts": {}}
    total_kb = 0.0

    for slug, lines in sorted(contexts.items()):
        entries = []
        for i, text in enumerate(lines):
            name = clip_name(slug, i)
            ogg = OUT_DIR / name
            mp3 = scratch / f"{slug}_{i}.mp3"

            await _render(text, mp3)
            _to_ogg(mp3, ogg)

            kb = ogg.stat().st_size / 1024
            total_kb += kb
            entries.append({
                "text": text,
                "file": name,
                "seconds": round(_duration(ogg), 3),
                # The hash lets --check prove a clip still matches its line
                # without re-rendering it.
                "text_sha1": hashlib.sha1(text.encode()).hexdigest()[:12],
            })
            print(f"  {name:34s} {kb:6.1f} KB  {entries[-1]['seconds']:5.2f}s"
                  f"  \"{text}\"")
        index["contexts"][slug] = entries

    index["total_kb"] = round(total_kb, 1)
    INDEX.write_text(json.dumps(index, indent=2) + "\n")

    print(f"\n  {len(list(OUT_DIR.glob('*.ogg')))} clips, {total_kb:.1f} KB "
          f"of a {VOICE_BUDGET_KB:.0f} KB allowance")
    if total_kb > VOICE_BUDGET_KB:
        raise SystemExit(
            f"FAIL: the voice pack is {total_kb:.1f} KB, over its allowance")
    return index


def check(contexts: dict[str, list[str]]) -> int:
    """Verify every authored line has a matching clip, and nothing is orphaned.

    This is what stops the audio drifting from the text. Reword a line and its
    hash changes; the check fails and tells you to regenerate.
    """
    if not INDEX.is_file():
        print("FAIL: no manifest.json — run without --check first")
        return 1

    index = json.loads(INDEX.read_text())
    problems: list[str] = []
    expected: set[str] = set()

    for slug, lines in sorted(contexts.items()):
        entries = index["contexts"].get(slug, [])
        if len(entries) != len(lines):
            problems.append(
                f"{slug}: {len(lines)} authored lines but {len(entries)} clips")
            continue
        for i, text in enumerate(lines):
            entry = entries[i]
            expected.add(entry["file"])
            path = OUT_DIR / entry["file"]
            if not path.is_file():
                problems.append(f"{entry['file']}: missing")
                continue
            want = hashlib.sha1(text.encode()).hexdigest()[:12]
            if entry["text_sha1"] != want:
                problems.append(
                    f"{entry['file']}: text changed to \"{text}\" — regenerate")

    for stray in sorted(OUT_DIR.glob("*.ogg")):
        if stray.name not in expected:
            problems.append(f"{stray.name}: orphaned, no line claims it")

    if problems:
        print(f"{len(problems)} PROBLEM(S):")
        for p in problems:
            print("  " + p)
        return 1

    total = sum(f.stat().st_size for f in OUT_DIR.glob("*.ogg")) / 1024
    print(f"OK — {len(expected)} clips match their authored lines, "
          f"{total:.1f} KB")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify existing clips; generate nothing")
    args = parser.parse_args()

    contexts = parse_manifest()
    count = sum(len(v) for v in contexts.values())
    print(f"{len(contexts)} contexts, {count} authored lines")
    if count == 0:
        print("FAIL: parsed no lines from dialogue_manifest.gd")
        return 1

    if args.check:
        return check(contexts)

    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            print(f"FAIL: {tool} is required")
            return 1

    print(f"voice {VOICE} rate={RATE} pitch={PITCH}\n")
    asyncio.run(generate(contexts))
    return check(contexts)


if __name__ == "__main__":
    sys.exit(main())
