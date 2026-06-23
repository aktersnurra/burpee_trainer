defmodule BurpeeTrainer.PlanSolver.UnbrokenSolverTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Input, PacePolicy, StructureSearch, UnbrokenSolver}

  test "generated 140-rep case is exact and not overfit to one shape" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      explicit_rests: []
    }

    assert {:ok, prescription} = UnbrokenSolver.solve(input, PacePolicy.for(:six_count))

    assert prescription.pacing_style == :unbroken
    assert prescription.burpee_count == 140
    assert prescription.target_duration_sec == 1_200
    assert Enum.sum(prescription.set_pattern) == 140
    assert Enum.all?(prescription.set_pattern, &(&1 <= 8))

    assert StructureSearch.encode(prescription.blocks) in ["20x[7]", "5x[8]|5x[7]|5x[7,6]"] or
             length(prescription.blocks) <= 4

    assert prescription.metadata.strategy in [:generated_grammar, :balanced_fallback]
  end

  test "manual tapered 140-rep structure is preserved exactly" do
    {:ok, block1} = BlockSpec.new(5, [8])
    {:ok, block2} = BlockSpec.new(5, [7])
    {:ok, block3} = BlockSpec.new(5, [7, 6])

    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      block_structure: [block1, block2, block3],
      explicit_rests: []
    }

    assert {:ok, prescription} = UnbrokenSolver.solve(input, PacePolicy.for(:six_count))
    assert prescription.blocks == [block1, block2, block3]
    assert prescription.metadata.strategy == :manual_structure
  end

  test "hard fastest pace is never relaxed" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 300,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      explicit_rests: []
    }

    assert {:error, error} = UnbrokenSolver.solve(input, PacePolicy.for(:six_count))

    assert error.reason in [
             :work_alone_exceeds_duration,
             :no_pace_within_hard_bounds,
             :no_human_shaped_recovery_allocation
           ]
  end
end
