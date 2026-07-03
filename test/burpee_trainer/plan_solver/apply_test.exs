defmodule BurpeeTrainer.PlanSolver.ApplyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{
    Apply,
    Execution,
    Input,
    PacePolicy,
    StructureSearch,
    UnbrokenSolver
  }

  defp even_input(n, dur_min) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_sec: dur_min * 60,
      burpee_count_target: n,
      pacing_style: :even,
      level: :level_1c
    }
  end

  defp unbroken_input(n, dur_min, rps) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_sec: dur_min * 60,
      burpee_count_target: n,
      pacing_style: :unbroken,
      level: :level_1c,
      max_unbroken_reps: rps
    }
  end

  test "legacy direct workout-plan builders are not exported" do
    refute function_exported?(Apply, :to_workout_plan, 4)
    refute function_exported?(Apply, :to_workout_plan, 5)
  end

  test ":even solved six-count catch-up persists exact v3 totals" do
    input = %{even_input(120, 20) | block_pattern: [12]}

    {:ok, solution} = BurpeeTrainer.PlanSolver.generate_plan(input)

    [block] = solution.plan.blocks
    assert block.repeat_count == 10
    assert Enum.map(block.sets, & &1.burpee_count) == [12]
    assert BurpeeTrainer.Planner.summary(solution.plan).burpee_count_total == 120

    [block_summary] = BurpeeTrainer.Planner.summary(solution.plan).blocks
    assert block_summary.burpee_count_total == 120
    assert round(block_summary.duration_sec_work) == 1200
    assert solution.metadata.strategy == :even
  end

  test ":even with preferred block pattern and rest — v3 keeps exact total duration" do
    input = %Input{
      name: "Pattern rest",
      burpee_type: :navy_seal,
      level: :level_1a,
      target_duration_sec: 1_200,
      burpee_count_target: 70,
      pacing_style: :even,
      block_pattern: [4, 3],
      explicit_rests: [
        %BurpeeTrainer.PlanSolver.ExplicitRest{
          target_elapsed_sec: 12 * 60,
          duration_sec: 20,
          tolerance_sec: 60
        }
      ]
    }

    {:ok, sol} = BurpeeTrainer.PlanSolver.generate_plan(input)

    assert [first_run, rest_step, second_run] = sol.plan.steps
    assert first_run.kind == :block_run
    assert first_run.repeat_count == 6
    assert rest_step.kind == :rest
    assert rest_step.rest_sec == 20
    assert second_run.kind == :block_run
    assert second_run.repeat_count == 4
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 70
    assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == 1200
    assert sol.metadata.strategy == :even
  end

  test ":unbroken does not count recovery after the final repeated set" do
    input = unbroken_input(144, 20, 8)

    {:ok, solution} = BurpeeTrainer.PlanSolver.generate_plan(input)

    assert solution.set_pattern == List.duplicate(8, 18)
    assert round(BurpeeTrainer.Planner.summary(solution.plan).duration_sec_total) == 1200

    assert Enum.sum(Enum.map(solution.plan.blocks, & &1.repeat_count)) == 18

    assert Enum.all?(solution.plan.blocks, fn block ->
             [%{burpee_count: 8}] = block.sets
             true
           end)

    final_block = List.last(solution.plan.blocks)
    assert final_block.repeat_count == 1
    assert [%{end_of_set_rest: 0}] = final_block.sets

    assert Enum.any?(Enum.drop(solution.plan.blocks, -1), fn block ->
             [%{end_of_set_rest: rest_after_set}] = block.sets
             rest_after_set > 0
           end)
  end

  test "persists v3 prescription metadata and matches execution summary" do
    input = %Input{
      name: "140",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8,
      explicit_rests: []
    }

    {:ok, prescription} = UnbrokenSolver.solve(input, PacePolicy.for(:six_count))
    execution = Execution.build(prescription)

    assert {:ok, plan} = Apply.from_execution(input, execution, prescription)
    assert plan.plan_solver_metadata.solver_version == 3
    assert plan.plan_solver_metadata.structure_key == StructureSearch.encode(prescription.blocks)
    assert BurpeeTrainer.Planner.summary(plan).burpee_count_total == 140
    assert abs(BurpeeTrainer.Planner.summary(plan).duration_sec_total - 1_200) <= 1
  end
end
