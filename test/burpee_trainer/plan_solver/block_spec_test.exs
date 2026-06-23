defmodule BurpeeTrainer.PlanSolver.BlockSpecTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.BlockSpec

  test "expands repeated one-set motifs" do
    {:ok, block} = BlockSpec.new(5, [8])

    assert BlockSpec.expand(block) == [8, 8, 8, 8, 8]
    assert BlockSpec.encode(block) == "5x[8]"
    assert BlockSpec.total_reps(block) == 40
    assert BlockSpec.set_count(block) == 5
  end

  test "expands repeated two-set motifs" do
    {:ok, block} = BlockSpec.new(5, [7, 6])

    assert BlockSpec.expand(block) == [7, 6, 7, 6, 7, 6, 7, 6, 7, 6]
    assert BlockSpec.encode(block) == "5x[7,6]"
    assert BlockSpec.average_reps(block) == 6.5
  end

  test "rejects invalid motifs" do
    assert {:error, {:invalid_repeat, 0}} = BlockSpec.new(0, [8])
    assert {:error, {:invalid_motif, []}} = BlockSpec.new(5, [])
    assert {:error, {:invalid_motif, [8, 7, 6]}} = BlockSpec.new(5, [8, 7, 6])
    assert {:error, {:invalid_rep_count, 0}} = BlockSpec.new(5, [8, 0])
  end
end
