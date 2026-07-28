#!/usr/bin/env python3
"""Validate generated pack files ON DISK.

Run as a separate CI step after generation, deliberately re-reading the files
rather than trusting the generator's in-memory view. A truncated write, a bad
output path or a stale orphan would otherwise be committed and only surface
later — on a player's device, where there is no log to read.

This is also the schema contract the Godot loader is tested against, so a
change here that the loader does not understand fails in CI rather than in
the field.

Exit 0 when the roster is publishable.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_VERSION = 1
TOTAL_PACKS = 20
FREE_PACKS = 5

# Every field the game reads. A pack missing any of these is unusable, and the
# loader must never have to guess a default for something the pipeline owns.
REQUIRED_PACK_FIELDS = {
    "schema_version", "week", "id", "name", "blurb",
    "free", "order", "symbols", "palette", "tempo",
    "popularity_score", "is_popular",
}
# Name-derived only. An id that embeds the display order changes when the
# roster rotates, and the id is ALSO the rental pack id and the save key — so
# an order-based id silently orphans every ad-bought unlock and every score.
ID_RE = re.compile(r"^trend_(?!\d)[a-z0-9_]+$")
POPULAR_THRESHOLD = 70


def fail(problems: list[str]) -> int:
    print(f"VALIDATION FAILED ({len(problems)} problem(s)):")
    for problem in problems:
        print(f"  - {problem}")
    return 1


def main() -> int:
    problems: list[str] = []

    index_path = ROOT / "index.json"
    if not index_path.exists():
        return fail(["index.json is missing"])

    try:
        index = json.loads(index_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return fail([f"index.json is not valid JSON: {exc}"])

    if int(index.get("schema_version", -1)) != SCHEMA_VERSION:
        problems.append(
            f"index schema_version {index.get('schema_version')} != {SCHEMA_VERSION}")

    # A wall-clock timestamp here would make every run a fresh diff and push a
    # commit weekly even when the roster is unchanged. Asserted so it cannot
    # be reintroduced.
    if "generated_utc" in index:
        problems.append(
            "index carries a wall-clock timestamp; output must be deterministic")

    entries = index.get("packs", [])
    if len(entries) != TOTAL_PACKS:
        problems.append(f"index lists {len(entries)} packs, expected {TOTAL_PACKS}")

    seen_ids: set[str] = set()
    seen_orders: list[int] = []
    free_count = 0

    for entry in entries:
        pack_id = str(entry.get("id", ""))
        if not ID_RE.match(pack_id):
            problems.append(f"malformed pack id {pack_id!r}")
        if pack_id in seen_ids:
            problems.append(f"duplicate pack id {pack_id!r}")
        seen_ids.add(pack_id)

        pack_path = ROOT / str(entry.get("file", ""))
        if not pack_path.exists():
            problems.append(f"{pack_id}: index references a missing file")
            continue

        try:
            pack = json.loads(pack_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append(f"{pack_id}: invalid JSON ({exc})")
            continue

        missing = REQUIRED_PACK_FIELDS - set(pack)
        if missing:
            problems.append(f"{pack_id}: missing fields {sorted(missing)}")
            continue

        # The index and the pack file must agree. A disagreement means one of
        # them was written from stale state, and the game would show a name or
        # tier that does not match what it loads.
        for field in ("id", "name", "free", "order"):
            if pack[field] != entry.get(field, pack[field]):
                problems.append(
                    f"{pack_id}: index/{field} disagrees with the pack file")

        if int(pack["schema_version"]) != SCHEMA_VERSION:
            problems.append(f"{pack_id}: wrong schema_version")
        if not 2 <= int(pack["symbols"]) <= 32:
            problems.append(f"{pack_id}: symbols {pack['symbols']} out of range")
        if not 0.1 <= float(pack["tempo"]) <= 2.0:
            problems.append(f"{pack_id}: tempo {pack['tempo']} out of range")
        if not 0 <= int(pack["palette"]) <= 63:
            problems.append(f"{pack_id}: palette {pack['palette']} out of range")

        score = int(pack["popularity_score"])
        if not 0 <= score <= 100:
            problems.append(f"{pack_id}: popularity {score} outside 0-100")
        if bool(pack["is_popular"]) != (score >= POPULAR_THRESHOLD):
            problems.append(
                f"{pack_id}: is_popular={pack['is_popular']} disagrees with "
                f"score {score} (threshold {POPULAR_THRESHOLD})")

        seen_orders.append(int(pack["order"]))
        if bool(pack["free"]):
            free_count += 1

    if free_count != FREE_PACKS:
        problems.append(f"{free_count} free packs, expected {FREE_PACKS}")

    if sorted(seen_orders) != list(range(len(entries))):
        problems.append("display order is not a dense 0..N-1 run")

    # No orphans: a pack file the index does not reference is dead weight that
    # a future reader will mistake for live content.
    referenced = {ROOT / str(e.get("file", "")) for e in entries}
    for found in (ROOT / "packs").glob("pack_*.json"):
        if found not in referenced:
            problems.append(f"orphan pack file not in the index: {found.name}")

    if problems:
        return fail(problems)

    print(f"OK — {len(entries)} packs, {free_count} free, schema v{SCHEMA_VERSION}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
