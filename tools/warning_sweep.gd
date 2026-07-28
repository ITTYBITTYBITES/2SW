extends SceneTree
## Compiler-warning sweep: the Godot Debugger tab must stay empty.
##
## WHY THIS EXISTS:
## A warning nobody reads is a warning nobody acts on, and a Debugger tab with
## nine permanent entries is one where the tenth — the real one — is invisible.
## The project reached ~9,000 lines with fourteen standing warnings, three of
## which were genuine hazards rather than noise:
##
##   • two locals named `rotation` inside Control subclasses shadowed
##     Control.rotation, so a stray assignment would have spun the whole node
##     instead of the shape being drawn;
##   • Save.set_v(name: String) shadowed Node.name — assigning to it inside an
##     autoload would have renamed the singleton;
##   • _draw_glyph_particle() silently discarded its `phase` argument, so the
##     rain columns fell in lockstep instead of being de-synchronised.
##
## Nothing caught these. The static linters check style, not semantics, and the
## engine only surfaces warnings in the editor GUI — headless runs swallow them
## entirely, which is why CI was green while the Debugger tab was not.
##
## HOW IT WORKS:
## project.godot cannot enable warnings-as-errors permanently (it would make
## every debug run fail on a work-in-progress line), so this script writes a
## temporary override, recompiles every .gd in the project with
## CACHE_MODE_IGNORE, collects what the compiler says, and restores the
## original file. Recompiling is what forces the warning pass to run again —
## a cached script reports nothing.
##
## RUN VIA tools/warning_sweep.sh, which handles the import pass and the
## override. Running this script directly reports whatever the current
## project settings happen to be, which is usually nothing.

## Directories that are not ours to fix.
const SKIP_DIRS: Array[String] = ["legacy_reference", "addons"]

## Re-loading the script that IS the running MainLoop with CACHE_MODE_IGNORE
## segfaults the engine — it frees the GDScript out from under the loop that
## is currently executing it. Found by this sweep crashing on its own file.
const SELF_PATH: String = "res://tools/warning_sweep.gd"

var _files: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("\n═══ COMPILER WARNING SWEEP ═══\n")
	_collect("res://")
	_files.sort()

	# Each marker line lets the shell wrapper attribute a warning to the file
	# that produced it; the compiler's own output does not always name it.
	for path: String in _files:
		print("### FILE ", path)
		# CACHE_MODE_IGNORE is load-bearing: a cached script is already
		# compiled, so re-loading it normally emits nothing at all and the
		# sweep would report a clean project no matter how dirty it was.
		ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE)

	print("### SWEEP DONE %d" % _files.size())
	quit(0)


func _collect(dir_path: String) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		# Not an invariant: res:// subfolders can legitimately be unreadable
		# in an exported context. Log it rather than failing the sweep.
		print("### SKIP unreadable ", dir_path)
		return

	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with(".") and entry not in SKIP_DIRS:
				_collect(full)
		elif entry.ends_with(".gd") and full != SELF_PATH:
			_files.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
