extends Node
## Palette — centralized design tokens. Autoload (Rule D).
##
## Nothing anywhere may hardcode a Color, font size, or animation duration.
## Every visual constant in the project resolves here, so the whole app
## re-skins from one file and an accessibility setting can override globally.
##
## v1 scattered literals like Color(0.03, 0.04, 0.08, 1) across 12 scripts and
## every .tscn, so "make it less bright" meant hunting call sites.
##
## Brightness rationale (dark-room tuned — a 2-minute cognitive trainer is used
## at night):
##   - Backgrounds sit at L* ~6-12, never pure black. Pure black smears on OLED
##     during motion and crushes the Iris's glow to nothing.
##   - Body text tops out at 0.82 white, never 1.0.
##   - Surfaces stay desaturated so the Iris is the only luminous thing.

# ═════════════════════════════════════════════════════════════════════════
# COLOR TOKENS
# ═════════════════════════════════════════════════════════════════════════
const COLOR_BACKGROUND   := Color(0.024, 0.031, 0.055)  # deepest backdrop
const COLOR_SURFACE      := Color(0.043, 0.055, 0.090)  # panels
const COLOR_SURFACE_HIGH := Color(0.070, 0.086, 0.130)  # raised panels
const COLOR_HAIRLINE     := Color(1, 1, 1, 0.07)        # 1px separators
const COLOR_SCRIM        := Color(0, 0, 0, 0.62)        # modal backdrop

const COLOR_TEXT         := Color(0.82, 0.86, 0.94)
const COLOR_TEXT_DIM     := Color(0.82, 0.86, 0.94, 0.62)
## Tertiary text: hints, captions, "Locked" badges, unearned streak markers.
##
## The alpha here is NOT a taste decision, it is a measured floor. Composited
## over COLOR_BACKGROUND the old 0.34 produced a 2.47:1 contrast ratio against
## a 4.5:1 WCAG AA requirement for text below 24px — and every consumer of this
## token draws at FONT_MICRO (15px) or FONT_SMALL (19px), so none of them earn
## the large-text exemption. 75 of the 206 labels in the app were illegible.
##
## Solving contrast(alpha) = 4.5 over the darkest surface gives alpha = 0.529.
## 0.55 clears it with margin on all three panel colours: 4.79:1 on background,
## 4.79:1 on surface, 4.72:1 on surface_high. Anything below 0.53 fails.
const COLOR_TEXT_FAINT   := Color(0.82, 0.86, 0.94, 0.55)

const COLOR_SUCCESS      := Color(0.35, 0.88, 0.62)
const COLOR_DANGER       := Color(0.95, 0.40, 0.42)
const COLOR_WARNING      := Color(0.98, 0.76, 0.36)

## Tier accents — index maps to rank tier. Iris and UI share these, so a
## rank-up re-skins the entire app in sync with the eye.
const TIER_ACCENTS: Array[Color] = [
	Color(0.22, 0.72, 0.78),   # 0 Observer     deep teal
	Color(0.26, 0.66, 0.95),   # 1 Seer         cyan
	Color(0.30, 0.80, 0.66),   # 2 Sentinel     blue-green
	Color(0.50, 0.50, 0.95),   # 3 Oracle       violet
	Color(0.62, 0.70, 0.88),   # 4 Witness      silver-blue
	Color(0.90, 0.72, 0.36),   # 5 Luminary     gold
	Color(0.88, 0.42, 0.66),   # 6 Eternal      rose
	Color(0.80, 0.82, 0.90),   # 7 Transcendent prismatic
]

## Deuteranopia/protanopia-safe substitutes for the pass/fail pair, which is
## the only place colour alone carries meaning.
const COLOR_SUCCESS_CB := Color(0.35, 0.72, 0.98)
const COLOR_DANGER_CB  := Color(0.98, 0.62, 0.20)

# ── Iris rendering tokens ────────────────────────────────────────────────
## Used by procedurally drawn eyes (loading indicator, sponsor mark, and the
## real Iris). Kept here so the eye can never drift from the app's palette.
## ── THE EYE'S OWN PALETTE ────────────────────────────────────────────────
## Measured against the art reference, not chosen by eye. Sampling the
## reference eye gave:
##
##     median pixel        0.097   (near-black — the eye GLOWS out of dark)
##     bright pixels       8.3%    of the frame
##     mean saturation     0.726
##
## The shader previously fed sclera_color = COLOR_TEXT (0.82, 0.86, 0.94),
## a near-white. Measured, that produced 25.4% bright pixels — 3x the
## reference — and 0.461 saturation. The eye read as a white eyeball with a
## teal disc rather than as a luminous iris in shadow. No amount of shader
## maths corrects a value structure that is inverted at the source.
##
## A dark globe with a saturated iris is also what makes the catchlight
## read: a highlight is only bright RELATIVE to what surrounds it.
const COLOR_SCLERA_DEEP := Color(0.055, 0.098, 0.105)
## Brushed metal for the eye's housing. Sampled from the reference's lid
## frame, which is a warm gunmetal rather than a neutral grey — the warmth is
## what stops it reading as plastic against the cold teal iris.
const COLOR_SURROUND_METAL := Color(0.278, 0.243, 0.180)
## The wet rim where the globe curves away — barely lifted from the sclera.
const COLOR_SCLERA_RIM  := Color(0.118, 0.212, 0.212)
## Saturation multiplier applied to the tier accent for the iris body.
const IRIS_SATURATION_BOOST := 1.45

const COLOR_PUPIL      := Color(0.015, 0.020, 0.035)
const COLOR_PUPIL_RIM  := Color(0.020, 0.030, 0.050)
const COLOR_CATCHLIGHT := Color(1, 1, 1, 0.55)
const COLOR_CATCHLIGHT_SOFT := Color(1, 1, 1, 0.18)
const COLOR_TRANSPARENT := Color(1, 1, 1, 0)

## Alpha ramps for concentric iris rings: outer rings fade toward the limbus.
const IRIS_RING_ALPHA_INNER := 0.42
const IRIS_RING_ALPHA_OUTER := 0.05
const IRIS_GLOW_ALPHA := 0.045

# ═════════════════════════════════════════════════════════════════════════
# TRIAL HUD — carved bezels and feedback
# ═════════════════════════════════════════════════════════════════════════
## The in-trial readouts (score, timer, streak) are drawn as carved metal
## plates rather than bare labels. These are the tokens that describe them.
##
## Every value lives here rather than in the bezel script for the same reason
## every other colour does: an accessibility or art pass retunes the whole HUD
## from one file, and Rule D can mechanically prove no literal escaped.

## Bezel plate fill.
##
## MEASURED AGAINST THE BACKGROUND, NOT CHOSEN BY EYE. The first value was
## Color(0.035, 0.047, 0.070), picked to read as "recessed" — which computed to
## a 1.02:1 contrast ratio against COLOR_BACKGROUND. That is indistinguishable
## from invisible, and on a real device the plates simply were not there: the
## HUD looked exactly like the bare labels it was meant to replace.
##
## 1.18:1 is still deliberately subtle, because the plate is a backdrop, not a
## button. The bezel is made legible by its METAL RIM (1.62:1 against this
## fill) and its cyan arc (7.06:1), which is how a carved edge actually reads.
const COLOR_BEZEL_PLATE := Color(0.090, 0.110, 0.158)
## The machined groove cut around the plate's inner edge.
const COLOR_BEZEL_GROOVE := Color(0.012, 0.018, 0.030)
## Warm metal catching light on the plate's top edge. Shares the surround
## tone of the hero housing so the HUD and the eye read as the same alloy.
const COLOR_BEZEL_METAL := Color(0.278, 0.243, 0.180)

## Bezel geometry, as fractions of the plate's short side.
const BEZEL_RIM_FRAC := 0.055
const BEZEL_GROOVE_FRAC := 0.030
## Corner rounding of a bezel plate, in pixels.
const BEZEL_RADIUS := 10

## The cyan progress arc drawn inside a bezel.
const BEZEL_ARC_ALPHA := 0.92
## Unfilled remainder of the arc — present, so the track reads as a dial with
## a start and an end rather than a bar growing out of nothing.
const BEZEL_TRACK_ALPHA := 0.14
## Arc thickness as a fraction of the plate's short side.
const BEZEL_ARC_FRAC := 0.075
## Concentric passes used to bloom the arc without a shader.
const BEZEL_GLOW_RINGS := 4
const BEZEL_GLOW_ALPHA := 0.09

## ── Success / failure feedback ───────────────────────────────────────────
## A correct answer fires an expanding cyan energy pulse; a wrong one fires a
## chromatic abrasion — the red and blue channels torn apart by a few pixels,
## the way a damaged sensor smears. Both are deliberately SHORT: feedback that
## outlasts the next stimulus stops being feedback and becomes noise.
const FEEDBACK_PULSE_SEC := 0.44
const FEEDBACK_ABRASION_SEC := 0.32

## How far a success pulse travels, as a multiple of the field's short side.
const FEEDBACK_PULSE_REACH := 0.62
## Rings in the expanding pulse.
const FEEDBACK_PULSE_RINGS := 3
const FEEDBACK_PULSE_ALPHA := 0.44

## Peak channel separation of a failure abrasion, as a fraction of the short
## side. Subtle by intent — the brief asked for abrasion, not a glitch effect.
const FEEDBACK_ABRASION_SPREAD := 0.016
const FEEDBACK_ABRASION_ALPHA := 0.30
## Horizontal tear lines drawn across the abrasion.
const FEEDBACK_ABRASION_BANDS := 7

## How far the tears reach from the answered point, as a fraction of the
## field's short side. Confined rather than full-screen.
##
## THESE THREE TOKENS EXIST BECAUSE THE FIRST VERSION WAS RENDERED AND WAS
## WRONG. It filled every band edge to edge at 0.30 alpha, which drew solid
## red and cyan stripes over the whole play field — a glitch effect that also
## obscured the stimulus the player was trying to read. Real chromatic
## aberration fringes edges; it does not flood areas.
const FEEDBACK_ABRASION_REACH := 0.22
## Tear line thickness, as a fraction of the short side.
const FEEDBACK_ABRASION_LINE := 0.004
## Tear length, as a fraction of the field's width.
const FEEDBACK_ABRASION_LENGTH := 0.34

# ═════════════════════════════════════════════════════════════════════════
# SPLASH — the cinematic startup bloom
# ═════════════════════════════════════════════════════════════════════════
## A wide cyan halo behind the startup marks, rising as the warm-up advances.
## The splash used to be a flat fill with three vector marks on it; this is
## what gives the sequence depth and a sense of something powering up.

## Concentric passes in the halo. Each is drawn at a LOW alpha and they
## accumulate — the gradient is the sum, not any single ring.
##
## THIS IS WHY THE COUNT IS HIGH AND THE ALPHA IS LOW. An earlier preview
## stacked a dozen near-opaque arcs and produced a solid cyan disc that
## obliterated the mark behind it. A soft bloom is many faint layers.
const SPLASH_HALO_RINGS := 26
const SPLASH_HALO_ALPHA := 0.018

## Halo reach as a fraction of the screen's short side, at full progress.
const SPLASH_HALO_REACH := 0.92
## Reach before loading starts, so the bloom visibly GROWS rather than just
## brightening in place.
const SPLASH_HALO_REACH_MIN := 0.34

## Breath period of the halo, in seconds.
const SPLASH_HALO_BREATH := 3.4
## How much the halo scale varies over one breath.
const SPLASH_HALO_BREATH_AMOUNT := 0.045

## ── Runic text frames ────────────────────────────────────────────────────
## The sponsor name and status line are set on their own small carved bands,
## so the type belongs to the same forged object as the baked centerpieces
## rather than floating as bare labels beneath them.
##
## Drawn procedurally, not baked: the text is a Label whose width changes with
## the string and the font scale, and a fixed-size texture behind live text
## would either crop it or float away from it.
const COLOR_RUNE_BAND := Color(0.055, 0.070, 0.098)
const COLOR_RUNE_ETCH := Color(0.278, 0.243, 0.180)

## Band height as a multiple of the text's own height.
const RUNE_BAND_PAD := 1.55
## Horizontal padding beyond the text, as a multiple of text height.
const RUNE_BAND_SIDE := 1.1
## Rune ticks etched along the band's rails.
const RUNE_TICKS := 13
const RUNE_TICK_ALPHA := 0.40
## Thickness of the band's rails, as a fraction of band height.
const RUNE_RAIL_FRAC := 0.055
## Length of the tapered end caps, as a fraction of band height.
const RUNE_CAP_FRAC := 0.62

## Facet Cascade gem colours. Six maximally-separable hues; the bracket picks
## how many are in play (4 easy -> 6 hard). Kept in Palette so an accessibility
## pass retunes every appearance from one place.
const FACET_COLORS: Array[Color] = [
	Color(0.30, 0.85, 0.95),   # cyan
	Color(0.45, 0.95, 0.70),   # green
	Color(0.65, 0.55, 1.00),   # violet
	Color(1.00, 0.80, 0.40),   # gold
	Color(1.00, 0.50, 0.65),   # rose
	Color(0.80, 0.90, 1.00),   # ice
]

## Stroop trial inks. Four maximally-separable hues that stay legible on the
## dark-room background. Kept here rather than in the trial so a colourblind
## or high-contrast pass can retune every appearance from one place.
const STROOP_INKS: Array[Color] = [
	Color(0.22, 0.78, 0.80),   # teal
	Color(0.92, 0.74, 0.32),   # gold
	Color(0.92, 0.42, 0.52),   # rose
	Color(0.60, 0.48, 0.95),   # violet
]
const STROOP_INK_NAMES: Array[String] = ["TEAL", "GOLD", "ROSE", "VIOLET"]

## Warm amber the eye drifts toward at night, blended by time_of_day_warmth.
const COLOR_NIGHT_WARMTH := Color(1.0, 0.85, 0.6)
## How far night warmth is allowed to pull the iris hue (0-1).
const NIGHT_WARMTH_BLEND := 0.15
## How far the per-day ambient mood drifts the iris hue (0-1).
const AMBIENT_MOOD_BLEND := 0.20

# ═════════════════════════════════════════════════════════════════════════
# SPACING (4pt grid)
# ═════════════════════════════════════════════════════════════════════════
const SPACE_XXS := 4.0
const SPACE_XS  := 8.0
const SPACE_SM  := 12.0
const SPACE_MD  := 16.0
const SPACE_LG  := 24.0
const SPACE_XL  := 32.0
const SPACE_XXL := 48.0
const SPACE_HUGE := 64.0

## Minimum interactive target, in pixels.
##
## 48 is the stricter of the two platform guidelines (Material 48dp, iOS HIG
## 44pt) and the value Android's accessibility scanner enforces. Every
## tappable control is measured against this in tools/polish_audit.gd, which
## found bare CheckButtons rendering at 44x27.
const MIN_TOUCH_TARGET := 48.0

## Standard control heights, all >= MIN_TOUCH_TARGET.
##
## These existed as bare literals scattered across four controllers — 48, 52,
## 56 and 64 — with nothing tying them to the accessibility floor above. A
## literal cannot be audited: raising MIN_TOUCH_TARGET would have left every
## one of them behind, and a typo'd 46 would have passed review. Naming them
## here means the relationship is checkable and the floor is enforceable.
const CONTROL_HEIGHT_SM := 52.0   # dense rows: filter chips, tabs
const CONTROL_HEIGHT_MD := 56.0   # standard buttons and list actions
const CONTROL_HEIGHT_LG := 64.0   # primary calls to action
const CONTROL_HEIGHT_XL := 72.0   # full-width confirm buttons

## Width floor for a label that must not collapse in a squeezed HBox.
const LABEL_MIN_WIDTH := 220.0

## Compass shard marker footprint on the hub.
const MARKER_SIZE := Vector2(160.0, 40.0)

## Panel fill opacity. Below 1.0 so the vignette and dust motes behind a
## panel remain faintly visible, which is what ties a modal to the world
## instead of stamping a solid card over it.
const PANEL_OPACITY := 0.88

## Drop shadow beneath a carved plate. A token rather than a literal so every
## panel and dialog casts the same shadow.
const COLOR_PANEL_SHADOW := Color(0, 0, 0, 0.45)
## Deeper, for a modal that floats above the whole screen.
const COLOR_MODAL_SHADOW := Color(0, 0, 0, 0.55)

const RADIUS_SM := 8
const RADIUS_MD := 14
const RADIUS_LG := 22

# ═════════════════════════════════════════════════════════════════════════
# TYPE SCALE
# ═════════════════════════════════════════════════════════════════════════
const FONT_DISPLAY := 64
const FONT_TITLE   := 42
const FONT_HEADING := 30
const FONT_BODY    := 24
const FONT_SMALL   := 19
const FONT_MICRO   := 15

# ═════════════════════════════════════════════════════════════════════════
# MOTION
# ═════════════════════════════════════════════════════════════════════════
const TRANSITION_SPEED := 0.22   # canonical screen crossfade
const DURATION_FAST    := 0.14
const DURATION_MED     := 0.24
const DURATION_SLOW    := 0.42
const DURATION_INSTANT := 0.01   # reduced-motion substitute

# ═════════════════════════════════════════════════════════════════════════
# STATE
# ═════════════════════════════════════════════════════════════════════════
var _tier: int = 0
var _reduced_motion := false
var _high_contrast := false
var _colorblind := false
var _font_scale := 1.0


func _ready() -> void:
	_refresh_from_save()
	Save.loaded.connect(_refresh_from_save)


func _exit_tree() -> void:
	if Save.loaded.is_connected(_refresh_from_save):
		Save.loaded.disconnect(_refresh_from_save)


## Re-read accessibility settings. Call after any settings change.
func _refresh_from_save() -> void:
	_reduced_motion = bool(Save.setting("reduced_motion", false))
	_high_contrast  = bool(Save.setting("high_contrast", false))
	_colorblind     = bool(Save.setting("colorblind", false))
	_font_scale     = float(Save.setting("font_scale", 1.0))


func refresh() -> void:
	_refresh_from_save()
	Bus.palette_changed.emit(_tier)


# ─────────────────────────────────────────────────────────────────────────
# Tier
# ─────────────────────────────────────────────────────────────────────────
func set_tier(t: int) -> void:
	var clamped := clampi(t, 0, TIER_ACCENTS.size() - 1)
	if clamped == _tier:
		return
	_tier = clamped
	Bus.palette_changed.emit(_tier)


func tier() -> int:
	return _tier


## The current accent, honouring high-contrast.
func accent() -> Color:
	var c: Color = TIER_ACCENTS[_tier]
	if _high_contrast:
		c = c.lightened(0.22)
	return c


func accent_alpha(a: float) -> Color:
	var c := accent()
	c.a = a
	return c


# ─────────────────────────────────────────────────────────────────────────
# Accessibility-aware accessors
# ─────────────────────────────────────────────────────────────────────────
## Scale a token font size by the text-size setting.
func font(size: int) -> int:
	return int(round(float(size) * _font_scale))


## A duration that collapses to near-zero under reduced motion.
func duration(d: float) -> float:
	return DURATION_INSTANT if _reduced_motion else d


func reduced_motion() -> bool:
	return _reduced_motion


func high_contrast() -> bool:
	return _high_contrast


func success() -> Color:
	return COLOR_SUCCESS_CB if _colorblind else COLOR_SUCCESS


func danger() -> Color:
	return COLOR_DANGER_CB if _colorblind else COLOR_DANGER


# ─────────────────────────────────────────────────────────────────────────
# Style helpers — so widgets never build StyleBoxes from literals
# ─────────────────────────────────────────────────────────────────────────
## Carved metallic panel, matching the hero eye's housing.
##
## Every panel in the app routes through here — the consent card, the chrono
## result card, the daily anomaly panel, the trend archive cards — so lifting
## this one function restyles all of them at once. That is the whole reason
## it exists rather than each screen building its own StyleBoxFlat.
##
## THE CARVED LOOK, in three parts:
##   * a translucent dark fill, so the vignette and dust motes behind it read
##     through the panel rather than being blocked by it
##   * a bright accent-tinted TOP border and a dark bottom, which is what
##     makes a flat rectangle read as a bevelled plate lit from above
##   * a soft drop shadow, so the plate floats off the backdrop
##
## A uniform 1px hairline on all four sides — what this used to draw — cannot
## produce that: an even outline is the one thing a real carved edge never is.
func panel_style(raised: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var base: Color = COLOR_SURFACE_HIGH if raised else COLOR_SURFACE
	# Translucent, not opaque: the atmosphere layer shows through.
	base.a = PANEL_OPACITY
	sb.bg_color = base
	sb.set_corner_radius_all(RADIUS_MD)

	# Bevel: lit top edge, shadowed bottom.
	var lit: Color = accent()
	lit.a = 0.34
	var shadow: Color = COLOR_BACKGROUND
	shadow.a = 0.72
	sb.border_color = lit
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.border_width_bottom = 1
	sb.expand_margin_top = 0.0

	sb.shadow_color = COLOR_PANEL_SHADOW
	sb.shadow_size = int(SPACE_SM)
	sb.shadow_offset = Vector2(0.0, 3.0)

	sb.content_margin_left = SPACE_MD
	sb.content_margin_right = SPACE_MD
	sb.content_margin_top = SPACE_SM
	sb.content_margin_bottom = SPACE_SM
	return sb


func bar_style(c: Color, radius: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	return sb
