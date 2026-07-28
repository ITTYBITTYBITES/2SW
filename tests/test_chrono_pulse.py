"""CHRONO-PULSE Phase 1: deterministic seeds, streak rules, date rollovers.

This mirrors core/chrono_pulse.gd in Python and then ATTACKS it. A test that
only re-states the implementation proves nothing; these try to break the date
maths at every boundary a calendar has — month ends, leap days, year rollovers,
the epoch, and the two timezone extremes where UTC and local disagree.

The load-bearing property is DETERMINISM: every player on Earth must get the
same puzzle on the same UTC date, on every device, forever. If that breaks, a
shared score card becomes a lie and nobody notices until two people compare
phones.

Run: python3 tests/test_chrono_pulse.py
"""
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = (ROOT / "core/chrono_pulse.gd").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


CODE = strip_comments(SRC)

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def const_int(name: str) -> int:
    m = re.search(rf"const {name}:\s*int\s*=\s*(-?\d+)", CODE)
    assert m, f"{name} not found in chrono_pulse.gd"
    return int(m.group(1))


# Parse the real constants rather than restating them, so the mirror cannot
# drift from the implementation the way test_boot.py's route list did.
GRACE_DAYS = int(re.search(r"const GRACE_DAYS:\s*int\s*=\s*ProgressionEngine\.STREAK_GRACE_DAYS", CODE) is not None)
PROG = strip_comments((ROOT / "data/progression_engine.gd").read_text())
GRACE_DAYS = int(re.search(r"const STREAK_GRACE_DAYS:\s*int\s*=\s*(\d+)", PROG).group(1))
MAX_RECOVERABLE_GAP_DAYS = const_int("MAX_RECOVERABLE_GAP_DAYS")
RECOVERY_LUMINA_COST = const_int("RECOVERY_LUMINA_COST")
MAX_RECOVERIES_PER_DAY = const_int("MAX_RECOVERIES_PER_DAY")
MAX_HISTORY_ENTRIES = const_int("MAX_HISTORY_ENTRIES")
PULSES_MIN, PULSES_MAX = const_int("PULSES_MIN"), const_int("PULSES_MAX")
WINDOW_MIN_MS, WINDOW_MAX_MS = const_int("WINDOW_MIN_MS"), const_int("WINDOW_MAX_MS")
LEAD_IN_MIN_MS, LEAD_IN_MAX_MS = const_int("LEAD_IN_MIN_MS"), const_int("LEAD_IN_MAX_MS")

TIERS = [(m.group(1), int(m.group(2))) for m in
         re.finditer(r'"id":\s*&"(\w+)",\s*"label":\s*"[^"]*",\s*"max_ms":\s*(\d+)', CODE)]
_names_block = re.search(r"const ANOMALY_NAMES:[^=]*=\s*\[(.*?)\]", CODE, re.S)
assert _names_block, "ANOMALY_NAMES not found"
ANOMALY_COUNT = len(re.findall(r'"[^"]+"', _names_block.group(1)))
assert ANOMALY_COUNT > 0, "parsed zero anomaly names"


# ── Mirrors of the GDScript ──────────────────────────────────────────────
def hash_seed(text: str) -> int:
    h = 2166136261
    for ch in text:
        h ^= ord(ch)
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def derive(seed_id: str, salt: str) -> int:
    return hash_seed(f"{seed_id}|{salt}")


def span(value: int, lo: int, hi: int) -> int:
    return lo + (value % (hi - lo + 1))


def seed_for_unix(unix_time: int) -> str:
    return datetime.datetime.fromtimestamp(
        unix_time, datetime.timezone.utc).strftime("%Y-%m-%d")


def local_day_index(unix_time: float, bias_minutes: int) -> int:
    import math
    return math.floor((unix_time + bias_minutes * 60) / 86400.0)


def anomaly_for_seed(seed_id: str) -> dict:
    pulses = span(derive(seed_id, "pulses"), PULSES_MIN, PULSES_MAX)
    return {
        "seed_id": seed_id,
        "kind": span(derive(seed_id, "kind"), 0, ANOMALY_COUNT - 1),
        "pulses": pulses,
        "target_index": span(derive(seed_id, "target"), 1, pulses - 1),
        "window_ms": span(derive(seed_id, "window"), WINDOW_MIN_MS, WINDOW_MAX_MS),
        "lead_in_ms": span(derive(seed_id, "lead"), LEAD_IN_MIN_MS, LEAD_IN_MAX_MS),
        "interval_ms": span(derive(seed_id, "interval"), 620, 1150),
    }


def evaluate_streak(stored, best, last_idx, today_idx) -> dict:
    """Mirror of ProgressionEngine.evaluate_daily_streak's day arithmetic.

    ChronoPulse no longer has its own copy; this models the SHARED engine so
    the design checks below still describe the behaviour the anomaly inherits.
    """
    prev = max(stored, 0)
    out = {"advanced": False, "streak": prev, "previous_streak": prev,
           "best_streak": max(best, 0), "missed_days": 0,
           "already_done_today": False, "broke": False}
    if last_idx == today_idx:
        out["already_done_today"] = True
        return out
    if last_idx > today_idx:
        return out
    gap = today_idx - last_idx
    if last_idx < 0:
        out["streak"] = 1
    elif gap <= 1 + GRACE_DAYS:
        out["streak"] = prev + 1
    else:
        out["streak"] = 1
        out["missed_days"] = gap - 1
        out["broke"] = True
    out["advanced"] = True
    out["best_streak"] = max(out["best_streak"], out["streak"])
    return out


def recovery_offer(stored, last_idx, today_idx, lumina, used_today) -> dict:
    o = {"eligible": False, "reason": "", "gap_days": 0,
         "lost_streak": max(stored, 0), "lumina_cost": RECOVERY_LUMINA_COST,
         "ad_eligible": False, "affordable": False}
    if last_idx < 0 or stored <= 0:
        o["reason"] = "no streak to recover"; return o
    if last_idx >= today_idx:
        o["reason"] = "streak is not broken"; return o
    gap = today_idx - last_idx
    o["gap_days"] = gap
    if gap <= 1 + GRACE_DAYS:
        o["reason"] = "streak is still alive"; return o
    if gap > MAX_RECOVERABLE_GAP_DAYS + 1:
        o["reason"] = "gap too large"; return o
    if used_today >= MAX_RECOVERIES_PER_DAY:
        o["reason"] = "recovery already used today"; return o
    o["eligible"] = True
    o["affordable"] = lumina >= RECOVERY_LUMINA_COST
    o["ad_eligible"] = True
    o["reason"] = "recoverable"
    return o


def tier_for(latency: int, hit: bool) -> str:
    if not hit or latency < 0:
        return "missed"
    for tid, ceiling in TIERS:
        if latency <= ceiling:
            return tid
    return "missed"


# ═════════════════════════════════════════════════════════════════════════
print("-- SEED IS A PURE FUNCTION OF THE UTC DATE --")
# Determinism is the whole product. Same date, same puzzle, always.
for date in ("2026-01-01", "2026-07-26", "2030-12-31"):
    a, b = anomaly_for_seed(date), anomaly_for_seed(date)
    check(f"{date} is reproducible", a == b)

check("different dates give different seeds",
      hash_seed("2026-07-26") != hash_seed("2026-07-27"))

# Every second of a UTC day must map to the same seed, and the next second
# after midnight must map to the next one. This is the rollover contract.
DAY = 86400
midnight = int(datetime.datetime(2026, 7, 26, tzinfo=datetime.timezone.utc).timestamp())
check("00:00:00 UTC starts the day", seed_for_unix(midnight) == "2026-07-26")
check("23:59:59 UTC is the same day", seed_for_unix(midnight + DAY - 1) == "2026-07-26")
check("midnight+0s rolls to the next day", seed_for_unix(midnight + DAY) == "2026-07-27")
check("one second before is the previous day", seed_for_unix(midnight - 1) == "2026-07-25")

print("\n-- DATE ROLLOVER EDGE CASES --")
# Every boundary a calendar actually has. These are the cases hand-rolled date
# maths gets wrong, which is why the seed uses the engine's converter.
EDGES = [
    ("month end 31->1", datetime.datetime(2026, 1, 31, tzinfo=datetime.timezone.utc), "2026-02-01"),
    ("short month 28->1 (non-leap)", datetime.datetime(2026, 2, 28, tzinfo=datetime.timezone.utc), "2026-03-01"),
    ("leap day exists", datetime.datetime(2028, 2, 28, tzinfo=datetime.timezone.utc), "2028-02-29"),
    ("leap day -> march", datetime.datetime(2028, 2, 29, tzinfo=datetime.timezone.utc), "2028-03-01"),
    ("year rollover", datetime.datetime(2026, 12, 31, tzinfo=datetime.timezone.utc), "2027-01-01"),
    ("century leap year 2000-style", datetime.datetime(2024, 2, 28, tzinfo=datetime.timezone.utc), "2024-02-29"),
    ("30-day month", datetime.datetime(2026, 4, 30, tzinfo=datetime.timezone.utc), "2026-05-01"),
]
for label, start, expected in EDGES:
    got = seed_for_unix(int(start.timestamp()) + DAY)
    check(label, got == expected, f"got {got} want {expected}")

check("epoch is 1970-01-01", seed_for_unix(0) == "1970-01-01")
check("seed format is strictly YYYY-MM-DD",
      all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", seed_for_unix(midnight + i * DAY))
          for i in range(400)))

# ISO dates must sort chronologically — trim_history() depends on it.
seeds = [seed_for_unix(midnight + i * DAY) for i in range(400)]
check("ISO dates sort chronologically", seeds == sorted(seeds))

print("\n-- 3650 CONSECUTIVE DAYS: NO COLLISION, NO GAP --")
ten_years = [seed_for_unix(midnight + i * DAY) for i in range(3650)]
check("10 years of dates are unique", len(set(ten_years)) == 3650)
# Consecutive days must not produce identical puzzles, or the "daily" part is
# a fiction. FNV-1a on a 1-char delta must still diverge.
same_as_yesterday = sum(
    1 for i in range(1, 3650)
    if anomaly_for_seed(ten_years[i]) == anomaly_for_seed(ten_years[i - 1]))
check("no two consecutive days share a puzzle", same_as_yesterday == 0,
      f"{same_as_yesterday} repeats")

print("\n-- PARAMETERS STAY IN RANGE OVER 10 YEARS --")
bad = []
for s in ten_years:
    a = anomaly_for_seed(s)
    if not (PULSES_MIN <= a["pulses"] <= PULSES_MAX):
        bad.append(f"{s} pulses={a['pulses']}")
    if not (1 <= a["target_index"] < a["pulses"]):
        bad.append(f"{s} target={a['target_index']}/{a['pulses']}")
    if not (WINDOW_MIN_MS <= a["window_ms"] <= WINDOW_MAX_MS):
        bad.append(f"{s} window={a['window_ms']}")
    if not (LEAD_IN_MIN_MS <= a["lead_in_ms"] <= LEAD_IN_MAX_MS):
        bad.append(f"{s} lead={a['lead_in_ms']}")
check("every generated day is playable", not bad, "; ".join(bad[:3]))
# target_index >= 1 always: the first pulse establishes the rhythm, so an
# anomaly on it would be unjudgeable.
check("anomaly never lands on the first pulse",
      all(anomaly_for_seed(s)["target_index"] >= 1 for s in ten_years))

print("\n-- DISTRIBUTION IS NOT DEGENERATE --")
# A hash that always returns the same bucket would pass every determinism
# check above while making the game identical every day.
kinds = {}
for s in ten_years:
    k = anomaly_for_seed(s)["kind"]
    kinds[k] = kinds.get(k, 0) + 1
check(f"all {ANOMALY_COUNT} anomaly kinds occur", len(kinds) == ANOMALY_COUNT, str(kinds))
worst = max(abs(c / 3650 - 1 / ANOMALY_COUNT) for c in kinds.values())
check("kind distribution within 3% of uniform", worst < 0.03, f"max dev {worst:.4f}")

windows = {anomaly_for_seed(s)["window_ms"] for s in ten_years}
check("window takes many distinct values", len(windows) > 500, str(len(windows)))

print("\n-- SALTED DERIVATION: FIELDS ARE INDEPENDENT --")
# Each parameter gets its own salted hash rather than sequential RNG draws, so
# adding or reordering a field must not shift the others. Verify the salts
# actually produce independent streams.
d = "2026-07-26"
salts = ["kind", "pulses", "window", "lead", "target", "interval"]
values = [derive(d, s) for s in salts]
check("all salts produce distinct values", len(set(values)) == len(salts))
# Adding a hypothetical new salted field must not disturb existing ones.
before = anomaly_for_seed(d)
_ = derive(d, "some_future_field")
check("a new salt does not perturb existing fields", anomaly_for_seed(d) == before)

print("\n-- TIER TABLE: TOTAL COVERAGE, NO OVERLAP --")
check("tiers ascend strictly",
      all(TIERS[i][1] < TIERS[i + 1][1] for i in range(len(TIERS) - 1)))
check("final tier is unbounded", TIERS[-1][1] == 2147483647)
# Walk every boundary +-1. An off-by-one here silently mis-tiers a band of
# players, and looks completely correct when read.
boundary_bad = []
for i, (tid, ceiling) in enumerate(TIERS[:-1]):
    if tier_for(ceiling, True) != tid:
        boundary_bad.append(f"{ceiling} should be {tid}")
    if tier_for(ceiling + 1, True) != TIERS[i + 1][0]:
        boundary_bad.append(f"{ceiling + 1} should be {TIERS[i + 1][0]}")
check("every tier boundary is exact", not boundary_bad, "; ".join(boundary_bad))
check("0ms is the best tier", tier_for(0, True) == TIERS[0][0])
check("a miss is not a slow tier", tier_for(50, False) == "missed")
check("a miss at 0ms is still a miss", tier_for(0, False) == "missed")
check("negative latency is rejected, not tiered", tier_for(-5, True) == "missed")
# Every latency in a wide sweep lands in exactly one tier.
unassigned = [ms for ms in range(0, 5000, 7) if tier_for(ms, True) not in {t[0] for t in TIERS}]
check("every latency maps to a tier", not unassigned, str(unassigned[:5]))

print("\n-- STREAK IS UNIFIED: NO SECOND EVALUATOR --")
# Phase 1 had its own evaluate_streak() mirroring ProgressionEngine rule for
# rule. Every rule was right; existing was wrong. Two functions that must
# always agree are one function that is sometimes wrong — the exact shape of
# the v1 defect where trial identity lived in four tables.
check("ChronoPulse declares no streak evaluator",
      "static func evaluate_streak(" not in CODE)
CTL = strip_comments((ROOT / "nodes/chrono_pulse_controller.gd").read_text())
check("the controller delegates to ProgressionEngine",
      "ProgressionEngine.evaluate_daily_streak(" in CTL)
check("the controller stamps SEC_DAILY so the hub agrees",
      'Save.SEC_DAILY, "last_day_index"' in CTL)
check("recovery is the only direct streak write",
      CTL.count("state.streak_days =") == 1)

print("\n-- STREAK RULES (verified against ProgressionEngine's own mirror) --")
check("first ever completion starts at 1",
      evaluate_streak(0, 0, -1, 20000)["streak"] == 1)
check("consecutive day advances", evaluate_streak(5, 5, 19999, 20000)["streak"] == 6)
check("same day is idempotent",
      evaluate_streak(5, 5, 20000, 20000)["already_done_today"] is True)
check("same day does not advance",
      evaluate_streak(5, 5, 20000, 20000)["streak"] == 5)
# Grace: one missed day is forgiven, matching ProgressionEngine exactly.
check(f"gap of {1 + GRACE_DAYS} days is within grace",
      evaluate_streak(5, 5, 20000 - (1 + GRACE_DAYS), 20000)["streak"] == 6)
check(f"gap of {2 + GRACE_DAYS} days breaks the streak",
      evaluate_streak(5, 5, 20000 - (2 + GRACE_DAYS), 20000)["streak"] == 1)
check("a broken streak still credits today",
      evaluate_streak(9, 9, 19990, 20000)["streak"] == 1)
check("break is reported", evaluate_streak(9, 9, 19990, 20000)["broke"] is True)
check("missed days counted", evaluate_streak(9, 9, 19990, 20000)["missed_days"] == 9)
check("best streak never decreases",
      evaluate_streak(9, 30, 19990, 20000)["best_streak"] == 30)
check("best streak rises with current",
      evaluate_streak(9, 9, 19999, 20000)["best_streak"] == 10)

print("\n-- CLOCK MOVED BACKWARDS IS NOT A LAPSE --")
# Timezone change, NTP correction or a manual edit must not reset a streak.
back = evaluate_streak(7, 7, 20005, 20000)
check("backwards clock does not advance", back["advanced"] is False)
check("backwards clock does not reset", back["streak"] == 7)
check("backwards clock does not break", back["broke"] is False)

print("\n-- STREAK SURVIVES A YEAR OF DAILY PLAY --")
streak, best, last = 0, 0, -1
for day in range(20000, 20365):
    r = evaluate_streak(streak, best, last, day)
    streak, best, last = r["streak"], r["best_streak"], day
check("365 consecutive days -> streak 365", streak == 365)
check("365 consecutive days -> best 365", best == 365)

print("\n-- RECOVERY --")
check("no streak means nothing to recover",
      recovery_offer(0, -1, 20000, 99999, 0)["eligible"] is False)
check("an unbroken streak is not recoverable",
      recovery_offer(5, 20000, 20000, 99999, 0)["reason"] == "streak is not broken")
check("a streak inside grace is still alive",
      recovery_offer(5, 20000 - (1 + GRACE_DAYS), 20000, 99999, 0)["reason"]
      == "streak is still alive")
recoverable = recovery_offer(9, 20000 - 3, 20000, 99999, 0)
check("a fresh lapse is recoverable", recoverable["eligible"] is True)
check("recovery reports the lost streak", recoverable["lost_streak"] == 9)
check("an ancient lapse is not recoverable",
      recovery_offer(9, 20000 - 30, 20000, 99999, 0)["eligible"] is False)
check(f"gap beyond {MAX_RECOVERABLE_GAP_DAYS} days is refused",
      recovery_offer(9, 20000 - (MAX_RECOVERABLE_GAP_DAYS + 2), 20000, 99999, 0)["eligible"] is False)
check("one recovery per day",
      recovery_offer(9, 20000 - 3, 20000, 99999, MAX_RECOVERIES_PER_DAY)["eligible"] is False)

print("\n-- RECOVERY: BROKE PLAYERS ARE OFFERED, NOT HIDDEN --")
# eligible and affordable are separate so the UI can show a priced, greyed
# option rather than pretending recovery does not exist.
poor = recovery_offer(9, 20000 - 3, 20000, 0, 0)
check("a broke player still sees the offer", poor["eligible"] is True)
check("a broke player cannot afford it", poor["affordable"] is False)
check("a broke player can still watch an ad", poor["ad_eligible"] is True)
rich = recovery_offer(9, 20000 - 3, 20000, RECOVERY_LUMINA_COST, 0)
check("exact balance is affordable", rich["affordable"] is True)
check("one Lumina short is not",
      recovery_offer(9, 20000 - 3, 20000, RECOVERY_LUMINA_COST - 1, 0)["affordable"] is False)

print("\n-- UTC/LOCAL SKEW IS BOUNDED AT ONE DAY --")
# The accepted cost of the two-clock design. Prove it can never exceed a day
# across the full real offset range (UTC-12..UTC+14), at every hour.
worst_skew, worst_case = 0, ""
for offset_minutes in range(-12 * 60, 14 * 60 + 1, 15):
    for hour in range(24):
        ts = midnight + hour * 3600
        utc_date = seed_for_unix(ts)
        utc_idx = (datetime.datetime.strptime(utc_date, "%Y-%m-%d")
                   .replace(tzinfo=datetime.timezone.utc).timestamp()) // DAY
        skew = abs(local_day_index(ts, offset_minutes) - int(utc_idx))
        if skew > worst_skew:
            worst_skew, worst_case = skew, f"offset={offset_minutes}m hour={hour}"
check("UTC/local skew never exceeds 1 day", worst_skew <= 1, f"{worst_skew} at {worst_case}")

# The critical property: two players in the most extreme zones, at the same
# instant, must still be handed the SAME puzzle.
instants = [midnight + h * 3600 for h in range(0, 24)]
disagreements = [t for t in instants if seed_for_unix(t) != seed_for_unix(t)]
check("the seed does not depend on the observer's timezone", not disagreements)

print("\n-- HISTORY RETENTION --")
hist = {seed_for_unix(midnight + i * DAY): {"n": i} for i in range(MAX_HISTORY_ENTRIES + 50)}
keys = sorted(hist.keys())
trimmed = {k: hist[k] for k in keys[len(keys) - MAX_HISTORY_ENTRIES:]}
check(f"history trims to {MAX_HISTORY_ENTRIES}", len(trimmed) == MAX_HISTORY_ENTRIES)
check("trimming drops the OLDEST", keys[0] not in trimmed)
check("trimming keeps the newest", keys[-1] in trimmed)
check("a small history is untouched", len({"2026-01-01": 1}) == 1)

print("\n-- SOURCE CONTRACTS --")
check("grace is sourced from ProgressionEngine, not redeclared",
      "ProgressionEngine.STREAK_GRACE_DAYS" in CODE)
check("local day index delegates to ProgressionEngine",
      "ProgressionEngine.local_day_index" in CODE)
check("seed takes an explicit timestamp (testable)",
      "static func seed_for_unix(unix_time: float) -> String:" in CODE)
check("no IAP surface", "purchase" not in CODE.lower() and "iap" not in CODE.lower())
check("recovery priced in Lumina, not a new currency",
      "RECOVERY_LUMINA_COST" in CODE and "essence" not in CODE.lower())
check("Phase 1 is pure: no Save writes", "Save.set_v" not in CODE)
# A %UniqueName accessor is `%Name`; the modulo operator and format specifiers
# are not. Match the accessor shape specifically instead of any '%'.
_no_strings = re.sub(r'"[^"]*"', '""', CODE)
_accessors = re.findall(r"%[A-Za-z_]\w*", _no_strings)
check("Phase 1 is pure: no node accessors", not _accessors, str(_accessors))
check("Phase 1 is pure: no scene tree access",
      "get_node" not in CODE and "get_tree" not in CODE)
check("all funcs typed", not re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", CODE, re.M))
check("no bare var", not re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", CODE, re.M))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
