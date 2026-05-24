# Plan Editor State Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plan editor's loose LiveView assigns with an explicit `PlanEditor.State` and move editor transitions into pure, testable code.

**Architecture:** Introduce state structs under `BurpeeTrainer.PlanEditor`, migrate initialization first, then move transition groups from `PlansLive.Edit` into the editor state machine. The LiveView keeps rendering, forms, flashes, navigation, and persistence; `PlanEditor` owns editor input, regeneration, derived facts, rest editing, and block/set manipulation.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto changesets, ExUnit, Phoenix.LiveViewTest, jj.

---

## File Structure

- Modify: `lib/burpee_trainer/plan_editor.ex` — add `%PlanEditor.State{}`, `%PlanEditor.Derived{}`, initialization, transition functions, and derived helpers.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex` — store `:editor` state, mirror old assigns while migrating, then delegate event transitions to `PlanEditor`.
- Modify: `test/burpee_trainer/plan_editor_test.exs` — extend pure unit coverage for state initialization and transitions.
- Existing tests: `test/burpee_trainer_web/live` — keep LiveView behavior passing.

## Task 1: Introduce PlanEditor State

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write failing state initialization tests**

Add to `test/burpee_trainer/plan_editor_test.exs`:

```elixir
describe "state initialization" do
  test "new/2 builds default editor state" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    assert %PlanEditor.State{} = state
    assert state.plan == nil
    assert state.level == :level_1a
    assert state.input.name == "New plan"
    assert state.input.burpee_type == :six_count
    assert state.manual_edit? == false
    assert state.expanded_blocks == MapSet.new()
    assert state.open_block_menu == nil
  end

  test "new/2 applies coach params" do
    {:ok, state} = PlanEditor.new(:level_1a, %{"count" => "75", "pace" => "2.5"})

    assert state.input.burpee_count_target == 75
    assert state.input.sec_per_burpee_override == 2.5
  end

  test "from_plan/2 builds edit state from persisted plan" do
    user = user_fixture()
    plan = plan_fixture(user, %{"name" => "Persisted", "burpee_count_target" => 42})

    {:ok, state} = PlanEditor.from_plan(plan, :level_2)

    assert state.plan.id == plan.id
    assert state.level == :level_2
    assert state.input.name == "Persisted"
    assert state.input.burpee_count_target == 42
  end
end
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs
```

Expected: FAIL because `PlanEditor.State`, `new/2`, and `from_plan/2` do not exist.

- [ ] **Step 3: Add state structs and initialization functions**

In `lib/burpee_trainer/plan_editor.ex`, add nested modules and functions:

```elixir
defmodule State do
  @moduledoc "Plan editor state."

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanEditor.Derived
  alias BurpeeTrainer.PlanSolver.Solution
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [:input, :level, :derived]
  defstruct [
    :plan,
    :input,
    :level,
    :solver_error,
    :solver_solution,
    :derived,
    manual_edit?: false,
    expanded_blocks: MapSet.new(),
    open_block_menu: nil
  ]

  @type t :: %__MODULE__{
          plan: WorkoutPlan.t() | nil,
          input: PlanEditor.input(),
          level: atom(),
          manual_edit?: boolean(),
          solver_error: term() | nil,
          solver_solution: Solution.t() | nil,
          derived: Derived.t(),
          expanded_blocks: MapSet.t(integer()),
          open_block_menu: integer() | nil
        }
end

defmodule Derived do
  @moduledoc "Computed editor facts used by the LiveView."

  defstruct summary: nil,
            duration_ok?: false,
            reps_ok?: false,
            can_save?: false

  @type t :: %__MODULE__{
          summary: map() | nil,
          duration_ok?: boolean(),
          reps_ok?: boolean(),
          can_save?: boolean()
        }
end

@spec new(atom(), map()) :: {:ok, State.t()}
def new(level, params) do
  state = %State{
    input: default_input() |> apply_coach_params(params),
    level: level,
    derived: %Derived{}
  }

  {:ok, state}
end

@spec from_plan(WorkoutPlan.t(), atom()) :: {:ok, State.t()}
def from_plan(%WorkoutPlan{} = plan, level) do
  state = %State{
    plan: plan,
    input: input_from_plan(plan),
    level: level,
    derived: %Derived{}
  }

  {:ok, state}
end
```

- [ ] **Step 4: Store editor state in LiveView while mirroring old assigns**

In `PlansLive.Edit`, update `load_plan/2` paths:

```elixir
{:ok, editor} = PlanEditor.from_plan(plan, socket.assigns.level)
plan_input = editor.input
```

and:

```elixir
{:ok, editor} = PlanEditor.new(socket.assigns.level, params)
plan_input = editor.input
```

Assign `:editor` in both branches:

```elixir
|> assign(:editor, editor)
|> assign(:plan_input, plan_input)
```

Keep existing old assigns for now so templates continue to work.

- [ ] **Step 5: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(plans): introduce editor state struct"
jj new
```

## Task 2: Move Low-Risk Input Transitions

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write transition tests**

Add tests:

```elixir
describe "low-risk input transitions" do
  test "pick_type updates type and resets reps per set" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.pick_type(state, "navy_seal")

    assert state.input.burpee_type == :navy_seal
    assert state.input.reps_per_set == PlanSolver.default_reps_per_set(:navy_seal)
  end

  test "pick_pacing updates pacing style" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.pick_pacing(state, "unbroken")

    assert state.input.pacing_style == :unbroken
  end

  test "set_pace_override accepts positive pace and rejects invalid pace" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.set_pace_override(state, "2.5")
    assert state.input.sec_per_burpee_override == 2.5

    {:error, {:invalid_pace, "bad"}, unchanged} = PlanEditor.set_pace_override(state, "bad")
    assert unchanged.input.sec_per_burpee_override == 2.5
  end
end
```

- [ ] **Step 2: Implement transition functions**

In `PlanEditor`:

```elixir
@spec pick_type(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
def pick_type(%State{} = state, type) do
  case BurpeeTrainer.BurpeeType.parse(type) do
    {:ok, burpee_type} ->
      input = %{
        state.input
        | burpee_type: burpee_type,
          reps_per_set: PlanSolver.default_reps_per_set(burpee_type)
      }

      {:ok, %{state | input: input}}

    {:error, reason} ->
      {:error, reason, state}
  end
end

@spec pick_pacing(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
def pick_pacing(%State{} = state, style) when style in ["even", "unbroken", :even, :unbroken] do
  pacing_style = if is_binary(style), do: String.to_existing_atom(style), else: style
  {:ok, %{state | input: %{state.input | pacing_style: pacing_style}}}
end

def pick_pacing(%State{} = state, style), do: {:error, {:invalid_pacing_style, style}, state}

@spec set_pace_override(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
def set_pace_override(%State{} = state, pace) do
  case parse_positive_float(pace) do
    {:ok, pace} -> {:ok, %{state | input: %{state.input | sec_per_burpee_override: pace}}}
    {:error, reason} -> {:error, reason, state}
  end
end
```

Add private parser:

```elixir
defp parse_positive_float(value) when is_binary(value) do
  case Float.parse(value) do
    {number, _rest} when number > 0 -> {:ok, number}
    _ -> {:error, {:invalid_pace, value}}
  end
end

defp parse_positive_float(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
defp parse_positive_float(value), do: {:error, {:invalid_pace, value}}
```

- [ ] **Step 3: Delegate matching LiveView events**

In `PlansLive.Edit`, update `pick_type`, `pick_pacing`, and `set_pace_override` handlers to call `PlanEditor` first, then mirror `editor.input` back to existing assigns. Keep the existing `regenerate(socket)` call until Task 3 moves regeneration.

Example shape:

```elixir
case PlanEditor.pick_type(socket.assigns.editor, type) do
  {:ok, editor} ->
    socket = socket |> assign(:editor, editor) |> assign(:plan_input, editor.input)
    {:noreply, regenerate(socket)}

  {:error, _reason, _editor} ->
    {:noreply, socket}
end
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): move basic editor transitions"
jj new
```

## Task 3: Move Rest Transitions

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write rest transition tests**

Add tests:

```elixir
describe "rest transitions" do
  test "add_rest appends default rest" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.add_rest(state)

    assert [%{target_min: 10, rest_sec: 60}] = state.input.additional_rests
  end

  test "remove_rest drops rest by index" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.add_rest(state)

    {:ok, state} = PlanEditor.remove_rest(state, "0")

    assert state.input.additional_rests == []
  end

  test "change_rest updates a rest by index" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.add_rest(state)

    {:ok, state} =
      PlanEditor.change_rest(state, %{
        "0" => %{"target_min" => "12", "rest_sec" => "90"}
      })

    assert [%{target_min: 12, rest_sec: 90}] = state.input.additional_rests
  end
end
```

- [ ] **Step 2: Implement rest transition functions**

Move the existing rest parsing/update logic from `PlansLive.Edit` into `PlanEditor.add_rest/1`, `remove_rest/2`, and `change_rest/2`. Preserve current default values and invalid-input behavior.

- [ ] **Step 3: Delegate rest LiveView handlers**

Update `add_rest`, `remove_rest`, and `change_rest` handlers to call `PlanEditor`, assign `:editor` and `:plan_input`, then call existing `regenerate(socket)`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): move rest editor transitions"
jj new
```

## Task 4: Move Regeneration and Derived State

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write regeneration tests**

Add tests:

```elixir
describe "regeneration and derived state" do
  test "regenerate creates a solver solution and derived summary" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.regenerate(state)

    assert state.solver_error == nil
    assert state.solver_solution != nil
    assert state.derived.summary != nil
  end

  test "change_basics updates input then regenerates" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} =
      PlanEditor.change_basics(state, %{
        "plan" => %{
          "name" => "Changed",
          "target_duration_min" => "25",
          "burpee_count_target" => "120",
          "reps_per_set" => "10"
        }
      })

    assert state.input.name == "Changed"
    assert state.input.target_duration_min == 25
    assert state.input.burpee_count_target == 120
    assert state.solver_solution != nil
  end
end
```

- [ ] **Step 2: Implement regeneration in PlanEditor**

Move the pure portions of `regenerate/1` and `assign_derived/1` into `PlanEditor.regenerate/1`, `change_basics/2`, and `derived/1`. Keep `to_form/1` and changeset construction in the LiveView if it depends on Phoenix form state.

- [ ] **Step 3: Update LiveView regeneration path**

Replace direct solver/regeneration logic in `PlansLive.Edit` with calls to `PlanEditor.regenerate/1`. Mirror state fields back into assigns required by existing templates:

```elixir
socket
|> assign(:editor, editor)
|> assign(:plan_input, editor.input)
|> assign(:solver_error, editor.solver_error)
|> assign(:solver_solution, editor.solver_solution)
```

Keep template compatibility during this task.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): move editor regeneration state"
jj new
```

## Task 5: Move Manual Block and Set Transitions

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write manual edit transition tests**

Add tests that build a regenerated state and verify:

```elixir
describe "manual edit transitions" do
  test "enable_manual_edit marks state manual" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})

    {:ok, state} = PlanEditor.enable_manual_edit(state)

    assert state.manual_edit? == true
  end

  test "copy_block returns manual state with another block" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.regenerate(state)
    block_count = length(Ecto.Changeset.get_field(state.form_source, :blocks, []))

    {:ok, state} = PlanEditor.copy_block(state, "0")

    assert state.manual_edit? == true
    assert length(Ecto.Changeset.get_field(state.form_source, :blocks, [])) == block_count + 1
  end
end
```

If `form_source` is not the chosen state field name after Task 4, use the actual field that holds editable plan/changset source. Keep the assertion focused on behavior: copying increases block count and enters manual mode.

- [ ] **Step 2: Implement manual transition functions**

Move the pure logic for `enable_manual_edit`, `copy_block`, and `copy_set` from `PlansLive.Edit` into `PlanEditor`. These functions should return `{:ok, state}` or `{:error, reason, state}` and set `manual_edit?: true` for manual mutations.

- [ ] **Step 3: Delegate manual LiveView handlers**

Update `enable_manual_edit`, `copy_block`, and `copy_set` handlers to call `PlanEditor`, mirror state back into assigns, and preserve existing form behavior.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): move manual editor transitions"
jj new
```

## Task 6: Remove Obsolete Loose Assigns Where Safe

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Audit assign reads**

Run:

```bash
rg "assigns\.(plan_input|manual_edit|solver_error|solver_solution|expanded_blocks|open_block_menu)|@(plan_input|manual_edit|solver_error|solver_solution|expanded_blocks|open_block_menu)" lib/burpee_trainer_web/live/plans_live/edit.ex
```

Record which assigns are still template-facing and which can be replaced by `@editor` reads.

- [ ] **Step 2: Replace safe reads with editor state**

For assigns used only inside callbacks, replace them with `socket.assigns.editor.<field>`. Keep template-facing assigns if changing HEEx would make the diff too large.

- [ ] **Step 3: Add regression test for editor assign presence**

Add a LiveView smoke test if no existing test mounts the plan editor after these changes. Prefer:

```elixir
assert has_element?(view, "#plan-editor-form")
```

Use the actual stable form id present in the template.

- [ ] **Step 4: Run verification**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live
mix precommit
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): prefer editor state assigns"
jj new
```

## Task 7: Final Verification

**Files:** no planned changes.

- [ ] **Step 1: Run full verification**

Run:

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 2: Inspect jj state**

Run:

```bash
jj diff --stat
jj status
jj log -r 'ancestors(@, 8)' --no-graph
```

Expected: clean working copy or only an empty `@` on top of completed commits.

- [ ] **Step 3: Do not create an empty commit**

If no files changed during final verification, do not run `jj describe` for an empty commit.

## Self-Review

Spec coverage:

- Explicit state struct: Task 1.
- Low-risk transitions: Tasks 2 and 3.
- Solver/regeneration and derived state: Task 4.
- Manual block/set editing transitions: Task 5.
- Removing loose assigns where safe: Task 6.
- Final verification: Task 7.

Placeholder scan: no unresolved placeholders are present. Where implementation names may differ after earlier tasks, the plan explicitly instructs the worker to use the actual chosen field name and preserve the tested behavior.

Type consistency: this plan consistently uses `PlanEditor.State`, `PlanEditor.Derived`, `new/2`, `from_plan/2`, `pick_type/2`, `pick_pacing/2`, `set_pace_override/2`, `add_rest/1`, `remove_rest/2`, `change_rest/2`, `regenerate/1`, `change_basics/2`, `enable_manual_edit/1`, `copy_block/2`, and `copy_set/3`.
