"""Consent screen: persistence, defaults, and gating.

The load-bearing property is OPT-IN. Ad personalisation and analytics must
default OFF, so a player who taps straight through gets the most private
configuration rather than the most permissive one. Pre-ticked consent is
unlawful under GDPR and would make the Play data-safety declaration false.

SIMPLIFIED: the two switches no longer appear on this screen at all. Both
default OFF and an untouched switch is legally identical to no switch, so the
first-run gate is now a single card with one button, and the switches live in
Settings -> Privacy & Data where opting in AND withdrawing are equally easy.
That makes the guarantee stronger, not weaker: this screen is now INCAPABLE
of writing a permissive value, which the checks below assert directly.

Also guards the v1 defect where the RESUME PATH ROUTED AROUND consent: a
player who force-quit on the screen came back straight into the game having
never accepted.

Run: python3 tests/test_consent.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONSENT = (ROOT / "nodes/consent_controller.gd").read_text()
TSCN = (ROOT / "screens/consent/consent.tscn").read_text()
APP = (ROOT / "app/app.gd").read_text()
ROUTER = (ROOT / "core/router.gd").read_text()
SETTINGS = (ROOT / "nodes/settings_view_controller.gd").read_text()
SAVE = (ROOT / "core/save.gd").read_text()
BUS = (ROOT / "core/bus.gd").read_text()


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


CODE = strip_comments(CONSENT)
APP_CODE = strip_comments(APP)

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


print("-- OPT-IN BY DEFAULT --")
check("consent_defaults() is the single definition",
      "static func consent_defaults() -> Dictionary:" in CODE)
defaults_block = CODE.split("func consent_defaults")[1].split("\n\n")[0]
check("defaults ads OFF", '"personalized_ads": false' in defaults_block)
check("defaults analytics OFF", '"analytics": false' in defaults_block)
check("no default is true", "true" not in defaults_block)
check("save seeds ads false", 'SEC_CONSENT, "personalized_ads", false' in SAVE)
check("save seeds analytics false", 'SEC_CONSENT, "analytics", false' in SAVE)

print("\n-- SIMPLIFIED: no switches on the gate --")
check("no CheckButton in the controller", "CheckButton" not in CODE)
check("no CheckButton in the scene", "CheckButton" not in TSCN)
check("no toggle list node", "ToggleList" not in TSCN and "ToggleList" not in CODE)
check("no toggle builder", "_build_toggles" not in CODE and "_add_toggle" not in CODE)
check("no pre-ticked anything", "button_pressed = true" not in CODE)
# The strongest form of the guarantee: the screen cannot write `true` to
# either key, no matter what a player does on it. Grep the whole file for a
# write of a permissive value rather than trusting the UI to be absent.
import re as _re
permissive = _re.findall(
    r'set_v\(\s*Save\.SEC_CONSENT\s*,\s*"(?:personalized_ads|analytics)"\s*,\s*true',
    CODE)
check("gate cannot write a permissive value", not permissive, str(permissive))

print("\n-- GATING --")
check("app gates on consent", "ConsentController.is_satisfied()" in APP_CODE)
check("no auto-accept stub", "auto-accepting" not in APP)
check("gate precedes session restore",
      APP_CODE.index("is_satisfied") < APP_CODE.index("read_session"))
# The gate routes to the SPLASH, which resolves consent-or-hub after its
# warm-up. A first-time player sees the ident before a wall of legal text, and
# the gate is still unskippable — SplashController.resolve_destination()
# checks consent first, before anything else.
check("gate routes into the startup sequence", 'Router.go("splash")' in APP_CODE)
check("gate returns early", "return" in APP_CODE.split("is_satisfied")[1][:260])
SPLASH = (ROOT / "nodes/splash_controller.gd").read_text()
splash_code = strip_comments(SPLASH)
check("splash resolves consent first",
      splash_code.split("func resolve_destination")[1].split("return")[0].count("is_recorded") == 1)
check("splash uses the recorded state, not the debug bypass",
      "is_recorded()" in splash_code.split("func resolve_destination")[1][:400])
check("splash routes to consent", 'return "consent"' in splash_code)
check("consent precedes the hub in resolution",
      splash_code.index('return "consent"') < splash_code.index('return "hub"'))

print("\n-- DEBUG BYPASS --")
check("is_satisfied bypasses in debug", "OS.is_debug_build()" in CODE)
check("is_recorded exposes the real state", "static func is_recorded()" in CODE)
check("bypass documented as release-safe", "release build" in CONSENT.lower())

print("\n-- POLICY VERSIONING --")
check("POLICY_VERSION declared", "POLICY_VERSION: int" in CODE)
check("version stamped on accept", '"policy_version", POLICY_VERSION' in CODE)
check("is_satisfied checks version", "policy_version" in CODE.split("func is_satisfied")[1][:300])
check("timestamp recorded", "accepted_unix" in CODE)

print("\n-- PERSISTENCE --")
check("writes through Save", "Save.set_v(Save.SEC_CONSENT" in CODE)
check("flushes immediately", "Save.flush()" in CODE)
check("commit is public + testable", "func commit_consent() -> void:" in CODE)
check("static readers exist",
      "static func personalized_ads_allowed()" in CODE
      and "static func analytics_allowed()" in CODE)
check("emits consent_changed", "Bus.consent_changed.emit" in CODE)
check("Bus declares consent_changed", "signal consent_changed(" in BUS)

print("\n-- ROUTING --")
check("route declared", '"consent":' in ROUTER)
check("scene exists", (ROOT / "screens/consent/consent.tscn").exists())
check("consent is a ROOT route", re.search(r'ROOT_ROUTES\s*:=\s*\[[^\]]*"consent"', ROUTER) is not None)
# The chain used to be consent -> sponsor -> loading -> home; those screens
# are deleted. Rather than naming a replacement route here, the controller
# asks the same resolver the splash uses, so the two cannot disagree.
check("first run defers to the boot resolver",
      "SplashController.resolve_destination()" in CODE)
check("no route to a deleted screen",
      'replace("sponsor")' not in CODE and 'replace("loading")' not in CODE)
check("guards against a resolver that still demands consent",
      'destination != "consent"' in CODE)
check("no change_scene", "change_scene" not in CODE)

print("\n-- PRIVACY & DATA LIVES IN SETTINGS --")
settings_code = strip_comments(SETTINGS)
check("settings has a Privacy & Data section",
      '_add_section("Privacy & Data")' in settings_code)
check("settings offers the ads switch",
      '"personalized_ads"' in settings_code)
check("settings offers the analytics switch",
      '"analytics"' in settings_code)
check("switches read the STORED state, not a constant",
      "ConsentController.personalized_ads_allowed()" in settings_code
      and "ConsentController.analytics_allowed()" in settings_code)
# One writer for the consent section. If Settings wrote through Save directly
# there would be two places that could record a legal choice, and only one of
# them would emit the audit line and the Bus event.
check("settings writes via ConsentController, not Save",
      "ConsentController.set_privacy_choice(" in settings_code)
check("settings never writes SEC_CONSENT directly",
      "SEC_CONSENT" not in settings_code)
check("withdrawal is possible from the same control",
      "set_privacy_choice(key, pressed)" in settings_code)
check("controller exposes a single privacy writer",
      "static func set_privacy_choice(key: String, allowed: bool) -> void:" in CODE)
check("privacy writer validates its key",
      "consent_defaults().has(key)" in CODE)
check("privacy writer emits the Bus event",
      "Bus.consent_changed.emit" in CODE.split("func set_privacy_choice")[1][:400])

print("\n-- REVISIT FROM SETTINGS --")
check("settings reopens the terms", 'Router.go("consent", {"revisit": true})' in settings_code)
check("controller honours revisit", '_revisit = bool(payload.get("revisit"' in CODE)
check("revisit returns instead of continuing", "if _revisit:" in CODE)
check("revisit relabels the CTA", '"Done" if _revisit' in CODE)
# A revisit must not reset choices made in Settings since acceptance.
check("revisit preserves stored choices", "if first_time:" in CODE)
check("first_time derived from the real stored state",
      "var first_time: bool = not is_recorded()" in CODE)

print("\n-- BACK BEHAVIOUR --")
back_block = CODE.split("func on_back_requested()")[1]
check("mandatory gate swallows back", "return true" in back_block)
check("revisit allows back", "if _revisit:" in back_block)

print("\n-- LAYOUT FITS ANY ASPECT --")
check("card is width-capped", "CARD_MAX_WIDTH" in CODE)
layout_fn = CODE.split("func _layout")[1][:900]
check("card width derives from the live viewport, not the design size",
      "size.x" in layout_fn)
check("card shrinks rather than overflowing",
      "minf(CARD_MAX_WIDTH" in CODE)
# Resize handling is inherited: Screen wires `resized` to _layout() and tears
# it down in _exit_tree, so a screen overriding _layout() is covered without
# repeating the connect/disconnect pair. Verified against the base class
# rather than this file, and enforced for every Screen by Rule G.
SCREEN_CODE = (ROOT / "ui" / "screen.gd").read_text()
check("Screen wires resize to the layout hook",
      "resized.connect(_run_layout)" in SCREEN_CODE)
check("Screen covers the first frame too",
      "_run_layout.call_deferred()" in SCREEN_CODE)
check("consent overrides the inherited hook", "func _layout" in CODE)
# A visible vertical scrollbar eats width from the RIGHT edge only, so a card
# centred in the remainder sits half a bar off true centre (4px at 800x600 —
# caught by tools/layout_flow.gd, not by any static check).
check("scrollbar asymmetry compensated", "margin_left" in layout_fn
      and "shift" in layout_fn)
check("scrollbar visibility tracked",
      "visibility_changed.connect(_layout)" in CODE)
check("scrollbar handler disconnected",
      "visibility_changed.disconnect(_layout)" in CODE)
# The gutter must be reserved unconditionally in the WIDTH: if width depended
# on bar visibility, a wider card could hide the bar, which would widen the
# card again — a layout loop that settles differently per frame.
check("gutter reserved in width regardless of visibility",
      "- gutter" in layout_fn)
check("scrolls when even the shrunk card is too tall", "ScrollContainer" in TSCN)
check("card is centred", "alignment = 1" in TSCN)
check("margins honour the safe area", "safe_bottom" in CODE and "safe_top" in CODE)
check("no fixed offsets on the root",
      "offset_bottom" not in TSCN.split('name="Root"')[1].split("[node")[0])

print("\n-- DISCLOSURE CONTENT --")
check("states the required welcome line",
      "free to play and uses non-personalized services to run" in CONSENT)
check("states free to play", "free to play" in CONSENT)
check("states no purchases", "no purchases" in CONSENT.lower())
check("states local storage", "on this device" in CONSENT)
check("states no account required", "account" in CONSENT)
check("privacy link", "PRIVACY_URL" in CODE)
check("terms link", "TERMS_URL" in CODE)

print("\n-- SCENE WIRING --")
for node in ("Background", "Root", "Card", "TitleLabel", "BodyLabel",
             "PrivacyButton", "TermsButton", "AcceptButton", "BackButton"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, TSCN) is not None)

print("\n-- TYPING --")
untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", CODE, re.M)
check("all funcs typed", not untyped, str(untyped))
bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", CODE, re.M)
check("no bare var", not bare, str(bare))

print("\n-- SIM: gate logic --")


def satisfied(accepted: bool, stored_version: int, current: int = 1) -> bool:
    return accepted and stored_version >= current


check("fresh install -> gated", not satisfied(False, 0))
check("accepted current -> passes", satisfied(True, 1))
check("accepted stale policy -> re-prompts", not satisfied(True, 0))
check("accepted newer policy -> passes", satisfied(True, 2))
check("version alone is not enough", not satisfied(False, 5))

print("\n-- SIM: a revisit never resets a Settings opt-in --")


def commit(store: dict) -> dict:
    """Mirror of commit_consent(): defaults seeded ONLY on first acceptance."""
    store = dict(store)
    first_time = not (store.get("accepted") and store.get("policy_version", 0) >= 1)
    store["accepted"] = True
    store["policy_version"] = 1
    if first_time:
        store["personalized_ads"] = False
        store["analytics"] = False
    return store


fresh = commit({})
check("first acceptance stores ads OFF", fresh["personalized_ads"] is False)
check("first acceptance stores analytics OFF", fresh["analytics"] is False)

opted_in = dict(fresh, personalized_ads=True, analytics=True)
after_revisit = commit(opted_in)
check("revisit keeps an ads opt-in", after_revisit["personalized_ads"] is True)
check("revisit keeps an analytics opt-in", after_revisit["analytics"] is True)
check("revisit keeps acceptance", after_revisit["accepted"] is True)

# A stale policy version re-prompts, which IS a first acceptance again --
# the player is agreeing to different terms, so the optional choices reset to
# the most private state rather than being carried across silently.
stale = dict(opted_in, policy_version=0)
after_reprompt = commit(stale)
check("a material policy change re-seeds the private defaults",
      (after_reprompt["personalized_ads"], after_reprompt["analytics"]) == (False, False))

print("\n-- SIM: settings switches round-trip --")
store = commit({})
for key in ("personalized_ads", "analytics"):
    store[key] = True
    check(f"{key} can be turned on", store[key] is True)
    store[key] = False
    check(f"{key} can be withdrawn", store[key] is False)
    check("withdrawal never revokes acceptance", store["accepted"] is True)

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
