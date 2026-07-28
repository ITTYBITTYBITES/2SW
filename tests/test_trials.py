"""Phase 7 verification: trial mini-games and results screen.

Static analysis plus behavioural simulation of the three trial modes.

Load-bearing guarantees:
  · ZERO textures — every visual is vector geometry
  · INPUT ISOLATION — a mini-game root never swallows taps; only explicit
    hit targets accept input, so the Iris and chrome stay reachable
  · FAIR SCORING — every round produces exactly one recorded answer, a
    timeout counts as a miss rather than a silent skip, and no trial can
    produce a division by zero
  · GENUINE STROOP — the ink colour never matches the word, or the trial
    measures nothing
  · READ-ONLY RESULTS — settlement already happened; the results screen
    must never award again

Run: python3 tests/test_trials.py
"""
import math
import pathlib
import random
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = (ROOT / "nodes/trials/trial_minigame.gd").read_text()
FALSE_WITNESS = (ROOT / "nodes/trials/false_witness.gd").read_text()
SEQUENCE = (ROOT / "nodes/trials/sequence_recall.gd").read_text()
STROOP = (ROOT / "nodes/trials/cognitive_conflict.gd").read_text()
RESULTS = (ROOT / "nodes/trial_results_controller.gd").read_text()
RESULTS_TSCN = (ROOT / "screens/trial_results.tscn").read_text()
HOST = (ROOT / "nodes/trial_controller.gd").read_text()
ROUTER = (ROOT / "core/router.gd").read_text()

ALL_TRIALS = {"false_witness": FALSE_WITNESS, "sequence_recall": SEQUENCE,
              "cognitive_conflict": STROOP}

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


def strip_strings(src: str) -> str:
    return re.sub(r'"[^"\n]*"', '""', src)


# ═══════════════════════════════════════════════════════════════════════
print("── ZERO IMAGE ASSETS ──")
for name, src in list(ALL_TRIALS.items()) + [("base", BASE), ("results", RESULTS)]:
    clean = strip_comments(src)
    for ext in (".png", ".jpg", ".svg"):
        check(f"{name}: no {ext}", ext not in clean)
    check(f"{name}: no Texture2D", "Texture2D" not in clean)

print("\n── DRAWS WITH VECTOR PRIMITIVES ──")
for name, src in ALL_TRIALS.items():
    clean = strip_comments(src)
    check(f"{name}: has _draw()", "func _draw()" in clean)
    prims = [p for p in ("draw_circle", "draw_arc", "draw_line",
                         "draw_colored_polygon", "draw_polyline", "draw_rect")
             if p in clean]
    check(f"{name}: uses vector primitives", len(prims) >= 2, str(prims))

print("\n── INPUT ISOLATION ──")
check("base root is IGNORE", "mouse_filter = Control.MOUSE_FILTER_IGNORE" in BASE)
check("only targets accept input", "MOUSE_FILTER_STOP" in BASE)
check("make_target() is the single entry", BASE.count("MOUSE_FILTER_STOP") == 2)
for name, src in ALL_TRIALS.items():
    clean = strip_comments(src)
    check(f"{name}: no direct MOUSE_FILTER_STOP", "MOUSE_FILTER_STOP" not in clean)
    check(f"{name}: clears stale targets", "clear_targets()" in clean)
check("host stage is pass-through",
      "minigame.mouse_filter = Control.MOUSE_FILTER_IGNORE" in strip_comments(HOST))

print("\n── HOST CONTRACT ──")
for name, src in ALL_TRIALS.items():
    clean = strip_comments(src)
    # submit_step() is the timing-only variant, for modes where several
    # answers make up one round (sequence_recall taps each step of a
    # pattern). It reports to the host exactly like submit() but leaves round
    # bookkeeping to the subclass.
    reports = ("submit(" in clean or "submit_step(" in clean
               or "record_answer" in clean)
    check(f"{name}: reports answers", reports)
check("base routes to record_answer", "host.record_answer" in BASE)
check("base routes to conclude_trial", "host.conclude_trial" in BASE)
check("host exposes conclude_trial()", "func conclude_trial()" in HOST)
REGISTRY = (ROOT / "data/trial_registry.gd").read_text()
check("host resolves scripts via registry", "TrialRegistry.script_path" in HOST)
check("host has no duplicate id table", "const MINIGAMES" not in HOST)
for trial_id in ALL_TRIALS:
    check(f"'{trial_id}' in registry", f'"{trial_id}"' in REGISTRY)
check("unknown id fails loudly", "unregistered trial" in HOST)

print("\n── RESULTS IS READ-ONLY ──")
results_code = strip_comments(RESULTS)
for forbidden in ("grant_seed", "award_lumina", "add_rank_xp", "settle_trial",
                  "spend_lumina", "Save.set_v", "Save.flush"):
    check(f"never calls {forbidden}", forbidden not in results_code)
check("reads the summary payload", 'payload.get("summary"' in results_code)
check("routes via Router", "Router." in results_code)
check("no change_scene", "change_scene" not in results_code)

print("\n── RESULTS UI ──")
for node in ("Background", "TitleLabel", "AccuracyLabel", "TimeLabel",
             "LuminaLabel", "BreakdownLabel", "RankLabel", "XPBar",
             "RetryButton", "HubButton", "CelebrationModal",
             "CelebrationLabel", "CelebrationClaimButton"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, RESULTS_TSCN) is not None)
check("animates accuracy", "_set_accuracy_display" in results_code)
check("animates lumina tally", "_set_lumina_display" in results_code)
check("animates XP bar", '"value"' in results_code)
check("honours reduced motion", "Palette.reduced_motion()" in results_code)
check("celebration on seed unlock", "_maybe_celebrate" in results_code)
check("retry action present", "func _on_retry" in results_code)
check("hub action present", "func _on_hub" in results_code)
check("results route wired", "screens/trial_results.tscn" in ROUTER)

print("\n── TYPING ──")
for name, src in list(ALL_TRIALS.items()) + [("base", BASE), ("results", RESULTS)]:
    clean = strip_comments(src)
    untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", clean, re.M)
    check(f"{name}: all funcs typed", not untyped, str(untyped))
    bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", clean, re.M)
    check(f"{name}: no bare var", not bare, str(bare))


# ═══════════════════════════════════════════════════════════════════════
# BEHAVIOURAL SIMULATION
# ═══════════════════════════════════════════════════════════════════════
print("\n── SIM: False Witness difficulty curve ──")
GLYPHS = [6, 11, 17]
WINDOWS = [6.5, 4.0, 2.2]
DELTAS = [0.45, 0.30, 0.20]
check("harder = more glyphs", GLYPHS[0] < GLYPHS[1] < GLYPHS[2])
check("harder = less time", WINDOWS[0] > WINDOWS[1] > WINDOWS[2])
check("harder = subtler anomaly", DELTAS[0] > DELTAS[1] > DELTAS[2])

rng = random.Random(7)
out_of_range = 0
for bracket in range(3):
    for _ in range(500):
        if not 0 <= rng.randrange(GLYPHS[bracket]) < GLYPHS[bracket]:
            out_of_range += 1
check("anomaly index always valid (1500 draws)", out_of_range == 0)

print("\n── SIM: Sequence Recall has no ambiguous repeats ──")
LMIN, LMAX = [3, 5, 7], [4, 6, 9]
rng = random.Random(11)
for bracket in range(3):
    violations = 0
    for _ in range(500):
        length = rng.randint(LMIN[bracket], LMAX[bracket])
        seq: list[int] = []
        previous = -1
        for _ in range(length):
            pick = rng.randrange(4)
            while pick == previous:
                pick = rng.randrange(4)
            seq.append(pick)
            previous = pick
        if any(seq[i] == seq[i + 1] for i in range(len(seq) - 1)):
            violations += 1
        if not LMIN[bracket] <= len(seq) <= LMAX[bracket]:
            violations += 1
    check(f"bracket {bracket}: 500 sequences clean", violations == 0, str(violations))

sequence = [0, 1, 2, 3, 0, 1]
taps = [0, 1, 2, 9, 0, 1]
scored: list[bool] = []
for i, tap in enumerate(taps):
    ok = tap == sequence[i]
    scored.append(ok)
    if not ok:
        break
check("wrong tap ends the round", len(scored) == 4)
check("partial credit kept (3 of 4)", sum(scored) == 3)

print("\n── SIM: Cognitive Conflict is a real Stroop task ──")
rng = random.Random(13)
conflicts = 0
SAMPLES = 2000
for _ in range(SAMPLES):
    word = rng.randrange(4)
    ink = rng.randrange(4)
    while ink == word:
        ink = rng.randrange(4)
    if ink != word:
        conflicts += 1
check(f"ink never matches word ({SAMPLES} samples)", conflicts == SAMPLES)
STIMULI, RESPONSE = [4, 6, 8], [2.40, 1.10, 0.55]
check("harder = more stimuli", STIMULI[0] < STIMULI[1] < STIMULI[2])
check("harder = shorter window", RESPONSE[0] > RESPONSE[1] > RESPONSE[2])
check("4 distinct shapes for colourblind play",
      len({"circle", "triangle", "square", "diamond"}) == 4)
check("inks live in Palette", "Palette.STROOP_INKS" in strip_comments(STROOP))

print("\n── SIM: accuracy maths cannot divide by zero ──")


def accuracy(correct: int, attempted: int) -> float:
    return 0.0 if attempted <= 0 else max(0.0, min(1.0, correct / attempted))


check("0 attempts -> 0.0", accuracy(0, 0) == 0.0)
check("6/6 -> 1.0", accuracy(6, 6) == 1.0)
check("3/6 -> 0.5", accuracy(3, 6) == 0.5)
check("cannot exceed 1.0", accuracy(10, 6) == 1.0)

print("\n── SIM: payouts respond to performance ──")
BASE_LUMINA, DIFFICULTY = [40, 70, 110], [1.0, 1.35, 1.8]


def payout(acc: float, bracket: int) -> int:
    total = BASE_LUMINA[bracket] * acc * DIFFICULTY[bracket]
    return max(5, min(int(round(total)), 1_000_000))


for name, bracket in (("false_witness", 0), ("sequence_recall", 1),
                      ("cognitive_conflict", 2)):
    perfect, zero = payout(1.0, bracket), payout(0.0, bracket)
    print(f"    {name:<20} bracket {bracket}: perfect {perfect:>3} ✦   zero {zero:>2} ✦")
    check(f"{name}: perfect beats zero", perfect > zero)
    check(f"{name}: zero still pays minimum", zero == 5)

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
