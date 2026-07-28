extends SceneTree
## Layout regression: every screen must fit inside the viewport at any aspect.
##
## THE BUG THIS CATCHES:
## The splash was authored with fixed pixel offsets against a 1080x1920 design.
## On a landscape editor window (stretch aspect "expand" makes the viewport
## short and wide) the content ran off the bottom edge and the marks appeared
## clipped at the screen edge. Fixed offsets look correct at the design size
## and only fail elsewhere, so nothing caught it until a screenshot did.

const VIEWPORTS: Array[Vector2i] = [
	Vector2i(1080, 1920),   # design target, portrait phone
	Vector2i(1440, 3200),   # tall modern phone
	Vector2i(1920, 1080),   # landscape desktop / editor window
	Vector2i(1280, 720),    # small landscape
	Vector2i(800, 600),     # worst case: short and squarish
	Vector2i(2048, 1536),   # tablet
]

const SCREENS: Array[String] = [
	"res://screens/splash/splash.tscn",
	"res://screens/consent/consent.tscn",
	"res://screens/hub_portal.tscn",
	"res://screens/daily_hub.tscn",
	"res://screens/wardrobe.tscn",
	"res://screens/progress_view.tscn",
	"res://screens/settings_view.tscn",
	"res://screens/trial_host.tscn",
	"res://screens/trial_results.tscn",
	"res://screens/chrono_pulse/result_card.tscn",
	"res://screens/trend_hub.tscn",
]

var _fails: Array[String] = []
var _n: int = 0


func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	if not cond:
		_fails.append(label)
		print("  FAIL  %s  [%s]" % [label, detail])


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ LAYOUT ACROSS VIEWPORTS ═══\n")
	for viewport: Vector2i in VIEWPORTS:
		root.content_scale_size = viewport
		root.size = viewport
		await process_frame
		var clean: int = 0
		for path: String in SCREENS:
			if not ResourceLoader.exists(path):
				continue
			var screen: Control = (load(path) as PackedScene).instantiate()
			root.add_child(screen)
			await process_frame
			await process_frame

			var overflow: Array[String] = []
			_scan(screen, viewport, overflow)
			_ok("%s at %dx%d" % [path.get_file(), viewport.x, viewport.y],
				overflow.is_empty(), ", ".join(overflow))
			if overflow.is_empty():
				clean += 1
			screen.free()
		print("  %dx%d — %d/%d screens fit" % [viewport.x, viewport.y, clean, SCREENS.size()])

	print("\n── the consent card fits WITHOUT scrolling ──")
	# The generic scan deliberately ignores anything inside a ScrollContainer,
	# because overflowing is what scrolling is for. That makes it blind to the
	# exact bug reported: the Agree button sitting below the fold. The scroll
	# view is a safety net for absurd viewports, not the intended experience,
	# so assert the card and its primary action are ON SCREEN unaided.
	for viewport: Vector2i in VIEWPORTS:
		root.content_scale_size = viewport
		root.size = viewport
		await process_frame
		var consent: Control = (load("res://screens/consent/consent.tscn") as PackedScene).instantiate()
		root.add_child(consent)
		await process_frame
		await process_frame

		var card: Control = consent.get_node_or_null("%Card") as Control
		var accept: Control = consent.get_node_or_null("%AcceptButton") as Control
		if card == null or accept == null:
			_ok("consent card present at %dx%d" % [viewport.x, viewport.y], false)
			consent.free()
			continue

		var card_rect: Rect2 = card.get_global_rect()
		var accept_rect: Rect2 = accept.get_global_rect()

		_ok("card fits vertically at %dx%d" % [viewport.x, viewport.y],
			card_rect.position.y >= -1.0
			and card_rect.position.y + card_rect.size.y <= float(viewport.y) + 1.0,
			"card y %.0f..%.0f vs %d" % [card_rect.position.y,
				card_rect.position.y + card_rect.size.y, viewport.y])

		_ok("card fits horizontally at %dx%d" % [viewport.x, viewport.y],
			card_rect.position.x >= -1.0
			and card_rect.position.x + card_rect.size.x <= float(viewport.x) + 1.0,
			"card x %.0f..%.0f vs %d" % [card_rect.position.x,
				card_rect.position.x + card_rect.size.x, viewport.x])

		# The reported bug, stated directly: the button was unreachable.
		_ok("Agree button fully on screen at %dx%d" % [viewport.x, viewport.y],
			accept_rect.position.y >= 0.0
			and accept_rect.position.y + accept_rect.size.y <= float(viewport.y),
			"button y %.0f..%.0f vs %d" % [accept_rect.position.y,
				accept_rect.position.y + accept_rect.size.y, viewport.y])

		_ok("Agree button is tappable at %dx%d" % [viewport.x, viewport.y],
			accept_rect.size.y >= 48.0 and accept_rect.size.x >= 88.0,
			str(accept_rect.size))

		# Centred horizontally, within a pixel of the viewport midline.
		var card_centre: float = card_rect.position.x + card_rect.size.x * 0.5
		_ok("card centred at %dx%d" % [viewport.x, viewport.y],
			absf(card_centre - float(viewport.x) * 0.5) < 2.0,
			"centre %.0f vs %.0f" % [card_centre, float(viewport.x) * 0.5])

		consent.free()
		await process_frame

	print("\n── the chrono result card fits WITHOUT scrolling ──")
	# Same reasoning as the consent card: the generic scan ignores content
	# inside a ScrollContainer, so it cannot see a share button below the fold.
	for viewport: Vector2i in VIEWPORTS:
		root.content_scale_size = viewport
		root.size = viewport
		await process_frame
		var card_screen: Control = (load("res://screens/chrono_pulse/result_card.tscn") as PackedScene).instantiate()
		root.add_child(card_screen)
		await process_frame
		await process_frame

		var card: Control = card_screen.get_node_or_null("%Card") as Control
		var share: Control = card_screen.get_node_or_null("%ShareButton") as Control
		var bars: Control = card_screen.get_node_or_null("%PulseBars") as Control
		if card == null or share == null or bars == null:
			_ok("chrono card present at %dx%d" % [viewport.x, viewport.y], false)
			card_screen.free()
			continue

		var card_rect: Rect2 = card.get_global_rect()
		var share_rect: Rect2 = share.get_global_rect()

		_ok("chrono card fits at %dx%d" % [viewport.x, viewport.y],
			card_rect.position.y >= -1.0
			and card_rect.position.y + card_rect.size.y <= float(viewport.y) + 1.0,
			"y %.0f..%.0f vs %d" % [card_rect.position.y,
				card_rect.position.y + card_rect.size.y, viewport.y])

		_ok("chrono share button on screen at %dx%d" % [viewport.x, viewport.y],
			share_rect.position.y >= 0.0
			and share_rect.position.y + share_rect.size.y <= float(viewport.y),
			"y %.0f..%.0f" % [share_rect.position.y,
				share_rect.position.y + share_rect.size.y])

		_ok("chrono card centred at %dx%d" % [viewport.x, viewport.y],
			absf((card_rect.position.x + card_rect.size.x * 0.5)
				- float(viewport.x) * 0.5) < 2.0)

		# The bars must have real area, or the score is invisible.
		_ok("pulse bars have drawable area at %dx%d" % [viewport.x, viewport.y],
			bars.size.x > 40.0 and bars.size.y > 10.0, str(bars.size))

		card_screen.free()
		await process_frame

	print("\n── trend hub cards are usable at every viewport ──")
	for viewport: Vector2i in VIEWPORTS:
		root.content_scale_size = viewport
		root.size = viewport
		await process_frame
		var hub: Control = (load("res://screens/trend_hub.tscn") as PackedScene).instantiate()
		root.add_child(hub)
		await process_frame
		await process_frame

		var column: Control = hub.get_node_or_null("%CardColumn") as Control
		var back: Control = hub.get_node_or_null("%BackButton") as Control
		if column == null or back == null:
			_ok("trend hub wired at %dx%d" % [viewport.x, viewport.y], false)
			hub.free()
			continue

		# Count read from the registry, not hardcoded — the weekly roster
		# changes and a literal here reports as a failure of the roster.
		var registry: GDScript = load("res://data/trend_registry.gd") as GDScript
		var expected: int = (registry.call("all_ids") as Array).size()
		_ok("trend hub renders every card at %dx%d" % [viewport.x, viewport.y],
			column.get_child_count() == expected,
			"%d of %d" % [column.get_child_count(), expected])
		_ok("trend cards have width at %dx%d" % [viewport.x, viewport.y],
			column.size.x > 100.0, str(column.size))
		# Back sits outside the scroll view, so it must always be on screen.
		var back_rect: Rect2 = back.get_global_rect()
		_ok("trend back button on screen at %dx%d" % [viewport.x, viewport.y],
			back_rect.position.y >= 0.0
			and back_rect.position.y + back_rect.size.y <= float(viewport.y) + 1.0,
			"y %.0f..%.0f" % [back_rect.position.y,
				back_rect.position.y + back_rect.size.y])
		# Every action button must be tappable, not squeezed to a sliver.
		var small: Array[String] = []
		_scan_buttons(column, small)
		_ok("trend action buttons are tappable at %dx%d" % [viewport.x, viewport.y],
			small.is_empty(), ", ".join(small))

		# The rail selector must fit and stay hittable. Three tabs sharing one
		# row is the control most at risk of being squeezed on a narrow phone.
		var tabs: Control = hub.get_node_or_null("%TabRow") as Control
		_ok("tab row present at %dx%d" % [viewport.x, viewport.y], tabs != null)
		if tabs == null:
			hub.free()
			await process_frame
			continue

		var tab_rect: Rect2 = tabs.get_global_rect()
		_ok("tab row is on screen at %dx%d" % [viewport.x, viewport.y],
			tab_rect.position.y >= -1.0
			and tab_rect.position.y + tab_rect.size.y <= float(viewport.y) + 1.0,
			"y %.0f..%.0f" % [tab_rect.position.y,
				tab_rect.position.y + tab_rect.size.y])
		var thin: Array[String] = []
		_scan_buttons(tabs, thin)
		_ok("tabs are tappable at %dx%d" % [viewport.x, viewport.y],
			thin.is_empty(), ", ".join(thin))

		# Each rail must render without overflowing. Switching is where a
		# layout breaks: a rail built for one aspect can push content off the
		# edge in another.
		for rail: int in [1, 2, 0]:
			hub.call("_on_tab_pressed", rail)
			await process_frame
			await process_frame
			var overflowed: Array[String] = []
			_scan(column, viewport, overflowed, true)
			_ok("rail %d fits at %dx%d" % [rail, viewport.x, viewport.y],
				overflowed.is_empty(), ", ".join(overflowed))

		hub.free()
		await process_frame

	print("\n── procedural marks centre in their own rect ──")
	root.content_scale_size = Vector2i(1080, 1920)
	root.size = Vector2i(1080, 1920)
	await process_frame
	var splash: Control = (load("res://screens/splash/splash.tscn") as PackedScene).instantiate()
	root.add_child(splash)
	await process_frame
	await process_frame
	for mark_name: String in ["SponsorMark", "Monogram", "IrisProgress"]:
		var mark: Control = splash.get_node_or_null("%" + mark_name) as Control
		_ok("%s exists" % mark_name, mark != null)
		if mark == null:
			continue
		_ok("%s has non-zero size" % mark_name,
			mark.size.x > 1.0 and mark.size.y > 1.0, str(mark.size))
		# Horizontally centred within the parent container.
		var rect: Rect2 = mark.get_global_rect()
		var centre_x: float = rect.position.x + rect.size.x * 0.5
		_ok("%s horizontally centred" % mark_name,
			absf(centre_x - 540.0) < 2.0, "centre_x=%.0f" % centre_x)
	splash.free()

	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d LAYOUT CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED" % [_fails.size(), _n])
	quit(1)


## Flag any button too small to hit reliably. 44pt is the platform minimum
## touch target on both iOS and Android.
func _scan_buttons(node: Node, small: Array[String]) -> void:
	if node is Button:
		var button: Button = node as Button
		if button.size.y < 44.0 or button.size.x < 44.0:
			small.append("%s%s" % [button.name, str(button.size)])
	for child: Node in node.get_children():
		_scan_buttons(child, small)


func _scan(node: Node, viewport: Vector2i, overflow: Array[String],
		inside_scroll: bool = false) -> void:
	for child: Node in node.get_children():
		if child is Control:
			var control: Control = child as Control
			# Content INSIDE a ScrollContainer is meant to exceed the view —
			# that is the entire point of scrolling. Only the container itself
			# has to fit.
			var scrolling: bool = inside_scroll or node is ScrollContainer
			# The hero housing is DECORATIVE BLEED. Its art extends past the
			# eyeball by design — the carved frame and gems orbit outside the
			# aperture, and on a screen where the eye is large that reaches
			# past the viewport edge. Cropping it would defeat the purpose;
			# what matters is that no INTERACTIVE or TEXT element leaves the
			# frame, which every other node here is still checked for.
			var decorative: bool = control.name == "HeroHousing"
			if not control.name.begins_with("@") and not scrolling and not decorative:
				var rect: Rect2 = control.get_global_rect()
				if rect.position.y < -1.0 or (rect.position.y + rect.size.y) > float(viewport.y) + 1.0:
					overflow.append("%s(y %.0f..%.0f)" % [
						control.name, rect.position.y, rect.position.y + rect.size.y])
			_scan(child, viewport, overflow, inside_scroll or node is ScrollContainer)
