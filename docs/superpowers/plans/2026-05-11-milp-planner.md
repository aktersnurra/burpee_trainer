# MILP Plan Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bespoke `PlanWizard.Solver` constraint pipeline with a MILP model serialized to MPS and solved by the HiGHS CLI, and add a fatigue model that biases rest toward later slots.

**Architecture:** A new `Lp` module builds an `%LpProblem{}` from the existing `%SlotModel{}`. A new `Mps` module serializes it as standard MPS text. A new `Highs` module shells out to the `highs` CLI via `System.cmd/3`, parses the solution file, and returns slot rest values. The existing `PlanWizard`, `PlanInput`, `SlotModel`, `Styles`, `Apply`, and `Errors` modules keep their public interfaces. The old `Reservation` module and all `Constraints/*` modules except `PaceFloor` are deleted.

**Tech Stack:** Elixir 1.15+, Phoenix 1.8, Ecto + SQLite, HiGHS (built from source), ExUnit + StreamData for property tests.

**Reference spec:** `docs/superpowers/specs/2026-05-11-milp-planner-design.md`

---

## File Structure

**Create:**
- `lib/burpee_trainer/plan_wizard/lp/problem.ex` — `%LpProblem{}` struct
- `lib/burpee_trainer/plan_wizard/lp.ex` — `Lp.build/1` (SlotModel → LpProblem)
- `lib/burpee_trainer/plan_wizard/mps.ex` — MPS serializer
- `lib/burpee_trainer/plan_wizard/highs.ex` — HiGHS CLI invoker + solution parser
- `priv/highs_options.txt` — HiGHS options fixture
- `priv/repo/migrations/20260511000000_add_fatigue_factor_to_workout_plans.exs`
- `test/burpee_trainer/plan_wizard/lp_test.exs`
- `test/burpee_trainer/plan_wizard/mps_test.exs`
- `test/burpee_trainer/plan_wizard/highs_test.exs`
- `test/fixtures/planner_golden.exs`

**Modify:**
- `lib/burpee_trainer/plan_wizard/plan_input.ex` — add `fatigue_factor` field
- `lib/burpee_trainer/plan_wizard/slot_model.ex` — add `fatigue_factor` field + `ideal_rests/1`
- `lib/burpee_trainer/plan_wizard/solver.ex` — rewrite pipeline
- `lib/burpee_trainer/plan_wizard.ex` — pass `fatigue_factor` through (unchanged API)
- `lib/burpee_trainer/workouts/workout_plan.ex` — add `fatigue_factor` field + validation
- `lib/burpee_trainer_web/live/plans_live/edit.ex` — add fatigue slider
- `config/config.exs` — add `:highs_path` default
- `README.md` — HiGHS build/install steps
- `CHANGELOG.md`

**Delete (at the end, after parity is verified):**
- `lib/burpee_trainer/plan_wizard/reservation.ex`
- `lib/burpee_trainer/plan_wizard/constraints/minimize_placement_error.ex`
- `lib/burpee_trainer/plan_wizard/constraints/minimize_rest_deviation.ex`
- `lib/burpee_trainer/plan_wizard/constraints/rest_non_negative.ex`
- `lib/burpee_trainer/plan_wizard/constraints/total_duration.ex`
- `lib/burpee_trainer/plan_wizard/constraints/valid_placement.ex`
- `test/burpee_trainer/plan_wizard/reservation_test.exs`
- `test/burpee_trainer/plan_wizard/solver_test.exs` (replaced by new tests)

---

## Task 1: Install HiGHS and verify

**Files:**
- Modify: `README.md` (add install section)

- [ ] **Step 1: Build HiGHS from source locally**

```bash
cd /tmp
git clone https://github.com/ERGO-Code/HiGHS.git
cd HiGHS
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --parallel
sudo cmake --install .
```

Expected: `highs` binary installed to `/usr/local/bin/highs`.

- [ ] **Step 2: Verify install**

Run: `highs --version`
Expected: prints HiGHS version (≥ 1.7.0).

- [ ] **Step 3: Smoke-test with a trivial MPS file**

Write `/tmp/smoke.mps`:
```
NAME          SMOKE
ROWS
 N  COST
 L  C1
COLUMNS
    X1  COST  -1  C1  1
RHS
    RHS  C1  10
BOUNDS
ENDATA
```

Run: `highs /tmp/smoke.mps --solution_file /tmp/smoke.sol`
Expected: `/tmp/smoke.sol` exists; objective ≈ -10.

- [ ] **Step 4: Add HiGHS install section to README**

Append to `README.md` under a new `## Dependencies` section:

````markdown
## Dependencies

This app requires the [HiGHS](https://highs.dev) MILP solver on `$PATH` for plan generation.

### Build from source

```bash
git clone https://github.com/ERGO-Code/HiGHS.git
cd HiGHS && mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --parallel
sudo cmake --install .
```

Verify with `highs --version`. CI builds HiGHS as part of the test image setup.
````

- [ ] **Step 5: Commit**

```bash
jj describe -m "docs: document HiGHS dependency"
jj new
```

---

## Task 2: Add `:highs_path` config and runtime check

**Files:**
- Modify: `config/config.exs`
- Modify: `lib/burpee_trainer/application.ex`

- [ ] **Step 1: Read current config and application files**

Read `config/config.exs` and `lib/burpee_trainer/application.ex` to understand existing structure.

- [ ] **Step 2: Add config default**

In `config/config.exs`, add (near other app-level config):

```elixir
config :burpee_trainer, :highs_path, "highs"
```

- [ ] **Step 3: Add startup check to Application**

In `lib/burpee_trainer/application.ex`, inside `start/2` before the `Supervisor.start_link` call, add:

```elixir
warn_if_highs_missing()
```

And at the bottom of the module:

```elixir
defp warn_if_highs_missing do
  path = Application.get_env(:burpee_trainer, :highs_path, "highs")

  if System.find_executable(path) == nil do
    require Logger
    Logger.warning("HiGHS solver not found on PATH (looked for #{inspect(path)}). " <>
                   "Plan generation will fail until HiGHS is installed.")
  end
end
```

- [ ] **Step 4: Run compile**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add :highs_path config and startup check"
jj new
```

---

## Task 3: Add `fatigue_factor` to `PlanInput`

**Files:**
- Modify: `lib/burpee_trainer/plan_wizard/plan_input.ex`

- [ ] **Step 1: Update the PlanInput struct**

Replace the struct + type definition in `lib/burpee_trainer/plan_wizard/plan_input.ex` with:

```elixir
defstruct [
  :name,
  :burpee_type,
  :target_duration_min,
  :burpee_count_target,
  :sec_per_burpee,
  :pacing_style,
  reps_per_set: nil,
  additional_rests: [],
  fatigue_factor: 0.0
]

@type burpee_type :: :six_count | :navy_seal
@type pacing_style :: :even | :unbroken
@type additional_rest :: %{rest_sec: number, target_min: number}

@type t :: %__MODULE__{
        name: String.t(),
        burpee_type: burpee_type,
        target_duration_min: number,
        burpee_count_target: pos_integer,
        sec_per_burpee: number,
        pacing_style: pacing_style,
        reps_per_set: pos_integer | nil,
        additional_rests: [additional_rest],
        fatigue_factor: float
      }
```

- [ ] **Step 2: Run compile**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 3: Run existing PlanWizard tests**

Run: `mix test test/burpee_trainer/plan_wizard_test.exs test/burpee_trainer/plan_wizard/`
Expected: all pass (default `0.0` preserves behavior).

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat: add fatigue_factor field to PlanInput"
jj new
```

---

## Task 4: Add `fatigue_factor` and `ideal_rests/1` to `SlotModel`

**Files:**
- Modify: `lib/burpee_trainer/plan_wizard/slot_model.ex`
- Test: `test/burpee_trainer/plan_wizard/slot_model_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `test/burpee_trainer/plan_wizard/slot_model_test.exs`:

```elixir
describe "ideal_rests/1" do
  test ":even style with fatigue_factor=0.0 distributes uniformly" do
    input = %BurpeeTrainer.PlanWizard.PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 5,
      sec_per_burpee: 4.0,
      pacing_style: :even,
      fatigue_factor: 0.0
    }

    model = BurpeeTrainer.PlanWizard.SlotModel.new(input, nil)
    ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)
    [first | rest] = ideals

    Enum.each(rest, fn r -> assert_in_delta r, first, 1.0e-6 end)
    assert_in_delta Enum.sum(ideals), BurpeeTrainer.PlanWizard.SlotModel.rest_budget(model), 1.0e-6
  end

  test ":even style with fatigue_factor=1.0 biases later slots" do
    input = %BurpeeTrainer.PlanWizard.PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 5,
      sec_per_burpee: 4.0,
      pacing_style: :even,
      fatigue_factor: 1.0
    }

    model = BurpeeTrainer.PlanWizard.SlotModel.new(input, nil)
    ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)

    # Strictly increasing for :even with fatigue > 0.
    pairs = Enum.zip(ideals, tl(ideals))
    Enum.each(pairs, fn {a, b} -> assert b > a end)

    assert_in_delta Enum.sum(ideals), BurpeeTrainer.PlanWizard.SlotModel.rest_budget(model), 1.0e-6
  end

  test ":unbroken style: zero-weight slots stay zero under fatigue" do
    input = %BurpeeTrainer.PlanWizard.PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      sec_per_burpee: 4.0,
      pacing_style: :unbroken,
      reps_per_set: 5,
      fatigue_factor: 1.0
    }

    model = BurpeeTrainer.PlanWizard.SlotModel.new(input, 5)
    ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)

    # Slot 5 is the only set boundary in a 10-rep, 5-per-set unbroken plan.
    Enum.with_index(ideals, 1)
    |> Enum.each(fn {v, i} ->
      if i == 5, do: assert(v > 0), else: assert_in_delta(v, 0.0, 1.0e-6)
    end)
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test test/burpee_trainer/plan_wizard/slot_model_test.exs --only describe:"ideal_rests/1"`
Expected: FAIL — `ideal_rests/1` undefined and struct missing field.

- [ ] **Step 3: Update SlotModel struct**

In `lib/burpee_trainer/plan_wizard/slot_model.ex`, add `fatigue_factor` to the struct fields and type:

```elixir
@enforce_keys [
  :total_reps,
  :sec_per_burpee,
  :target_duration_sec,
  :style,
  :weights,
  :additional_rests_input
]
defstruct [
  :total_reps,
  :sec_per_burpee,
  :target_duration_sec,
  :style,
  :reps_per_set,
  :weights,
  :additional_rests_input,
  reservations: [],
  slot_rests: nil,
  fatigue_factor: 0.0
]

@type t :: %__MODULE__{
        total_reps: pos_integer,
        sec_per_burpee: number,
        target_duration_sec: number,
        style: Styles.style(),
        reps_per_set: pos_integer | nil,
        weights: [float],
        reservations: [%{slot: pos_integer, rest_sec: number, target_min: number}],
        slot_rests: [float] | nil,
        additional_rests_input: [PlanInput.additional_rest()],
        fatigue_factor: float
      }
```

In `new/2`, pass `fatigue_factor`:

```elixir
def new(%PlanInput{} = input, reps_per_set) do
  %__MODULE__{
    total_reps: input.burpee_count_target,
    sec_per_burpee: input.sec_per_burpee,
    target_duration_sec: input.target_duration_min * 60,
    style: input.pacing_style,
    reps_per_set: reps_per_set,
    weights: Styles.weight_vector(input.pacing_style, input.burpee_count_target, reps_per_set),
    additional_rests_input: input.additional_rests || [],
    fatigue_factor: input.fatigue_factor || 0.0
  }
end
```

- [ ] **Step 4: Add `ideal_rests/1`**

Add at the bottom of the module:

```elixir
@doc """
Fatigue-adjusted ideal rest distribution across slots. Returns a list of
length `total_reps - 1`. Zero-weight slots stay zero. Non-zero slots sum
to `rest_budget(model)`.

Formula:
  fatigue_weight[i]  = 1 + fatigue_factor * (i / (N - 1))
  combined_weight[i] = base_weight[i] * fatigue_weight[i]
  ideal_rest[i]      = budget * combined_weight[i] / Σ combined_weight
"""
@spec ideal_rests(t) :: [float]
def ideal_rests(%__MODULE__{total_reps: n} = m) when n <= 1, do: []

def ideal_rests(%__MODULE__{} = m) do
  n = m.total_reps
  f = m.fatigue_factor || 0.0
  budget = rest_budget(m)

  combined =
    m.weights
    |> Enum.with_index(1)
    |> Enum.map(fn {w, i} -> w * (1.0 + f * (i / (n - 1))) end)

  total = Enum.sum(combined)

  if total == 0.0 do
    List.duplicate(0.0, length(m.weights))
  else
    Enum.map(combined, fn c -> budget * c / total end)
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/burpee_trainer/plan_wizard/slot_model_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add fatigue_factor and ideal_rests to SlotModel"
jj new
```

---

## Task 5: Define the `Lp.Problem` struct

**Files:**
- Create: `lib/burpee_trainer/plan_wizard/lp/problem.ex`

- [ ] **Step 1: Write the struct module**

Write `lib/burpee_trainer/plan_wizard/lp/problem.ex`:

```elixir
defmodule BurpeeTrainer.PlanWizard.Lp.Problem do
  @moduledoc """
  Canonical representation of a linear/MILP problem ready for serialization.

  Variables are referenced by string name. Coefficients are stored in
  sparse form: each constraint and the objective hold a list of
  `{var_name, coefficient}` pairs.

  Variable name conventions used by `BurpeeTrainer.PlanWizard.Lp`:

    * `r_<i>`     — rest at slot i (continuous, ≥ 0)
    * `e_<i>`     — absolute deviation of r_i from ideal (continuous, ≥ 0)
    * `x_<k>_<i>` — binary assignment, reservation k → slot i
    * `y_<k>_<i>` — bilinear linearization, x_{k,i} * slot_end_time[i]
    * `d_<k>`     — placement error for reservation k (continuous, ≥ 0)
  """

  @type sense :: :minimize | :maximize
  @type comparator :: :eq | :leq | :geq
  @type term_ :: {String.t(), float}
  @type constraint :: %{
          name: String.t(),
          terms: [term_],
          comparator: comparator,
          rhs: float
        }
  @type variable :: %{
          name: String.t(),
          type: :continuous | :binary,
          lower: float | :neg_inf,
          upper: float | :pos_inf
        }

  @enforce_keys [:objective_sense, :objective_terms, :variables, :constraints]
  defstruct [:objective_sense, :objective_terms, :variables, :constraints]

  @type t :: %__MODULE__{
          objective_sense: sense,
          objective_terms: [term_],
          variables: [variable],
          constraints: [constraint]
        }
end
```

- [ ] **Step 2: Run compile**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add Lp.Problem struct"
jj new
```

---

## Task 6: Implement `Lp.build/1` — total duration + zero-weight constraints

**Files:**
- Create: `lib/burpee_trainer/plan_wizard/lp.ex`
- Test: `test/burpee_trainer/plan_wizard/lp_test.exs`

This task handles the no-reservation case. Reservation variables (x, y, d) come in Task 7.

- [ ] **Step 1: Write failing test**

Write `test/burpee_trainer/plan_wizard/lp_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanWizard.LpTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Lp, PlanInput, SlotModel}

  describe "build/1 — no reservations" do
    test ":even style produces r_i vars, e_i vars, total-duration equality, deviation rows" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        sec_per_burpee: 4.0,
        pacing_style: :even
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)

      # 4 r vars + 4 e vars
      r_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "r_"))
      e_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "e_"))
      assert length(r_vars) == 4
      assert length(e_vars) == 4
      Enum.each(r_vars, fn v -> assert v.type == :continuous and v.lower == 0.0 end)

      # Total duration equality row
      total_row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))
      assert total_row.comparator == :eq
      assert_in_delta total_row.rhs, 600.0 - 5 * 4.0, 1.0e-6
      assert MapSet.new(Enum.map(total_row.terms, &elem(&1, 0))) ==
               MapSet.new(["r_1", "r_2", "r_3", "r_4"])

      # Deviation linearization rows: 4 e vars × 2 = 8 rows.
      dev_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "DEV_"))
      assert length(dev_rows) == 8

      # Objective minimizes sum of e_i (ε * 1 with no d_k present).
      assert problem.objective_sense == :minimize
      obj_vars = MapSet.new(Enum.map(problem.objective_terms, &elem(&1, 0)))
      assert obj_vars == MapSet.new(["e_1", "e_2", "e_3", "e_4"])
    end

    test ":unbroken style produces zero-rest equality rows for intra-set slots" do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 10,
        sec_per_burpee: 4.0,
        pacing_style: :unbroken,
        reps_per_set: 5
      }

      model = SlotModel.new(input, 5)
      problem = Lp.build(model)

      zero_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "ZERO_SLOT_"))
      # Slots 1,2,3,4,6,7,8,9 are intra-set (8 zero rows). Slot 5 is boundary.
      assert length(zero_rows) == 8
      Enum.each(zero_rows, fn row ->
        assert row.comparator == :eq
        assert row.rhs == 0.0
        assert length(row.terms) == 1
      end)
    end
  end
end
```

- [ ] **Step 2: Run test to verify failure**

Run: `mix test test/burpee_trainer/plan_wizard/lp_test.exs`
Expected: FAIL — `Lp` module undefined.

- [ ] **Step 3: Implement minimal Lp.build/1 (no reservations)**

Write `lib/burpee_trainer/plan_wizard/lp.ex`:

```elixir
defmodule BurpeeTrainer.PlanWizard.Lp do
  @moduledoc """
  Builds an `%Lp.Problem{}` from a `%SlotModel{}`. Pure function — no I/O.

  Reservations contribute binary `x_<k>_<i>` assignment variables and the
  linearization machinery (`y_<k>_<i>`, big-M rest-amount linkage,
  placement-error rows). When there are no reservations, the problem
  reduces to: find `r_i ≥ 0` summing to `rest_budget(model)`, minimize
  `Σ |r_i - r_ideal[i]|` (linearized via `e_i`).
  """

  alias BurpeeTrainer.PlanWizard.{SlotModel}
  alias BurpeeTrainer.PlanWizard.Lp.Problem

  # ε weights the deviation term relative to the placement-error term.
  # Small enough that placement error dominates when reservations exist,
  # large enough to drive the no-reservation case to the ideal distribution.
  @epsilon 1.0e-3

  @spec build(SlotModel.t()) :: Problem.t()
  def build(%SlotModel{} = model) do
    n = model.total_reps
    slot_count = n - 1
    ideal = SlotModel.ideal_rests(model)
    budget = SlotModel.rest_budget(model)

    r_vars = for i <- 1..slot_count, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count, do: continuous("e_#{i}")

    constraints =
      [total_duration_row(slot_count, budget)] ++
        zero_weight_rows(model) ++
        deviation_rows(slot_count, ideal)

    objective_terms = for i <- 1..slot_count, do: {"e_#{i}", @epsilon}

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: r_vars ++ e_vars,
      constraints: constraints
    }
  end

  # ---------------------------------------------------------------------------
  # Variables
  # ---------------------------------------------------------------------------

  defp continuous(name),
    do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}

  # ---------------------------------------------------------------------------
  # Constraint builders
  # ---------------------------------------------------------------------------

  defp total_duration_row(slot_count, budget) do
    %{
      name: "TOTAL_DUR",
      terms: for(i <- 1..slot_count, do: {"r_#{i}", 1.0}),
      comparator: :eq,
      rhs: budget * 1.0
    }
  end

  defp zero_weight_rows(%SlotModel{weights: weights}) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {0.0, i} ->
        [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}]

      _ ->
        []
    end)
  end

  # e_i ≥ r_i - ideal_i  =>  -r_i + e_i ≥ -ideal_i
  # e_i ≥ ideal_i - r_i  =>   r_i + e_i ≥  ideal_i
  defp deviation_rows(slot_count, ideal) do
    Enum.flat_map(1..slot_count, fn i ->
      ideal_i = Enum.at(ideal, i - 1)

      [
        %{
          name: "DEV_POS_#{i}",
          terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: -ideal_i
        },
        %{
          name: "DEV_NEG_#{i}",
          terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: ideal_i
        }
      ]
    end)
  end
end
```

- [ ] **Step 4: Run test to verify pass**

Run: `mix test test/burpee_trainer/plan_wizard/lp_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: implement Lp.build for no-reservation case"
jj new
```

---

## Task 7: Extend `Lp.build/1` with reservation MILP machinery

**Files:**
- Modify: `lib/burpee_trainer/plan_wizard/lp.ex`
- Modify: `test/burpee_trainer/plan_wizard/lp_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `test/burpee_trainer/plan_wizard/lp_test.exs`:

```elixir
describe "build/1 — with reservations" do
  test ":even style: one reservation produces x, y, d vars and linkage rows" do
    # 10 reps × 12s = 120s work; 600s target → 480s rest budget.
    # 1 reservation of 60s at minute 5 (300s); projected nearest slot ≈ 5.
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      sec_per_burpee: 12.0,
      pacing_style: :even,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    x_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "x_"))
    y_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "y_"))
    d_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "d_"))

    assert length(d_vars) == 1
    assert length(x_vars) == length(y_vars)
    assert length(x_vars) >= 1

    Enum.each(x_vars, fn v -> assert v.type == :binary end)

    # Assignment-sum row: Σ x_1_i = 1.
    assert Enum.any?(problem.constraints, fn c ->
             c.name == "ASSIGN_1" and c.comparator == :eq and c.rhs == 1.0
           end)

    # Tolerance bound: d_1 ≤ 30.
    assert Enum.any?(problem.constraints, fn c ->
             c.name == "TOL_1" and c.comparator == :leq and c.rhs == 30.0
           end)

    # Placement error rows.
    assert Enum.any?(problem.constraints, &(&1.name == "PERR_POS_1"))
    assert Enum.any?(problem.constraints, &(&1.name == "PERR_NEG_1"))

    # Objective includes d_1 with weight 1.0.
    assert Enum.any?(problem.objective_terms, fn {n, c} -> n == "d_1" and c == 1.0 end)
  end

  test ":even style: ordering constraint for two reservations" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 20,
      sec_per_burpee: 12.0,
      pacing_style: :even,
      additional_rests: [
        %{rest_sec: 60, target_min: 7},
        %{rest_sec: 60, target_min: 14}
      ]
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    # ORDER_1: Σ i * x_1_i + 1 ≤ Σ i * x_2_i
    #          Σ i * x_2_i - Σ i * x_1_i ≥ 1
    assert Enum.any?(problem.constraints, fn c ->
             c.name == "ORDER_1" and c.comparator == :geq and c.rhs == 1.0
           end)
  end

  test ":unbroken style: AllowedSlots restricted to set boundaries" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 20,
      sec_per_burpee: 12.0,
      pacing_style: :unbroken,
      reps_per_set: 5,
      additional_rests: [%{rest_sec: 60, target_min: 10}]
    }

    model = SlotModel.new(input, 5)
    problem = Lp.build(model)

    # x_1_i variables only exist for boundary slots: 5, 10, 15.
    x_indices =
      problem.variables
      |> Enum.filter(&String.starts_with?(&1.name, "x_1_"))
      |> Enum.map(fn %{name: name} ->
        ["x", "1", i] = String.split(name, "_")
        String.to_integer(i)
      end)
      |> Enum.sort()

    assert Enum.all?(x_indices, fn i -> rem(i, 5) == 0 end)
    assert Enum.member?(x_indices, 10)
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test test/burpee_trainer/plan_wizard/lp_test.exs --only describe:"build/1 — with reservations"`
Expected: FAIL — reservation handling not implemented.

- [ ] **Step 3: Extend Lp.build/1**

Replace the entire body of `lib/burpee_trainer/plan_wizard/lp.ex` with:

```elixir
defmodule BurpeeTrainer.PlanWizard.Lp do
  @moduledoc """
  Builds an `%Lp.Problem{}` from a `%SlotModel{}`. Pure function — no I/O.

  Reservations contribute binary `x_<k>_<i>` assignment variables and the
  linearization machinery (`y_<k>_<i>`, big-M rest-amount linkage,
  placement-error rows).
  """

  alias BurpeeTrainer.PlanWizard.{Errors, SlotModel}
  alias BurpeeTrainer.PlanWizard.Lp.Problem

  @epsilon 1.0e-3

  @spec build(SlotModel.t()) :: Problem.t()
  def build(%SlotModel{} = model) do
    n = model.total_reps
    slot_count = n - 1
    ideal = SlotModel.ideal_rests(model)
    budget = SlotModel.rest_budget(model)
    big_m = max(model.target_duration_sec * 1.0, 1.0)

    reservations =
      model.additional_rests_input
      |> Enum.sort_by(& &1.target_min)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, k} ->
        %{k: k, rest_sec: r.rest_sec * 1.0, target_sec: r.target_min * 60.0}
      end)

    allowed = Enum.map(reservations, &allowed_slots(&1, model))

    r_vars = for i <- 1..slot_count, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count, do: continuous("e_#{i}")

    x_vars =
      for {res, slots} <- Enum.zip(reservations, allowed),
          i <- slots,
          do: binary("x_#{res.k}_#{i}")

    y_vars =
      for {res, slots} <- Enum.zip(reservations, allowed),
          i <- slots,
          do: continuous("y_#{res.k}_#{i}")

    d_vars = for res <- reservations, do: continuous("d_#{res.k}")

    constraints =
      [total_duration_row(slot_count, budget)] ++
        zero_weight_rows(model) ++
        deviation_rows(slot_count, ideal) ++
        assignment_rows(reservations, allowed) ++
        one_per_slot_rows(slot_count, reservations, allowed) ++
        ordering_rows(model, reservations, allowed) ++
        rest_linkage_rows(reservations, allowed, big_m) ++
        y_linearization_rows(reservations, allowed, big_m, slot_count, model.sec_per_burpee) ++
        placement_error_rows(reservations, allowed) ++
        tolerance_rows(reservations)

    objective_terms =
      Enum.map(reservations, fn r -> {"d_#{r.k}", 1.0} end) ++
        for(i <- 1..slot_count, do: {"e_#{i}", @epsilon})

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: r_vars ++ e_vars ++ x_vars ++ y_vars ++ d_vars,
      constraints: constraints
    }
  end

  # ---------------------------------------------------------------------------
  # Allowed slots: projected slot time within ±30s of target_sec.
  # For :unbroken, additionally restricted to set-boundary (non-zero-weight) slots.
  # ---------------------------------------------------------------------------

  defp allowed_slots(%{target_sec: target}, %SlotModel{} = model) do
    projected = projected_slot_times(model)
    tolerance = Errors.placement_tolerance_sec() * 1.0

    projected
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {t, i} ->
      if abs(t - target) <= tolerance and slot_eligible?(model, i),
        do: [i],
        else: []
    end)
  end

  defp slot_eligible?(%SlotModel{style: :unbroken, weights: weights}, i),
    do: Enum.at(weights, i - 1) > 0.0

  defp slot_eligible?(%SlotModel{}, _i), do: true

  # Cumulative wall-clock time at the end of each slot, assuming the
  # fatigue-adjusted ideal distribution. Same as legacy projection
  # otherwise — used solely to prune the binary assignment space.
  defp projected_slot_times(%SlotModel{} = model) do
    s = model.sec_per_burpee
    ideal = SlotModel.ideal_rests(model)

    {times, _} =
      ideal
      |> Enum.with_index(1)
      |> Enum.map_reduce(0.0, fn {rest, i}, acc ->
        t = i * s + acc + rest
        {t, acc + rest}
      end)

    times
  end

  # ---------------------------------------------------------------------------
  # Variables
  # ---------------------------------------------------------------------------

  defp continuous(name),
    do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}

  defp binary(name),
    do: %{name: name, type: :binary, lower: 0.0, upper: 1.0}

  # ---------------------------------------------------------------------------
  # Constraint builders
  # ---------------------------------------------------------------------------

  defp total_duration_row(slot_count, budget) do
    %{
      name: "TOTAL_DUR",
      terms: for(i <- 1..slot_count, do: {"r_#{i}", 1.0}),
      comparator: :eq,
      rhs: budget * 1.0
    }
  end

  defp zero_weight_rows(%SlotModel{weights: weights}) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {0.0, i} ->
        [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}]

      _ ->
        []
    end)
  end

  defp deviation_rows(slot_count, ideal) do
    Enum.flat_map(1..slot_count, fn i ->
      ideal_i = Enum.at(ideal, i - 1)

      [
        %{
          name: "DEV_POS_#{i}",
          terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: -ideal_i
        },
        %{
          name: "DEV_NEG_#{i}",
          terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}],
          comparator: :geq,
          rhs: ideal_i
        }
      ]
    end)
  end

  # Σ x_{k,i} = 1 for each reservation k.
  defp assignment_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.map(fn {res, slots} ->
      %{
        name: "ASSIGN_#{res.k}",
        terms: Enum.map(slots, fn i -> {"x_#{res.k}_#{i}", 1.0} end),
        comparator: :eq,
        rhs: 1.0
      }
    end)
  end

  # Σ_k x_{k,i} ≤ 1 for each slot i (only slots used by ≥ 2 reservations).
  defp one_per_slot_rows(slot_count, reservations, allowed) do
    pairs = Enum.zip(reservations, allowed)

    Enum.flat_map(1..slot_count, fn i ->
      uses =
        for {res, slots} <- pairs, i in slots, do: {"x_#{res.k}_#{i}", 1.0}

      if length(uses) >= 2 do
        [%{name: "ONE_PER_SLOT_#{i}", terms: uses, comparator: :leq, rhs: 1.0}]
      else
        []
      end
    end)
  end

  # For :even style, consecutive reservations k1, k2 (by target_min order):
  #   Σ_i i * x_{k2,i} - Σ_i i * x_{k1,i} ≥ 1
  defp ordering_rows(%SlotModel{style: :even}, reservations, allowed) do
    pairs = Enum.zip(reservations, allowed)

    pairs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{k1_res, k1_slots}, {k2_res, k2_slots}] ->
      terms =
        Enum.map(k2_slots, fn i -> {"x_#{k2_res.k}_#{i}", i * 1.0} end) ++
          Enum.map(k1_slots, fn i -> {"x_#{k1_res.k}_#{i}", -i * 1.0} end)

      %{
        name: "ORDER_#{k1_res.k}",
        terms: terms,
        comparator: :geq,
        rhs: 1.0
      }
    end)
  end

  defp ordering_rows(_model, _reservations, _allowed), do: []

  # r_i ≥ R_k - M(1 - x_{k,i})  =>  r_i + M * x_{k,i} ≥ R_k + M ... wait, rearrange:
  #   r_i - R_k + M - M*x_{k,i} ≥ 0  =>  r_i - M*x_{k,i} ≥ R_k - M
  # r_i ≤ R_k + M(1 - x_{k,i})  =>  r_i + M*x_{k,i} ≤ R_k + M
  defp rest_linkage_rows(reservations, allowed, big_m) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        [
          %{
            name: "RLINK_LO_#{res.k}_#{i}",
            terms: [{"r_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :geq,
            rhs: res.rest_sec - big_m
          },
          %{
            name: "RLINK_HI_#{res.k}_#{i}",
            terms: [{"r_#{i}", 1.0}, {"x_#{res.k}_#{i}", big_m}],
            comparator: :leq,
            rhs: res.rest_sec + big_m
          }
        ]
      end)
    end)
  end

  # slot_end_time[i] = i * S + Σ_{j≤i} r_j
  #
  # y_{k,i} ≤ M * x_{k,i}                     => y_{k,i} - M*x_{k,i} ≤ 0
  # y_{k,i} ≤ slot_end_time[i]                => y_{k,i} - i*S - Σ_{j≤i} r_j ≤ 0
  # y_{k,i} ≥ slot_end_time[i] - M(1 - x_{k,i})
  #     => y_{k,i} - i*S - Σ_{j≤i} r_j + M*x_{k,i} ≥ -M   (after moving M)
  #     But M (1 - x) means subtract M when x=0, subtract 0 when x=1.
  #     y ≥ slot_end - M + M*x  =>  y - slot_end - M*x ≥ -M
  #     =>  y_{k,i} - i*S - Σ_{j≤i} r_j - M*x_{k,i} ≥ -M
  # y_{k,i} ≥ 0  (handled by variable bound)
  defp y_linearization_rows(reservations, allowed, big_m, _slot_count, sec_per_burpee) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        slot_end_terms = for j <- 1..i, do: {"r_#{j}", -1.0}

        [
          # y_{k,i} ≤ M * x_{k,i}
          %{
            name: "YBND_X_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :leq,
            rhs: 0.0
          },
          # y_{k,i} ≤ i*S + Σ_{j≤i} r_j
          %{
            name: "YBND_SE_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0} | slot_end_terms],
            comparator: :leq,
            rhs: i * sec_per_burpee * 1.0
          },
          # y_{k,i} ≥ slot_end_time[i] - M(1 - x_{k,i})
          %{
            name: "YBND_LO_#{res.k}_#{i}",
            terms: [
              {"y_#{res.k}_#{i}", 1.0},
              {"x_#{res.k}_#{i}", -big_m} | slot_end_terms
            ],
            comparator: :geq,
            rhs: i * sec_per_burpee * 1.0 - big_m
          }
        ]
      end)
    end)
  end

  # actual_k = Σ_i y_{k,i}
  # d_k ≥ actual_k - T_k   =>  d_k - Σ_i y_{k,i} ≥ -T_k
  # d_k ≥ T_k - actual_k   =>  d_k + Σ_i y_{k,i} ≥  T_k
  defp placement_error_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      y_terms_neg = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", -1.0} end)
      y_terms_pos = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", 1.0} end)

      [
        %{
          name: "PERR_POS_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_terms_neg],
          comparator: :geq,
          rhs: -res.target_sec
        },
        %{
          name: "PERR_NEG_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_terms_pos],
          comparator: :geq,
          rhs: res.target_sec
        }
      ]
    end)
  end

  defp tolerance_rows(reservations) do
    Enum.map(reservations, fn res ->
      %{
        name: "TOL_#{res.k}",
        terms: [{"d_#{res.k}", 1.0}],
        comparator: :leq,
        rhs: Errors.placement_tolerance_sec() * 1.0
      }
    end)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/burpee_trainer/plan_wizard/lp_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: extend Lp.build with reservation MILP machinery"
jj new
```

---

## Task 8: Implement `Mps.serialize/1`

**Files:**
- Create: `lib/burpee_trainer/plan_wizard/mps.ex`
- Test: `test/burpee_trainer/plan_wizard/mps_test.exs`

- [ ] **Step 1: Write failing tests**

Write `test/burpee_trainer/plan_wizard/mps_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanWizard.MpsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Lp, Mps, PlanInput, SlotModel}

  test "serializes a minimal no-reservation :even problem to a valid MPS string" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 5,
      sec_per_burpee: 4.0,
      pacing_style: :even
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)
    text = Mps.serialize(problem)

    assert text =~ ~r/^NAME\s+BURPEE_PLAN/
    assert text =~ "ROWS"
    assert text =~ "COLUMNS"
    assert text =~ "RHS"
    assert text =~ "BOUNDS"
    assert text =~ ~r/ENDATA\s*\z/

    # Objective row tagged as N (free row).
    assert text =~ ~r/^\s*N\s+COST/m
    # Total duration row tagged as E (equality).
    assert text =~ ~r/^\s*E\s+TOTAL_DUR/m
  end

  test "wraps binary variables in INTORG/INTEND markers" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      sec_per_burpee: 12.0,
      pacing_style: :even,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)
    text = Mps.serialize(problem)

    assert text =~ "'MARKER'"
    assert text =~ "'INTORG'"
    assert text =~ "'INTEND'"
  end

  test "round-trips through HiGHS without error" do
    # Sanity check: HiGHS reads the MPS we emit. Requires highs on PATH.
    if System.find_executable("highs") do
      input = %PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        sec_per_burpee: 4.0,
        pacing_style: :even
      }

      model = SlotModel.new(input, nil)
      problem = Lp.build(model)
      text = Mps.serialize(problem)

      path = Path.join(System.tmp_dir!(), "mps_round_trip_#{:erlang.unique_integer([:positive])}.mps")
      File.write!(path, text)

      try do
        {output, exit_code} = System.cmd("highs", [path], stderr_to_stdout: true)
        assert exit_code == 0, "highs failed: #{output}"
      after
        File.rm(path)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify failure**

Run: `mix test test/burpee_trainer/plan_wizard/mps_test.exs`
Expected: FAIL — `Mps` module undefined.

- [ ] **Step 3: Implement Mps.serialize/1**

Write `lib/burpee_trainer/plan_wizard/mps.ex`:

```elixir
defmodule BurpeeTrainer.PlanWizard.Mps do
  @moduledoc """
  Serializes a `%Lp.Problem{}` to standard MPS format.

  Conventions:
    * Free objective row is named "COST".
    * Binary variables are wrapped in MARKER 'INTORG'/'INTEND' blocks.
    * Continuous variables ≥ 0 have lower bound 0 (implicit, but emitted
      for clarity).
  """

  alias BurpeeTrainer.PlanWizard.Lp.Problem

  @objective_row "COST"

  @spec serialize(Problem.t()) :: String.t()
  def serialize(%Problem{} = p) do
    IO.iodata_to_binary([
      "NAME          BURPEE_PLAN\n",
      "ROWS\n",
      rows_section(p),
      "COLUMNS\n",
      columns_section(p),
      "RHS\n",
      rhs_section(p),
      "BOUNDS\n",
      bounds_section(p),
      "ENDATA\n"
    ])
  end

  # ---------------------------------------------------------------------------
  # ROWS
  # ---------------------------------------------------------------------------

  defp rows_section(p) do
    [
      " N  #{@objective_row}\n"
      | Enum.map(p.constraints, fn c -> " #{row_tag(c.comparator)}  #{c.name}\n" end)
    ]
  end

  defp row_tag(:eq), do: "E"
  defp row_tag(:leq), do: "L"
  defp row_tag(:geq), do: "G"

  # ---------------------------------------------------------------------------
  # COLUMNS
  #
  # Group entries by variable. For each variable, emit one or more lines:
  #     <varname>  <row1>  <coef1>  <row2>  <coef2>
  # Pair entries to keep lines compact. Binary variables are bracketed by
  # MARKER lines.
  # ---------------------------------------------------------------------------

  defp columns_section(p) do
    by_var = group_terms_by_var(p)

    p.variables
    |> Enum.map_reduce(:continuous, fn var, prev_kind ->
      entries = Map.get(by_var, var.name, [])
      lines = column_lines(var.name, entries)

      transitions =
        cond do
          prev_kind != :binary and var.type == :binary -> [intorg_marker()]
          prev_kind == :binary and var.type != :binary -> [intend_marker()]
          true -> []
        end

      {[transitions, lines], var.type}
    end)
    |> case do
      {iodata, :binary} -> [iodata, intend_marker()]
      {iodata, _} -> iodata
    end
  end

  defp intorg_marker, do: "    MARKER                 'MARKER'                 'INTORG'\n"
  defp intend_marker, do: "    MARKER                 'MARKER'                 'INTEND'\n"

  defp group_terms_by_var(p) do
    obj_entries = Enum.map(p.objective_terms, fn {name, c} -> {name, {@objective_row, c}} end)

    constraint_entries =
      Enum.flat_map(p.constraints, fn con ->
        Enum.map(con.terms, fn {name, c} -> {name, {con.name, c}} end)
      end)

    (obj_entries ++ constraint_entries)
    |> Enum.reduce(%{}, fn {var, pair}, acc ->
      Map.update(acc, var, [pair], &[pair | &1])
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp column_lines(_var_name, []), do: []

  defp column_lines(var_name, entries) do
    entries
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [{r1, c1}, {r2, c2}] ->
        "    #{var_name}  #{r1}  #{fmt(c1)}   #{r2}  #{fmt(c2)}\n"

      [{r1, c1}] ->
        "    #{var_name}  #{r1}  #{fmt(c1)}\n"
    end)
  end

  # ---------------------------------------------------------------------------
  # RHS
  # ---------------------------------------------------------------------------

  defp rhs_section(p) do
    p.constraints
    |> Enum.reject(fn c -> c.rhs == 0.0 end)
    |> Enum.map(fn c -> "    RHS  #{c.name}  #{fmt(c.rhs)}\n" end)
  end

  # ---------------------------------------------------------------------------
  # BOUNDS
  #
  # Continuous variables: default lower 0, upper +inf (no row needed for
  # default). Binary variables: emit `BV` for both bounds at once.
  # ---------------------------------------------------------------------------

  defp bounds_section(p) do
    Enum.flat_map(p.variables, fn
      %{type: :binary, name: name} ->
        [" BV BND  #{name}\n"]

      %{type: :continuous, lower: 0.0, upper: :pos_inf} ->
        []

      %{type: :continuous, name: name, lower: lower, upper: upper} ->
        [
          if(lower != 0.0, do: " LO BND  #{name}  #{fmt(lower)}\n", else: []),
          if(upper != :pos_inf, do: " UP BND  #{name}  #{fmt(upper)}\n", else: [])
        ]
    end)
  end

  # ---------------------------------------------------------------------------
  # Number formatting — fixed-precision, no scientific notation.
  # ---------------------------------------------------------------------------

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 6)
  defp fmt(n) when is_integer(n), do: :erlang.float_to_binary(n * 1.0, decimals: 6)
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/burpee_trainer/plan_wizard/mps_test.exs`
Expected: PASS, including the HiGHS round-trip.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: implement MPS serializer"
jj new
```

---

## Task 9: Add HiGHS options fixture and `Highs.solve/1`

**Files:**
- Create: `priv/highs_options.txt`
- Create: `lib/burpee_trainer/plan_wizard/highs.ex`
- Test: `test/burpee_trainer/plan_wizard/highs_test.exs`

- [ ] **Step 1: Write the options fixture**

Write `priv/highs_options.txt`:

```
presolve = on
time_limit = 5
mip_rel_gap = 1.0e-6
solution_file = highs.sol
write_solution_style = 1
```

(`write_solution_style = 1` emits a parseable text format.)

- [ ] **Step 2: Write failing tests**

Write `test/burpee_trainer/plan_wizard/highs_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanWizard.HighsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Highs, Lp, PlanInput, SlotModel}

  @moduletag :highs

  test "solves a no-reservation :even plan and returns slot rest values" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 5,
      sec_per_burpee: 4.0,
      pacing_style: :even
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    assert {:ok, %{r: r, objective: _obj}} = Highs.solve(problem)
    assert length(r) == 4
    Enum.each(r, fn v -> assert v >= -1.0e-6 end)
    assert_in_delta Enum.sum(r), 600.0 - 5 * 4.0, 1.0e-3
  end

  test "solves a :unbroken plan with one reservation" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 20,
      sec_per_burpee: 12.0,
      pacing_style: :unbroken,
      reps_per_set: 5,
      additional_rests: [%{rest_sec: 60, target_min: 10}]
    }

    model = SlotModel.new(input, 5)
    problem = Lp.build(model)

    assert {:ok, %{r: r}} = Highs.solve(problem)
    # Total rest = target - work = 1200 - 240 = 960.
    assert_in_delta Enum.sum(r), 960.0, 1.0e-2
  end

  test "returns :infeasible for an unsatisfiable problem" do
    # Reservation 200s requested but plan has no slot near min 0.
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      sec_per_burpee: 12.0,
      pacing_style: :even,
      # target_min: 0.001 → 0.06s, no slot is that early.
      additional_rests: [%{rest_sec: 60, target_min: 0.001}]
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    assert {:error, :infeasible} = Highs.solve(problem)
  end
end
```

- [ ] **Step 3: Run test to verify failure**

Run: `mix test test/burpee_trainer/plan_wizard/highs_test.exs`
Expected: FAIL — `Highs` module undefined.

- [ ] **Step 4: Implement Highs.solve/1**

Write `lib/burpee_trainer/plan_wizard/highs.ex`:

```elixir
defmodule BurpeeTrainer.PlanWizard.Highs do
  @moduledoc """
  Invokes the HiGHS CLI to solve an `%Lp.Problem{}`.

  Workflow:
    1. Serialize the problem to MPS.
    2. Write to a uniquely-named temp file.
    3. Run `highs <mps> --solution_file <sol>`.
    4. Parse the solution file for status, objective, and `r_*` values.
    5. Clean up temp files.

  Configurable binary path via `:burpee_trainer, :highs_path` (default
  `"highs"`).
  """

  alias BurpeeTrainer.PlanWizard.{Lp.Problem, Mps}

  @options_file "highs_options.txt"

  @spec solve(Problem.t()) ::
          {:ok, %{r: [float], objective: float}}
          | {:error, :infeasible | :timeout | {:exit, integer, String.t()}}
  def solve(%Problem{} = problem) do
    mps = Mps.serialize(problem)
    base = "burpee_#{:erlang.unique_integer([:positive])}"
    mps_path = Path.join(System.tmp_dir!(), "#{base}.mps")
    sol_path = Path.join(System.tmp_dir!(), "#{base}.sol")

    try do
      File.write!(mps_path, mps)
      run_highs(mps_path, sol_path, problem)
    after
      File.rm(mps_path)
      File.rm(sol_path)
    end
  end

  defp run_highs(mps_path, sol_path, problem) do
    bin = Application.get_env(:burpee_trainer, :highs_path, "highs")
    options_path = Application.app_dir(:burpee_trainer, ["priv", @options_file])

    args = [
      mps_path,
      "--solution_file",
      sol_path,
      "--options_file",
      options_path
    ]

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_solution(sol_path, output, problem)

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  # HiGHS solution format (write_solution_style = 1):
  #
  #   Model status        : Optimal
  #   ...
  #   # Columns
  #   r_1   3.5
  #   r_2   2.1
  #   ...
  #   # Rows
  #   ...
  defp parse_solution(sol_path, output, problem) do
    case File.read(sol_path) do
      {:ok, contents} ->
        cond do
          status_line(contents) =~ ~r/infeasible/i -> {:error, :infeasible}
          status_line(contents) =~ ~r/time limit/i -> {:error, :timeout}
          status_line(contents) =~ ~r/optimal/i -> extract_values(contents, problem)
          true -> {:error, {:exit, 0, "unexpected status: #{status_line(contents)} / #{output}"}}
        end

      {:error, _} ->
        # No solution file usually means infeasible at presolve.
        if output =~ ~r/infeasible/i,
          do: {:error, :infeasible},
          else: {:error, {:exit, 0, output}}
    end
  end

  defp status_line(contents) do
    case Regex.run(~r/Model status\s*:\s*(.*)/i, contents) do
      [_, status] -> String.trim(status)
      _ -> ""
    end
  end

  defp extract_values(contents, problem) do
    # The "# Columns" section lists `<name> <value>` per variable.
    columns_section =
      contents
      |> String.split(~r/#\s*Columns/i, parts: 2)
      |> Enum.at(1, "")
      |> String.split(~r/#\s*Rows/i, parts: 2)
      |> List.first()

    values =
      columns_section
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [name, value] -> [{name, parse_float(value)}]
          _ -> []
        end
      end)
      |> Map.new()

    slot_count =
      problem.variables
      |> Enum.filter(&String.starts_with?(&1.name, "r_"))
      |> length()

    r =
      for i <- 1..slot_count,
          do: Map.get(values, "r_#{i}", 0.0) |> max(0.0)

    objective =
      case Regex.run(~r/Objective value\s*:\s*([\-0-9.eE+]+)/i, contents) do
        [_, v] -> parse_float(v)
        _ -> 0.0
      end

    {:ok, %{r: r, objective: objective}}
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/burpee_trainer/plan_wizard/highs_test.exs`
Expected: PASS.

If the HiGHS solution-file format differs from the parser (HiGHS versions vary), inspect a sample output with `highs <mps> --solution_file /tmp/out.sol` and adjust the parser to match. Common variants: a header `# Status`, `# Primal solution values`, etc.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: implement Highs.solve via System.cmd"
jj new
```

---

## Task 10: Rewrite `Solver` to use the new pipeline

**Files:**
- Modify: `lib/burpee_trainer/plan_wizard/solver.ex`
- Test: `test/burpee_trainer/plan_wizard_test.exs` (existing — should still pass)

- [ ] **Step 1: Rewrite Solver**

Replace `lib/burpee_trainer/plan_wizard/solver.ex` with:

```elixir
defmodule BurpeeTrainer.PlanWizard.Solver do
  @moduledoc """
  Orchestrates the MILP solver pipeline:

    1. `PaceFloor.check_input/1` — pace ≥ floor, work fits in target,
       additional rests don't force cadence below floor.
    2. `SlotModel.new/2` — build universal slot representation.
    3. `Lp.build/1` — construct `%Lp.Problem{}` from the slot model.
    4. `Highs.solve/1` — invoke HiGHS, parse solution.
    5. Inject `r[i]` values into `slot_rests`; populate `reservations` from
       the binary assignment values for downstream `Apply`.

  Errors from HiGHS are mapped to user-facing strings via
  `BurpeeTrainer.PlanWizard.Errors`.
  """

  alias BurpeeTrainer.PlanWizard.{Errors, Highs, Lp, PlanInput, SlotModel}
  alias BurpeeTrainer.PlanWizard.Constraints.PaceFloor

  @spec solve(PlanInput.t(), pos_integer | nil) ::
          {:ok, SlotModel.t()} | {:error, [String.t()]}
  def solve(%PlanInput{} = input, reps_per_set \\ nil) do
    with :ok <- PaceFloor.check_input(input),
         model = SlotModel.new(input, reps_per_set),
         problem = Lp.build(model),
         {:ok, %{r: r}} <- run_solver(problem, input) do
      {:ok, fill_solution(model, problem, r)}
    end
  end

  defp run_solver(problem, input) do
    case Highs.solve(problem) do
      {:ok, _} = ok -> ok
      {:error, :infeasible} -> {:error, [infeasibility_message(input)]}
      {:error, :timeout} -> {:error, ["plan solver timed out"]}
      {:error, {:exit, code, output}} -> {:error, ["plan solver failed (exit #{code}): #{output}"]}
    end
  end

  defp infeasibility_message(%PlanInput{additional_rests: [_ | _] = rests, pacing_style: style}) do
    # Pick the rest with the largest target_min — the most likely to be
    # unplaceable given that work occupies the early portion of the workout.
    %{target_min: t} = Enum.max_by(rests, & &1.target_min)

    case style do
      :even -> Errors.cannot_place_rest_out_of_tolerance_even(t, t, Errors.placement_tolerance_sec())
      :unbroken -> Errors.cannot_place_rest_out_of_tolerance_unbroken(t, t, Errors.placement_tolerance_sec())
    end
  end

  defp infeasibility_message(%PlanInput{} = input) do
    work_sec = input.burpee_count_target * input.sec_per_burpee
    target_sec = input.target_duration_min * 60
    Errors.work_exceeds_target(work_sec, target_sec)
  end

  # Populate slot_rests; recover reservation slot assignments by finding
  # the slot whose rest matches each reservation's rest_sec (small float
  # tolerance). Falls back to nearest-rest match for robustness.
  defp fill_solution(%SlotModel{} = model, _problem, r) do
    reservations = recover_reservations(model, r)
    %{model | slot_rests: r, reservations: reservations}
  end

  defp recover_reservations(%SlotModel{additional_rests_input: []}, _r), do: []

  defp recover_reservations(%SlotModel{} = model, r) do
    model.additional_rests_input
    |> Enum.sort_by(& &1.target_min)
    |> Enum.with_index(1)
    |> Enum.map_reduce(MapSet.new(), fn {rest, _k}, taken ->
      slot =
        r
        |> Enum.with_index(1)
        |> Enum.reject(fn {_v, i} -> MapSet.member?(taken, i) end)
        |> Enum.min_by(fn {v, _i} -> abs(v - rest.rest_sec) end)
        |> elem(1)

      reservation = %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}
      {reservation, MapSet.put(taken, slot)}
    end)
    |> elem(0)
  end
end
```

- [ ] **Step 2: Update PlanWizard to pass fatigue_factor (no API change)**

In `lib/burpee_trainer/plan_wizard.ex`, no change is needed if `Solver.solve/2` already takes `PlanInput`. Verify by re-reading the file:

Read: `lib/burpee_trainer/plan_wizard.ex`
Confirm: `Solver.solve(input, reps_per_set)` is called with the full input.

- [ ] **Step 3: Run existing PlanWizard top-level test**

Run: `mix test test/burpee_trainer/plan_wizard_test.exs`
Expected: PASS — golden-equivalent outputs for default `fatigue_factor: 0.0`.

If failures occur due to small numerical differences, document them and update tests if the new outputs are within the existing `±1ms` cadence / `±0.1s` total tolerances. If outside tolerance, investigate before continuing.

- [ ] **Step 4: Delete the now-superseded solver test**

```bash
rm test/burpee_trainer/plan_wizard/solver_test.exs
rm test/burpee_trainer/plan_wizard/reservation_test.exs
```

- [ ] **Step 5: Run full plan_wizard test directory**

Run: `mix test test/burpee_trainer/plan_wizard*`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: rewrite Solver to use MILP pipeline"
jj new
```

---

## Task 11: Add `fatigue_factor` to `WorkoutPlan` schema + migration

**Files:**
- Create: `priv/repo/migrations/20260511000000_add_fatigue_factor_to_workout_plans.exs`
- Modify: `lib/burpee_trainer/workouts/workout_plan.ex`

- [ ] **Step 1: Create migration**

Write `priv/repo/migrations/20260511000000_add_fatigue_factor_to_workout_plans.exs`:

```elixir
defmodule BurpeeTrainer.Repo.Migrations.AddFatigueFactorToWorkoutPlans do
  use Ecto.Migration

  def change do
    alter table(:workout_plans) do
      add :fatigue_factor, :float, default: 0.0, null: false
    end
  end
end
```

- [ ] **Step 2: Run migration**

Run: `mix ecto.migrate`
Expected: migration succeeds.

- [ ] **Step 3: Update WorkoutPlan schema**

Replace the schema block and changeset in `lib/burpee_trainer/workouts/workout_plan.ex` to include `fatigue_factor`:

```elixir
schema "workout_plans" do
  field :name, :string
  field :burpee_type, Ecto.Enum, values: @burpee_types
  field :target_duration_min, :integer
  field :burpee_count_target, :integer
  field :sec_per_burpee, :float
  field :pacing_style, Ecto.Enum, values: @pacing_styles
  field :additional_rests, :string, default: "[]"
  field :style_name, :string
  field :fatigue_factor, :float, default: 0.0

  belongs_to :user, User

  has_many :blocks, Block,
    foreign_key: :plan_id,
    preload_order: [asc: :position],
    on_replace: :delete

  timestamps(type: :utc_datetime)
end
```

And in the changeset:

```elixir
def changeset(plan, attrs) do
  plan
  |> cast(attrs, [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :sec_per_burpee,
    :pacing_style,
    :additional_rests,
    :style_name,
    :fatigue_factor
  ])
  |> validate_required([:name, :burpee_type])
  |> validate_length(:name, min: 1, max: 80)
  |> validate_number(:target_duration_min, greater_than: 0)
  |> validate_number(:burpee_count_target, greater_than: 0)
  |> validate_number(:sec_per_burpee, greater_than: 0)
  |> validate_number(:fatigue_factor, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  |> cast_assoc(:blocks,
    with: &Block.changeset/2,
    sort_param: :blocks_sort,
    drop_param: :blocks_drop,
    required: true
  )
end
```

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add fatigue_factor field to WorkoutPlan"
jj new
```

---

## Task 12: Wire `fatigue_factor` through `Apply` and `PlanWizard`

**Files:**
- Modify: `lib/burpee_trainer/plan_wizard/apply.ex`

`Apply.wrap_plan/2` builds the `%WorkoutPlan{}` from `PlanInput`. Add `fatigue_factor` to the wrapper.

- [ ] **Step 1: Update wrap_plan**

In `lib/burpee_trainer/plan_wizard/apply.ex`, replace `wrap_plan/2` with:

```elixir
defp wrap_plan(input, blocks) do
  %WorkoutPlan{
    name: input.name,
    burpee_type: input.burpee_type,
    target_duration_min: input.target_duration_min,
    burpee_count_target: input.burpee_count_target,
    sec_per_burpee: input.sec_per_burpee,
    pacing_style: input.pacing_style,
    additional_rests: encode_rests(input.additional_rests || []),
    fatigue_factor: input.fatigue_factor || 0.0,
    blocks: blocks
  }
end
```

- [ ] **Step 2: Run apply tests**

Run: `mix test test/burpee_trainer/plan_wizard/apply_test.exs`
Expected: PASS (default `0.0` preserves existing assertions).

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: pass fatigue_factor through Apply.wrap_plan"
jj new
```

---

## Task 13: Add fatigue slider to plan edit LiveView

**Files:**
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`

- [ ] **Step 1: Read current edit form**

Read `lib/burpee_trainer_web/live/plans_live/edit.ex` to find where pacing-style and additional-rest controls are rendered.

- [ ] **Step 2: Add fatigue control to the form**

Locate the form section (likely near pacing_style). Add a segmented control near it:

```heex
<div class="space-y-2">
  <label class="block text-sm font-medium">Fatigue bias</label>
  <div class="flex gap-2" role="radiogroup" aria-label="Fatigue bias">
    <label class={"px-3 py-2 border rounded cursor-pointer " <>
                  if @form[:fatigue_factor].value in [0.0, "0.0", nil], do: "bg-[#4A9EFF] text-white", else: "bg-transparent"}>
      <input type="radio" name="workout_plan[fatigue_factor]" value="0.0" class="sr-only"
             checked={@form[:fatigue_factor].value in [0.0, "0.0", nil]} />
      None
    </label>
    <label class={"px-3 py-2 border rounded cursor-pointer " <>
                  if to_string(@form[:fatigue_factor].value) == "0.5", do: "bg-[#4A9EFF] text-white", else: "bg-transparent"}>
      <input type="radio" name="workout_plan[fatigue_factor]" value="0.5" class="sr-only"
             checked={to_string(@form[:fatigue_factor].value) == "0.5"} />
      Mild
    </label>
    <label class={"px-3 py-2 border rounded cursor-pointer " <>
                  if to_string(@form[:fatigue_factor].value) == "1.0", do: "bg-[#4A9EFF] text-white", else: "bg-transparent"}>
      <input type="radio" name="workout_plan[fatigue_factor]" value="1.0" class="sr-only"
             checked={to_string(@form[:fatigue_factor].value) == "1.0"} />
      Strong
    </label>
  </div>
  <p class="text-xs text-gray-500">Bias rest periods toward later in the workout.</p>
</div>
```

(If the actual form uses a `simple_form` or specific component, adapt to match. The exact placement is at the engineer's judgment — near pacing_style is the right location.)

- [ ] **Step 3: Pass `fatigue_factor` from form to PlanInput when generating**

Find where `PlanInput` is built from form params in the LiveView. Add `fatigue_factor: parse_fatigue(params["fatigue_factor"])` where:

```elixir
defp parse_fatigue(nil), do: 0.0
defp parse_fatigue(""), do: 0.0
defp parse_fatigue(v) when is_binary(v), do: String.to_float(v)
defp parse_fatigue(v) when is_number(v), do: v * 1.0
```

- [ ] **Step 4: Run compile + boot dev server**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

Run: `mix phx.server` (background) and visit `/plans/new`. Confirm the fatigue control renders. Stop the server.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add fatigue bias control to plan edit form"
jj new
```

---

## Task 14: Capture golden fixtures for legacy parity

**Files:**
- Create: `test/fixtures/planner_golden.exs`
- Create: `test/burpee_trainer/plan_wizard/golden_test.exs`

- [ ] **Step 1: Write the golden fixtures**

Write `test/fixtures/planner_golden.exs`:

```elixir
# Golden inputs and expected outputs for plan generation.
# Outputs were captured after the MILP rewrite and locked. Regenerate with
# `mix run test/fixtures/regenerate_golden.exs` only if the formulation
# itself changes.
[
  %{
    name: "even, 50 reps, 10 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g1",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 50,
      sec_per_burpee: 5.0,
      pacing_style: :even
    },
    expect: %{block_count: 1, total_sets: 1, total_reps: 50, duration_sec: 600}
  },
  %{
    name: "even, 50 reps, 10 min, one rest at min 5",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g2",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 50,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    },
    expect: %{block_count: 2, total_sets: 2, total_reps: 50, duration_sec: 600}
  },
  %{
    name: "unbroken, 20 reps × 5 per set, 6 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g3",
      burpee_type: :six_count,
      target_duration_min: 6,
      burpee_count_target: 20,
      sec_per_burpee: 5.0,
      pacing_style: :unbroken,
      reps_per_set: 5
    },
    expect: %{block_count: 1, total_sets: 4, total_reps: 20, duration_sec: 360}
  },
  %{
    name: "navy_seal, even, 25 reps, 4 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g4",
      burpee_type: :navy_seal,
      target_duration_min: 4,
      burpee_count_target: 25,
      sec_per_burpee: 9.0,
      pacing_style: :even
    },
    expect: %{block_count: 1, total_sets: 1, total_reps: 25, duration_sec: 240}
  }
]
```

- [ ] **Step 2: Write the test**

Write `test/burpee_trainer/plan_wizard/golden_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanWizard.GoldenTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard
  alias BurpeeTrainer.Workouts.{Block, Set}

  @golden Code.eval_file("test/fixtures/planner_golden.exs") |> elem(0)

  for {fixture, idx} <- Enum.with_index(@golden) do
    @fixture fixture
    @tag fixture: idx
    test "golden: #{fixture.name}" do
      assert {:ok, plan} = PlanWizard.generate(@fixture.input)

      sets = Enum.flat_map(plan.blocks, fn %Block{sets: sets} -> sets end)
      total_reps = Enum.reduce(sets, 0, fn %Set{burpee_count: c}, acc -> acc + c end)

      duration =
        Enum.reduce(sets, 0, fn %Set{burpee_count: c, sec_per_rep: spr, end_of_set_rest: r}, acc ->
          acc + c * spr + r
        end)

      assert length(plan.blocks) == @fixture.expect.block_count
      assert length(sets) == @fixture.expect.total_sets
      assert total_reps == @fixture.expect.total_reps
      assert_in_delta duration, @fixture.expect.duration_sec, 1.0
    end
  end
end
```

- [ ] **Step 3: Run golden tests**

Run: `mix test test/burpee_trainer/plan_wizard/golden_test.exs`
Expected: PASS.

If a fixture fails, inspect the actual output and decide: is the new behavior correct (update expectation) or is there a regression (fix the code)?

- [ ] **Step 4: Commit**

```bash
jj describe -m "test: lock golden fixtures for plan generation"
jj new
```

---

## Task 15: Delete superseded constraint modules

**Files:**
- Delete: 5 constraint files and any orphaned tests

- [ ] **Step 1: Confirm no references**

Run: `grep -rn "MinimizePlacementError\|MinimizeRestDeviation\|RestNonNegative\|TotalDuration\|ValidPlacement" lib/ test/ | grep -v "/constraints/" | grep -v "_test.exs"`
Expected: no results from non-constraint files (or only the new Solver, which has been rewritten not to use them).

- [ ] **Step 2: Delete the modules**

```bash
rm lib/burpee_trainer/plan_wizard/constraints/minimize_placement_error.ex
rm lib/burpee_trainer/plan_wizard/constraints/minimize_rest_deviation.ex
rm lib/burpee_trainer/plan_wizard/constraints/rest_non_negative.ex
rm lib/burpee_trainer/plan_wizard/constraints/total_duration.ex
rm lib/burpee_trainer/plan_wizard/constraints/valid_placement.ex
rm lib/burpee_trainer/plan_wizard/reservation.ex
```

- [ ] **Step 3: Delete any orphaned test files**

```bash
ls test/burpee_trainer/plan_wizard/constraints/ 2>/dev/null && \
  find test/burpee_trainer/plan_wizard/constraints -name "*_test.exs" -delete
```

- [ ] **Step 4: Run the full test suite**

Run: `mix precommit`
Expected: PASS (compile clean, format clean, all tests pass).

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor: delete superseded constraint modules"
jj new
```

---

## Task 16: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append entry**

Read `CHANGELOG.md` and append a new entry at the top (under any existing "Unreleased" or latest version section):

```markdown
## MILP plan wizard

- Replaced the bespoke constraint-solver pipeline (`Reservation`, `Constraints/*`) with a MILP model serialized to MPS and solved by HiGHS.
- New modules: `PlanWizard.Lp`, `PlanWizard.Lp.Problem`, `PlanWizard.Mps`, `PlanWizard.Highs`.
- Added `fatigue_factor` field to `WorkoutPlan` and `PlanInput`. Biases rest distribution toward later slots. Default `0.0` preserves existing behavior.
- HiGHS is now a runtime dependency; see README for build instructions.
- Deleted: `Reservation`, `Constraints.MinimizePlacementError`, `Constraints.MinimizeRestDeviation`, `Constraints.RestNonNegative`, `Constraints.TotalDuration`, `Constraints.ValidPlacement`. `Constraints.PaceFloor` retained as the pre-LP feasibility gate.
```

- [ ] **Step 2: Final precommit run**

Run: `mix precommit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
jj describe -m "docs: changelog entry for MILP plan wizard"
jj new
```

---

## Done

The MILP plan wizard is complete: a declarative LP model replaces the imperative constraint pipeline, HiGHS provides industry-standard solving, and the fatigue model validates the new architecture by adding a soft constraint cleanly.
