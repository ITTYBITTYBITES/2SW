extends Screen
class_name TrendHubController
## TrendHubController — vertical category cards for the Trend Witness mode.
##
## PHASE 2/3. One card per category, stacked vertically, styled to match the
## Wardrobe's item rows: name, status line, action button.
##
## ═══════════════════════════════════════════════════════════════════════════
## UNLOCKS ARE READ FROM THE RENTAL ENGINE, NEVER FROM A LOCAL COPY
## ═══════════════════════════════════════════════════════════════════════════
## Every card asks IrisState directly — is_rental_active(), then
## rental_days_remaining() / get_pack_expires_utc() for the badge. Nothing
## about unlock state is cached on this screen, because a cached copy is a
## second source of truth that goes stale the moment an ad completes or a pass
## expires mid-session.
##
## Rentals are PRUNED on entry, matching the Wardrobe. An expired pass must
## stop granting access the moment the player looks at it, not at next launch.

## The unlock call to action. One definition, so the button copy and the test
## that asserts it cannot drift.
const UNLOCK_LABEL: String = "WATCH AD TO UNLOCK (7 DAYS)"
## Shown when no ad is loaded and the category is NOT on cooldown. A distinct
## message from the countdown: "not ready" is a network state the player can
## wait out in seconds, a cooldown is a deliberate throttle with a known end.
## Collapsing them into one label would tell a player to wait five minutes for
## something that resolves in two seconds.
const NOT_READY_LABEL: String = "[ 📡 AD NOT READY ]"

## The three rails. Values are persisted in no way — a tab is a view, not
## player state, and restoring one would surprise a player who expects the
## default roster on open.
enum Tab { THIS_WEEK = 0, POPULAR = 1, ARCHIVE = 2 }

const TAB_LABELS: Array[String] = ["THIS WEEK", "POPULAR", "ARCHIVE"]

## How many entries the POPULAR rail shows.
const POPULAR_LIMIT: int = 10

@onready var _tab_row: HBoxContainer = %TabRow
## Needed again now that switching rails resets the scroll offset.
@onready var _scroll: ScrollContainer = %Scroll
@onready var _background: ColorRect = %Background
@onready var _root: MarginContainer = %Root
@onready var _title: Label = %TitleLabel
@onready var _subtitle: Label = %SubtitleLabel
@onready var _cards: VBoxContainer = %CardColumn
@onready var _back_button: Button = %BackButton

var _state: IrisState = null
var _wired: bool = false
## Category awaiting an ad reward, or "" when none is pending.
var _pending_unlock: String = ""
## Locked-category action buttons, so the cooldown tick can relabel them
## without rebuilding every card each second. Rebuilding would drop the
## player's scroll position once a second, which is unusable on a 20-card list.
var _cooldown_buttons: Array[Button] = []
## Locked-category buttons waiting on ad INVENTORY rather than a cooldown.
## Tracked separately because they clear on a signal, not on a timer.
var _availability_buttons: Array[Button] = []
## The rail currently on screen.
var _tab: Tab = Tab.THIS_WEEK
## Tab buttons, kept so the active one can be restyled without a rebuild.
var _tab_buttons: Array[Button] = []
## Whole seconds shown on the last tick. Used to skip redundant relabels.
var _last_cooldown_shown: int = -1


# ═════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════
func _setup() -> void:
	# This screen folds the safe area into its own MarginContainer;
	# the base class must not offset it a second time.
	handles_own_safe_area = true
	_state = _resolve_state()

	_wired = (
		Log.must(_cards != null, "TrendHub", "%CardColumn missing")
		and Log.must(_back_button != null, "TrendHub", "%BackButton missing")
		and Log.must(_state != null, "TrendHub", "state failed to resolve")
	)
	if not _wired:
		return

	# Housekeeping on entry, same as the Wardrobe: an expired pass must stop
	# granting access now, not at next launch.
	var pruned: int = _state.prune_expired_rentals()
	if pruned > 0:
		Save.set_v("iris", "state", _state.to_dict())
		Save.flush()
		Log.info("TrendHub", "pruned %d expired pass(es)" % pruned)

	_back_button.pressed.connect(_on_back_pressed)
	# Rule B: subscribe here, disconnect in _exit_tree.
	AdManager.ad_watched_successfully.connect(_on_ad_watched)
	AdManager.ad_dismissed_early.connect(_on_ad_dismissed)
	# Availability flips on a signal, not a clock, so the cards react rather
	# than polling. A player staring at "AD NOT READY" sees it clear the
	# instant the network delivers.
	AdManager.availability_changed.connect(_on_availability_changed)
	# A player who leaves the app open across Sunday midnight would otherwise
	# keep last week's roster until they relaunch. Resuming is the moment to
	# notice, so the hub re-checks then as well as on entry.
	Bus.app_resumed.connect(_on_app_resumed)

	# Nudge a preload on entry. If an earlier load failed, opening this screen
	# is a fresh explicit request and resets the backoff.
	if not AdManager.is_rewarded_ad_ready():
		AdManager.preload_rewarded_ad.call_deferred()

	# Catch a week that rolled over while the app sat open. Cheap: a string
	# compare against the stored week, and a no-op when nothing changed.
	_refresh_if_week_changed()

	_style()
	_build_tabs()
	_build()
	# One-second tick, driving only the countdown labels.
	set_process(true)


func _exit_tree() -> void:
	if AdManager.ad_watched_successfully.is_connected(_on_ad_watched):
		AdManager.ad_watched_successfully.disconnect(_on_ad_watched)
	if AdManager.ad_dismissed_early.is_connected(_on_ad_dismissed):
		AdManager.ad_dismissed_early.disconnect(_on_ad_dismissed)
	if AdManager.availability_changed.is_connected(_on_availability_changed):
		AdManager.availability_changed.disconnect(_on_availability_changed)
	if Bus.app_resumed.is_connected(_on_app_resumed):
		Bus.app_resumed.disconnect(_on_app_resumed)
	super()


func _resolve_state() -> IrisState:
	var incoming: Variant = payload.get("iris_state", null)
	if incoming is IrisState:
		return incoming as IrisState
	var state: IrisState = IrisState.new()
	var stored: Dictionary = Save.get_v("iris", "state", {})
	if not stored.is_empty():
		state.from_dict(stored)
	return state


func _operational(context: String) -> bool:
	if _wired and _state != null:
		return true
	Log.d("TrendHub", "not operational in %s" % context)
	return false


# ═════════════════════════════════════════════════════════════════════════
# COOLDOWN TICK
# ═════════════════════════════════════════════════════════════════════════
## Relabel locked buttons once per whole second.
##
## Only the LABELS update. A full _build() every second would rebuild twenty
## cards and reset the scroll position under the player's thumb, and rebuilding
## is also how a pressed-button connection gets torn out mid-tap.
##
## The moment the cooldown reaches zero the buttons are re-enabled in place,
## so a player watching the timer can act the instant it clears.
func _process(_delta: float) -> void:
	if not _wired:
		return
	if _cooldown_buttons.is_empty():
		return

	var remaining: int = AdManager.get_category_cooldown_remaining_sec()
	if remaining == _last_cooldown_shown:
		return
	_last_cooldown_shown = remaining

	if remaining <= 0:
		# Cooldown cleared. Restore the real action and stop tracking.
		for button: Button in _cooldown_buttons:
			if is_instance_valid(button):
				button.text = UNLOCK_LABEL
				button.disabled = AdManager.watches_remaining() <= 0
		_cooldown_buttons.clear()
		return

	var label: String = cooldown_label(remaining)
	for button: Button in _cooldown_buttons:
		if is_instance_valid(button):
			button.text = label


## An ad became available, or stopped being. Relabel only the buttons that
## were waiting on inventory — a full rebuild would reset scroll position on a
## 20-card list, and the cooldown buttons are not affected either way.
func _on_availability_changed(available: bool) -> void:
	if not _wired:
		return
	if _availability_buttons.is_empty():
		# Nothing was waiting. If ads just became available and cards are
		# showing a stale state, rebuild once to pick it up.
		if available:
			_build()
		return
	if not available:
		return
	for button: Button in _availability_buttons:
		if is_instance_valid(button):
			button.text = UNLOCK_LABEL
			button.disabled = false
	_availability_buttons.clear()


## The countdown button copy. Static and pure so the exact string is testable
## without a scene or a running clock.
static func cooldown_label(remaining_sec: int) -> String:
	return "[ ⏱ UNLOCK IN %s ]" % AdManager.format_cooldown(remaining_sec)


func _style() -> void:
	if not _operational("_style"):
		return
	_background.color = Palette.COLOR_BACKGROUND

	_root.add_theme_constant_override("margin_top", int(maxf(safe_top, Palette.SPACE_LG)))
	_root.add_theme_constant_override("margin_bottom",
		int(maxf(safe_bottom, Palette.SPACE_LG)))

	_title.text = "Trend Hub"
	_title.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	_title.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_TITLE))

	_subtitle.text = "Witness the pattern. Name what you saw."
	_subtitle.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	_subtitle.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))


func _on_palette_changed(_tier: int) -> void:
	_style()
	_style_tabs()
	_build()


# ═════════════════════════════════════════════════════════════════════════
# CARDS
# ═════════════════════════════════════════════════════════════════════════
## The rail selector. Built once; only the active styling changes on switch,
## so tapping a tab cannot tear out the button that is mid-press.
func _build_tabs() -> void:
	if not _operational("_build_tabs"):
		return
	for child: Node in _tab_row.get_children():
		child.queue_free()
	_tab_buttons.clear()

	for index: int in range(TAB_LABELS.size()):
		var tab: Tab = index as Tab
		var button: Button = Button.new()
		button.text = TAB_LABELS[index]
		button.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_SM)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override(
			"font_size", Palette.font(Palette.FONT_MICRO))
		button.pressed.connect(func() -> void: _on_tab_pressed(tab))
		_tab_row.add_child(button)
		_tab_buttons.append(button)

	_style_tabs()


## The active tab is filled; the others are outlined. Colour alone would be
## invisible to a colourblind player, so the active one is also the only tab
## that is disabled — it cannot be re-selected, which doubles as the state cue.
func _style_tabs() -> void:
	for index: int in range(_tab_buttons.size()):
		var button: Button = _tab_buttons[index]
		if not is_instance_valid(button):
			continue
		var active: bool = index == int(_tab)
		button.disabled = active
		button.add_theme_color_override("font_color",
			Palette.accent() if active else Palette.COLOR_TEXT_DIM)


## Re-check the calendar week and rebuild if it rolled over.
##
## THE CASE THIS COVERS: the splash runs the rotation check at launch, but a
## player who leaves the app open past Sunday midnight never re-launches. They
## would sit on a stale roster until they did — and, worse, the categories
## they unlocked would not be archived, so the pass they paid for would look
## like it had vanished when the roster finally did change.
##
## Deliberately does nothing when the week is unchanged, which is the
## overwhelmingly common case: one string comparison, no file access, no
## rebuild. Never called mid-run — the hub is not on screen during a trial, so
## this cannot disturb active gameplay.
func _refresh_if_week_changed() -> bool:
	var week_change: Dictionary = TrendLoader.check_week_rotation()
	if not bool(week_change.get("rotated", false)):
		return false

	Log.info("TrendHub", "week rolled over to %s while open; refreshing"
		% str(week_change.get("current_week", "")))
	# Re-read state from disk. The rotation archived the outgoing roster, and
	# a stale in-memory IrisState would overwrite that on the next save.
	_state = _resolve_state()
	return true


## App came back to the foreground. The most likely moment for the calendar to
## have moved without us noticing.
func _on_app_resumed(_away_seconds: int) -> void:
	if not _operational("_on_app_resumed"):
		return
	if _refresh_if_week_changed():
		_build()
		Bus.toast.emit("New weekly roster", "✦")


func _on_tab_pressed(tab: Tab) -> void:
	if tab == _tab:
		return
	AudioManager.play_sfx(&"ui_tap")
	_tab = tab
	_style_tabs()
	_build()
	# Return to the top: a player switching rails is starting a new scan, and
	# inheriting the previous rail's scroll offset lands them mid-list.
	if _scroll != null:
		_scroll.scroll_vertical = 0


## The rail currently shown. Read-only, for tests.
func current_tab() -> int:
	return int(_tab)


func _build() -> void:
	if not _operational("_build"):
		return
	# Stale handles point at nodes about to be freed; the tick checks
	# is_instance_valid() too, but clearing here keeps the list from growing
	# by twenty entries on every rebuild.
	_cooldown_buttons.clear()
	_availability_buttons.clear()
	_last_cooldown_shown = -1
	for child: Node in _cards.get_children():
		child.queue_free()

	match _tab:
		Tab.THIS_WEEK:
			for trend_id: String in TrendRegistry.all_ids():
				_cards.add_child(_build_card(trend_id))
		Tab.POPULAR:
			_build_popular()
		Tab.ARCHIVE:
			_build_archive()
		_:
			Log.must(false, "TrendHub", "unknown tab %d" % int(_tab))


## Top categories by editorial prior weighted with local play count.
##
## Only categories in the LIVE roster are shown. A popular entry the player
## cannot currently reach would be an advert for content that is not there.
func _build_popular() -> void:
	var ranked: Array[Dictionary] = TrendLoader.get_popular_categories(POPULAR_LIMIT)
	var shown: int = 0
	for entry: Dictionary in ranked:
		var id: String = str(entry.get("id", ""))
		if not TrendRegistry.has(id):
			continue
		_cards.add_child(_build_card(id, _popularity_note(entry)))
		shown += 1

	if shown == 0:
		_cards.add_child(_build_notice(
			"No rankings yet.", "Play a few runs and your favourites appear here."))


## A short line explaining WHY something ranked, so the rail is legible rather
## than a mysterious reordering of the same list.
func _popularity_note(entry: Dictionary) -> String:
	var plays: int = int(entry.get("plays", 0))
	if plays > 0:
		return "%d play%s  ·  rank score %d" % [
			plays, "" if plays == 1 else "s", int(entry.get("rank_score", 0))]
	if bool(entry.get("is_popular", false)):
		return "Popular with players"
	return "Rank score %d" % int(entry.get("rank_score", 0))


## Past weeks, and the categories the player still holds a pass for.
##
## Grouped by week rather than flattened, because "which week was this from"
## is the question the archive exists to answer.
func _build_archive() -> void:
	var weeks: Array[String] = TrendLoader.get_archived_weeks()
	if weeks.is_empty():
		_cards.add_child(_build_notice(
			"No past weeks yet.",
			"Rosters are archived when the week rolls over, so unlocks you "
			+ "have paid for stay reachable."))
		return

	var owned: Array[Dictionary] = TrendLoader.get_owned_archived_categories(_state)
	var by_week: Dictionary = {}
	for entry: Dictionary in owned:
		var week: String = str(entry.get("week", ""))
		if not by_week.has(week):
			by_week[week] = []
		(by_week[week] as Array).append(entry)

	for week: String in weeks:
		_cards.add_child(_build_week_header(week,
			(by_week.get(week, []) as Array).size()))
		for entry: Dictionary in (by_week.get(week, []) as Array):
			_cards.add_child(_build_archive_card(entry))

	if owned.is_empty():
		_cards.add_child(_build_notice(
			"Nothing still unlocked.",
			"Categories you unlock with an ad stay playable here for the "
			+ "full 7 days, even after the roster rotates."))


func _build_week_header(week: String, count: int) -> Control:
	var label: Label = Label.new()
	label.text = "%s  ·  %d still unlocked" % [week, count]
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Palette.accent())
	label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	return label


## An archived category the player still holds. Always playable — the pass is
## live, which is the only reason it is in this list at all.
func _build_archive_card(entry: Dictionary) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", Palette.panel_style(false))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", int(Palette.SPACE_XS))
	card.add_child(body)

	var trend_id: String = str(entry.get("id", ""))

	var name_label: Label = Label.new()
	name_label.text = str(entry.get("name", trend_id))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	name_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))
	body.add_child(name_label)

	var days: int = int(entry.get("days_remaining", 0))
	var status: Label = Label.new()
	status.text = "[ %d DAY%s LEFT ]" % [days, "" if days == 1 else "S"]
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_color_override("font_color", Palette.COLOR_WARNING)
	status.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	body.add_child(status)

	var action: Button = Button.new()
	action.text = "PLAY RUN"
	action.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_MD)
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	# Only launchable if the category is still in the live registry. An
	# archived pass for a category the build no longer knows how to run would
	# be a button that leads nowhere.
	if TrendRegistry.has(trend_id):
		action.pressed.connect(func() -> void: _on_play(trend_id))
	else:
		action.text = "NOT IN THIS BUILD"
		action.disabled = true
	body.add_child(action)

	return card


## An empty-state panel. An honest explanation beats a blank rail.
func _build_notice(title: String, detail: String) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", Palette.panel_style(false))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", int(Palette.SPACE_XS))
	card.add_child(body)

	var heading: Label = Label.new()
	heading.text = title
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	heading.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_BODY))
	body.add_child(heading)

	var caption: Label = Label.new()
	caption.text = detail
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	caption.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	body.add_child(caption)

	return card


func _build_card(trend_id: String, note: String = "") -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", Palette.panel_style(true))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", int(Palette.SPACE_XS))
	card.add_child(body)

	var name_label: Label = Label.new()
	name_label.text = TrendRegistry.display_name(trend_id)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_color_override("font_color", Palette.COLOR_TEXT)
	name_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_HEADING))
	body.add_child(name_label)

	var blurb: Label = Label.new()
	blurb.text = TrendRegistry.blurb(trend_id)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blurb.add_theme_color_override("font_color", Palette.COLOR_TEXT_FAINT)
	blurb.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	body.add_child(blurb)

	# Best score, always shown — including "—" for an unplayed category, so the
	# card's shape does not change once a score exists.
	var best: int = TrendRegistry.best_score(trend_id)
	var score_label: Label = Label.new()
	score_label.text = "Best  %s" % ("—" if best <= 0 else str(best))
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_label.add_theme_color_override("font_color", Palette.accent())
	score_label.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))
	body.add_child(score_label)

	if not note.is_empty():
		var note_label: Label = Label.new()
		note_label.text = note
		note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		note_label.add_theme_color_override("font_color", Palette.accent())
		note_label.add_theme_font_size_override(
			"font_size", Palette.font(Palette.FONT_MICRO))
		body.add_child(note_label)

	var status: Label = Label.new()
	status.text = status_text(_state, trend_id)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_color_override("font_color", _status_colour(trend_id))
	status.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_MICRO))
	body.add_child(status)

	var action: Button = Button.new()
	action.custom_minimum_size = Vector2(0.0, Palette.CONTROL_HEIGHT_LG)
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action.add_theme_font_size_override("font_size", Palette.font(Palette.FONT_SMALL))

	if TrendRegistry.is_unlocked(_state, trend_id):
		action.text = "PLAY RUN"
		action.pressed.connect(func() -> void: _on_play(trend_id))
	else:
		var remaining: int = AdManager.get_category_cooldown_remaining_sec()
		if remaining > 0:
			# On cooldown: show the wait, and disable. The button states the
			# reason rather than being inert with no explanation.
			action.text = cooldown_label(remaining)
			action.disabled = true
			_cooldown_buttons.append(action)
		elif not AdManager.is_rewarded_ad_ready():
			# Cooldown is clear but no ad is loaded. Checked SECOND so a
			# cooldown — the longer, more informative wait — always wins the
			# label when both apply.
			action.text = NOT_READY_LABEL
			action.disabled = true
			_availability_buttons.append(action)
		else:
			action.text = UNLOCK_LABEL
			action.disabled = false
		action.pressed.connect(func() -> void: _on_watch_ad(trend_id))
	body.add_child(action)

	return card


## The status line for a category. Static and pure so a test can assert the
## exact copy for each unlock state without building a scene.
static func status_text(state: IrisState, trend_id: String,
		now_unix: float = -1.0) -> String:
	if state == null:
		return ""
	if TrendRegistry.is_free(trend_id):
		return "Free  ·  always open"
	if TrendRegistry.is_unlocked(state, trend_id, now_unix):
		var days: int = TrendRegistry.days_remaining(state, trend_id, now_unix)
		return "[ %d DAY%s LEFT ]" % [days, "" if days == 1 else "S"]
	if state.get_pack_expires_utc(TrendRegistry.pack_id(trend_id)) > 0:
		return "Pass expired"
	return "Locked"


func _status_colour(trend_id: String) -> Color:
	if TrendRegistry.is_free(trend_id):
		return Palette.success()
	if TrendRegistry.is_unlocked(_state, trend_id):
		return Palette.COLOR_WARNING
	return Palette.COLOR_TEXT_FAINT


# ═════════════════════════════════════════════════════════════════════════
# ACTIONS
# ═════════════════════════════════════════════════════════════════════════
func _on_play(trend_id: String) -> void:
	if not _operational("_on_play"):
		return
	AudioManager.play_sfx(&"ui_tap")

	# Re-check at the moment of launch. The card was rendered earlier and a
	# pass can expire while the screen is open; trusting the button's own
	# state would let a lapsed pass through.
	if not TrendRegistry.is_unlocked(_state, trend_id):
		Log.info("TrendHub", "play refused: '%s' is locked" % trend_id)
		Bus.toast.emit("That channel has expired", "✧")
		_build()
		return

	await Router.go("trial", {
		"trial_id": "trend_witness",
		"iris_state": _state,
		"trend_id": trend_id,
	})


## Request a rewarded ad for a 7-day pass.
##
## The pass is granted on the REWARD CALLBACK, never here — crediting on the
## request would hand out a week's access for opening an ad and dismissing it.
func _on_watch_ad(trend_id: String) -> void:
	if not _operational("_on_watch_ad"):
		return
	AudioManager.play_sfx(&"ui_tap")

	if TrendRegistry.is_free(trend_id):
		Log.warn("TrendHub", "ad requested for the free category")
		return

	# Re-check at the moment of the tap. The button was labelled when the card
	# was built and a cooldown can start while this screen is open — from a
	# rescue ad in a run the player just left, for instance.
	if not AdManager.can_unlock_category():
		var wait: int = AdManager.get_category_cooldown_remaining_sec()
		Log.info("TrendHub", "unlock refused; %ds of cooldown left" % wait)
		Bus.toast.emit("Next unlock in %s" % AdManager.format_cooldown(wait), "✧")
		_build()
		return

	if not AdManager.is_rewarded_ad_ready():
		Log.info("TrendHub", "unlock refused; no ad loaded")
		Bus.toast.emit("Ad not ready — try again shortly", "✧")
		AdManager.preload_rewarded_ad()
		_build()
		return

	if not AdManager.show_rewarded("trend_" + trend_id):
		Bus.toast.emit("No ad available right now", "✧")
		return

	_pending_unlock = trend_id


func _on_ad_watched(placement: String) -> void:
	if not _operational("_on_ad_watched"):
		return
	# Only credit the category this screen actually requested. Without the
	# placement check, an ad watched for a cosmetic elsewhere would unlock a
	# trend channel too.
	if _pending_unlock == "" or placement != "trend_" + _pending_unlock:
		return

	var trend_id: String = _pending_unlock
	_pending_unlock = ""

	_state.grant_rental(TrendRegistry.pack_id(trend_id))
	Save.set_v("iris", "state", _state.to_dict())
	Save.flush()

	var days: int = TrendRegistry.days_remaining(_state, trend_id)
	HapticsManager.pattern(&"streak_celebrate")
	Bus.toast.emit("%s unlocked · %d days" % [
		TrendRegistry.display_name(trend_id), days], "✦")
	Log.info("TrendHub", "granted 7-day pass for '%s' (expires %d)" % [
		trend_id, TrendRegistry.expires_utc(_state, trend_id)])
	_build()


func _on_ad_dismissed(_placement: String) -> void:
	# Dropped without a reward. Clear the pending request so a LATER ad,
	# watched for something else entirely, cannot land on this category.
	if _pending_unlock != "":
		Log.info("TrendHub", "ad dismissed; '%s' stays locked" % _pending_unlock)
		_pending_unlock = ""
		_build()


func _on_back_pressed() -> void:
	AudioManager.play_sfx(&"ui_tap")
	await Router.back()


func on_back_requested() -> bool:
	return false
