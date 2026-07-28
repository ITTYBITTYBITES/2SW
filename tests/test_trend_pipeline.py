"""Trend content pipeline: safety filtering and id stability.

Both properties here are REGRESSIONS. Each shipped as a real defect into
generated data before this file existed:

  1. Pack ids embedded the display order, so a category's id changed whenever
     the roster rotated. An id is also the IrisState rental pack id and the
     save key for scores, so every ad-bought unlock was silently orphaned
     every Sunday. Measured: 18 of 18 shared categories drifted W31 -> W32.

  2. The safety filter blocked unsafe SUBJECTS but not real PEOPLE. A live
     fetch produced categories titled "Christopher Nolan", "Andy Burnham" (a
     serving politician) and "Jon-Erik Hexum" (an actor who died in an
     accident), plus single-word names like "Shakira" and "Zendaya".

Run: python3 tests/test_trend_pipeline.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools/trend_content_pipeline/scripts"))

from generate_weekly_packs import (  # noqa: E402
    POPULAR_THRESHOLD, TOTAL_PACKS, FREE_PACKS,
    build_packs, build_topic_pool, is_safe_topic, popularity_for, slug,
    validate,
)

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


print("-- REGRESSION: real people must never become categories --")
# Every one of these came out of an actual fetch.
PEOPLE = [
    "Christopher Nolan", "Andy Burnham", "Lamine Yamal", "Jon-Erik Hexum",
    "Dharmendra Pradhan", "Kaylee Hottle", "Jana Nayagan",
    "Shakira", "Zendaya", "Agamemnon", "Odysseus",
]
for person in PEOPLE:
    check(f"rejects {person!r}", not is_safe_topic(person))

print("\n-- themes still pass --")
THEMES = [
    "Boss Themes", "Deep Lore", "Lost Media", "Pop Culture", "Neon Alleys",
    "Glitch Cathedral", "Cartridge Dust", "Hidden Rooms", "Internet Lore",
    "Gaming Myths & Glitches", "Pixel Archaeology", "Speedrun Relics",
]
for theme in THEMES:
    check(f"accepts {theme!r}", is_safe_topic(theme))

print("\n-- unsafe subjects --")
UNSAFE = [
    "2026 United States elections",   # plural slipped \belection\b
    "Election night", "Killings report", "War films", "Murder trial",
    "NSFW artist", "Cancer treatment", "<script>alert(1)</script>", "", "a",
]
for topic in UNSAFE:
    check(f"rejects {topic!r}", not is_safe_topic(topic))

print("\n-- REGRESSION: ids must survive a roster rotation --")
pool = build_topic_pool([])
weeks = {w: {p["name"]: p["id"] for p in build_packs(w, pool)}
         for w in ("2026-W31", "2026-W32", "2026-W40", "2027-W03")}

labels = sorted(weeks)
drift: list[str] = []
for i in range(len(labels) - 1):
    a, b = weeks[labels[i]], weeks[labels[i + 1]]
    for name in set(a) & set(b):
        if a[name] != b[name]:
            drift.append(f"{name}: {a[name]} != {b[name]}")
check("a category keeps its id across every week", not drift, "; ".join(drift[:3]))

# An id starting with digits is indistinguishable from the old order prefix.
numeric = [i for w in weeks.values() for i in w.values()
           if i.removeprefix("trend_")[:1].isdigit()]
check("no id begins with a number", not numeric, str(numeric[:3]))

print("\n-- roster shape --")
for label in labels:
    packs = build_packs(label, pool)
    check(f"{label} builds {TOTAL_PACKS} packs", len(packs) == TOTAL_PACKS)
    check(f"{label} has {FREE_PACKS} free", sum(1 for p in packs if p["free"]) == FREE_PACKS)
    check(f"{label} validates", not validate(packs), str(validate(packs))[:120])
    check(f"{label} ids are unique",
          len({p["id"] for p in packs}) == len(packs))

print("-- registry ids follow the generator's naming rule --")
# A pack id is an IrisState rental pack id AND a save key. If the bundled
# registry and the generator disagree about the id for the same display name,
# a pass bought under one roster silently fails to resolve under the other.
# Found in exactly that way: `trend_gaming_myths` vs
# `trend_gaming_myths_glitches` for "Gaming Myths & Glitches".
import re as _re  # noqa: E402
REGISTRY = (ROOT / "data/trend_registry.gd").read_text()
pairs = _re.findall(r'"(trend_[a-z0-9_]+)": \{\s*\n\s*"name": "([^"]+)"', REGISTRY)
check("the registry declares categories", len(pairs) == 20, str(len(pairs)))
mismatched = [f"{cur} != {slug(name)}" for cur, name in pairs if cur != slug(name)]
check("every registry id matches the generator slug", not mismatched,
      "; ".join(mismatched[:3]))

print("\n-- popularity --")
check("an evergreen theme scores high", popularity_for("Internet Lore") >= POPULAR_THRESHOLD)
check("an unlisted theme scores below the threshold",
      popularity_for("Some Unlisted Theme") < POPULAR_THRESHOLD)
check("derived scores are deterministic",
      popularity_for("Some Unlisted Theme") == popularity_for("Some Unlisted Theme"))
check("every score is in range",
      all(0 <= popularity_for(n) <= 100 for n in THEMES + ["Unlisted"]))
# is_popular must be derived, never independent of the score.
for pack in build_packs("2026-W31", pool):
    if pack["is_popular"] != (pack["popularity_score"] >= POPULAR_THRESHOLD):
        check(f"{pack['id']} flag matches its score", False)
        break
else:
    check("is_popular always matches the score", True)

print("\n-- determinism --")
check("the same week builds identically",
      build_packs("2026-W31", pool) == build_packs("2026-W31", pool))
check("different weeks differ",
      build_packs("2026-W31", pool) != build_packs("2026-W32", pool))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
