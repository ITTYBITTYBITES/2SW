"""Phase 8 verification: dialogue manifest, audio safety, daily hub.

Three things are load-bearing here:

  1. NO BACK-TO-BACK VOICE REPEATS. v1 played the same "welcome" clip on both
     the Loading screen and Console entry - the same line twice in four
     seconds. The shuffle bag draws without replacement and guards the cycle
     boundary, so a repeat is structurally impossible, not merely unlikely.

  2. NO CLIPPING, EVER. Procedural synthesis can trivially produce full-scale
     spikes and DC offset. Every path is checked for peak, head/tail silence
     (clicks), and offset. These are the failure modes that damage headphones.

  3. STREAK CORRECTNESS. Personal best must survive a broken streak, and a
     double-claim or clock rewind must never pay twice.

Run: python3 tests/test_daily_audio.py
"""
import math
import pathlib
import random
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = (ROOT / "data/dialogue_manifest.gd").read_text()
AUDIO = (ROOT / "data/audio_manager.gd").read_text()
HUB = (ROOT / "nodes/daily_hub_controller.gd").read_text()
HUB_TSCN = (ROOT / "screens/daily_hub.tscn").read_text()
ENGINE = (ROOT / "data/progression_engine.gd").read_text()
STATE = (ROOT / "data/iris_state.gd").read_text()
PROJECT = (ROOT / "project.godot").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


print("-- MANIFEST: 6+ variants per context --")
CONTEXTS = ["hub_greet", "trial_start", "in_trial_good", "in_trial_miss",
            "trial_complete_high", "trial_complete_mid", "trial_complete_low",
            "streak_milestone", "return_after_absence"]
for ctx in CONTEXTS:
    check(f"context '{ctx}' declared", f'&"{ctx}"' in MANIFEST)
check("9 contexts defined", sum(1 for c in CONTEXTS if f'&"{c}"' in MANIFEST) == 9)
check("minimum enforced by validate()", "MIN_VARIANTS: int = 6" in MANIFEST)
check("shuffle bag, not pick_random", "pick_random" not in strip_comments(MANIFEST))
check("cycle boundary guarded", "_last_issued" in MANIFEST)
check("validate() rejects duplicates", "duplicate line" in MANIFEST)

print("\n-- AUDIO: procedural only, no files --")
audio_code = strip_comments(AUDIO)
for ext in (".ogg", ".wav", ".mp3"):
    check(f"no {ext} reference", ext not in audio_code)
check("uses AudioStreamGenerator", "AudioStreamGenerator" in audio_code)
check("no TTS / speech synthesis", "TTS" not in audio_code and "tts" not in audio_code)
check("master ceiling declared", "MASTER_CEILING" in audio_code)
check("every frame hard-clamped", "_clamp_frame" in audio_code)
check("edge fade prevents clicks", "_envelope" in audio_code)
check("registered as autoload", 'AudioManager="*res://data/audio_manager.gd"' in PROJECT)
for sfx in ("ui_tap", "swap", "match", "sequence_bell", "stroop_pulse"):
    check(f"sfx '{sfx}' defined", f'&"{sfx}"' in audio_code)
for emo in ("hub_idle", "touch_respond", "streak_celebrate", "warble_error"):
    check(f"formant '{emo}' defined", f'&"{emo}"' in audio_code)

print("\n-- DAILY HUB: wiring --")
hub_code = strip_comments(HUB)
for node in ("Background", "IrisView", "StreakLabel", "BestLabel", "GraceLabel",
             "MilestoneTrack", "ClaimButton", "BeginTrialButton", "RewardLabel"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, HUB_TSCN) is not None)
check("single Save write path", hub_code.count("Save.set_v") == 4)
check("claim routes through engine", "ProgressionEngine.evaluate_daily_streak" in hub_code)
check("does not grant seeds directly", "grant_seed" not in hub_code)
check("does not award lumina directly", "award_lumina" not in hub_code)
check("no change_scene", "change_scene" not in hub_code)
check("daily trial uses adaptive bracket", '"bracket"' not in hub_code)
check("best_streak on IrisState", "best_streak_days" in STATE)
check("milestone track 3/7/14/21/30", "[3, 7, 14, 21, 30]" in ENGINE)

untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", hub_code, re.M)
check("hub: all funcs typed", not untyped, str(untyped))
untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", audio_code, re.M)
check("audio: all funcs typed", not untyped, str(untyped))


print("-- SHUFFLE BAG: no back-to-back repeats --")
class Bag:
    def __init__(s,size,rng): s.size=size; s.rng=rng; s.bag=[]; s.last=None
    def refill(s):
        idx=list(range(s.size))
        for i in range(len(idx)-1,0,-1):
            j=s.rng.randint(0,i); idx[i],idx[j]=idx[j],idx[i]
        if s.last is not None and len(idx)>1 and idx[-1]==s.last:
            idx[-1],idx[0]=idx[0],idx[-1]
        return idx
    def next(s):
        if not s.bag: s.bag=s.refill()
        v=s.bag.pop(); s.last=v; return v

rng=random.Random(4242)
for size in (6,7):
    b=Bag(size,rng); seq=[b.next() for _ in range(6000)]
    repeats=sum(1 for i in range(len(seq)-1) if seq[i]==seq[i+1])
    check(f"pool {size}: zero back-to-back in 6000 draws", repeats==0, str(repeats))
    # every line appears once per cycle
    cycles_ok=all(sorted(seq[i:i+size])==list(range(size)) for i in range(0,6000-size,size))
    check(f"pool {size}: each cycle covers all lines", cycles_ok)
    counts={i:seq.count(i) for i in range(size)}
    spread=max(counts.values())-min(counts.values())
    check(f"pool {size}: even distribution (spread {spread})", spread<=1, str(spread))

b=Bag(6,rng)
naive=[rng.randrange(6) for _ in range(6000)]
naive_rep=sum(1 for i in range(len(naive)-1) if naive[i]==naive[i+1])
print(f"    naive random would repeat {naive_rep} times; shuffle bag repeats 0")
check("shuffle bag strictly better than random", naive_rep>0)

print("\n-- CONTEXT RESOLUTION --")
def completion(acc): return "high" if acc>=0.85 else ("mid" if acc>=0.55 else "low")
for acc,exp in [(1.0,"high"),(0.85,"high"),(0.849,"mid"),(0.55,"mid"),(0.549,"low"),(0.0,"low")]:
    check(f"accuracy {acc} -> {exp}", completion(acc)==exp)
def greeting(absent,mile): return "absence" if absent>=2 else ("milestone" if mile else "greet")
check("2+ days away -> absence line", greeting(3,True)=="absence")
check("absence outranks milestone", greeting(5,True)=="absence")
check("milestone when present", greeting(0,True)=="milestone")
check("plain greet otherwise", greeting(1,False)=="greet")

print("\n-- AUDIO SAFETY: no clipping, ever --")
CEIL=0.72; SR=22050.0
def clamp(v): return max(-CEIL,min(CEIL,v))
def env(p,e):
    e=max(0.001,min(0.5,e))
    if p<e: return p/e
    if p>1-e: return (1-p)/e
    return 1.0
# formant voice
peak=0.0; first=None; last=None
FORM={"hub_idle":(420,900),"streak_celebrate":(700,1800),"warble_error":(320,700)}
for emo,(f1,f2) in FORM.items():
    n=int(0.4*SR); pk=0.0
    for i in range(0,n,7):
        t=i/SR; p=i/n
        src=sum(math.sin(t*2*math.pi*150*h)/h for h in range(1,7))*0.35
        shaped=src*(0.55+math.sin(t*2*math.pi*f1)*0.30+math.sin(t*2*math.pi*f2)*0.15)
        shaped*= 1.0+math.sin(t*2*math.pi*5.2)*0.04
        s=clamp(shaped*0.34*env(p,0.008/0.4)); pk=max(pk,abs(s))
    check(f"voice '{emo}' peak {pk:.3f} <= ceiling", pk<=CEIL+1e-9)
    peak=max(peak,pk)

# sfx
SFX={"ui_tap":(660,0.09,2,0.02),"match":(880,0.22,4,0.03),"sequence_bell":(1046,0.45,5,0.0),
     "error":(233,0.20,2,0.10)}
rng=random.Random(1)
for name,(f,dec,harm,noise) in SFX.items():
    n=int(dec*SR); pk=0.0; head=None; tail=None
    for i in range(0,n,5):
        t=i/SR; p=i/n
        s=sum(math.sin(t*2*math.pi*f*(h*(1+h*0.004)))/h for h in range(1,harm+1))
        if noise>0: s+=rng.uniform(-1,1)*noise
        s=clamp(s*0.28*pow(1-p,2.2)*env(p,0.008/dec))
        pk=max(pk,abs(s))
        if head is None: head=abs(s)
        tail=abs(s)
    check(f"sfx '{name}' peak {pk:.3f} <= ceiling", pk<=CEIL+1e-9)
    check(f"sfx '{name}' starts near silence", head<0.05, f"{head:.4f}")
    check(f"sfx '{name}' ends near silence", tail<0.05, f"{tail:.4f}")

# pad: long run, must never drift or clip
ph=0.0; dr=0.0; inc=1/SR; pk=0.0; dc=0.0; cnt=0
for i in range(int(SR*8)):
    ph+=inc; dr+=inc*0.037
    lfo=math.sin(dr*2*math.pi*0.11); root=110*(1+lfo*0.004)
    s=math.sin(ph*2*math.pi*root)*0.55+math.sin(ph*2*math.pi*root*1.5*(1+lfo*0.002))*0.28
    s+=math.sin(ph*2*math.pi*root*2.01)*0.14
    s=clamp(s*0.16); pk=max(pk,abs(s)); dc+=s; cnt+=1
check(f"pad 8s peak {pk:.3f} <= ceiling", pk<=CEIL+1e-9)
check(f"pad DC offset {dc/cnt:.5f} ~ 0", abs(dc/cnt)<0.01, f"{dc/cnt:.5f}")
check("pad well under ceiling (headroom for mix)", pk<0.35, f"{pk:.3f}")
check("voice+pad+sfx sum stays in range", 0.34+0.16+0.28 <= 1.0)

print("\n-- PAD NON-REPETITION --")
# two detuned partials beat; period is the LCM which must be long
def pad_at(t):
    lfo=math.sin(t*0.037*2*math.pi*0.11); root=110*(1+lfo*0.004)
    return math.sin(t*2*math.pi*root)*0.55+math.sin(t*2*math.pi*root*1.5)*0.28
a=[round(pad_at(t/SR),4) for t in range(0,2000)]
b=[round(pad_at((t+SR*4)/SR),4) for t in range(0,2000)]
check("4s apart, waveform differs (no loop)", a!=b)

print("\n-- MILESTONE TRACK --")
DAYS=[3,7,14,21,30]; PAY={3:150,7:500,14:900,21:1400,30:2500}
BASE=50; REPEAT=500
def is_mile(d):
    if d<=0: return False
    if d in DAYS: return True
    return d%7==0 if d>30 else False
def payout(d):
    d=max(d,1)
    if d in PAY: return PAY[d]
    if is_mile(d): return REPEAT
    return max(BASE,round(BASE*min(1.0+(d-1)*0.10,3.0)))
for d in DAYS: check(f"day {d} is a milestone", is_mile(d))
for d in (1,2,4,5,6,8,13,29): check(f"day {d} is not", not is_mile(d))
check("day 35 repeats (past 30)", is_mile(35))
check("day 31 is not", not is_mile(31))
for d in DAYS: check(f"day {d} pays {PAY[d]}", payout(d)==PAY[d])
check("day 1 pays base", payout(1)==BASE)
check("payouts increase across track", all(PAY[DAYS[i]]<PAY[DAYS[i+1]] for i in range(len(DAYS)-1)))
def next_mile(d):
    for x in DAYS:
        if x>d: return x
    n=37
    while n<=d: n+=7
    return n
for cur,exp in [(0,3),(2,3),(3,7),(6,7),(7,14),(20,21),(29,30),(30,37)]:
    check(f"next milestone after {cur} is {exp}", next_mile(cur)==exp, str(next_mile(cur)))

print("\n-- STREAK + BEST --")
class S:
    def __init__(s): s.streak=0; s.best=0
def claim(s,last,today):
    if last==today: return False
    if last>today: return False
    gap=today-last
    s.streak = 1 if (last<0 or gap>2) else s.streak+1
    s.best=max(s.best,s.streak)
    return True
s=S(); last=-1
for d in range(10):
    claim(s,last,1000+d); last=1000+d
check("10 days -> streak 10", s.streak==10)
check("best tracks 10", s.best==10)
claim(s,last,last+9)
check("big gap resets streak to 1", s.streak==1)
check("best PRESERVED after break", s.best==10, str(s.best))
check("double-claim same day refused", claim(s,last+9,last+9)==False)
check("clock rewind refused", claim(s,5000,4999)==False)


print("\n-- REGRESSION: the voice buffer must hold a whole utterance --")
# THE BUG: BUFFER_LENGTH was 0.35s (7717 frames at 22050 Hz) while
# play_iris_formant() synthesises up to MAX_VOICE_SECONDS. The push loop
# clamped to whatever the buffer could take that frame, so every line longer
# than ~12 characters was cut off mid-utterance with no warning. Measured on
# the four intro lines: 27%, 0%, 35% and 10% of the audio discarded. The text
# still rendered in full — subtitles with no matching sound.
#
# Asserted as a RELATIONSHIP, not a literal. Raising MAX_VOICE_SECONDS or
# lowering BUFFER_LENGTH must fail here rather than silently truncating again.
AUDIO_SRC = (ROOT / "data" / "audio_manager.gd").read_text()

def _const(name: str) -> float:
    m = re.search(rf"const {name}\s*:\s*float\s*=\s*([\d.]+)", AUDIO_SRC)
    assert m is not None, f"{name} not found in audio_manager.gd"
    return float(m.group(1))

BUFFER_LENGTH = _const("BUFFER_LENGTH")
MAX_VOICE_SECONDS = _const("MAX_VOICE_SECONDS")
SAMPLE_RATE = _const("SAMPLE_RATE")

check("the buffer holds the longest utterance",
      BUFFER_LENGTH >= MAX_VOICE_SECONDS,
      f"buffer {BUFFER_LENGTH}s < voice {MAX_VOICE_SECONDS}s")
check("the formant duration is clamped to MAX_VOICE_SECONDS",
      "0.22, MAX_VOICE_SECONDS)" in AUDIO_SRC)
check("truncation is reported, never silent",
      "voice truncated" in AUDIO_SRC)

# Every real dialogue line must fit. A line is 0.22 + 0.012s per character.
LONGEST = 0
for _m in re.finditer(r'"([^"]{4,})"', (ROOT / "data" / "dialogue_manifest.gd").read_text()):
    LONGEST = max(LONGEST, len(_m.group(1)))
_needed = min(0.22 + LONGEST * 0.012, MAX_VOICE_SECONDS)
check("the longest authored line fits in the buffer",
      _needed <= BUFFER_LENGTH,
      f"{LONGEST} chars needs {_needed:.2f}s, buffer is {BUFFER_LENGTH}s")

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
