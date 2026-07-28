# data/ — Phase 1 Output

Strongly-typed `Resource` scripts and data definitions. **No behaviour, no UI,
no node accessors.**

Content that designers tune belongs here as `Resource` + `@export`, so values
are editable in the inspector without touching code.

Planned:
- `trial_def.gd` — one Resource per trial: id, display name, scene, weight,
  difficulty brackets. Replaces v1's four parallel dictionaries that had to be
  manually kept in sync (and weren't — `facet_cascade` was omitted from the
  save seeding, pinning it to Easy forever).
- `cosmetic_def.gd` — hat tiers, unlock rules
- `achievement_def.gd` — 12 milestone definitions
