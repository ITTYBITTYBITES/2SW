extends Screen
class_name ConsentController
## ConsentController — first-run privacy and F2P disclosure.
##
## PHASE 10, SIMPLIFIED IN PHASE 17.
##
## THE CONSENT MODEL — opt-in, not opt-out:
## Accepting the terms is required to play. Ad personalisation and analytics
## are SEPARATE, default to OFF, and are NOT ASKED FOR HERE. A player who taps
## straight through gets the most private configuration possible, because that
## is the only configuration this screen can produce.
##
## WHY THE TOGGLES LEFT THIS SCREEN:
## Two switches on the very first screen is onboarding friction that buys
## nothing. Under GDPR a pre-ticked box is unlawful and an untouched box is
## simply "no" — so a screen whose switches are both OFF and which the player
## never touches is legally identical to a screen with no switches at all,
## while being slower to read and easier to get wrong. The switches now live
## in Settings → Privacy & Data, where a player who WANTS to opt in can, at
## any time. Withdrawal stays exactly as easy as consent.
##
## What this means concretely: consent_defaults() is the single definition of
## the untouched state, commit_consent() only ever writes those defaults for a
## FIRST acceptance, and a revisit preserves whatever the player later chose
## in Settings rather than silently resetting it.
##
## v1 shipped a consent screen but the RESUME PATH ROUTED AROUND IT: a player
## who force-quit here came back straight into the game having never accepted.
## `app.gd` now gates before reading the session snapshot, and test_boot.py
## asserts it.
##
## REVISIT MODE: when opened from Settings the screen re-states the terms,
## swaps the CTA to "Done", and returns rather than continuing to the game.
## It never rewrites the player's privacy choices.

## Bump when the policy text changes materially. A player whose stored version
## is older is re-prompted, which is what "material change" consent requires.
const POLICY_VERSION: int = 1

const PRIVACY_URL: String = "https://ittybittybites.github.io/privacy-policy/"
const TERMS_URL: String = "https://ittybittybites.github.io/privacy-policy/terms/"

## The whole disclosure, in four sentences. Anything longer is not read.
const BODY_TEXT: String = """Two Second Witness is free to play and uses non-personalized services to run.

There are no purchases of any kind — every cosmetic is earned through play, rewarded ads, or surprise drops.

Your progress is stored only on this device. No account, no name, no email.

Personalised ads and anonymous analytics are OFF. You can turn either on in Settings → Privacy & Data."""

## Card sizing. Held to a readable measure rather than the full screen width,
## and never wider than the viewport minus the screen margins.
const CARD_MAX_WIDTH: float = 720.0

@onready var _background: ColorRect = %Background
@onready var _root: MarginContainer = %Root
@onready var _scroll: ScrollContainer = %Scroll
@onready var _card: PanelContainer = %Card
@onready var _title: Label = %TitleLabel
@onready var _body: Label = %BodyLabel
@onready var _privacy_button: Button = %PrivacyButton
@onready var _terms_button: Button = %TermsButton
@onready var _accept_button: Button = %AcceptButton
@onready var _back_button: Button = %BackButton

var _wired: bool = false
## True when opened from Settings rather than as the first-run gate.
var _revisit: bool = false


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	# This screen folds the safe area into its own MarginContainer;
	# the base class must not offset it a second time.
	handles_own_safe_area = true
	_revisit = bool(payload.get("revisit", false))

	_wired = (
		Log.must(_card != null, "Consent", "%Card missing")
		and Log.must(_accept_button != null, "Consent", "%AcceptButton missing")
		and Log.must(_body != null, "Consent", "%BodyLabel missing")
	)
	if not _wired:
		return

	_accept_button.pressed.connect(_on_accept_pressed)
	_privacy_button.pressed.connect(_on_privacy_pressed)
	_terms_button.pressed.connect(_on_terms_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# Back is only meaningful on a revisit; on first run there is nowhere to go.
	_back_button.visible = _revisit

	# The scrollbar appearing changes the usable width, so the layout has to
	# be recomputed when it does — see _layout().
	_scroll.get_v_scroll_bar().visibility_changed.connect(_layout)
	# No _layout() here: Screen defers the first call, and geometry is not
	# valid during _setup().
	_style()


func _exit_tree() -> void:
	# `resized` is owned by Screen, which connects and tears it down itself.
	# Only the scrollbar subscription belongs to this controller.
	if _scroll != null:
		var bar: VScrollBar = _scroll.get_v_scroll_bar()
		if bar != null and bar.visibility_changed.is_connected(_layout):
			bar.visibility_changed.disconnect(_layout)
	super()


func _operational(context: String) -> bool:
	if _wired:
		return true
	Log.d("Consent", "not operational in %s" % context)
	return false


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND

	_root.add_theme_constant_override("margin_top", int(maxf(safe_top, Palette.SPACE_LG)))
	_root.add_theme_constant_override("margin_bottom",
		int(maxf(safe_bottom, Palette.SPACE_LG)))

	_card.add_theme_stylebox_override("panel", Palette.panel_style(true))

	_title.text = "Privacy" if _revisit else "Before we begin"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))

	_body.text = BODY_TEXT
	_body.add_theme_color_override("font_color", Palette.COLOR_TEXT_DIM)
	_body.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))

	# A revisit is informational: consent is already recorded, so the button
	# dismisses rather than re-agreeing.
	_accept_button.text = "Done" if _revisit else "Agree & Continue"


## Keep the card inside the visible margins, and dead centre, at any aspect.
##
## THE BUG THIS PREVENTS: the previous layout was authored against a fixed
## 1080-wide design, so on a short landscape viewport the content ran past the
## bottom edge and the Continue button was unreachable. Sizing from the live
## viewport instead of a design constant means the card shrinks to fit rather
## than overflowing, and the ScrollContainer catches the remainder on a
## viewport too short for even the shrunk card.
##
## THE SCROLLBAR ASYMMETRY: a visible vertical scrollbar consumes width from
## the RIGHT edge only, so a card centred in what is left sits half a bar
## width off the true centre — 4px at 800x600, which the layout test caught.
## Compensating means adding the bar's width to the LEFT margin so the
## remaining content region is symmetric about the viewport midline:
##
##   left = right + bar   ⟹   left + (W - left - right - bar)/2 == W/2
##
## The gutter is reserved in the WIDTH calculation unconditionally, whether or
## not the bar is currently showing. That is deliberate: if the card's width
## depended on the bar's visibility, widening the card could hide the bar,
## which would widen the card again — a layout feedback loop that oscillates
## for a few frames and settles differently depending on frame timing. Only
## the margin reacts to visibility; the width never does.
func _layout() -> void:
	if not _operational("_layout"):
		return

	var bar: VScrollBar = _scroll.get_v_scroll_bar()
	var gutter: float = 0.0
	if bar != null:
		gutter = maxf(bar.size.x, bar.get_minimum_size().x)

	var margin: float = Palette.SPACE_XL
	var shift: float = gutter if (bar != null and bar.visible) else 0.0
	_root.add_theme_constant_override("margin_left", int(margin + shift))
	_root.add_theme_constant_override("margin_right", int(margin))

	var available: float = size.x - margin * 2.0 - gutter
	_card.custom_minimum_size = Vector2(maxf(minf(CARD_MAX_WIDTH, available), 1.0), 0.0)


func _on_palette_changed(_tier: int) -> void:
	_style()
	# Font sizes changed, so the measured card width is stale even though the
	# screen did not resize.
	request_layout()


# ═════════════════════════════════════════════════════════════════════════
# PERSISTENCE
# ═════════════════════════════════════════════════════════════════════════
## The untouched privacy state. The ONLY thing this screen can write, and the
## single definition both the controller and its tests read — so "defaults to
## off" cannot drift between the code and the check that guards it.
static func consent_defaults() -> Dictionary:
	return {"personalized_ads": false, "analytics": false}


## Write acceptance and continue. On first run this is the ONLY path into the
## game, so the write must complete before navigating — flush(), not
## flush_soon(), because a kill here would otherwise re-prompt forever.
func _on_accept_pressed() -> void:
	if not _operational("_on_accept_pressed"):
		return
	AudioManager.play_sfx(&"ui_tap")
	commit_consent()

	if _revisit:
		await Router.back()
		return

	# Ask the boot resolver where a player goes now, rather than naming a
	# route here. Consent is recorded at this point, so resolve_destination()
	# cannot return "consent" again — it yields the intro on a first run and
	# the hub thereafter. Duplicating that rule in a second place is how the
	# old chain (consent → sponsor → loading → home) drifted out of sync with
	# the screens that actually existed.
	var destination: String = SplashController.resolve_destination()
	if not Log.must(destination != "consent", "Consent",
			"resolver still demands consent after acceptance"):
		return
	await Router.replace(destination)


## Public and side-effect-contained so a test can call it without a scene.
##
## Only a FIRST acceptance seeds the privacy defaults. A revisit deliberately
## leaves personalized_ads and analytics untouched: the player may have opted
## in from Settings since, and re-reading the terms must not silently revoke
## that choice.
func commit_consent() -> void:
	var first_time: bool = not is_recorded()

	Save.set_v(Save.SEC_CONSENT, "accepted", true)
	Save.set_v(Save.SEC_CONSENT, "policy_version", POLICY_VERSION)
	Save.set_v(Save.SEC_CONSENT, "accepted_unix",
		int(Time.get_unix_time_from_system()))

	if first_time:
		var defaults: Dictionary = consent_defaults()
		Save.set_v(Save.SEC_CONSENT, "personalized_ads",
			bool(defaults["personalized_ads"]))
		Save.set_v(Save.SEC_CONSENT, "analytics", bool(defaults["analytics"]))

	Save.flush()
	var ads: bool = personalized_ads_allowed()
	var analytics: bool = analytics_allowed()
	Bus.consent_changed.emit(ads, analytics)
	Log.info("Consent", "recorded: ads=%s analytics=%s v%d first=%s" % [
		str(ads), str(analytics), POLICY_VERSION, str(first_time)])


## Change one privacy choice from anywhere (Settings owns the UI for this).
##
## Lives here rather than in the Settings controller so there is exactly one
## writer for the consent section, and so the audit log line is identical no
## matter which screen triggered the change.
static func set_privacy_choice(key: String, allowed: bool) -> void:
	if not Log.must(consent_defaults().has(key), "Consent",
			"unknown privacy key '%s'" % key):
		return
	Save.set_v(Save.SEC_CONSENT, key, allowed)
	Save.flush()
	Bus.consent_changed.emit(personalized_ads_allowed(), analytics_allowed())
	Log.info("Consent", "privacy choice %s=%s" % [key, str(allowed)])


## True when the stored consent is present AND matches the current policy
## version. A material policy change re-prompts rather than assuming the old
## agreement still covers it.
static func is_satisfied() -> bool:
	# EDITOR/DEBUG BYPASS: never gate a developer behind the consent screen
	# when running from the editor. Release builds always gate.
	#
	# This is safe because OS.is_debug_build() is false in every exported
	# release template — the same derivation Cfg uses to guarantee a debug
	# build cannot serve live ads.
	if OS.is_debug_build():
		return true
	return is_recorded()


## The real stored state, ignoring the debug bypass.
##
## Kept separate so tests can verify genuine gating from a debug build, where
## is_satisfied() short-circuits. Without this the bypass would make the
## release path untestable — a bypass that hides its own logic is how a
## compliance gate quietly stops working.
static func is_recorded() -> bool:
	if not bool(Save.get_v(Save.SEC_CONSENT, "accepted", false)):
		return false
	return int(Save.get_v(Save.SEC_CONSENT, "policy_version", 0)) >= POLICY_VERSION


static func personalized_ads_allowed() -> bool:
	return bool(Save.get_v(Save.SEC_CONSENT, "personalized_ads", false))


static func analytics_allowed() -> bool:
	return bool(Save.get_v(Save.SEC_CONSENT, "analytics", false))


func _on_privacy_pressed() -> void:
	_open_link(PRIVACY_URL)


func _on_terms_pressed() -> void:
	_open_link(TERMS_URL)


func _open_link(url: String) -> void:
	AudioManager.play_sfx(&"ui_tap")
	OS.shell_open(url)


func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


## On first run there is nowhere to go back to — consent is mandatory, so back
## is swallowed. On a revisit it returns without changing anything.
func on_back_requested() -> bool:
	if _revisit:
		return false
	return true
