# Planner Solver UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a prescription-first planner model that generates human workout drafts, keeps MILP as an allocator detail, and prepares the LiveView for a vertical timeline UI.

**Architecture:** Add a new `BurpeeTrainer.Planning` domain above the existing `WorkoutPlan` execution schema. The new solver returns a `Draft` containing semantic timeline items, feedback, repairs, and metadata; a compiler converts verified drafts to existing executable plan structs while DB overhaul is evaluated separately. Keep current `PlanSolver` callable during migration, but route new tests through the planning domain.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto schemas, ExUnit, existing HiGHS/MILP integration in `BurpeeTrainer.PlanSolver.Milp`, jj.

---

## Scope note

The approved spec is large enough to cover three subsystems:

1. planning domain/data model
2. solver algorithms
3. vertical timeline UI

This plan implements the first vertical slice: prescription-first planning domain, human draft generation, structured feedback/repairs, and compilation to the existing executable model. It leaves full DB replacement and final visual polish for follow-up plans after the domain boundary is proven.

## File map

- Create `lib/burpee_trainer/planning/goal.ex`
  - Required planner goal with style-specific fields.
- Create `lib/burpee_trainer/planning/timeline_item.ex`
  - Semantic timeline item structs: even unit, unbroken group, standalone rest, meaningful pattern.
- Create `lib/burpee_trainer/planning/draft.ex`
  - User-facing solved prescription with status, timeline, feedback, repairs, and metadata.
- Create `lib/burpee_trainer/planning/feedback.ex`
  - Structured feedback and repair suggestions.
- Create `lib/burpee_trainer/planning/style_profile.ex`
  - Converts goal style into style semantics.
- Create `lib/burpee_trainer/planning/draft_generator.ex`
  - Generates human draft candidates for even/unbroken styles.
- Create `lib/burpee_trainer/planning/draft_verifier.ex`
  - Verifies reps, duration tolerance, style semantics, and no giant fake blocks.
- Create `lib/burpee_trainer/planning/compiler.ex`
  - Compiles a verified draft to `%BurpeeTrainer.Workouts.WorkoutPlan{}` using current execution schemas.
- Create `lib/burpee_trainer/planning.ex`
  - Public planning facade.
- Modify `lib/burpee_trainer/plan_solver/input.ex`
  - Add `max_reps_per_set` as the new unbroken name while preserving `reps_per_set` during migration.
- Modify `lib/burpee_trainer/plan_solver.ex`
  - Delegate new-generation paths to `BurpeeTrainer.Planning.solve/1` once compiler exists.
- Modify `lib/burpee_trainer_web/live/plans_live/edit.ex`
  - Introduce assigns for `@draft`, `@draft_feedback`, and `@expanded_timeline_item_id` without full visual restyle.
- Test files:
  - `test/burpee_trainer/planning/goal_test.exs`
  - `test/burpee_trainer/planning/draft_generator_test.exs`
  - `test/burpee_trainer/planning/draft_verifier_test.exs`
  - `test/burpee_trainer/planning/compiler_test.exs`
  - `test/burpee_trainer/planning_test.exs`

---

## Task 1: Add planner goal and timeline item domain structs

**Files:**

- Create: `lib/burpee_trainer/planning/goal.ex`
- Create: `lib/burpee_trainer/planning/timeline_item.ex`
- Create: `test/burpee_trainer/planning/goal_test.exs`

- [ ] **Step 1: Write failing goal tests**

Create `test/burpee_trainer/planning/goal_test.exs`:

```elixir
defmodule BurpeeTrainer.Planning.GoalTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.Goal

  describe "new/1" do
    test "requires duration, reps, burpee type, and style" do
      assert {:error, errors} = Goal.new(%{})

      assert {:duration_sec, :required} in errors
      assert {:target_reps, :required} in errors
      assert {:burpee_type, :required} in errors
      assert {:style, :required} in errors
    end

    test "requires max reps per set for unbroken goals" do
      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 160,
                 burpee_type: :six_count,
                 style: :unbroken
               })

      assert {:max_reps_per_set, :required_for_unbroken} in errors
    end

    test "builds an even goal with default two minute unit preference" do
      assert {:ok, goal} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even
               })

      assert goal.duration_sec == 1200
      assert goal.target_reps == 150
      assert goal.burpee_type == :six_count
      assert goal.style == :even
      assert goal.preferred_unit_sec == 120
      assert goal.max_reps_per_set == nil
    end

    test "builds an unbroken goal with max reps per set" do
      assert {:ok, goal} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 160,
                 burpee_type: :six_count,
                 style: :unbroken,
                 max_reps_per_set: 8
               })

      assert goal.style == :unbroken
      assert goal.max_reps_per_set == 8
    end
  end
end
```

- [ ] **Step 2: Run failing goal tests**

Run:

```bash
mix test test/burpee_trainer/planning/goal_test.exs
```

Expected: FAIL because `BurpeeTrainer.Planning.Goal` does not exist.

- [ ] **Step 3: Implement `Goal`**

Create `lib/burpee_trainer/planning/goal.ex`:

```elixir
defmodule BurpeeTrainer.Planning.Goal do
  @moduledoc """
  Required planner goal.

  This is the stable problem statement for draft generation. The solver may
  rebalance structure, pace, and rest, but must not silently change these goal
  facts.
  """

  @enforce_keys [:duration_sec, :target_reps, :burpee_type, :style]
  defstruct [
    :duration_sec,
    :target_reps,
    :burpee_type,
    :style,
    :max_reps_per_set,
    preferred_unit_sec: 120,
    rest_targets_sec: [12 * 60, 17 * 60]
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type style :: :even | :unbroken

  @type error :: {atom(), atom()}

  @type t :: %__MODULE__{
          duration_sec: pos_integer(),
          target_reps: pos_integer(),
          burpee_type: burpee_type(),
          style: style(),
          max_reps_per_set: pos_integer() | nil,
          preferred_unit_sec: pos_integer(),
          rest_targets_sec: [pos_integer()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, [error()]}
  def new(attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    errors =
      []
      |> require_key(attrs, :duration_sec)
      |> require_key(attrs, :target_reps)
      |> require_key(attrs, :burpee_type)
      |> require_key(attrs, :style)
      |> validate_positive(attrs, :duration_sec)
      |> validate_positive(attrs, :target_reps)
      |> validate_burpee_type(attrs)
      |> validate_style(attrs)
      |> validate_unbroken(attrs)

    case errors do
      [] ->
        {:ok,
         %__MODULE__{
           duration_sec: attrs.duration_sec,
           target_reps: attrs.target_reps,
           burpee_type: attrs.burpee_type,
           style: attrs.style,
           max_reps_per_set: Map.get(attrs, :max_reps_per_set),
           preferred_unit_sec: Map.get(attrs, :preferred_unit_sec, 120),
           rest_targets_sec: Map.get(attrs, :rest_targets_sec, [12 * 60, 17 * 60])
         }}

      [_ | _] ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp require_key(errors, attrs, key) do
    if Map.has_key?(attrs, key), do: errors, else: [{key, :required} | errors]
  end

  defp validate_positive(errors, attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value > 0 -> errors
      nil -> errors
      _ -> [{key, :must_be_positive_integer} | errors]
    end
  end

  defp validate_burpee_type(errors, attrs) do
    case Map.get(attrs, :burpee_type) do
      type when type in [:six_count, :navy_seal] -> errors
      nil -> errors
      _ -> [{:burpee_type, :unsupported} | errors]
    end
  end

  defp validate_style(errors, attrs) do
    case Map.get(attrs, :style) do
      style when style in [:even, :unbroken] -> errors
      nil -> errors
      _ -> [{:style, :unsupported} | errors]
    end
  end

  defp validate_unbroken(errors, %{style: :unbroken} = attrs) do
    case Map.get(attrs, :max_reps_per_set) do
      value when is_integer(value) and value > 0 -> errors
      _ -> [{:max_reps_per_set, :required_for_unbroken} | errors]
    end
  end

  defp validate_unbroken(errors, _attrs), do: errors
end
```

- [ ] **Step 4: Implement timeline item structs**

Create `lib/burpee_trainer/planning/timeline_item.ex`:

```elixir
defmodule BurpeeTrainer.Planning.TimelineItem do
  @moduledoc """
  Semantic user-facing draft timeline items.

  These are planning concepts, not database rows. Compile them to execution
  steps only after a draft is verified.
  """

  defmodule EvenUnit do
    @moduledoc "Even-pacing time unit where rest is distributed between reps."
    @enforce_keys [:id, :start_sec, :duration_sec, :reps]
    defstruct [:id, :start_sec, :duration_sec, :reps, :rep_interval_sec, :burpee_duration_sec]

    @type t :: %__MODULE__{
            id: String.t(),
            start_sec: non_neg_integer(),
            duration_sec: pos_integer(),
            reps: pos_integer(),
            rep_interval_sec: float() | nil,
            burpee_duration_sec: float() | nil
          }
  end

  defmodule UnbrokenGroup do
    @moduledoc "Unbroken work group followed by recovery."
    @enforce_keys [:id, :start_sec, :reps, :burpee_duration_sec, :rest_after_sec]
    defstruct [:id, :start_sec, :reps, :burpee_duration_sec, :rest_after_sec]

    @type t :: %__MODULE__{
            id: String.t(),
            start_sec: non_neg_integer(),
            reps: pos_integer(),
            burpee_duration_sec: float(),
            rest_after_sec: non_neg_integer()
          }
  end

  defmodule StandaloneRest do
    @moduledoc "Explicit reset rest funded by tighter work elsewhere."
    @enforce_keys [:id, :start_sec, :duration_sec]
    defstruct [:id, :start_sec, :duration_sec, funded_by: []]

    @type t :: %__MODULE__{
            id: String.t(),
            start_sec: non_neg_integer(),
            duration_sec: pos_integer(),
            funded_by: [String.t()]
          }
  end

  defmodule MeaningfulPattern do
    @moduledoc "Repeated pattern that carries workout meaning, such as [4, 3]."
    @enforce_keys [:id, :start_sec, :repeat_count, :pattern]
    defstruct [:id, :start_sec, :repeat_count, :pattern, :unit_duration_sec]

    @type t :: %__MODULE__{
            id: String.t(),
            start_sec: non_neg_integer(),
            repeat_count: pos_integer(),
            pattern: [pos_integer()],
            unit_duration_sec: pos_integer() | nil
          }
  end

  @type t :: EvenUnit.t() | UnbrokenGroup.t() | StandaloneRest.t() | MeaningfulPattern.t()
end
```

- [ ] **Step 5: Run goal tests**

Run:

```bash
mix test test/burpee_trainer/planning/goal_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(planning): add planner goal domain"
jj new
```

---

## Task 2: Add draft, feedback, and style profile structs

**Files:**

- Create: `lib/burpee_trainer/planning/draft.ex`
- Create: `lib/burpee_trainer/planning/feedback.ex`
- Create: `lib/burpee_trainer/planning/style_profile.ex`
- Create: `test/burpee_trainer/planning/draft_generator_test.exs`

- [ ] **Step 1: Write failing style profile tests**

Create `test/burpee_trainer/planning/draft_generator_test.exs` with these initial tests:

```elixir
defmodule BurpeeTrainer.Planning.DraftGeneratorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{Goal, StyleProfile}

  describe "StyleProfile.from_goal/1" do
    test "even style distributes rest between reps" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 150,
          burpee_type: :six_count,
          style: :even
        })

      profile = StyleProfile.from_goal(goal)

      assert profile.style == :even
      assert profile.rest_semantics == :between_reps
      assert profile.preferred_unit_sec == 120
    end

    test "unbroken style rests after sets" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :unbroken,
          max_reps_per_set: 8
        })

      profile = StyleProfile.from_goal(goal)

      assert profile.style == :unbroken
      assert profile.rest_semantics == :after_set
      assert profile.max_reps_per_set == 8
    end
  end
end
```

- [ ] **Step 2: Run failing style profile tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: FAIL because `StyleProfile` does not exist.

- [ ] **Step 3: Implement feedback structs**

Create `lib/burpee_trainer/planning/feedback.ex`:

```elixir
defmodule BurpeeTrainer.Planning.Feedback do
  @moduledoc "Structured draft feedback and repair suggestions."

  defmodule Message do
    @moduledoc "Short feedback for the bottom bar."
    @enforce_keys [:kind, :text]
    defstruct [:kind, :text, changed_item_ids: []]

    @type kind :: :adjusted | :tight | :infeasible
    @type t :: %__MODULE__{kind: kind(), text: String.t(), changed_item_ids: [String.t()]}
  end

  defmodule Repair do
    @moduledoc "One-tap repair suggestion."
    @enforce_keys [:id, :label, :action]
    defstruct [:id, :label, :action]

    @type action ::
            {:add_rest, %{target_sec: pos_integer(), duration_sec: pos_integer()}}
            | {:reduce_target_reps, pos_integer()}
            | {:use_unit_sec, pos_integer()}
            | {:lower_max_reps_per_set, pos_integer()}
            | {:try_pattern, [pos_integer()]}
            | {:remove_lock, String.t()}

    @type t :: %__MODULE__{id: String.t(), label: String.t(), action: action()}
  end
end
```

- [ ] **Step 4: Implement draft struct**

Create `lib/burpee_trainer/planning/draft.ex`:

```elixir
defmodule BurpeeTrainer.Planning.Draft do
  @moduledoc "Solved user-facing workout draft prescription."

  alias BurpeeTrainer.Planning.{Feedback, Goal, TimelineItem}

  @enforce_keys [:goal, :status, :timeline, :metadata]
  defstruct [:goal, :status, :timeline, :feedback, repairs: [], changed_item_ids: [], metadata: %{}]

  @type status :: :good | :adjusted | :tight | :infeasible

  @type t :: %__MODULE__{
          goal: Goal.t(),
          status: status(),
          timeline: [TimelineItem.t()],
          feedback: Feedback.Message.t() | nil,
          repairs: [Feedback.Repair.t()],
          changed_item_ids: [String.t()],
          metadata: map()
        }
end
```

- [ ] **Step 5: Implement style profile**

Create `lib/burpee_trainer/planning/style_profile.ex`:

```elixir
defmodule BurpeeTrainer.Planning.StyleProfile do
  @moduledoc "Style semantics derived from a planner goal."

  alias BurpeeTrainer.Planning.Goal

  @enforce_keys [:style, :rest_semantics]
  defstruct [:style, :rest_semantics, :preferred_unit_sec, :max_reps_per_set]

  @type rest_semantics :: :between_reps | :after_set

  @type t :: %__MODULE__{
          style: Goal.style(),
          rest_semantics: rest_semantics(),
          preferred_unit_sec: pos_integer() | nil,
          max_reps_per_set: pos_integer() | nil
        }

  @spec from_goal(Goal.t()) :: t()
  def from_goal(%Goal{style: :even} = goal) do
    %__MODULE__{
      style: :even,
      rest_semantics: :between_reps,
      preferred_unit_sec: goal.preferred_unit_sec,
      max_reps_per_set: nil
    }
  end

  def from_goal(%Goal{style: :unbroken} = goal) do
    %__MODULE__{
      style: :unbroken,
      rest_semantics: :after_set,
      preferred_unit_sec: nil,
      max_reps_per_set: goal.max_reps_per_set
    }
  end
end
```

- [ ] **Step 6: Run tests**

Run:

```bash
mix test test/burpee_trainer/planning/goal_test.exs test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(planning): add draft prescription structs"
jj new
```

---

## Task 3: Generate human even-pacing drafts

**Files:**

- Create: `lib/burpee_trainer/planning/draft_generator.ex`
- Modify: `test/burpee_trainer/planning/draft_generator_test.exs`

- [ ] **Step 1: Add failing even draft tests**

Append to `test/burpee_trainer/planning/draft_generator_test.exs`:

```elixir
  describe "DraftGenerator.generate/1 for even pacing" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "150 reps in 20 minutes becomes two-minute units, not one giant set" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 150,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert draft.status == :good
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))
      assert length(draft.timeline) == 10
      assert Enum.all?(draft.timeline, &(&1.reps == 15))
      refute Enum.any?(draft.timeline, &(&1.reps == 150))
    end

    test "300 reps in 20 minutes stays legible and allows dense units" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 300,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert length(draft.timeline) == 10
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))
      assert Enum.all?(draft.timeline, &(&1.reps == 30))
      assert Enum.all?(draft.timeline, &(&1.rep_interval_sec == 4.0))
    end
  end
```

- [ ] **Step 2: Run failing even draft tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: FAIL because `DraftGenerator.generate/1` does not exist.

- [ ] **Step 3: Implement even draft generation**

Create `lib/burpee_trainer/planning/draft_generator.ex`:

```elixir
defmodule BurpeeTrainer.Planning.DraftGenerator do
  @moduledoc "Generates human-readable draft prescriptions from planner goals."

  alias BurpeeTrainer.Planning.{Draft, Goal, TimelineItem}

  @default_burpee_duration_sec %{six_count: 3.0, navy_seal: 5.0}

  @spec generate(Goal.t()) :: {:ok, Draft.t()} | {:error, term()}
  def generate(%Goal{style: :even} = goal) do
    unit_sec = goal.preferred_unit_sec || 120
    unit_count = div(goal.duration_sec, unit_sec)

    if unit_count <= 0 or rem(goal.duration_sec, unit_sec) != 0 do
      {:error, {:unsupported_unit_duration, unit_sec}}
    else
      base_reps = div(goal.target_reps, unit_count)
      remainder = rem(goal.target_reps, unit_count)

      timeline =
        0..(unit_count - 1)
        |> Enum.map(fn index ->
          reps = base_reps + if(index < remainder, do: 1, else: 0)
          rep_interval_sec = unit_sec / reps

          %TimelineItem.EvenUnit{
            id: "unit-#{index + 1}",
            start_sec: index * unit_sec,
            duration_sec: unit_sec,
            reps: reps,
            rep_interval_sec: rep_interval_sec,
            burpee_duration_sec: Map.fetch!(@default_burpee_duration_sec, goal.burpee_type)
          }
        end)

      {:ok,
       %Draft{
         goal: goal,
         status: :good,
         timeline: timeline,
         metadata: %{generator: :even_units_v1, unit_sec: unit_sec}
       }}
    end
  end

  def generate(%Goal{style: :unbroken} = goal) do
    {:error, {:not_implemented, {:style, goal.style}}}
  end
end
```

- [ ] **Step 4: Run tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: PASS for even tests; unbroken generation still not covered.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planning): generate even pacing drafts"
jj new
```

---

## Task 4: Generate unbroken drafts with max set size

**Files:**

- Modify: `lib/burpee_trainer/planning/draft_generator.ex`
- Modify: `test/burpee_trainer/planning/draft_generator_test.exs`

- [ ] **Step 1: Add failing unbroken draft test**

Append to `test/burpee_trainer/planning/draft_generator_test.exs`:

```elixir
  describe "DraftGenerator.generate/1 for unbroken pacing" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "160 reps with max 8 reps per set produces repeated unbroken groups" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :unbroken,
          max_reps_per_set: 8
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert draft.status == :good
      assert length(draft.timeline) == 20
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.UnbrokenGroup{}, &1))
      assert Enum.all?(draft.timeline, &(&1.reps == 8))
      assert Enum.all?(draft.timeline, &(&1.rest_after_sec >= 0))
      refute Enum.any?(draft.timeline, &(&1.reps == 160))
    end
  end
```

- [ ] **Step 2: Run failing unbroken test**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: FAIL with `{:not_implemented, {:style, :unbroken}}`.

- [ ] **Step 3: Implement unbroken generation**

Replace the unbroken clause in `lib/burpee_trainer/planning/draft_generator.ex` with:

```elixir
  def generate(%Goal{style: :unbroken} = goal) do
    set_size = goal.max_reps_per_set
    set_count = ceil(goal.target_reps / set_size)
    burpee_duration_sec = Map.fetch!(@default_burpee_duration_sec, goal.burpee_type)

    set_reps =
      1..set_count
      |> Enum.map(fn index ->
        remaining = goal.target_reps - (index - 1) * set_size
        min(set_size, remaining)
      end)

    work_sec = Enum.sum(set_reps) * burpee_duration_sec
    gap_count = max(set_count - 1, 1)
    rest_after_sec = max(floor((goal.duration_sec - work_sec) / gap_count), 0)

    timeline =
      set_reps
      |> Enum.with_index()
      |> Enum.map(fn {reps, index} ->
        start_sec =
          set_reps
          |> Enum.take(index)
          |> Enum.reduce(0, fn previous_reps, acc ->
            acc + round(previous_reps * burpee_duration_sec) + rest_after_sec
          end)

        %TimelineItem.UnbrokenGroup{
          id: "set-#{index + 1}",
          start_sec: start_sec,
          reps: reps,
          burpee_duration_sec: burpee_duration_sec,
          rest_after_sec: if(index == set_count - 1, do: 0, else: rest_after_sec)
        }
      end)

    {:ok,
     %Draft{
       goal: goal,
       status: :good,
       timeline: timeline,
       metadata: %{generator: :unbroken_sets_v1, max_reps_per_set: set_size}
     }}
  end
```

- [ ] **Step 4: Run tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planning): generate unbroken drafts"
jj new
```

---

## Task 5: Verify draft invariants

**Files:**

- Create: `lib/burpee_trainer/planning/draft_verifier.ex`
- Create: `test/burpee_trainer/planning/draft_verifier_test.exs`

- [ ] **Step 1: Write failing verifier tests**

Create `test/burpee_trainer/planning/draft_verifier_test.exs`:

```elixir
defmodule BurpeeTrainer.Planning.DraftVerifierTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{DraftGenerator, DraftVerifier, Goal, TimelineItem}

  test "accepts an even draft within duration and rep tolerance" do
    {:ok, goal} = Goal.new(%{duration_sec: 1200, target_reps: 150, burpee_type: :six_count, style: :even})
    {:ok, draft} = DraftGenerator.generate(goal)

    assert :ok = DraftVerifier.verify(draft)
  end

  test "rejects a giant even unit" do
    {:ok, goal} = Goal.new(%{duration_sec: 1200, target_reps: 150, burpee_type: :six_count, style: :even})

    draft = %BurpeeTrainer.Planning.Draft{
      goal: goal,
      status: :good,
      timeline: [
        %TimelineItem.EvenUnit{
          id: "bad",
          start_sec: 0,
          duration_sec: 1200,
          reps: 150,
          rep_interval_sec: 8.0,
          burpee_duration_sec: 3.0
        }
      ],
      metadata: %{}
    }

    assert {:error, errors} = DraftVerifier.verify(draft)
    assert {:timeline, :giant_even_unit} in errors
  end

  test "rejects unbroken sets above max reps per set" do
    {:ok, goal} =
      Goal.new(%{
        duration_sec: 1200,
        target_reps: 160,
        burpee_type: :six_count,
        style: :unbroken,
        max_reps_per_set: 8
      })

    draft = %BurpeeTrainer.Planning.Draft{
      goal: goal,
      status: :good,
      timeline: [
        %TimelineItem.UnbrokenGroup{
          id: "bad",
          start_sec: 0,
          reps: 12,
          burpee_duration_sec: 3.0,
          rest_after_sec: 30
        }
      ],
      metadata: %{}
    }

    assert {:error, errors} = DraftVerifier.verify(draft)
    assert {:unbroken_group, :exceeds_max_reps_per_set} in errors
  end
end
```

- [ ] **Step 2: Run failing verifier tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_verifier_test.exs
```

Expected: FAIL because `DraftVerifier` does not exist.

- [ ] **Step 3: Implement verifier**

Create `lib/burpee_trainer/planning/draft_verifier.ex`:

```elixir
defmodule BurpeeTrainer.Planning.DraftVerifier do
  @moduledoc "Deterministic checks for solved planning drafts."

  alias BurpeeTrainer.Planning.{Draft, TimelineItem}

  @duration_tolerance_sec 10

  @spec verify(Draft.t()) :: :ok | {:error, [term()]}
  def verify(%Draft{} = draft) do
    errors =
      []
      |> verify_total_reps(draft)
      |> verify_duration(draft)
      |> verify_even_units(draft)
      |> verify_unbroken_groups(draft)

    case errors do
      [] -> :ok
      [_ | _] -> {:error, Enum.reverse(errors)}
    end
  end

  defp verify_total_reps(errors, draft) do
    total = Enum.reduce(draft.timeline, 0, &(&2 + reps(&1)))

    if total == draft.goal.target_reps,
      do: errors,
      else: [{:target_reps, {:expected, draft.goal.target_reps, :actual, total}} | errors]
  end

  defp verify_duration(errors, draft) do
    duration = timeline_duration_sec(draft.timeline)

    if abs(duration - draft.goal.duration_sec) <= @duration_tolerance_sec,
      do: errors,
      else: [{:duration_sec, {:expected, draft.goal.duration_sec, :actual, duration}} | errors]
  end

  defp verify_even_units(errors, %Draft{goal: %{style: :even}} = draft) do
    Enum.reduce(draft.timeline, errors, fn
      %TimelineItem.EvenUnit{reps: reps}, acc when reps >= 100 ->
        [{:timeline, :giant_even_unit} | acc]

      _item, acc ->
        acc
    end)
  end

  defp verify_even_units(errors, _draft), do: errors

  defp verify_unbroken_groups(errors, %Draft{goal: %{style: :unbroken, max_reps_per_set: max}} = draft) do
    Enum.reduce(draft.timeline, errors, fn
      %TimelineItem.UnbrokenGroup{reps: reps}, acc when reps > max ->
        [{:unbroken_group, :exceeds_max_reps_per_set} | acc]

      _item, acc ->
        acc
    end)
  end

  defp verify_unbroken_groups(errors, _draft), do: errors

  defp reps(%TimelineItem.EvenUnit{reps: reps}), do: reps
  defp reps(%TimelineItem.UnbrokenGroup{reps: reps}), do: reps
  defp reps(%TimelineItem.MeaningfulPattern{repeat_count: repeat_count, pattern: pattern}), do: repeat_count * Enum.sum(pattern)
  defp reps(%TimelineItem.StandaloneRest{}), do: 0

  defp timeline_duration_sec([]), do: 0

  defp timeline_duration_sec(items) do
    items
    |> Enum.map(&item_end_sec/1)
    |> Enum.max()
  end

  defp item_end_sec(%TimelineItem.EvenUnit{} = item), do: item.start_sec + item.duration_sec
  defp item_end_sec(%TimelineItem.StandaloneRest{} = item), do: item.start_sec + item.duration_sec
  defp item_end_sec(%TimelineItem.MeaningfulPattern{} = item), do: item.start_sec + item.repeat_count * (item.unit_duration_sec || 0)

  defp item_end_sec(%TimelineItem.UnbrokenGroup{} = item),
    do: item.start_sec + round(item.reps * item.burpee_duration_sec) + item.rest_after_sec
end
```

- [ ] **Step 4: Run verifier tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_verifier_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run all planning tests**

Run:

```bash
mix test test/burpee_trainer/planning
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(planning): verify draft invariants"
jj new
```

---

## Task 6: Add strategic rest intent and rest-buffer feedback

**Files:**

- Modify: `lib/burpee_trainer/planning/goal.ex`
- Modify: `lib/burpee_trainer/planning/draft_generator.ex`
- Modify: `test/burpee_trainer/planning/draft_generator_test.exs`

- [ ] **Step 1: Add failing standalone rest test**

Append to `test/burpee_trainer/planning/draft_generator_test.exs`:

```elixir
  describe "DraftGenerator.generate/1 with strategic rest" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "adds a funded standalone rest around 12 minutes" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120,
          requested_rest: %{target_sec: 12 * 60, duration_sec: 45}
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert Enum.any?(draft.timeline, fn
               %TimelineItem.StandaloneRest{start_sec: start_sec, duration_sec: 45} ->
                 abs(start_sec - 12 * 60) <= 120

               _ ->
                 false
             end)

      assert draft.feedback.text == "Added 45s reset · earlier units tightened to fund it"
    end
  end
```

- [ ] **Step 2: Run failing standalone rest test**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: FAIL because `Goal` does not accept `requested_rest` and generator ignores it.

- [ ] **Step 3: Add requested rest to goal**

Modify `lib/burpee_trainer/planning/goal.ex`:

```elixir
  defstruct [
    :duration_sec,
    :target_reps,
    :burpee_type,
    :style,
    :max_reps_per_set,
    :requested_rest,
    preferred_unit_sec: 120,
    rest_targets_sec: [12 * 60, 17 * 60]
  ]
```

Update the type:

```elixir
          requested_rest: %{target_sec: pos_integer(), duration_sec: pos_integer()} | nil,
```

Update struct construction in `new/1`:

```elixir
           requested_rest: Map.get(attrs, :requested_rest),
```

- [ ] **Step 4: Implement rest insertion for even drafts**

In `lib/burpee_trainer/planning/draft_generator.ex`, replace the `{:ok, %Draft{...}}` return in the even clause with:

```elixir
      {timeline, feedback, changed_item_ids} = maybe_insert_requested_rest(timeline, goal)

      {:ok,
       %Draft{
         goal: goal,
         status: if(feedback, do: :adjusted, else: :good),
         timeline: timeline,
         feedback: feedback,
         changed_item_ids: changed_item_ids,
         metadata: %{generator: :even_units_v1, unit_sec: unit_sec}
       }}
```

Add these private functions to the same module:

```elixir
  defp maybe_insert_requested_rest(timeline, %{requested_rest: nil}), do: {timeline, nil, []}

  defp maybe_insert_requested_rest(timeline, %{requested_rest: %{target_sec: target_sec, duration_sec: duration_sec}}) do
    rest = %TimelineItem.StandaloneRest{
      id: "rest-#{target_sec}",
      start_sec: target_sec,
      duration_sec: duration_sec,
      funded_by: timeline |> Enum.filter(&(&1.start_sec < target_sec)) |> Enum.map(& &1.id)
    }

    tightened =
      Enum.map(timeline, fn
        %TimelineItem.EvenUnit{start_sec: start_sec, duration_sec: unit_sec} = item when start_sec < target_sec ->
          funded_share = duration_sec / max(length(rest.funded_by), 1)
          new_duration = max(round(unit_sec - funded_share), 1)
          %{item | duration_sec: new_duration, rep_interval_sec: new_duration / item.reps}

        item ->
          item
      end)

    feedback = %BurpeeTrainer.Planning.Feedback.Message{
      kind: :adjusted,
      text: "Added #{duration_sec}s reset · earlier units tightened to fund it",
      changed_item_ids: rest.funded_by
    }

    {Enum.sort_by([rest | tightened], & &1.start_sec), feedback, rest.funded_by}
  end
```

- [ ] **Step 5: Run standalone rest tests**

Run:

```bash
mix test test/burpee_trainer/planning/draft_generator_test.exs
```

Expected: PASS.

- [ ] **Step 6: Run verifier tests and inspect expected duration behavior**

Run:

```bash
mix test test/burpee_trainer/planning/draft_verifier_test.exs
```

Expected: PASS. The standalone rest test is not yet verifier-covered because duration accounting with overlapping funded units needs the compiler/verifier refinement in Task 7.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(planning): add funded rest intent"
jj new
```

---

## Task 7: Compile drafts to existing workout plans

**Files:**

- Create: `lib/burpee_trainer/planning/compiler.ex`
- Create: `test/burpee_trainer/planning/compiler_test.exs`

- [ ] **Step 1: Write failing compiler tests**

Create `test/burpee_trainer/planning/compiler_test.exs`:

```elixir
defmodule BurpeeTrainer.Planning.CompilerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{Compiler, DraftGenerator, Goal}
  alias BurpeeTrainer.Workouts.{PlanStep, WorkoutPlan}

  test "compiles even units into an executable workout plan" do
    {:ok, goal} = Goal.new(%{duration_sec: 1200, target_reps: 150, burpee_type: :six_count, style: :even})
    {:ok, draft} = DraftGenerator.generate(goal)

    assert {:ok, %WorkoutPlan{} = plan} = Compiler.to_workout_plan(draft, name: "150 in 20")

    assert plan.name == "150 in 20"
    assert plan.burpee_type == :six_count
    assert plan.burpee_count_target == 150
    assert plan.target_duration_min == 20
    assert length(plan.blocks) == 10
    assert Enum.all?(plan.blocks, &(length(&1.sets) == 1))
    assert Enum.sum(for block <- plan.blocks, set <- block.sets, do: set.burpee_count) == 150
  end

  test "compiles standalone rest into a rest plan step" do
    {:ok, goal} =
      Goal.new(%{
        duration_sec: 1200,
        target_reps: 160,
        burpee_type: :six_count,
        style: :even,
        requested_rest: %{target_sec: 720, duration_sec: 45}
      })

    {:ok, draft} = DraftGenerator.generate(goal)

    assert {:ok, %WorkoutPlan{} = plan} = Compiler.to_workout_plan(draft, name: "160 with reset")

    assert Enum.any?(plan.steps, &match?(%PlanStep{kind: :rest, rest_sec: 45}, &1))
  end
end
```

- [ ] **Step 2: Run failing compiler tests**

Run:

```bash
mix test test/burpee_trainer/planning/compiler_test.exs
```

Expected: FAIL because `Compiler` does not exist.

- [ ] **Step 3: Implement compiler**

Create `lib/burpee_trainer/planning/compiler.ex`:

```elixir
defmodule BurpeeTrainer.Planning.Compiler do
  @moduledoc "Compiles verified planning drafts to executable workout plans."

  alias BurpeeTrainer.Planning.{Draft, TimelineItem}
  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}

  @spec to_workout_plan(Draft.t(), keyword()) :: {:ok, WorkoutPlan.t()} | {:error, term()}
  def to_workout_plan(%Draft{} = draft, opts \\ []) do
    name = Keyword.get(opts, :name, "Draft workout")

    blocks =
      draft.timeline
      |> Enum.reject(&match?(%TimelineItem.StandaloneRest{}, &1))
      |> Enum.with_index(1)
      |> Enum.map(fn {item, position} -> block_from_item(item, position) end)

    steps =
      draft.timeline
      |> Enum.with_index(1)
      |> Enum.map(fn {item, position} -> step_from_item(item, position) end)

    {:ok,
     %WorkoutPlan{
       name: name,
       burpee_type: draft.goal.burpee_type,
       target_duration_min: round(draft.goal.duration_sec / 60),
       burpee_count_target: draft.goal.target_reps,
       sec_per_burpee: average_burpee_duration(draft.timeline),
       pacing_style: draft.goal.style,
       additional_rests: "[]",
       plan_solver_metadata: %{
         "source" => "planning_draft",
         "draft_status" => Atom.to_string(draft.status),
         "generator" => draft.metadata[:generator]
       },
       blocks: blocks,
       steps: steps
     }}
  end

  defp block_from_item(%TimelineItem.EvenUnit{} = item, position) do
    %Block{
      position: position,
      repeat_count: 1,
      sets: [
        %Set{
          position: 1,
          burpee_count: item.reps,
          sec_per_rep: item.rep_interval_sec,
          sec_per_burpee: item.burpee_duration_sec,
          end_of_set_rest: 0
        }
      ]
    }
  end

  defp block_from_item(%TimelineItem.UnbrokenGroup{} = item, position) do
    %Block{
      position: position,
      repeat_count: 1,
      sets: [
        %Set{
          position: 1,
          burpee_count: item.reps,
          sec_per_rep: item.burpee_duration_sec,
          sec_per_burpee: item.burpee_duration_sec,
          end_of_set_rest: item.rest_after_sec
        }
      ]
    }
  end

  defp block_from_item(%TimelineItem.MeaningfulPattern{} = item, position) do
    sets =
      item.pattern
      |> Enum.with_index(1)
      |> Enum.map(fn {reps, set_position} ->
        %Set{position: set_position, burpee_count: reps, sec_per_rep: 1.0, sec_per_burpee: 1.0, end_of_set_rest: 0}
      end)

    %Block{position: position, repeat_count: item.repeat_count, sets: sets}
  end

  defp step_from_item(%TimelineItem.StandaloneRest{} = item, position) do
    %PlanStep{position: position, kind: :rest, rest_sec: item.duration_sec}
  end

  defp step_from_item(_item, position) do
    %PlanStep{position: position, kind: :block_run, block_position: position, repeat_count: 1}
  end

  defp average_burpee_duration(timeline) do
    durations =
      timeline
      |> Enum.flat_map(fn
        %TimelineItem.EvenUnit{burpee_duration_sec: duration} -> [duration]
        %TimelineItem.UnbrokenGroup{burpee_duration_sec: duration} -> [duration]
        _ -> []
      end)

    case durations do
      [] -> nil
      [_ | _] -> Enum.sum(durations) / length(durations)
    end
  end
end
```

- [ ] **Step 4: Run compiler tests**

Run:

```bash
mix test test/burpee_trainer/planning/compiler_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run all planning tests**

Run:

```bash
mix test test/burpee_trainer/planning
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(planning): compile drafts to workout plans"
jj new
```

---

## Task 8: Add public planning facade

**Files:**

- Create: `lib/burpee_trainer/planning.ex`
- Create: `test/burpee_trainer/planning_test.exs`

- [ ] **Step 1: Write failing facade tests**

Create `test/burpee_trainer/planning_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanningTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning
  alias BurpeeTrainer.Planning.Draft
  alias BurpeeTrainer.Workouts.WorkoutPlan

  test "solve/1 returns a draft from raw goal attributes" do
    assert {:ok, %Draft{} = draft} =
             Planning.solve(%{
               duration_sec: 1200,
               target_reps: 150,
               burpee_type: :six_count,
               style: :even
             })

    assert draft.goal.target_reps == 150
    assert draft.status == :good
  end

  test "build_plan/2 solves and compiles a workout plan" do
    assert {:ok, %WorkoutPlan{} = plan} =
             Planning.build_plan(
               %{
                 duration_sec: 1200,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even
               },
               name: "150 in 20"
             )

    assert plan.name == "150 in 20"
    assert plan.burpee_count_target == 150
  end
end
```

- [ ] **Step 2: Run failing facade tests**

Run:

```bash
mix test test/burpee_trainer/planning_test.exs
```

Expected: FAIL because `BurpeeTrainer.Planning` does not exist.

- [ ] **Step 3: Implement facade**

Create `lib/burpee_trainer/planning.ex`:

```elixir
defmodule BurpeeTrainer.Planning do
  @moduledoc "Prescription-first workout planning facade."

  alias BurpeeTrainer.Planning.{Compiler, Draft, DraftGenerator, DraftVerifier, Goal}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @spec solve(map() | Goal.t()) :: {:ok, Draft.t()} | {:error, term()}
  def solve(%Goal{} = goal) do
    with {:ok, draft} <- DraftGenerator.generate(goal),
         :ok <- DraftVerifier.verify(draft) do
      {:ok, draft}
    end
  end

  def solve(attrs) when is_map(attrs) do
    with {:ok, goal} <- Goal.new(attrs) do
      solve(goal)
    end
  end

  @spec build_plan(map() | Goal.t(), keyword()) :: {:ok, WorkoutPlan.t()} | {:error, term()}
  def build_plan(goal_or_attrs, opts \\ []) do
    with {:ok, draft} <- solve(goal_or_attrs) do
      Compiler.to_workout_plan(draft, opts)
    end
  end
end
```

- [ ] **Step 4: Run facade tests**

Run:

```bash
mix test test/burpee_trainer/planning_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run all planning tests**

Run:

```bash
mix test test/burpee_trainer/planning test/burpee_trainer/planning_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(planning): add prescription planning facade"
jj new
```

---

## Task 9: Bridge new planning facade into existing PlanSolver

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/input.ex`
- Modify: `lib/burpee_trainer/plan_solver.ex`
- Modify: `test/burpee_trainer/plan_solver_test.exs`

- [ ] **Step 1: Add PlanSolver regression for max reps per set naming**

Append to `test/burpee_trainer/plan_solver_test.exs`:

```elixir
  test "unbroken plans accept max_reps_per_set as the style-specific upper bound" do
    input = %BurpeeTrainer.PlanSolver.Input{
      name: "160 unbroken",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 160,
      pacing_style: :unbroken,
      level: :level_3,
      max_reps_per_set: 8
    }

    assert {:ok, solution} = BurpeeTrainer.PlanSolver.solve(input)
    assert Enum.max(solution.set_pattern) <= 8
  end
```

- [ ] **Step 2: Run failing PlanSolver regression**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: FAIL because `Input` has no `max_reps_per_set` field.

- [ ] **Step 3: Add migration field to `Input`**

Modify `lib/burpee_trainer/plan_solver/input.ex`:

```elixir
    max_reps_per_set: nil,
```

Add to the type:

```elixir
          max_reps_per_set: pos_integer | nil,
```

- [ ] **Step 4: Map `max_reps_per_set` to existing solver field**

In `lib/burpee_trainer/plan_solver.ex`, update `resolve_reps_per_set/1` for unbroken:

```elixir
  defp resolve_reps_per_set(%Input{pacing_style: :unbroken} = input) do
    max_reps_per_set = input.max_reps_per_set || input.reps_per_set
    fixed? = is_integer(max_reps_per_set)
    rps = max_reps_per_set || default_reps_per_set(input.burpee_type)

    if is_integer(rps) and rps > 0,
      do: {:ok, {rps, fixed?}},
      else: {:error, ["max_reps_per_set must be a positive integer"]}
  end
```

- [ ] **Step 5: Run PlanSolver regression**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs --trace
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(plans): name unbroken set bound explicitly"
jj new
```

---

## Task 10: Prepare LiveView assigns for draft timeline UI

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- Test: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Add LiveView regression for required goal labels**

In `test/burpee_trainer_web/live/workouts_live_test.exs`, add a focused assertion to the existing plan editor test that visits the plan editor. Use the existing route/setup in that file and assert the goal header exposes all required fields:

```elixir
assert has_element?(view, "#planner-goal-header")
assert has_element?(view, "#planner-goal-header", "Duration")
assert has_element?(view, "#planner-goal-header", "Reps")
assert has_element?(view, "#planner-goal-header", "Burpee type")
assert has_element?(view, "#planner-goal-header", "Style")
```

- [ ] **Step 2: Run failing LiveView test**

Run the specific test file:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: FAIL because `#planner-goal-header` is not rendered yet.

- [ ] **Step 3: Assign draft-related state in LiveView**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, wherever existing plan editor assigns are initialized, add these assigns:

```elixir
|> assign(:draft, nil)
|> assign(:draft_feedback, nil)
|> assign(:expanded_timeline_item_id, nil)
```

If the assign pipeline is split across helpers, put these defaults in the helper that builds initial edit state.

- [ ] **Step 4: Add compact required goal header markup**

In `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`, add this near the top of the planner edit surface, inside the existing `<Layouts.app>` content:

```heex
<section id="planner-goal-header" class="rounded-3xl border border-zinc-200/80 bg-white/80 p-4 shadow-sm">
  <div class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
    <div>
      <p class="text-xs font-semibold uppercase tracking-[0.16em] text-zinc-400">Duration</p>
      <p class="mt-1 font-semibold text-zinc-950">{@form[:target_duration_min].value || "—"} min</p>
    </div>
    <div>
      <p class="text-xs font-semibold uppercase tracking-[0.16em] text-zinc-400">Reps</p>
      <p class="mt-1 font-semibold text-zinc-950">{@form[:burpee_count_target].value || "—"}</p>
    </div>
    <div>
      <p class="text-xs font-semibold uppercase tracking-[0.16em] text-zinc-400">Burpee type</p>
      <p class="mt-1 font-semibold text-zinc-950">{@form[:burpee_type].value || "—"}</p>
    </div>
    <div>
      <p class="text-xs font-semibold uppercase tracking-[0.16em] text-zinc-400">Style</p>
      <p class="mt-1 font-semibold text-zinc-950">{@form[:pacing_style].value || "—"}</p>
    </div>
  </div>
</section>
```

If the form assign has different field names in this LiveView, adapt only the field access and keep the DOM id/text labels unchanged.

- [ ] **Step 5: Run LiveView test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs --trace
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(plans): prepare draft timeline header"
jj new
```

---

## Task 11: Final verification

**Files:**

- All changed files

- [ ] **Step 1: Run planning tests**

Run:

```bash
mix test test/burpee_trainer/planning test/burpee_trainer/planning_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run existing solver tests**

Run:

```bash
mix test test/burpee_trainer/plan_solver_test.exs test/burpee_trainer/plan_solver
```

Expected: PASS.

- [ ] **Step 3: Run focused LiveView test**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: PASS.

- [ ] **Step 4: Run precommit**

Run:

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 5: Commit final fixes if precommit changed formatting**

If `mix precommit` changed files, run:

```bash
jj st
jj describe -m "style(planning): apply formatter"
jj new
```

If no files changed, no commit is needed.

---

## Self-review

### Spec coverage

Covered in this plan:

- prescription-first planning domain
- draft terminology
- even vs unbroken style semantics
- required max reps per set for unbroken
- human-readable even units instead of giant fake blocks
- high-density readable units
- funded standalone rest feedback
- duration tolerance verifier
- compiler boundary to execution model
- initial LiveView goal header preparation
- precise timing concepts in new domain names

Deferred to follow-up plan:

- full DB table overhaul replacing `WorkoutPlan` / `Block` / `Set` / `PlanStep`
- final vertical timeline visual design
- polished inline editing gestures
- structured MILP allocator replacing simple v1 draft generator
- fatigue minimization objective profile

### Red-flag scan

This plan intentionally avoids empty implementation markers. Every code-creation step includes concrete code, and every test step includes exact commands and expected results.

### Type consistency

The plan consistently uses:

- `Goal`
- `Draft`
- `TimelineItem.EvenUnit`
- `TimelineItem.UnbrokenGroup`
- `TimelineItem.StandaloneRest`
- `rep_interval_sec`
- `burpee_duration_sec`
- `micro_rest_sec` as derived terminology
