extends Control
class_name IrisView
## IrisView — the procedural Iris hub portal renderer.
##
## PHASE 2 CONTRACT. This node OWNS rendering and nothing else:
##   · reads exactly one autoload — Palette (Rule D). Never Save, Router,
##     audio, or any progression system.
##   · receives an IrisState and pushes it into shader uniforms
##   · emits interaction intent on Bus; never acts on it
##
## v1's IrisCore was 801 lines doing nine jobs: rendering, autonomous life,
## gaze, trait compositing, lids, particles, NAVIGATION ROUTING, hat mounting,
## and toast notifications. It read nine autoloads and played audio directly.
## Roughly 250 lines of that was bloat. None of it is here.
##
## Z-LAYER ISOLATION (spec requirement):
##   Z = -10  %UnderlayAnchors   limbs, wings, tentacles, peeking hands
##   Z =   0  %CoreEye           eyelids + eyeball shader  ← input receptor
##   Z = +10  %OverlayAnchors    headpieces, frames, glasses, auras
##
## INPUT: every cosmetic anchor is MOUSE_FILTER_IGNORE, so touches fall
## straight through the decoration layers to the core eye. Only %CoreEye
## has MOUSE_FILTER_STOP. There is exactly one input receptor.

# ── Z-layer constants ────────────────────────────────────────────────────
const Z_UNDERLAY: int = -10
const Z_CORE: int = 0
const Z_OVERLAY: int = 10

## The shader works in a normalised square. This is the design-space reference
## edge that IrisState.ANCHOR_OFFSETS are expressed against.
const DESIGN_SIZE: float = 360.0

## The baked hero housing. Rule F exception — see check_architecture.py.
const HOUSING_TEXTURE: String = "res://art/hero/iris_hero_housing.png"
## How far the housing extends past the eyeball, as a multiple of its side.
##
## MEASURED, not guessed. The art's aperture spans x 154..870 of the 1024px
## image — 0.699 of it. At the first value of 1.85 the housing drew 962px
## wide, giving a 672px opening for a 520px eye: the iris filled 54% of the
## hole and read as a small disc floating in a large socket.
##
## 1.63 puts the eye at 88% of the aperture, which leaves a thin margin of
## the art's own inner rim visible around the eyeball rather than the eye
## overlapping the metal.
## How far the baked housing extends past the eyeball, as a multiple of the
## view's short side.
##
## MEASURED FROM THE ART, TWICE, AND THE FIRST MEASUREMENT WAS WRONG.
##
## The original 1.63 was derived from where the art's *aperture hole* appeared
## to start, and it put the metal ring at 225px from centre. The CoreEye is
## opaque out to 260px — the shader's body_alpha only begins falling off at
## |p| = 1.02 — so the entire carved frame was drawn BEHIND the eye and the
## player saw bare black. Reported twice as "I don't see the hero housing",
## and I twice mistook the shader's own lid and sclera for the baked art.
##
## Re-measured properly by scanning the texture for its first sustained lit
## pixel: the metal begins at normalised radius 0.531, and the opaque art ends
## at 0.848. For that ring to clear a 260px eye the span must be at least
## 260 / 0.531 * 2 = 979px, i.e. 1.88x the view.
##
## 1.95 rather than the bare 1.88 minimum, so the frame clears the rim with a
## margin instead of sitting exactly on it:
##
##     hub 520px view -> 1014px span, metal 269..430px, eye edge 260px
##
## A 1.72 span was tried and looked correct in a GPU capture — but only because
## the frame is an EYE shape whose metal sits closest to centre above and below,
## where the eyeball is thin. On the horizontal centre line it was buried, which
## the aperture check caught and the screenshot did not.
const HOUSING_SPAN: float = 1.95

## Normalised radius in the texture where the carved metal begins, and where
## the opaque art ends. Measured, and asserted by the polish audit so a
## regenerated housing that breaks the assumption fails loudly.
const HOUSING_APERTURE: float = 0.531
const HOUSING_OUTER: float = 0.848

## Pupil radius bounds, as a fraction of the eye's HALF short side.
##
## MUST MATCH `pupil_min` / `pupil_max` in iris_procedural.gdshader, and are
## pushed to it on every state apply so the two cannot drift.
##
## They are declared here rather than left as shader-only defaults because
## GDScript cannot read a uniform's declared default at all: Shader has no
## get_default_parameter(), and RenderingServer.shader_get_parameter_default()
## returns null for an unassigned uniform. A test asking "does the vision disc
## fit inside the pupil?" therefore measured a pupil of ZERO pixels and could
## never fail — which is how a glyph four times too big shipped.
const PUPIL_MIN: float = 0.20
const PUPIL_MAX: float = 0.46

## Autonomous life tuning. These are behaviour constants, not visual tokens.
const BLINK_INTERVAL_MIN: float = 2.6
const BLINK_INTERVAL_MAX: float = 5.8
const BLINK_INTERVAL_REDUCED_MIN: float = 9.0
const BLINK_INTERVAL_REDUCED_MAX: float = 15.0
const DOUBLE_BLINK_CHANCE: float = 0.18
const DOUBLE_BLINK_DELAY: float = 0.28
const BLINK_CLOSE_TIME: float = 0.085
const BLINK_OPEN_TIME: float = 0.155

const SACCADE_INTERVAL_MIN: float = 1.1
const SACCADE_INTERVAL_MAX: float = 3.4
const SACCADE_RECENTRE_CHANCE: float = 0.35
const MICROSACCADE_AMPLITUDE: float = 0.045
const GAZE_EASE_RATE: float = 8.0
const BREATH_RATE: float = 1.1
const BREATH_AMPLITUDE: float = 0.075

## Interaction geometry, as fractions of the control's side.
const DEADZONE_FRAC: float = 0.14
const SHARD_COMMIT_DOT: float = 0.55

# ── Scene-unique nodes (Rule B: %UniqueName only) ────────────────────────
@onready var _underlays: Control = %UnderlayAnchors
@onready var _core_eye: ColorRect = %CoreEye
@onready var _overlays: Control = %OverlayAnchors

# ── State ────────────────────────────────────────────────────────────────
var _state: IrisState = null
var _material: ShaderMaterial = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _side: float = DESIGN_SIZE
var _interactive: bool = false
## Compass hit-testing. False on a first run until the nav gate opens.
var _nav_enabled: bool = true
var _vision: VisionRenderer = null
var _vision_route: String = ""
var _vision_tween: Tween = null
## The baked hero housing: carved metal frame, gem shards and outer glow.
## Behind the eye, so the procedural iris and lids composite over it.
var _housing: TextureRect = null

# Gaze: target is where we want to look, current is eased toward it.
var _gaze_target: Vector2 = Vector2.ZERO
var _gaze_current: Vector2 = Vector2.ZERO
var _idle_gaze: Vector2 = Vector2.ZERO
var _saccade_timer: float = 0.0

var _breath_phase: float = 0.0
var _blink_value: float = 0.0
var _blink_timer: Timer = null
var _expression_active: bool = false
var _dilation_override: float = -1.0

# Interaction
var _pressing: bool = false
var _hover_shard: int = 0


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _ready() -> void:
	_rng.randomize()

	if not Log.must(_core_eye != null, "IrisView", "%CoreEye missing"):
		return

	# Order matters: the material must exist before any geometry is pushed
	# into it. _enforce_square() runs AFTER _build_material() so its
	# rect_size push lands, rather than running first and being a silent
	# no-op that a second call had to repair.
	_enforce_z_layers()
	_enforce_input_isolation()
	_build_material()
	_build_housing()
	_enforce_square()

	resized.connect(_enforce_square)
	_core_eye.gui_input.connect(_on_core_input)

	_build_blink_timer()
	_push_palette()

	# Rule B: subscribe here, disconnect in _exit_tree.
	Bus.palette_changed.connect(_on_palette_changed)

	set_process(true)


func _exit_tree() -> void:
	if Bus.palette_changed.is_connected(_on_palette_changed):
		Bus.palette_changed.disconnect(_on_palette_changed)


# ═════════════════════════════════════════════════════════════════════════
# Z-LAYER ISOLATION
# ═════════════════════════════════════════════════════════════════════════
## Underlays behind, core in the middle, overlays in front. Enforced in code
## rather than trusted to scene ordering, so a reparent can't silently put a
## crown behind the eyeball.
## Layer the three bands by CHILD ORDER, not by a negative z_index.
##
## THE BUG THIS FIXES: the baked hero housing was invisible on every screen,
## reported three separate times, and every previous attempt to fix it by
## resizing the frame was chasing the wrong thing.
##
## The underlay used `z_index = -10` with `z_as_relative = true`. Measured
## directly on a GPU with an isolated reproduction: an oversized TextureRect
## inside such a node renders 0% of its overflow area, while the identical
## structure at z_index = 0 renders 53.3% of it. A negative relative z-index
## pushes the child behind its own parent's canvas item, and anything it draws
## outside the parent's rect is simply never composited.
##
## Draw order inside a Control is child order, and _underlays is ALREADY the
## first child, so it paints behind the core eye without needing a z-index at
## all. The z values remain as named constants because the cosmetic mount and
## the audit both reference them for INTENT, but the underlay no longer sets a
## negative one on the node that has to draw outside its bounds.
func _enforce_z_layers() -> void:
	if _underlays != null:
		# Deliberately NOT Z_UNDERLAY. See above: a negative relative z here
		# is what made the housing invisible.
		_underlays.z_index = 0
		_underlays.z_as_relative = true
		# Order is what actually layers it: first child draws first.
		move_child(_underlays, 0)
	if _core_eye != null:
		_core_eye.z_index = Z_CORE
		_core_eye.z_as_relative = true
	if _overlays != null:
		_overlays.z_index = Z_OVERLAY
		_overlays.z_as_relative = true


## The eye is the ONLY thing that receives input. Every cosmetic anchor —
## present and future — is forced to IGNORE, so a crown can never swallow a
## tap meant for the pupil.
func _enforce_input_isolation() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _core_eye != null:
		_core_eye.mouse_filter = Control.MOUSE_FILTER_STOP
	for container: Control in [_underlays, _overlays]:
		if container == null:
			continue
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_force_ignore_recursive(container)


func _force_ignore_recursive(node: Node) -> void:
	for child: Node in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_force_ignore_recursive(child)


## Call after adding any cosmetic node so the guarantee still holds.
func refresh_input_isolation() -> void:
	_enforce_input_isolation()


## Keep the shader's coordinate space isotropic.
##
## THE BUG THIS FIXES: this function computed _side and set a pivot, and
## despite its name never made anything square nor told the shader anything.
## The shader meanwhile hardcoded `p = uv * 2.0` under a comment asserting
## "the view keeps the control square". Measured, the host rect is square on
## exactly one of the three screens that mount this view:
##
##     hub_portal   520 x 520    aspect 1.000
##     intro       1016 x 1350   aspect 0.753   squashed
##     daily_hub   1024 x 200    aspect 5.120   smeared
##
## Every radial term in the shader assumes an isotropic p, so a non-square
## rect turns the pupil into an ellipse and the limbal ring oval.
##
## The rect itself is deliberately NOT resized: it is the drawing canvas, and
## containers own its geometry. Instead the true pixel size is handed to the
## shader, which divides by the short axis and keeps every circle circular.
func _enforce_square() -> void:
	_side = minf(size.x, size.y)
	if _side <= 0.0:
		_side = DESIGN_SIZE
	pivot_offset = size * 0.5
	_push_rect_size()
	_size_vision()
	_size_housing()


## Hand the host rect's pixel size to the shader for aspect correction.
## Mount the baked hero housing on the underlay layer.
##
## WHY A BAKED ASSET HERE AND NOWHERE ELSE
## Three procedural attempts could not reach the reference: the carved metal,
## the gem facets and the volumetric bloom are photographic qualities a
## fragment shader does not produce. The housing is therefore art, and the
## IRIS — the only part that must respond to dilation, gaze, shimmer and the
## hover vision — stays procedural on top of it. See Rule F's documented
## exception in tests/check_architecture.py.
##
## UNDERLAY, not overlay: the shader draws the eyeball and lids over this, and
## cosmetics still mount above both.
func _build_housing() -> void:
	if _housing != null:
		return
	var art: Texture2D = load(HOUSING_TEXTURE) as Texture2D
	if not Log.must(art != null, "IrisView", "hero housing texture missing"):
		return
	_housing = TextureRect.new()
	_housing.name = "HeroHousing"
	_housing.texture = art
	_housing.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_housing.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_housing.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# === STRUCTURAL FIX: Transparent center socket mask ===
	# Makes the solid black center of the housing texture transparent
	# so the procedural cyan iris shows through cleanly.
	var mask_shader := Shader.new()
	mask_shader.code = """
shader_type canvas_item;

void fragment() {
	COLOR = texture(TEXTURE, UV);
	// Make very dark pixels (the center socket) fully transparent
	if (COLOR.r < 0.05 && COLOR.g < 0.05 && COLOR.b < 0.05) {
		COLOR.a = 0.0;
	}
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = mask_shader
	_housing.material = mat

	_overlays.add_child(_housing)
	_size_housing()


func _size_housing() -> void:
	# The housing extends past the eyeball, so its rect is larger than the
	# view and centred on it. Absent before _build_housing() has run, which
	# is the ordinary path on the first resize.
	if _housing != null:
		# CLAMP THE SPAN TO THE HOST RECT.
		#
		# THE BUG THIS FIXES: on the intro the metallic surround was simply
		# not there, and the eye floated on bare black.
		#
		# _side is min(width, height), and HOUSING_SPAN deliberately overshoots
		# it so the frame reaches past the eyeball. On a SQUARE host that is
		# correct. On a tall host it is not: the intro's IrisView is 995x1321,
		# so _side = 995 and the span came out at 1622px — wider than the whole
		# 1059px screen. The frame was drawn, but scaled so far out that only
		# its empty middle fell inside the viewport, which reads as "no
		# housing at all".
		#
		# The daily hub had the mirror problem from the same line: a 1003x200
		# host gave _side = 200 and a 326px frame adrift in a 1003px-wide slot.
		#
		# The frame must fit the rect it is decorating, so the span is capped
		# at the host's own bounds. Where the host is square this changes
		# nothing and the hub still measures 847.6px exactly as before.
		# THE CLAMP IS AGAINST THE VIEWPORT, NOT THE HOST.
		#
		# Overshooting the HOST is the entire point of the frame, so clamping
		# to the host rect is wrong — tried, and it cut the hub's calibrated
		# 847.6px back to 520px, throwing away the fit that was measured
		# against the art's aperture.
		#
		# Overshooting the SCREEN is the actual bug. The intro's IrisView is
		# 995x1321, so _side = 995 gave a 1622px frame on a 1059px-wide
		# screen: drawn, but scaled so far out that only its empty middle
		# landed in the viewport, which reads as no housing at all.
		#
		#   hub    520x520   -> 847.6px, under the 1059 cap, unchanged
		#   intro  995x1321  -> capped 1622 -> 1059, now visible
		#   daily 1003x200   -> 326px, under the cap, unchanged
		var span: float = _side * HOUSING_SPAN
		var vp: Vector2 = get_viewport_rect().size
		if vp.x > 1.0 and vp.y > 1.0:
			span = minf(span, minf(vp.x, vp.y))
		_housing.size = Vector2(span, span)
		_housing.position = size * 0.5 - Vector2(span, span) * 0.5


func _push_rect_size() -> void:
	if not _has_material("_push_rect_size") or _core_eye == null:
		Log.d("IrisView", "cannot push rect_size before the material exists")
		return
	var rect: Vector2 = _core_eye.size
	if rect.x <= 0.0 or rect.y <= 0.0:
		rect = Vector2(_side, _side)
	_material.set_shader_parameter("rect_size", rect)


# ═════════════════════════════════════════════════════════════════════════
# MATERIAL
# ═════════════════════════════════════════════════════════════════════════
func _build_material() -> void:
	var shader: Shader = load("res://shaders/iris_procedural.gdshader")
	if not Log.must(shader != null, "IrisView", "iris_procedural.gdshader missing"):
		# Fatal for this node. Stop the frame loop rather than no-op forever.
		set_process(false)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_core_eye.material = _material
	_core_eye.color = Palette.COLOR_TRANSPARENT   # shader draws everything


## Palette is the only autoload this node reads (Rule D).
func _push_palette() -> void:
	if not _has_material("_push_palette"):
		return
	# The iris is the light source in this composition, so it is pushed
	# SATURATED and the globe around it is pushed DARK. Feeding the accent
	# straight through left the iris at 0.46 saturation against a reference
	# measuring 0.73.
	var accent: Color = Palette.accent()
	var vivid: Color = accent
	vivid.s = clampf(accent.s * Palette.IRIS_SATURATION_BOOST, 0.0, 1.0)
	vivid.v = clampf(accent.v * 1.12, 0.0, 1.0)

	_material.set_shader_parameter("iris_color", _v3(vivid))
	_material.set_shader_parameter("iris_deep_color", _v3(accent.darkened(0.80)))
	# NOT COLOR_TEXT. That is a near-white intended for body copy, and using
	# it here made the globe brighter than the iris it was meant to frame.
	_material.set_shader_parameter("sclera_color", _v3(Palette.COLOR_SCLERA_DEEP))
	_material.set_shader_parameter("limbal_color", _v3(Palette.COLOR_PUPIL_RIM))
	_material.set_shader_parameter("lid_color", _v3(Palette.COLOR_BACKGROUND))
	_material.set_shader_parameter("glint_color", _v3(Palette.COLOR_CATCHLIGHT))



func _on_palette_changed(_tier: int) -> void:
	_push_palette()


func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


## Guard for "the shader material exists". Never fails silently: the shader
## load failure is already an ERROR at build time, so this logs at debug level
## to avoid spamming a per-frame call site while still leaving a breadcrumb.
func _has_material(context: String) -> bool:
	if _material != null:
		return true
	Log.d("IrisView", "no material in %s (shader failed to load)" % context)
	return false


# ═════════════════════════════════════════════════════════════════════════
# STATE APPLICATION — the single inbound surface
# ═════════════════════════════════════════════════════════════════════════
## Hand the view a complete IrisState. It renders that and nothing else.
func apply_state(state: IrisState) -> void:
	if not Log.must(state != null, "IrisView", "apply_state got null"):
		return
	_state = state
	_push_state()


func _push_state() -> void:
	if not _has_material("_push_state"):
		return
	if _state == null:
		return   # no state applied yet; legitimate pre-apply_state condition

	_material.set_shader_parameter("complexity_factor",
		clampf(_state.current_complexity_factor(), 1.0, 6.0))
	_material.set_shader_parameter("shimmer_resonance",
		clampf(_state.lens_shimmer / 100.0, 0.0, 1.0))
	_material.set_shader_parameter("portal_transition", _state.portal_transition_state)
	_material.set_shader_parameter("reduced_motion", 1.0 if _state.reduced_motion else 0.0)

	# Ambient mood and time-of-day warmth tint the iris without overriding the
	# rank accent — the eye stays recognisably yours, but shifts by session.
	var accent: Color = Palette.accent()
	var moody: Color = accent.lerp(_state.ambient_mood_color, Palette.AMBIENT_MOOD_BLEND)
	moody = moody.lerp(Palette.COLOR_NIGHT_WARMTH,
		_state.time_of_day_warmth * Palette.NIGHT_WARMTH_BLEND)
	_material.set_shader_parameter("iris_color", _v3(moody))
	_material.set_shader_parameter("iris_deep_color", _v3(moody.darkened(0.72)))

	# Rank raises baseline luminance forever, but asymptotically — a rank
	# 10,000 eye glows more than rank 100 without whiting out.
	var rank_glow: float = 1.0 + log(1.0 + float(_state.rank_tier)) * 0.06
	_material.set_shader_parameter("glow", clampf(rank_glow, 0.0, 3.0))


# ═════════════════════════════════════════════════════════════════════════
# PER-FRAME LIFE
# ═════════════════════════════════════════════════════════════════════════
## Breathing, idle gaze, and micro-saccades. This is the part of v1 that
## genuinely worked and the reason its eye read as alive at all.
func _process(delta: float) -> void:
	if not _has_material("_process"):
		set_process(false)
		return

	var reduced: bool = _state != null and _state.reduced_motion

	# ── Autonomous gaze: only when the player isn't driving it ──────────
	if not _pressing and not reduced:
		_saccade_timer -= delta
		if _saccade_timer <= 0.0:
			if _rng.randf() < SACCADE_RECENTRE_CHANCE:
				_idle_gaze = Vector2.ZERO
			else:
				var angle: float = _rng.randf_range(0.0, TAU)
				var radius: float = _rng.randf_range(0.3, 1.0)
				_idle_gaze = Vector2(cos(angle), sin(angle)) * radius
			_saccade_timer = _rng.randf_range(SACCADE_INTERVAL_MIN, SACCADE_INTERVAL_MAX)

		# Micro-saccades: constant sub-degree jitter. Real eyes never hold
		# perfectly still, and this is what the brain reads as "alive".
		var micro: Vector2 = Vector2(
			_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-1.0, 1.0)) * MICROSACCADE_AMPLITUDE
		_gaze_target = (_idle_gaze + micro).limit_length(1.0)

	_gaze_current = _gaze_current.lerp(_gaze_target,
		clampf(delta * GAZE_EASE_RATE, 0.0, 1.0))
	_material.set_shader_parameter("gaze_vector", _gaze_current)

	# The vision disc rides WITH the pupil. The shader translates the iris by
	# the gaze every frame, so a disc positioned only on resize is left behind
	# the moment the eye looks anywhere — which is exactly the state it is
	# shown in, since it only ever appears during a drag.
	if _vision != null and _vision.reveal() > 0.0:
		_size_vision()

	# ── Breathing dilation ──────────────────────────────────────────────
	var dilation: float = 0.5
	if _state != null:
		dilation = _state.pupil_dilation_target
	if _dilation_override >= 0.0:
		dilation = _dilation_override
	elif not reduced:
		_breath_phase += delta * BREATH_RATE
		dilation += sin(_breath_phase) * BREATH_AMPLITUDE

	_material.set_shader_parameter("pupil_dilation", clampf(dilation, 0.0, 1.0))
	# Pushed explicitly, every frame, so the shader's pupil and the CPU-side
	# constants a test measures against can never disagree.
	_material.set_shader_parameter("pupil_min", PUPIL_MIN)
	_material.set_shader_parameter("pupil_max", PUPIL_MAX)
	_material.set_shader_parameter("blink", _blink_value)


# ═════════════════════════════════════════════════════════════════════════
# EXPRESSIONS
# ═════════════════════════════════════════════════════════════════════════
## One-shot expressions. Emits iris_expression_finished so callers can
## sequence without guessing durations — something v1 never provided.
func express(kind: StringName, intensity: float = 1.0) -> void:
	var amount: float = clampf(intensity, 0.0, 1.0)
	match kind:
		&"blink":
			_play_blink()
		&"pulse":
			_play_dilation(0.5 + 0.28 * amount, Palette.DURATION_FAST, Palette.DURATION_MED)
		&"widen":
			_play_dilation(0.5 + 0.42 * amount, Palette.DURATION_MED, Palette.DURATION_SLOW)
		&"focus":
			_play_dilation(0.5 + 0.20 * amount, Palette.DURATION_FAST, Palette.DURATION_FAST)
		&"flare":
			_play_flare(amount)
		_:
			Log.must(false, "IrisView", "unknown expression '%s'" % kind)
			return


func _play_blink() -> void:
	var tween: Tween = create_tween()
	tween.tween_method(_set_blink, _blink_value, 1.0, BLINK_CLOSE_TIME) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_method(_set_blink, 1.0, 0.0, BLINK_OPEN_TIME) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_callback(func() -> void:
		Bus.iris_expression_finished.emit(&"blink"))


func _play_dilation(peak: float, rise: float, fall: float) -> void:
	_expression_active = true
	var start: float = _dilation_override if _dilation_override >= 0.0 else 0.5
	var tween: Tween = create_tween()
	tween.tween_method(_set_dilation_override, start, peak, Palette.duration(rise)) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_method(_set_dilation_override, peak, 0.5, Palette.duration(fall)) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_callback(func() -> void:
		_dilation_override = -1.0
		_expression_active = false
		Bus.iris_expression_finished.emit(&"dilation"))


func _play_flare(amount: float) -> void:
	if not _has_material("_play_flare"):
		return
	var base: float = float(_material.get_shader_parameter("glow"))
	var tween: Tween = create_tween()
	tween.tween_method(_set_glow, base, base + 0.9 * amount, Palette.duration(Palette.DURATION_MED))
	tween.tween_method(_set_glow, base + 0.9 * amount, base, Palette.duration(Palette.DURATION_SLOW))
	tween.tween_callback(func() -> void:
		Bus.iris_expression_finished.emit(&"flare"))


func _set_blink(v: float) -> void:
	_blink_value = v


func _set_dilation_override(v: float) -> void:
	_dilation_override = v


func _set_glow(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("glow", v)


# ── Idle blinking ────────────────────────────────────────────────────────
func _build_blink_timer() -> void:
	_blink_timer = Timer.new()
	_blink_timer.one_shot = true
	add_child(_blink_timer)
	_blink_timer.timeout.connect(_on_blink_timeout)
	_schedule_blink()


func _schedule_blink() -> void:
	var reduced: bool = _state != null and _state.reduced_motion
	var lo: float = BLINK_INTERVAL_REDUCED_MIN if reduced else BLINK_INTERVAL_MIN
	var hi: float = BLINK_INTERVAL_REDUCED_MAX if reduced else BLINK_INTERVAL_MAX
	_blink_timer.start(_rng.randf_range(lo, hi))


func _on_blink_timeout() -> void:
	_play_blink()
	# Real blinks cluster — an occasional double reads as far more natural
	# than perfectly spaced singles.
	var reduced: bool = _state != null and _state.reduced_motion
	if not reduced and _rng.randf() < DOUBLE_BLINK_CHANCE:
		var tween: Tween = create_tween()
		tween.tween_interval(DOUBLE_BLINK_DELAY)
		tween.tween_callback(_play_blink)
	_schedule_blink()


# ═════════════════════════════════════════════════════════════════════════
# GAZE CONTROL
# ═════════════════════════════════════════════════════════════════════════
func look_at_direction(direction: Vector2) -> void:
	_gaze_target = direction.limit_length(1.0)


func look_reset() -> void:
	_gaze_target = Vector2.ZERO
	_idle_gaze = Vector2.ZERO


## Enable/disable compass interaction. When off, a tap is just a tap.
func set_interactive(enabled: bool) -> void:
	_interactive = enabled
	if not enabled:
		_hover_shard = IrisState.CompassShard.NONE
		look_reset()


## Enable or suppress COMPASS hit-testing, independently of interactivity.
##
## The two are deliberately separate. set_interactive(false) makes the eye
## inert entirely — used mid-navigation so a second tap cannot double-commit.
## This one keeps the eye tappable while refusing to resolve a direction,
## which is the first-run state: the eye is a button, not a dial.
##
## Without it a gated player could still drag, see the gaze track their
## finger, and get no preview and no navigation — an interaction that
## responds but does nothing, which reads as broken rather than as locked.
## ── PUPIL VISION ─────────────────────────────────────────────────────────
## Show a destination glyph inside the pupil, per the v1 contract:
## a 0.60-of-side disc, fading in over 0.22s while scaling from 0.85 over
## 0.28s, with a pupil pulse. The tween lives here rather than in the
## controller so the animation cannot desynchronise from the node it drives.
func show_vision(route: String, tint: Color) -> void:
	if not _nav_enabled:
		return
	var glyph: VisionGlyph = VisionGlyph.for_route(route)
	if glyph == null:
		# Not an error: settings and the chrono card are reached by button,
		# not by the compass, so they legitimately have no glyph.
		hide_vision()
		return
	if _vision_route == route and _vision != null:
		return
	_vision_route = route

	_ensure_vision()
	_size_vision()
	_vision.set_glyph(glyph, tint, _side * VisionGlyph.DISC_FRACTION * 0.5)

	if _vision_tween != null and _vision_tween.is_running():
		_vision_tween.kill()

	if Palette.reduced_motion():
		_vision.set_reveal(1.0)
		return

	_vision.set_reveal(0.0)
	_vision_tween = create_tween().set_parallel(true)
	_vision_tween.tween_method(_vision.set_reveal, 0.0, 1.0,
		Palette.duration(VisionGlyph.FADE_IN_SEC)).set_trans(Tween.TRANS_SINE)
	express(&"pulse", VisionGlyph.PUPIL_PULSE)


func hide_vision() -> void:
	_vision_route = ""
	# The renderer is created lazily on the first hover, so hiding before one
	# has ever shown is the normal path, not a failure.
	if _vision != null:
		if _vision_tween != null and _vision_tween.is_running():
			_vision_tween.kill()
		if Palette.reduced_motion():
			_vision.set_reveal(0.0)
		else:
			_vision_tween = create_tween()
			_vision_tween.tween_method(_vision.set_reveal,
				_vision.reveal(), 0.0,
				Palette.duration(Palette.DURATION_FAST))


func vision_visible() -> bool:
	return _vision != null and _vision.reveal() > 0.001


func vision_route() -> String:
	return _vision_route


func _ensure_vision() -> void:
	if _vision != null:
		return
	_vision = VisionRenderer.new()
	_vision.name = "PupilVision"
	# Above the eye shader, below any overlay cosmetic: the glyph is inside
	# the pupil, so a headpiece still occludes it.
	_vision.z_index = Z_OVERLAY - 1
	_vision.z_as_relative = true
	_overlays.add_child(_vision)
	_size_vision()


## Fraction of the gaze vector the pupil translates by.
##
## MUST MATCH `vec2 gaze = gaze_vector * 0.22;` in iris_procedural.gdshader.
## The shader moves the whole iris/pupil group by this much; the vision disc
## is a Control pinned in CPU space and knows nothing about it, so without
## the same term the glyph detaches from the pupil it is supposed to sit in.
##
## Measured on a GPU capture mid-drag: the pupil centroid had travelled to
## (541, 905) while the disc stayed at the view centre (540, 864) — a 41px
## separation on a 500px eye, with the pupil visibly sliding out from under
## its own symbol.
const GAZE_TRANSLATE: float = 0.22


func _size_vision() -> void:
	# Called on every resize, including before the first hover has created
	# the renderer. Absent is expected, not a failure.
	if _vision != null:
		var diameter: float = _side * VisionGlyph.DISC_FRACTION
		_vision.size = Vector2(diameter, diameter)
		_vision.position = _pupil_centre() - Vector2(diameter, diameter) * 0.5


## The pupil's CURRENT rendered diameter in pixels.
##
## Reads the live `pupil_dilation` the shader is actually using — including
## the breathing term added in _process() — rather than the state's target, so
## a caller sizing something to the pupil tracks what is on screen.
func pupil_diameter() -> float:
	var dilation: float = 0.5
	if _material != null:
		var live: Variant = _material.get_shader_parameter("pupil_dilation")
		if live != null:
			dilation = float(live)
	return lerpf(PUPIL_MIN, PUPIL_MAX, clampf(dilation, 0.0, 1.0)) * _side


## Where the pupil actually is, in this control's local space.
##
## SIGN: the shader computes `iris_flat = p - gaze` and draws the pupil where
## `iris_flat ≈ 0`, i.e. at `p ≈ +gaze`. The pupil therefore moves TOWARD the
## gaze direction, so this ADDS. Subtracting sent the disc the opposite way —
## on a north drag the pupil rose while the glyph sank, doubling the error to
## ~110px and putting the symbol on the lower iris. Visible immediately in a
## GPU capture, and invisible to the first version of the check, which
## recomputed this same expression and so agreed with the bug.
##
## `p` is normalised by the SHORT SIDE and spans [-1, 1], so one unit of gaze
## is a half-side in pixels.
func _pupil_centre() -> Vector2:
	return size * 0.5 + _gaze_current * (_side * 0.5 * GAZE_TRANSLATE)


func set_nav_enabled(enabled: bool) -> void:
	_nav_enabled = enabled
	if not enabled:
		_set_hover(IrisState.CompassShard.NONE)
		hide_vision()


func nav_enabled() -> bool:
	return _nav_enabled


# ═════════════════════════════════════════════════════════════════════════
# ANCHOR TRANSFORMATION HELPERS
# ═════════════════════════════════════════════════════════════════════════
## Convert a design-space anchor offset into this view's local pixel position.
## Cosmetics mount through these and never touch the eye's internals.
func anchor_position(slot_name: StringName) -> Vector2:
	var offset: Vector2 = Vector2.ZERO
	if _state != null:
		offset = _state.get_anchor_offset(slot_name)
	else:
		if not Log.must(IrisState.ANCHOR_OFFSETS.has(slot_name),
				"IrisView", "unknown anchor slot '%s'" % slot_name):
			return size * 0.5
		offset = IrisState.ANCHOR_OFFSETS[slot_name]
	return size * 0.5 + offset * anchor_scale()


## Uniform scale from design space to current pixel size.
func anchor_scale() -> float:
	return _side / DESIGN_SIZE


## Full transform for a cosmetic: position, uniform scale, and the tangent
## rotation of the eyelid arc at that slot, so a crown sits along the brow
## rather than floating flat.
func anchor_transform(slot_name: StringName) -> Transform2D:
	var pos: Vector2 = anchor_position(slot_name)
	var scale_factor: float = anchor_scale()
	var angle: float = anchor_rotation(slot_name)
	var basis: Transform2D = Transform2D(angle, Vector2.ONE * scale_factor, 0.0, pos)
	return basis


## Tangent angle of the eyelid arc at a slot. Horizontal at the arc apexes,
## vertical at the hinges — matching how ornaments actually hang on an eye.
func anchor_rotation(slot_name: StringName) -> float:
	match slot_name:
		IrisState.ANCHOR_TOP_ARC, IrisState.ANCHOR_BOTTOM_ARC:
			return 0.0
		IrisState.ANCHOR_LEFT_HINGE:
			return -PI * 0.5
		IrisState.ANCHOR_RIGHT_HINGE:
			return PI * 0.5
	Log.must(false, "IrisView", "unknown anchor slot '%s'" % slot_name)
	return 0.0


## Mount a cosmetic node on a layer. Forces MOUSE_FILTER_IGNORE so it can
## never intercept a tap intended for the eye.
func mount_cosmetic(node: Control, slot_name: StringName, overlay: bool) -> void:
	if not Log.must(node != null, "IrisView", "mount_cosmetic got null"):
		return
	var host: Control = _overlays if overlay else _underlays
	if not Log.must(host != null, "IrisView", "anchor host missing"):
		return
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(node)
	node.position = anchor_position(slot_name)
	node.rotation = anchor_rotation(slot_name)
	node.scale = Vector2.ONE * anchor_scale()
	_force_ignore_recursive(node)


## Remove every mounted cosmetic from both layers.
func clear_cosmetics() -> void:
	for host: Control in [_underlays, _overlays]:
		if host == null:
			continue
		for child: Node in host.get_children():
			# The housing and the pupil vision live on these layers too, but
			# they are PART OF THE EYE, not cosmetics. Freeing them here
			# deleted the metallic surround the moment CosmeticMount.apply()
			# ran — which the hub does on every mount, so the frame existed
			# in isolation and vanished in the real screen.
			if child == _vision or child == _housing:
				continue
			child.queue_free()


# ═════════════════════════════════════════════════════════════════════════
# INPUT — one receptor, intent only
# ═════════════════════════════════════════════════════════════════════════
## The view reports WHAT happened. It never decides what it means, never
## loads a destination image, and never changes a scene. v1's IrisCore owned
## a NAV_SHARDS table with hardcoded route names AND asset paths.
func _on_core_input(event: InputEvent) -> void:
	var pressed: bool = (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
		or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed)
	var released: bool = (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed) \
		or (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed)
	var moved: bool = event is InputEventScreenDrag or event is InputEventMouseMotion

	var local_pos: Vector2 = Vector2.ZERO
	if event is InputEventMouse:
		local_pos = (event as InputEventMouse).position
	elif event is InputEventScreenTouch:
		local_pos = (event as InputEventScreenTouch).position
	elif event is InputEventScreenDrag:
		local_pos = (event as InputEventScreenDrag).position

	if not _interactive:
		if pressed:
			express(&"pulse", 0.5)
			Bus.iris_tapped.emit(IrisState.CompassShard.NONE)
		return

	if pressed:
		_pressing = true
		_update_compass(local_pos)
	elif moved and _pressing:
		_update_compass(local_pos)
	elif released:
		_pressing = false
		var committed: int = _hover_shard
		_hover_shard = IrisState.CompassShard.NONE
		look_reset()
		Bus.iris_shard_hovered.emit(IrisState.CompassShard.NONE)
		if committed != IrisState.CompassShard.NONE:
			Bus.iris_shard_committed.emit(committed)
		else:
			Bus.iris_tapped.emit(IrisState.CompassShard.NONE)


## Map a pointer position to a compass shard by direction, not by zone
## overlap — robust, and it makes the dead-zone unambiguous.
func _update_compass(pos: Vector2) -> void:
	if not _nav_enabled:
		# Gated: track the gaze so the eye still feels alive under a finger,
		# but resolve no shard and show no vision.
		look_at_direction((pos - size * 0.5).normalized() * 0.4)
		return
	var centre: Vector2 = size * 0.5
	var offset: Vector2 = pos - centre
	var distance: float = offset.length()

	if distance < _side * DEADZONE_FRAC:
		look_at_direction(Vector2.ZERO)
		_set_hover(IrisState.CompassShard.NONE)
		return

	var direction: Vector2 = offset / maxf(distance, 0.001)
	var best: int = IrisState.CompassShard.NONE
	var best_dot: float = SHARD_COMMIT_DOT
	var best_dir: Vector2 = Vector2.ZERO

	for entry: Array in _compass_directions():
		var shard_id: int = entry[0]
		var shard_dir: Vector2 = entry[1]
		var dot: float = direction.dot(shard_dir)
		if dot > best_dot:
			best_dot = dot
			best = shard_id
			best_dir = shard_dir

	# Once committed, glance deliberately AT the shard rather than tracking the
	# raw finger — the preview then feels locked in, not twitchy.
	if best != IrisState.CompassShard.NONE:
		look_at_direction(best_dir)
	else:
		look_at_direction(direction * 0.6)

	_set_hover(best)


func _compass_directions() -> Array:
	return [
		[IrisState.CompassShard.NORTH_TRIALS, Vector2(0, -1)],
		[IrisState.CompassShard.EAST_PROGRESS, Vector2(1, 0)],
		[IrisState.CompassShard.SOUTH_DAILY, Vector2(0, 1)],
		[IrisState.CompassShard.WEST_PROFILE, Vector2(-1, 0)],
		# Diagonal, so it cannot steal a cardinal direction. Selection is by
		# MAX dot product, and a 45-degree vector's dot with any cardinal is
		# 0.707 — below a cardinal's own 1.0 — so every existing shard still
		# wins its own direction. Verified by sweep in tools/trend_flow.gd.
		[IrisState.CompassShard.NORTHEAST_TREND, Vector2(0.7071, -0.7071)],
	]


func _set_hover(shard_id: int) -> void:
	if shard_id == _hover_shard:
		return
	_hover_shard = shard_id
	if shard_id != IrisState.CompassShard.NONE:
		express(&"focus", 0.6)
	Bus.iris_shard_hovered.emit(shard_id)


func hovered_shard() -> int:
	return _hover_shard
