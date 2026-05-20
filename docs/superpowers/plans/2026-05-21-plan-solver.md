# PlanSolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `BurpeeTrainer.PlanWizard` with `BurpeeTrainer.PlanSolver` — a MILP that finds `sec_per_burpee` jointly with rest distribution, bounded below by a level-derived sustainable ceiling; `sec_per_burpee` is no longer a user input.

**Architecture:** Move the generic LP infrastructure (`Lp.Problem`, `Mps`, `Highs`) to a shared `BurpeeTrainer.Milp.*` namespace. Build `PlanSolver` on top: a new `PlanSolver.Lp` builds an extended LP where `p` (pace) is a free variable bounded by `[ceiling[level], max_pace]`, the total-duration constraint references `p`, and the deviation rows express ideal rest as a linear function of `p`. `PlanSolver.Apply` reads the solved pace from the solution. `PlanWizard` and all its sub-modules are deleted at the end.

**Tech Stack:** Elixir 1.15+, Phoenix 1.8 LiveView, HiGHS CLI (already installed), ExUnit.

**Reference:** `PATCH_MILP_SOLVER.md`, `SPEC_INTELIGENCE_LAYER.md`

---

## Sustainable ceiling constants

Used throughout. Defined in `PlanSolver` and exposed via `PlanSolver.sustainable_ceiling/1`:

```elixir
@sustainable_ceiling %{
  level_1a:  8.0,
  level_1b:  7.0,
  level_1c:  6.0,
  level_1d:  5.5,
  level_2:   5.0,
  level_3:   4.5,
  level_4:   4.0,
  graduated: 3.70
}

@pace_floor %{
  six_count: Float.ceil(1200 / 325, 2),   # 3.70s — graduation standard
  navy_seal: 1200 / 150                    # 8.00s
}

# Upper bound for p: slowest plausible pace. Keeps LP bounded.
@max_pace 30.0
```

---

## File Structure

**Move (rename module, keep logic):**
- `lib/burpee_trainer/plan_wizard/lp/problem.ex` → `lib/burpee_trainer/milp/problem.ex` (module: `BurpeeTrainer.Milp.Problem`)
- `lib/burpee_trainer/plan_wizard/mps.ex` → `lib/burpee_trainer/milp/mps.ex` (module: `BurpeeTrainer.Milp.Mps`)
- `lib/burpee_trainer/plan_wizard/highs.ex` → `lib/burpee_trainer/milp/highs.ex` (module: `BurpeeTrainer.Milp.Highs`)

**Create:**
- `lib/burpee_trainer/plan_solver.ex` — public API, replaces `PlanWizard`
- `lib/burpee_trainer/plan_solver/input.ex` — `%PlanSolver.Input{}` (no `sec_per_burpee`, adds `level`)
- `lib/burpee_trainer/plan_solver/solution.ex` — `%PlanSolver.Solution{}` output struct
- `lib/burpee_trainer/plan_solver/lp.ex` — LP builder with `p` as variable
- `lib/burpee_trainer/plan_solver/apply.ex` — collapses solved model to `%WorkoutPlan{}`
- `test/burpee_trainer/plan_solver/lp_test.exs`
- `test/burpee_trainer/plan_solver/apply_test.exs`
- `test/burpee_trainer/plan_solver_test.exs`

**Modify:**
- `lib/burpee_trainer_web/live/plans_live/edit.ex` — remove `sec_per_burpee` input, add level hint, wire `PlanSolver`
- `test/burpee_trainer/milp/highs_test.exs` — renamed from plan_wizard/highs_test.exs
- `test/burpee_trainer/milp/mps_test.exs` — renamed from plan_wizard/mps_test.exs

**Delete (Task 10, after parity verified):**
- `lib/burpee_trainer/plan_wizard.ex`
- `lib/burpee_trainer/plan_wizard/` (entire directory)
- `test/burpee_trainer/plan_wizard/` (entire directory)

---

## Task 1: Move LP infrastructure to `BurpeeTrainer.Milp`

**Files:**
- Create: `lib/burpee_trainer/milp/problem.ex`
- Create: `lib/burpee_trainer/milp/mps.ex`
- Create: `lib/burpee_trainer/milp/highs.ex`
- Create: `test/burpee_trainer/milp/highs_test.exs`
- Create: `test/burpee_trainer/milp/mps_test.exs`

The existing `PlanWizard.Lp.Problem`, `PlanWizard.Mps`, and `PlanWizard.Highs` are generic — they have no wizard-specific logic. We move them to a shared namespace so both `PlanSolver` and the future `ScheduleSolver` can use them. The old modules stay in place for now (deleted in Task 10); the new ones are copies with updated module names and aliases.

- [ ] **Step 1: Write `lib/burpee_trainer/milp/problem.ex`**

```elixir
defmodule BurpeeTrainer.Milp.Problem do
  @moduledoc """
  Canonical representation of a linear/MILP problem ready for serialization.

  Variables are referenced by string name. Coefficients are stored in
  sparse form: each constraint and the objective hold a list of
  `{var_name, coefficient}` pairs.
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

- [ ] **Step 2: Write `lib/burpee_trainer/milp/mps.ex`**

Copy `lib/burpee_trainer/plan_wizard/mps.ex` exactly, changing only:
- Module name: `BurpeeTrainer.Milp.Mps`
- Alias: `alias BurpeeTrainer.Milp.Problem`

```elixir
defmodule BurpeeTrainer.Milp.Mps do
  @moduledoc """
  Serializes a `%Milp.Problem{}` to standard MPS format.

  Conventions:
    * Free objective row is named "COST".
    * Binary variables are wrapped in MARKER 'INTORG'/'INTEND' blocks.
    * Continuous variables ≥ 0 have lower bound 0 (implicit, but emitted
      for clarity).
  """

  alias BurpeeTrainer.Milp.Problem

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

  defp rows_section(p) do
    [
      " N  #{@objective_row}\n"
      | Enum.map(p.constraints, fn c -> " #{row_tag(c.comparator)}  #{c.name}\n" end)
    ]
  end

  defp row_tag(:eq), do: "E"
  defp row_tag(:leq), do: "L"
  defp row_tag(:geq), do: "G"

  defp columns_section(p) do
    by_var = group_terms_by_var(p)

    {iodata, prev_kind} =
      Enum.map_reduce(p.variables, :continuous, fn var, prev_kind ->
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

    if prev_kind == :binary, do: [iodata, intend_marker()], else: iodata
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

  defp rhs_section(p) do
    p.constraints
    |> Enum.reject(fn c -> c.rhs == 0.0 end)
    |> Enum.map(fn c -> "    RHS  #{c.name}  #{fmt(c.rhs)}\n" end)
  end

  defp bounds_section(p) do
    Enum.flat_map(p.variables, fn
      %{type: :binary, name: name} ->
        [" BV BND  #{name}\n"]

      %{type: :continuous, lower: lower, upper: :pos_inf} when lower == 0.0 ->
        []

      %{type: :continuous, name: name, lower: lower, upper: upper} ->
        [
          if(lower != 0.0, do: " LO BND  #{name}  #{fmt(lower)}\n", else: []),
          if(upper != :pos_inf, do: " UP BND  #{name}  #{fmt(upper)}\n", else: [])
        ]
    end)
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 6)
  defp fmt(n) when is_integer(n), do: :erlang.float_to_binary(n * 1.0, decimals: 6)
end
```

- [ ] **Step 3: Write `lib/burpee_trainer/milp/highs.ex`**

Copy `lib/burpee_trainer/plan_wizard/highs.ex` exactly, changing only:
- Module name: `BurpeeTrainer.Milp.Highs`
- Aliases: `alias BurpeeTrainer.Milp.{Problem, Mps}`
- Return type: add `sec_per_burpee` to the ok tuple — `{:ok, %{r: [float], p: float, objective: float}}`

The `extract_values/2` function needs to also extract `p` from the solution:

```elixir
defmodule BurpeeTrainer.Milp.Highs do
  @moduledoc """
  Invokes the HiGHS CLI to solve a `%Milp.Problem{}`.
  """

  alias BurpeeTrainer.Milp.{Mps, Problem}

  @options_file "highs_options.txt"

  @spec solve(Problem.t()) ::
          {:ok, %{r: [float], p: float | nil, objective: float}}
          | {:error, :infeasible | :timeout | {:exit, integer, String.t()}}
  def solve(%Problem{} = problem) do
    mps = Mps.serialize(problem)
    base = "burpee_#{:erlang.unique_integer([:positive])}"
    tmp = System.tmp_dir!()
    mps_path = Path.join(tmp, "#{base}.mps")
    sol_path = Path.join(tmp, "#{base}.sol")

    try do
      File.write!(mps_path, mps)
      run_highs(mps_path, sol_path, tmp, problem)
    after
      File.rm(mps_path)
      File.rm(sol_path)
    end
  end

  defp run_highs(mps_path, sol_path, cwd, problem) do
    bin = Application.get_env(:burpee_trainer, :highs_path, "highs")
    options_path = Application.app_dir(:burpee_trainer, ["priv", @options_file])

    args = [
      mps_path,
      "--solution_file",
      sol_path,
      "--options_file",
      options_path
    ]

    case System.cmd(bin, args, stderr_to_stdout: true, cd: cwd) do
      {output, 0} -> parse_solution(sol_path, output, problem)
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp parse_solution(sol_path, output, problem) do
    case File.read(sol_path) do
      {:ok, contents} ->
        status = status_line(contents)

        cond do
          status =~ ~r/infeasible/i -> {:error, :infeasible}
          status =~ ~r/time limit/i -> {:error, :timeout}
          status =~ ~r/optimal/i -> extract_values(contents, problem)
          true -> {:error, {:exit, 0, "unexpected status: #{status} / #{output}"}}
        end

      {:error, _} ->
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
    columns_section =
      contents
      |> String.split(~r/^Columns\s*$/m, parts: 2)
      |> Enum.at(1, "")
      |> String.split(~r/^Rows\s*$/m, parts: 2)
      |> List.first()

    values =
      columns_section
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        parts = String.split(line, ~r/\s+/, trim: true)

        with [idx | _] <- parts,
             {_, ""} <- Integer.parse(idx) do
          name = List.last(parts)

          primal_idx =
            case parts do
              [_, second | _] ->
                case Float.parse(second) do
                  {_, ""} -> 3
                  _ -> 4
                end

              _ ->
                nil
            end

          if primal_idx do
            primal_str = Enum.at(parts, primal_idx)

            case primal_str && Float.parse(primal_str) do
              {v, _} -> [{name, v}]
              _ -> []
            end
          else
            []
          end
        else
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

    p = Map.get(values, "p")

    objective =
      case Regex.run(~r/Objective value\s*:\s*([\-0-9.eE+]+)/i, contents) do
        [_, v] -> parse_float(v)
        _ -> 0.0
      end

    {:ok, %{r: r, p: p, objective: objective}}
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
```

- [ ] **Step 4: Write `test/burpee_trainer/milp/mps_test.exs`**

```elixir
defmodule BurpeeTrainer.Milp.MpsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milp.{Mps, Problem}

  test "serializes a minimal problem to valid MPS" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", 1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: 10.0}
      ]
    }

    text = Mps.serialize(problem)

    assert text =~ ~r/^NAME\s+BURPEE_PLAN/
    assert text =~ "ROWS"
    assert text =~ "COLUMNS"
    assert text =~ "RHS"
    assert text =~ "BOUNDS"
    assert text =~ ~r/ENDATA\s*\z/
    assert text =~ ~r/^\s*N\s+COST/m
    assert text =~ ~r/^\s*L\s+C1/m
  end

  test "wraps binary variables in INTORG/INTEND markers" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [],
      variables: [
        %{name: "x", type: :binary, lower: 0.0, upper: 1.0}
      ],
      constraints: []
    }

    text = Mps.serialize(problem)
    assert text =~ "'INTORG'"
    assert text =~ "'INTEND'"
  end

  test "emits LO bound for variable with non-zero lower" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"p", -1.0}],
      variables: [%{name: "p", type: :continuous, lower: 5.0, upper: :pos_inf}],
      constraints: []
    }

    text = Mps.serialize(problem)
    assert text =~ ~r/LO BND\s+p\s+5\.000000/
  end
end
```

- [ ] **Step 5: Write `test/burpee_trainer/milp/highs_test.exs`**

```elixir
defmodule BurpeeTrainer.Milp.HighsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milp.{Highs, Mps, Problem}

  @moduletag :highs

  test "solves a trivial LP and returns r and p as nil" do
    # minimize -x subject to x <= 10, x >= 0
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", -1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: 10.0}
      ]
    }

    assert {:ok, %{r: [], p: nil, objective: obj}} = Highs.solve(problem)
    assert_in_delta obj, -10.0, 1.0e-3
  end

  test "returns :infeasible for contradictory constraints" do
    problem = %Problem{
      objective_sense: :minimize,
      objective_terms: [{"x", 1.0}],
      variables: [%{name: "x", type: :continuous, lower: 0.0, upper: :pos_inf}],
      constraints: [
        %{name: "C1", terms: [{"x", 1.0}], comparator: :leq, rhs: -1.0}
      ]
    }

    assert {:error, :infeasible} = Highs.solve(problem)
  end
end
```

- [ ] **Step 6: Run compile and new tests**

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer
mix compile --warnings-as-errors
mix test test/burpee_trainer/milp/
```

Expected: compiles clean, both test files pass.

- [ ] **Step 7: Commit**

```bash
git add lib/burpee_trainer/milp/ test/burpee_trainer/milp/
git commit -m "feat: add BurpeeTrainer.Milp shared LP infrastructure"
```

---

## Task 2: Define `PlanSolver.Input` and `PlanSolver.Solution`

**Files:**
- Create: `lib/burpee_trainer/plan_solver/input.ex`
- Create: `lib/burpee_trainer/plan_solver/solution.ex`

- [ ] **Step 1: Write `lib/burpee_trainer/plan_solver/input.ex`**

```elixir
defmodule BurpeeTrainer.PlanSolver.Input do
  @moduledoc """
  Input to `BurpeeTrainer.PlanSolver.solve/1`. No `sec_per_burpee` —
  the solver finds the optimal pace from the level ceiling.
  """

  @enforce_keys [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style,
    :level
  ]
  defstruct [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style,
    :level,
    reps_per_set: nil,
    additional_rests: []
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type pacing_style :: :even | :unbroken
  @type additional_rest :: %{rest_sec: number, target_min: number}
  @type level ::
          :level_1a
          | :level_1b
          | :level_1c
          | :level_1d
          | :level_2
          | :level_3
          | :level_4
          | :graduated

  @type t :: %__MODULE__{
          name: String.t(),
          burpee_type: burpee_type,
          target_duration_min: number,
          burpee_count_target: pos_integer,
          pacing_style: pacing_style,
          level: level,
          reps_per_set: pos_integer | nil,
          additional_rests: [additional_rest]
        }
end
```

- [ ] **Step 2: Write `lib/burpee_trainer/plan_solver/solution.ex`**

```elixir
defmodule BurpeeTrainer.PlanSolver.Solution do
  @moduledoc """
  Output of `BurpeeTrainer.PlanSolver.solve/1`.
  """

  alias BurpeeTrainer.Workouts.WorkoutPlan

  @enforce_keys [:sec_per_burpee, :set_size, :set_count, :rest_sec, :duration_sec, :plan]
  defstruct [:sec_per_burpee, :set_size, :set_count, :rest_sec, :duration_sec, :plan]

  @type t :: %__MODULE__{
          sec_per_burpee: float,
          set_size: pos_integer,
          set_count: pos_integer,
          rest_sec: float,
          duration_sec: float,
          plan: WorkoutPlan.t()
        }
end
```

- [ ] **Step 3: Run compile**

```bash
mix compile --warnings-as-errors
```

Expected: no warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/burpee_trainer/plan_solver/input.ex lib/burpee_trainer/plan_solver/solution.ex
git commit -m "feat: add PlanSolver.Input and PlanSolver.Solution structs"
```

---

## Task 3: Implement `PlanSolver.Lp` — the extended LP with pace as variable

**Files:**
- Create: `lib/burpee_trainer/plan_solver/lp.ex`
- Create: `test/burpee_trainer/plan_solver/lp_test.exs`

### LP formulation recap

Variables:
- `p` — `sec_per_burpee`, continuous, bounded `[ceiling, @max_pace]`
- `r_1..r_{N-1}` — rest at each inter-rep slot, continuous ≥ 0
- `e_1..e_{N-1}` — absolute deviation `|r_i - ideal_i|`, continuous ≥ 0
- `x_k_i`, `y_k_i`, `d_k` — reservation machinery (unchanged from PlanWizard.Lp)

Key constraint changes vs `PlanWizard.Lp`:

**TOTAL_DUR** (was `Σ r_i = budget_scalar`):
```
N * p + Σ r_i = target_sec - additional_rest_total
```
Both `p` and `r_i` appear. RHS is a scalar.

**DEV rows** (was `ideal_i` as scalar RHS):
Uniform ideal (no fatigue): `ideal_i = weight_i * (target_sec - additional_rest_total - N*p) / (N-1)` for non-zero weight slots.

For zero-weight slots: `r_i = 0` (ZERO_SLOT constraint, unchanged).

For non-zero weight slots with uniform weights (`weight_i = 1/(active_slot_count)`):
```
ideal_i = (budget_const - N * p) / active_slot_count
```
where `budget_const = target_sec - additional_rest_total`.

So `DEV_POS_i`: `-r_i + e_i ≥ -(budget_const - N*p) / active_slot_count`
becomes: `-r_i + e_i + N/active_slot_count * p ≥ -budget_const / active_slot_count`

And `DEV_NEG_i`: `r_i + e_i ≥ (budget_const - N*p) / active_slot_count`
becomes: `r_i + e_i - N/active_slot_count * p ≥ budget_const / active_slot_count ... wait`

More carefully, move the `p` term to the LHS:
```
DEV_NEG_i:  r_i + e_i + N/active_slot_count * p ≥  budget_const / active_slot_count
                                                    (nope — wrong sign)
```

Let `A = budget_const / active_slot_count`, `B = N / active_slot_count`. Then `ideal_i = A - B*p`.

```
DEV_POS_i:  -r_i + e_i ≥ -(A - B*p)  →  -r_i + e_i - B*p ≥ -A
DEV_NEG_i:   r_i + e_i ≥   A - B*p   →   r_i + e_i + B*p ≥  A
```

Both linear. ✓

**Objective** (from patch spec, linearized):
```
minimize  -α * p  +  ε * Σ e_i  +  Σ d_k
```
`α = 0.6` (prefer slower pace = more sustainable).
`ε = 1.0e-3` (soft deviation regularizer, as before).
`d_k` placement error terms (as before).

**y_linearization_rows**: slot end time is `i*p + Σ_{j≤i} r_j`. The `YBND_SE` and `YBND_LO` rows had `i * sec_per_burpee` as a scalar RHS — now `p` appears in the terms:

```
YBND_SE_k_i:  y_{k,i} - Σ_{j≤i} r_j - i*p ≤ 0
YBND_LO_k_i:  y_{k,i} - Σ_{j≤i} r_j - i*p - M*x_{k,i} ≥ -M
```

All still linear. ✓

- [ ] **Step 1: Write the failing tests**

Write `test/burpee_trainer/plan_solver/lp_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanSolver.LpTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Milp.Problem
  alias BurpeeTrainer.PlanSolver.{Input, Lp}

  defp base_input(overrides \\ %{}) do
    Map.merge(
      %{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        pacing_style: :even,
        level: :level_1c,
        additional_rests: []
      },
      overrides
    )
    |> then(fn m -> struct!(Input, m) end)
  end

  describe "build/2 — no reservations, :even" do
    test "includes p variable with correct bounds" do
      problem = Lp.build(base_input(), nil)

      p_var = Enum.find(problem.variables, &(&1.name == "p"))
      assert p_var != nil
      assert p_var.type == :continuous
      # level_1c ceiling is 6.0
      assert_in_delta p_var.lower, 6.0, 1.0e-9
      assert p_var.upper == :pos_inf or p_var.upper >= 6.0
    end

    test "TOTAL_DUR row has both p and r_i terms" do
      problem = Lp.build(base_input(), nil)
      row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))

      assert row != nil
      assert row.comparator == :eq

      term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
      assert MapSet.member?(term_names, "p")
      assert MapSet.member?(term_names, "r_1")

      # p coefficient should be N (= 5)
      {_, p_coef} = Enum.find(row.terms, fn {n, _} -> n == "p" end)
      assert_in_delta p_coef, 5.0, 1.0e-9

      # RHS = target_sec - additional_rest_total = 600
      assert_in_delta row.rhs, 600.0, 1.0e-9
    end

    test "DEV rows reference p" do
      problem = Lp.build(base_input(), nil)

      dev_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "DEV_"))
      assert length(dev_rows) == 8

      Enum.each(dev_rows, fn row ->
        term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
        assert MapSet.member?(term_names, "p"),
               "expected DEV row #{row.name} to reference p"
      end)
    end

    test "objective minimizes -α*p and ε*e_i terms" do
      problem = Lp.build(base_input(), nil)
      assert problem.objective_sense == :minimize

      {_, p_coef} = Enum.find(problem.objective_terms, fn {n, _} -> n == "p" end)
      # α = 0.6, coefficient should be -0.6
      assert_in_delta p_coef, -0.6, 1.0e-9

      e_terms = Enum.filter(problem.objective_terms, fn {n, _} -> String.starts_with?(n, "e_") end)
      assert length(e_terms) == 4
      Enum.each(e_terms, fn {_, c} -> assert_in_delta c, 1.0e-3, 1.0e-9 end)
    end
  end

  describe "build/2 — :unbroken" do
    test "zero-weight slots still get ZERO_SLOT constraints" do
      input = base_input(%{pacing_style: :unbroken, burpee_count_target: 10})
      problem = Lp.build(input, 5)

      zero_rows = Enum.filter(problem.constraints, &String.starts_with?(&1.name, "ZERO_SLOT_"))
      assert length(zero_rows) == 8
    end
  end

  describe "build/2 — with reservation" do
    test "reservation produces x, y, d vars; TOTAL_DUR still has p" do
      input =
        base_input(%{
          burpee_count_target: 10,
          additional_rests: [%{rest_sec: 60, target_min: 5}]
        })

      problem = Lp.build(input, nil)

      row = Enum.find(problem.constraints, &(&1.name == "TOTAL_DUR"))
      term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
      assert MapSet.member?(term_names, "p")

      # RHS = 600 - 60 = 540
      assert_in_delta row.rhs, 540.0, 1.0e-9

      d_vars = Enum.filter(problem.variables, &String.starts_with?(&1.name, "d_"))
      assert length(d_vars) == 1
    end

    test "y_linearization rows include p coefficient" do
      input =
        base_input(%{
          burpee_count_target: 10,
          additional_rests: [%{rest_sec: 60, target_min: 5}]
        })

      problem = Lp.build(input, nil)

      ybnd_se_rows =
        Enum.filter(problem.constraints, &String.starts_with?(&1.name, "YBND_SE_"))

      Enum.each(ybnd_se_rows, fn row ->
        term_names = Enum.map(row.terms, &elem(&1, 0)) |> MapSet.new()
        assert MapSet.member?(term_names, "p"),
               "expected #{row.name} to reference p"
      end)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/plan_solver/lp_test.exs
```

Expected: FAIL — `BurpeeTrainer.PlanSolver.Lp` undefined.

- [ ] **Step 3: Write `lib/burpee_trainer/plan_solver/lp.ex`**

```elixir
defmodule BurpeeTrainer.PlanSolver.Lp do
  @moduledoc """
  Builds a `%Milp.Problem{}` for the session planner.

  Extends the slot-distribution LP with `p` (sec_per_burpee) as a free
  variable. The total-duration constraint and deviation rows both reference
  `p`; the objective minimizes -α*p (prefer slower, more sustainable pace)
  plus a small deviation regularizer.
  """

  alias BurpeeTrainer.Milp.Problem
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.Input

  # Weight on pace term in objective: prefer slower (more sustainable) pace.
  @alpha 0.6
  # Small weight on deviation — keeps rest distribution even when pace is free.
  @epsilon 1.0e-3
  # Tolerance in seconds for reservation placement.
  @placement_tolerance_sec 30.0
  # Max sensible pace — keeps the LP bounded.
  @max_pace 30.0

  @spec build(Input.t(), pos_integer | nil) :: Problem.t()
  def build(%Input{} = input, reps_per_set) do
    n = input.burpee_count_target
    ceiling = PlanSolver.sustainable_ceiling(input.level)
    target_sec = input.target_duration_min * 60.0
    add_rest_total = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))
    budget_const = target_sec - add_rest_total

    weights = weight_vector(input.pacing_style, n, reps_per_set)
    active_count = Enum.count(weights, &(&1 > 0.0))

    slot_count = max(n - 1, 0)
    big_m = max(target_sec * 1.0, 1.0)

    reservations = build_reservations(input, ceiling, n, target_sec, weights)
    allowed = Enum.map(reservations, &allowed_slots(&1, n, weights, input.pacing_style, ceiling, target_sec))

    p_var = %{name: "p", type: :continuous, lower: ceiling, upper: @max_pace}
    r_vars = for i <- 1..slot_count//1, do: continuous("r_#{i}")
    e_vars = for i <- 1..slot_count//1, do: continuous("e_#{i}")

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
      total_duration_row(slot_count, n, budget_const) ++
        zero_weight_rows(weights) ++
        deviation_rows(weights, active_count, n, budget_const) ++
        assignment_rows(reservations, allowed) ++
        one_per_slot_rows(slot_count, reservations, allowed) ++
        ordering_rows(input.pacing_style, reservations, allowed) ++
        rest_linkage_rows(reservations, allowed, big_m) ++
        y_linearization_rows(reservations, allowed, big_m) ++
        placement_error_rows(reservations, allowed) ++
        tolerance_rows(reservations)

    objective_terms =
      [{"p", -@alpha}] ++
        Enum.map(reservations, fn r -> {"d_#{r.k}", 1.0} end) ++
        for(i <- 1..slot_count//1, do: {"e_#{i}", @epsilon})

    %Problem{
      objective_sense: :minimize,
      objective_terms: objective_terms,
      variables: [p_var] ++ r_vars ++ e_vars ++ x_vars ++ y_vars ++ d_vars,
      constraints: constraints
    }
  end

  # ---------------------------------------------------------------------------
  # Weights — same logic as PlanWizard.Styles
  # ---------------------------------------------------------------------------

  # :even — all slots equal weight 1.0
  defp weight_vector(:even, n, _reps_per_set) when n > 1,
    do: List.duplicate(1.0, n - 1)

  defp weight_vector(:even, _n, _), do: []

  # :unbroken — weight 1.0 at set boundaries, 0.0 elsewhere
  defp weight_vector(:unbroken, n, reps_per_set) when is_integer(reps_per_set) and n > 1 do
    for i <- 1..(n - 1) do
      if rem(i, reps_per_set) == 0, do: 1.0, else: 0.0
    end
  end

  defp weight_vector(:unbroken, n, _) when n > 1, do: List.duplicate(0.0, n - 1)
  defp weight_vector(_, _, _), do: []

  # ---------------------------------------------------------------------------
  # Reservations
  # ---------------------------------------------------------------------------

  defp build_reservations(%Input{additional_rests: rests}, ceiling, n, target_sec, weights) do
    rests
    |> Enum.sort_by(& &1.target_min)
    |> Enum.with_index(1)
    |> Enum.map(fn {r, k} ->
      %{k: k, rest_sec: r.rest_sec * 1.0, target_sec: r.target_min * 60.0}
    end)
  end

  defp allowed_slots(%{target_sec: target_s}, n, weights, style, ceiling, total_sec) do
    # Project slot end times assuming pace = ceiling (lower bound); gives the
    # earliest possible wall-clock position for each slot. Slots that could
    # plausibly fall within ±tolerance of the target are included.
    projected = projected_slot_times(n, weights, style, ceiling, total_sec)

    projected
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {t, i} ->
      if abs(t - target_s) <= @placement_tolerance_sec and slot_eligible?(weights, style, i),
        do: [i],
        else: []
    end)
  end

  defp slot_eligible?(weights, :unbroken, i), do: Enum.at(weights, i - 1, 0.0) > 0.0
  defp slot_eligible?(_weights, _style, _i), do: true

  defp projected_slot_times(_n, _weights, :unbroken, _ceiling, total_sec) do
    # For :unbroken, use uniform spacing as a proxy
    n = length(_weights) + 1
    for i <- 1..(n - 1), do: i * total_sec / n
  end

  defp projected_slot_times(n, _weights, :even, ceiling, total_sec) do
    # Even ideal distribution at ceiling pace: uniform rest per slot
    rest_per_slot = max(total_sec - n * ceiling, 0.0) / max(n - 1, 1)
    for i <- 1..(n - 1), do: i * ceiling + i * rest_per_slot
  end

  # ---------------------------------------------------------------------------
  # Variables
  # ---------------------------------------------------------------------------

  defp continuous(name), do: %{name: name, type: :continuous, lower: 0.0, upper: :pos_inf}
  defp binary(name), do: %{name: name, type: :binary, lower: 0.0, upper: 1.0}

  # ---------------------------------------------------------------------------
  # Constraints
  # ---------------------------------------------------------------------------

  # N*p + Σ r_i = target_sec - additional_rest_total
  defp total_duration_row(0, _n, _budget_const), do: []

  defp total_duration_row(slot_count, n, budget_const) do
    r_terms = for i <- 1..slot_count, do: {"r_#{i}", 1.0}

    [
      %{
        name: "TOTAL_DUR",
        terms: [{"p", n * 1.0} | r_terms],
        comparator: :eq,
        rhs: budget_const
      }
    ]
  end

  defp zero_weight_rows(weights) do
    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {0.0, i} ->
        [%{name: "ZERO_SLOT_#{i}", terms: [{"r_#{i}", 1.0}], comparator: :eq, rhs: 0.0}]

      _ ->
        []
    end)
  end

  # Uniform ideal rest (no fatigue): ideal_i = (budget_const - N*p) / active_count
  # DEV_POS_i:  -r_i + e_i - (N/active_count)*p ≥ -budget_const/active_count
  # DEV_NEG_i:   r_i + e_i + (N/active_count)*p ≥  budget_const/active_count  (wrong sign — see below)
  #
  # Correct derivation:
  #   e_i ≥ |r_i - ideal_i|
  #   e_i ≥ r_i - ideal_i  →  e_i - r_i ≥ -ideal_i  →  -r_i + e_i ≥ -(A - B*p)  →  -r_i + e_i + B*p ≥ -A... wait
  #
  # Let ideal_i = A - B*p  where A = budget_const/active_count, B = n/active_count
  # e_i ≥  r_i - ideal_i  →  e_i - r_i ≥ -ideal_i   →  -r_i + e_i ≥ -(A-B*p) = -A + B*p  →  -r_i + e_i - B*p ≥ -A
  # e_i ≥ -r_i + ideal_i  →  e_i + r_i ≥  ideal_i   →   r_i + e_i ≥  A - B*p            →   r_i + e_i + B*p ≥  A
  defp deviation_rows(weights, active_count, n, budget_const) when active_count > 0 do
    a = budget_const / active_count
    b = n * 1.0 / active_count

    weights
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {0.0, _i} ->
        []

      {_w, i} ->
        [
          %{
            name: "DEV_POS_#{i}",
            terms: [{"r_#{i}", -1.0}, {"e_#{i}", 1.0}, {"p", -b}],
            comparator: :geq,
            rhs: -a
          },
          %{
            name: "DEV_NEG_#{i}",
            terms: [{"r_#{i}", 1.0}, {"e_#{i}", 1.0}, {"p", b}],
            comparator: :geq,
            rhs: a
          }
        ]
    end)
  end

  defp deviation_rows(_weights, 0, _n, _budget_const), do: []

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

  defp one_per_slot_rows(slot_count, reservations, allowed) do
    pairs = Enum.zip(reservations, allowed)

    Enum.flat_map(1..slot_count//1, fn i ->
      uses = for {res, slots} <- pairs, i in slots, do: {"x_#{res.k}_#{i}", 1.0}

      if length(uses) >= 2,
        do: [%{name: "ONE_PER_SLOT_#{i}", terms: uses, comparator: :leq, rhs: 1.0}],
        else: []
    end)
  end

  defp ordering_rows(:even, reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{k1_res, k1_slots}, {k2_res, k2_slots}] ->
      terms =
        Enum.map(k2_slots, fn i -> {"x_#{k2_res.k}_#{i}", i * 1.0} end) ++
          Enum.map(k1_slots, fn i -> {"x_#{k1_res.k}_#{i}", -i * 1.0} end)

      %{name: "ORDER_#{k1_res.k}", terms: terms, comparator: :geq, rhs: 1.0}
    end)
  end

  defp ordering_rows(_style, _reservations, _allowed), do: []

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

  # slot_end_time[i] = i*p + Σ_{j≤i} r_j
  # y_{k,i} linearizes x_{k,i} * slot_end_time[i]
  #
  # YBND_X:   y_{k,i} ≤ M * x_{k,i}         → y - M*x ≤ 0
  # YBND_SE:  y_{k,i} ≤ i*p + Σ r_j         → y - i*p - Σ r_j ≤ 0
  # YBND_LO:  y_{k,i} ≥ i*p + Σ r_j - M*(1 - x_{k,i})
  #           → y - i*p - Σ r_j - M*x ≥ -M
  defp y_linearization_rows(reservations, allowed, big_m) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      Enum.flat_map(slots, fn i ->
        r_terms = for j <- 1..i, do: {"r_#{j}", -1.0}

        [
          %{
            name: "YBND_X_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"x_#{res.k}_#{i}", -big_m}],
            comparator: :leq,
            rhs: 0.0
          },
          %{
            name: "YBND_SE_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"p", -i * 1.0} | r_terms],
            comparator: :leq,
            rhs: 0.0
          },
          %{
            name: "YBND_LO_#{res.k}_#{i}",
            terms: [{"y_#{res.k}_#{i}", 1.0}, {"p", -i * 1.0}, {"x_#{res.k}_#{i}", -big_m} | r_terms],
            comparator: :geq,
            rhs: -big_m
          }
        ]
      end)
    end)
  end

  defp placement_error_rows(reservations, allowed) do
    Enum.zip(reservations, allowed)
    |> Enum.flat_map(fn {res, slots} ->
      y_neg = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", -1.0} end)
      y_pos = Enum.map(slots, fn i -> {"y_#{res.k}_#{i}", 1.0} end)

      [
        %{
          name: "PERR_POS_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_neg],
          comparator: :geq,
          rhs: -res.target_sec
        },
        %{
          name: "PERR_NEG_#{res.k}",
          terms: [{"d_#{res.k}", 1.0} | y_pos],
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
        rhs: @placement_tolerance_sec
      }
    end)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/plan_solver/lp_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/burpee_trainer/plan_solver/lp.ex test/burpee_trainer/plan_solver/lp_test.exs
git commit -m "feat: implement PlanSolver.Lp with pace as LP variable"
```

---

## Task 4: Implement `PlanSolver.Apply`

**Files:**
- Create: `lib/burpee_trainer/plan_solver/apply.ex`
- Create: `test/burpee_trainer/plan_solver/apply_test.exs`

`Apply` receives the solved `p` (pace) and `r` (slot rests) and collapses them into a `%WorkoutPlan{}`. It follows the same block/set structure logic as `PlanWizard.Apply`, but reads `sec_per_burpee` from the solution rather than the input.

- [ ] **Step 1: Write failing tests**

Write `test/burpee_trainer/plan_solver/apply_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanSolver.ApplyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{Apply, Input}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  defp even_input(n, dur_min) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: dur_min,
      burpee_count_target: n,
      pacing_style: :even,
      level: :level_1c
    }
  end

  defp unbroken_input(n, dur_min, rps) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: dur_min,
      burpee_count_target: n,
      pacing_style: :unbroken,
      level: :level_1c,
      reps_per_set: rps
    }
  end

  test ":even, no reservations — one block, one set, all reps" do
    input = even_input(10, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert %WorkoutPlan{} = plan
    assert length(plan.blocks) == 1
    [block] = plan.blocks
    assert length(block.sets) == 1
    [set] = block.sets
    assert set.burpee_count == 10
    assert_in_delta set.sec_per_burpee, 6.0, 1.0e-6
  end

  test ":even — total duration matches target within 1s" do
    input = even_input(20, 10)
    target_sec = 600.0
    p = 6.0
    # Even distribution
    rest_budget = target_sec - 20 * p
    r = List.duplicate(rest_budget / 19, 19)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    sets = Enum.flat_map(plan.blocks, & &1.sets)
    duration = Enum.reduce(sets, 0.0, fn s, acc -> acc + s.burpee_count * s.sec_per_rep + s.end_of_set_rest end)
    assert_in_delta duration, target_sec, 1.0
  end

  test ":even with one reservation — two blocks" do
    input = %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      pacing_style: :even,
      level: :level_1c,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    }
    p = 6.0
    r = List.duplicate(0.0, 9)
    reservations = [%{slot: 5, rest_sec: 60.0, target_min: 5}]

    {:ok, plan} = Apply.to_workout_plan(input, p, r, reservations)

    assert length(plan.blocks) == 2
    [b1, b2] = Enum.sort_by(plan.blocks, & &1.position)
    [s1] = b1.sets
    [s2] = b2.sets
    assert s1.burpee_count == 5
    assert s2.burpee_count == 5
    assert_in_delta s1.end_of_set_rest, 60.0, 1.0e-6
    assert s2.end_of_set_rest == 0
  end

  test ":unbroken — correct set count and no inter-set rest for one set" do
    input = unbroken_input(10, 5, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    sets = List.first(plan.blocks).sets
    assert length(sets) == 2
    Enum.each(sets, &assert(&1.sec_per_burpee == p))
  end

  test "solved p is stored in plan.sec_per_burpee" do
    input = even_input(5, 5)
    p = 7.3
    r = List.duplicate(0.0, 4)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert_in_delta plan.sec_per_burpee, 7.3, 1.0e-6
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs
```

Expected: FAIL — `BurpeeTrainer.PlanSolver.Apply` undefined.

- [ ] **Step 3: Write `lib/burpee_trainer/plan_solver/apply.ex`**

```elixir
defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Collapses solved LP output into a `%WorkoutPlan{}`.

  Receives the solved pace `p` (sec_per_burpee), the slot-rest vector `r`,
  and the recovered `reservations` list. Produces the same block/set
  structure as the old PlanWizard.Apply but reads pace from the solution
  rather than the input.
  """

  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @spec to_workout_plan(Input.t(), float, [float], [map]) ::
          {:ok, WorkoutPlan.t()}
  def to_workout_plan(%Input{} = input, p, r, reservations)
      when is_float(p) do
    blocks =
      case input.pacing_style do
        :even -> build_even(input, p, reservations)
        :unbroken -> build_unbroken(input, p, r, reservations)
      end

    {:ok, wrap_plan(input, p, blocks)}
  end

  # ---------------------------------------------------------------------------
  # :even
  # ---------------------------------------------------------------------------

  defp build_even(%Input{burpee_count_target: n, target_duration_min: dur_min} = input, p, []) do
    target_sec = dur_min * 60.0
    cadence = target_sec / n

    set = %Set{
      position: 1,
      burpee_count: n,
      sec_per_rep: cadence,
      sec_per_burpee: p,
      end_of_set_rest: 0
    }

    [%Block{position: 1, repeat_count: 1, sets: [set]}]
  end

  defp build_even(%Input{} = input, p, reservations) do
    target_sec = input.target_duration_min * 60.0
    reservation_total = Enum.reduce(reservations, 0.0, &(&1.rest_sec + &2))
    cadence = (target_sec - reservation_total) / input.burpee_count_target

    sorted = Enum.sort_by(reservations, & &1.slot)
    splits = Enum.map(sorted, &{&1.slot, &1.rest_sec}) ++ [{input.burpee_count_target, 0}]

    {blocks, _} =
      Enum.reduce(splits, {[], 0}, fn {split_at, rest_sec}, {acc, prev} ->
        reps = split_at - prev

        set = %Set{
          position: 1,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: p,
          end_of_set_rest: rest_sec
        }

        block = %Block{position: length(acc) + 1, repeat_count: 1, sets: [set]}
        {[block | acc], split_at}
      end)

    Enum.reverse(blocks)
  end

  # ---------------------------------------------------------------------------
  # :unbroken
  # ---------------------------------------------------------------------------

  defp build_unbroken(%Input{} = input, p, r, reservations) do
    n = input.burpee_count_target
    set_size = min(input.reps_per_set || n, n)
    full_sets = div(n, set_size)
    remainder = rem(n, set_size)
    set_count = if remainder > 0, do: full_sets + 1, else: full_sets

    reservation_total = Enum.reduce(reservations, 0.0, &(&1.rest_sec + &2))
    target_sec = input.target_duration_min * 60.0
    work = n * p
    between_rest_total = target_sec - work - reservation_total

    rest_per_gap =
      if set_count > 1, do: between_rest_total / (set_count - 1), else: 0.0

    extra_by_set =
      Enum.reduce(reservations, %{}, fn res, acc ->
        idx = div(res.slot, set_size)
        Map.update(acc, idx, res.rest_sec, &(&1 + res.rest_sec))
      end)

    sets =
      for i <- 1..set_count do
        is_last = i == set_count
        reps = if is_last and remainder > 0, do: remainder, else: set_size
        base_rest = if is_last, do: 0, else: round(rest_per_gap)
        extra = Map.get(extra_by_set, i, 0)

        %Set{
          position: i,
          burpee_count: reps,
          sec_per_rep: p,
          sec_per_burpee: p,
          end_of_set_rest: base_rest + extra
        }
      end

    [%Block{position: 1, repeat_count: 1, sets: sets}]
  end

  # ---------------------------------------------------------------------------
  # Wrap
  # ---------------------------------------------------------------------------

  defp wrap_plan(%Input{} = input, p, blocks) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: p,
      pacing_style: input.pacing_style,
      additional_rests: encode_rests(input.additional_rests || []),
      fatigue_factor: 0.0,
      blocks: blocks
    }
  end

  defp encode_rests([]), do: "[]"

  defp encode_rests(rests) do
    items =
      Enum.map(rests, fn %{rest_sec: r, target_min: t} ->
        "{\"rest_sec\":#{r},\"target_min\":#{t}}"
      end)

    "[" <> Enum.join(items, ",") <> "]"
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/plan_solver/apply_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/burpee_trainer/plan_solver/apply.ex test/burpee_trainer/plan_solver/apply_test.exs
git commit -m "feat: implement PlanSolver.Apply"
```

---

## Task 5: Implement `BurpeeTrainer.PlanSolver` (public API)

**Files:**
- Create: `lib/burpee_trainer/plan_solver.ex`
- Create: `test/burpee_trainer/plan_solver_test.exs`

`PlanSolver` is the public entry point. It handles:
1. Pre-flight: check unbroken feasibility (one set, no LP needed)
2. Reps-per-set resolution for `:unbroken`
3. LP build + HiGHS solve
4. Reservation recovery from solution
5. `Apply.to_workout_plan/4`
6. Wrap into `%Solution{}`

- [ ] **Step 1: Write failing tests**

Write `test/burpee_trainer/plan_solver_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanSolverTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Input, Solution}

  @moduletag :highs

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 20,
        pacing_style: :even,
        level: :level_1c,
        additional_rests: []
      },
      overrides
    )
    |> then(fn m -> struct!(Input, m) end)
  end

  test "sustainable_ceiling/1 returns correct ceiling per level" do
    assert PlanSolver.sustainable_ceiling(:level_1a) == 8.0
    assert PlanSolver.sustainable_ceiling(:level_1c) == 6.0
    assert PlanSolver.sustainable_ceiling(:level_4) == 4.0
    assert PlanSolver.sustainable_ceiling(:graduated) == 3.70
  end

  test "default_reps_per_set/1 returns sensible defaults" do
    assert PlanSolver.default_reps_per_set(:six_count) == 10
    assert PlanSolver.default_reps_per_set(:navy_seal) == 5
  end

  test "solve/1 returns ok with valid solution" do
    assert {:ok, %Solution{} = sol} = PlanSolver.solve(input())

    assert is_float(sol.sec_per_burpee)
    # Pace must be at or above level_1c ceiling (6.0)
    assert sol.sec_per_burpee >= 6.0 - 1.0e-6
    assert sol.set_count >= 1
    assert sol.set_size >= 1
    assert sol.set_size * sol.set_count == 20
    assert is_float(sol.duration_sec)
    assert_in_delta sol.duration_sec, 600.0, 5.0
  end

  test "solver chooses pace >= ceiling for each level" do
    for {level, ceiling} <- [
          level_1a: 8.0,
          level_1c: 6.0,
          level_2: 5.0,
          level_4: 4.0
        ] do
      {:ok, sol} = PlanSolver.solve(input(%{level: level}))
      assert sol.sec_per_burpee >= ceiling - 1.0e-4,
             "level #{level}: expected pace >= #{ceiling}, got #{sol.sec_per_burpee}"
    end
  end

  test "higher level yields faster optimal pace" do
    {:ok, sol_1a} = PlanSolver.solve(input(%{level: :level_1a}))
    {:ok, sol_4} = PlanSolver.solve(input(%{level: :level_4}))

    # level_4 ceiling is lower → solver can find a faster pace
    assert sol_4.sec_per_burpee <= sol_1a.sec_per_burpee
  end

  test ":unbroken solve — one block, set_size respected" do
    {:ok, sol} =
      PlanSolver.solve(input(%{pacing_style: :unbroken, reps_per_set: 5}))

    sets = List.first(sol.plan.blocks).sets
    assert length(sets) == 4
    Enum.each(sets, &assert(&1.burpee_count == 5))
  end

  test "returns error when work alone exceeds target" do
    # 20 reps × 8s/rep = 160s; target = 1min = 60s. Infeasible.
    assert {:error, [msg]} =
             PlanSolver.solve(input(%{target_duration_min: 1, level: :level_1a}))

    assert is_binary(msg)
  end

  test "additional_rests places rest within 30s of target" do
    inp = input(%{
      burpee_count_target: 20,
      target_duration_min: 10,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    })

    {:ok, sol} = PlanSolver.solve(inp)
    assert length(sol.plan.blocks) == 2
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/plan_solver_test.exs
```

Expected: FAIL — `BurpeeTrainer.PlanSolver` undefined.

- [ ] **Step 3: Write `lib/burpee_trainer/plan_solver.ex`**

```elixir
defmodule BurpeeTrainer.PlanSolver do
  @moduledoc """
  Public entry point for session plan generation.

  Given a `%PlanSolver.Input{}` (burpee count, type, duration, pacing style,
  user level), finds the optimal pace and rest distribution via a joint MILP
  and returns a `%PlanSolver.Solution{}` wrapping the `%WorkoutPlan{}`.

  `sec_per_burpee` is solver-chosen, bounded below by `sustainable_ceiling/1`.
  Users never input a pace.
  """

  alias BurpeeTrainer.Milp.Highs
  alias BurpeeTrainer.PlanSolver.{Apply, Input, Lp, Solution}

  @sustainable_ceiling %{
    level_1a: 8.0,
    level_1b: 7.0,
    level_1c: 6.0,
    level_1d: 5.5,
    level_2: 5.0,
    level_3: 4.5,
    level_4: 4.0,
    graduated: 3.70
  }

  @pace_floor %{
    six_count: Float.ceil(1200 / 325, 2),
    navy_seal: 1200 / 150
  }

  @default_reps_per_set %{six_count: 10, navy_seal: 5}

  @doc "Level-derived sustainable pace ceiling (sec/rep). Solver will not go faster."
  @spec sustainable_ceiling(atom) :: float
  def sustainable_ceiling(level), do: Map.get(@sustainable_ceiling, level, 8.0)

  @doc "Default reps-per-set for a given burpee type."
  @spec default_reps_per_set(atom) :: pos_integer
  def default_reps_per_set(type), do: Map.get(@default_reps_per_set, type, 10)

  @doc """
  Generate a `%Solution{}` from a `%PlanSolver.Input{}`.
  Returns `{:ok, solution}` or `{:error, [reason_string]}`.
  """
  @spec solve(Input.t()) :: {:ok, Solution.t()} | {:error, [String.t()]}
  def solve(%Input{} = input) do
    with {:ok, reps_per_set} <- resolve_reps_per_set(input),
         :ok <- preflight_check(input),
         {:ok, p, r, reservations} <- run_lp(input, reps_per_set),
         {:ok, plan} <- Apply.to_workout_plan(input, p, r, reservations) do
      {:ok, build_solution(p, plan, input, reps_per_set)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_reps_per_set(%Input{pacing_style: :even}), do: {:ok, nil}

  defp resolve_reps_per_set(%Input{pacing_style: :unbroken} = input) do
    rps = input.reps_per_set || default_reps_per_set(input.burpee_type)

    if is_integer(rps) and rps > 0,
      do: {:ok, rps},
      else: {:error, ["reps_per_set must be a positive integer"]}
  end

  defp preflight_check(%Input{} = input) do
    ceiling = sustainable_ceiling(input.level)
    min_work = input.burpee_count_target * ceiling
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))

    cond do
      min_work > target_sec ->
        {:error,
         [
           "#{input.burpee_count_target} reps at minimum pace #{ceiling}s/rep requires " <>
             "#{round(min_work)}s — target is #{round(target_sec)}s"
         ]}

      min_work + add_rest > target_sec ->
        {:error,
         [
           "work (#{round(min_work)}s) + additional rests (#{round(add_rest)}s) exceed " <>
             "target duration (#{round(target_sec)}s)"
         ]}

      true ->
        :ok
    end
  end

  defp run_lp(%Input{} = input, reps_per_set) do
    problem = Lp.build(input, reps_per_set)

    case Highs.solve(problem) do
      {:ok, %{r: r, p: p}} when is_float(p) ->
        reservations = recover_reservations(input, r)
        {:ok, p, r, reservations}

      {:ok, %{p: nil}} ->
        # Degenerate (0 or 1 rep): use ceiling as pace, empty r
        ceiling = sustainable_ceiling(input.level)
        {:ok, ceiling, [], []}

      {:error, :infeasible} ->
        {:error, [infeasibility_message(input)]}

      {:error, :timeout} ->
        {:error, ["plan solver timed out"]}

      {:error, {:exit, code, out}} ->
        {:error, ["plan solver failed (exit #{code}): #{out}"]}
    end
  end

  defp infeasibility_message(%Input{additional_rests: [_ | _] = rests}) do
    %{target_min: t} = Enum.max_by(rests, & &1.target_min)
    "Cannot place rest at minute #{t} within 30s of a rep boundary"
  end

  defp infeasibility_message(%Input{} = input) do
    target_sec = input.target_duration_min * 60.0
    "#{input.burpee_count_target} reps cannot fit in #{round(target_sec)}s at your level"
  end

  defp recover_reservations(%Input{additional_rests: []}, _r), do: []

  defp recover_reservations(%Input{additional_rests: rests}, r) do
    {result, _taken} =
      rests
      |> Enum.sort_by(& &1.target_min)
      |> Enum.map_reduce(MapSet.new(), fn rest, taken ->
        slot =
          r
          |> Enum.with_index(1)
          |> Enum.reject(fn {_v, i} -> MapSet.member?(taken, i) end)
          |> Enum.min_by(fn {v, _i} -> abs(v - rest.rest_sec) end)
          |> elem(1)

        reservation = %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}
        {reservation, MapSet.put(taken, slot)}
      end)

    result
  end

  defp build_solution(p, plan, %Input{} = input, reps_per_set) do
    n = input.burpee_count_target
    set_size = reps_per_set || n
    set_count = ceil(n / set_size)
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))
    rest_sec = if set_count > 1, do: (target_sec - n * p - add_rest) / (set_count - 1), else: 0.0

    %Solution{
      sec_per_burpee: p,
      set_size: set_size,
      set_count: set_count,
      rest_sec: max(rest_sec, 0.0),
      duration_sec: n * p + max(rest_sec, 0.0) * (set_count - 1) + add_rest,
      plan: plan
    }
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/plan_solver_test.exs
```

Expected: PASS for all tests. If HiGHS not found, tests tagged `:highs` skip automatically.

- [ ] **Step 5: Commit**

```bash
git add lib/burpee_trainer/plan_solver.ex test/burpee_trainer/plan_solver_test.exs
git commit -m "feat: implement BurpeeTrainer.PlanSolver public API"
```

---

## Task 6: Wire `PlanSolver` into the LiveView (`edit.ex`)

**Files:**
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`

Changes:
1. Remove `sec_per_burpee` from `plan_input` map and all related parsing/rendering
2. Remove `fatigue_factor` (no longer in `PlanSolver.Input`)
3. Add `level` — derived from `Levels.current_level(sessions)` at mount
4. Replace `PlanWizard.generate` call with `PlanSolver.solve`
5. Replace `PlanInput` struct construction with `PlanSolver.Input` struct
6. Add solver-chosen pace display in Layer 3 summary
7. Update level hint in Layer 1

- [ ] **Step 1: Read current mount and session handling**

The `mount/3` currently assigns `:current_user` from session. We need `:sessions` to derive level. Read how sessions are loaded in other LiveViews:

```bash
grep -n "sessions\|current_level\|Levels" /home/aktersnurra/projects/vibe/burpee_trainer/lib/burpee_trainer_web/live/overview_live.ex | head -20
```

- [ ] **Step 2: Update aliases and module-level attributes**

In `edit.ex`, replace the top section:

```elixir
use BurpeeTrainerWeb, :live_view

alias BurpeeTrainer.{Levels, Planner, Workouts}
alias BurpeeTrainer.PlanSolver
alias BurpeeTrainer.PlanSolver.Input
alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}
alias BurpeeTrainerWeb.Fmt
```

Remove these module attributes (no longer needed):
```elixir
# DELETE these two lines:
@sec_per_burpee_floor_six Float.ceil(1200 / 325, 2)
@sec_per_burpee_floor_navy 1200 / 150
```

- [ ] **Step 3: Update `mount/3` to load level**

In `mount/3`, after the existing assigns, load sessions and derive level:

```elixir
@impl true
def mount(params, _session, socket) do
  sessions = Workouts.list_sessions(socket.assigns.current_user)
  level = Levels.current_level(sessions)

  {:ok,
   socket
   |> assign(:live_action, socket.assigns.live_action)
   |> assign(:expanded_blocks, MapSet.new())
   |> assign(:open_block_menu, nil)
   |> assign(:level, level)
   |> load_plan(params)
   |> build_form_from_plan()
   |> assign_derived()}
end
```

- [ ] **Step 4: Update `default_plan_input/0`**

```elixir
defp default_plan_input do
  %{
    name: "New plan",
    burpee_type: :six_count,
    target_duration_min: 20,
    burpee_count_target: 100,
    pacing_style: :even,
    reps_per_set: PlanSolver.default_reps_per_set(:six_count),
    additional_rests: []
  }
end
```

- [ ] **Step 5: Update `plan_input_from_plan/1`**

```elixir
defp plan_input_from_plan(plan) do
  rests =
    case Jason.decode(plan.additional_rests || "[]") do
      {:ok, list} ->
        Enum.map(list, fn %{"rest_sec" => r, "target_min" => t} ->
          %{rest_sec: r, target_min: t}
        end)
      _ -> []
    end

  %{
    name: plan.name,
    burpee_type: plan.burpee_type,
    target_duration_min: plan.target_duration_min || 20,
    burpee_count_target: plan.burpee_count_target || 100,
    pacing_style: plan.pacing_style || :even,
    reps_per_set: infer_reps_per_set(plan),
    additional_rests: rests
  }
end
```

- [ ] **Step 6: Update `infer_reps_per_set/1`**

```elixir
defp infer_reps_per_set(plan) do
  first_set =
    plan.blocks
    |> Enum.sort_by(& &1.position)
    |> List.first()
    |> case do
      nil -> nil
      block -> block.sets |> Enum.sort_by(& &1.position) |> List.first()
    end

  (first_set && first_set.burpee_count) || PlanSolver.default_reps_per_set(plan.burpee_type)
end
```

- [ ] **Step 7: Update `regenerate/1`**

```elixir
defp regenerate(socket) do
  plan_input = socket.assigns.plan_input
  level = socket.assigns.level

  solver_input = %Input{
    name: plan_input.name,
    burpee_type: plan_input.burpee_type,
    target_duration_min: plan_input.target_duration_min,
    burpee_count_target: plan_input.burpee_count_target,
    pacing_style: plan_input.pacing_style,
    level: level,
    reps_per_set: plan_input.reps_per_set,
    additional_rests: plan_input.additional_rests
  }

  case PlanSolver.solve(solver_input) do
    {:ok, solution} ->
      base = socket.assigns.plan || %WorkoutPlan{}
      changeset = Workouts.change_plan(%{base | blocks: []}, plan_to_attrs(solution.plan))

      socket
      |> assign(:form, to_form(changeset))
      |> assign(:solver_error, nil)
      |> assign(:solver_solution, solution)

    {:error, reasons} ->
      existing_form =
        socket.assigns[:form] || to_form(Workouts.change_plan(%WorkoutPlan{blocks: []}))

      socket
      |> assign(:form, existing_form)
      |> assign(:solver_error, Enum.join(reasons, "; "))
      |> assign(:solver_solution, nil)
  end
end
```

Also add `:solver_solution` to the initial socket state in `load_plan/2`:

```elixir
defp load_plan(socket, %{"id" => id}) do
  plan = ...
  socket
  |> assign(:plan, plan)
  |> assign(:plan_input, plan_input_from_plan(plan))
  |> assign(:page_title, "Edit plan")
  |> assign(:solver_error, nil)
  |> assign(:solver_solution, nil)
end

defp load_plan(socket, _params) do
  socket
  |> assign(:plan, nil)
  |> assign(:plan_input, default_plan_input())
  |> assign(:page_title, "New plan")
  |> assign(:solver_error, nil)
  |> assign(:solver_solution, nil)
end
```

- [ ] **Step 8: Update `plan_to_attrs/1`**

Remove `"sec_per_burpee"` from the top-level attrs (it's still in sets). Remove `"fatigue_factor"`:

```elixir
defp plan_to_attrs(%WorkoutPlan{} = plan) do
  %{
    "name" => plan.name,
    "burpee_type" => Atom.to_string(plan.burpee_type),
    "target_duration_min" => plan.target_duration_min,
    "burpee_count_target" => plan.burpee_count_target,
    "sec_per_burpee" => plan.sec_per_burpee,
    "pacing_style" => Atom.to_string(plan.pacing_style),
    "additional_rests" => plan.additional_rests,
    "blocks" => blocks_to_attrs(plan.blocks)
  }
end
```

- [ ] **Step 9: Update `parse_basics/2` — remove sec_per_burpee**

```elixir
defp parse_basics(params, current) do
  name = Map.get(params, "name", current.name)

  target_duration_min =
    case Integer.parse(Map.get(params, "target_duration_min", "")) do
      {n, ""} when n > 0 -> n
      _ -> current.target_duration_min
    end

  burpee_count_target =
    case Integer.parse(Map.get(params, "burpee_count_target", "")) do
      {n, ""} when n > 0 -> n
      _ -> current.burpee_count_target
    end

  reps_per_set =
    case Integer.parse(Map.get(params, "reps_per_set", "")) do
      {n, ""} when n > 0 -> n
      _ -> current.reps_per_set
    end

  %{current | name: name, target_duration_min: target_duration_min,
              burpee_count_target: burpee_count_target, reps_per_set: reps_per_set}
end
```

- [ ] **Step 10: Update `merge_basics/2` — remove sec_per_burpee**

```elixir
defp merge_basics(params, plan_input) do
  Map.merge(params, %{
    "name" => plan_input.name,
    "burpee_type" => Atom.to_string(plan_input.burpee_type),
    "target_duration_min" => plan_input.target_duration_min,
    "burpee_count_target" => plan_input.burpee_count_target,
    "pacing_style" => Atom.to_string(plan_input.pacing_style),
    "additional_rests" =>
      Jason.encode!(
        Enum.map(plan_input.additional_rests, fn %{rest_sec: r, target_min: t} ->
          %{"rest_sec" => r, "target_min" => t}
        end)
      )
  })
end
```

- [ ] **Step 11: Update `handle_event("pick_type", ...)`**

```elixir
def handle_event("pick_type", %{"type" => type}, socket)
    when type in ["six_count", "navy_seal"] do
  burpee_type = String.to_atom(type)

  plan_input =
    socket.assigns.plan_input
    |> Map.put(:burpee_type, burpee_type)
    |> Map.put(:reps_per_set, PlanSolver.default_reps_per_set(burpee_type))

  socket =
    socket
    |> assign(:plan_input, plan_input)
    |> regenerate()
    |> assign_derived()

  {:noreply, socket}
end
```

- [ ] **Step 12: Remove `handle_event("set_fatigue_factor", ...)` entirely**

Delete that event handler.

- [ ] **Step 13: Remove dead helper functions**

Delete these functions which are now unused:
- `pace_floor/1`
- `pace_floor_label/1`
- `format_sec/1`

- [ ] **Step 14: Update the Layer 1 template — remove sec/burpee input, add level hint**

Find the `sec_per_burpee` input block (around line 777–790) and replace it with a level hint:

```heex
<div class="space-y-1">
  <label class="text-xs text-base-content/50">Your level</label>
  <p class="text-sm font-medium">
    {Atom.to_string(@level) |> String.replace("_", " ") |> String.upcase()}
  </p>
  <p class="text-xs text-base-content/30">
    Min pace: {Float.to_string(BurpeeTrainer.PlanSolver.sustainable_ceiling(@level))}s/rep
    — solver will not go faster
  </p>
</div>
```

Also remove the fatigue bias control block (the `set_fatigue_factor` phx-click section).

- [ ] **Step 15: Add solver summary to Layer 3**

Find the Layer 3 section (where blocks are shown). Add a summary bar just above the blocks, conditional on `@solver_solution`:

```heex
<%= if @solver_solution do %>
  <div class="px-5 py-3 border-b border-[#1E2535] text-xs text-base-content/50 flex gap-6">
    <span>Pace: <strong class="text-base-content">{Float.round(@solver_solution.sec_per_burpee, 2)}s/rep</strong></span>
    <span>Sets: <strong class="text-base-content">{@solver_solution.set_count} × {@solver_solution.set_size}</strong></span>
    <span>Rest/set: <strong class="text-base-content">{round(@solver_solution.rest_sec)}s</strong></span>
  </div>
<% end %>
```

- [ ] **Step 16: Compile and check**

```bash
mix compile --warnings-as-errors 2>&1 | head -40
```

Fix any remaining references to `PlanWizard`, `sec_per_burpee` in the LiveView, or `fatigue_factor` event handlers. Expected: no warnings.

- [ ] **Step 17: Commit**

```bash
git add lib/burpee_trainer_web/live/plans_live/edit.ex
git commit -m "feat: wire PlanSolver into plan edit LiveView, remove sec_per_burpee input"
```

---

## Task 7: Run full test suite and fix breakage

**Files:**
- Any file that references `BurpeeTrainer.PlanWizard` outside `plan_wizard/` itself

- [ ] **Step 1: Find all PlanWizard references outside the wizard directory**

```bash
grep -rn "PlanWizard\|PlanInput\|fatigue_factor\|set_fatigue_factor" \
  lib/ test/ \
  --include="*.ex" --include="*.exs" \
  | grep -v "plan_wizard" \
  | grep -v "plan_solver"
```

- [ ] **Step 2: Run the full test suite**

```bash
mix test 2>&1 | tail -40
```

- [ ] **Step 3: Fix each failure**

For each failing test or compile error:
- If it references `PlanWizard` in a test that tests `PlanSolver` behaviour → rewrite the test to use `PlanSolver.Input` and `PlanSolver.solve/1`
- If it references `PlanWizard` in production code other than `edit.ex` → update the alias and call
- If it fails due to a missing `sec_per_burpee` or `fatigue_factor` field → remove the field reference

- [ ] **Step 4: Run precommit**

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: update all PlanWizard references to PlanSolver after migration"
```

---

## Task 8: Update `Workouts.list_sessions/1` (if needed)

**Files:**
- Possibly modify: `lib/burpee_trainer/workouts.ex`

- [ ] **Step 1: Check if `list_sessions/1` exists**

```bash
grep -n "def list_sessions" /home/aktersnurra/projects/vibe/burpee_trainer/lib/burpee_trainer/workouts.ex
```

If it exists and takes a user argument, skip to step 3. If it doesn't exist or has a different signature, add it.

- [ ] **Step 2: Add `list_sessions/1` if missing**

In `lib/burpee_trainer/workouts.ex`, add:

```elixir
@spec list_sessions(User.t()) :: [WorkoutSession.t()]
def list_sessions(%User{} = user) do
  Repo.all(from s in WorkoutSession, where: s.user_id == ^user.id, order_by: [desc: s.inserted_at])
end
```

- [ ] **Step 3: Compile**

```bash
mix compile --warnings-as-errors
```

Expected: no warnings.

- [ ] **Step 4: Commit if changed**

```bash
git add lib/burpee_trainer/workouts.ex
git commit -m "feat: add Workouts.list_sessions/1 for level derivation"
```

---

## Task 9: Delete `PlanWizard` and its tests

All PlanWizard references are now replaced. Delete the old code.

- [ ] **Step 1: Confirm no remaining references**

```bash
grep -rn "PlanWizard" lib/ test/ --include="*.ex" --include="*.exs" \
  | grep -v "plan_wizard/"
```

Expected: no output.

- [ ] **Step 2: Delete PlanWizard source tree**

```bash
rm -rf lib/burpee_trainer/plan_wizard.ex lib/burpee_trainer/plan_wizard/
```

- [ ] **Step 3: Delete PlanWizard tests**

```bash
rm -rf test/burpee_trainer/plan_wizard/
```

- [ ] **Step 4: Run precommit**

```bash
mix precommit
```

Expected: PASS — compile clean, format clean, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete PlanWizard, fully replaced by PlanSolver"
```

---

## Task 10: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read CHANGELOG and prepend entry**

Read `CHANGELOG.md`, then prepend under an `## Unreleased` heading (or add one if absent):

```markdown
## PlanSolver — session plan MILP with solver-chosen pace

- Replaced `BurpeeTrainer.PlanWizard` with `BurpeeTrainer.PlanSolver`.
- `sec_per_burpee` is no longer a user input. The solver finds the optimal pace
  bounded below by `PlanSolver.sustainable_ceiling/1` (level-derived).
- Extended LP formulation: `p` (pace) is a free variable in the same problem
  as rest distribution, finding the true joint optimum rather than two
  sequential optima.
- New shared LP infrastructure: `BurpeeTrainer.Milp.{Problem,Mps,Highs}` —
  reusable for future ScheduleSolver.
- UI: Layer 1 shows level + min pace hint instead of sec/burpee input.
  Layer 3 shows solver-chosen pace, sets, rest as a read-only summary.
```

- [ ] **Step 2: Final precommit**

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for PlanSolver"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| Remove `sec_per_burpee` as user input | Tasks 2, 6 |
| Level-derived sustainable ceiling | Task 5 (`sustainable_ceiling/1`) |
| Solver finds `p` jointly with rest | Task 3 (`PlanSolver.Lp`) |
| `PlanSolver.sustainable_ceiling/1` public API | Task 5 |
| `BurpeeTrainer.PlanSolver.solve/1` public API | Task 5 |
| `%PlanSolution{}` output struct | Task 2 |
| UI: remove sec/burpee input, add level hint | Task 6, step 14 |
| UI: Layer 3 solver summary | Task 6, step 15 |
| Milp.* shared namespace | Task 1 |
| Delete PlanWizard | Task 9 |

**Placeholder scan:** No TBD, TODO, or "similar to" references found.

**Type consistency check:**
- `Apply.to_workout_plan/4` signature: `(Input.t(), float, [float], [map])` — called with `(input, p, r, reservations)` in Task 5 ✓
- `Highs.solve/1` returns `{:ok, %{r: [float], p: float | nil, objective: float}}` — consumed in Task 5 `run_lp/2` ✓
- `Lp.build/2` takes `(Input.t(), pos_integer | nil)` — called in Task 5 ✓
- `Solution` fields match `build_solution/4` in Task 5 ✓
