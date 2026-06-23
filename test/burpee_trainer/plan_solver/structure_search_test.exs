defmodule BurpeeTrainer.PlanSolver.StructureSearchTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Input, StructureSearch}

  test "preserves manual block structure exactly" do
    {:ok, block1} = BlockSpec.new(5, [8])
    {:ok, block2} = BlockSpec.new(5, [7])
    {:ok, block3} = BlockSpec.new(5, [7, 6])

    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      block_structure: [block1, block2, block3]
    }

    assert {:ok, [[^block1, ^block2, ^block3]]} = StructureSearch.structures(input)
  end

  test "generated 140-rep structures include readable exact options without requiring one golden shape" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8
    }

    assert {:ok, structures} = StructureSearch.structures(input)
    encodings = Enum.map(structures, &StructureSearch.encode/1)

    assert "20x[7]" in encodings or "5x[8]|5x[7]|5x[7,6]" in encodings

    assert Enum.all?(structures, fn structure ->
             set_pattern = StructureSearch.expand(structure)
             Enum.sum(set_pattern) == 140 and Enum.all?(set_pattern, &(&1 <= 8))
           end)
  end

  test "balanced fallback avoids tiny final scrap sets" do
    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 139,
      pacing_style: :unbroken,
      max_unbroken_reps: 8
    }

    assert {:ok, [structure | _]} = StructureSearch.structures(input)
    set_pattern = StructureSearch.expand(structure)

    assert Enum.sum(set_pattern) == 139
    assert Enum.min(set_pattern) >= 5
    assert Enum.max(set_pattern) <= 8
  end
end
