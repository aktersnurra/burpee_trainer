defmodule BurpeeTrainer.PlanSolver.MilpTest do
  use ExUnit.Case, async: false

  alias BurpeeTrainer.PlanSolver.Milp

  test "selects the lowest-cost feasible precomputed option with HiGHS" do
    options = [
      %{id: :bad, cost: 10.0, duration_ds: 12_000, reps: 100},
      %{id: :good, cost: 1.0, duration_ds: 12_000, reps: 100}
    ]

    assert {:ok, %{id: :good}} =
             Milp.select_option(options,
               target_duration_ds: 12_000,
               target_reps: 100
             )
  end

  test "returns infeasible when no precomputed option matches hard constraints" do
    options = [
      %{id: :wrong_reps, cost: 1.0, duration_ds: 12_000, reps: 90},
      %{id: :wrong_duration, cost: 1.0, duration_ds: 11_000, reps: 100}
    ]

    assert {:error, :infeasible} =
             Milp.select_option(options,
               target_duration_ds: 12_000,
               target_reps: 100
             )
  end
end
