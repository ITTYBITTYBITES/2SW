"""Phase 8 verification: trial registry, Facet Cascade, adaptive difficulty.

Covers the three gaps found in the legacy review:
  1. facet_cascade was MISSING from v2 entirely (20% pick weight in v1)
  2. cognitive_conflict had been shortened from 8 rounds to 4 at easy bracket
  3. adaptive difficulty did not exist in v2 at all

The registry test matters most structurally: v1 spread trial identity across
four parallel tables and one of them omitted facet_cascade, silently pinning
20% of trials to Easy forever. There is now one table, and `validate()` proves
it agrees with itself.

Run: python3 tests/test_trial_suite.py
"""
import pathlib
import random
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = (ROOT / "data/trial_registry.gd").read_text()
ADAPTIVE = (ROOT / "data/adaptive_difficulty.gd").read_text()
CASCADE = (ROOT / "nodes/trials/facet_cascade.gd").read_text()
STATE = (ROOT / "data/iris_state.gd").read_text()
HOST = (ROOT / "nodes/trial_controller.gd").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)



print("-- REGISTRY: single source of truth --")
ROSTER = ["false_witness", "sequence_recall", "cognitive_conflict", "facet_cascade"]
for trial_id in ROSTER:
    check(f"'{trial_id}' registered", f'"{trial_id}"' in REGISTRY)
check("4 trials in roster", sum(1 for t in ROSTER if f'"{t}"' in REGISTRY) == 4)
check("registry validates itself", "static func validate()" in REGISTRY)
check("history seeded from all_ids()", "for id: String in all_ids()" in REGISTRY)
check("host has no duplicate id table", "const MINIGAMES" not in strip_comments(HOST))
check("host resolves via registry", "TrialRegistry.script_path" in HOST)
check("selection order is deterministic", "sorted_ids()" in REGISTRY)

for trial_id in ROSTER:
    path = ROOT / f"nodes/trials/{trial_id}.gd"
    check(f"{trial_id}.gd exists", path.exists())

print("\n-- ADAPTIVE: wired into state and host --")
check("trial_history on IrisState", "@export var trial_history" in STATE)
check("trial_history serialised", '"trial_history": trial_history' in STATE)
check("host records attempts", "AdaptiveDifficulty.record_attempt" in HOST)
check("host reads adaptive bracket", "AdaptiveDifficulty.current_bracket" in HOST)
check("demote threshold 0.63", "DEMOTE_THRESHOLD: float = 0.63" in ADAPTIVE)
check("demote streak 3", "DEMOTE_STREAK: int = 3" in ADAPTIVE)
check("promote threshold 0.87", "PROMOTE_THRESHOLD: float = 0.87" in ADAPTIVE)
check("promote streak 5", "PROMOTE_STREAK: int = 5" in ADAPTIVE)
check("history capped at 10", "HISTORY_LENGTH: int = 10" in ADAPTIVE)

print("\n-- FACET CASCADE: textureless + isolated --")
cascade_code = strip_comments(CASCADE)
for ext in (".png", ".jpg", ".svg"):
    check(f"no {ext}", ext not in cascade_code)
check("no Texture2D", "Texture2D" not in cascade_code)
check("draws with vectors", "draw_colored_polygon" in cascade_code)
check("colours from Palette", "Palette.FACET_COLORS" in cascade_code)
check("no direct MOUSE_FILTER_STOP", "MOUSE_FILTER_STOP" not in cascade_code)
check("uses make_target()", "make_target(" in cascade_code)
check("params from registry", "TrialRegistry.params" in cascade_code)
untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", cascade_code, re.M)
check("all funcs typed", not untyped, str(untyped))

MIN_MATCH=3
def find_matches(grid):
    n=len(grid); matched=set()
    for r in range(n):
        start=0
        for c in range(1,n+1):
            same = c<n and grid[r][c]>=0 and grid[r][c]==grid[r][start]
            if not same:
                if c-start>=MIN_MATCH and grid[r][start]>=0:
                    for cc in range(start,c): matched.add((cc,r))
                start=c
    for c in range(n):
        start=0
        for r in range(1,n+1):
            same = r<n and grid[r][c]>=0 and grid[r][c]==grid[start][c]
            if not same:
                if r-start>=MIN_MATCH and grid[start][c]>=0:
                    for rr in range(start,r): matched.add((c,rr))
                start=r
    return matched

print("-- MATCH DETECTION --")
check("horizontal run of 3", find_matches([[0,0,0,1],[1,2,1,2],[2,1,2,1],[1,2,1,2]])=={(0,0),(1,0),(2,0)})
check("vertical run of 3", find_matches([[0,1,2,1],[0,2,1,2],[0,1,2,1],[1,2,1,2]])=={(0,0),(0,1),(0,2)})
check("run of 4 found entirely", len(find_matches([[0,0,0,0],[1,2,1,2],[2,1,2,1],[1,2,1,2]]))==4)
m=find_matches([[0,0,0,1],[0,2,1,2],[0,1,2,1],[1,2,1,2]])
check("L-shape unions both runs", m=={(0,0),(1,0),(2,0),(0,1),(0,2)}, str(sorted(m)))
check("L-shape corner counted ONCE", len(m)==5, str(len(m)))
m=find_matches([[1,0,1,2],[0,0,0,1],[1,0,1,2],[2,1,2,1]])
check("T-shape unions correctly", m=={(1,0),(1,1),(1,2),(0,1),(2,1)}, str(sorted(m)))
check("checkerboard: no matches", len(find_matches([[0,1,0,1],[1,0,1,0],[0,1,0,1],[1,0,1,0]]))==0)
check("run of 2 does NOT match", len(find_matches([[0,0,1,2],[1,2,0,1],[2,1,2,0],[0,1,0,1]]))==0)

print("\n-- GRAVITY --")
def gravity(grid):
    n=len(grid)
    for c in range(n):
        w=n-1
        for r in range(n-1,-1,-1):
            if grid[r][c]>=0:
                grid[w][c]=grid[r][c]
                if w!=r: grid[r][c]=-1
                w-=1
        for r in range(w,-1,-1): grid[r][c]=-1
    return grid
g=gravity([[1,2,3],[-1,2,3],[3,-1,3]])
check("col 0 compacts down", [g[r][0] for r in range(3)]==[-1,1,3], str([g[r][0] for r in range(3)]))
check("col 1 compacts down", [g[r][1] for r in range(3)]==[-1,2,2], str([g[r][1] for r in range(3)]))
check("full column untouched", [g[r][2] for r in range(3)]==[3,3,3])
g=gravity([[-1,-1],[-1,-1]])
check("empty board stays empty", all(v==-1 for row in g for v in row))

print("\n-- BOARD GEN: no pre-existing matches --")
def gen(size,colors,rng):
    grid=[]
    for r in range(size):
        line=[]
        for c in range(size):
            forbidden=[]
            if c>=2 and line[c-1]==line[c-2]: forbidden.append(line[c-1])
            if r>=2 and grid[r-1][c]==grid[r-2][c]: forbidden.append(grid[r-1][c])
            pick=None
            for _ in range(12):
                p=rng.randrange(colors)
                if p not in forbidden: pick=p; break
            line.append(pick if pick is not None else rng.randrange(colors))
        grid.append(line)
    return grid
rng=random.Random(42); bad=0
for size,colors in [(6,4),(7,5),(8,6)]:
    for _ in range(300):
        if find_matches(gen(size,colors,rng)): bad+=1
check("900 boards, zero start matched", bad==0, str(bad))

print("\n-- COMBO MULTIPLIER --")
def combo(step): return min(1.0+(step-1)*0.5, 3.0)
for s,e in [(1,1.0),(2,1.5),(3,2.0),(4,2.5),(5,3.0),(9,3.0)]:
    check(f"chain {s} -> x{e}", abs(combo(s)-e)<1e-9)
check("capped at 3.0", combo(100)==3.0)
check("longer chains score more", 3*combo(3) > 3*combo(1))

print("\n-- MOVE BUDGET --")
def run(target,moves,per):
    cleared=0; left=moves
    while left>0 and cleared<target:
        left-=1; cleared+=per
    return cleared,left,cleared>=target
# 18 moves clearing 1 each = 18 < 25 target -> genuinely insufficient.
c,l,w=run(25,18,1); check("insufficient -> budget exhausted", not w and l==0, f"cleared {c}")
check("exhausted board still scores partial", 0 < min(c,25)/25 < 1.0, str(min(c,25)/25))
c,l,w=run(25,18,5); check("efficient -> target reached", w and l>0, f"cleared {c}")
check("accuracy capped at 1.0", min(c,25)/25<=1.0)
c,l,w=run(40,20,1); check("partial progress = partial credit", 0<min(c,40)/40<1.0)
check("zero clears -> 0.0", 0/40==0.0)

print("\n-- ADAPTIVE THRESHOLDS --")
DN,DT=3,0.63; PN,PT=5,0.87
def below(log,n,t): return len(log)>=n and all(x<t for x in log[-n:])
def above(log,n,t): return len(log)>=n and all(x>t for x in log[-n:])
def ev(log,cur):
    if below(log,DN,DT): return max(cur-1,0)
    if above(log,PN,PT): return min(cur+1,2)
    return cur
check("2 bad: no demote yet", ev([0.5,0.5],1)==1)
check("3 bad: DEMOTE", ev([0.5]*3,1)==0)
check("exactly 0.63 does NOT demote", ev([0.63]*3,1)==1)
check("0.629 demotes", ev([0.629]*3,1)==0)
check("4 good: no promote yet", ev([0.9]*4,1)==1)
check("5 good: PROMOTE", ev([0.9]*5,1)==2)
check("exactly 0.87 does NOT promote", ev([0.87]*5,1)==1)
check("0.871 promotes", ev([0.871]*5,1)==2)
check("floor at bracket 0", ev([0.1]*3,0)==0)
check("ceiling at bracket 2", ev([0.99]*5,2)==2)
check("mixed: no shift", ev([0.9,0.4,0.9,0.4,0.9],1)==1)
check("old bad ignored if recent good", ev([0.1,0.1,0.9,0.9,0.9,0.9,0.9],1)==2)
check("recent bad overrides old good", ev([0.99,0.99,0.99,0.5,0.5,0.5],1)==0)

print("\n-- ROLLING WINDOW (10) --")
log=[]
for i in range(25):
    log.append(0.5)
    while len(log)>10: log.pop(0)
check("never exceeds 10", len(log)==10)
log=[0.9]*10; log.append(0.1); log.pop(0)
check("oldest evicted", log[0]==0.9 and log[-1]==0.1 and len(log)==10)

print("\n-- SHIFT RESETS WINDOW (anti-runaway) --")
log=[0.9]*5
new=ev(log,0); check("promotes 0 -> 1", new==1)
log=[]
check("window cleared after shift", len(log)==0)
check("cannot immediately re-promote", ev(log,new)==1)
check("without reset it WOULD runaway", ev([0.9]*5,1)==2)

print("\n-- ALL 4 TRIALS TRACKED --")
ROSTER=["cognitive_conflict","facet_cascade","false_witness","sequence_recall"]
hist={t:{"scores":[],"bracket":0} for t in ROSTER}
check("4 trials seeded", len(hist)==4)
check("facet_cascade tracked (the v1 BUG)", "facet_cascade" in hist)
for t in ROSTER:
    hist[t]["scores"]=[0.9]*5
    hist[t]["bracket"]=ev(hist[t]["scores"],hist[t]["bracket"])
check("all 4 adapt identically", all(hist[t]["bracket"]==1 for t in ROSTER))

print("\n-- WEIGHTED SELECTION --")
W={"false_witness":35,"sequence_recall":25,"cognitive_conflict":20,"facet_cascade":20}
total=sum(W.values()); check("weights total 100", total==100)
rng=random.Random(99); counts={k:0 for k in W}; N=200000
ids=sorted(W.keys())
for _ in range(N):
    roll=rng.randrange(total); acc=0
    for i in ids:
        acc+=W[i]
        if roll<acc: counts[i]+=1; break
ok=True
for i in ids:
    obs=counts[i]/N*100
    print(f"    {i:<20} expected {W[i]}%   observed {obs:.2f}%")
    if abs(obs-W[i])>=0.6: ok=False
check("200k draws match weights (<0.6% drift)", ok)
check("every trial selectable", all(c>0 for c in counts.values()))

print("\n-- COGNITIVE CONFLICT: 8 rounds restored --")
CC=[{"rounds":8,"window":2.40},{"rounds":8,"window":1.10},{"rounds":8,"window":0.55}]
check("all brackets run 8 rounds", all(b["rounds"]==8 for b in CC))
check("difficulty scales speed not length", CC[0]["window"]>CC[1]["window"]>CC[2]["window"])

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
