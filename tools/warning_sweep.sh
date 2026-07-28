#!/usr/bin/env bash
# Fail if the project produces ANY GDScript compiler warning.
#
#   ./tools/warning_sweep.sh [path-to-godot]
#
# The Godot Debugger tab is only useful when it is empty. This turns "keep it
# quiet" from a habit into a check.
#
# WHY THE TEMPORARY OVERRIDE:
# Warnings-as-errors cannot live in project.godot permanently — it would make
# every debug run fail on a half-finished line, and the editor would refuse to
# open the project. So the setting is written, the sweep runs, and the original
# project.godot is restored on exit no matter how the script terminates.
#
# WHY headless --editor DOESN'T WORK:
# Godot only prints script warnings through the editor GUI. A headless run
# swallows them silently, which is exactly why 14 warnings survived a suite
# that was otherwise 255 checks green. Promoting them to errors is the only way
# to see them from a terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${1:-${GODOT_BIN:-}}"
if [[ -z "$GODOT" ]]; then
  for candidate in godot godot4 /tmp/Godot_v4.6.3-stable_linux.x86_64 \
                   /tmp/Godot_v4.3-stable_linux.x86_64; do
    if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
      GODOT="$candidate"; break
    fi
  done
fi
if [[ -z "$GODOT" ]]; then
  echo "ERROR: no Godot binary found."
  exit 127
fi

BACKUP="$(mktemp)"
cp project.godot "$BACKUP"
# Restore on ANY exit path — success, failure, or interrupt. A crashed sweep
# must never leave warnings-as-errors committed to the project file.
trap 'cp "$BACKUP" project.godot; rm -f "$BACKUP"' EXIT

# Every warning that indicates a real defect. Deliberately EXCLUDED:
#   untyped/inferred_declaration — the architecture check already enforces
#     strict typing, and its rules are stricter than the engine's;
#   unsafe_* — these fire on every Variant round-trip through Save and would
#     bury the signal under thousands of lines;
#   return_value_discarded — fires on idiomatic connect() and tween calls.
cat >> project.godot <<'EOF'

[debug]

gdscript/warnings/enable=true
gdscript/warnings/exclude_addons=true
gdscript/warnings/unused_variable=2
gdscript/warnings/unused_local_constant=2
gdscript/warnings/unused_parameter=2
gdscript/warnings/unused_private_class_variable=2
gdscript/warnings/unused_signal=2
gdscript/warnings/shadowed_variable=2
gdscript/warnings/shadowed_variable_base_class=2
gdscript/warnings/shadowed_global_identifier=2
gdscript/warnings/narrowing_conversion=2
gdscript/warnings/integer_division=2
gdscript/warnings/standalone_expression=2
gdscript/warnings/standalone_ternary=2
gdscript/warnings/confusable_local_declaration=2
gdscript/warnings/confusable_local_usage=2
gdscript/warnings/static_called_on_instance=2
gdscript/warnings/redundant_static_unload=2
gdscript/warnings/int_as_enum_without_cast=2
gdscript/warnings/native_method_override=2
gdscript/warnings/get_node_default_without_onready=2
gdscript/warnings/onready_with_export=2
gdscript/warnings/incompatible_ternary=2
gdscript/warnings/return_value_discarded=0
gdscript/warnings/untyped_declaration=0
gdscript/warnings/inferred_declaration=0
gdscript/warnings/unsafe_property_access=0
gdscript/warnings/unsafe_method_access=0
gdscript/warnings/unsafe_cast=0
gdscript/warnings/unsafe_call_argument=0
gdscript/warnings/unsafe_void_return=0
EOF

# The import pass builds the global class cache. Without it every `class_name`
# is unknown, scripts fail on "Could not find base class Screen" BEFORE the
# warning pass runs, and the sweep reports a falsely clean project.
"$GODOT" --headless --path . --import >/tmp/warning_sweep_import.log 2>&1 || true

LOG=/tmp/warning_sweep.log
"$GODOT" --headless --path . --script res://tools/warning_sweep.gd >"$LOG" 2>&1 || true

python3 - "$LOG" <<'PY'
import re, sys

log = open(sys.argv[1], errors="replace").read().splitlines()
current, warnings, errors = None, {}, {}

for line in log:
    line = line.rstrip()
    if line.startswith("### FILE "):
        current = line[9:]
    elif "Warning treated as error" in line:
        text = re.sub(r"^SCRIPT ERROR: Parse Error: ", "", line.strip())
        warnings.setdefault(current or "<before any file marker>", []).append(text)
    elif "Parse Error" in line or "Compile Error" in line or "Failed to load" in line:
        errors.setdefault(current or "<before any file marker>", []).append(
            line.strip()[:160])

# Warnings-as-errors ARE parse errors — that is the whole mechanism — so every
# file with a warning also logs "Failed to load script". Attributing those to
# the compile-failure bucket would report a real warning as a broken sweep.
# Only a file that failed WITHOUT producing a warning genuinely hid something.
errors = {k: v for k, v in errors.items() if k not in warnings}

if not any(l.startswith("### SWEEP DONE") for l in log):
    print("SWEEP DID NOT COMPLETE — see", sys.argv[1])
    sys.exit(1)

swept = int(next(l for l in log if l.startswith("### SWEEP DONE")).split()[-1])

# A parse error stops compilation BEFORE the warning pass, so an unfixed one
# would hide every warning in that file behind a green result. Treat it as a
# failure of the sweep itself rather than reporting a clean project.
if errors:
    print("SWEEP INVALID — these files failed to compile, so their warnings")
    print("were never evaluated:\n")
    for path, msgs in errors.items():
        print(f"  {path}")
        for m in dict.fromkeys(msgs):
            print(f"      {m}")
    sys.exit(1)

if warnings:
    total = sum(len(v) for v in warnings.values())
    print(f"{total} COMPILER WARNING(S) across {len(warnings)} file(s):\n")
    for path, msgs in sorted(warnings.items()):
        print(f"  {path}")
        for m in dict.fromkeys(msgs):
            print(f"      {m}")
    print("\nThe Debugger tab must stay quiet. Fix these or justify each one")
    print("with an explicit @warning_ignore and a comment saying why.")
    sys.exit(1)

print(f"ZERO COMPILER WARNINGS across {swept} scripts")
PY
