extends Control
class_name CosmeticRenderer
## CosmeticRenderer — draws one procedural cosmetic with vector math.
##
## PHASE 5 CONTRACT. ZERO PNGs, zero textures, zero image assets. Every
## ornament is generated from a seed plus draw_rules via `_draw()` primitives.
##
## v1 shipped 16 hats as 1536x1024 PNGs (28.8 MB) that rendered as ~200 px
## overlays — roughly 50x the pixels it could display. This renders the same
## catalogue at any resolution for zero bytes, and scales detail with rank.
##
## DETERMINISM: all randomness comes from a seeded RNG. The same seed always
## draws the identical ornament, on every device and every launch. v1
## re-randomised trait positions on every _apply_traits() call, so a player's
## freckles moved on relaunch.
##
## INPUT: this node and every child it creates are MOUSE_FILTER_IGNORE, so a
## crown can never intercept a tap meant for the pupil.
##
## ANCHORING: position and rotation come from IrisView's anchor helpers
## (TOP_ARC / BOTTOM_ARC / LEFT_HINGE / RIGHT_HINGE). This node draws in its
## own local space around origin (0,0) and lets the mount place it.

## Design-space reference edge. Rules express sizes as fractions of this, so a
## cosmetic scales cleanly to any eye size.
const DESIGN_SIZE: float = 360.0

## Hard ceilings so a rank-1,000,000 player cannot melt a low-end GPU.
const MAX_SPIKES: int = 24
const MAX_LEAVES: int = 28
const MAX_FEATHERS: int = 32
const MAX_PARTICLES: int = 96
const MAX_TENDRILS: int = 16
const MAX_SEGMENTS: int = 18

var _rules: Dictionary = {}
var _seed: int = 0
var _complexity: float = 1.0
var _accent: Color = Color.WHITE
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _time: float = 0.0
var _animated: bool = false
var _reduced_motion: bool = false


func _ready() -> void:
	# Rule: decorations never take input.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(_animated and not _reduced_motion)


## Configure and redraw. `complexity` comes from
## IrisState.get_rank_complexity_factor() so ornament density grows with rank.
func configure(rules: Dictionary, complexity: float, accent: Color,
		reduced_motion: bool = false) -> void:
	_rules = rules
	_seed = int(rules.get("seed", 0))
	_complexity = maxf(complexity, 1.0)
	_accent = accent
	_reduced_motion = reduced_motion
	_rng.seed = _seed

	_animated = _rules.get("shape", "") == "particles" \
		or bool(_rules.get("orbit_motes", 0)) \
		or _rules.get("shape", "") in ["tentacle", "vine", "dangle", "wings"]
	set_process(_animated and not _reduced_motion)
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	queue_redraw()


## Element count scaled by rank, then hard-clamped. Base density is what a
## rank-1 player sees; the ceiling is what protects the frame budget.
func scaled_count(base: int, ceiling: int) -> int:
	var scaled: int = int(round(float(base) * _complexity))
	return clampi(scaled, base, ceiling)


## Reset the RNG before each draw so a redraw is byte-identical.
func _reseed() -> void:
	_rng.seed = _seed


func _unit() -> float:
	return minf(size.x, size.y) if size.x > 0.0 else DESIGN_SIZE


# ═════════════════════════════════════════════════════════════════════════
# DRAW DISPATCH
# ═════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	if _rules.is_empty():
		return
	_reseed()
	var shape: String = str(_rules.get("shape", ""))
	match shape:
		"crown", "tiara":
			_draw_crown()
		"cap":
			_draw_cap()
		"horns":
			_draw_horns()
		"ring":
			_draw_halo()
		"laurel":
			_draw_laurel()
		"cone":
			_draw_cone_hat()
		"jester":
			_draw_jester()
		"monocle":
			_draw_monocle()
		"glasses":
			_draw_glasses()
		"band":
			_draw_gem_band()
		"vine":
			_draw_vine()
		"dangle":
			_draw_dangle()
		"hands":
			_draw_hands()
		"feet":
			_draw_feet()
		"wings":
			_draw_wings()
		"tentacle":
			_draw_tentacles()
		"particles":
			_draw_particles()
		_:
			Log.must(false, "CosmeticRenderer", "unknown shape '%s'" % shape)


# ═════════════════════════════════════════════════════════════════════════
# HEADPIECES
# ═════════════════════════════════════════════════════════════════════════
## Crown / tiara: a band with N spikes rising from it, gems set along the band.
## Spike count scales with rank, so a veteran's crown is visibly more ornate.
func _draw_crown() -> void:
	var unit: float = _unit()
	var base_spikes: int = int(_rules.get("spikes", 5))
	var spikes: int = scaled_count(base_spikes, MAX_SPIKES)
	var width: float = unit * 0.62
	var height: float = unit * 0.30
	var band_y: float = 0.0
	var glow: float = float(_rules.get("glow", 1.0))
	var colour: Color = _accent
	colour.a = 0.95

	# Band
	var band: PackedVector2Array = PackedVector2Array([
		Vector2(-width * 0.5, band_y),
		Vector2(width * 0.5, band_y),
	])
	draw_polyline(band, colour, maxf(unit * 0.018, 2.0), true)

	# Spikes, tallest at centre and tapering toward the edges.
	for i: int in range(spikes):
		var t: float = float(i) / float(maxi(spikes - 1, 1))
		var x: float = lerpf(-width * 0.5, width * 0.5, t)
		var falloff: float = 1.0 - pow(absf(t - 0.5) * 2.0, 1.6)
		var tip_h: float = height * lerpf(0.45, 1.0, falloff)
		var half_w: float = width / float(spikes) * 0.42

		var spike: PackedVector2Array = PackedVector2Array([
			Vector2(x - half_w, band_y),
			Vector2(x, band_y - tip_h),
			Vector2(x + half_w, band_y),
		])
		draw_colored_polygon(spike, Color(colour, 0.30))
		draw_polyline(spike, colour, maxf(unit * 0.010, 1.5), true)

		# Tip highlight sells the metal.
		draw_circle(Vector2(x, band_y - tip_h), unit * 0.012, Color(colour, 0.9 * glow))

	_draw_gems(width, band_y, unit)
	_draw_orbit_motes(unit)


## Gems set along the crown band, evenly spaced and deterministic.
func _draw_gems(width: float, band_y: float, unit: float) -> void:
	var gem_count: int = int(_rules.get("gem_count", 0))
	if gem_count <= 0:
		return
	gem_count = scaled_count(gem_count, MAX_SPIKES)
	var prismatic: bool = bool(_rules.get("prismatic", false))
	for i: int in range(gem_count):
		var t: float = (float(i) + 0.5) / float(gem_count)
		var x: float = lerpf(-width * 0.46, width * 0.46, t)
		var radius: float = unit * 0.018
		var gem_col: Color = _accent
		if prismatic:
			gem_col = Color.from_hsv(fposmod(t + _time * 0.05, 1.0), 0.55, 1.0)
		# Facet: a small diamond rather than a circle.
		var facet: PackedVector2Array = PackedVector2Array([
			Vector2(x, band_y - radius), Vector2(x + radius * 0.7, band_y),
			Vector2(x, band_y + radius), Vector2(x - radius * 0.7, band_y),
		])
		draw_colored_polygon(facet, Color(gem_col, 0.85))
		draw_circle(Vector2(x - radius * 0.2, band_y - radius * 0.25),
			radius * 0.22, Palette.COLOR_CATCHLIGHT)


## Motes orbiting a prestige headpiece.
func _draw_orbit_motes(unit: float) -> void:
	var motes: int = int(_rules.get("orbit_motes", 0))
	if motes <= 0:
		return
	motes = scaled_count(motes, MAX_PARTICLES)
	for i: int in range(motes):
		var phase: float = TAU * float(i) / float(motes) + _time * 0.4
		var radius: float = unit * 0.34
		var pos: Vector2 = Vector2(cos(phase) * radius, sin(phase) * radius * 0.35 - unit * 0.14)
		draw_circle(pos, unit * 0.010, Color(_accent, 0.75))


## Simple starter cap: a dome of segments.
func _draw_cap() -> void:
	var unit: float = _unit()
	var segments: int = scaled_count(int(_rules.get("segments", 5)), MAX_SEGMENTS)
	var width: float = unit * 0.50
	var height: float = unit * 0.20
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(segments + 1):
		var t: float = float(i) / float(segments)
		var x: float = lerpf(-width * 0.5, width * 0.5, t)
		var y: float = -height * (1.0 - pow((t - 0.5) * 2.0, 2.0))
		points.append(Vector2(x, y))
	points.append(Vector2(width * 0.5, 0.0))
	points.append(Vector2(-width * 0.5, 0.0))
	draw_colored_polygon(points, Color(_accent, 0.35))
	draw_polyline(points, Color(_accent, 0.9), maxf(unit * 0.012, 2.0), true)


## Horns: two mirrored tapered curves.
func _draw_horns() -> void:
	var unit: float = _unit()
	var curve: float = float(_rules.get("curve", 0.6))
	var taper: float = float(_rules.get("taper", 0.4))
	var segments: int = scaled_count(8, MAX_SEGMENTS)
	for side: int in [-1, 1]:
		var outline: PackedVector2Array = PackedVector2Array()
		var back: PackedVector2Array = PackedVector2Array()
		for i: int in range(segments + 1):
			var t: float = float(i) / float(segments)
			# Quadratic sweep outward and up.
			var x: float = float(side) * unit * (0.10 + 0.26 * t)
			var y: float = -unit * (0.34 * t + curve * 0.10 * t * t)
			var thickness: float = unit * 0.045 * (1.0 - taper * t)
			outline.append(Vector2(x, y - thickness))
			back.insert(0, Vector2(x, y + thickness))
		for point: Vector2 in back:
			outline.append(point)
		draw_colored_polygon(outline, Color(_accent, 0.42))
		draw_polyline(outline, Color(_accent, 0.9), maxf(unit * 0.008, 1.5), true)


## Halo: a tilted ellipse ring floating above the brow.
func _draw_halo() -> void:
	var unit: float = _unit()
	var thickness: float = float(_rules.get("thickness", 0.08))
	var tilt: float = float(_rules.get("tilt", 0.22))
	var glow: float = float(_rules.get("glow", 1.4))
	var radius: float = unit * 0.28
	var centre: Vector2 = Vector2(0, -unit * 0.20)
	var steps: int = scaled_count(36, 72)

	var ring: PackedVector2Array = PackedVector2Array()
	for i: int in range(steps + 1):
		var angle: float = TAU * float(i) / float(steps)
		ring.append(centre + Vector2(cos(angle) * radius, sin(angle) * radius * tilt))
	# Glow pass then core pass — a cheap bloom without a shader.
	draw_polyline(ring, Color(_accent, 0.22 * glow), unit * thickness * 1.8, true)
	draw_polyline(ring, Color(_accent, 0.95), unit * thickness * 0.5, true)


## Laurel wreath: mirrored leaf pairs along two arcs.
func _draw_laurel() -> void:
	var unit: float = _unit()
	var leaves: int = scaled_count(int(_rules.get("leaves", 9)), MAX_LEAVES)
	var spread: float = float(_rules.get("spread", 0.7))
	for side: int in [-1, 1]:
		for i: int in range(leaves):
			var t: float = float(i) / float(maxi(leaves - 1, 1))
			var angle: float = lerpf(PI * 0.10, PI * 0.46 * spread, t)
			var radius: float = unit * 0.30
			var base: Vector2 = Vector2(
				float(side) * sin(angle) * radius, -cos(angle) * radius * 0.82)
			var leaf_len: float = unit * 0.075 * (1.0 - t * 0.35)
			var lean: float = float(side) * (0.5 + t * 0.5)
			var tip: Vector2 = base + Vector2(lean, -0.7).normalized() * leaf_len
			var w: Vector2 = Vector2(-lean, 0.35).normalized() * leaf_len * 0.32
			var leaf: PackedVector2Array = PackedVector2Array([
				base, base + w, tip, base - w,
			])
			draw_colored_polygon(leaf, Color(_accent, 0.55))
			draw_polyline(leaf, Color(_accent, 0.85), maxf(unit * 0.005, 1.0), true)


## Wizard cone with stars.
func _draw_cone_hat() -> void:
	var unit: float = _unit()
	var lean: float = float(_rules.get("lean", 0.18))
	var brim: float = float(_rules.get("brim", 0.9))
	var height: float = unit * 0.46
	var half_w: float = unit * 0.24 * brim
	var tip: Vector2 = Vector2(lean * unit * 0.4, -height)
	var cone: PackedVector2Array = PackedVector2Array([
		Vector2(-half_w, 0.0), tip, Vector2(half_w, 0.0),
	])
	draw_colored_polygon(cone, Color(_accent, 0.42))
	draw_polyline(cone, Color(_accent, 0.9), maxf(unit * 0.010, 1.5), true)
	# Brim
	draw_line(Vector2(-half_w * 1.25, 0.0), Vector2(half_w * 1.25, 0.0),
		Color(_accent, 0.9), maxf(unit * 0.016, 2.0), true)

	var stars: int = scaled_count(int(_rules.get("stars", 6)), MAX_PARTICLES)
	for i: int in range(stars):
		var t: float = _rng.randf_range(0.15, 0.9)
		var spread: float = half_w * (1.0 - t) * 0.8
		var pos: Vector2 = Vector2(
			_rng.randf_range(-spread, spread) + tip.x * t, -height * t)
		_draw_star(pos, unit * 0.020, Color(_accent, 0.9))


func _draw_star(centre: Vector2, radius: float, colour: Color) -> void:
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in range(10):
		var angle: float = TAU * float(i) / 10.0 - PI * 0.5
		var r: float = radius if i % 2 == 0 else radius * 0.42
		points.append(centre + Vector2(cos(angle) * r, sin(angle) * r))
	draw_colored_polygon(points, colour)


## Jester hat: lobed points, each ending in a bell.
func _draw_jester() -> void:
	var unit: float = _unit()
	var lobes: int = scaled_count(int(_rules.get("lobes", 3)), 7)
	var wobble: float = float(_rules.get("wobble", 0.5))
	var width: float = unit * 0.52
	for i: int in range(lobes):
		var t: float = (float(i) + 0.5) / float(lobes)
		var x: float = lerpf(-width * 0.5, width * 0.5, t)
		var sway: float = sin(_time * 1.4 + float(i)) * wobble * unit * 0.03
		var tip: Vector2 = Vector2(x + sway, -unit * (0.22 + 0.10 * sin(t * PI)))
		var half: float = width / float(lobes) * 0.45
		var lobe: PackedVector2Array = PackedVector2Array([
			Vector2(x - half, 0.0), tip, Vector2(x + half, 0.0),
		])
		var hue: float = fposmod(float(i) / float(lobes), 1.0)
		var lobe_col: Color = Color.from_hsv(hue, 0.45, 1.0)
		draw_colored_polygon(lobe, Color(lobe_col, 0.45))
		draw_polyline(lobe, Color(lobe_col, 0.9), maxf(unit * 0.008, 1.5), true)
		# Bell
		draw_circle(tip, unit * 0.018, Color(_accent, 0.95))


# ═════════════════════════════════════════════════════════════════════════
# FRAMES / RIMS
# ═════════════════════════════════════════════════════════════════════════
## Monocle: a rim circle with a hanging chain.
func _draw_monocle() -> void:
	var unit: float = _unit()
	var thickness: float = float(_rules.get("rim_thickness", 0.06))
	var radius: float = unit * 0.30
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48,
		Color(_accent, 0.95), unit * thickness, true)
	# Lens sheen: a short bright arc, not a full circle.
	draw_arc(Vector2.ZERO, radius * 0.82, PI * 1.05, PI * 1.45, 16,
		Palette.COLOR_CATCHLIGHT, unit * thickness * 0.4, true)

	var links: int = scaled_count(int(_rules.get("chain_links", 8)), MAX_SEGMENTS)
	var start: Vector2 = Vector2(radius * 0.7, radius * 0.7)
	for i: int in range(links):
		var t: float = float(i) / float(links)
		var pos: Vector2 = start + Vector2(t * unit * 0.10, t * unit * 0.26)
		draw_circle(pos, unit * 0.010, Color(_accent, 0.75))


## Spectacles: two rims joined by a bridge.
func _draw_glasses() -> void:
	var unit: float = _unit()
	var thickness: float = float(_rules.get("rim_thickness", 0.05))
	var bridge: float = float(_rules.get("bridge", 0.3))
	var radius: float = unit * 0.22
	var offset: float = radius * (1.0 + bridge)
	for side: int in [-1, 1]:
		var centre: Vector2 = Vector2(float(side) * offset, 0.0)
		draw_arc(centre, radius, 0.0, TAU, 40,
			Color(_accent, 0.95), unit * thickness, true)
		draw_arc(centre, radius * 0.80, PI * 1.05, PI * 1.40, 12,
			Palette.COLOR_CATCHLIGHT, unit * thickness * 0.35, true)
	draw_line(Vector2(-offset + radius, 0.0), Vector2(offset - radius, 0.0),
		Color(_accent, 0.9), unit * thickness * 0.8, true)


## Gem band: a shallow arc studded with facets.
func _draw_gem_band() -> void:
	var unit: float = _unit()
	var width: float = unit * 0.44
	draw_line(Vector2(-width * 0.5, 0.0), Vector2(width * 0.5, 0.0),
		Color(_accent, 0.85), maxf(unit * 0.014, 2.0), true)
	_draw_gems(width, 0.0, unit)


## Vines: curling tendrils with leaves, gently animated.
func _draw_vine() -> void:
	var unit: float = _unit()
	var tendrils: int = scaled_count(int(_rules.get("tendrils", 6)), MAX_TENDRILS)
	var curl: float = float(_rules.get("curl", 0.5))
	var density: float = float(_rules.get("leaf_density", 0.7))
	var steps: int = 10

	for i: int in range(tendrils):
		var origin_t: float = float(i) / float(maxi(tendrils - 1, 1))
		var base: Vector2 = Vector2(lerpf(-unit * 0.26, unit * 0.26, origin_t), 0.0)
		var dir: float = -1.0 if i % 2 == 0 else 1.0
		var path: PackedVector2Array = PackedVector2Array()
		for s: int in range(steps + 1):
			var t: float = float(s) / float(steps)
			var sway: float = sin(_time * 0.8 + float(i) + t * 3.0) * unit * 0.012
			var x: float = base.x + dir * sin(t * PI * curl * 2.0) * unit * 0.10 + sway
			var y: float = base.y - t * unit * 0.24
			path.append(Vector2(x, y))
		draw_polyline(path, Color(_accent, 0.8), maxf(unit * 0.007, 1.2), true)

		# Leaves along the tendril.
		var leaves: int = int(float(steps) * density * 0.5)
		for l: int in range(leaves):
			var idx: int = int(float(l + 1) / float(leaves + 1) * float(steps))
			var point: Vector2 = path[clampi(idx, 0, path.size() - 1)]
			var side: float = 1.0 if l % 2 == 0 else -1.0
			var leaf_dir: Vector2 = Vector2(side * 0.85, -0.5).normalized()
			var tip: Vector2 = point + leaf_dir * unit * 0.045
			var w: Vector2 = Vector2(-leaf_dir.y, leaf_dir.x) * unit * 0.014
			draw_colored_polygon(PackedVector2Array([point, point + w, tip, point - w]),
				Color(_accent, 0.6))


## Dangling earring: a chain of links that sways.
func _draw_dangle() -> void:
	var unit: float = _unit()
	var links: int = scaled_count(int(_rules.get("links", 4)), MAX_SEGMENTS)
	var sway_amt: float = float(_rules.get("sway", 0.35))
	var sway: float = sin(_time * 1.6) * sway_amt * unit * 0.04
	for i: int in range(links):
		var t: float = float(i + 1) / float(links)
		var pos: Vector2 = Vector2(sway * t, t * unit * 0.22)
		var radius: float = unit * 0.018 * (1.0 - t * 0.3)
		draw_arc(pos, radius, 0.0, TAU, 16, Color(_accent, 0.9),
			maxf(unit * 0.006, 1.0), true)
	# Terminal gem
	var end: Vector2 = Vector2(sway, unit * 0.24)
	draw_circle(end, unit * 0.022, Color(_accent, 0.9))
	draw_circle(end - Vector2(unit * 0.006, unit * 0.006), unit * 0.007,
		Palette.COLOR_CATCHLIGHT)


# ═════════════════════════════════════════════════════════════════════════
# LIMBS / UNDERLAYS
# ═════════════════════════════════════════════════════════════════════════
## Peeking hands: two small hands gripping the lower lid.
func _draw_hands() -> void:
	var unit: float = _unit()
	var fingers: int = clampi(int(_rules.get("fingers", 4)), 2, 6)
	var peek: float = float(_rules.get("peek_depth", 0.3))
	for side: int in [-1, 1]:
		var origin: Vector2 = Vector2(float(side) * unit * 0.22, 0.0)
		# Palm
		var palm: PackedVector2Array = PackedVector2Array([
			origin + Vector2(-unit * 0.06, 0.0),
			origin + Vector2(unit * 0.06, 0.0),
			origin + Vector2(unit * 0.05, unit * 0.07),
			origin + Vector2(-unit * 0.05, unit * 0.07),
		])
		draw_colored_polygon(palm, Color(_accent, 0.55))
		# Fingers curling up over the lid.
		for f: int in range(fingers):
			var t: float = (float(f) + 0.5) / float(fingers)
			var x: float = origin.x + lerpf(-unit * 0.05, unit * 0.05, t)
			var length: float = unit * 0.05 * (0.7 + 0.5 * sin(t * PI)) * (0.6 + peek)
			draw_line(Vector2(x, 0.0), Vector2(x, -length),
				Color(_accent, 0.85), maxf(unit * 0.012, 2.0), true)
			draw_circle(Vector2(x, -length), unit * 0.007, Color(_accent, 0.9))


## Little feet shuffling below.
func _draw_feet() -> void:
	var unit: float = _unit()
	var toes: int = clampi(int(_rules.get("toes", 3)), 2, 5)
	var shuffle: float = float(_rules.get("shuffle", 0.4))
	for side: int in [-1, 1]:
		var bob: float = sin(_time * 2.0 + (0.0 if side < 0 else PI)) * shuffle * unit * 0.012
		var origin: Vector2 = Vector2(float(side) * unit * 0.14, bob)
		var foot: PackedVector2Array = PackedVector2Array([
			origin + Vector2(-unit * 0.05, 0.0),
			origin + Vector2(unit * 0.06, 0.0),
			origin + Vector2(unit * 0.06, unit * 0.035),
			origin + Vector2(-unit * 0.05, unit * 0.035),
		])
		draw_colored_polygon(foot, Color(_accent, 0.6))
		for t: int in range(toes):
			var tx: float = origin.x + unit * 0.06 - float(t) * unit * 0.022
			draw_circle(Vector2(tx, origin.y), unit * 0.010, Color(_accent, 0.8))


## Wings: mirrored feather fans. Feather count scales with rank.
func _draw_wings() -> void:
	var unit: float = _unit()
	var feathers: int = scaled_count(int(_rules.get("feathers", 11)), MAX_FEATHERS)
	var flap: float = float(_rules.get("flap", 0.25))
	var beat: float = sin(_time * 1.2) * flap
	for side: int in [-1, 1]:
		for i: int in range(feathers):
			var t: float = float(i) / float(maxi(feathers - 1, 1))
			# Fan from near-horizontal to swept-back.
			var angle: float = lerpf(-0.15, 1.15, t) + beat * (0.3 + t * 0.7)
			var length: float = unit * lerpf(0.34, 0.14, pow(t, 1.4))
			var base: Vector2 = Vector2(float(side) * unit * 0.10, 0.0)
			var dir: Vector2 = Vector2(float(side) * cos(angle), sin(angle))
			var tip: Vector2 = base + dir * length
			var w: Vector2 = Vector2(-dir.y, dir.x) * unit * 0.022 * (1.0 - t * 0.4)
			var feather: PackedVector2Array = PackedVector2Array([
				base, base + w, tip, base - w,
			])
			draw_colored_polygon(feather, Color(_accent, 0.28 + 0.22 * (1.0 - t)))
			draw_polyline(feather, Color(_accent, 0.55), maxf(unit * 0.004, 1.0), true)


## Tentacles: segmented arms that writhe.
func _draw_tentacles() -> void:
	var unit: float = _unit()
	var arms: int = scaled_count(int(_rules.get("arms", 5)), MAX_TENDRILS)
	var segments: int = clampi(int(_rules.get("segments", 7)), 3, MAX_SEGMENTS)
	var writhe: float = float(_rules.get("writhe", 0.6))

	for a: int in range(arms):
		var spread_t: float = (float(a) + 0.5) / float(arms)
		var base_x: float = lerpf(-unit * 0.26, unit * 0.26, spread_t)
		var phase: float = float(a) * 1.7
		var path: PackedVector2Array = PackedVector2Array()
		for s: int in range(segments + 1):
			var t: float = float(s) / float(segments)
			var wave: float = sin(_time * 1.5 + phase + t * 4.0) * writhe * unit * 0.05 * t
			path.append(Vector2(base_x + wave, t * unit * 0.30))
		# Taper by drawing each span with a shrinking width.
		for s: int in range(path.size() - 1):
			var t: float = float(s) / float(path.size() - 1)
			draw_line(path[s], path[s + 1], Color(_accent, 0.75),
				maxf(unit * 0.030 * (1.0 - t * 0.75), 1.0), true)
		# Suckers on the inner edge.
		for s: int in range(1, path.size(), 2):
			var t: float = float(s) / float(path.size() - 1)
			draw_circle(path[s], unit * 0.008 * (1.0 - t * 0.6), Color(_accent, 0.5))


# ═════════════════════════════════════════════════════════════════════════
# AURAS
# ═════════════════════════════════════════════════════════════════════════
## Particle auras. Each kind has distinct motion, all deterministic per seed
## and driven by _time rather than stored state, so there is nothing to sync.
func _draw_particles() -> void:
	var unit: float = _unit()
	var kind: String = str(_rules.get("kind", "spark"))
	var count: int = scaled_count(int(_rules.get("count", 24)), MAX_PARTICLES)
	var field: float = unit * 0.62

	for i: int in range(count):
		# Per-particle constants drawn once from the seeded RNG.
		var ox: float = _rng.randf_range(-field, field)
		var oy: float = _rng.randf_range(-field, field)
		var speed: float = _rng.randf_range(0.4, 1.3)
		var phase: float = _rng.randf_range(0.0, TAU)
		var spread: float = _rng.randf_range(0.6, 1.4)

		match kind:
			"snow":
				_draw_snow_particle(ox, oy, speed, phase, spread, field, unit)
			"spark":
				_draw_spark_particle(ox, oy, speed, phase, spread, field, unit)
			"glyph":
				_draw_glyph_particle(ox, oy, speed, phase, spread, field, unit, i)
			"dust":
				_draw_dust_particle(ox, oy, speed, phase, spread, field, unit)
			_:
				draw_circle(Vector2(ox, oy), unit * 0.008 * spread, Color(_accent, 0.6))


## Snow: drifts downward, wrapping, with lateral sway.
func _draw_snow_particle(ox: float, oy: float, speed: float, phase: float,
		spread: float, field: float, unit: float) -> void:
	var drift: float = float(_rules.get("drift", 0.3))
	var fall: float = fposmod(oy + _time * speed * unit * 0.10, field * 2.0) - field
	var sway: float = sin(_time * speed + phase) * drift * unit * 0.05
	var pos: Vector2 = Vector2(ox + sway, fall)
	var radius: float = unit * 0.009 * spread
	draw_circle(pos, radius, Color(Palette.COLOR_TEXT, 0.75))
	# Six-point crystal at larger sizes.
	if spread > 1.0:
		for arm: int in range(3):
			var angle: float = PI * float(arm) / 3.0
			var offset: Vector2 = Vector2(cos(angle), sin(angle)) * radius * 2.0
			draw_line(pos - offset, pos + offset, Color(Palette.COLOR_TEXT, 0.45),
				maxf(unit * 0.003, 1.0), true)


## Sparks: rise and fade, brightest at birth.
func _draw_spark_particle(ox: float, oy: float, speed: float, phase: float,
		spread: float, field: float, unit: float) -> void:
	var rise: float = float(_rules.get("rise", 0.4))
	var life: float = fposmod(_time * speed * 0.5 + phase, 1.0)
	var pos: Vector2 = Vector2(
		ox + sin(_time * 2.0 + phase) * unit * 0.02,
		oy - life * rise * field * 1.4)
	var alpha: float = (1.0 - life) * 0.9
	var radius: float = unit * 0.007 * spread * (1.0 - life * 0.5)
	draw_circle(pos, radius, Color(_accent, alpha))
	# Trailing streak.
	draw_line(pos, pos + Vector2(0, radius * 3.0), Color(_accent, alpha * 0.4),
		maxf(unit * 0.003, 1.0), true)


## Matrix rain: vertical glyph columns falling at column-specific speeds.
## Glyphs are drawn as small rune-like line clusters — no font, no texture.
func _draw_glyph_particle(ox: float, oy: float, speed: float, phase: float,
		spread: float, field: float, unit: float, index: int) -> void:
	var fall_rate: float = float(_rules.get("fall", 0.8))
	# Snap x to a column grid so it reads as rain, not noise.
	var column: float = round(ox / (unit * 0.055)) * unit * 0.055
	# `phase` de-synchronises the columns. Snapping x to a grid collapses
	# several particles onto the same column, and without a per-particle
	# offset they fall in lockstep and read as one thick blinking bar rather
	# than rain. Every other particle type already folds phase into its
	# motion; this one silently dropped it, which is why the parameter was
	# flagged as unused.
	var y: float = fposmod(oy + phase * field * 0.5
		+ _time * speed * fall_rate * unit * 0.22, field * 2.0) - field
	# Head of the column is brightest.
	var head_fade: float = clampf(1.0 - (y + field) / (field * 2.0), 0.15, 1.0)
	var glyph_col: Color = Palette.success()
	glyph_col.a = head_fade * 0.85

	var glyph_size: float = unit * 0.016 * spread
	var pos: Vector2 = Vector2(column, y)
	# Deterministic 3-stroke rune from the particle index.
	var variant: int = index % 4
	match variant:
		0:
			draw_line(pos + Vector2(-glyph_size, 0), pos + Vector2(glyph_size, 0),
				glyph_col, maxf(unit * 0.004, 1.0), true)
			draw_line(pos + Vector2(0, -glyph_size), pos + Vector2(0, glyph_size),
				glyph_col, maxf(unit * 0.004, 1.0), true)
		1:
			draw_line(pos + Vector2(-glyph_size, -glyph_size),
				pos + Vector2(glyph_size, glyph_size), glyph_col,
				maxf(unit * 0.004, 1.0), true)
			draw_line(pos + Vector2(glyph_size, -glyph_size),
				pos + Vector2(-glyph_size, glyph_size), glyph_col,
				maxf(unit * 0.004, 1.0), true)
		2:
			draw_arc(pos, glyph_size, 0.0, PI, 8, glyph_col, maxf(unit * 0.004, 1.0), true)
			draw_line(pos + Vector2(0, 0), pos + Vector2(0, glyph_size),
				glyph_col, maxf(unit * 0.004, 1.0), true)
		_:
			draw_rect(Rect2(pos - Vector2(glyph_size, glyph_size) * 0.6,
				Vector2(glyph_size, glyph_size) * 1.2), glyph_col, false,
				maxf(unit * 0.004, 1.0))


## Cosmic dust: slow orbital swirl, optionally prismatic.
func _draw_dust_particle(ox: float, oy: float, speed: float, phase: float,
		spread: float, field: float, unit: float) -> void:
	var swirl: float = float(_rules.get("swirl", 0.5))
	var prismatic: bool = bool(_rules.get("prismatic", false))
	var radius_from_centre: float = Vector2(ox, oy).length()
	var angle: float = atan2(oy, ox) + _time * speed * swirl * 0.25
	var pos: Vector2 = Vector2(cos(angle), sin(angle)) * radius_from_centre
	var alpha: float = 0.35 + 0.35 * sin(_time * speed + phase)
	var colour: Color = _accent
	if prismatic:
		colour = Color.from_hsv(
			fposmod(radius_from_centre / maxf(field, 1.0) + _time * 0.04, 1.0), 0.5, 1.0)
	draw_circle(pos, unit * 0.006 * spread, Color(colour, alpha))
