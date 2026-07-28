"""Behavioural tests for Router's back stack and App's boot/resume logic.

These mirror core/Router.gd and app/App.gd in Python so the rules can be
verified without a Godot binary in CI. If you change the navigation or resume
rules in GDScript, change them here too — a divergence means one of them is
wrong.

Each test names the v1 bug it prevents from returning.

Run: python3 tests/test_boot.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _string_array(src: str, const_name: str) -> list[str]:
    """Read a `const NAME := ["a", "b"]` list straight out of GDScript.

    These used to be retyped by hand here, which meant deleting the sponsor
    and loading screens left this mirror asserting against routes that no
    longer existed — and still passing, because the mirror only ever tested
    itself. Parsing the real constant makes a divergence impossible rather
    than merely discouraged.
    """
    m = re.search(rf"const {const_name}\s*:=\s*\[([^\]]*)\]", src)
    assert m, f"{const_name} not found; the constant was renamed or removed"
    return re.findall(r'"([^"]+)"', m.group(1))


ROUTER_SRC = (ROOT / "core/router.gd").read_text()
APP_SRC = (ROOT / "app/app.gd").read_text()

ROOT_ROUTES = _string_array(ROUTER_SRC, "ROOT_ROUTES")
NO_RESUME = _string_array(APP_SRC, "NO_RESUME")
DECLARED_ROUTES = dict(
    re.findall(r'"(\w+)":\s+"res://([^"]+)"',
               ROUTER_SRC.split("const ROUTES")[1].split("}")[0]))
RESUME_GRACE = 90 * 60

BOOT_ROUTE = "splash"   # App._boot() hands cold starts to the splash


class Router:
    """Mirror of core/Router.gd."""

    def __init__(self):
        self.stack = []
        self.route = ""
        self.payload = {}
        self.screen_consumes = False

    def go(self, r, p=None):
        p = p or {}
        if r in ROOT_ROUTES:
            self.stack.clear()
        elif self.route:
            self.stack.append((self.route, self.payload))
        self.route, self.payload = r, p

    def replace(self, r, p=None):
        self.route, self.payload = r, (p or {})

    def back(self):
        if self.screen_consumes:
            return True                      # screen intercepted it
        if not self.stack:
            return False                     # at root: App shows quit confirm
        self.route, self.payload = self.stack.pop()
        return True


def boot(session, consent_accepted, now):
    """Mirror of App._boot()."""
    r = Router()
    # Consent gate first, ALWAYS. A resumable session must not route around it.
    if not consent_accepted:
        r.go("consent")
        return r, "consent"
    if session:
        route = session.get("route", "")
        away = now - session.get("unix", 0)
        if route and route not in NO_RESUME and away < RESUME_GRACE:
            r.go(route, session.get("payload", {}))
            return r, "resumed"
    r.go(BOOT_ROUTE)
    return r, "cold"


fails = []


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        print(f"        got={got!r}  want={want!r}")
        fails.append(label)


print("── V1 BUG: back button quit the app from inside a trial ──")
r = Router(); r.go("hub"); r.go("trial", {"id": "false_witness"})
check("back from trial returns to the hub", (r.back(), r.route), (True, "hub"))

print("\n── back unwinds a deep stack one level at a time ──")
r = Router(); r.go("hub"); r.go("profile"); r.go("visage")
r.back(); check("visage -> profile", r.route, "profile")
r.back(); check("profile -> hub", r.route, "hub")
check("hub is root; back not consumed", r.back(), False)

print("\n── a trial can intercept back to confirm forfeit ──")
r = Router(); r.go("hub"); r.go("trial"); r.screen_consumes = True
check("screen consumes back", r.back(), True)
check("still on trial", r.route, "trial")

print("\n── root routes reset the stack (no unbounded history) ──")
r = Router(); r.go("hub"); r.go("profile"); r.go("hub")
check("stack cleared by root route", len(r.stack), 0)

print("\n── V1 BUG: Samsung killed the app in background, game fully reloaded ──")
NOW = 1_000_000
r, mode = boot({"route": "progress", "payload": {}, "unix": NOW - 120}, True, NOW)
check("resumes to progress after 2 min away", (mode, r.route), ("resumed", "progress"))

r, mode = boot({"route": "trial", "payload": {}, "unix": NOW - 120}, True, NOW)
check("never resumes mid-trial", (mode, r.route), ("cold", BOOT_ROUTE))

r, mode = boot({"route": "hub", "payload": {}, "unix": NOW - 2 * 60 * 60}, True, NOW)
check("stale session (2h) -> fresh boot", (mode, r.route), ("cold", BOOT_ROUTE))

r, mode = boot({}, False, NOW)
check("first ever run -> consent", (mode, r.route), ("consent", "consent"))

print("\n── consent can never be skipped by a resumable session ──")
r, mode = boot({"route": "hub", "payload": {}, "unix": NOW - 30}, False, NOW)
check("unaccepted consent still gates", mode, "consent")

print("\n── startup uses replace(), so back can't re-enter the ident ──")
r = Router(); r.go("splash"); r.replace("consent"); r.replace("hub")
check("stack empty after startup", len(r.stack), 0)
check("back at hub -> confirm quit", r.back(), False)

print("\n── deleted screens leave no dangling references ──")
# screens/sponsor/ and screens/loading/ were Phase 2 work superseded by the
# splash. They stayed routable for months after nothing navigated to them; a
# route pointing at a deleted scene is exactly the failure that broke five
# routes in Phase 9, so the constants are checked, not assumed.
# `intro` joins them: the four-line tap-through carousel is gone, and startup
# is consent-or-hub. This is the check that proves the purge is COMPLETE
# rather than merely unreferenced — a surviving route to a deleted scene is
# exactly the failure that broke five routes in Phase 9.
for gone in ("sponsor", "loading", "home", "intro"):
    check(f"'{gone}' no longer a declared route", gone in DECLARED_ROUTES, False)
    check(f"'{gone}' no longer a ROOT route", gone in ROOT_ROUTES, False)
    check(f"'{gone}' no longer in NO_RESUME", gone in NO_RESUME, False)
    check(f"screens/{gone}/ deleted", (ROOT / "screens" / gone).exists(), False)

check("every declared route resolves to a real scene",
      sorted(n for n, p in DECLARED_ROUTES.items() if not (ROOT / p).exists()), [])
check("the boot route is declared", BOOT_ROUTE in DECLARED_ROUTES, True)
check("the boot route is never resumed into", BOOT_ROUTE in NO_RESUME, True)

print("\n── a stored route that no longer exists must not crash the boot ──")
# Sessions persist across updates, so an install whose last session was on a
# since-deleted route would call Router.go() with an unknown id — and Router
# guards that with Log.must(), which hard-asserts in a debug build. Verified
# reachable before `home` was removed: write_session("home") round-tripped.
APP_SRC = (ROOT / "app/app.gd").read_text()
check("app validates a stored route against the table",
      "Router.ROUTES.has(route)" in APP_SRC, True)
check("an unknown stored route is logged, not silently dropped",
      "dropping stale session route" in APP_SRC, True)


def boot_with_unknown(route: str):
    """A session naming a route the build no longer ships."""
    r = Router()
    known = route in DECLARED_ROUTES
    if known and route not in NO_RESUME:
        r.go(route)
        return r, "resumed"
    r.go(BOOT_ROUTE)
    return r, "cold"


r, mode = boot_with_unknown("home")
check("a deleted route falls back to the boot route", (mode, r.route),
      ("cold", BOOT_ROUTE))
r, mode = boot_with_unknown("hub")
check("a live route still resumes", (mode, r.route), ("resumed", "hub"))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
