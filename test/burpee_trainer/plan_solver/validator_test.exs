defmodule BurpeeTrainer.PlanSolver.ValidatorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Input, Validator}

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        name: "validator",
        burpee_type: :six_count,
        target_duration_min: 20,
        burpee_count_target: 108,
        pacing_style: :unbroken,
        level: :level_1c,
        reps_per_set: 8,
        reps_per_set_fixed?: true,
        additional_rests: []
      },
      overrides
    )
    |> then(&struct!(Input, &1))
  end

  test "validates unbroken fixed reps per set and final remainder" do
    input = input()
    assert {:ok, solution} = PlanSolver.solve(input)

    assert :ok = Validator.validate(solution, input)

    assert solution.set_pattern == List.duplicate(8, 13) ++ [4]
    assert Enum.drop(solution.set_pattern, -1) |> Enum.all?(&(&1 == 8))
  end

  test "rejects solutions that rewrite fixed unbroken set size" do
    input = input(%{burpee_count_target: 24})
    assert {:ok, solution} = PlanSolver.solve(input)

    rewritten = %{solution | set_pattern: [6, 6, 12]}

    assert {:error, {:unbroken_reps_per_set_changed, %{expected: 8}}} =
             Validator.validate(rewritten, input)
  end

  test "rejects hidden rest after final set" do
    input = input(%{burpee_count_target: 24})
    assert {:ok, solution} = PlanSolver.solve(input)

    with_final_rest = %{solution | rest_pattern_sec: solution.rest_pattern_sec ++ [10.0]}

    assert {:error, :hidden_final_rest} = Validator.validate(with_final_rest, input)
  end
end
