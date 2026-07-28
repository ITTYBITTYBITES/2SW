extends Node
## Log — leveled logging that is LOUD in debug and quiet in release.
##
## v1 had exactly one push_error() in 7,604 lines and a culture of silent
## fallbacks: a missing trial scene awarded the player a neutral score and
## moved on. Bugs hid instead of surfacing.
##
## Rule here: in a debug build, a broken invariant CRASHES. In release, it
## degrades gracefully and records a breadcrumb. Same call site, both
## behaviours — so we never have to choose between "safe for players" and
## "obvious for us".

enum Level { DEBUG, INFO, WARN, ERROR }

## Ring buffer of recent lines, attached to crash/bug reports.
const BREADCRUMB_MAX := 120
var _breadcrumbs: PackedStringArray = []

var min_level: Level = Level.DEBUG


func _ready() -> void:
	min_level = Level.DEBUG if OS.is_debug_build() else Level.WARN
	info("Log", "boot v%s debug=%s" % [
		ProjectSettings.get_setting("application/config/version", "?"),
		str(OS.is_debug_build()),
	])


func d(tag: String, msg: String) -> void:
	_emit(Level.DEBUG, tag, msg)

func info(tag: String, msg: String) -> void:
	_emit(Level.INFO, tag, msg)

func warn(tag: String, msg: String) -> void:
	_emit(Level.WARN, tag, msg)

func error(tag: String, msg: String) -> void:
	_emit(Level.ERROR, tag, msg)


## Assert an invariant. Debug: hard crash with context. Release: log + continue.
## Returns `cond` so it can be used inline:  if not Log.must(x != null, ...): return
func must(cond: bool, tag: String, msg: String) -> bool:
	if not cond:
		_emit(Level.ERROR, tag, "INVARIANT FAILED: " + msg)
		if OS.is_debug_build():
			# Deliberate hard stop. Fix the cause; do not soften this.
			assert(false, "%s: %s" % [tag, msg])
	return cond


func breadcrumbs() -> String:
	return "\n".join(_breadcrumbs)


func _emit(level: Level, tag: String, msg: String) -> void:
	var line := "[%s] %-14s %s" % [_tag_of(level), tag, msg]
	_breadcrumbs.append(line)
	if _breadcrumbs.size() > BREADCRUMB_MAX:
		_breadcrumbs.remove_at(0)
	if level < min_level:
		return
	match level:
		Level.ERROR:
			push_error(line)
		Level.WARN:
			push_warning(line)
		_:
			print(line)


func _tag_of(level: Level) -> String:
	match level:
		Level.DEBUG: return "dbg"
		Level.INFO:  return "inf"
		Level.WARN:  return "WRN"
		_:           return "ERR"
