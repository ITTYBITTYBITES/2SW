#!/usr/bin/env bash
# Headless Godot validation.
#
#   ./tools/godot_validate.sh [path-to-godot]
#
# Resolves a Godot 4 binary, forces a full import so the global class cache is
# built, then runs tools/validate.gd. Exits non-zero on any failure.
#
# WHY THE IMPORT PASS MATTERS: on a clean checkout there is no .godot/ cache,
# so every `class_name` is unknown and the whole project reports phantom parse
# errors. One `--import` fixes it. CI without this step fails mysteriously.
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
  echo "  pass one:  ./tools/godot_validate.sh /path/to/godot"
  echo "  or set:    GODOT_BIN=/path/to/godot"
  exit 127
fi

echo "── using: $($GODOT --version 2>/dev/null | head -1)"

echo "── import pass (builds the global class cache)"
"$GODOT" --headless --path . --import >/tmp/godot_import.log 2>&1 || true

# A parse error here means broken GDScript, not a missing cache.
if grep -qE "SCRIPT ERROR|Parse Error" /tmp/godot_import.log; then
  echo "FAILED: parse errors during import"
  grep -E "SCRIPT ERROR|Parse Error|at: GDScript" /tmp/godot_import.log | sort -u | head -30
  exit 1
fi
echo "   0 parse errors"

echo "── validation script"
set +e
"$GODOT" --headless --path . --script res://tools/validate.gd 2>&1 | tee /tmp/godot_validate.log
set -e

if ! grep -q "ALL .* CHECKS PASSED" /tmp/godot_validate.log; then
  echo
  echo "GODOT VALIDATION FAILED"
  exit 1
fi

echo "── consent flow"
set +e
"$GODOT" --headless --path . --script res://tools/consent_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:" | tee /tmp/godot_consent.log
set -e

if ! grep -q "ALL .* CONSENT CHECKS PASSED" /tmp/godot_consent.log; then
  echo
  echo "CONSENT FLOW FAILED"
  exit 1
fi

echo "── ads + haptics flow"
set +e
"$GODOT" --headless --path . --script res://tools/ads_haptics_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:" | tee /tmp/godot_ads.log
set -e

if ! grep -q "ALL .* ADS/HAPTICS CHECKS PASSED" /tmp/godot_ads.log; then
  echo
  echo "ADS/HAPTICS FLOW FAILED"
  exit 1
fi

echo "── splash sequence"
set +e
"$GODOT" --headless --path . --script res://tools/splash_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:" | tee /tmp/godot_splash.log
set -e

if ! grep -q "ALL .* SPLASH CHECKS PASSED" /tmp/godot_splash.log; then
  echo
  echo "SPLASH FLOW FAILED"
  exit 1
fi


echo "── layout across viewports"
set +e
"$GODOT" --headless --path . --script res://tools/layout_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]" | tee /tmp/godot_layout.log
set -e

if ! grep -q "ALL .* LAYOUT CHECKS PASSED" /tmp/godot_layout.log; then
  echo
  echo "LAYOUT FAILED"
  exit 1
fi

echo "── chrono-pulse (daily anomaly)"
set +e
"$GODOT" --headless --path . --script res://tools/chrono_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
  | tee /tmp/godot_chrono.log
set -e

if ! grep -q "ALL .* CHRONO CHECKS PASSED" /tmp/godot_chrono.log; then
  echo
  echo "CHRONO-PULSE FAILED"
  exit 1
fi

echo "── trend hub"
set +e
"$GODOT" --headless --path . --script res://tools/trend_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
  | tee /tmp/godot_trend.log
set -e

if ! grep -q "ALL .* TREND CHECKS PASSED" /tmp/godot_trend.log; then
  echo
  echo "TREND HUB FAILED"
  exit 1
fi

echo "── trial timing contract"
set +e
"$GODOT" --headless --path . --script res://tools/trial_timing_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
  | tee /tmp/godot_timing.log
set -e

if ! grep -q "ALL .* TIMING CHECKS PASSED" /tmp/godot_timing.log; then
  echo
  echo "TRIAL TIMING FAILED"
  exit 1
fi

echo "── lifecycle safeguards"
# UNDER A REAL DISPLAY SERVER, AT A NON-DESIGN WINDOW SIZE.
#
# The safe-area sanity checks exercise DisplayServer.get_display_safe_area(),
# which under --headless returns a zero rect — the desktop code path never
# runs and the checks are vacuous. Proven by injection: reverting the safe
# area fix entirely still gave "ALL CHECKS PASSED" headlessly, while the same
# run under X11 produced six failures.
#
# 817x1452 is the window size the defect was reported from, deliberately NOT
# the design resolution, so the monitor/window mismatch is real.
set +e
if command -v xvfb-run >/dev/null 2>&1; then
  xvfb-run -a --server-args="-screen 0 1920x1080x24" \
    "$GODOT" --path . --resolution 817x1452 \
    --script res://tools/lifecycle_flow.gd 2>&1 \
    | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
    | tee /tmp/godot_lifecycle.log
else
  echo "  (xvfb-run absent — the safe-area sanity checks will report SKIP)"
  "$GODOT" --headless --path . --script res://tools/lifecycle_flow.gd 2>&1 \
    | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
    | tee /tmp/godot_lifecycle.log
fi
set -e

if ! grep -q "ALL .* LIFECYCLE CHECKS PASSED" /tmp/godot_lifecycle.log; then
  echo
  echo "LIFECYCLE FLOW FAILED"
  exit 1
fi

echo "── phase 1: nav gate + vision model"
# RUN THIS ONE ON A REAL GPU WHEN ONE CAN BE FAKED.
#
# The vision flow locates the pupil by reading rendered PIXELS — the only way
# to catch a glyph drawn in the wrong place, since any check that recomputes
# the position agrees with whatever bug the implementation has. Under
# --headless the driver is Dummy, nothing is rasterised, and the check reports
# SKIP. xvfb-run gives it llvmpipe, so it actually executes.
set +e
if command -v xvfb-run >/dev/null 2>&1; then
  xvfb-run -a --server-args="-screen 0 1200x2000x24" \
    "$GODOT" --path . --resolution 1080x1920 \
    --script res://tools/vision_gate_flow.gd 2>&1 \
    | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
    | tee /tmp/godot_vision.log
else
  echo "  (xvfb-run absent — the rendered-pupil check will report SKIP)"
  "$GODOT" --headless --path . --script res://tools/vision_gate_flow.gd 2>&1 \
    | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
    | tee /tmp/godot_vision.log
fi
set -e

if ! grep -q "ALL .* PHASE-1+2 CHECKS PASSED" /tmp/godot_vision.log; then
  echo
  echo "VISION/GATE FLOW FAILED"
  exit 1
fi

echo "── visual polish audit"
set +e
"$GODOT" --headless --path . --script res://tools/polish_audit.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:|backtrace|^\s+\[[0-9]\]|^ERROR|^SCRIPT ERROR" \
  | tee /tmp/godot_polish.log
set -e

if ! grep -q "ALL .* POLISH CHECKS PASSED" /tmp/godot_polish.log; then
  echo
  echo "POLISH AUDIT FAILED"
  exit 1
fi

echo "── audio director"
"$GODOT" --headless --path . --script res://tools/audio_director_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:" | tee /tmp/godot_audiodir.log
if ! grep -q "ALL .* AUDIO DIRECTOR CHECKS PASSED" /tmp/godot_audiodir.log; then
  echo "AUDIO DIRECTOR FAILED"; exit 1
fi

echo "── layer engine"
"$GODOT" --headless --path . --script res://tools/layer_engine_flow.gd 2>&1 \
  | grep -vE "^\[inf|^\[dbg|^WARNING|^     at:" | tee /tmp/godot_layers.log
if ! grep -q "ALL .* LAYER ENGINE CHECKS PASSED" /tmp/godot_layers.log; then
  echo "LAYER ENGINE FAILED"; exit 1
fi

echo "── layer library matches its recipes"
if ! python3 ./tools/bake_audio_layers.py --check; then
  echo "LAYER LIBRARY FAILED"; exit 1
fi

echo "── compiler warning sweep"
# Keeps the Debugger tab empty. Runs LAST because it rewrites project.godot
# temporarily; every earlier flow needs the file untouched.
if ! bash ./tools/warning_sweep.sh "$GODOT" 2>&1 | tee /tmp/godot_warnings.log; then
  echo
  echo "COMPILER WARNINGS PRESENT"
  exit 1
fi

echo
echo "GODOT VALIDATION PASSED"
exit 0
