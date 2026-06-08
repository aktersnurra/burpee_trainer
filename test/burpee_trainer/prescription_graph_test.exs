defmodule BurpeeTrainer.PrescriptionGraphTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PrescriptionGraph
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  describe "build/3" do
    test "splits repeated block runs around additional rests" do
      plan = %WorkoutPlan{
        blocks: [
          %Block{
            position: 1,
            repeat_count: 10,
            sets: [
              %Set{
                position: 1,
                burpee_count: 4,
                sec_per_rep: 15.0,
                sec_per_burpee: 8.0,
                end_of_set_rest: 0
              },
              %Set{
                position: 2,
                burpee_count: 3,
                sec_per_rep: 20.0,
                sec_per_burpee: 8.0,
                end_of_set_rest: 0
              }
            ]
          }
        ]
      }

      graph = PrescriptionGraph.build(plan, [%{target_min: 12, rest_sec: 10}], 1210)

      assert Enum.map(graph.nodes, & &1.kind) == [:start, :block_run, :rest, :block_run, :finish]

      assert Enum.at(graph.nodes, 1) == %PrescriptionGraph.BlockRunNode{
               kind: :block_run,
               id: {:block_run, 0, 1},
               source_block_index: 0,
               repeat_from: 1,
               repeat_to: 6,
               repeat_count: 6,
               starts_at_sec: 0.0,
               ends_at_sec: 720.0,
               block: hd(plan.blocks)
             }

      assert Enum.at(graph.nodes, 2) == %PrescriptionGraph.RestNode{
               kind: :rest,
               id: {:additional_rest, 0},
               source_rest_index: 0,
               starts_at_sec: 720,
               duration_sec: 10
             }

      assert %{
               __struct__: PrescriptionGraph.BlockRunNode,
               kind: :block_run,
               source_block_index: 0,
               repeat_from: 7,
               repeat_to: 10,
               repeat_count: 4,
               starts_at_sec: 730,
               ends_at_sec: 1210.0
             } = Enum.at(graph.nodes, 3)
    end

    test "does not turn set recovery into top-level rest nodes" do
      plan = %WorkoutPlan{
        blocks: [
          %Block{
            position: 1,
            repeat_count: 1,
            sets: [
              %Set{
                position: 1,
                burpee_count: 10,
                sec_per_rep: 6.0,
                sec_per_burpee: 3.0,
                end_of_set_rest: 30
              },
              %Set{
                position: 2,
                burpee_count: 10,
                sec_per_rep: 6.0,
                sec_per_burpee: 3.0,
                end_of_set_rest: 0
              }
            ]
          }
        ]
      }

      graph = PrescriptionGraph.build(plan, [], 150)

      assert Enum.map(graph.nodes, & &1.kind) == [:start, :block_run, :finish]
    end
  end
end
