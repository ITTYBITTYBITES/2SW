extends Control
class_name TrialMiniGame
## TrialMiniGame — base contract for every trial mode.
##
## PHASE 7. Each mini-game draws itself with vector geometry (no textures),
## records answers through the host, and ends by calling conclude_trial().
##
## INPUT ISOLATION (spec requirement): the mini-game root is MOUSE_FILTER_IGNORE
## so it can never swallow taps meant for chrome or the Iris behind it. Only
## explicit hit targets opt back in, via `make_target()`. v1 layered whole-screen
## Controls that stole input from the eye.
##
## DETERMINISM: every mini-game seeds its RNG from the host's trial seed, so a
## given run is reproducible for debugging and for fair daily challenges.
##
## Subclasses override: _configure_bracket(), begin(), and _draw().

## Set by the host. Never reached into — only these three methods are used.
var host: Node = null

## Appearance recipe, derived from the player's rank. Read by _draw() only —
## it never influences difficulty, scoring, timing or answer correctness,
## which stay owned by bracket and the trial's own rules.
var recipe: RelicRecipe = null
var bracket: int = 0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _running: bool = false
var _rounds_total: int = 0
var _rounds_done: int = 0

# ── Reaction latency ─────────────────────────────────────────────────────
## Monotonic timestamp of the moment the current stimulus became answerable,
## in milliseconds. -1 means no stimulus is live, so a stray tap cannot be
## timed against a stimulus that was never shown.
var _stimulus_msec: int = -1
## Latency of every answered round, in the order they were answered.
var _latencies: Array[int] = []
## Rounds where the player never responded before the window closed. Kept
## separate from a slow response: a miss is a different outcome, not a large
## number, and averaging one into the other would make a timeout look like a
## sluggish but successful reaction.
var _misses: int = 0

## Where the player last touched, in field-local space. Seeded to (-1, -1) —
## a coordinate no real target occupies — so answer_point() can report
## "nothing touched yet" without a second boolean to keep in sync.
var _last_answer_point: Vector2 = Vector2(-1.0, -1.0)


## The centre of the last hit target the player pressed, in field-local space.
##
## Falls back to the field centre when nothing has been touched, which is the
## right answer for modes that are answered by a gesture or a timeout rather
## than by tapping a specific object.
func answer_point() -> Vector2:
	if _last_answer_point.x < 0.0:
		return field_centre()
	return _last_answer_point


## Has the player pressed a hit target this run? Distinct from answer_point()
## so a caller can tell a real touch at the centre from the fallback.
func has_answer_point() -> bool:
	return _last_answer_point.x >= 0.0


func _ready() -> void:
	# The stage itself is transparent to input; targets opt in explicitly.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Called by TrialController immediately after instantiation.
func configure(p_host: Node, p_bracket: int) -> void:
	host = p_host
	bracket = clampi(p_bracket, 0, 2)
	recipe = _derive_recipe()

	# DETERMINISM: the seed comes from the host when it has one, and only
	# falls back to the wall clock for ordinary practice runs.
	#
	# The docstring above claimed runs were "reproducible ... for fair daily
	# challenges" while the seed was Time.get_unix_time_from_system() — a value
	# that differs for every player and every run. The claim was false for as
	# long as it existed, and no test caught it because nothing compared two
	# runs. A deterministic daily REQUIRES the host to supply the seed.
	var supplied: int = 0
	if host != null and host.has_method("trial_seed"):
		supplied = int(host.call("trial_seed"))
	if supplied != 0:
		_rng.seed = supplied ^ (bracket << 8)
	else:
		_rng.seed = int(Time.get_unix_time_from_system()) ^ (bracket << 8)

	_configure_bracket(bracket)


## Subclasses read their difficulty table here.
func _configure_bracket(_bracket: int) -> void:
	pass


## Subclasses start their first round here.
func begin() -> void:
	_running = true


# ═════════════════════════════════════════════════════════════════════════
# REACTION LATENCY
# ═════════════════════════════════════════════════════════════════════════
## Mark the instant the current stimulus became answerable.
##
## Called by a subclass at the exact frame the player could first legitimately
## respond — not when the round was set up. The gap between "round begins" and
## "stimulus is visible" is real (fade-ins, lead-in delays) and counting it as
## reaction time would inflate every measurement.
##
## Time.get_ticks_msec() is monotonic: immune to the player editing their
## device clock mid-run, which the wall clock is not.
func mark_stimulus() -> void:
	_stimulus_msec = Time.get_ticks_msec()


## Milliseconds since the current stimulus appeared, or -1 if none is live.
func latency_since_stimulus() -> int:
	if _stimulus_msec < 0:
		return -1
	return maxi(Time.get_ticks_msec() - _stimulus_msec, 0)


## Clear the live stimulus so a late tap cannot be timed against it.
func clear_stimulus() -> void:
	_stimulus_msec = -1


## Every recorded latency, in answer order.
func latencies() -> Array[int]:
	return _latencies


func miss_count() -> int:
	return _misses


## Mean latency over ANSWERED rounds only, or -1 when nothing was answered.
##
## Timeouts are deliberately excluded rather than counted as the window
## length. Including them would blend "did not respond" into "responded
## slowly", and the daily card's tier would then describe a reaction the
## player never made.
func mean_latency_ms() -> int:
	if _latencies.is_empty():
		return -1
	var total: int = 0
	for value: int in _latencies:
		total += value
	return int(round(float(total) / float(_latencies.size())))


## Fastest recorded latency, or -1 when nothing was answered.
func best_latency_ms() -> int:
	if _latencies.is_empty():
		return -1
	var best: int = _latencies[0]
	for value: int in _latencies:
		best = mini(best, value)
	return best


## Did the player respond to at least one stimulus?
func had_any_response() -> bool:
	return not _latencies.is_empty()


## Report one answer WITHOUT advancing the round counter.
##
## For modes where several answers make up one round — sequence_recall taps
## each step of a pattern — submit() would end the run after the first few
## taps, because it treats every call as a completed round. This records the
## latency and the answer and leaves round bookkeeping to the subclass.
##
## Exists so such a mode still gets real timing instead of bypassing the base
## class entirely, which is exactly what sequence_recall did: it called
## host.record_answer() directly and therefore recorded no latency at all.
func submit_step(is_correct: bool, timed_out: bool = false) -> void:
	if not _running:
		return
	_record_timing(timed_out)
	if host != null and host.has_method("record_answer"):
		host.record_answer(is_correct)


## Shared timing capture for submit() and submit_step().
func _record_timing(timed_out: bool) -> void:
	if timed_out:
		_misses += 1
	else:
		var measured: int = latency_since_stimulus()
		if measured >= 0:
			_latencies.append(measured)
		else:
			# An answer with no live stimulus means a subclass submitted
			# without calling mark_stimulus(). Score it, but never invent a
			# latency for it — a fabricated number would be indistinguishable
			# from a real one in the history.
			Log.d("Trial", "answer submitted with no live stimulus")
	clear_stimulus()


## Report one answer to the host. Routed through the base so no subclass has to
## know the host's method name, and so scoring can never be double-counted.
##
## `timed_out` distinguishes a window expiring from a wrong answer. Both score
## zero, but only one of them has a latency worth recording.
func submit(is_correct: bool, timed_out: bool = false) -> void:
	if not _running:
		return

	_record_timing(timed_out)

	if host != null and host.has_method("record_answer"):
		host.record_answer(is_correct)
	_rounds_done += 1
	if _rounds_total > 0 and _rounds_done >= _rounds_total:
		finish()


## End the run and hand control back to the host for settlement.
func finish() -> void:
	if not _running:
		return
	_running = false
	set_process(false)
	if host != null and host.has_method("conclude_trial"):
		host.conclude_trial()


func is_running() -> bool:
	return _running


func progress_text() -> String:
	return "%d / %d" % [_rounds_done, maxi(_rounds_total, 1)]


# ═════════════════════════════════════════════════════════════════════════
# HIT TARGETS
# ═════════════════════════════════════════════════════════════════════════
## A transparent, input-receiving region. This is the ONLY thing in a
## mini-game that accepts touch, so nothing else can intercept the eye.
func make_target(target_rect: Rect2, on_pressed: Callable) -> Control:
	var target: Control = Control.new()
	target.mouse_filter = Control.MOUSE_FILTER_STOP
	target.position = target_rect.position
	target.size = target_rect.size
	# Remember where the player touched, so the feedback overlay can centre its
	# pulse or abrasion on the thing they actually answered rather than on the
	# middle of the screen. Recorded here, in the ONE place every hit target is
	# built, so no subclass has to opt in and none can forget.
	var centre: Vector2 = target_rect.position + target_rect.size * 0.5
	target.gui_input.connect(func(event: InputEvent) -> void:
		var pressed: bool = (
			(event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed))
		if pressed:
			_last_answer_point = centre
			on_pressed.call())
	add_child(target)
	return target


## Remove every hit target so a stale one from the previous round cannot fire.
func clear_targets() -> void:
	for child: Node in get_children():
		if child is Control and (child as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
			child.queue_free()


## Centre of the play field, in local coordinates.
func field_centre() -> Vector2:
	return size * 0.5


## Short edge of the play field — all geometry scales from this.
func field_unit() -> float:
	return minf(size.x, size.y)


## Build the appearance recipe from live progression.
##
## Falls back to a rank-1 recipe when the host cannot supply state — a
## practice run mounted without an IrisState still has to draw something, and
## the floor recipe is exactly what a new player would see anyway.
func _derive_recipe() -> RelicRecipe:
	var complexity: float = 1.0
	var shimmer: float = 0.0
	if host != null and host.has_method("progression_visuals"):
		var v: Dictionary = host.call("progression_visuals")
		complexity = float(v.get("complexity", 1.0))
		shimmer = float(v.get("shimmer", 0.0))
	return RelicRecipe.derive(complexity, shimmer, bracket)


func rng() -> RandomNumberGenerator:
	return _rng


func set_round_count(count: int) -> void:
	_rounds_total = maxi(count, 1)


func rounds_done() -> int:
	return _rounds_done


func rounds_total() -> int:
	return _rounds_total
