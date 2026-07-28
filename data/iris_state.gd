extends Resource
class_name IrisState
## IrisState — the complete, typed view model for the procedural Iris hub portal.
##
## PHASE 1 CONTRACT. This is a pure data container:
##   · no UI nodes, no scene instances, no $Node / %Node accessors
##   · no texture or audio paths of any kind (the eye is 100% procedural)
##   · no navigation, no Router, no scene changes
##   · no behaviour beyond deriving values from its own fields
##
## Everything the eye renders is computed from this object. The view (Phase 3)
## receives one IrisState and draws; it never queries a system for anything.
##
## v1 lessons encoded here:
##   · v1's IrisCore read NINE autoloads directly. This object is the single
##     inbound surface, so the view can read zero.
##   · v1 randomised trait positions on every _apply_traits() call, so a
##     player's freckles moved on every relaunch. Every procedural feature here
##     derives from a STABLE seed (see derive_seed_from_sku / cosmetic seeds).
##   · v1 capped evolution at 8 textures with an ad-hoc "cycle" hack past Lv 80.
##     Rank scaling here is mathematically uncapped by construction.

# ═════════════════════════════════════════════════════════════════════════
# ENUMS & CONSTANTS
# ═════════════════════════════════════════════════════════════════════════

## Compass shards on the iris rim. Values are stable and persisted — never
## reorder; append only.
enum CompassShard {
	NONE = 0,
	NORTH_TRIALS = 1,
	EAST_PROGRESS = 2,
	SOUTH_DAILY = 3,
	WEST_PROFILE = 4,
	NORTHEAST_TREND = 5,
}

## Seasonal presentation. 0 follows the system clock; 1-5 force a look.
enum Season {
	AUTO = 0,
	SPRING = 1,
	SUMMER = 2,
	AUTUMN = 3,
	WINTER = 4,
	HOLIDAY = 5,
}

## Cosmetic layers. Each maps to an independent rule dictionary so slots can
## never collide or overwrite one another.
enum CosmeticLayer {
	HEADPIECE = 0,   # crowns, tiaras, horns, halos
	FRAME = 1,       # earrings, monocles, glasses, vines
	LIMB = 2,        # peeking hands, little feet, wings, tentacles
	AURA = 3,        # snow, sparks, matrix code, cosmic dust
}

# ── Anchor slots on the almond eyelid frame ──────────────────────────────
## Offsets are in the eye's local, unscaled design space (a 360 px reference
## square). The view multiplies by its own scale factor. Kept as pure geometry
## so cosmetics can mount without knowing anything about the eye's internals.
const ANCHOR_TOP_ARC: StringName = &"TOP_ARC"
const ANCHOR_BOTTOM_ARC: StringName = &"BOTTOM_ARC"
const ANCHOR_LEFT_HINGE: StringName = &"LEFT_HINGE"
const ANCHOR_RIGHT_HINGE: StringName = &"RIGHT_HINGE"

const ANCHOR_OFFSETS: Dictionary = {
	ANCHOR_TOP_ARC: Vector2(0, -120),      # flush along the upper eyelid arch
	ANCHOR_BOTTOM_ARC: Vector2(0, 120),    # flush along the lower eyelid arch
	ANCHOR_LEFT_HINGE: Vector2(-180, 0),   # outer left eyelid corner
	ANCHOR_RIGHT_HINGE: Vector2(180, 0),   # outer right eyelid corner
}

# ── Infinite rank curve ──────────────────────────────────────────────────
## Cumulative XP to first reach rank R:  BASE * (R - 1) ^ EXPONENT
## Chosen because it is exactly invertible, strictly monotonic, and unbounded —
## there is no rank 200 wall, no lookup table, and no special case for high
## ranks. Reference schema: legacy IrisProgression used
## level = floor((lumina / divisor) ^ exponent); same family, uncapped.
const RANK_XP_BASE: float = 100.0
const RANK_XP_EXPONENT: float = 1.35

## Complexity scaling for procedural detail (fiber density, spike count,
## ornament layers). Logarithmic so rank 10,000 is richer than rank 100 without
## becoming unrenderable.
const RANK_COMPLEXITY_SCALE: float = 0.25

## Named rank bands. Past the last name the title escalates procedurally with a
## numeral suffix, so titles are infinite too.
const RANK_TITLES: Array[String] = [
	"Observer", "Seer", "Sentinel", "Oracle",
	"Witness", "Luminary", "Eternal", "Transcendent",
]
const RANKS_PER_TITLE: int = 25

# ── Rentals & drops ──────────────────────────────────────────────────────
const RENTAL_DURATION_SEC: int = 7 * 86400        # 7-day cosmetic passes
const SURPRISE_DROP_MIN: int = 5
const SURPRISE_DROP_MAX: int = 10


# ═════════════════════════════════════════════════════════════════════════
# A. INFINITE PROGRESSION & ECONOMY
# ═════════════════════════════════════════════════════════════════════════

@export var level: int = 1
@export var lumina: int = 0
## Mathematically uncapped. Nothing in this class special-cases a maximum.
@export var rank_tier: int = 1
@export var rank_xp: int = 0
## Resonance ◈ — the premium/earned currency, spent in the Wardrobe.
@export var lens_shimmer: float = 0.0
@export var streak_days: int = 0
## Highest streak ever reached. Never decreases, so a broken streak still
## leaves the player something they earned.
@export var best_streak_days: int = 0

## Lifetime completed trials, and cumulative seconds spent in them. Together
## these give the average completion time the Progress view reports.
@export var trials_completed: int = 0
@export var total_trial_seconds: float = 0.0


# ═════════════════════════════════════════════════════════════════════════
# B. LEGACY SCHEMA MIRRORS
# ═════════════════════════════════════════════════════════════════════════
## Read-only mirrors of a v1 profile, retained ONLY so a migration can be
## audited and re-run. Nothing in the live game reads these; the game reads the
## converted v2 fields in section A. Mapping happens in map_legacy_profile_data().

@export var legacy_user_account_id: String = ""
@export var legacy_rank_raw_xp: int = 0
@export var legacy_currency_balance: int = 0
@export var legacy_unlocked_skus: Array[String] = []


# ═════════════════════════════════════════════════════════════════════════
# C. INTERACTION & STATE DRIVERS
# ═════════════════════════════════════════════════════════════════════════
## Written by the interaction controller (Phase 2), read by the view (Phase 3).
## The view never computes these itself.

## 0.0 = fully constricted, 1.0 = fully dilated. 0.5 is the resting baseline.
@export var pupil_dilation_target: float = 0.5
## Normalised gaze direction, length clamped to 1.0 by set_gaze().
@export var gaze_vector: Vector2 = Vector2.ZERO
## Which compass shard is hovered. See CompassShard.
@export var active_compass_shard_id: int = 0
## 0.0 = hub view, 1.0 = fully zoomed into a destination portal.
@export var portal_transition_state: float = 0.0

## Route name whose glyph is previewing inside the pupil, "" for none.
##
## The state carries a ROUTE STRING, not a texture and not a shard id. The
## view resolves it to a VisionGlyph and draws primitives; it never learns
## what a route means. v1 stored an artwork path here, which is how the eye
## ended up knowing every screen's filename.
@export var vision_route: String = ""

## 0..1 reveal of the pupil vision. Driven by the controller's tween so the
## view stays a pure function of state and never owns an animation.
@export var vision_reveal: float = 0.0

## False until the player has returned from their first trial.
##
## Mirrors Save.has_returned_from_trial() into the view model so the renderer
## and the hub controller read ONE value. The view uses it to suppress
## compass hit-testing entirely: on a first run the eye is a button, not a
## dial, and a drag must not preview a destination the player cannot reach.
@export var nav_unlocked: bool = false


# ═════════════════════════════════════════════════════════════════════════
# D. DYNAMIC PROCEDURAL COSMETIC STATE
# ═════════════════════════════════════════════════════════════════════════
## Rule dictionaries describe HOW to draw a cosmetic procedurally — seed, layer
## count, colour keys, anchor slot, scale. They never contain file paths.
## The Hub is a READ-ONLY view of these; only the Wardrobe writes them.

@export var equipped_headpiece_rules: Dictionary = {}
@export var equipped_frame_rules: Dictionary = {}
@export var equipped_limb_rules: Dictionary = {}
@export var equipped_aura_rules: Dictionary = {}

## Permanently owned procedural seeds. A seed IS the cosmetic — the same seed
## always generates the same ornament, forever.
@export var unlocked_cosmetic_seeds: Array[int] = []

## Rental pack id -> unix expiry timestamp.
##
## NOTE: typed Dictionary syntax (Dictionary[StringName, float]) is Godot 4.4+.
## This project targets 4.3, where it is a hard parse error that cascades into
## every dependent script. Keys are StringName and values float by convention,
## enforced at the accessor boundary in grant_rental()/is_rental_active().
@export var active_rental_passes: Dictionary = {}

## Per-trial adaptive difficulty history, keyed by trial id:
##   { scores: Array[float], bracket: int, plays: int, best: float }
##
## Seeded from TrialRegistry.all_ids(), never a hardcoded list. v1 kept a
## separate array in SaveSystem that omitted facet_cascade, permanently
## pinning 20% of trials to Easy with adaptation silently disabled.
@export var trial_history: Dictionary = {}


# ═════════════════════════════════════════════════════════════════════════
# E. ENGAGEMENT & MONETIZATION COUNTERS
# ═════════════════════════════════════════════════════════════════════════

## Lifetime total of rewarded/interstitial ads watched. Monotonic.
@export var ad_watch_count: int = 0
## Absolute ad_watch_count at which the next surprise drop fires. Re-rolled to
## a fresh 5-10 window each time one lands, so the cadence stays unpredictable.
@export var next_surprise_drop_threshold: int = 7


# ═════════════════════════════════════════════════════════════════════════
# F. ENVIRONMENT & TEMPORAL TRIGGERS
# ═════════════════════════════════════════════════════════════════════════

@export var season_override: int = 0
## 0.0 = cool daylight, 1.0 = warm night.
@export var time_of_day_warmth: float = 0.5
## Per-day ambient drift. Colour token, not a literal — see Palette.
@export var ambient_mood_color: Color = Color.WHITE
@export var reduced_motion: bool = false


# ── Non-serialised ───────────────────────────────────────────────────────
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


# ═════════════════════════════════════════════════════════════════════════
# INFINITE RANK MATHEMATICS
# ═════════════════════════════════════════════════════════════════════════

## Logarithmic complexity factor driving procedural density — fiber count,
## spike count, ornament layer depth. Grows forever, but slowly enough that
## rank 100,000 still renders.
##   rank 1 -> 1.17 · rank 100 -> 2.15 · rank 10,000 -> 3.30
func get_rank_complexity_factor(rank: int) -> float:
	var safe_rank: int = maxi(rank, 0)
	return 1.0 + log(1.0 + float(safe_rank)) * RANK_COMPLEXITY_SCALE


## Complexity factor for this state's current rank.
func current_complexity_factor() -> float:
	return get_rank_complexity_factor(rank_tier)


## Turn the complexity factor into a concrete element count, clamped so the
## renderer always has a hard upper bound no matter how absurd the rank.
func procedural_element_count(base_count: int, max_count: int) -> int:
	if not Log.must(base_count >= 0, "IrisState", "base_count must be >= 0"):
		return 0
	if not Log.must(max_count >= base_count, "IrisState", "max_count < base_count"):
		return base_count
	var scaled: int = int(round(float(base_count) * current_complexity_factor()))
	return clampi(scaled, base_count, max_count)


## Cumulative XP required to first reach `rank`. Rank 1 is the starting rank
## and costs nothing. Unbounded above.
func cumulative_xp_for_rank(rank: int) -> int:
	if rank <= 1:
		return 0
	return int(ceil(RANK_XP_BASE * pow(float(rank - 1), RANK_XP_EXPONENT)))


## Exact inverse of cumulative_xp_for_rank(). No table, no cap.
func rank_for_total_xp(total_xp: int) -> int:
	if total_xp <= 0:
		return 1
	var ratio: float = float(total_xp) / RANK_XP_BASE
	return 1 + int(floor(pow(ratio, 1.0 / RANK_XP_EXPONENT)))


## XP still required to reach the next rank.
func xp_to_next_rank() -> int:
	return maxi(cumulative_xp_for_rank(rank_tier + 1) - rank_xp, 0)


## Progress through the current rank band, 0.0-1.0.
func rank_progress() -> float:
	var floor_xp: int = cumulative_xp_for_rank(rank_tier)
	var ceil_xp: int = cumulative_xp_for_rank(rank_tier + 1)
	var span: int = ceil_xp - floor_xp
	if span <= 0:
		return 0.0
	return clampf(float(rank_xp - floor_xp) / float(span), 0.0, 1.0)


## Infinite rank title: named bands first, then procedural numeral escalation
## ("Transcendent II", "Transcendent III", ...). Never returns empty.
func rank_title(rank: int) -> String:
	var safe_rank: int = maxi(rank, 1)
	# Deliberate floor: ranks 1..RANKS_PER_TITLE are band 0, the next block is
	# band 1, and so on. Integer division is the operation being asked for and
	# stays exact at ranks a float round-trip would start rounding.
	@warning_ignore("integer_division")
	var band: int = (safe_rank - 1) / RANKS_PER_TITLE
	var name_count: int = RANK_TITLES.size()
	if band < name_count:
		return RANK_TITLES[band]
	var final_name: String = RANK_TITLES[name_count - 1]
	var cycle: int = band - name_count + 2
	return "%s %s" % [final_name, _numeral(cycle)]


func current_rank_title() -> String:
	return rank_title(rank_tier)


## Award XP and recompute rank. Returns the number of ranks gained (0 if none).
func add_rank_xp(amount: int) -> int:
	if not Log.must(amount >= 0, "IrisState", "cannot award negative XP"):
		return 0
	var before: int = rank_tier
	rank_xp += amount
	rank_tier = rank_for_total_xp(rank_xp)
	return maxi(rank_tier - before, 0)


## Small Roman-ish numeral for infinite title escalation. Falls back to digits
## beyond a sane range so it can never fail or loop forever.
func _numeral(n: int) -> String:
	if n <= 1:
		return "I"
	if n > 39:
		return str(n)
	const VALUES: Array[int] = [10, 9, 5, 4, 1]
	const GLYPHS: Array[String] = ["X", "IX", "V", "IV", "I"]
	var out: String = ""
	var remaining: int = n
	for i in range(VALUES.size()):
		while remaining >= VALUES[i]:
			out += GLYPHS[i]
			remaining -= VALUES[i]
	return out


# ═════════════════════════════════════════════════════════════════════════
# ANCHOR GEOMETRY
# ═════════════════════════════════════════════════════════════════════════

## Standard mount offsets relative to the almond eyelid frame, in the eye's
## local design space. Pure geometry — no node lookups, no sprite sizing.
## Unknown slots fail loudly in debug and return ZERO in release.
func get_anchor_offset(slot_name: StringName) -> Vector2:
	if not Log.must(
			ANCHOR_OFFSETS.has(slot_name),
			"IrisState",
			"unknown anchor slot '%s'" % slot_name):
		return Vector2.ZERO
	return ANCHOR_OFFSETS[slot_name]


## Every valid anchor slot name. Lets the Wardrobe enumerate mount points
## without hardcoding the list.
func anchor_slot_names() -> Array:
	return ANCHOR_OFFSETS.keys()


# ═════════════════════════════════════════════════════════════════════════
# COSMETIC OWNERSHIP & RENTAL VALIDATION
# ═════════════════════════════════════════════════════════════════════════

## True if the seed is permanently owned.
func owns_seed(seed_value: int) -> bool:
	return unlocked_cosmetic_seeds.has(seed_value)


## Grant permanent ownership. Idempotent; returns true if newly granted.
func grant_seed(seed_value: int) -> bool:
	if unlocked_cosmetic_seeds.has(seed_value):
		return false
	unlocked_cosmetic_seeds.append(seed_value)
	return true


## True if a rental pass is present AND not yet expired.
func is_rental_active(pack_id: StringName, now_unix: float = -1.0) -> bool:
	if not active_rental_passes.has(pack_id):
		return false
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	return active_rental_passes[pack_id] > now


## Seconds left on a rental, or 0.0 if absent/expired.
func rental_seconds_remaining(pack_id: StringName, now_unix: float = -1.0) -> float:
	if not active_rental_passes.has(pack_id):
		return 0.0
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	return maxf(active_rental_passes[pack_id] - now, 0.0)


## Whole days left on a rental, rounded up — for "3 days left" style copy.
func rental_days_remaining(pack_id: StringName, now_unix: float = -1.0) -> int:
	var secs: float = rental_seconds_remaining(pack_id, now_unix)
	if secs <= 0.0:
		return 0
	return int(ceil(secs / 86400.0))


## Absolute UTC expiry timestamp for a pack, or 0 when none is stored.
##
## READ-ONLY VIEW over active_rental_passes. Added so UI layers (the Trend Hub
## cards) can render an exact expiry without reaching into the dictionary and
## without a second store of the same fact.
##
## Returns an int because a unix timestamp is a whole number of seconds; the
## underlying float carries sub-second precision no caller needs and which
## would render as "1785053364.78505" if it ever reached a label.
##
## NOTE: 0 means "no pass recorded", which is distinct from "expired". An
## expired pass still returns its (past) timestamp until prune_expired_rentals()
## removes it, so a caller can honestly say "expired 2 days ago". Callers
## deciding whether play is allowed must use is_rental_active(), not this.
func get_pack_expires_utc(pack_id: StringName) -> int:
	if not active_rental_passes.has(pack_id):
		return 0
	return int(active_rental_passes[pack_id])


## Start or extend a rental pass. Duration defaults to the 7-day window.
func grant_rental(pack_id: StringName, now_unix: float = -1.0,
		duration_sec: int = RENTAL_DURATION_SEC) -> void:
	if not Log.must(duration_sec > 0, "IrisState", "rental duration must be > 0"):
		return
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	active_rental_passes[pack_id] = now + float(duration_sec)


## Access = permanent seed ownership OR an unexpired rental. Ownership wins, so
## a lapsed rental never revokes something the player actually earned.
func has_cosmetic_access(seed_value: int, pack_id: StringName,
		now_unix: float = -1.0) -> bool:
	if owns_seed(seed_value):
		return true
	return is_rental_active(pack_id, now_unix)


## Drop expired passes. Returns how many were removed, so a caller can decide
## whether to re-evaluate equipped cosmetics.
func prune_expired_rentals(now_unix: float = -1.0) -> int:
	var now: float = now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()
	var expired: Array[StringName] = []
	for pack_id: StringName in active_rental_passes.keys():
		if active_rental_passes[pack_id] <= now:
			expired.append(pack_id)
	for pack_id: StringName in expired:
		active_rental_passes.erase(pack_id)
	return expired.size()


## The rule dictionary for a cosmetic layer. Returns an empty dict for unknown
## layers rather than crashing a render pass.
func rules_for_layer(layer: CosmeticLayer) -> Dictionary:
	match layer:
		CosmeticLayer.HEADPIECE:
			return equipped_headpiece_rules
		CosmeticLayer.FRAME:
			return equipped_frame_rules
		CosmeticLayer.LIMB:
			return equipped_limb_rules
		CosmeticLayer.AURA:
			return equipped_aura_rules
	Log.must(false, "IrisState", "unknown cosmetic layer %d" % int(layer))
	return {}


## Assign the rule dictionary for a layer. WARDROBE ONLY — the hub is a
## read-only view and its test suite forbids calling this.
func set_layer_rules(layer: CosmeticLayer, rules: Dictionary) -> void:
	match layer:
		CosmeticLayer.HEADPIECE:
			equipped_headpiece_rules = rules
		CosmeticLayer.FRAME:
			equipped_frame_rules = rules
		CosmeticLayer.LIMB:
			equipped_limb_rules = rules
		CosmeticLayer.AURA:
			equipped_aura_rules = rules
		_:
			Log.must(false, "IrisState", "unknown cosmetic layer %d" % int(layer))


## Unequip a layer.
func clear_layer(layer: CosmeticLayer) -> void:
	set_layer_rules(layer, {})


## The equipped cosmetic id for a layer, or "" if the slot is empty.
func equipped_id_for_layer(layer: CosmeticLayer) -> String:
	return str(rules_for_layer(layer).get("id", ""))


## Atomically spend Lumina. Returns false and changes nothing if the balance is
## insufficient, so a caller can never drive the currency negative by forgetting
## to check first.
func spend_lumina(cost: int) -> bool:
	if not Log.must(cost >= 0, "IrisState", "cannot spend negative Lumina"):
		return false
	if lumina < cost:
		return false
	lumina -= cost
	return true


## True if any cosmetic is equipped in any layer.
func has_any_cosmetic() -> bool:
	return not (equipped_headpiece_rules.is_empty()
		and equipped_frame_rules.is_empty()
		and equipped_limb_rules.is_empty()
		and equipped_aura_rules.is_empty())


# ═════════════════════════════════════════════════════════════════════════
# ENGAGEMENT COUNTERS
# ═════════════════════════════════════════════════════════════════════════

## Record one watched ad. Returns true when this watch triggers a surprise drop,
## in which case the next threshold is re-rolled to a fresh 5-10 window.
##
## ad_watch_count stays a lifetime total; the threshold is an ABSOLUTE target,
## so the two never drift out of sync the way a "count since last drop" pair can.
func register_ad_watch() -> bool:
	ad_watch_count += 1
	if ad_watch_count < next_surprise_drop_threshold:
		return false
	roll_next_surprise_threshold()
	return true


## Re-roll the next surprise drop target to ad_watch_count + [5, 10].
func roll_next_surprise_threshold() -> void:
	next_surprise_drop_threshold = ad_watch_count + _rng.randi_range(
		SURPRISE_DROP_MIN, SURPRISE_DROP_MAX)


## Ads remaining until the next surprise drop. Never negative.
func ads_until_surprise_drop() -> int:
	return maxi(next_surprise_drop_threshold - ad_watch_count, 0)


# ═════════════════════════════════════════════════════════════════════════
# LEGACY PROFILE MAPPING
# ═════════════════════════════════════════════════════════════════════════

## Translate a raw v1 profile dictionary into v2 state.
##
## Stores the untouched mirrors (section B) for audit, then derives the live v2
## values: Lumina balance, rank from converted XP, Resonance, streak, and a
## permanent procedural seed for every legacy store SKU the player owned.
##
## Accepts missing keys — a partial legacy profile converts what it can rather
## than failing the whole migration.
func map_legacy_profile_data(raw_dict: Dictionary) -> void:
	if not Log.must(not raw_dict.is_empty(), "IrisState",
			"map_legacy_profile_data received an empty dictionary"):
		return

	# ── 1. Mirror the raw schema verbatim (audit trail) ──────────────────
	legacy_user_account_id = str(raw_dict.get("account_id", ""))
	legacy_rank_raw_xp = int(raw_dict.get("raw_xp", 0))
	legacy_currency_balance = int(raw_dict.get("currency_balance", 0))

	legacy_unlocked_skus.clear()
	var raw_skus: Array = raw_dict.get("unlocked_skus", [])
	for entry: Variant in raw_skus:
		var sku: String = str(entry)
		if sku != "" and not legacy_unlocked_skus.has(sku):
			legacy_unlocked_skus.append(sku)

	# ── 2. Derive live v2 economy ────────────────────────────────────────
	# Legacy Lumina carries across 1:1; it was already the primary XP currency.
	lumina = maxi(legacy_rank_raw_xp, 0)
	rank_xp = lumina
	rank_tier = rank_for_total_xp(rank_xp)
	level = maxi(int(raw_dict.get("level", rank_tier)), 1)

	# Legacy Resonance -> Lens Shimmer, 1:1.
	lens_shimmer = maxf(float(legacy_currency_balance), 0.0)
	streak_days = maxi(int(raw_dict.get("streak_days", 0)), 0)

	# ── 3. Convert owned SKUs into permanent procedural seeds ────────────
	for sku: String in legacy_unlocked_skus:
		grant_seed(derive_seed_from_sku(sku))

	# ── 4. Carry engagement counters, keeping the drop cadence sane ──────
	ad_watch_count = maxi(int(raw_dict.get("ad_watch_count", 0)), 0)
	if next_surprise_drop_threshold <= ad_watch_count:
		roll_next_surprise_threshold()

	Log.info("IrisState", "migrated legacy profile '%s': rank %d, %d seeds" % [
		legacy_user_account_id, rank_tier, unlocked_cosmetic_seeds.size(),
	])


## Deterministic 32-bit FNV-1a hash of a SKU string.
##
## A seed IS the cosmetic's appearance, permanently. We deliberately do NOT use
## String.hash(), whose value is an engine implementation detail — if it ever
## changed, every migrated player's ornaments would silently transform. FNV-1a
## is fully specified and stable across engine versions and platforms.
static func derive_seed_from_sku(sku: String) -> int:
	var hash_value: int = 2166136261
	for i: int in range(sku.length()):
		hash_value ^= sku.unicode_at(i)
		hash_value = (hash_value * 16777619) & 0xFFFFFFFF
	return hash_value


# ═════════════════════════════════════════════════════════════════════════
# INTERACTION SETTERS (clamped)
# ═════════════════════════════════════════════════════════════════════════
## Clamping lives here, not in the view, so no renderer can be handed an
## out-of-range value.

func set_gaze(direction: Vector2) -> void:
	gaze_vector = direction.limit_length(1.0)


func set_dilation(value: float) -> void:
	pupil_dilation_target = clampf(value, 0.0, 1.0)


func set_portal_transition(value: float) -> void:
	portal_transition_state = clampf(value, 0.0, 1.0)


## Show a destination glyph in the pupil. "" clears it.
##
## Rejects a route with no glyph rather than storing it: a state that names a
## symbol which cannot be drawn would leave the view silently blank, which is
## the class of bug that hid the invisible Iris for the life of the project.
func set_vision(route: String) -> void:
	if route == "":
		vision_route = ""
		vision_reveal = 0.0
		return
	if not Log.must(VisionGlyph.for_route(route) != null,
			"IrisState", "no vision glyph for route '%s'" % route):
		vision_route = ""
		vision_reveal = 0.0
		return
	vision_route = route


func set_vision_reveal(value: float) -> void:
	vision_reveal = clampf(value, 0.0, 1.0)


## True when a glyph is both named and at least partly visible. The view uses
## this rather than testing the string, so "named but fully faded out" counts
## as not showing.
func is_vision_visible() -> bool:
	return vision_route != "" and vision_reveal > 0.001


## Gate compass interaction. Set from Save.has_returned_from_trial().
func set_nav_unlocked(unlocked: bool) -> void:
	nav_unlocked = unlocked


## Highest valid shard id, DERIVED from the enum rather than named.
##
## THE BUG THIS FIXES: the guard below hard-coded `<= CompassShard.WEST_PROFILE`
## (4). Adding NORTHEAST_TREND = 5 for the Trend Hub therefore made hovering
## that shard fail its own invariant — a hard assert in debug, every time the
## player's finger crossed the north-east arc of the eye. The enum and the
## validator were two places that had to agree, and they stopped agreeing the
## moment the enum grew.
##
## values().max() cannot go stale: append a shard and the bound follows.
static func max_shard_id() -> int:
	var highest: int = 0
	for value: int in CompassShard.values():
		highest = maxi(highest, value)
	return highest


func set_compass_shard(shard_id: int) -> void:
	if not Log.must(
			shard_id >= CompassShard.NONE and shard_id <= max_shard_id(),
			"IrisState", "invalid compass shard id %d" % shard_id):
		active_compass_shard_id = CompassShard.NONE
		return
	active_compass_shard_id = shard_id


func is_shard_active() -> bool:
	return active_compass_shard_id != CompassShard.NONE


## Reset transient interaction fields. Persistent progression is untouched.
func clear_interaction() -> void:
	gaze_vector = Vector2.ZERO
	pupil_dilation_target = 0.5
	active_compass_shard_id = CompassShard.NONE
	portal_transition_state = 0.0
	# The vision is interaction state, not progression: leaving the hub with
	# a preview open must not restore it on return.
	vision_route = ""
	vision_reveal = 0.0


# ═════════════════════════════════════════════════════════════════════════
# SERIALISATION
# ═════════════════════════════════════════════════════════════════════════
## JSON-safe round trip for core/save.gd. Transient interaction fields
## (section C) are deliberately excluded — gaze and hover must never persist
## across a session.

func to_dict() -> Dictionary:
	var rentals: Dictionary = {}
	for pack_id: StringName in active_rental_passes.keys():
		rentals[String(pack_id)] = active_rental_passes[pack_id]

	return {
		"level": level,
		"lumina": lumina,
		"rank_tier": rank_tier,
		"rank_xp": rank_xp,
		"lens_shimmer": lens_shimmer,
		"streak_days": streak_days,
		"best_streak_days": best_streak_days,
		"trials_completed": trials_completed,
		"total_trial_seconds": total_trial_seconds,

		"legacy_user_account_id": legacy_user_account_id,
		"legacy_rank_raw_xp": legacy_rank_raw_xp,
		"legacy_currency_balance": legacy_currency_balance,
		"legacy_unlocked_skus": legacy_unlocked_skus,

		"equipped_headpiece_rules": equipped_headpiece_rules,
		"equipped_frame_rules": equipped_frame_rules,
		"equipped_limb_rules": equipped_limb_rules,
		"equipped_aura_rules": equipped_aura_rules,
		"unlocked_cosmetic_seeds": unlocked_cosmetic_seeds,
		"active_rental_passes": rentals,
		"trial_history": trial_history,

		"ad_watch_count": ad_watch_count,
		"next_surprise_drop_threshold": next_surprise_drop_threshold,

		"season_override": season_override,
	}


func from_dict(data: Dictionary) -> void:
	if not Log.must(not data.is_empty(), "IrisState", "from_dict got empty data"):
		return

	level = int(data.get("level", 1))
	lumina = int(data.get("lumina", 0))
	rank_tier = maxi(int(data.get("rank_tier", 1)), 1)
	rank_xp = int(data.get("rank_xp", 0))
	lens_shimmer = float(data.get("lens_shimmer", 0.0))
	streak_days = int(data.get("streak_days", 0))
	best_streak_days = int(data.get("best_streak_days", 0))
	trials_completed = int(data.get("trials_completed", 0))
	total_trial_seconds = float(data.get("total_trial_seconds", 0.0))

	legacy_user_account_id = str(data.get("legacy_user_account_id", ""))
	legacy_rank_raw_xp = int(data.get("legacy_rank_raw_xp", 0))
	legacy_currency_balance = int(data.get("legacy_currency_balance", 0))
	legacy_unlocked_skus = _to_string_array(data.get("legacy_unlocked_skus", []))

	equipped_headpiece_rules = data.get("equipped_headpiece_rules", {})
	equipped_frame_rules = data.get("equipped_frame_rules", {})
	equipped_limb_rules = data.get("equipped_limb_rules", {})
	equipped_aura_rules = data.get("equipped_aura_rules", {})
	unlocked_cosmetic_seeds = _to_int_array(data.get("unlocked_cosmetic_seeds", []))
	trial_history = data.get("trial_history", {})

	active_rental_passes.clear()
	var rentals: Dictionary = data.get("active_rental_passes", {})
	for key: Variant in rentals.keys():
		active_rental_passes[StringName(str(key))] = float(rentals[key])

	ad_watch_count = maxi(int(data.get("ad_watch_count", 0)), 0)
	next_surprise_drop_threshold = int(data.get("next_surprise_drop_threshold", 7))
	season_override = int(data.get("season_override", 0))

	# Transient fields are never restored.
	clear_interaction()


## Deep copy. Guards against Godot's resource cache handing two systems the
## same instance — a real hazard once .tres presets exist.
func clone() -> IrisState:
	var copy: IrisState = IrisState.new()
	copy.from_dict(to_dict())
	copy.time_of_day_warmth = time_of_day_warmth
	copy.ambient_mood_color = ambient_mood_color
	copy.reduced_motion = reduced_motion
	return copy


func _to_string_array(source: Variant) -> Array[String]:
	var out: Array[String] = []
	if source is Array:
		for entry: Variant in (source as Array):
			out.append(str(entry))
	return out


func _to_int_array(source: Variant) -> Array[int]:
	var out: Array[int] = []
	if source is Array:
		for entry: Variant in (source as Array):
			out.append(int(entry))
	return out
