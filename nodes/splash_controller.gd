extends Screen
class_name SplashController
## SplashController — the full startup sequence, in one screen.
##
## PHASE 12. Two acts with no scene change between them, because a Router hop
## mid-sequence costs a frame and shows as a hitch on the very first thing a
## player sees.
##
##   ACT 1  sponsor ident      procedural ITTYBITTYBITES mark, ~2.5s
##   ACT 2  title + loading    2SW monogram resolving into the full name,
##                             with a miniature Iris as the progress readout
##
## SUPERSEDES screens/sponsor/ and screens/loading/, which were built in
## Phase 2 before the hub existed and were never revisited.
##
## ZERO ASSETS. Both marks are drawn with vector maths. v1's equivalent was a
## 12 MB branding PNG plus a fake progress bar that loaded nothing.
##
## THE PROGRESS IS REAL. Each warm-up step does actual work — audio channel
## init, save integrity verification, trial registry validation, scene
## preloading. A progress bar that lies is worse than none, because the hitch
## it was meant to hide still happens, just after the bar claims 100%.

# ── Act 1: sponsor ───────────────────────────────────────────────────────
const SPONSOR_FADE_IN: float = 0.6
const SPONSOR_HOLD: float = 1.3
const SPONSOR_FADE_OUT: float = 0.6
const SPONSOR_TOTAL: float = SPONSOR_FADE_IN + SPONSOR_HOLD + SPONSOR_FADE_OUT

# ── Act 2: title ─────────────────────────────────────────────────────────
## The monogram holds alone before the full name resolves under it.
const MONOGRAM_HOLD: float = 0.7
const NAME_RESOLVE: float = 0.8
## Never flash past faster than this: a loading screen that vanishes reads as
## a glitch rather than as speed.
const MIN_LOADING_TIME: float = 1.6

## Warm-up steps, in order. Each is real work with a human-readable label.
const WARMUP_STEPS: Array[Dictionary] = [
	{"id": &"audio", "label": "Audio engine"},
	{"id": &"save", "label": "Save integrity"},
	{"id": &"trials", "label": "Trial matrices"},
	{"id": &"trends", "label": "Weekly rotation"},
	{"id": &"scenes", "label": "Preparing the Iris"},
]

## Scenes worth paying for now rather than on first navigation.
const PREWARM_SCENES: Array[String] = [
	"res://screens/hub_portal.tscn",
	"res://screens/trial_host.tscn",
]

@onready var _background: ColorRect = %Background
@onready var _sponsor_layer: Control = %SponsorLayer
@onready var _sponsor_name: Label = %SponsorName
@onready var _sponsor_tagline: Label = %SponsorTagline
@onready var _title_layer: Control = %TitleLayer
@onready var _title_name: Label = %TitleName
@onready var _iris_progress: Control = %IrisProgress
@onready var _status_label: Label = %StatusLabel
@onready var _skip_hint: Label = %SkipHint
@onready var _bloom: SplashBloom = %Bloom
@onready var _sponsor_mark: Control = %SponsorMark
@onready var _sponsor_plate: SplashPlate = %SponsorPlate
@onready var _title_plate: SplashPlate = %TitlePlate

var _wired: bool = false
var _act: int = 0                  # 0 = sponsor, 1 = title/loading
var _skipped_sponsor: bool = false
var _finished: bool = false
var _progress: float = 0.0
var _loading_started_at: float = 0.0
## Carved bands drawn behind the sponsor name and the status line.
var _bands: Array[RuneBand] = []


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	_wired = (
		Log.must(_sponsor_layer != null, "Splash", "%SponsorLayer missing")
		and Log.must(_title_layer != null, "Splash", "%TitleLayer missing")
		and Log.must(_iris_progress != null, "Splash", "%IrisProgress missing")
		and Log.must(_status_label != null, "Splash", "%StatusLabel missing")
		and Log.must(_bloom != null, "Splash", "%Bloom missing")
		and Log.must(_sponsor_plate != null, "Splash", "%SponsorPlate missing")
		and Log.must(_title_plate != null, "Splash", "%TitlePlate missing")
	)
	if not _wired:
		return

	# THE CINEMATIC BACKDROP.
	#
	# The splash was the only screen in the app with no atmosphere layer: a
	# flat ColorRect, three vector marks, nothing behind them. Every other
	# screen had been given the vignette and the drifting dust, so the very
	# first thing a player sees was the least finished thing in the build.
	#
	# install_atmosphere() is the SAME call the hub, wardrobe, progress and
	# settings screens already make — the darkening vignette that pulls the
	# frame in around the mark, plus the slow teal motes that stop a dark
	# screen reading as a frozen app. Nothing bespoke, and nothing about the
	# startup sequence's logic changes.
	install_atmosphere()
	_install_rune_bands()

	_style()
	# TitleLayer stays VISIBLE but fully transparent. A hidden container never
	# performs a sort, so its children report zero size — which silently broke
	# the procedural marks' centring until the layout test caught it.
	_title_layer.modulate.a = 0.0
	_sponsor_layer.modulate.a = 0.0

	_run_sponsor()


func _operational(context: String) -> bool:
	if _wired:
		return true
	Log.d("Splash", "not operational in %s" % context)
	return false


## Set the sponsor name and the status line on their own carved bands.
##
## The bands are inserted as PRECEDING SIBLINGS of the labels they frame, so
## they paint underneath without becoming the labels' parent. That matters:
## reparenting a Label clears its `owner` and de-registers its %UniqueName —
## the exact fault that broke sixteen checks when the HUD bezels first landed.
## Nothing about these labels changes here except what is drawn behind them.
func _install_rune_bands() -> void:
	for label: Label in [_sponsor_name, _status_label]:
		if label == null:
			continue
		var parent: Node = label.get_parent()
		if parent == null:
			continue
		var band := RuneBand.new()
		band.name = "%sBand" % label.name
		band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Match the label's slot in the VBox so the band occupies the same
		# column, then sit one index earlier so it draws first.
		band.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parent.add_child(band)
		parent.move_child(band, label.get_index())
		band.frame(label)
		_bands.append(band)


## Keep each band registered with its label's live rect after layout.
func _fit_rune_bands() -> void:
	for band: RuneBand in _bands:
		var label: Label = band.framed_label()
		if label == null:
			continue
		# The band is a zero-height sibling in the box, so it is given no space
		# of its own. Park it over the label's rect and let band_rect() measure
		# the text inside that.
		band.position = label.position
		band.size = label.size
		band.queue_redraw()


## Re-aim the halo once the containers have actually sized the marks.
##
## Rule G: geometry belongs here, not in _setup(). focus_on() reads the target's
## rect, and during _setup() the VBox has not sorted yet — every mark reports
## (0,0), so the halo would aim at the top-left corner and stay there.
func _layout() -> void:
	if not _operational("_layout"):
		return
	var mark: Control = _sponsor_mark if _act == 0 else _iris_progress
	if mark != null:
		_bloom.focus_on(mark)
	_fit_rune_bands()


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND

	_sponsor_name.text = "ITTYBITTYBITES"
	_sponsor_name.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_sponsor_name.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_HEADING))

	_sponsor_tagline.text = "experience"
	_sponsor_tagline.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_sponsor_tagline.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_SMALL))

	_title_name.text = "TWO SECOND WITNESS"
	_title_name.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	_title_name.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_SMALL))

	_status_label.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_status_label.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_MICRO))

	_skip_hint.text = "tap to skip"
	_skip_hint.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_skip_hint.add_theme_font_size_override(
		"font_size", Palette.font(Palette.FONT_MICRO))
	_skip_hint.modulate.a = 0.0


func _on_palette_changed(_tier: int) -> void:
	_style()


# ═════════════════════════════════════════════════════════════════════════
# ACT 1 — SPONSOR
# ═════════════════════════════════════════════════════════════════════════
## Base halo level during the sponsor ident, before any warm-up has run.
##
## Non-zero on purpose: the ident is lit by the same source as the rest of the
## sequence, and starting the bloom at literally nothing makes Act 1 look like
## a different screen from Act 2 rather than the opening of the same one.
const SPONSOR_BLOOM: float = 0.16


func _run_sponsor() -> void:
	_act = 0
	if _bloom != null:
		_bloom.set_progress(SPONSOR_BLOOM)
		# Light the mark that is actually on screen.
		_bloom.focus_on(_sponsor_mark)
	# The harmonic cue lands as the mark illuminates, not on scene entry —
	# sound and light arriving together is what makes an ident feel deliberate.
	AudioManager.play_iris_formant(&"hub_idle", 14)
	AudioManager.play_ambient_pad(0.18)

	if Palette.reduced_motion():
		_sponsor_layer.modulate.a = 1.0
		await get_tree().create_timer(0.7).timeout
		_begin_title()
		return

	var tween: Tween = create_tween()
	tween.tween_property(_sponsor_layer, "modulate:a", 1.0, SPONSOR_FADE_IN) \
		.set_trans(Tween.TRANS_SINE)
	tween.parallel().tween_property(_skip_hint, "modulate:a", 1.0,
		Palette.DURATION_SLOW).set_delay(SPONSOR_FADE_IN)
	tween.tween_interval(SPONSOR_HOLD)
	tween.tween_property(_sponsor_layer, "modulate:a", 0.0, SPONSOR_FADE_OUT) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_callback(_begin_title)


# ═════════════════════════════════════════════════════════════════════════
# ACT 2 — TITLE + LOADING
# ═════════════════════════════════════════════════════════════════════════
func _begin_title() -> void:
	if _act >= 1:
		return
	_act = 1
	_loading_started_at = Time.get_ticks_msec() / 1000.0

	_sponsor_layer.visible = false

	# Move the halo from the ident to the iris, which is what Act 2 is lit
	# around. A glow left pointing at a mark that is no longer on screen puts
	# its bright core in empty space and silhouettes the eye against it.
	if _bloom != null:
		_bloom.focus_on(_iris_progress)

	# The monogram resolves into the full name: 2SW holds alone, then the
	# words fade in beneath it.
	_title_name.modulate.a = 0.0
	var fade: float = Palette.duration(Palette.DURATION_MED)
	var tween: Tween = create_tween()
	tween.tween_property(_title_layer, "modulate:a", 1.0, fade)
	tween.tween_interval(Palette.duration(MONOGRAM_HOLD))
	tween.tween_property(_title_name, "modulate:a", 1.0,
		Palette.duration(NAME_RESOLVE)).set_trans(Tween.TRANS_SINE)

	_run_warmup()


## Real work, one step at a time, with the status line reflecting each.
func _run_warmup() -> void:
	var total: int = WARMUP_STEPS.size()
	for i: int in range(total):
		var step: Dictionary = WARMUP_STEPS[i]
		_set_status(str(step["label"]))
		# NOT awaited: _perform_step() contains no await, so it is a plain
		# call and awaiting it raises REDUNDANT_AWAIT. It became synchronous
		# when the threaded scene preload was replaced with a blocking load.
		_perform_step(StringName(step["id"]))
		_set_progress(float(i + 1) / float(total))
		# One frame between steps so the Iris visibly advances rather than
		# jumping straight to full.
		await get_tree().process_frame

	_set_status("ready")
	await _hold_minimum()
	_hand_off()


## Each step does genuine work. If one fails the sequence continues — a
## startup screen must never strand the player.
func _perform_step(step_id: StringName) -> void:
	match step_id:
		&"audio":
			# Touch every channel so buses and generators are live before the
			# first gameplay cue rather than during it.
			AudioManager.set_pad_intensity(0.22)
			AudioManager.play_sfx(&"ui_tap")
		&"save":
			# Verify the save round-trips. A corrupt file surfaces here, at a
			# moment we control, rather than mid-trial.
			var state: IrisState = IrisState.new()
			var stored: Dictionary = Save.get_v("iris", "state", {})
			if not stored.is_empty():
				state.from_dict(stored)
			TrialRegistry.ensure_history(state)
		&"trials":
			var problems: Array[String] = TrialRegistry.validate()
			if not problems.is_empty():
				Log.error("Splash", "trial registry invalid: %s" % str(problems))
		&"trends":
			# Detect a calendar week change and snapshot the outgoing roster
			# before the new one loads. Unlock records are NOT touched —
			# passes live in IrisState keyed by pack id, and the archive
			# stores only what the categories WERE.
			var week_change: Dictionary = TrendLoader.check_week_rotation()
			if bool(week_change.get("rotated", false)):
				Log.info("Splash", "week %s -> %s (archived=%s)" % [
					str(week_change.get("previous_week", "")),
					str(week_change.get("current_week", "")),
					str(week_change.get("archived", false))])
		&"scenes":
			for path: String in PREWARM_SCENES:
				if ResourceLoader.exists(path):
					ResourceLoader.load_threaded_request(path)
			for path: String in PREWARM_SCENES:
				if ResourceLoader.exists(path):
					ResourceLoader.load_threaded_get(path)
		_:
			Log.must(false, "Splash", "unknown warm-up step '%s'" % step_id)


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)
	if _iris_progress != null and _iris_progress.has_method("set_progress"):
		_iris_progress.call("set_progress", _progress)
	# The halo swells with the SAME measured progress the iris aperture reads.
	# One source of truth, so the glow can never disagree with the eye about
	# how far along the warm-up is.
	if _bloom != null:
		_bloom.set_progress(_progress)


func progress() -> float:
	return _progress


## Hold so a fast device does not flash the title past unread.
func _hold_minimum() -> void:
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _loading_started_at
	var remaining: float = MIN_LOADING_TIME - elapsed
	if remaining > 0.0:
		await get_tree().create_timer(remaining).timeout


# ═════════════════════════════════════════════════════════════════════════
# ROUTING HANDOFF
# ═════════════════════════════════════════════════════════════════════════
## Resolve where a player goes after the splash.
##
## Static and pure so the decision can be tested without running the sequence.
## Order matters: consent is a legal gate and must precede everything.
static func resolve_destination() -> String:
	# TWO OUTCOMES ONLY: consent, or the hub.
	#
	# There used to be a third — a four-line tap-through intro carousel
	# ("Initialization complete." / "I am Iris." / ...) gated on a
	# meta.first_run_done flag. It has been removed: it stood between a new
	# player and the game for four taps, and the trial itself now carries a
	# one-time briefing that explains the mode at the moment it is relevant,
	# which is where an explanation actually helps.
	#
	# Uses is_recorded(), NOT is_satisfied(). The debug bypass exists so the
	# App boot gate never blocks the editor, but the splash must still be able
	# to REACH the consent screen in a debug build — otherwise the screen
	# becomes untestable and unreviewable.
	if not ConsentController.is_recorded():
		return "consent"
	return "hub"


func _hand_off() -> void:
	if _finished:
		return
	_finished = true
	var destination: String = resolve_destination()
	Log.info("Splash", "handing off to '%s'" % destination)
	# replace(), not go(): the splash must never be reachable via back.
	await Router.replace(destination)


# ═════════════════════════════════════════════════════════════════════════
# SKIP
# ═════════════════════════════════════════════════════════════════════════
## A tap skips the sponsor ident. It does NOT skip loading — the warm-up is
## real work, and skipping it would just move the hitch somewhere less
## forgivable.
func _gui_input(event: InputEvent) -> void:
	var pressed: bool = (
		(event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
		or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed))
	if pressed:
		skip()


func skip() -> void:
	if _act > 0 or _skipped_sponsor:
		return
	_skipped_sponsor = true
	AudioManager.play_sfx(&"ui_tap")
	HapticsManager.pulse(&"ui_tap")
	_begin_title()


func was_skipped() -> bool:
	return _skipped_sponsor


## Back during startup does nothing. There is nowhere behind this.
func on_back_requested() -> bool:
	return true
