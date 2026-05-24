# Plan Editor State Redesign

## Purpose

Continue the `PlansLive.Edit` refactor by replacing the LiveView's loose editor assigns with an explicit `BurpeeTrainer.PlanEditor.State` struct and transition API.

The goal is to make the plan editor state machine testable outside LiveView while preserving the current user-visible behavior.

## Goals

- Model plan-editor state explicitly in a struct instead of many independent LiveView assigns.
- Move editor transitions into `BurpeeTrainer.PlanEditor` as pure functions where practical.
- Keep LiveView responsible for route/session context, rendering, forms, flashes, navigation, and persistence calls.
- Preserve existing plan editor behavior during migration.
- Add pure unit tests for state initialization and transitions.

## Non-goals

- Redesign the plan editor UI.
- Replace Ecto changesets for form validation.
- Change database schema.
- Rewrite every render helper or split templates in this pass.
- Change final persistence semantics in `BurpeeTrainer.Workouts`.

## State Model

Introduce a state struct, likely in `BurpeeTrainer.PlanEditor.State`:

```elixir
%BurpeeTrainer.PlanEditor.State{
  plan: nil | %BurpeeTrainer.Workouts.WorkoutPlan{},
  input: BurpeeTrainer.PlanEditor.input(),
  level: atom(),
  manual_edit?: boolean(),
  solver_error: nil | term(),
  solver_solution: nil | BurpeeTrainer.PlanSolver.Solution.t(),
  derived: BurpeeTrainer.PlanEditor.Derived.t(),
  expanded_blocks: MapSet.t(integer()),
  open_block_menu: nil | integer()
}
```

The exact field types may be refined while implementing, but the struct should keep the editor's core state in one value. Avoid introducing a generic map state.

A derived struct may be introduced if it keeps computed display facts coherent:

```elixir
%BurpeeTrainer.PlanEditor.Derived{
  summary: map(),
  duration_ok?: boolean(),
  reps_ok?: boolean(),
  can_save?: boolean()
}
```

Derived values should be recomputed by transitions that affect plan content.

## Transition API

`BurpeeTrainer.PlanEditor` becomes the editor state machine. Initial public API target:

```elixir
new(level, params)
from_plan(plan, level)
change_basics(state, params)
pick_type(state, burpee_type)
pick_pacing(state, pacing_style)
add_rest(state)
remove_rest(state, index)
change_rest(state, params)
set_pace_override(state, pace)
enable_manual_edit(state)
copy_block(state, index)
copy_set(state, block_index, set_index)
derived(state)
```

Expected return shape for transitions:

```elixir
{:ok, state}
{:error, reason, state}
```

Use atoms or tagged tuples for expected error reasons. Avoid stringly-typed domain errors.

The previous refactor introduced refined parser modules such as `BurpeeTrainer.BurpeeType`, `BurpeeTrainer.Duration`, and `BurpeeTrainer.Mood`. Follow that pattern for editor boundary parsing: parse raw params once, then thread refined values through transitions.

## LiveView Boundary

`BurpeeTrainerWeb.PlansLive.Edit` remains responsible for:

- reading current user/current route params;
- computing the user's current level;
- assigning `%PlanEditor.State{}` into the socket;
- building `to_form/1` values for HEEx;
- flashes and navigation;
- final save/delete/duplicate persistence through `BurpeeTrainer.Workouts`;
- rendering HEEx.

`BurpeeTrainer.PlanEditor` owns:

- editor input;
- solver calls and regeneration decisions;
- derived duration and constraint calculations;
- rest editing state;
- manual edit transitions;
- block/set copy manipulation;
- expanded/open menu state if those remain part of editor state.

## Migration Strategy

Implement incrementally to reduce risk:

1. Introduce `%PlanEditor.State{}` and initialize it from the current new/edit mount paths.
2. Mirror existing assigns from the state so templates continue to work.
3. Move low-risk transitions first: type/pacing picks, pace override, rest add/remove/change.
4. Move solver/regeneration transitions.
5. Move manual block/set editing transitions.
6. Remove old loose assigns only after no code reads them.

Each phase should keep existing LiveView behavior passing before moving to the next transition group.

## Testing Strategy

Add pure unit tests for `BurpeeTrainer.PlanEditor` and state transitions:

- `new/2` builds the same default state currently used by the new-plan path.
- `from_plan/2` preserves persisted plan values.
- `change_basics/2` updates input and regenerates solver-backed blocks.
- `pick_type/2` updates burpee type and resets reps-per-set appropriately.
- `pick_pacing/2` updates pacing style and regenerates.
- `add_rest/1`, `remove_rest/2`, and `change_rest/2` update rest state and regenerate.
- manual edit transitions do not unexpectedly regenerate user-edited blocks.
- `copy_block/2` and `copy_set/3` preserve positions and derived totals.

Keep existing LiveView tests passing. Add LiveView smoke tests only where a transition lacks coverage through current tests, and prefer stable DOM IDs/outcomes over raw HTML assertions.

Final verification:

- focused `PlanEditor` tests;
- `mix test test/burpee_trainer_web/live`;
- `mix precommit`.

## Success Criteria

- `PlansLive.Edit` stores editor state primarily in `%PlanEditor.State{}`.
- The largest editor transitions are covered by pure unit tests.
- Existing user-visible plan editor behavior remains unchanged.
- `mix precommit` passes.
