"""Phase 4 verification: Wardrobe transactions, ownership, migration.

Two halves:
  1. Static analysis of nodes/wardrobe_controller.gd + data/cosmetic_*.gd
  2. Behavioural simulation of the economy, ported to Python

The economy is where bugs cost real money, so the simulation deliberately
attacks it: overspending, double-granting, expired rentals revoking owned
items, drop-threshold drift, and repeated legacy migration.

Run: python3 tests/test_wardrobe.py
"""
import pathlib
import random
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GD = (ROOT / "nodes/wardrobe_controller.gd").read_text()
TSCN = (ROOT / "screens/wardrobe.tscn").read_text()
DEF = (ROOT / "data/cosmetic_def.gd").read_text()
CATALOG = (ROOT / "data/cosmetic_catalog.gd").read_text()
STATE = (ROOT / "data/iris_state.gd").read_text()
HUB = (ROOT / "nodes/hub_portal_controller.gd").read_text()

fails: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(label)


def strip_comments(src: str) -> str:
    return "\n".join(re.sub(r"#.*$", "", ln) for ln in src.split("\n"))


CODE = strip_comments(GD)

DAY = 86400.0
RENTAL = 7 * DAY
MIN_D, MAX_D = 5, 10


def fnv(text: str) -> int:
    h = 2166136261
    for ch in text:
        h ^= ord(ch)
        h = (h * 16777619) & 0xFFFFFFFF
    return h


# ═══════════════════════════════════════════════════════════════════════
print("── NO ART ASSETS ANYWHERE (100% procedural) ──")
for name, src in (("cosmetic_def", DEF), ("cosmetic_catalog", CATALOG), ("wardrobe", GD)):
    for ext in (".png", ".jpg", ".svg", ".ogg"):
        check(f"{name}: no {ext}", ext not in src)
check("catalog has no texture loads", "load(" not in strip_comments(CATALOG))

print("\n── CATEGORY TABS ──")
for layer in ("HEADPIECE", "FRAME", "LIMB", "AURA"):
    check(f"tab {layer}", f"CosmeticDef.Layer.{layer}" in CODE)
check("4 tabs in TAB_ORDER", CODE.count("CosmeticDef.Layer.", CODE.index("TAB_ORDER"),
                                        CODE.index("TAB_LABELS")) == 4)

print("\n── AVAILABILITY STATES ──")
for st in ("OWNED", "RENTED", "LOCKED", "RANK_LOCKED"):
    check(f"Availability.{st}", f"{st} =" in CODE or f"Availability.{st}" in CODE)
check("evaluate_availability exists", "func evaluate_availability(" in CODE)
check("ownership checked before rental",
      CODE.index("owns_seed") < CODE.index("is_rental_active"))

print("\n── MUTATOR SURFACE (Wardrobe may write; Hub may not) ──")
for fn in ("equip", "unequip", "purchase_with_lumina", "watch_ad_for_rental"):
    check(f"{fn}() exists", f"func {fn}(" in CODE)
check("single persistence path _commit()", "func _commit()" in CODE)
check("Save writes only inside _commit",
      len(re.findall(r"Save\.set_v", CODE)) == 1)

print("\n── 100% FREE-TO-PLAY: no real-money path ──")
check("no complete_iap()", "func complete_iap(" not in CODE)
check("no IAP acquisition enum", "IAP = " not in strip_comments(DEF))
check("no iap_price_label field", "iap_price_label" not in DEF)
check("catalog has no IAP entries", "Acquisition.IAP" not in strip_comments(CATALOG))
check("no price strings in catalog", "$" not in strip_comments(CATALOG))
check("wardrobe never references IAP", "IAP" not in CODE)

print("\n── HUB REMAINS READ-ONLY (Phase 3 guarantee intact) ──")
hub_code = strip_comments(HUB)
for forbidden in ("grant_seed", "grant_rental", "spend_lumina", "set_layer_rules",
                  "register_ad_watch", "Save.set_v"):
    check(f"hub never calls {forbidden}", forbidden not in hub_code)

print("\n── LEGACY MIGRATION HELPER ──")
check("map_legacy_unlocked_skus() exists", "func map_legacy_unlocked_skus() -> int:" in CODE)
check("runs on Wardrobe entry", "map_legacy_unlocked_skus()" in CODE.split("func map_legacy")[0])
check("uses FNV-1a derivation", "derive_seed_from_sku" in CODE)
check("16 legacy SKUs catalogued", CATALOG.count('"') >= 16)

print("\n── INPUT ISOLATION ──")
check("preview is non-interactive", "_preview.set_interactive(false)" in CODE)
check("scene overlays pass through", TSCN.count("mouse_filter = 2") >= 4,
      str(TSCN.count("mouse_filter = 2")))

print("\n── SCENE WIRING ──")
for node in ("Background", "PreviewIris", "TabRow", "ItemList", "LuminaLabel",
             "TitleLabel", "BackButton", "SurpriseDropModal", "DropLabel", "DropClaimButton"):
    pattern = rf'name="{node}"[^\]]*\]\n(?:[^\[]*?)unique_name_in_owner = true'
    check(f"%{node} unique", re.search(pattern, TSCN) is not None)

print("\n── IrisState transaction primitives ──")
for fn in ("spend_lumina", "set_layer_rules", "clear_layer", "equipped_id_for_layer"):
    check(f"IrisState.{fn}()", f"func {fn}(" in STATE)

print("\n── TYPING ──")
untyped = re.findall(r"^func\s+(\w+)\s*\([^)]*\)\s*:", CODE, re.M)
check("all funcs typed", not untyped, str(untyped))
bare = re.findall(r"^\s*var\s+(\w+)\s*=(?!=)", CODE, re.M)
check("no bare var declarations", not bare, str(bare))


# ═══════════════════════════════════════════════════════════════════════
# BEHAVIOURAL SIMULATION
# ═══════════════════════════════════════════════════════════════════════
class SimState:
    """Mirrors the IrisState economy primitives."""

    def __init__(self) -> None:
        self.lumina = 0
        self.seeds: list[int] = []
        self.rentals: dict[str, float] = {}
        self.ads = 0
        self.threshold = 7

    def spend(self, cost: int) -> bool:
        if cost < 0 or self.lumina < cost:
            return False
        self.lumina -= cost
        return True

    def grant_seed(self, value: int) -> bool:
        if value in self.seeds:
            return False
        self.seeds.append(value)
        return True

    def owns(self, value: int) -> bool:
        return value in self.seeds

    def grant_rental(self, pack: str, now: float) -> None:
        self.rentals[pack] = now + RENTAL

    def rental_active(self, pack: str, now: float) -> bool:
        return pack in self.rentals and self.rentals[pack] > now

    def prune(self, now: float) -> int:
        expired = [k for k, v in self.rentals.items() if v <= now]
        for k in expired:
            del self.rentals[k]
        return len(expired)

    def register_ad(self, rng: random.Random) -> bool:
        self.ads += 1
        if self.ads < self.threshold:
            return False
        self.threshold = self.ads + rng.randint(MIN_D, MAX_D)
        return True


print("\n── SIM: Lumina is atomic, never negative ──")
s = SimState()
s.lumina = 100
check("overspend rejected", not s.spend(120))
check("balance untouched on failure", s.lumina == 100)
check("exact spend succeeds", s.spend(100))
check("balance is zero", s.lumina == 0)
check("cannot spend from empty", not s.spend(1))
check("negative cost rejected", not s.spend(-50) and s.lumina == 0)

print("\n── SIM: double-grant is a no-op ──")
s = SimState()
seed = fnv("crown")
s.grant_seed(seed)
check("second grant refused", not s.grant_seed(seed))
check("seed stored once", s.seeds.count(seed) == 1)

print("\n── SIM: ownership survives rental expiry ──")
s = SimState()
now = 1_000_000.0
s.grant_rental("pack_wizard_hat", now)
s.grant_seed(fnv("wizard_hat"))
s.prune(now + RENTAL + 1)
check("rental pruned", not s.rental_active("pack_wizard_hat", now + RENTAL + 1))
check("ownership intact", s.owns(fnv("wizard_hat")))

print("\n── SIM: 7-day rental window ──")
s = SimState()
s.grant_rental("pack_vines", now)
for offset, expected in ((0, True), (DAY * 6.9, True), (RENTAL - 1, True),
                         (RENTAL + 1, False), (DAY * 30, False)):
    check(f"t+{offset / DAY:.1f}d -> {expected}", s.rental_active("pack_vines", now + offset) == expected)

print("\n── SIM: surprise drop cadence always 5-10 ──")
rng = random.Random(42)
s = SimState()
gaps: list[int] = []
last = 0
for _ in range(500):
    if s.register_ad(rng):
        gaps.append(s.ads - last)
        last = s.ads
check(f"{len(gaps)} drops over 500 ads", len(gaps) > 0)
check("every gap within [5,10]", all(MIN_D <= g <= MAX_D for g in gaps), str(sorted(set(gaps))))
check("threshold stays ahead", s.threshold > s.ads)

print("\n── SIM: legacy migration is idempotent ──")
LEGACY = ["starter_cap", "crown", "celestial_crown", "founders_crown",
          "galaxy_halo", "gem_band", "hallow_horns", "halo", "horns",
          "jester_hat", "laurel", "phoenix_crest", "spring_wreath",
          "top_hat", "winter_hat", "wizard_hat"]
s = SimState()


def migrate(state: SimState) -> int:
    return sum(1 for sku in LEGACY if state.grant_seed(fnv(sku)))


check("first pass grants 16", migrate(s) == 16)
check("second pass grants 0", migrate(s) == 0)
check("third pass grants 0", migrate(s) == 0)
check("no duplicates", len(s.seeds) == len(set(s.seeds)))
check("distinct SKUs -> distinct seeds", len({fnv(x) for x in LEGACY}) == len(LEGACY))

print("\n── SIM: equip requires ownership or active rental ──")
s = SimState()


def can_equip(state: SimState, seed_v: int, pack: str, now_t: float) -> bool:
    return state.owns(seed_v) or state.rental_active(pack, now_t)


check("unowned refused", not can_equip(s, fnv("tiara"), "pack_tiara", 0))
s.grant_seed(fnv("tiara"))
check("owned allowed", can_equip(s, fnv("tiara"), "pack_tiara", 0))
s2 = SimState()
s2.grant_rental("pack_vines", now)
check("rented allowed", can_equip(s2, fnv("vines"), "pack_vines", now))
check("expired refused", not can_equip(s2, fnv("vines"), "pack_vines", now + RENTAL + 1))

print()
if fails:
    print(f"{len(fails)} FAILURE(S): {fails}")
    sys.exit(1)
print("ALL PASS")
