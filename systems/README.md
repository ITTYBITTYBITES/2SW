# systems/ — Phase 2 Output

Headless gameplay controllers. Logic and math only — these must be testable
without opening a scene.

Rules:
- Emit cross-system events via `Bus`; never call into another system directly.
- Read balance and timing from `Palette` / `Cfg`, never inline magic numbers.
- Every system ships with a test in `tests/`.

Planned:
- `progression.gd` — level curve, Lumina/Resonance economy, adaptive difficulty
- `trial_host.gd` — fixed-timestep trial loop, deterministic seeding
- `daily.gd` — UTC day index, streak rules
