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

  test "even pacing preserves preferred block pattern as cadence groups" do
    input = %Input{
      burpee_type: :navy_seal,
      target_duration_sec: 1_200,
      burpee_count_target: 70,
      pacing_style: :even,
      block_pattern: [4, 3],
      explicit_rests: []
    }

    expected_pattern =
      List.duplicate(4, 10)
      |> Enum.zip(List.duplicate(3, 10))
      |> Enum.flat_map(&Tuple.to_list/1)

    assert {:ok, prescription} = EvenSolver.solve(input, PacePolicy.for(:navy_seal))
    assert Enum.map(prescription.blocks, &{&1.repeat, &1.motif}) == [{10, [4, 3]}]
    assert prescription.set_pattern == expected_pattern
  end

  test "even pacing compresses long legacy block patterns into valid v3 motifs" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 120,
      pacing_style: :even,
      block_pattern: [10, 10, 10],
      explicit_rests: []
    }

    assert {:ok, prescription} = EvenSolver.solve(input, PacePolicy.for(:six_count))
    assert Enum.sum(prescription.set_pattern) == 120
    assert Enum.all?(prescription.blocks, &(length(&1.motif) <= 2))
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
