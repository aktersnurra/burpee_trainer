defmodule BurpeeTrainer.PlanSolver.EvenSolverTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{EvenSolver, Input, PacePolicy}

  test "even pacing uses one cadence stream and preserves style" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :even,
      explicit_rests: []
    }

    assert {:ok, prescription} = EvenSolver.solve(input, PacePolicy.for(:six_count))
    assert prescription.pacing_style == :even
    assert prescription.burpee_count == 140
    assert prescription.cadence_sec >= prescription.sec_per_rep
    assert prescription.recoveries == []
    assert prescription.metadata.strategy == :even
  end

  test "even pacing rejects impossible hard-fastest target" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 300,
      burpee_count_target: 140,
      pacing_style: :even,
      explicit_rests: []
    }

    assert {:error, error} = EvenSolver.solve(input, PacePolicy.for(:six_count))
    assert error.reason == :no_pace_within_hard_bounds
  end
end
