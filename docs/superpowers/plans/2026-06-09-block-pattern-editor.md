# Block Pattern Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a solver-level block pattern preference and graph inspector so users can define patterns like `4 + 3`, have the solver compute repeats/pace/rest, and remove the old “Show structure” editor.

**Architecture:** Extend `PlanSolver.Input` with a preferred block pattern, teach `PlanSolver.Apply` to generate block definitions/steps from that pattern, and drive the LiveView from this input instead of low-level block forms. The graph remains the primary output, while a stable inspector edits the pattern preference and explicit additional rests rerun the solver.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto changesets, ExUnit, Phoenix.LiveViewTest, existing `jj` workflow.

---

## File Map

- Modify `lib/burpee_trainer/plan_solver/input.ex`
  - Add `block_pattern` to the solver input struct/types.
- Modify `lib/burpee_trainer/plan_editor.ex`
  - Add pattern state to editor input.
  - Parse pattern-edit events.
  - Feed pattern into solver.
  - Infer pattern from existing plans for edit pages.
- Modify `lib/burpee_trainer/plan_solver.ex`
  - Validate pattern input.
  - Use pattern total for candidate generation/remainder handling.
- Modify `lib/burpee_trainer/plan_solver/apply.ex`
  - Build blocks/steps from preferred pattern.
  - Generate automatic remainder block.
  - Keep additional rests first-class.
- Modify `lib/burpee_trainer_web/live/plans_live/edit.ex`
  - Add LiveView events for pattern set add/remove/change.
  - Remove old `Show structure` state/actions from normal UX.
  - Keep graph/inspector stable while editing.
- Modify `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
  - Replace old structure panel with pattern editor/inspector.
  - Remove `Show structure` button.
- Modify `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
  - Stop rendering it in normal flow. Keep file only if still used by tests/legacy route; otherwise remove in a later cleanup task.
- Modify tests:
  - `test/burpee_trainer/plan_solver_test.exs`
  - `test/burpee_trainer/plan_solver/apply_test.exs`
  - `test/burpee_trainer_web/live/workouts_live_test.exs`

---

## Task 1: Add block pattern to solver input

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/input.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Write failing input/solver validation tests**

Add tests near existing solver input/solve tests:

```elixir
test "even solve accepts preferred block pattern" do
  {:ok, sol} =
    PlanSolver.solve(
      input(%{
        pacing_style: :even,
        burpee_type: :navy_seal,
        burpee_count_target: 70,
        target_duration_min: 20,
        block_pattern: [4, 3]
      })
    )

  assert sol.plan.blocks |> Enum.map(&Enum.map(&1.sets, fn set -> set.burpee_count end)) == [[4, 3]]
  assert [%{kind: :block_run, repeat_count: 10}] = sol.plan.steps
end

test "rejects non-positive preferred block pattern entries" do
  assert {:error, [msg]} =
           PlanSolver.solve(
             input(%{
               pacing_style: :even,
               burpee_count_target: 70,
               block_pattern: [4, 0]
             })
           )

  assert msg =~ "block pattern"
end
```

If `input/1` helper does not pass unknown keys into `%Input{}`, update the helper in the test file to include `block_pattern` explicitly.

- [ ] **Step 2: Run the failing tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: fails because `%PlanSolver.Input{}` has no `block_pattern` field or solver ignores it.

- [ ] **Step 3: Add `block_pattern` to input struct**

In `lib/burpee_trainer/plan_solver/input.ex`, add a field with a conservative default:

```elixir
defstruct [
  :name,
  :burpee_type,
  :level,
  :target_duration_min,
  :burpee_count_target,
  :pacing_style,
  :reps_per_set,
  :additional_rests,
  :sec_per_burpee_override,
  block_pattern: nil
]
```

Update the type to include:

```elixir
block_pattern: [pos_integer()] | nil
```

- [ ] **Step 4: Validate pattern in `PlanSolver.solve/1`**

In `lib/burpee_trainer/plan_solver.ex`, add validation after `resolve_reps_per_set(input)` and before `preflight_check(input)`:

```elixir
with {:ok, reps_per_set} <- resolve_reps_per_set(input),
     :ok <- validate_block_pattern(input.block_pattern),
     :ok <- preflight_check(input),
     ...
```

Add helper:

```elixir
defp validate_block_pattern(nil), do: :ok

defp validate_block_pattern(pattern)
     when is_list(pattern) and pattern != [] and length(pattern) <= 12 do
  if Enum.all?(pattern, &(is_integer(&1) and &1 > 0)) do
    :ok
  else
    {:error, ["block pattern must contain positive rep counts"]}
  end
end

defp validate_block_pattern(_pattern),
  do: {:error, ["block pattern must contain 1 to 12 positive rep counts"]}
```

- [ ] **Step 5: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: validation test passes; generation test may still fail until Task 2.

---

## Task 2: Generate blocks and steps from the preferred pattern

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/apply.ex`
- Modify: `lib/burpee_trainer/plan_solver.ex`
- Test: `test/burpee_trainer/plan_solver/apply_test.exs`
- Test: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Write failing generation tests**

Add to `test/burpee_trainer/plan_solver/apply_test.exs`:

```elixir
test "even preferred block pattern produces reusable block run" do
  input = %Input{
    name: "Pattern",
    burpee_type: :navy_seal,
    level: :level_1a,
    target_duration_min: 20,
    burpee_count_target: 70,
    pacing_style: :even,
    reps_per_set: nil,
    block_pattern: [4, 3],
    additional_rests: [],
    sec_per_burpee_override: nil
  }

  {:ok, plan} = Apply.to_workout_plan(input, 8.0, [70], [], [])

  [block] = plan.blocks
  assert Enum.map(block.sets, & &1.burpee_count) == [4, 3]
  assert [%{kind: :block_run, block_position: 1, repeat_count: 10}] = plan.steps
  assert BurpeeTrainer.Planner.summary(plan).burpee_count_total == 70
  assert round(BurpeeTrainer.Planner.summary(plan).duration_sec_total) == 1200
end

test "preferred block pattern creates automatic remainder block" do
  input = %Input{
    name: "Pattern remainder",
    burpee_type: :navy_seal,
    level: :level_1a,
    target_duration_min: 20,
    burpee_count_target: 75,
    pacing_style: :even,
    reps_per_set: nil,
    block_pattern: [4, 3],
    additional_rests: [],
    sec_per_burpee_override: nil
  }

  {:ok, plan} = Apply.to_workout_plan(input, 8.0, [75], [], [])

  assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
           [4, 3],
           [4, 1]
         ]

  assert Enum.map(plan.steps, &{&1.kind, &1.block_position, &1.repeat_count}) == [
           {:block_run, 1, 10},
           {:block_run, 2, 1}
         ]

  assert BurpeeTrainer.Planner.summary(plan).burpee_count_total == 75
end
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs --trace
```

Expected: fails because `Apply` ignores `block_pattern`.

- [ ] **Step 3: Add pattern helpers in `PlanSolver.Apply`**

Add helpers near `build_even/3`:

```elixir
defp preferred_pattern(%Input{block_pattern: pattern}) when is_list(pattern) and pattern != [],
  do: pattern

defp preferred_pattern(%Input{pacing_style: :unbroken, reps_per_set: reps}) when is_integer(reps) and reps > 0,
  do: [reps]

defp preferred_pattern(%Input{burpee_count_target: reps}), do: [reps]

defp split_pattern(total_reps, pattern) do
  block_total = Enum.sum(pattern)
  full_repeats = div(total_reps, block_total)
  remainder = rem(total_reps, block_total)

  remainder_pattern =
    if remainder > 0 do
      pattern
      |> Enum.reduce_while({[], remainder}, fn reps, {acc, remaining} ->
        cond do
          remaining == 0 -> {:halt, {acc, 0}}
          reps <= remaining -> {:cont, {acc ++ [reps], remaining - reps}}
          true -> {:halt, {acc ++ [remaining], 0}}
        end
      end)
      |> elem(0)
    else
      []
    end

  {full_repeats, remainder_pattern}
end
```

- [ ] **Step 4: Build pattern blocks**

Add helper:

```elixir
defp pattern_block(position, pattern, cadence, p) do
  sets =
    pattern
    |> Enum.with_index(1)
    |> Enum.map(fn {reps, set_position} ->
      %Set{
        position: set_position,
        burpee_count: reps,
        sec_per_rep: cadence,
        sec_per_burpee: p,
        end_of_set_rest: 0
      }
    end)

  %Block{position: position, repeat_count: 1, sets: sets}
end
```

- [ ] **Step 5: Use pattern in even `build_even/3`**

Replace the single-set even block generation with:

```elixir
pattern = preferred_pattern(input)
{full_repeats, remainder_pattern} = split_pattern(n, pattern)

blocks = [pattern_block(1, pattern, cadence, p)]
blocks =
  if remainder_pattern == [] do
    blocks
  else
    blocks ++ [pattern_block(2, remainder_pattern, cadence, p)]
  end

blocks
```

Do this for both `build_even(input, p, [])` and `build_even(input, p, reservations)`, but keep split blocks for reservations in Task 3. For this task, no-rest behavior must pass first.

- [ ] **Step 6: Update `build_steps/2` for pattern blocks**

For no additional rests, generate:

```elixir
defp build_steps(%Input{block_pattern: pattern, burpee_count_target: total} = input, blocks)
     when is_list(pattern) and pattern != [] do
  {full_repeats, remainder_pattern} = split_pattern(total, pattern)

  steps =
    if full_repeats > 0 do
      [block_run_step(1, 1, full_repeats)]
    else
      []
    end

  steps =
    if remainder_pattern == [] do
      steps
    else
      steps ++ [block_run_step(length(steps) + 1, 2, 1)]
    end

  Enum.with_index(steps, 1) |> Enum.map(fn {step, position} -> %{step | position: position} end)
end
```

Keep existing fallback clauses for legacy plans.

- [ ] **Step 7: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: pattern and remainder tests pass.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(plans): generate preferred block patterns"
jj new
```

---

## Task 3: Support additional rests with preferred patterns

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/apply.ex`
- Test: `test/burpee_trainer/plan_solver/apply_test.exs`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Write failing solver test for pattern plus rest**

Add:

```elixir
test "even preferred block pattern splits around additional rest" do
  input = %Input{
    name: "Pattern rest",
    burpee_type: :navy_seal,
    level: :level_1a,
    target_duration_min: 20,
    burpee_count_target: 70,
    pacing_style: :even,
    reps_per_set: nil,
    block_pattern: [4, 3],
    additional_rests: [%{target_min: 12, rest_sec: 20}],
    sec_per_burpee_override: nil
  }

  {:ok, sol} = BurpeeTrainer.PlanSolver.solve(input)

  assert Enum.map(sol.plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [[4, 3]]
  assert Enum.map(sol.plan.steps, & &1.kind) == [:block_run, :rest, :block_run]
  assert [%{repeat_count: before}, %{rest_sec: 20}, %{repeat_count: after}] = sol.plan.steps
  assert before + after == 10
  assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 70
  assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == 1200
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs --trace
```

Expected: fails until pattern-aware rest split exists.

- [ ] **Step 3: Compute rest split by block repeats**

In `Apply.build_steps/2`, for `%Input{block_pattern: pattern, additional_rests: rests}`:

1. Compute `block_total = Enum.sum(pattern)`.
2. Compute full repeats and remainder.
3. For each rest, compute target repeat boundary from `target_min` and block duration.
4. Only split on whole block repeat boundaries.
5. Reject or fall back to solver error if no valid boundary exists.

Use helper:

```elixir
defp block_run_splits(input, block, full_repeats) do
  block_sec = block_duration(block)

  input.additional_rests
  |> Enum.sort_by(& &1.target_min)
  |> Enum.map_reduce({[], full_repeats, 0.0}, fn rest, {steps, remaining, elapsed} ->
    target_sec = rest.target_min * 60.0
    repeats_before = round((target_sec - elapsed) / block_sec)

    cond do
      repeats_before <= 0 or repeats_before >= remaining ->
        throw({:invalid_rest, rest.target_min})

      abs(elapsed + repeats_before * block_sec - target_sec) > 30 ->
        throw({:invalid_rest, rest.target_min})

      true ->
        block_step = block_run_step(0, block.position, repeats_before)
        rest_step = %PlanStep{position: 0, kind: :rest, rest_sec: rest.rest_sec}
        {[block_step, rest_step], {steps ++ [block_step, rest_step], remaining - repeats_before, target_sec + rest.rest_sec}}
    end
  end)
end
```

If using `throw`, catch inside `build_steps` and return an error from `PlanSolver.solve/1` instead of raising. Prefer a clean `{:error, message}` refactor if the code shape allows it.

- [ ] **Step 4: Ensure even cadence includes explicit rests**

Keep:

```elixir
cadence = (target_sec - reservation_total) / n
```

Do not round cadence internally. Display remains one decimal elsewhere.

- [ ] **Step 5: Add LiveView regression**

In `test/burpee_trainer_web/live/workouts_live_test.exs`, add:

```elixir
test "pattern editor plan accepts explicit rest and keeps finish", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("button[phx-value-type='navy_seal']") |> render_click()

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

  render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

  view |> element("[data-timeline-edge-index='1'][data-timeline-edge-action]") |> render_click()

  view
  |> element("[data-timeline-rest-editor]")
  |> render_change(%{"rest" => %{"index" => "1", "rest_sec" => "20", "target_min" => "12"}})

  html = render(view)
  assert html =~ "+20s recovery"
  assert html =~ "20:00"
  assert html =~ "Block 1"
end
```

This test will not compile/pass until Task 4 adds the LiveView event.

- [ ] **Step 6: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: solver test passes after this task; LiveView test may remain pending until Task 4.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(plans): split preferred patterns around rests"
jj new
```

---

## Task 4: Add pattern preference state and LiveView events

**Files:**

- Modify: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add failing LiveView test for pattern control**

Add:

```elixir
test "block pattern editor reruns solver", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("button[phx-value-type='navy_seal']") |> render_click()

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

  render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

  html = render(view)
  assert html =~ "Block pattern"
  assert html =~ "7 reps/block"
  assert html =~ "10×"
  assert html =~ "70 reps"
  assert html =~ "20:00"
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: fails because event/control does not exist.

- [ ] **Step 3: Extend `PlanEditor.input` type/default**

In `lib/burpee_trainer/plan_editor.ex`, add `block_pattern` to the input map type:

```elixir
block_pattern: [pos_integer()] | nil
```

Set default:

```elixir
block_pattern: nil
```

- [ ] **Step 4: Pass pattern into solver input**

In `PlanEditor.regenerate/1`, add:

```elixir
block_pattern: state.input.block_pattern
```

- [ ] **Step 5: Add parser/event function in `PlanEditor`**

Add public function:

```elixir
@spec change_block_pattern(State.t(), map()) :: {:ok, State.t()}
def change_block_pattern(%State{} = state, params) do
  pattern =
    params
    |> Map.get("pattern", %{})
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, value} -> parse_positive_integer(value) end)
    |> Enum.reject(&is_nil/1)

  state
  |> put_input(%{state.input | block_pattern: pattern})
  |> regenerate()
end

defp parse_positive_integer(value) do
  case Integer.parse(to_string(value || "")) do
    {parsed, ""} when parsed > 0 -> parsed
    _ -> nil
  end
end
```

If a helper with this name already exists, reuse it and avoid duplicate definitions.

- [ ] **Step 6: Add LiveView event**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`:

```elixir
def handle_event("change_block_pattern", params, socket) do
  {:ok, editor} = PlanEditor.change_block_pattern(socket.assigns.editor, params)

  socket =
    socket
    |> put_editor(editor)
    |> regenerate()
    |> assign_derived()

  {:noreply, socket}
end
```

- [ ] **Step 7: Run tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: still fails until the template control is added.

---

## Task 5: Replace “Show structure” with pattern editor and inspector

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Update tests to require removal of old structure UX**

Add or update tests:

```elixir
test "new editor has pattern control and no show structure", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/workouts/new")

  assert html =~ "Block pattern"
  refute html =~ "Show structure"
  refute html =~ ~s(id="plan-fine-tune-panel")
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: fails because `Show structure` still exists.

- [ ] **Step 3: Add pattern control markup**

In `plan_solution_card_template.html.heex`, near the style controls or prescription card, add:

```heex
<form id="block-pattern-editor" phx-change="change_block_pattern" class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] p-5 space-y-3">
  <div class="flex items-center justify-between gap-4">
    <div>
      <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
        Block pattern
      </p>
      <p class="mt-1 text-xs text-[var(--session-muted)]">
        Solver uses this grouping and computes repeats, pace, and rests.
      </p>
    </div>
    <p class="text-xs tabular-nums text-[var(--session-muted)]">
      {@pattern_summary}
    </p>
  </div>

  <div class="flex flex-wrap items-center gap-2">
    <%= for {reps, idx} <- Enum.with_index(@plan_input.block_pattern || default_pattern(@plan_input)) do %>
      <input
        type="number"
        min="1"
        name={"pattern[#{idx}]"}
        value={reps}
        class="w-16 rounded-xl border border-[var(--session-border)] bg-[var(--session-surface-alt)] px-2 py-2 text-center text-sm tabular-nums text-[var(--session-ink)]"
      />
    <% end %>
    <button type="button" phx-click="add_pattern_set" class="rounded-xl border border-[var(--session-border)] px-3 py-2 text-xs text-[var(--session-muted)]">
      + Set
    </button>
  </div>
</form>
```

If `default_pattern/1` and `@pattern_summary` do not exist yet, add them in `edit.ex`:

```elixir
defp default_pattern(%{reps_per_set: reps}) when is_integer(reps) and reps > 0, do: [reps]
defp default_pattern(_), do: [1]
```

Add pattern summary assign in `plan_solution_card/1`:

```elixir
|> assign(:pattern_summary, pattern_summary(assigns.plan_input, assigns.derived))
```

Helper:

```elixir
defp pattern_summary(plan_input, derived) do
  pattern = plan_input.block_pattern || default_pattern(plan_input)
  reps_per_block = Enum.sum(pattern)
  repeats = div(plan_input.burpee_count_target, max(reps_per_block, 1))
  remainder = rem(plan_input.burpee_count_target, max(reps_per_block, 1))
  finish = if derived, do: Fmt.duration_sec(round(derived.duration_sec)), else: "—"

  suffix = if remainder > 0, do: " + remainder #{remainder}", else: ""
  "#{reps_per_block} reps/block · #{repeats}×#{suffix} · #{finish}"
end
```

- [ ] **Step 4: Add add/remove pattern set events**

In `edit.ex`:

```elixir
def handle_event("add_pattern_set", _params, socket) do
  input = socket.assigns.editor.input
  pattern = input.block_pattern || default_pattern(input)
  editor = %{socket.assigns.editor | input: %{input | block_pattern: pattern ++ [1]}}

  socket =
    socket
    |> put_editor(editor)
    |> regenerate()
    |> assign_derived()

  {:noreply, socket}
end
```

Only add remove behavior if the UI includes remove controls. First version can omit remove and let users set values before adding more.

- [ ] **Step 5: Remove old structure button/panel from normal template**

Remove from `plan_solution_card_template.html.heex`:

- the `Show structure` button,
- the `id="plan-fine-tune-panel"` wrapper,
- rendering of `blocks_editor_template.html.heex` in normal plan editor.

Do not delete server-side handlers yet unless tests prove they are unused; removing the UI first is enough.

- [ ] **Step 6: Run LiveView tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: pattern control tests pass; old `Show structure` tests must be updated to assert removal.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(plans): add block pattern editor"
jj new
```

---

## Task 6: Stabilize graph inspector editing

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Write inspector stability test**

Add:

```elixir
test "block inspector edits pattern and stays open", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

  view |> element("[data-timeline-row-index='1'] [data-timeline-block-toggle]") |> render_click()

  assert has_element?(view, "#block-pattern-inspector")

  view
  |> element("#block-pattern-inspector")
  |> render_change(%{"pattern" => %{"0" => "5", "1" => "2"}})

  html = render(view)
  assert has_element?(view, "#block-pattern-inspector")
  assert html =~ "7 reps/block"
  assert html =~ "5"
  assert html =~ "2"
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: fails until inspector exists.

- [ ] **Step 3: Add inspector markup**

When a block node is expanded, render:

```heex
<form
  id="block-pattern-inspector"
  phx-change="change_block_pattern"
  class="mt-4 space-y-3 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface-alt)] p-4"
>
  <div class="flex items-center justify-between gap-4">
    <p class="text-sm font-semibold text-[var(--session-ink)]">Block pattern</p>
    <p class="text-xs text-[var(--session-muted)]">Edits rerun the solver</p>
  </div>

  <%= for {reps, idx} <- Enum.with_index(@plan_input.block_pattern || default_pattern(@plan_input)) do %>
    <label class="grid grid-cols-[1fr_5rem] items-center gap-3 text-xs">
      <span class="text-[var(--session-muted)]">Set {idx + 1}</span>
      <input
        type="number"
        min="1"
        name={"pattern[#{idx}]"}
        value={reps}
        class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] px-2 py-2 text-center text-sm tabular-nums text-[var(--session-ink)]"
      />
    </label>
  <% end %>
</form>
```

Do not put `phx-click` on the inspector parent. The only block toggle should remain on `[data-timeline-block-toggle]`.

- [ ] **Step 4: Remove old per-generated-set editor from graph**

Remove or hide the existing `change_timeline_set` mini-form from the graph path. The graph inspector edits pattern preference instead of generated copies.

Leave `change_timeline_set` server code temporarily if tests/legacy paths still reference it; remove in cleanup once green.

- [ ] **Step 5: Run tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: inspector tests pass, no collapse regression.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(plans): edit block patterns from graph inspector"
jj new
```

---

## Task 7: Persistence and session correctness

**Files:**

- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer/workouts/workout_plan.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex` if needed
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`
- Test: `test/burpee_trainer_web/live/session_live_test.exs`

- [ ] **Step 1: Write save/reload test**

Add:

```elixir
test "saves generated pattern plan and reloads steps", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view |> element("button[phx-value-type='navy_seal']") |> render_click()

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

  render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

  view |> element("button", "Create session") |> render_click()

  assert_redirect(view, ~p"/workouts")

  [plan] = BurpeeTrainer.Workouts.list_plans()
  plan = BurpeeTrainer.Workouts.get_plan!(plan.id)

  assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [[4, 3]]
  assert [%{kind: :block_run, repeat_count: 10}] = plan.steps
end
```

Adjust `list_plans/0` call if it requires a user/scope in this codebase.

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: may fail if generated pattern/steps are not persisted correctly.

- [ ] **Step 3: Ensure save paths include steps and blocks**

Confirm `Workouts.save_generated_plan/2`, create, update, and duplicate flows include:

```elixir
"blocks" => save_generated_plan_blocks(plan.blocks),
"steps" => save_generated_plan_steps(plan.steps)
```

If `get_plan!/1` does not preload `steps`, update preloads in `lib/burpee_trainer/workouts.ex` to include `steps: []`.

- [ ] **Step 4: Ensure session runner uses persisted steps**

Run existing session test:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs --trace
```

If failing, ensure `SessionLive.serialize_execution_timeline/1` handles pattern-generated `steps` and resolves `block_position` to the correct block.

- [ ] **Step 5: Run persistence/session tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs test/burpee_trainer_web/live/session_live_test.exs --trace
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "fix(plans): persist block pattern executions"
jj new
```

---

## Task 8: Cleanup old structure editor paths

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify/Delete: `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Search for old structure references**

Run:

```bash
rg -n "Show structure|plan-fine-tune-panel|blocks_editor_template|enable_manual_edit|change_timeline_set|copy_block|copy_set|drop_block|drop_set" lib test
```

- [ ] **Step 2: Remove unused UI-only code**

If the old low-level editor is no longer rendered and tests are updated, remove:

- `enable_manual_edit` button rendering,
- old structure panel render call,
- obsolete tests expecting `Show structure`,
- server handlers that are no longer reachable.

Do not remove domain-level block/set schemas or persistence.

- [ ] **Step 3: Keep only still-used graph handlers**

Keep:

- `toggle_timeline_block`,
- rest editing handlers,
- pattern editing handlers.

Remove `change_timeline_set` only after no tests or UI paths use it.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: no old structure assertions remain; new pattern editor assertions pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(plans): remove legacy structure editor"
jj new
```

---

## Task 9: Final verification

**Files:**

- No direct code edits unless verification finds failures.

- [ ] **Step 1: Run JS hook tests**

Run:

```bash
node assets/js/hooks/session_plan_test.mjs
```

Expected: `session_plan tests passed`.

- [ ] **Step 2: Run full precommit**

Run:

```bash
mix precommit
```

Expected: all tests pass.

- [ ] **Step 3: Manual browser check**

Run:

```bash
mix ecto.migrate
mix phx.server
```

Manual checks:

1. `/workouts/new`
2. Pick Navy SEAL.
3. Set goal 70, duration 20.
4. Set block pattern `4 + 3`.
5. Confirm graph shows 70 reps and 20:00.
6. Add 20s rest at minute 12.
7. Confirm graph shows rest and still finishes 20:00.
8. Confirm there is no “Show structure”.
9. Click a block and edit pattern in inspector; confirm inspector stays open.

- [ ] **Step 4: Final commit if needed**

If verification required cleanup edits:

```bash
jj describe -m "fix(plans): verify block pattern editor"
jj new
```

- [ ] **Step 5: Push**

```bash
jj bookmark set master -r @-
jj git push -b master
```

If the working copy is already an empty child after commits, set `master` to the last non-empty commit (`@-`).
