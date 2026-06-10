# BurpeeTrainer — CLAUDE.md

## Tech stack

- Elixir / Phoenix 1.8, LiveView 1.1, Ecto + SQLite (ecto_sqlite3)
- Tailwind CSS + esbuild (no PostCSS, no Sass)
- No React, no Node server — all server-rendered LiveView

## Intelligence layer

See `INTELLIGENCE_LAYER.md` for the current fixed weekly contract, coach target planner, catch-up planner, deterministic PlanSolver, and removed architecture.

## Module map

| Module | Responsibility |
|---|---|
| `BurpeeTrainer.WeeklyTrainingContract` | Fixed 80 min / 4×20 / 2+2 weekly contract status |
| `BurpeeTrainer.CoachTargetPlanner` | Deterministic 20-minute target suggestions from active performance goals |
| `BurpeeTrainer.CatchUpPlanner` | Type-locked long catch-up session planning with duration intensity caps |
| `BurpeeTrainer.PerformanceModel` | Type-specific 20-minute capacity estimates from history |
| `BurpeeTrainer.PaceModel` | Type-specific recommended pace ranges by level |
| `BurpeeTrainer.PlanSolver` | Deterministic session structure generation; exact-duration `Search` candidates, no MILP/external solver |
| `BurpeeTrainer.PlanNotation` | Compact `N×[reps,…]` workout notation (e.g. `14×[8] 4×[7]`) |
| `BurpeeTrainer.PlanEditor.Segments` | Plan-editor segment model: balance/validate structures with one-tap fixes, materialize to blocks+steps |
| `BurpeeTrainer.Planner` | Converts a saved `WorkoutPlan` to a flat timeline of events |
| `BurpeeTrainer.Workouts` | Ecto context: sessions, plans, blocks, sets, style_performance |
| `BurpeeTrainer.Goals` | Ecto context: goals CRUD and conversion to performance goals |
| `BurpeeTrainer.Progression` | Pure progression logic: recommend, project_trend, trend_status |
| `BurpeeTrainer.Scoring` | Pure push-up score (six_count ×1, navy_seal ×3), weekly totals, 40/40 balance |
| `BurpeeTrainer.Milestones` | Pure celebration-event detection (PRs, level-up, goals, comeback) |
| `BurpeeTrainer.Levels` | Level unlock + **decay** rules (co-week, landmark_history, level_status) |
| `BurpeeTrainer.StyleGenerator` | Generates style variants for a plan |
| `BurpeeTrainer.StyleRecommender` | Picks a style variant to suggest |
| `BurpeeTrainer.Accounts` | User auth (bcrypt, sessions) |

## Data model — critical distinctions

- `sec_per_burpee` — movement time only (used for pace validation and warmup)
- `sec_per_rep` on `Set` — cadence = movement + padding (used for timeline math)
- `additional_rests` on `WorkoutPlan` — stored as JSON text: `[{rest_sec, target_min}]`
- `pacing_style` — `:even` (sets with end_of_set_rest) or `:unbroken` (one block, one set)

**Levels decay:** `Levels.current_level/2` and `level_status/2` take a `today` and require a
level to be *maintained* — the most recent co-week pair must be within `window_days/1`
(30 days for `:graduated`, 14 for the rest) or the level drops. `:level_1a` is the floor.

**`user_stats` gamification columns** (migration `20260529000000`): `best_week_pushups`(+`_on`),
`best_session_pushups`(+`_on`), `best_pace_sec_per_burpee`(+`_on`), `lifetime_pushup_milestone`.
Personal bests are persisted by `Workouts.session_milestones/3` at session-save time.

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
