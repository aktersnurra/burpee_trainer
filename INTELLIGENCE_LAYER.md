# Intelligence Layer

This document describes the current intelligence layer implementation. It supersedes the old PlanWizard / MILP / ScheduleSolver direction.

## Core contract

The app uses a fixed weekly training contract:

- 80 minutes per week
- 4 standard sessions
- 20 minutes per standard session
- 2 Six-count sessions
- 2 Navy SEAL sessions

The app does not schedule days or times. The user decides when to train.

## What the intelligence layer answers

The intelligence layer answers narrow, explicit questions:

1. **WeeklyTrainingContract** — how much of the fixed weekly contract is complete?
2. **PerformanceModel** — what does the user currently seem capable of for each burpee type?
3. **CoachTargetPlanner** — what 20-minute target keeps this type-specific performance goal moving?
4. **CatchUpPlanner** — given the user-selected type and remaining duration, what long catch-up target is reasonable?
5. **PlanSolver** — how should a chosen target become a concrete workout plan?

It does not answer:

- which day to train
- what time of day to train
- whether to mix burpee types
- whether to repair the weekly split automatically
- whether to create catch-up work without explicit user intent

## Module map

| Module | Responsibility |
| --- | --- |
| `BurpeeTrainer.WeeklyTrainingContract` | Fixed 80 min / 4×20 / 2+2 weekly status. |
| `BurpeeTrainer.PerformanceGoal` | Pure type-specific performance goal struct. |
| `BurpeeTrainer.Goals` | Ecto goals context and conversion to `%PerformanceGoal{}`. |
| `BurpeeTrainer.CurrentCapacity` | Type-specific 20-minute capacity estimate. |
| `BurpeeTrainer.PerformanceModel` | Builds capacity estimates and `%TrainingState{}` from history. |
| `BurpeeTrainer.TrainingState` | Type-specific levels, capacities, fatigue, confidence. |
| `BurpeeTrainer.PaceModel` | Type- and level-specific recommended pace ranges. |
| `BurpeeTrainer.CoachTargetPlanner` | Deterministic 20-minute goal-target suggestions. |
| `BurpeeTrainer.CatchUpPlanner` | Type-locked long catch-up planning. |
| `BurpeeTrainer.PlanSolver` | Deterministic session structure generation. |

## WeeklyTrainingContract

`WeeklyTrainingContract` tracks the fixed weekly contract only. It exposes:

- `contract/0`
- `status/2`
- `remaining_slots/2`
- `remaining_minutes/2`

A normal 20-minute session consumes one matching standard slot. A manual longer session counts toward weekly minutes, but marks the split as non-standard if it does not match the canonical 4×20 structure.

Non-standard weeks are allowed. The app reflects them honestly instead of auto-repairing them.

## Performance goals

Performance goals are separate from weekly volume. Existing persisted `goals` rows are converted to `%PerformanceGoal{}` by `Goals.to_performance_goal/1` and `Goals.get_active_performance_goal/2`.

Goals are type-specific:

- one active Six-count goal
- one active Navy SEAL goal

The coach and catch-up planners require a real active goal. They do not synthesize temporary goals.

## PerformanceModel

`PerformanceModel.current_capacity/3` estimates current 20-minute capacity per burpee type from comparable history.

Important rules:

- Six-count history does not affect Navy SEAL capacity.
- Navy SEAL history does not affect Six-count capacity.
- Manual longer sessions are not blindly treated as 20-minute capacity results.
- Low-history estimates carry lower confidence.

`PerformanceModel.build_training_state/1` produces `%TrainingState{}` with separate levels and capacities per type.

## CoachTargetPlanner

`CoachTargetPlanner` creates deterministic suggestions for one standard 20-minute session.

It uses:

- active type-specific performance goal
- current capacity
- recent history
- training state
- weekly status

It returns suggestions such as:

- `:on_track`
- `:recommended`
- `:safe_progress`
- `:stretch`
- `:maintenance`
- `:deload`

Home presents coach targets as a weekly split, not as “today” commands. For each active type-specific goal, Home shows one harder/recommended 20-minute session and one easier/safe 20-minute session. Extra variants should live on a planner/detail surface, not Home.

Coach targets are always 20 minutes. The coach does not generate 40-minute catch-up sessions. When the weekly contract has no remaining minutes, Home hides weekly split recommendations even if the week is non-standard.

## CatchUpPlanner

`CatchUpPlanner` is used only when the user explicitly asks to plan remaining work. Home only exposes catch-up planning on Saturday or Sunday, when there are 2 days left or less in the week.

The user must choose the burpee type first:

- Six-count
- Navy SEAL

The planner never chooses the type and never creates mixed-type plans.

Current behavior:

- one long selected-type session
- no 2×20 chunking
- no day/time scheduling
- no automatic split repair

Duration intensity factors for long catch-up sessions:

| Duration | Intensity factor |
| --- | ---: |
| 20 min | 100% |
| 30 min | 85% |
| 40 min | 75% |
| 60 min | 60% |
| 80+ min | 50% |

Example with 150 reps / 20 min current capacity:

| Duration | Target |
| --- | ---: |
| 30 min | 191 reps |
| 40 min | 225 reps |
| 60 min | 270 reps |
| 80 min | 300 reps |

Catch-up output is labeled honestly:

- `:preserves_contract`
- `:counts_but_non_standard`
- `:over_target`

A long manual catch-up session usually counts but is non-standard.

## PlanSolver

`PlanSolver` is deterministic. It does not use MILP, LP, MPS, or HiGHS.

It receives a chosen target and returns a rich `%PlanSolver.Solution{}` plus a concrete `%WorkoutPlan{}` structure.

The solver uses `PaceModel` as its pace source. `sec_per_burpee_override` is still supported for manual pace overrides and pins the pace exactly when supplied. Internal pace values remain floats, but user-facing pace displays use one decimal place for readability.

Solution output includes:

- `set_pattern`
- `rest_pattern_sec`
- `burpee_count`
- `pacing_style`
- `burpee_type`
- solver metadata
- generated `%WorkoutPlan{}`

For `:unbroken` plans, candidate set structures come from `PlanSolver.Search`: the rep target is split into `k` sets sized `base`/`base + 1`, never exceeding the preferred reps per set, so awkward targets taper down instead of leaving an orphan set (e.g. `140` reps at `8`/set becomes `14×[8] 4×[7]`, and `107` reps at `10`/set becomes `8×[10] 3×[9]`). When no within-preference split leaves useful recovery, larger sets up to a per-type maximum are tried as a scored-down fallback before the solver reports infeasibility. `BurpeeTrainer.PlanNotation` renders these structures in the compact `N×[reps,…]` notation used across the editor.

It preserves these invariants:

- total reps match the target
- the executable duration is exact: every set carries an integer recovery except the workout's final set, which carries none (the rest budget is distributed as `base`/`base + 1` seconds across the gaps)
- pace respects type-specific level bounds from `PaceModel`
- additional rests must land near valid boundaries

## Plan editor

The plan editor (`BurpeeTrainerWeb.PlansLive.Edit`) edits a `BurpeeTrainer.PlanEditor.Segments` list — work segments (`N×[reps,…]`) and rest segments — rather than raw blocks. Target changes re-run the solver; structure edits mark the plan custom and only re-balance pace and recovery against the targets. `Segments.balance/3` reports blocking problems (rep mismatch, impossible duration) and warnings (thin recovery) with one-tap fixes, and `Segments.to_plan_attrs/3` materializes segments into `blocks` + `steps` for saving.

## Plan metadata

Generated plans store metadata on `workout_plans`:

- `coach_suggestion_kind`
- `coach_target_reps`
- `plan_solver_metadata`

Metadata includes source information:

- `coach_target`
- `catch_up`

and durable debug fields such as:

- `solver_version: deterministic-v2`
- risk
- rationale
- catch-up split effect
- catch-up fatigue cost

The plan edit page renders this as a compact **Why this?** section.

## Home UI principles

Home is an action surface. It should not become a dashboard or option dump.

Current Home behavior:

- shows one primary weekly status card
- shows weekly split recommendations while weekly minutes remain
- hides recommendations when remaining minutes are 0, including non-standard complete weeks
- exposes catch-up planning only on Saturday/Sunday and only as explicit user action
- creates plans directly and navigates to the plan editor

Avoid reintroducing:

- multiple peer coach cards per type
- push/safe/stretch variants on Home
- day/time scheduling suggestions
- mixed catch-up plans
- 2×20 catch-up chunking

## Removed architecture

The following are intentionally removed from the active implementation:

- `BurpeeTrainer.PlanWizard`
- `BurpeeTrainer.ScheduleSolver`
- `BurpeeTrainer.PlanSolver.Lp`
- `BurpeeTrainer.Milp.*`
- HiGHS runtime dependency
- Thompson-sampling Home coach
- coach learning arms
- MILP weekly scheduling
- solver-selected days/times

Do not reintroduce these without a specific new requirement and tests proving deterministic scoring is insufficient.
