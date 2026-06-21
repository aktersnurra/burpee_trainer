## Critical

- None. No blockers found in the working-copy diff.

## Important

- `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex:304-308` / `lib/burpee_trainer_web/live/plans_live/edit.ex:1545-1562` — rendering the prescription timeline calls `timeline_rest_edge_available?/4` for each edge, and that helper constructs a `PlanSolverInput` and runs `PlanSolver.solve/1`. That makes ordinary LiveView renders perform N solver runs, and the cost grows with timeline row count and every phx-change/assign update. Smallest safe fix: precompute edge availability once in `plan_solution_card/1` when `@timeline_rows` are built, store it on each row/edge (or in a map keyed by row index), and have the HEEx only read the precomputed boolean.

## Minor

- `lib/burpee_trainer_web/live/plans_live/edit.ex:640-646` — `accept_rest_suggestion` regenerates twice: first via `PlanEditor.regenerate(editor)` and then again through the LiveView `regenerate/1` pipeline after `put_editor(editor)`. This is redundant solver work and can briefly discard/use duplicated state paths. Smallest safe fix: remove the explicit `PlanEditor.regenerate/1` call and let `regenerate/1` do it, or keep the regenerated editor and only rebuild the form without solving again.

- `lib/burpee_trainer_web/live/overview_live.ex:385-396` — `workout_plan_attrs/1` persists generated coach/catch-up plans with blocks but omits `plan.steps`, while `Workouts.save_generated_plan/2` includes steps at `lib/burpee_trainer/workouts.ex:590-598`. With `PlanSolver.Apply.from_execution/3`, steps are now part of the canonical persisted representation, so this path can silently drop first-class timeline/rest ordering for overview-generated plans. Smallest safe fix: include a `"steps" => ...` entry in `workout_plan_attrs/1` using the same fields as `save_generated_plan_steps/1`, or reuse a shared generated-plan attrs helper.

- `test/burpee_trainer/plan_solver_test.exs:181-207` and `test/burpee_trainer/plan_solver_test.exs:400-410` — the new execution/persisted-plan round-trip grid does not cover `additional_rests`, and the only `PlanSolver.solve/1` rest test exercises the default even path. The unbroken/additional-rest cases in `test/burpee_trainer/plan_solver/apply_test.exs:170-219` call legacy `Apply.to_workout_plan/5`, not the new `solve -> Execution -> Apply.from_execution` path. Smallest safe fix: add at least one `PlanSolver.solve/1` assertion for unbroken pacing with an accepted additional rest, checking execution duration, plan summary duration, rest step count/order, and no final auto-rest regression.
