#!/usr/bin/env bash
# All checks. No Godot binary required — safe for CI.
set -e
cd "$(dirname "$0")/.."
echo "─── GDScript lint ───────────────────────────────"
python3 tests/lint_gdscript.py
echo "─── cross-reference check ───────────────────────"
python3 tests/check_xrefs.py
echo "─── architectural directives ────────────────────"
python3 tests/check_architecture.py
echo "─── boot / navigation behaviour ─────────────────"
python3 tests/test_boot.py
echo "─── iris shader + view contract ─────────────────"
python3 tests/test_iris_view.py
echo "─── hub portal + compass wiring ─────────────────"
python3 tests/test_hub_portal.py
echo "─── wardrobe economy + migration ────────────────"
python3 tests/test_wardrobe.py
echo "─── procedural cosmetic renderer ────────────────"
python3 tests/test_cosmetic_renderer.py
echo "─── progression + lumina economy ────────────────"
python3 tests/test_progression.py
echo "─── trial mini-games + results ──────────────────"
python3 tests/test_trials.py
echo "─── trial registry + adaptive difficulty ────────"
python3 tests/test_trial_suite.py
echo "─── dialogue, audio safety + daily hub ──────────"
python3 tests/test_daily_audio.py
echo "─── progress, settings + routing web ────────────"
python3 tests/test_progress_settings.py
echo "─── consent gate + privacy choices ──────────────"
python3 tests/test_consent.py
echo "─── admob integration + haptics ─────────────────"
python3 tests/test_ads_haptics.py
echo "─── startup splash + title sequence ─────────────"
python3 tests/test_splash.py
echo "─── chrono-pulse design model ───────────────────"
python3 tests/test_chrono_pulse.py
echo "─── trend content pipeline ──────────────────────"
python3 tests/test_trend_pipeline.py
python3 tools/trend_content_pipeline/scripts/validate_output.py

# Godot validation runs only when an engine is reachable, so the static suite
# still works on a machine without one.
if command -v godot >/dev/null 2>&1 || [ -n "${GODOT_BIN:-}" ] \
   || [ -x /tmp/Godot_v4.6.3-stable_linux.x86_64 ] \
   || [ -x /tmp/Godot_v4.3-stable_linux.x86_64 ]; then
  echo "─── voice pack matches the script ───────────────"
python3 tools/generate_voice_lines.py --check

echo "─── godot headless validation ───────────────────"
  bash ./tools/godot_validate.sh >/tmp/godot_suite.log 2>&1 \
    && grep -E "^ALL .* (CHECKS|CHRONO CHECKS|TREND CHECKS|POLISH CHECKS|LIFECYCLE CHECKS|TIMING CHECKS) PASSED|^ZERO COMPILER WARNINGS" /tmp/godot_suite.log \
    || { echo "GODOT VALIDATION FAILED (see /tmp/godot_suite.log)"; exit 1; }
else
  echo "─── godot headless validation ── SKIPPED (no engine) ─"
fi

echo
echo "ALL CHECKS PASSED"
