# BurpeeTrainer — CLAUDE.md

## Tech stack

- Elixir / Phoenix 1.8, LiveView 1.1, Ecto + SQLite (ecto_sqlite3)
- Tailwind CSS + esbuild (no PostCSS, no Sass)
- No React, no Node server — all server-rendered LiveView

## Module map

| Module | Responsibility |
|---|---|
| `BurpeeTrainer.PlanWizard` | Solver: takes `%PlanInput{}`, returns blocks/sets |
| `BurpeeTrainer.Planner` | Converts a saved `WorkoutPlan` to a flat timeline of events |
| `BurpeeTrainer.Workouts` | Ecto context: sessions, plans, blocks, sets, style_performance |
| `BurpeeTrainer.Goals` | Ecto context: goals CRUD |
| `BurpeeTrainer.Progression` | Pure progression logic: recommend, project_trend, trend_status |
| `BurpeeTrainer.Levels` | Level unlock rules (co-week rule, landmark_history) |
| `BurpeeTrainer.StyleGenerator` | Generates style variants for a plan |
| `BurpeeTrainer.StyleRecommender` | Picks a style variant to suggest |
| `BurpeeTrainer.Accounts` | User auth (bcrypt, sessions) |

## Data model — critical distinctions

- `sec_per_burpee` — movement time only (used for pace validation and warmup)
- `sec_per_rep` on `Set` — cadence = movement + padding (used for timeline math)
- `additional_rests` on `WorkoutPlan` — stored as JSON text: `[{rest_sec, target_min}]`
- `pacing_style` — `:even` (sets with end_of_set_rest) or `:unbroken` (one block, one set)

**Removed fields (do not reintroduce):** `warmup_enabled`, `warmup_reps`, `warmup_rounds`,
`rest_sec_warmup_between`, `rest_sec_warmup_before_main`, `shave_off_sec`, `shave_off_block_count`.
These were removed in migration `20260426000000`. Warmup is now computed dynamically in `Planner.warmup_timeline/1`.

## Planner event types

`:warmup_burpee`, `:warmup_rest`, `:work_burpee`, `:work_rest`, `:rest_block`

No `:shave_rest` — removed in the 2026-04-26 refactor.

## SQLite constraints

- No `RETURNING` clause support in older SQLite — avoid in raw queries
- No array column type — use JSON text fields for collections
- No `gen_random_uuid()` — use Ecto's `:binary_id` with `autogenerate: true`

## UI rules (see UI.md for full spec)

- Electric blue (`#4A9EFF`) replaces green everywhere — no `text-green-*` or `bg-green-*` for UI chrome
- No shadows, no gradients, no custom web fonts (system fonts only)
- Color palette is defined as CSS vars in UI.md — reference those, don't hardcode hex in templates
- Orange (`#F97316`) is data-only (navy_seal chart series) — never use it for UI elements

## Testing philosophy (see TESTING.md for full spec)

- Pure modules (`Planner`, `Progression`) use property-based tests via StreamData
- Test invariants, not examples: duration sums, burpee counts, state machine validity
- Do not write example-based unit tests for those modules — extend the property suites instead
- Integration tests (LiveView, Ecto) use standard ExUnit + ConnCase

## Precommit check

Run before marking any patch done:

```
mix precommit
```

This runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.
