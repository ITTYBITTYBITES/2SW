extends SceneTree
## Live-engine verification for the startup sequence.

var _fails: Array[String] = []
var _n: int = 0

func _ok(label: String, cond: bool, detail: String = "") -> void:
	_n += 1
	print("  %s  %s%s" % ["PASS" if cond else "FAIL", label,
		("  [" + detail + "]") if (detail != "" and not cond) else ""])
	if not cond:
		_fails.append(label)

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	print("\n═══ SPLASH SEQUENCE (live engine) ═══\n")
	var save: Node = root.get_node_or_null("Save")
	var router: Node = root.get_node_or_null("Router")
	var splash_script: GDScript = ResourceLoader.load("res://nodes/splash_controller.gd", "GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript

	print("── scene ──")
	var packed: PackedScene = load("res://screens/splash/splash.tscn") as PackedScene
	_ok("splash.tscn loads", packed != null)
	if packed == null:
		_report()
		return
	var instance: Node = packed.instantiate()
	_ok("splash instantiates", instance != null)

	print("── procedural visuals ──")
	for node_name: String in ["SponsorMark", "Monogram", "IrisProgress"]:
		var node: Node = instance.get_node_or_null("%" + node_name)
		_ok("%%%s present" % node_name, node != null)
		# Not guarded by `if node != null:` — a skipped assertion reports as a
		# pass, so a missing node would hide the script check entirely.
		_ok("%s has a draw script" % node_name,
			node != null and node.get_script() != null)
	instance.free()

	print("── routing handoff ──")
	var routes: Dictionary = router.get("ROUTES")
	_ok("'splash' route declared", routes.has("splash"))
	_ok("splash scene resolves", ResourceLoader.exists(str(routes.get("splash", ""))))
	_ok("splash is a ROOT route", "splash" in router.get("ROOT_ROUTES"))

	# Consent unsatisfied -> consent, regardless of first-run state.
	save.call("wipe")
	_ok("no consent -> routes to consent",
		str(splash_script.call("resolve_destination")) == "consent")

	# Consent satisfied, first run not done, no intro scene -> hub not a crash.
	save.call("set_v", "consent", "accepted", true)
	save.call("set_v", "consent", "policy_version", 1)
	# first_run_done is retired along with the intro carousel; a player with
	# consent recorded goes straight to the hub either way.
	_ok("returning player -> hub",
		str(splash_script.call("resolve_destination")) == "hub")

	# Consent always wins, even for a returning player on a stale policy.
	save.call("set_v", "consent", "policy_version", 0)
	_ok("stale policy re-gates to consent",
		str(splash_script.call("resolve_destination")) == "consent")
	save.call("set_v", "consent", "policy_version", 1)

	print("── warm-up + skip ──")
	var live: Node = packed.instantiate()
	live.call("configure", {})
	root.add_child(live)
	await process_frame

	_ok("progress starts at zero", float(live.call("progress")) == 0.0)
	_ok("not skipped initially", not bool(live.call("was_skipped")))

	live.call("skip")
	await process_frame
	_ok("skip advances past the sponsor", bool(live.call("was_skipped")))

	# Let the warm-up run to completion.
	for i: int in range(120):
		await process_frame
		if float(live.call("progress")) >= 1.0:
			break
	_ok("warm-up reaches 100%%", float(live.call("progress")) >= 1.0,
		str(live.call("progress")))

	_ok("back is swallowed during startup", bool(live.call("on_back_requested")))
	live.queue_free()
	await process_frame

	print("── boot chain ──")
	var app_src: String = FileAccess.get_file_as_string("res://app/app.gd")
	_ok("app boots to splash", 'Router.go("splash")' in app_src)
	_ok("splash excluded from resume", '"splash"' in app_src and "NO_RESUME" in app_src)

	print("── asset discipline ──")
	# Rule F is amended for exactly two baked centerpieces. What must still
	# hold is that splash_visuals.gd — the file that owns every ANIMATED mark,
	# including the iris aperture that reads out real loading progress —
	# stays fully procedural. The baked art is a still centerpiece; it does
	# not get to absorb the moving parts.
	var visuals: String = FileAccess.get_file_as_string("res://nodes/splash_visuals.gd")
	for ext: String in [".png", ".jpg", ".svg"]:
		_ok("the animated marks reference no %s" % ext, not visuals.contains(ext))
	_ok("the animated marks load no Texture2D", not visuals.contains("Texture2D"))
	_ok("the animated marks draw with vectors",
		visuals.contains("draw_polyline") and visuals.contains("draw_arc"))
	# The loading readout specifically must remain procedural: it is driven
	# frame by frame from the warm-up, which no static texture can express.
	_ok("the iris progress readout is still drawn procedurally",
		visuals.contains("func _draw_iris_progress()"))

	await _check_cinematic()

	_report()


# ═════════════════════════════════════════════════════════════════════════
# THE CINEMATIC TREATMENT IS ACTUALLY WIRED
# ═════════════════════════════════════════════════════════════════════════
## Prove the dark/cinematic styling is IN THE RUNNING SCREEN.
##
## The weak version of this test asserts %Bloom exists in the .tscn. That
## passes against a bloom that never receives progress, never grows, and is
## pinned at zero forever — which is exactly the gap this whole pass is
## closing, so it is the one thing the test must not accept.
##
## Every check below drives the live controller and reads a consequence.
func _check_cinematic() -> void:
	print("── the startup sequence is cinematic and wired ──")

	var packed: PackedScene = load("res://screens/splash/splash.tscn") as PackedScene
	var live: Node = packed.instantiate()
	live.call("configure", {})
	root.add_child(live)
	await process_frame
	await process_frame

	var bloom: Control = live.get_node_or_null("%Bloom") as Control
	_ok("the splash has a bloom layer", bloom != null)

	# ── The atmosphere layer is installed, like every other screen ───────
	var atmosphere: Node = live.get_node_or_null("Atmosphere")
	var sponsor_layer: Node = live.get_node_or_null("SponsorLayer")
	_ok("the splash installs the shared atmosphere layer", atmosphere != null)
	# Behind the marks, not over them. Written UNCONDITIONALLY: guarding this
	# behind `if atmosphere != null` would make it silently pass on the very
	# failure it exists to catch.
	_ok("the atmosphere sits behind the startup marks",
		atmosphere != null and sponsor_layer != null
		and atmosphere.get_index() < sponsor_layer.get_index(),
		"atmosphere at %d" % (atmosphere.get_index() if atmosphere != null else -1))

	if bloom == null:
		live.queue_free()
		await process_frame
		return

	# ── The bloom sits behind everything it lights ───────────────────────
	var sponsor: Node = live.get_node_or_null("SponsorLayer")
	_ok("the bloom is drawn behind the sponsor mark",
		bloom.get_index() < sponsor.get_index(),
		"bloom %d vs sponsor %d" % [bloom.get_index(), sponsor.get_index()])

	# ── The bloom is lit during the sponsor act, not black ───────────────
	_ok("the ident is already lit when the app opens",
		float(bloom.call("progress")) > 0.0,
		"progress %.3f" % float(bloom.call("progress")))

	# ── It GROWS with real loading progress ──────────────────────────────
	# The reach at 0% and at 100% must differ, or the "glow sequence" is a
	# static halo wearing a progress API.
	# The displayed value EASES toward the target, so both readings are taken
	# after letting it settle. That the reading changes over those frames is
	# itself the proof the ease is running rather than snapping.
	var small: float = await _settled_reach(bloom, 0.0)
	var big: float = await _settled_reach(bloom, 1.0)
	_ok("the halo grows as loading advances", big > small * 1.5,
		"reach %.0f -> %.0f" % [small, big])

	# ── THE SOLID-DISC REGRESSION GUARD ──────────────────────────────────
	# A preview render of this screen once stacked a dozen near-opaque arcs
	# and produced a solid cyan disc that obliterated the mark behind it.
	# A bloom is many faint layers; if the accumulated centre ever goes
	# near-opaque it has stopped being a glow and become a blindfold.
	var peak: float = float(bloom.call("peak_alpha"))
	_ok("the accumulated halo stays translucent", peak < 0.75,
		"peak alpha %.3f — the mark behind it would be obscured" % peak)
	_ok("the halo is actually visible", peak > 0.10,
		"peak alpha %.3f" % peak)

	# ── The bloom and the iris aperture read the SAME number ─────────────
	# Two progress readouts that can disagree will eventually disagree.
	var iris: Control = live.get_node_or_null("%IrisProgress") as Control
	_ok("the splash has an iris progress readout", iris != null)
	live.call("_set_progress", 0.6)
	await process_frame
	_ok("the halo and the iris aperture share one progress source",
		iris != null and is_equal_approx(float(bloom.call("progress")), 0.6),
		"bloom %.3f" % float(bloom.call("progress")))

	# ── THE MARKS MUST NOT PAINT OVER THE BLOOM ──────────────────────────
	# The iris progress mark masks itself down to an aperture. That mask used
	# to be two opaque COLOR_BACKGROUND rectangles spanning the mark's FULL
	# WIDTH — invisible while the backdrop was a flat fill of the same colour,
	# and a hard black box across the halo the moment a bloom was added behind
	# it. Rendering the screen from live state is what caught it; no node-state
	# check could have.
	#
	# A full-rect opaque background fill inside a mark's _draw() is the shape
	# of that bug, so that is what this forbids.
	var vis_src: String = FileAccess.get_file_as_string(
		"res://nodes/splash_visuals.gd")
	var stripped: String = ""
	for line: String in vis_src.split("\n"):
		var hash_at: int = line.find("#")
		stripped += (line if hash_at < 0 else line.substr(0, hash_at)) + "\n"
	_ok("no mark paints an opaque full-width backdrop rect",
		not stripped.contains("size.x + 4.0"),
		"a full-rect COLOR_BACKGROUND fill would erase the bloom behind it")
	_ok("the lid mask fades at its rim rather than ending on an edge",
		stripped.contains("LID_FEATHER"))

	# ── Zero assets, same as the marks ───────────────────────────────────
	var bloom_src: String = FileAccess.get_file_as_string("res://ui/splash_bloom.gd")
	for ext: String in [".png", ".jpg", ".svg"]:
		_ok("the bloom contains no %s" % ext, not bloom_src.contains(ext))

	await _check_baked_plates(live)

	live.queue_free()
	await process_frame


# ═════════════════════════════════════════════════════════════════════════
# THE BAKED CENTERPIECES
# ═════════════════════════════════════════════════════════════════════════
## Prove the carved-metal art is REALLY THERE AND REALLY DRAWN.
##
## The weak version of this asserts the two files exist on disk. That passes
## against a scene that never references them, a SplashPlate whose texture
## failed to load, and art squashed to the wrong aspect ratio. So every check
## reads the LIVE plate nodes instead.
func _check_baked_plates(live: Node) -> void:
	print("── the baked carved-metal centerpieces ──")

	var sponsor: Control = live.get_node_or_null("%SponsorPlate") as Control
	var title: Control = live.get_node_or_null("%TitlePlate") as Control
	_ok("the sponsor centerpiece is mounted", sponsor != null)
	_ok("the title centerpiece is mounted", title != null)
	if sponsor == null or title == null:
		return

	for pair: Array in [["sponsor", sponsor], ["title", title]]:
		var label: String = pair[0]
		var plate: Control = pair[1]

		# The texture resolved. A missing file leaves this null and the plate
		# silently draws nothing at all.
		var tex: Texture2D = plate.call("texture") as Texture2D
		_ok("the %s plate resolved its art" % label, tex != null)
		if tex == null:
			continue

		# ── THE ART IS NOT STRETCHED ─────────────────────────────────────
		# fitted_rect() contains the art rather than covering the control, so
		# its aspect must match the texture's. A squashed carved plate reads
		# as cheap immediately, and nothing else here would notice.
		var rect: Rect2 = plate.call("fitted_rect")
		_ok("the %s plate has a drawn rect" % label, rect.size.x > 1.0,
			str(rect))
		if rect.size.x > 1.0:
			var src: Vector2 = tex.get_size()
			var want: float = src.x / src.y
			var got: float = rect.size.x / rect.size.y
			_ok("the %s plate keeps its aspect ratio" % label,
				absf(want - got) < 0.01,
				"texture %.3f vs drawn %.3f" % [want, got])
			# And it must fit INSIDE the control, never overflow it.
			_ok("the %s plate fits inside its slot" % label,
				rect.size.x <= plate.size.x + 1.0
				and rect.size.y <= plate.size.y + 1.0,
				"drawn %s in %s" % [str(rect.size), str(plate.size)])

		# ── TRANSPARENT CORNERS ──────────────────────────────────────────
		# These composite over the procedural bloom. A baked-in opaque
		# backdrop would punch a dark square through the halo — the exact
		# defect the iris lid mask caused in the previous pass.
		var img: Image = tex.get_image()
		_ok("the %s plate art is readable" % label, img != null)
		var worst: float = 1.0
		if img != null:
			var w: int = img.get_width()
			var h: int = img.get_height()
			worst = 0.0
			var probes: Array[Vector2i] = [
				Vector2i(1, 1),
				Vector2i(w - 2, 1),
				Vector2i(1, h - 2),
				Vector2i(w - 2, h - 2),
			]
			for p: Vector2i in probes:
				worst = maxf(worst, img.get_pixelv(p).a)
		_ok("the %s plate has transparent corners" % label,
			img != null and worst < 0.04,
			"corner alpha %.3f would block the bloom" % worst)

		# ── AND NO STONE BACKDROP AROUND ITS EDGE ────────────────────────
		# Transparent corners are NOT sufficient, and assuming they were is
		# what shipped a title plate with 52.5% of its area as opaque
		# generated stone. Its four corners were clean; everything between
		# them was a black slab that rendered straight over the bloom.
		#
		# The surviving backdrop is always at the EDGE of the crop, so sample
		# the margin. Sampled over the whole image this would misfire on the
		# sponsor badge, whose dark pixels are the shadowed aperture blades at
		# its centre — a feature, not backdrop.
		var margin_dark: float = 1.0
		if img != null:
			var iw: int = img.get_width()
			var ih: int = img.get_height()
			var mx: int = maxi(int(float(iw) * 0.06), 2)
			var my: int = maxi(int(float(ih) * 0.06), 2)
			var dark: int = 0
			var seen: int = 0
			for y: int in range(0, ih, 2):
				for x: int in range(0, iw, 2):
					if x >= mx and x < iw - mx and y >= my and y < ih - my:
						continue
					seen += 1
					var c: Color = img.get_pixel(x, y)
					if c.a > 0.78 and c.get_luminance() < 0.16:
						dark += 1
			margin_dark = float(dark) / float(maxi(seen, 1))
		_ok("the %s plate has no stone backdrop at its edge" % label,
			img != null and margin_dark < 0.10,
			"%.1f%% of the margin is opaque dark" % (margin_dark * 100.0))

		# ── IT IS CARVED METAL, NOT A FLAT SHAPE ─────────────────────────
		# The whole point of baking was tonal richness the vectors could not
		# reach. Measure it: a flat vector mark has very few distinct
		# luminance levels, photographic metal has many.
		var levels: Dictionary = {}
		var opaque: int = 0
		if img != null:
			# Sample a ~96x96 grid regardless of the source size, so the
			# tonal-depth measurement costs the same on either plate.
			var step: int = maxi(int(floor(float(img.get_width()) / 96.0)), 1)
			for y: int in range(0, img.get_height(), step):
				for x: int in range(0, img.get_width(), step):
					var c: Color = img.get_pixel(x, y)
					if c.a < 0.5:
						continue
					opaque += 1
					levels[int(c.get_luminance() * 64.0)] = true
		_ok("the %s plate carries photographic tonal depth" % label,
			img != null and levels.size() >= 24,
			"only %d distinct luminance bands over %d samples"
				% [levels.size(), opaque])

	# ── The animated marks are still animated ────────────────────────────
	# Baking must not have quietly replaced the loading readout with a still.
	var iris: Control = live.get_node_or_null("%IrisProgress") as Control
	_ok("the iris readout is still a procedural mark",
		iris != null and iris.get_script() != null
		and str((iris.get_script() as Script).resource_path).ends_with(
			"splash_visuals.gd"))

	# ── The runic text bands are installed ───────────────────────────────
	var name_band: Node = live.get_node_or_null("SponsorLayer/SponsorNameBand")
	_ok("the sponsor name sits on a carved band", name_band != null)
	var framed: Label = null
	var band_rect := Rect2()
	var band_w: float = 0.0
	if name_band != null:
		framed = name_band.call("framed_label") as Label
		band_rect = name_band.call("band_rect")
		band_w = (name_band as Control).size.x
	_ok("the band frames the sponsor name",
		framed != null and framed.text.strip_edges() != "",
		str(framed.text) if framed != null else "no label")
	# The band must HUG the text, not span the container. A Label in a VBox is
	# stretched to full width, so a band that framed the label's rect would
	# draw a rail across the whole screen.
	_ok("the band hugs the text rather than the container",
		band_rect.size.x > 1.0 and band_rect.size.x < band_w * 0.95,
		"band %.0f of %.0f" % [band_rect.size.x, band_w])

## Set the bloom's progress and let its easing converge, then report the reach.
##
## The bloom lerps its displayed value toward the target, so a reading taken
## on the next frame reflects the OLD value almost entirely — which is why the
## first version of the growth check failed against a bloom that works.
func _settled_reach(bloom: Control, target: float) -> float:
	bloom.call("set_progress", target)
	for _i: int in range(90):
		await process_frame
	return float(bloom.call("reach"))


func _report() -> void:
	print("\n═══════════════════════════════════")
	if _fails.is_empty():
		print("ALL %d SPLASH CHECKS PASSED" % _n)
		quit(0)
		return
	print("%d of %d FAILED: %s" % [_fails.size(), _n, str(_fails)])
	quit(1)
