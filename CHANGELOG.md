# Changelog

## 2026-06-08 — Deterministic intelligence layer

- Removed the MILP/HiGHS infrastructure and old `PlanSolver.Lp`; `PlanSolver` now uses deterministic candidate/rest placement with rich solution metadata, PaceModel-backed pace bounds, manual pace overrides, and human-shaped non-uniform set patterns.
- Removed the old Thompson-sampling coach modules and Home coach cards now use `CoachTargetPlanner` with active type-specific performance goals.
- Added `WeeklyTrainingContract`, `PerformanceModel`, `TrainingState`, `PaceModel`, `CoachTargetPlanner`, and type-locked `CatchUpPlanner`.
- Catch-up planning now creates one long selected-type session only, with duration intensity factors: 20 min 100%, 30 min 85%, 40 min 75%, 60 min 60%, 80+ min 50%.
- Home coach and catch-up actions create real workout plans and navigate to the plan editor.
- Added generated plan metadata (`coach_suggestion_kind`, `coach_target_reps`, `plan_solver_metadata`) and a compact “Why this?” section on plan edit.

## 2026-05-21 — PlanSolver: joint MILP with solver-chosen pace

- Replaced `BurpeeTrainer.PlanWizard` with `BurpeeTrainer.PlanSolver`.
- `sec_per_burpee` is no longer a user input. The solver finds the optimal pace bounded below by `PlanSolver.sustainable_ceiling/1` (level-derived: level_1a=8.0s down to graduated=3.70s).
- Extended LP formulation: `p` (pace) is a free variable in the same problem as rest distribution, finding the true joint optimum rather than two sequential optima.
- New shared LP infrastructure: `BurpeeTrainer.Milp.{Problem, Mps, Highs}` — reusable for future ScheduleSolver.
- UI: Layer 1 shows level + min pace hint instead of sec/burpee input. Layer 3 shows solver-chosen pace, set structure, and rest as a read-only summary.
- Deleted: `BurpeeTrainer.PlanWizard` and all sub-modules.

## 2026-05-11 — MILP plan wizard

- Replaced the bespoke constraint-solver pipeline (`Reservation`, `Constraints/*`) with a MILP model serialized to MPS and solved by HiGHS.
- New modules: `PlanWizard.Lp`, `PlanWizard.Lp.Problem`, `PlanWizard.Mps`, `PlanWizard.Highs`.
- Added `fatigue_factor` field to `WorkoutPlan` and `PlanInput`. Biases rest distribution toward later slots in the workout via a linear weight ramp applied to the soft objective. Three-stop control (None / Mild / Strong) in the plan edit form. Default `0.0` preserves existing behavior.
- HiGHS CLI is now a runtime dependency; see README for build/install instructions.
- Deleted: `Reservation`, `Constraints.MinimizePlacementError`, `Constraints.MinimizeRestDeviation`, `Constraints.RestNonNegative`, `Constraints.TotalDuration`, `Constraints.ValidPlacement`. `Constraints.PaceFloor` retained as the pre-LP feasibility gate.

## 2026-05-09 — Constraint-solver refactor (FEAT_CONTRAINED_SOLVER)

Replaced the procedural `:even` / `:unbroken` branching in
`BurpeeTrainer.PlanWizard` with a unified **variables → constraints → solvers**
pipeline. Both pacing styles now flow through the same code path; their only
difference is the slot-weight vector supplied as data by `Styles.weight_vector/3`.

### New modules

- `PlanWizard.PlanInput` — extracted struct.
- `PlanWizard.SlotModel` — universal representation: `total_reps − 1`
  inter-rep slots, weight vector, reservations, distributed `slot_rests`.
- `PlanWizard.Styles` — `weight_vector(style, total_reps, reps_per_set)`.
  `:even` → all 1.0; `:unbroken` → 1.0 only at `k × reps_per_set`.
- `PlanWizard.Reservation` — places `additional_rests` at the nearest slot
  (±30s tolerance). `:even` uses `prev_slot + 1` bumping; `:unbroken` uses
  independent nearest-boundary placement.
- `PlanWizard.Solver` — pipeline: `PaceFloor.check_input` → `build_slot_model`
  → `Reservation.place` → closed-form `distribute_remaining_budget` →
  `RestNonNegative` → `TotalDuration` → `ValidPlacement`.
- `PlanWizard.Apply` — collapses a solved `%SlotModel{}` into `%WorkoutPlan{}`
  with `%Block{}` / `%Set{}`. Reads structural fields from the model; per-set
  numerics use the legacy closed-form formulas to keep regression tolerances
  tight (`sec_per_rep` to ±1 ms, total duration to ±0.1s).
- `PlanWizard.Errors` — centralised error strings, preserving legacy wording.
- `PlanWizard.Constraints.{PaceFloor,RestNonNegative,TotalDuration,ValidPlacement}`
  — hard constraints, each `check/1 :: :ok | {:error, [msg]}`.
- `PlanWizard.Constraints.{MinimizePlacementError,MinimizeRestDeviation}` —
  soft penalties, computed and stored on the model (not yet wired into solver
  decisions).

### Rewritten

- `PlanWizard` (392 → 134 lines): thin wrapper that resolves
  `reps_per_set` defaults, validates positivity, short-circuits the degenerate
  one-set `:unbroken` case (where `reps_per_set ≥ total_reps`), and otherwise
  delegates to `Solver.solve/2` then `Apply.to_workout_plan/2`. Public
  helpers `validate_pace/2` and `default_reps_per_set/1` preserved.

### Deleted

Legacy private helpers in `plan_wizard.ex`: `build_even`,
`build_even_with_rests`, `build_unbroken`, `build_unbroken_sets`,
`find_even_splits`, `build_even_segments`, `inject_unbroken_rests`,
`build_set_boundaries`, `find_all_boundary_injections`,
`find_nearest_boundary`, `apply_injections`, `wrap_plan`, `encode_rests`.

### Test results

- `test/burpee_trainer/plan_wizard_test.exs` — **26/26 unmodified**
  (regression contract).
- New tests: `styles_test.exs`, `reservation_test.exs`, `solver_test.exs`,
  `apply_test.exs` — all green.
- Combined PlanWizard + Planner: **114/114**.
- `mix compile --warnings-as-errors`, `mix format`, `mix deps.unlock --unused`
  all clean.

### Deferred (per plan)

DP conflict solver, replacing `Planner.fit_rest_to_duration/2`, StreamData
property tests, new pacing styles (`:pyramid`, `:tabata`), soft-constraint
penalty wiring into solver decisions, fatigue model.

---

## UI Polish — Stats, Workouts, Plan Editor (2026-05-21)

### Stats screen

- Removed "How you're tracking." subtitle; level badge moved into streak card header
- Goal cards: state leads (number/achieved), type label demoted to tertiary
- "Goal reached" card: trophy icon, achieved target shown as `N burpees`, completion date
- "Trends" section header added; "Sessions" floating header removed
- Weekly minutes chart: fixed viewBox (always 300px wide), 12 slots always rendered, sparse data fills from right, 120 label removed, "80" label on LHS beside dashed target line
- Progress chart: gridline y-axis labels removed for target values; target numbers anchored to right end of dashed lines, color-matched to series
- `Fmt.burpee_type/1`: "6-count" → "6-Count" for consistent casing with "Navy SEAL"

### Workouts screen

- "Pick something to do." subtitle removed
- Level filter pill labels: "1A/1B/1C/1D" → "L1A/L1B/L1C/L1D" for consistency with "L2/L3/L4"

### Plan editor (`/workouts/new`, `/workouts/:id/edit`)

- Single input card with `divide-y` hairlines replacing three separate cards (Basics, Additional rests, Advanced)
- Plan name is the page title — inline editable input, updates on change
- Fatigue bias moved behind `▸ Advanced` disclosure (collapsed by default)
- Additional rests: compact inline row, trash icon instead of "× remove"
- Solution card wraps blocks + save button; solution header shows `✓ Solution · 20:01 · 150 burpees`
- Block actions (Duplicate, Remove) moved to `⋯` overflow menu
- Set rows: dense single-line format with `Reps | Rest [s]` column headers; `sec/rep` and `sec/burpee` hidden (submitted as hidden inputs, defaulting to plan-level pace for new sets)
- Uniform sets collapsed to summary line ("10 × 15 reps · 29s rest") with "Edit sets" affordance
- Footer row shows live `duration · burpees` status beside Save button
- Stale solver error cleared on manual block edits
- Picker pattern unified: Burpee type, Pacing, Fatigue bias all use same pill-strip component
- Cancel demoted to plain text link
- Section numbers dropped from headers
- Native number input spinners hidden globally via CSS

### Tests

- 261 tests, 0 failures throughout
