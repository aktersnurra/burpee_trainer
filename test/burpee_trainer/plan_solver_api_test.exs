defmodule BurpeeTrainer.PlanSolverApiTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Execution, GeneratedPlan, Input, Solution}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  defp canonical_input do
    %Input{
      burpee_type: :six_count,
      target_duration_sec: 600,
      burpee_count_target: 60,
      pacing_style: :even,
      block_pattern: [10],
      explicit_rests: []
    }
  end

  test "solve returns solved execution without derived plan projection fields" do
    assert {:ok, %Solution{} = solution} = PlanSolver.solve(canonical_input())

    assert is_list(solution.execution)

    assert Enum.all?(solution.execution, fn event ->
             match?(%Execution.SetEvent{}, event) or match?(%Execution.RestEvent{}, event)
           end)

    assert solution.metadata.strategy == :even
    assert solution.prescription.pacing_style == :even
    assert solution.prescription.burpee_count == 60

    refute Map.has_key?(Map.from_struct(solution), :plan)
    refute Map.has_key?(Map.from_struct(solution), :sec_per_burpee)
    refute Map.has_key?(Map.from_struct(solution), :set_count)
    refute Map.has_key?(Map.from_struct(solution), :rest_sec)
  end

  test "input exposes canonical solver fields only" do
    keys = Map.keys(canonical_input())

    refute :target_duration_min in keys
    refute :reps_per_set in keys
    refute :additional_rests in keys
    refute :sec_per_burpee_override in keys
  end

  test "generate_plan is the explicit legacy plan projection adapter" do
    assert {:ok, %GeneratedPlan{} = generated} = PlanSolver.generate_plan(canonical_input())

    assert %WorkoutPlan{} = generated.plan
    assert generated.plan.burpee_count_target == 60
    assert generated.plan.target_duration_min == 10
    assert generated.execution == generated.solution.execution
  end
end
