# Hybrid Exact Prescription Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current heuristic-as-source-of-truth solver with a hybrid exact search solver that guarantees target reps and target duration before ranking human-friendly prescriptions.

**Architecture:** Add a small deterministic search module that enumerates human-shaped set structures and exact recovery allocations. `PlanSolver` will use this module for generated prescriptions, then `Apply` will materialize the exact prescription into blocks and steps. Heuristics remain only as scoring/ranking, not feasibility proof.

**Tech Stack:** Elixir, ExUnit, existing Phoenix LiveView tests, no external solver dependency in this phase.

---

## Core Principle

Hard constraints must be satisfied before a plan can be recommended:

- total reps equals target reps,
- executable summary duration equals target duration,
- pace is not faster than the effective safe lower bound,
- first-class rests remain `PlanStep :rest`,
- final phantom recovery is never counted.

Soft preferences only rank valid candidates:

- human set sizes,
- useful recovery,
- one-minute-ish work intervals,
- simple repeated blocks,
- low remainder awkwardness.

---

## File Map

- Create `lib/burpee_trainer/plan_solver/search.ex`
  - Exact deterministic candidate search.
  - Emits a solved prescription struct/map with set pattern, pace, recovery pattern, score, and metadata.
- Modify `lib/burpee_trainer/plan_solver.ex`
  - Delegate generated `:even` and `:unbroken` candidate solving to `PlanSolver.Search`.
  - Keep validation/preflight and `build_solution/3` metadata.
- Modify `lib/burpee_trainer/plan_solver/apply.ex`
  - Materialize exact set/rest patterns without adding final phantom recovery.
- Modify `lib/burpee_trainer/planner.ex`
  - If needed, make step-backed summaries respect no-final-recovery semantics.
- Tests:
  - `test/burpee_trainer/plan_solver/search_test.exs`
  - `test/burpee_trainer/plan_solver_test.exs`
  - `test/burpee_trainer/plan_solver/apply_test.exs`
  - `test/burpee_trainer/planner_test.exs`
  - `test/burpee_trainer_web/live/workouts_live_test.exs`

---

## Task 1: Add exact search for simple repeated set prescriptions

**Files:**

- Create: `lib/burpee_trainer/plan_solver/search.ex`
- Create: `test/burpee_trainer/plan_solver/search_test.exs`

- [ ] **Step 1: Write failing search tests**

Create `test/burpee_trainer/plan_solver/search_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanSolver.SearchTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.Search

  test "solves 160 reps in 20 minutes as exact 20 x 8" do
    assert {:ok, candidate} =
             Search.solve(%{
               burpee_type: :six_count,
               pacing_style: :unbroken,
               target_reps: 160,
               target_sec: 1200,
               min_sec_per_rep: 5.513,
               preferred_reps_per_set: 8,
               block_pattern: nil,
               additional_rests: []
             })

    assert candidate.set_pattern == List.duplicate(8, 20)
    assert length(candidate.rest_pattern_sec) == 19
    assert_in_delta candidate.duration_sec, 1200.0, 0.001
    assert candidate.sec_per_burpee >= 5.513
    assert candidate.recommendation == "20 × 8 reps with auto recovery"
  end

  test "rejects impossible target instead of returning invalid duration" do
    assert {:error, [message]} =
             Search.solve(%{
               burpee_type: :six_count,
               pacing_style: :unbroken,
               target_reps: 300,
               target_sec: 1200,
               min_sec_per_rep: 7.955,
               preferred_reps_per_set: 8,
               block_pattern: nil,
               additional_rests: []
             })

    assert message =~ "requires"
  end
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver/search_test.exs --trace
```

Expected: fails because `BurpeeTrainer.PlanSolver.Search` does not exist.

- [ ] **Step 3: Implement minimal exact search**

Create `lib/burpee_trainer/plan_solver/search.ex`:

```elixir
defmodule BurpeeTrainer.PlanSolver.Search do
  @moduledoc """
  Deterministic exact prescription search.

  This module proves feasibility first, then ranks human-friendly candidates.
  """

  @human_set_sizes %{six_count: [8, 10, 12, 6, 15, 5, 4], navy_seal: [5, 4, 6, 3]}
  @min_recovery_sec 8.0
  @max_recovery_sec 90.0

  @type candidate :: %{
          sec_per_burpee: float(),
          set_pattern: [pos_integer()],
          rest_pattern_sec: [float()],
          duration_sec: float(),
          score: float(),
          recommendation: String.t(),
          set_pattern_strategy: atom()
        }

  @spec solve(map()) :: {:ok, candidate()} | {:error, [String.t()]}
  def solve(%{} = input) do
    target_reps = Map.fetch!(input, :target_reps)
    target_sec = Map.fetch!(input, :target_sec) * 1.0
    min_sec_per_rep = Map.fetch!(input, :min_sec_per_rep) * 1.0
    burpee_type = Map.fetch!(input, :burpee_type)
    preferred = Map.get(input, :preferred_reps_per_set)

    candidates =
      burpee_type
      |> set_sizes(preferred)
      |> Enum.flat_map(fn set_size -> repeated_set_candidate(target_reps, target_sec, min_sec_per_rep, set_size) end)
      |> Enum.sort_by(& &1.score)

    case candidates do
      [candidate | _] -> {:ok, candidate}
      [] -> {:error, [infeasible_message(target_reps, target_sec, min_sec_per_rep)]}
    end
  end

  defp set_sizes(type, preferred) do
    base = Map.fetch!(@human_set_sizes, type)

    if is_integer(preferred) and preferred > 0 do
      [preferred | base]
    else
      base
    end
    |> Enum.uniq()
  end

  defp repeated_set_candidate(target_reps, target_sec, min_sec_per_rep, set_size) do
    if rem(target_reps, set_size) == 0 do
      set_count = div(target_reps, set_size)
      gap_count = max(set_count - 1, 0)

      fastest_work_sec = target_reps * min_sec_per_rep
      rest_budget = target_sec - fastest_work_sec

      cond do
        rest_budget < 0 ->
          []

        gap_count == 0 ->
          [%{sec_per_burpee: target_sec / target_reps, set_pattern: [target_reps], rest_pattern_sec: [], duration_sec: target_sec, score: 1000.0, recommendation: "1 × #{target_reps} reps", set_pattern_strategy: :exact_search}]

        rest_budget / gap_count < @min_recovery_sec ->
          []

        rest_budget / gap_count > @max_recovery_sec ->
          []

        true ->
          rest = rest_budget / gap_count
          set_pattern = List.duplicate(set_size, set_count)

          [
            %{
              sec_per_burpee: min_sec_per_rep,
              set_pattern: set_pattern,
              rest_pattern_sec: List.duplicate(rest, gap_count),
              duration_sec: target_sec,
              score: score(set_size, set_count, rest),
              recommendation: "#{set_count} × #{set_size} reps with auto recovery",
              set_pattern_strategy: :exact_search
            }
          ]
      end
    else
      []
    end
  end

  defp score(set_size, set_count, rest) do
    work_interval_penalty = abs(set_size - 8) * 0.5
    recovery_penalty = abs(rest - 20) * 0.05
    complexity_penalty = set_count * 0.01
    work_interval_penalty + recovery_penalty + complexity_penalty
  end

  defp infeasible_message(target_reps, target_sec, min_sec_per_rep) do
    required = target_sec / target_reps

    "#{target_reps} reps in #{format_duration(target_sec)} requires about #{Float.round(required, 1)}s/rep before useful recovery. " <>
      "Safe pace is #{Float.round(min_sec_per_rep, 1)}s/rep or slower. Try lowering reps, increasing duration, or using larger sets."
  end

  defp format_duration(seconds) do
    seconds = round(seconds)
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)

    cond do
      minutes > 0 and remainder > 0 -> "#{minutes}m #{remainder}s"
      minutes > 0 -> "#{minutes}m"
      true -> "#{remainder}s"
    end
  end
end
```

- [ ] **Step 4: Run search tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver/search_test.exs --trace
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

Run:

```bash
jj describe -m "feat(plans): add exact prescription search"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 2: Route PlanSolver through exact search

**Files:**

- Modify: `lib/burpee_trainer/plan_solver.ex`
- Test: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Add regression for exact executable duration**

Update the existing `"unbroken 160 in 20 minutes with 8 reps per set preserves auto recovery"` test in `test/burpee_trainer/plan_solver_test.exs` to include:

```elixir
summary = BurpeeTrainer.Planner.summary(sol.plan)
assert summary.burpee_count_total == 160
assert summary.duration_sec_total == 1200.0
refute sol.solver_error
```

If `sol.solver_error` does not exist, omit that line.

- [ ] **Step 2: Run failing test**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: fails today with `duration_sec_total == 1220.0`.

- [ ] **Step 3: Delegate unbroken solve to Search**

In `lib/burpee_trainer/plan_solver.ex`, alias Search:

```elixir
alias BurpeeTrainer.PlanSolver.{Apply, Input, Search, Solution}
```

Replace `solve_candidate(%Input{pacing_style: :unbroken} = input, reps_per_set)` with:

```elixir
defp solve_candidate(%Input{pacing_style: :unbroken} = input, reps_per_set) do
  case Search.solve(%{
         burpee_type: input.burpee_type,
         pacing_style: input.pacing_style,
         target_reps: input.burpee_count_target,
         target_sec: input.target_duration_min * 60,
         min_sec_per_rep: pace(input),
         preferred_reps_per_set: reps_per_set,
         block_pattern: input.block_pattern,
         additional_rests: input.additional_rests
       }) do
    {:ok, exact} ->
      {:ok,
       candidate(input,
         sec_per_burpee: exact.sec_per_burpee,
         set_pattern: exact.set_pattern,
         rest_pattern_sec: exact.rest_pattern_sec,
         reservations: [],
         candidate_count: 1,
         score: exact.score,
         set_pattern_strategy: exact.set_pattern_strategy
       )
       |> Map.put(:recommendation, exact.recommendation)}

    {:error, reasons} ->
      {:error, reasons}
  end
end
```

- [ ] **Step 4: Preserve exact recommendation metadata**

In `recommendation_text/2`, prefer candidate recommendation:

```elixir
defp recommendation_text(_input, %{recommendation: recommendation}) when is_binary(recommendation), do: recommendation
```

Place this before the existing recommendation clauses.

- [ ] **Step 5: Run tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs test/burpee_trainer/plan_solver/search_test.exs --trace
```

Expected: tests pass and `160 / 20 / 8` summary is exactly 1200.

- [ ] **Step 6: Commit**

Run:

```bash
jj describe -m "feat(plans): solve unbroken prescriptions with exact search"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 3: Materialize exact repeated sets without final phantom recovery

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/apply.ex`
- Modify: `lib/burpee_trainer/planner.ex` if needed
- Test: `test/burpee_trainer/plan_solver/apply_test.exs`
- Test: `test/burpee_trainer/planner_test.exs`

- [ ] **Step 1: Add apply regression**

Add to `test/burpee_trainer/plan_solver/apply_test.exs`:

```elixir
test ":unbroken exact 20 x 8 materializes to exact 20 minutes" do
  input = unbroken_input(160, 20, 8)
  p = 5.513
  rest = (1200.0 - 160 * p) / 19
  set_pattern = List.duplicate(8, 20)
  rest_pattern = List.duplicate(rest, 19)

  {:ok, plan} = Apply.to_workout_plan(input, p, set_pattern, rest_pattern, [])

  summary = BurpeeTrainer.Planner.summary(plan)
  assert summary.burpee_count_total == 160
  assert_in_delta summary.duration_sec_total, 1200.0, 1.0
end
```

- [ ] **Step 2: Fix materialization**

If the test fails because rounded set rests create a phantom final rest, update `Apply.build_unbroken/3` to set the final set recovery to zero only for the final executable run. If that cannot be represented with one reusable block, emit two block definitions:

```text
Block 1: 8 reps + rounded recovery, repeated 19
Block 2: 8 reps + 0 recovery, repeated 1
```

The resulting steps should be:

```elixir
[
  %PlanStep{kind: :block_run, block_position: 1, repeat_count: 19},
  %PlanStep{kind: :block_run, block_position: 2, repeat_count: 1}
]
```

- [ ] **Step 3: Run apply/planner tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs test/burpee_trainer/planner_test.exs --trace
```

Expected: all pass.

- [ ] **Step 4: Commit**

Run:

```bash
jj describe -m "fix(plans): materialize exact final recovery"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 4: Verify LiveView no longer shows self-invalid recommendation

**Files:**

- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`
- Modify source only if test fails.

- [ ] **Step 1: Add LiveView regression**

Add to `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
test "160 unbroken 8 reps recommendation is valid in the editor", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view
  |> element("#plan-goal-controls")
  |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "160"})

  view
  |> element("button[phx-value-style='unbroken']")
  |> render_click()

  render_change(view, "change_basics", %{"reps_per_set" => "8"})

  html = render(view)
  assert html =~ "20:00"
  assert html =~ "160 reps"
  assert html =~ "20 × 8 reps"
  refute html =~ "Prescription does not match target"
  refute html =~ "20:20"
end
```

- [ ] **Step 2: Run LiveView test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: all Workouts LiveView tests pass.

- [ ] **Step 3: Commit**

Run:

```bash
jj describe -m "test(plans): prevent self-invalid prescriptions"
jj bookmark set master -r @
jj git push -b master
```

---

## Task 5: Final verification

- [ ] **Step 1: Run JS test**

```bash
node assets/js/hooks/session_plan_test.mjs
```

Expected:

```text
session_plan tests passed
```

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

Expected: all tests pass with 0 failures.

- [ ] **Step 3: Commit formatter changes if any**

```bash
jj status
```

If there are formatting changes:

```bash
jj describe -m "style(plans): format exact prescription solver"
jj bookmark set master -r @
jj git push -b master
```

---

## Self-Review

This plan fixes the exact observed failure: a recommended `20 × 8` unbroken workout must not display as `20:20` or fail its own target. The search module proves exact duration before recommendation, and later tasks ensure materialization and LiveView rendering preserve that exact prescription.
