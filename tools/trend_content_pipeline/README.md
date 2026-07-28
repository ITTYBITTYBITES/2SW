# Trend content pipeline

Generates the weekly Trend Hub roster: `index.json` plus twenty
`packs/pack_*.json` files, in the schema `core/trend_loader.gd` parses.

## What a "pack" contains

A theme, not a question bank: a name, a symbol-alphabet size, a palette family
and a tempo. The game's witness task is procedural, so a category changes how a
run *looks and reads*, never what is true.

That boundary is deliberate. Authored trivia about real games and media would
mean unverified factual claims and third-party trademarks in a Play
submission, and the project ships zero content assets by rule. The topic fetch
and safety filter below are real and run every week, but they only influence
theme **naming**.

## Layout

```
.github/workflows/generate_trends.yml   Sunday 00:00 UTC + manual dispatch
scripts/generate_weekly_packs.py        fetch -> filter -> build -> write
scripts/validate_output.py              re-reads what landed on disk
index.json, packs/pack_*.json           generated output (committed)
```

## Determinism

Output is a pure function of the ISO week. Re-running on the same Sunday
produces byte-identical files, so `git-auto-commit-action` has nothing to push
and an accidental double-trigger is harmless.

The index deliberately carries **no wall-clock timestamp**. An earlier version
wrote `generated_utc`, which changed every run and pushed a pointless commit
weekly. The ISO week is the provenance; git records the rest.
`validate_output.py` asserts the field stays absent.

## Safety filtering

Candidate topics are rejected on a stem match against news, politics, crime,
NSFW, hate and medical-tragedy vocabulary, then constrained to
`^[A-Za-z0-9 &'-]{3,28}$`.

Stems match **whole word families** (`election` catches `elections`). An
earlier `\belection\b` let *"2026 United States elections"* through. The filter
is intentionally over-eager — `Warcraft` is rejected by the `war` stem, which
costs one candidate from a large pool and is the correct trade.

Filtering only ever *reduces* the pool; the evergreen fallback list tops it
back up to twenty, so a week where everything is rejected still ships a
complete roster.

## Running locally

```bash
python3 scripts/generate_weekly_packs.py --week 2026-W31
python3 scripts/validate_output.py
```

Both work offline: the fetch fails soft to the evergreen pool.

## Consuming it in the game

`core/trend_loader.gd` reads a copy under `res://data/trends/`. **Every**
failure — missing file, bad JSON, wrong schema, a promised pack that is
absent, the wrong free/paid split — falls back to the bundled `TrendRegistry`
roster. `load_roster()` never returns empty, and `last_source()` records which
path was taken.

This loader is filesystem-only. Fetching a roster over HTTP would need a
consent review (a network call is a data flow), a cache, a signature check and
an offline story — none of which exist yet, so pipeline output ships *with*
the build.
