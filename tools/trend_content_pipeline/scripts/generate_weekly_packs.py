#!/usr/bin/env python3
"""Generate the weekly Trend Hub pack set.

Emits `index.json` plus one `packs/pack_<id>.json` per category, in the exact
schema `core/trend_loader.gd` parses.

═══════════════════════════════════════════════════════════════════════════
WHAT THIS DOES AND DOES NOT DO
═══════════════════════════════════════════════════════════════════════════
It produces the pack STRUCTURE — ids, names, unlock tier, difficulty tuning
and a deterministic symbol alphabet. It does NOT write trivia questions, and
the game does not read any.

That is a deliberate constraint, not an unfinished feature:

  * The game is 100% procedural and ships zero content assets. A question bank
    would be the first, and every downstream system (loader, cache, fallback,
    localisation) would then exist to serve it.
  * Trivia about real games, films and music makes factual claims. Anything
    auto-generated here would be unverified by construction, and wrong answers
    in a "witness what you saw" game are indistinguishable from bugs.
  * Naming real franchises pulls third-party trademarks into a Play
    submission.

So a "trend" is a THEME: a name, a palette, a symbol count and a tempo. The
task underneath is the same procedural witness challenge either way.

The topic-fetch and safety-filter stages below are REAL and run on every
generation, but they only influence theme NAMING. Nothing they return is
presented to a player as fact.

═══════════════════════════════════════════════════════════════════════════
DETERMINISM
═══════════════════════════════════════════════════════════════════════════
Given the same ISO week, this script produces byte-identical output. The
weekly seed is the ISO year+week, so a re-run on the same Sunday is a no-op
and the auto-commit step has nothing to push — which is what makes an
accidental double-trigger harmless.

Usage:
    python3 scripts/generate_weekly_packs.py [--out DIR] [--week YYYY-Www]
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys

# ── Schema contract ──────────────────────────────────────────────────────
# Bumped when the shape changes in a way an older client cannot read. The
# loader refuses a mismatch and falls back to bundled data rather than
# guessing at fields it does not recognise.
SCHEMA_VERSION = 1

TOTAL_PACKS = 20
FREE_PACKS = 5

# Difficulty ramp. Mirrors data/trend_registry.gd: the free tier stays in the
# 6-8 symbol range and the paid tier climbs, so an unlock is never a downgrade.
FREE_SYMBOL_RANGE = (6, 8)
PAID_SYMBOL_RANGE = (9, 15)
TEMPO_MAX = 1.00
TEMPO_MIN = 0.75

# ── Safety filtering ─────────────────────────────────────────────────────
# Anything matching these is dropped before it can become a theme name. The
# list is deliberately blunt: a false positive costs one candidate topic out
# of a large pool, a false negative ships a category named after a tragedy.
# NOTE THE TRAILING \w* ON EVERY GROUP. An earlier version used \b...\b and
# "2026 United States elections" sailed through, because the pattern matched
# only the singular "election". Plurals and inflections are the common case in
# real headlines, so each stem matches its whole word family.
BLOCK_STEMS = [
    # news / politics
    "election", "senate", "congress", "parliament", "president", "minister",
    "policy", "politic", "protest", "war", "invasion", "sanction", "tariff",
    "impeach", "campaign", "vote", "ballot", "govern",
    # crime / harm
    "murder", "kill", "shoot", "assault", "abuse", "arrest", "lawsuit",
    "trial", "verdict", "convict", "fraud", "scandal", "die", "died", "death",
    "suicide", "overdose", "victim", "attack", "terror", "crash", "disaster",
    # NSFW
    "nsfw", "porn", "explicit", "nude", "onlyfans", "sexual", "erotic",
    # slurs / hate
    "racist", "racism", "nazi", "slur", "supremac",
    # medical / personal tragedy
    "cancer", "hospital", "illness", "disease", "outbreak", "pandemic",
    "shooting", "famine", "refugee",
]
# \b<stem>\w*  — anchored at the START of a word so "warcraft" is not caught
# by "war", but open at the end so "elections" and "killings" are.
BLOCK_RE = re.compile(
    r"\b(?:" + "|".join(BLOCK_STEMS) + r")\w*",
    re.IGNORECASE)

# Only these characters survive into a theme name. Anything else is a route to
# injecting markup, emoji or control characters into a UI label.
NAME_SAFE_RE = re.compile(r"^[A-Za-z0-9 &'\-]{3,28}$")

# Words that mark a phrase as a THEME rather than a person's name. A topic
# containing any of these is exempt from the person heuristic.
THEME_VOCABULARY = {
    "lore", "myths", "glitches", "culture", "hooks", "moments", "flashes",
    "signals", "relics", "ghosts", "fossils", "legends", "wars", "era",
    "vaults", "archaeology", "cathedral", "static", "media", "boss", "themes",
    "screens", "rooms", "alleys", "dust", "deep", "final", "hidden", "lost",
    "pixel", "arcade", "neon", "cartridge", "loading", "soundtrack",
    "broadcast", "console", "handheld", "studio", "speedrun", "meme", "pop",
    "internet", "gaming", "music", "science", "sports", "screen", "glitch",
}

# ── Popularity ───────────────────────────────────────────────────────────
# A score at or above this is tagged `is_popular` and surfaces in the
# "popular" rail. Derived scores are capped BELOW it, so only categories
# explicitly listed here can be promoted.
POPULAR_THRESHOLD = 70

# Editorial priors for the evergreen set. Deliberately a short list: every
# entry is a claim that this theme performs well, and a long auto-generated
# list would be a claim nobody made.
EVERGREEN_POPULARITY = {
    "Internet Lore": 96,
    "Gaming Myths & Glitches": 93,
    "Pop Culture": 90,
    "Meme Fossils": 88,
    "Speedrun Relics": 85,
    "Boss Themes": 83,
    "Arcade Ghosts": 81,
    "Lost Media": 79,
    "Pixel Archaeology": 77,
    "Glitch Cathedral": 75,
    "Final Boss": 74,
    "Console Wars": 72,
    "Music Hooks": 71,
    "Deep Lore": 70,
}

# ── Fallback topic pool ──────────────────────────────────────────────────
# Used when no network is available, when the fetch fails, or when filtering
# rejects too much. Evergreen, non-factual, franchise-free.
FALLBACK_TOPICS = [
    "Internet Lore", "Gaming Myths & Glitches", "Pop Culture", "Music Hooks",
    "Screen Moments", "Sports Flashes", "Science Signals", "Speedrun Relics",
    "Arcade Ghosts", "Meme Fossils", "Studio Legends", "Console Wars",
    "Handheld Era", "Soundtrack Vaults", "Pixel Archaeology",
    "Glitch Cathedral", "Broadcast Static", "Deep Lore", "Lost Media",
    "Final Boss", "Neon Alleys", "Cartridge Dust", "Loading Screens",
    "Boss Themes", "Hidden Rooms",
]


# Editorially reviewed names, exempt from the stem filter. Every entry here
# is a deliberate human choice; the automated filter guards the fetch path.
CURATED_SAFE = frozenset(FALLBACK_TOPICS) | frozenset(EVERGREEN_POPULARITY)


def iso_week(today: datetime.date | None = None) -> str:
    """The ISO week label that seeds a generation, e.g. '2026-W31'."""
    day = today or datetime.datetime.now(datetime.timezone.utc).date()
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def stable_hash(text: str) -> int:
    """Deterministic 32-bit hash.

    Python's built-in hash() is salted per process, so it would produce a
    different roster on every run and the whole "same week, same packs"
    guarantee would silently fail. blake2b is stable across processes,
    machines and Python versions.
    """
    digest = hashlib.blake2b(text.encode("utf-8"), digest_size=4).digest()
    return int.from_bytes(digest, "big")


def looks_like_a_person(topic: str) -> bool:
    """Heuristic: does this read as an individual's name?

    THE DEFECT THIS FIXES: the stem filter blocks unsafe SUBJECTS but says
    nothing about real PEOPLE, so a live fetch produced categories titled
    "Christopher Nolan", "Andy Burnham" (a serving politician) and
    "Jon-Erik Hexum" (an actor who died in an accident). Naming real
    individuals as game content is a defamation and publicity-rights exposure
    no theme is worth, and it happened on the first real run.

    The heuristic is intentionally blunt: two or three capitalised words with
    no theme vocabulary is far more likely to be a person than a theme, and
    the evergreen pool covers any false positives at zero cost.
    """
    words = topic.split()

    # A bare single capitalised word is unclassifiable: "Shakira" and
    # "Zendaya" are people, "Odyssey" and "Agamemnon" are not, and nothing in
    # the string distinguishes them. The evergreen pool is large enough that
    # rejecting the whole category is free, so single words are only accepted
    # when they carry theme vocabulary.
    if len(words) == 1:
        return words[0].lower() not in THEME_VOCABULARY

    if not 2 <= len(words) <= 3:
        return False

    # A theme word anywhere means it is a concept, not a person.
    if any(word.lower() in THEME_VOCABULARY for word in words):
        return False

    # Every word capitalised, alphabetic, and not an obvious connective.
    for word in words:
        core = word.strip("'-")
        if not core or not core[0].isupper() or not core.replace("'", "").replace("-", "").isalpha():
            return False
    return True


def is_safe_topic(topic: str) -> bool:
    """Reject anything unsuitable as a category name.

    The curated evergreen pool is exempt from the stem filter: those names are
    editorially reviewed, and the filter exists for UNTRUSTED fetched topics.
    Without this exemption "Console Wars" — our own evergreen entry — was
    rejected by the `war` stem and validate() failed on a roster the generator
    had just built itself.
    """
    if not topic or not topic.strip():
        return False
    cleaned = topic.strip()
    if cleaned in CURATED_SAFE:
        return bool(NAME_SAFE_RE.match(cleaned))
    if BLOCK_RE.search(cleaned):
        return False
    if looks_like_a_person(cleaned):
        return False
    return bool(NAME_SAFE_RE.match(cleaned))


def fetch_trending_topics(timeout: float = 10.0) -> list[str]:
    """Fetch candidate entertainment/gaming themes.

    Network access is OPTIONAL by design. This runs in CI where the network
    may be blocked and on a contributor's laptop offline; in both cases it
    returns [] and the caller falls back to the evergreen pool. A pipeline
    that fails closed on a missing network would mean no weekly packs at all.
    """
    try:
        import requests  # imported lazily so the script runs without it
    except ImportError:
        print("note: `requests` unavailable; using the fallback pool")
        return []

    # Wikipedia's most-viewed list: no API key, no personal data, and a
    # licence that permits reuse. Deliberately NOT a social trending feed —
    # those surface exactly the news and tragedy this pipeline must exclude.
    day = datetime.datetime.now(datetime.timezone.utc).date() - datetime.timedelta(days=2)
    url = (
        "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/"
        f"{day.year}/{day.month:02d}/{day.day:02d}"
    )
    try:
        response = requests.get(
            url, timeout=timeout,
            headers={"User-Agent": "2SW-TrendPipeline/1.0 (contact: dev@2sw.local)"},
        )
        if response.status_code != 200:
            print(f"note: fetch returned {response.status_code}; using fallback")
            return []
        payload = response.json()
    except Exception as exc:  # noqa: BLE001 - any failure means "use fallback"
        print(f"note: fetch failed ({exc.__class__.__name__}); using fallback")
        return []

    titles: list[str] = []
    for article in payload.get("mostread", {}).get("articles", []):
        title = str(article.get("titles", {}).get("normalized", "")).strip()
        if title:
            titles.append(title)
    return titles


def build_topic_pool(fetched: list[str]) -> list[str]:
    """Filtered fetch results, topped up from the evergreen pool.

    The fallback is APPENDED rather than used only on total failure, so a
    week where filtering rejects 18 of 20 candidates still yields a complete
    roster instead of a short one.
    """
    safe = [t for t in fetched if is_safe_topic(t)]
    rejected = len(fetched) - len(safe)
    if fetched:
        print(f"safety filter: kept {len(safe)}, rejected {rejected}")

    pool: list[str] = []
    for topic in safe + FALLBACK_TOPICS:
        if topic not in pool:
            pool.append(topic)
    return pool


def build_packs(week: str, pool: list[str]) -> list[dict]:
    """Assemble the ordered pack list for a week."""
    seed = stable_hash(week)

    # Rotate the pool by the weekly seed so the roster changes week to week
    # while staying deterministic within one week.
    if not pool:
        pool = list(FALLBACK_TOPICS)
    offset = seed % len(pool)
    rotated = pool[offset:] + pool[:offset]

    packs: list[dict] = []
    taken: set[str] = set()
    for order in range(TOTAL_PACKS):
        name = rotated[order % len(rotated)]
        free = order < FREE_PACKS

        # Difficulty climbs with display order across each tier.
        if free:
            low, high = FREE_SYMBOL_RANGE
            span = max(FREE_PACKS - 1, 1)
            symbols = low + round((high - low) * order / span)
        else:
            low, high = PAID_SYMBOL_RANGE
            span = max(TOTAL_PACKS - FREE_PACKS - 1, 1)
            symbols = low + round((high - low) * (order - FREE_PACKS) / span)

        tempo = TEMPO_MAX - (TEMPO_MAX - TEMPO_MIN) * (order / max(TOTAL_PACKS - 1, 1))

        pack_id = slug(name, taken)
        taken.add(pack_id)

        packs.append({
            "id": pack_id,
            "name": name,
            "blurb": ("Featured this week. Free to play." if free
                      else "Denser alphabet. Less time to read it."),
            "free": free,
            "order": order,
            "symbols": int(symbols),
            "palette": stable_hash(f"{week}|{name}|palette") % 8,
            "tempo": round(tempo, 2),
            "popularity_score": popularity_for(name),
            "is_popular": popularity_for(name) >= POPULAR_THRESHOLD,
        })
    return packs


def popularity_for(name: str) -> int:
    """Base popularity, 0-100, for a category name.

    Editorial for the evergreen set, derived for everything else. This is the
    PRIOR — a hint about what tends to perform — not a measurement. Actual
    engagement is counted locally per device by TrendRegistry.run_count() and
    weighted against this in TrendLoader.get_popular_categories().

    Derived scores are a stable hash so an unlisted category gets a fixed,
    reproducible value rather than a different one every week. They sit below
    the popular threshold on purpose: a category has to be named here to be
    promoted, so nothing gets featured by hash accident.
    """
    if name in EVERGREEN_POPULARITY:
        return EVERGREEN_POPULARITY[name]
    return stable_hash(f"popularity|{name}") % POPULAR_THRESHOLD


def slug(name: str, taken: set[str] | None = None) -> str:
    """A stable, filesystem- and save-key-safe id, derived ONLY from the name.

    THE BUG THIS FIXES: the id used to embed the display order
    (`trend_07_boss_themes`). But a pack id is ALSO the IrisState rental pack
    id and the save key for best scores and play counts — so "Boss Themes"
    became `trend_12_boss_themes` one week and `trend_14_boss_themes` the
    next, silently orphaning every ad-bought unlock and every score the moment
    the roster rotated. Measured: 18 of 18 shared categories changed id
    between W31 and W32.

    The id is now a pure function of the name, so a category keeps its
    identity for as long as it keeps its name. `taken` disambiguates a genuine
    same-week name collision with a numeric suffix, which is rare and — unlike
    the order — does not change when the roster is reshuffled.
    """
    base = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    # Strip a leading numeric run. An id beginning with digits is
    # indistinguishable from the old order-prefixed scheme, and the validator
    # rejects that shape because it cannot tell "2026" from a display index.
    base = re.sub(r"^\d+_?", "", base) or "pack"
    candidate = f"trend_{base}"[:48]
    if taken is None or candidate not in taken:
        return candidate
    for suffix in range(2, 100):
        alternate = f"{candidate[:44]}_{suffix}"
        if alternate not in taken:
            return alternate
    return candidate


def write_output(out_dir: pathlib.Path, week: str, packs: list[dict]) -> None:
    packs_dir = out_dir / "packs"
    packs_dir.mkdir(parents=True, exist_ok=True)

    # DELIBERATELY NO WALL-CLOCK TIMESTAMP.
    #
    # An earlier version wrote `generated_utc: <now>`, which changed on every
    # run and made the output non-deterministic — defeating the entire "same
    # week, no diff, no commit" design and producing a pointless commit every
    # Sunday. The ISO week IS the provenance, and git already records when the
    # commit happened.
    index = {
        "schema_version": SCHEMA_VERSION,
        "week": week,
        "total": len(packs),
        "free_count": sum(1 for p in packs if p["free"]),
        "packs": [
            {
                "id": p["id"], "name": p["name"], "free": p["free"],
                "order": p["order"], "is_popular": p["is_popular"],
                "popularity_score": p["popularity_score"],
                "file": f"packs/pack_{p['id']}.json",
            }
            for p in packs
        ],
    }

    # Sorted keys and a trailing newline keep the diff stable, so a week with
    # no roster change produces no commit at all.
    (out_dir / "index.json").write_text(
        json.dumps(index, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8")

    # Remove packs from a previous week that are no longer in the roster,
    # otherwise the directory accumulates orphans the index never references.
    current = {f"pack_{p['id']}.json" for p in packs}
    for stale in packs_dir.glob("pack_*.json"):
        if stale.name not in current:
            stale.unlink()

    for pack in packs:
        body = {
            "schema_version": SCHEMA_VERSION,
            "week": week,
            "id": pack["id"],
            "name": pack["name"],
            "blurb": pack["blurb"],
            "free": pack["free"],
            "order": pack["order"],
            "symbols": pack["symbols"],
            "palette": pack["palette"],
            "tempo": pack["tempo"],
            "popularity_score": pack["popularity_score"],
            "is_popular": pack["is_popular"],
        }
        (packs_dir / f"pack_{pack['id']}.json").write_text(
            json.dumps(body, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8")


def validate(packs: list[dict]) -> list[str]:
    """Fail the CI job rather than publishing a roster the game will reject."""
    problems: list[str] = []

    if len(packs) != TOTAL_PACKS:
        problems.append(f"expected {TOTAL_PACKS} packs, built {len(packs)}")

    free = sum(1 for p in packs if p["free"])
    if free != FREE_PACKS:
        problems.append(f"expected {FREE_PACKS} free packs, built {free}")

    ids = [p["id"] for p in packs]
    if len(set(ids)) != len(ids):
        problems.append("duplicate pack ids")

    orders = sorted(p["order"] for p in packs)
    if orders != list(range(len(packs))):
        problems.append("display order is not a dense 0..N-1 run")

    for pack in packs:
        if not is_safe_topic(pack["name"]):
            problems.append(f"{pack['id']}: unsafe name {pack['name']!r}")
        if not 2 <= pack["symbols"] <= 32:
            problems.append(f"{pack['id']}: symbols {pack['symbols']} out of range")
        if not 0.1 <= pack["tempo"] <= 2.0:
            problems.append(f"{pack['id']}: tempo {pack['tempo']} out of range")
        if not 0 <= pack["popularity_score"] <= 100:
            problems.append(
                f"{pack['id']}: popularity {pack['popularity_score']} out of 0-100")
        if pack["is_popular"] != (pack["popularity_score"] >= POPULAR_THRESHOLD):
            problems.append(f"{pack['id']}: is_popular disagrees with the score")
        if "_" in pack["id"][6:] and re.match(r"^trend_\d", pack["id"]):
            problems.append(
                f"{pack['id']}: id embeds a number; ids must be name-derived "
                f"so unlocks survive a roster rotation")

    # The unlock must never be a downgrade.
    hardest_free = max((p["symbols"] for p in packs if p["free"]), default=0)
    easiest_paid = min((p["symbols"] for p in packs if not p["free"]), default=99)
    if hardest_free > easiest_paid:
        problems.append(
            f"a free pack ({hardest_free} symbols) is denser than a paid one "
            f"({easiest_paid})")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent),
                        help="output directory (defaults to the repo root)")
    parser.add_argument("--week", default=None, help="ISO week override, e.g. 2026-W31")
    args = parser.parse_args()

    week = args.week or iso_week()
    out_dir = pathlib.Path(args.out)

    print(f"generating packs for {week}")
    pool = build_topic_pool(fetch_trending_topics())
    packs = build_packs(week, pool)

    problems = validate(packs)
    if problems:
        print("VALIDATION FAILED:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    write_output(out_dir, week, packs)
    print(f"wrote index.json and {len(packs)} pack files to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
