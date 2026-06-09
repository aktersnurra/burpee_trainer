defmodule BurpeeTrainer.PlanEditorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanEditor

  test "new editor uses PlanSolver as the primary generated source" do
    assert {:ok, state} = PlanEditor.new(:level_1a, %{})

    assert state.solver_solution
    assert state.structure
    assert state.form_plan.burpee_count_target == state.input.burpee_count_target
  end

  test "unbroken reps per set input is respected by generated editor plan" do
    assert {:ok, state} = PlanEditor.new(:level_1a, %{})

    assert {:ok, state} =
             PlanEditor.change_basics(state, %{
               "pacing_style" => "unbroken",
               "burpee_count_target" => "107",
               "target_duration_min" => "20",
               "reps_per_set" => "10"
             })

    assert state.solver_solution.set_pattern == List.duplicate(10, 10) ++ [7]
    assert Enum.drop(state.solver_solution.set_pattern, -1) |> Enum.all?(&(&1 == 10))
  end

  test "change_block_pattern ignores Phoenix unused placeholder keys" do
    assert {:ok, state} = PlanEditor.new(:level_1a, %{})

    assert {:ok, changed} =
             PlanEditor.change_block_pattern(state, %{
               "pattern" => %{"_unused_0" => "", "0" => "10"}
             })

    assert changed.input.block_pattern == [10]
  end
end
