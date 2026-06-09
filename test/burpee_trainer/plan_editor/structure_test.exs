defmodule BurpeeTrainer.PlanEditor.StructureTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanEditor.Structure
  alias BurpeeTrainer.PlanEditor.Structure.{RestNode, WorkNode}
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.Input

  defp input(overrides) do
    Map.merge(
      %{
        name: "structure",
        burpee_type: :six_count,
        target_duration_min: 20,
        burpee_count_target: 100,
        pacing_style: :even,
        level: :level_1a,
        reps_per_set: 8,
        additional_rests: []
      },
      overrides
    )
    |> then(&struct!(Input, &1))
  end

  test "converts solver output into ordered work and explicit rest nodes" do
    assert {:ok, solution} =
             PlanSolver.solve(
               input(%{
                 burpee_count_target: 64,
                 pacing_style: :even,
                 additional_rests: [%{rest_sec: 45, target_min: 10}]
               })
             )

    structure = Structure.from_plan(solution.plan)

    assert Enum.any?(structure.nodes, &match?(%WorkNode{}, &1))
    assert Enum.any?(structure.nodes, &match?(%RestNode{rest_sec: 45}, &1))
    assert Structure.total_reps(structure) == 64
  end

  test "notation keeps Block/Set semantics while showing explicit rests" do
    structure = %Structure{
      nodes: [
        %WorkNode{repeat_count: 5, set_pattern: [8]},
        %RestNode{rest_sec: 60},
        %WorkNode{repeat_count: 4, set_pattern: [7, 6]}
      ]
    }

    assert Structure.notation(structure) == "5 × [8] · Rest 60s · 4 × [7, 6]"
  end

  test "updates explicit rest nodes without touching work nodes" do
    structure = %Structure{
      nodes: [
        %WorkNode{repeat_count: 5, set_pattern: [8]},
        %RestNode{rest_sec: 60}
      ]
    }

    assert {:ok, updated} = Structure.update_rest(structure, 1, 45)

    assert [%WorkNode{repeat_count: 5, set_pattern: [8]}, %RestNode{rest_sec: 45}] =
             updated.nodes
  end

  test "updates work node repeat and set pattern without touching explicit rests" do
    structure = %Structure{
      nodes: [
        %WorkNode{repeat_count: 5, set_pattern: [8]},
        %RestNode{rest_sec: 60}
      ]
    }

    assert {:ok, updated} =
             Structure.update_work(structure, 0, repeat_count: 4, set_pattern: [7, 6])

    assert [%WorkNode{repeat_count: 4, set_pattern: [7, 6]}, %RestNode{rest_sec: 60}] =
             updated.nodes
  end
end
