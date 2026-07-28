extends Node
## Cfg — build configuration and secrets.
##
## v1 hardcoded live AdMob publisher ids as `const` in AdSystem.gd, plus a
## `const USE_TEST_ADS := true` that a human had to remember to flip before
## release (it was literally item #8 on a checklist). That put revenue and
## account safety on a sticky note.
##
## Here:
##   - Real ids live ONLY in build_config.cfg, which is gitignored and
##     injected by CI. The public repo never contains them.
##   - A debug build CANNOT serve live ads. Not a setting, not a choice.
##     use_test_ads is derived, and there is no setter.

const CONFIG_PATH := "res://build_config.cfg"

var use_test_ads: bool = true
var admob_app_id: String = ""
var admob_banner_id: String = ""
var admob_rewarded_id: String = ""

## iOS units, separate because AdMob issues a distinct app id per platform.
## v1 was Android-only, so these are empty until an iOS AdMob app exists.
var ios_app_id: String = ""
var ios_banner_id: String = ""
var ios_rewarded_id: String = ""

## True when we have everything needed to actually serve live ads.
var ads_configured: bool = false

# Google's official, publicly-documented test units. Safe to hardcode:
# they always fill, never earn, and never trigger policy strikes.
const TEST_APP_ID      := "ca-app-pub-3940256099942544~3347511713"
const TEST_BANNER_ID   := "ca-app-pub-3940256099942544/6300978111"
const TEST_REWARDED_ID := "ca-app-pub-3940256099942544/5224354917"


func _ready() -> void:
	# Derived, never assigned from config. A debug build always uses test ads.
	use_test_ads = OS.is_debug_build()

	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		admob_app_id      = str(cfg.get_value("admob", "app_id", ""))
		admob_banner_id   = str(cfg.get_value("admob", "banner_id", ""))
		admob_rewarded_id = str(cfg.get_value("admob", "rewarded_id", ""))
		ios_app_id        = str(cfg.get_value("admob", "ios_app_id", ""))
		ios_banner_id     = str(cfg.get_value("admob", "ios_banner_id", ""))
		ios_rewarded_id   = str(cfg.get_value("admob", "ios_rewarded_id", ""))
		if bool(cfg.get_value("build", "force_test_ads", false)):
			use_test_ads = true
	else:
		# Absent in a fresh clone. Expected — fall back to test ads.
		use_test_ads = true
		Log.info("Cfg", "no build_config.cfg; using test ads")

	ads_configured = not use_test_ads \
		and admob_banner_id != "" \
		and admob_rewarded_id != ""

	Log.info("Cfg", "test_ads=%s configured=%s" % [str(use_test_ads), str(ads_configured)])


## Ad unit accessors. Each falls back to Google's test unit when running in
## test mode OR when the production id is absent — serving a malformed request
## is worse than serving a test ad, and an empty id is a guaranteed no-fill.
func banner_id() -> String:
	var production: String = ios_banner_id if _is_ios() else admob_banner_id
	return TEST_BANNER_ID if (use_test_ads or production == "") else production


func rewarded_id() -> String:
	var production: String = ios_rewarded_id if _is_ios() else admob_rewarded_id
	return TEST_REWARDED_ID if (use_test_ads or production == "") else production


func app_id() -> String:
	var production: String = ios_app_id if _is_ios() else admob_app_id
	return TEST_APP_ID if (use_test_ads or production == "") else production


func _is_ios() -> bool:
	return OS.get_name() == "iOS"


## True when the ACTIVE platform has real ids configured. iOS reports false
## until an AdMob iOS app exists, so the caller can degrade rather than fail.
func platform_ads_configured() -> bool:
	if use_test_ads:
		return false
	if _is_ios():
		return ios_rewarded_id != ""
	return admob_rewarded_id != ""
