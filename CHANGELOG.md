# Changelog

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
