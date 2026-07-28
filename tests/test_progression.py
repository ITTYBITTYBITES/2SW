"""Phase 6 verification: progression engine and Lumina economy loop.

Two halves:
  1. Static analysis of data/progression_engine.gd + nodes/trial_controller.gd
  2. Behavioural simulation of the economy, ported to Python

The economy is where bugs are expensive and silent, so the simulation attacks
it directly: negative inputs, integer overflow at saturation, unbounded
multipliers, double daily claims, clock rewinds, and missed-day resets.

Run: python3 tests/test_progression.py
"""
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENGINE = (ROOT / "data/progression_engine.gd").read_text()
TRIAL = (ROOT / "nodes/trial_controller.gd").read_text()
TSCN = (ROOT / "screens/trial_host.tscn").read_text()
BUS = (ROOT / "core/bus.gd").read_text()

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


def strip_strings(src: str) -> str:
    """Blank string literals so format specifiers (%d) aren't mistaken for
    %UniqueName accessors, and so text can't satisfy a code check."""
    return re.sub(r'"[^"\n]*"', '""', src)


ENGINE_CODE = strip_comments(ENGINE)
TRIAL_CODE = strip_comments(TRIAL)

# ── Constants mirrored from progression_engine.gd ────────────────────────
BRACKET_BASE = [40, 70, 110]
BRACKET_MULT = [1.0, 1.35, 1.8]
BRACKET_XP = [25, 45, 70]
MIN_LUMINA = 5
MAX_AWARD = 1_000_000
MAX_BALANCE = 1_000_000_000_000
RESONANCE_GATE = 0.90
RANK_SCALE, RANK_MAX = 0.06, 1.5
DAILY_BASE, DAILY_STEP, DAILY_MAX = 50, 0.10, 3.0
MILESTONE_DAY, MILESTONE_LUMINA, GRACE = 7, 500, 1
XP_BASE, XP_EXP = 100.0, 1.35


def clampi(v: float, lo: int, hi: int) -> int:
    return max(lo, min(int(v), hi))


def streak_multiplier(days: int) -> float:
    return min(1.0 + max(days, 0) * DAILY_STEP, DAILY_MAX)


def rank_multiplier(rank: int) -> float:
    return min(1.0 + math.log(1.0 + max(rank, 1)) * RANK_SCALE, RANK_MAX)


def lumina_reward(acc: float, bracket: int, streak: int, rank: int) -> int:
    b = clampi(bracket, 0, 2)
    a = max(0.0, min(1.0, acc))
    total = BRACKET_BASE[b] * a * BRACKET_MULT[b] * streak_multiplier(streak) * rank_multiplier(rank)
    return clampi(round(total), MIN_LUMINA, MAX_AWARD)


def xp_reward(acc: float, bracket: int) -> int:
    b = clampi(bracket, 0, 2)
    return clampi(round(BRACKET_XP[b] * max(0.0, min(1.0, acc))), 1, MAX_AWARD)


def resonance_reward(acc: float, bracket: int) -> int:
    return 0 if acc < RESONANCE_GATE else 1 + clampi(bracket, 0, 2)


def daily_lumina(day: int) -> int:
    d = max(day, 1)
    if d % MILESTONE_DAY == 0:
        return MILESTONE_LUMINA
    return clampi(round(DAILY_BASE * streak_multiplier(d - 1)), DAILY_BASE, MAX_AWARD)


def rank_for_xp(xp: int) -> int:
    return 1 if xp <= 0 else 1 + int((xp / XP_BASE) ** (1 / XP_EXP))


class Sim:
    def __init__(self) -> None:
        self.lumina = 0
        self.rank_xp = 0
        self.rank_tier = 1
        self.streak = 0


def award_lumina(s: Sim, amount: int) -> int:
    if amount < 0:
        return 0
    amount = clampi(amount, 0, MAX_AWARD)
    before = s.lumina
    s.lumina = clampi(s.lumina + amount, 0, MAX_BALANCE)
    return s.lumina - before


def add_xp(s: Sim, amount: int) -> int:
    if amount < 0:
        return 0
    amount = clampi(amount, 0, MAX_AWARD)
    before = s.rank_tier
    s.rank_xp = clampi(s.rank_xp + amount, 0, MAX_BALANCE)
    s.rank_tier = max(rank_for_xp(s.rank_xp), 1)
    return s.rank_tier - before


def evaluate_daily(s: Sim, last_day: int, today: int) -> dict:
    if last_day == today:
        return {"claimed": False, "streak": s.streak}
    if last_day > today:
        return {"claimed": False, "streak": s.streak, "backwards": True}
    gap = today - last_day
    prev = s.streak
    if last_day < 0:
        s.streak = 1
    elif gap <= 1 + GRACE:
        s.streak = prev + 1
    else:
        s.streak = 1
    payout = daily_lumina(s.streak)
    award_lumina(s, payout)
    return {"claimed": True, "streak": s.streak, "lumina": payout,
            "milestone": s.streak % MILESTONE_DAY == 0}


# ═══════════════════════════════════════════════════════════════════════
print("── ENGINE IS PURE LOGIC (no nodes, no persistence) ──")
check("extends RefCounted", "extends RefCounted" in ENGINE)
check("no Save calls", re.search(r"\bSave\.", ENGINE_CODE) is None)
check("no Router calls", "Router." not in ENGINE_CODE)
# %UniqueName is an identifier; bare % is the modulo operator. Match only the
# accessor form so `streak_days % 7` is not flagged.
check("no $Node accessors", "$" not in ENGINE_CODE)
check("no %UniqueName accessors",
      re.search(r"%[A-Za-z_]\w*", strip_strings(ENGINE_CODE)) is None)
check("no scene loads", "load(" not in ENGINE_CODE)

print("\n── REQUIRED API ──")
for fn in ("add_rank_xp", "award_lumina", "evaluate_daily_streak",
           "compute_lumina_reward", "compute_xp_reward", "settle_trial",
           "streak_multiplier", "rank_bonus_multiplier"):
    check(f"{fn}()", f"func {fn}(" in ENGINE_CODE)

print("\n── SAFETY RAILS DECLARED ──")
for const in ("MAX_SAFE_AWARD", "MAX_BALANCE", "MIN_LUMINA_AWARD",
              "DAILY_MAX_MULTIPLIER", "RANK_BONUS_MAX"):
    check(f"const {const}", f"const {const}" in ENGINE_CODE)
check("negative XP guarded", "cannot grant negative XP" in ENGINE)
check("negative Lumina guarded", "cannot award negative Lumina" in ENGINE)

print("\n── NEGATIVE INPUTS REJECTED ──")
s = Sim()
s.lumina = 100
check("negative award credits 0", award_lumina(s, -500) == 0)
check("balance untouched", s.lumina == 100)
check("negative XP grants no rank", add_xp(s, -999) == 0)
for bracket in (-5, 0, 1, 2, 99):
    check(f"bracket {bracket} clamps", MIN_LUMINA <= lumina_reward(1.0, bracket, 0, 1) <= MAX_AWARD)
for acc in (-1.0, 0.0, 0.5, 1.0, 99.0):
    check(f"accuracy {acc} bounded", MIN_LUMINA <= lumina_reward(acc, 2, 0, 1) <= MAX_AWARD)

print("\n── NO OVERFLOW AT EXTREMES ──")
worst = lumina_reward(1.0, 2, 10_000, 10**6)
check("worst-case reward bounded", worst <= MAX_AWARD, str(worst))
print(f"    worst case (acc 1.0, bracket 2, streak 10k, rank 1M): {worst:,} ✦")
s = Sim()
s.lumina = MAX_BALANCE - 10
check("credits only up to the ceiling", award_lumina(s, MAX_AWARD) == 10)
check("balance sits at ceiling", s.lumina == MAX_BALANCE)
check("further awards credit nothing", award_lumina(s, 1000) == 0)
s = Sim()
for _ in range(2000):
    award_lumina(s, MAX_AWARD)
check("2000 max awards stay in range", 0 <= s.lumina <= MAX_BALANCE)
check("balance never negative", s.lumina >= 0)

print("\n── MULTIPLIERS CAP CORRECTLY ──")
for days, expected in ((0, 1.0), (5, 1.5), (10, 2.0), (20, 3.0), (100, 3.0), (10**6, 3.0)):
    check(f"streak {days}d -> {expected}x", abs(streak_multiplier(days) - expected) < 1e-9)
for rank in (1, 1000, 10**6):
    check(f"rank {rank} bonus <= {RANK_MAX}", rank_multiplier(rank) <= RANK_MAX + 1e-9)
print(f"    rank bonus: 1 -> {rank_multiplier(1):.3f}   1k -> {rank_multiplier(1000):.3f}   1M -> {rank_multiplier(10**6):.3f}")

print("\n── MINIMUM PAYOUT ──")
check("0% accuracy still pays minimum", lumina_reward(0.0, 0, 0, 1) == MIN_LUMINA)
check("XP is always at least 1", xp_reward(0.0, 0) >= 1)

print("\n── RESONANCE ACCURACY GATE ──")
for acc, expected in ((0.0, 0), (0.5, 0), (0.89, 0), (0.90, 1), (1.0, 1)):
    check(f"accuracy {acc} -> {expected}", resonance_reward(acc, 0) == expected)
check("bracket weights resonance", resonance_reward(1.0, 2) == 3)

print("\n── DAILY STREAK ACROSS DAY BOUNDARIES ──")
s = Sim()
check("first claim starts at day 1", evaluate_daily(s, -1, 1000)["streak"] == 1)
check("same-day repeat is not claimable", not evaluate_daily(s, 1000, 1000)["claimed"])
check("streak unchanged on repeat", s.streak == 1)
check("next day advances streak", evaluate_daily(s, 1000, 1001)["streak"] == 2)
check("gap of 2 stays within grace", evaluate_daily(s, 1001, 1003)["streak"] == 3)
check("gap of 7 resets to day 1", evaluate_daily(s, 1003, 1010)["streak"] == 1)

s2 = Sim()
s2.streak = 5
check("grace boundary (gap 2) continues", evaluate_daily(s2, 2000, 2002)["streak"] == 6)
s3 = Sim()
s3.streak = 5
check("gap of 3 breaks the streak", evaluate_daily(s3, 2000, 2003)["streak"] == 1)

print("\n── CLOCK REWIND IS SAFE ──")
s4 = Sim()
s4.streak = 4
result = evaluate_daily(s4, 5000, 4999)
check("no claim when clock moves back", not result["claimed"])
check("streak is NOT reset by a rewind", s4.streak == 4)

print("\n── 30-DAY UNBROKEN STREAK ──")
s = Sim()
last = -1
total = 0
milestones: list[int] = []
for day in range(30):
    r = evaluate_daily(s, last, 1000 + day)
    last = 1000 + day
    total += r.get("lumina", 0)
    if r.get("milestone"):
        milestones.append(s.streak)
check("streak reaches 30", s.streak == 30)
check("milestones at 7/14/21/28", milestones == [7, 14, 21, 28], str(milestones))
check("payout total matches balance", total == s.lumina)
print(f"    30 unbroken days -> {total:,} ✦, milestones {milestones}")
check("day 1 pays base", daily_lumina(1) == DAILY_BASE)
check("day 7 pays milestone", daily_lumina(7) == MILESTONE_LUMINA)
check("daily never below base", all(daily_lumina(d) >= DAILY_BASE for d in range(1, 200)))

print("\n── XP -> RANK ──")
s = Sim()
check("zero XP grants no rank", add_xp(s, 0) == 0 and s.rank_tier == 1)
s = Sim()
add_xp(s, 100)
check("100 xp reaches rank 2", s.rank_tier == 2)
s = Sim()
add_xp(s, 126_898)
check("126,898 xp reaches rank 200", s.rank_tier == 200)
check("no cap at rank 200", rank_for_xp(200_000) > 200)
s = Sim()
previous, monotonic = 1, True
for _ in range(500):
    add_xp(s, xp_reward(0.85, 1))
    if s.rank_tier < previous:
        monotonic = False
    previous = s.rank_tier
check("rank never decreases", monotonic)
print(f"    500 trials @85% bracket 1 -> rank {s.rank_tier}, {s.rank_xp:,} xp")

print("\n── FULL LOOP SANITY ──")
s = Sim()
s.streak = 7
for i in range(200):
    acc = 0.5 + (i % 50) / 100.0
    award_lumina(s, lumina_reward(acc, i % 3, s.streak, s.rank_tier))
    add_xp(s, xp_reward(acc, i % 3))
check("balance positive and bounded", 0 < s.lumina <= MAX_BALANCE)
check("rank advanced", s.rank_tier > 1)
check("can afford the cheapest cosmetic (70)", s.lumina >= 70)
print(f"    200 mixed trials -> {s.lumina:,} ✦, rank {s.rank_tier}")

# ═══════════════════════════════════════════════════════════════════════
print("\n── TRIAL CONTROLLER: settlement is atomic ──")
check("_settled guard exists", "_settled" in TRIAL_CODE)
check("double settle is refused", "settle called twice" in TRIAL)
check("single settlement path", TRIAL_CODE.count("ProgressionEngine.settle_trial") == 1)
check("single Save write", TRIAL_CODE.count("Save.set_v") == 1)
check("phase machine present", "enum Phase" in TRIAL_CODE)

print("\n── TRIAL CONTROLLER: v1 bugs stay fixed ──")
check("back is intercepted mid-run", "func on_back_requested()" in TRIAL_CODE)
check("forfeit confirmation shown", "_confirm_forfeit.popup_centered()" in TRIAL_CODE)
check("no change_scene_to_*", "change_scene" not in TRIAL_CODE)
check("navigates via Router", "Router.go(" in TRIAL_CODE)
check("monotonic clock, not wall clock", "Time.get_ticks_msec()" in TRIAL_CODE)
check("no silent neutral-score fallback", "0.5" not in TRIAL_CODE.split("FORFEIT_ACCURACY_FACTOR")[-1][:200])
check("zero attempts cannot divide by zero", "_attempted <= 0" in TRIAL_CODE)

print("\n── BUS CONTRACT ──")
check("trial_completed declared", "signal trial_completed(" in BUS)
check("controller emits it", "Bus.trial_completed.emit" in TRIAL_CODE)
for sig in ("trial_started", "trial_finished", "trial_forfeited"):
    check(f"emits {sig}", f"Bus.{sig}.emit" in TRIAL_CODE)

print("\n── SCENE WIRING ──")
for node in ("Background", "TitleLabel", "ScoreLabel", "TimerLabel",
             "FinishButton", "ConfirmForfeit"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, TSCN) is not None)

print("\n── TYPING ──")
for name, code in (("engine", ENGINE_CODE), ("trial", TRIAL_CODE)):
    untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", code, re.M)
    check(f"{name}: all funcs typed", not untyped, str(untyped))
    bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", code, re.M)
    check(f"{name}: no bare var", not bare, str(bare))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
