# Smart Prescription Graph Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a smart prescription generator and graph-first editor so users can enter duration/reps/style and receive a human-friendly block/set workout that is natural to edit from the graph.

**Architecture:** Add a solver scoring layer that generates human-sized set/block candidates for both even and unbroken styles, computes auto pace/recovery, and emits explanation metadata. Then update the LiveView graph to make the graph the editing surface with one stable inspector and contextual controls.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto schemas/changesets, ExUnit, Phoenix.LiveViewTest, Tailwind classes in HEEx, jj workflow.

---

## File Map

- Modify `lib/burpee_trainer/plan_solver.ex`
  - Generate human-friendly candidates for `:even` and `:unbroken`.
  - Rank by work interval, recovery usefulness, simplicity, and pace safety.
  - Add recommendation/suggestion metadata.
- Modify `lib/burpee_trainer/plan_solver/apply.ex`
  - Ensure even plans without user pattern still create reusable blocks/steps.
  - Keep explicit rests as `PlanStep :rest`.
- Modify `lib/burpee_trainer/plan_solver/solution.ex`
  - If needed, widen metadata type documentation only; no schema change required.
- Modify `lib/burpee_trainer/plan_editor.ex`
  - Add graph selection/edit transitions for block/rest inspector.
  - Keep auto pace/recovery as normal mode.
- Modify `lib/burpee_trainer_web/live/plans_live/edit.ex`
  - Add selected timeline row state if current `expanded_timeline_row` is insufficient.
  - Add event handlers for graph selection and recommended rest suggestion acceptance.
  - Improve plan feedback generation from solver metadata.
- Modify `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
  - Replace top pattern form with compact intent + prescription layout.
  - Keep one stable inspector outside timeline rows.
  - Make graph nodes clickable and edges expose `+ Rest`.
- Modify tests:
  - `test/burpee_trainer/plan_solver_test.exs`
  - `test/burpee_trainer/plan_solver/apply_test.exs`
  - `test/burpee_trainer_web/live/workouts_live_test.exs`

---

## Task 1: Make even plans human-shaped by default

**Files:**

- Modify: `lib/burpee_trainer/plan_solver.ex`
- Modify: `lib/burpee_trainer/plan_solver/apply.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`
- Test: `test/burpee_trainer/plan_solver/apply_test.exs`

- [ ] **Step 1: Add failing solver test for even 160/20:00**

Add to `test/burpee_trainer/plan_solver_test.exs`:

```elixir
test "even solve recommends human-sized repeated sets for high rep targets" do
  {:ok, sol} =
    PlanSolver.solve(
      input(%{
        pacing_style: :even,
        burpee_type: :six_count,
        burpee_count_target: 160,
        target_duration_min: 20,
        level: :level_1a
      })
    )

  assert sol.burpee_count == 160
  assert sol.plan.blocks != []
  refute match?([%{sets: [%{burpee_count: 160}]}], sol.plan.blocks)

  [block | _] = sol.plan.blocks
  assert Enum.all?(block.sets, &(&1.burpee_count in [15, 12, 10, 9, 8, 6, 5, 4]))
  assert [%{kind: :block_run, repeat_count: repeats} | _] = sol.plan.steps
  assert repeats > 1
  assert sol.metadata.set_pattern_strategy in [:smart_even, :preferred_pattern]
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: the new test fails because even currently produces a single 160-rep set when no `block_pattern` is supplied.

- [ ] **Step 3: Add default smart pattern selection helper**

In `lib/burpee_trainer/plan_solver.ex`, add helpers near `preferred_set_sizes/2`:

```elixir
@normal_work_interval_sec 60.0
@min_useful_recovery_sec 8.0

# Prefer set sizes that create roughly one-minute work intervals at the chosen pace.
defp smart_set_sizes(:navy_seal), do: [5, 4, 6, 3]
defp smart_set_sizes(:six_count), do: [8, 10, 12, 6, 15, 5, 4]

defp default_even_pattern(%Input{block_pattern: pattern}) when is_list(pattern) and pattern != [],
  do: pattern

defp default_even_pattern(%Input{} = input) do
  p = pace(input)

  input.burpee_type
  |> smart_set_sizes()
  |> Enum.min_by(fn reps -> abs(reps * p - @normal_work_interval_sec) end)
  |> then(&[&1])
end
```

- [ ] **Step 4: Change even candidate generation**

Replace the body of `solve_candidate(%Input{pacing_style: :even} = input, _reps_per_set)` in `lib/burpee_trainer/plan_solver.ex` with:

```elixir
defp solve_candidate(%Input{pacing_style: :even} = input, _reps_per_set) do
  p = pace(input)
  pattern = default_even_pattern(input)

  case place_additional_rests(%{input | block_pattern: pattern}, p, nil) do
    {:ok, reservations} ->
      set_pattern = expand_pattern(input.burpee_count_target, pattern)
      rest_pattern = List.duplicate(0.0, max(length(set_pattern) - 1, 0))

      {:ok,
       candidate(%{input | block_pattern: pattern},
         sec_per_burpee: p,
         set_pattern: set_pattern,
         rest_pattern_sec: rest_pattern,
         reservations: reservations,
         candidate_count: 1,
         score: score_smart_candidate(input, p, set_pattern, rest_pattern),
         set_pattern_strategy: if(input.block_pattern, do: :preferred_pattern, else: :smart_even)
       )}

    {:error, :invalid_rest_boundary} ->
      {:error, [infeasibility_message(input)]}
  end
end
```

Also add helpers:

```elixir
defp expand_pattern(total_reps, pattern) do
  {full_repeats, remainder_pattern} = Apply.split_pattern_for_solver(total_reps, pattern)
  List.duplicate(pattern, full_repeats) |> List.flatten() |> Kernel.++(remainder_pattern)
end

defp score_smart_candidate(_input, p, set_pattern, rest_pattern) do
  work_penalty =
    set_pattern
    |> Enum.map(fn reps -> abs(reps * p - @normal_work_interval_sec) / 60.0 end)
    |> Enum.sum()

  recovery_penalty =
    rest_pattern
    |> Enum.map(fn rest -> if rest > 0 and rest < @min_useful_recovery_sec, do: 10.0, else: 0.0 end)
    |> Enum.sum()

  work_penalty + recovery_penalty + length(set_pattern) * 0.01
end
```

- [ ] **Step 5: Expose split helper from Apply**

In `lib/burpee_trainer/plan_solver/apply.ex`, rename private `split_pattern/2` to public helper:

```elixir
@spec split_pattern_for_solver(pos_integer(), [pos_integer()]) :: {non_neg_integer(), [pos_integer()]}
def split_pattern_for_solver(total_reps, pattern) do
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

Then replace internal calls to `split_pattern(n, pattern)` with `split_pattern_for_solver(n, pattern)` and remove the old private helper.

- [ ] **Step 6: Make Apply use smart default pattern for even**

In `lib/burpee_trainer/plan_solver/apply.ex`, replace:

```elixir
defp preferred_pattern(%Input{burpee_count_target: reps}), do: [reps]
```

with:

```elixir
defp preferred_pattern(%Input{burpee_type: :navy_seal}), do: [5]
defp preferred_pattern(%Input{burpee_type: :six_count}), do: [8]
```

This keeps the apply layer aligned with the solver for no-pattern even plans.

- [ ] **Step 7: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs test/burpee_trainer/plan_solver/apply_test.exs
```

Expected: all tests pass, including the new even 160 test.

- [ ] **Step 8: Commit**

Run:

```bash
jj describe -m "feat(plans): generate human-shaped even prescriptions"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 2: Balance unbroken pace and recovery as auto training prescription

**Files:**

- Modify: `lib/burpee_trainer/plan_solver.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Add regression test for 160 unbroken 8 reps/set**

Add to `test/burpee_trainer/plan_solver_test.exs`:

```elixir
test "unbroken 160 in 20 minutes with 8 reps per set preserves auto recovery" do
  {:ok, sol} =
    PlanSolver.solve(
      input(%{
        pacing_style: :unbroken,
        burpee_type: :six_count,
        burpee_count_target: 160,
        target_duration_min: 20,
        level: :level_1a,
        reps_per_set: 8
      })
    )

  assert sol.set_pattern == List.duplicate(8, 20)
  assert length(sol.rest_pattern_sec) == 19
  assert sol.rest_sec >= 8.0
  assert sol.sec_per_burpee >= sol.metadata.pace_fastest_sec_per_rep
  assert sol.metadata.recovery_mode == :auto
  assert sol.metadata.recommendation =~ "20 × 8"
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: failure on missing metadata keys, not necessarily on solve.

- [ ] **Step 3: Add auto recovery metadata**

In `build_solution/3` in `lib/burpee_trainer/plan_solver.ex`, extend `metadata` with:

```elixir
recovery_mode: :auto,
recommendation: recommendation_text(input, candidate),
work_interval_sec: average_work_interval(candidate.set_pattern, candidate.sec_per_burpee),
recovery_sec: candidate.rest_sec
```

Add helpers:

```elixir
defp recommendation_text(%Input{pacing_style: :unbroken}, candidate) do
  primary = candidate.set_pattern |> Enum.frequencies() |> Enum.max_by(fn {_reps, count} -> count end)
  {reps, count} = primary
  "#{count} × #{reps} reps with auto recovery"
end

defp recommendation_text(%Input{pacing_style: :even}, candidate) do
  primary = candidate.set_pattern |> Enum.frequencies() |> Enum.max_by(fn {_reps, count} -> count end)
  {reps, count} = primary
  "#{count} × #{reps} reps at even cadence"
end

defp average_work_interval([], _p), do: 0.0

defp average_work_interval(set_pattern, p) do
  set_pattern
  |> Enum.map(&(&1 * p))
  |> Enum.sum()
  |> Kernel./(length(set_pattern))
end
```

- [ ] **Step 4: Improve infeasibility message for unsafe recovery**

In `derive_rest_pattern/4`, change the `true` branch to reject useless recovery for repeated unbroken sets:

```elixir
true ->
  rest_per_gap = rest_budget / gap_count

  if input.pacing_style == :unbroken and gap_count > 0 and rest_per_gap < @min_useful_recovery_sec do
    {:error, :insufficient_recovery}
  else
    {:ok, List.duplicate(rest_per_gap, gap_count)}
  end
```

In the `else` branch inside unbroken candidate generation, keep dropping bad candidates. The generic error remains acceptable until Task 5 improves feedback.

- [ ] **Step 5: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: all solver tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
jj describe -m "feat(plans): explain auto recovery prescriptions"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 3: Add optional midpoint rest suggestions

**Files:**

- Modify: `lib/burpee_trainer/plan_solver.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Add midpoint suggestion test**

Add to `test/burpee_trainer/plan_solver_test.exs`:

```elixir
test "solver suggests feasible midpoint reset rest without forcing it" do
  {:ok, sol} =
    PlanSolver.solve(
      input(%{
        pacing_style: :unbroken,
        burpee_type: :six_count,
        burpee_count_target: 160,
        target_duration_min: 20,
        level: :level_1a,
        reps_per_set: 8
      })
    )

  assert sol.plan.steps |> Enum.map(& &1.kind) == [:block_run]
  assert [%{target_min: target_min, rest_sec: rest_sec, effect: effect}] = sol.metadata.rest_suggestions
  assert target_min in 10..16
  assert rest_sec in [20, 30]
  assert effect =~ "recovery"
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: fails because `rest_suggestions` metadata is absent.

- [ ] **Step 3: Add suggestion helper**

In `lib/burpee_trainer/plan_solver.ex`, add:

```elixir
defp rest_suggestions(%Input{additional_rests: [_ | _]}, _candidate), do: []
defp rest_suggestions(%Input{target_duration_min: duration}, _candidate) when duration < 15, do: []

defp rest_suggestions(%Input{} = input, candidate) do
  target_min = midpoint_rest_minute(input.target_duration_min)
  rest_sec = 30
  gap_count = max(length(candidate.set_pattern) - 1, 0)

  if gap_count > 0 do
    adjusted_recovery = (candidate.target_sec - Enum.sum(candidate.set_pattern) * candidate.sec_per_burpee - rest_sec) / gap_count

    if adjusted_recovery >= @min_useful_recovery_sec do
      [%{target_min: target_min, rest_sec: rest_sec, effect: "set recovery becomes about #{round(adjusted_recovery)}s"}]
    else
      []
    end
  else
    []
  end
end

defp midpoint_rest_minute(duration_min) do
  duration_min
  |> Kernel.*(0.6)
  |> round()
  |> max(10)
  |> min(16)
end
```

- [ ] **Step 4: Add metadata key**

In `build_solution/3`, add:

```elixir
rest_suggestions: rest_suggestions(input, candidate)
```

- [ ] **Step 5: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: all solver tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
jj describe -m "feat(plans): suggest feasible reset rests"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 4: Make graph inspector stable and contextual

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add failing LiveView test for stable inspector**

Add to `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
test "graph block selection uses one stable inspector", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "160"})

  html = render(view)
  assert html =~ "Prescription graph"
  assert has_element?(view, "[data-timeline-block-toggle]")

  view |> element("[data-timeline-block-toggle]") |> render_click()
  assert has_element?(view, "#graph-inspector")
  assert has_element?(view, "#graph-inspector[data-inspector-kind='block']")

  view
  |> element("#graph-inspector")
  |> render_change(%{"pattern" => %{"0" => "10"}})

  assert has_element?(view, "#graph-inspector")
  refute render(view) =~ ~s(id="block-pattern-inspector")
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: fails because inspector is currently rendered inline as `#block-pattern-inspector`.

- [ ] **Step 3: Rename event semantics to selection**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, keep the existing event name if desired, but change its purpose to select a graph row:

```elixir
def handle_event("toggle_timeline_block", %{"row-index" => row_index}, socket) do
  row_index = String.to_integer(row_index)
  {:noreply, assign(socket, :expanded_timeline_row, row_index)}
end
```

If this handler already exists and toggles closed on second click, remove the close behavior. Selection should be stable.

- [ ] **Step 4: Move block inspector out of timeline row**

In `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`, remove the inline `<form id="block-pattern-inspector" ...>` from inside each timeline row.

After the timeline graph `</div>` for `#plan-prescription-timeline`, add:

```heex
<form
  :if={is_integer(@expanded_timeline_row)}
  id="graph-inspector"
  data-inspector-kind="block"
  phx-change="change_block_pattern"
  class="mt-5 space-y-4 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface-alt)] p-4 text-left"
>
  <div class="flex items-start justify-between gap-4">
    <div>
      <p class="text-sm font-semibold text-[var(--session-ink)]">Block 1</p>
      <p class="mt-1 text-xs text-[var(--session-muted)]">
        Auto pace and recovery. Edits rerun the prescription.
      </p>
    </div>
    <p :if={@solver_solution} class="text-right text-xs text-[var(--session-muted)]">
      {@solver_solution.metadata.recommendation}
    </p>
  </div>

  <div class="space-y-2">
    <%= for {reps, idx} <- Enum.with_index(default_pattern(@plan_input)) do %>
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
  </div>

  <div :if={@solver_solution} class="grid gap-2 text-xs text-[var(--session-muted)] sm:grid-cols-3">
    <div class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] p-3">
      Work · {round(@solver_solution.metadata.work_interval_sec)}s
    </div>
    <div class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] p-3">
      Recovery · {round(@solver_solution.metadata.recovery_sec)}s auto
    </div>
    <div class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] p-3">
      Pace · {:erlang.float_to_binary(@solver_solution.sec_per_burpee * 1.0, decimals: 1)}s/rep
    </div>
  </div>
</form>
```

- [ ] **Step 5: Rename graph label**

In the same template, change the label text from `Predicted` to:

```heex
Prescription graph
```

- [ ] **Step 6: Run LiveView test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: all workouts LiveView tests pass.

- [ ] **Step 7: Commit**

Run:

```bash
jj describe -m "feat(plans): stabilize graph inspector"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 5: Show recommendation and reset suggestion in the UI

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add failing LiveView test for recommendation and suggestion**

Add to `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
test "new plan explains smart recommendation and optional reset", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "160"})

  html = render(view)
  assert html =~ "Recommended"
  assert html =~ "auto recovery"
  assert html =~ "Optional reset"
  assert has_element?(view, "button[data-accept-rest-suggestion]")
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: fails because UI does not render rest suggestions.

- [ ] **Step 3: Add event handler for accepting suggestion**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, add:

```elixir
def handle_event("accept_rest_suggestion", %{"target-min" => target_min, "rest-sec" => rest_sec}, socket) do
  rest = %{target_min: String.to_integer(target_min), rest_sec: String.to_integer(rest_sec)}
  input = socket.assigns.editor.input
  editor = %{socket.assigns.editor | input: %{input | additional_rests: input.additional_rests ++ [rest]}}
  {:ok, editor} = PlanEditor.regenerate(editor)

  socket =
    socket
    |> put_editor(editor)
    |> assign_derived()

  {:noreply, socket}
end
```

- [ ] **Step 4: Render recommendation panel**

In `plan_solution_card_template.html.heex`, below the graph summary and above the timeline graph, add:

```heex
<div :if={@solver_solution} class="mt-5 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface-alt)] p-4 text-left">
  <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
    Recommended
  </p>
  <p class="mt-2 text-sm font-semibold text-[var(--session-ink)]">
    {@solver_solution.metadata.recommendation}
  </p>
  <p class="mt-1 text-xs text-[var(--session-muted)]">
    Pace and recovery are auto-balanced for your level.
  </p>

  <div :if={@solver_solution.metadata.rest_suggestions != []} class="mt-4 space-y-2">
    <%= for suggestion <- @solver_solution.metadata.rest_suggestions do %>
      <div class="flex items-center justify-between gap-3 rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)] p-3">
        <div>
          <p class="text-xs font-semibold text-[var(--session-ink)]">Optional reset</p>
          <p class="text-xs text-[var(--session-muted)]">
            {suggestion.rest_sec}s at {suggestion.target_min}:00 · {suggestion.effect}
          </p>
        </div>
        <button
          type="button"
          phx-click="accept_rest_suggestion"
          phx-value-target-min={suggestion.target_min}
          phx-value-rest-sec={suggestion.rest_sec}
          data-accept-rest-suggestion
          class="rounded-xl border border-[var(--session-border)] px-3 py-2 text-xs font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
        >
          Add
        </button>
      </div>
    <% end %>
  </div>
</div>
```

- [ ] **Step 5: Run LiveView tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: all workouts LiveView tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
jj describe -m "feat(plans): show smart prescription guidance"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 6: Improve actionable solver feedback

**Files:**

- Modify: `lib/burpee_trainer/plan_solver.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add solver feedback test**

Add to `test/burpee_trainer/plan_solver_test.exs`:

```elixir
test "solver explains impossible aggressive prescription with actionable alternatives" do
  assert {:error, [msg]} =
           PlanSolver.solve(
             input(%{
               pacing_style: :unbroken,
               burpee_type: :six_count,
               burpee_count_target: 300,
               target_duration_min: 20,
               level: :level_1a,
               reps_per_set: 8
             })
           )

  assert msg =~ "requires"
  assert msg =~ "Try"
  assert msg =~ "lowering reps"
end
```

- [ ] **Step 2: Replace generic infeasibility message**

In `lib/burpee_trainer/plan_solver.ex`, replace `infeasibility_message(%Input{} = input)` with:

```elixir
defp infeasibility_message(%Input{} = input) do
  target_sec = input.target_duration_min * 60.0
  required_pace = target_sec / input.burpee_count_target
  fastest = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, input.level)

  "#{input.burpee_count_target} reps in #{format_duration(target_sec)} requires " <>
    "about #{Float.round(required_pace, 1)}s/rep before useful recovery. " <>
    "Your level target is #{Float.round(fastest, 1)}s/rep or slower. " <>
    "Try lowering reps, increasing duration, using larger sets, or removing extra rests."
end
```

- [ ] **Step 3: Add LiveView feedback assertion**

Add or update an impossible prescription test in `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
assert render(view) =~ "Try lowering reps"
```

- [ ] **Step 4: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
jj describe -m "fix(plans): explain impossible prescriptions"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 7: Final verification

**Files:**

- No planned source edits.

- [ ] **Step 1: Run JS session plan tests**

Run:

```bash
node assets/js/hooks/session_plan_test.mjs
```

Expected:

```text
session_plan tests passed
```

- [ ] **Step 2: Run project precommit**

Run:

```bash
mix precommit
```

Expected: all tests pass. Existing duplicate primary key warnings may appear, but there must be `0 failures`.

- [ ] **Step 3: Check workspace**

Run:

```bash
jj status
```

Expected:

```text
The working copy has no changes.
```

If formatting changed files during `mix precommit`, commit them:

```bash
jj describe -m "style(plans): format smart prescription editor"
jj bookmark set master -r @
jj git push -b master
```

---

## Self-Review

Spec coverage:

- Human-friendly even defaults: Task 1.
- Unbroken 160/8 auto recovery: Task 2.
- Optional midpoint rest suggestion: Task 3 and Task 5.
- Graph-first stable inspector: Task 4.
- Recommendation/explanation UI: Task 5.
- Actionable feedback: Task 6.
- Final verification: Task 7.

No placeholders remain. Function names introduced in plan are consistent: `split_pattern_for_solver/2`, `default_even_pattern/1`, `expand_pattern/2`, `score_smart_candidate/4`, `rest_suggestions/2`, and `accept_rest_suggestion`.
