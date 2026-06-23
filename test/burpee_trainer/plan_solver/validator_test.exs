defmodule BurpeeTrainer.PlanSolver.ValidatorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{Execution, Input, PacePolicy, UnbrokenSolver, Validator}

  test "execution from unbroken prescription has exact reps and duration" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      explicit_rests: []
    }

    {:ok, prescription} = UnbrokenSolver.solve(input, PacePolicy.for(:six_count))

    execution = Execution.build(prescription)

    assert :ok = Validator.validate_execution(input, prescription, execution)
  end
end
