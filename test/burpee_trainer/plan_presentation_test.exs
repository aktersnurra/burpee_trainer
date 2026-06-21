defmodule BurpeeTrainer.PlanPresentationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.{PlanPresentation, PlanSolver}

  test "collapses solver-fragmented unbroken plan into one logical block with set ranges" do
    input = %PlanSolver.Input{
      name: "144 in 20",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 144,
      pacing_style: :unbroken,
      level: :level_1a,
      reps_per_set: 8
    }

    assert {:ok, solution} = PlanSolver.solve(input)
    assert length(solution.plan.blocks) > 1

    outline = PlanPresentation.outline(solution.plan)

    assert outline.summary == "20:00 · 144 reps · 18 sets"

    assert [
             %{
               title: "Block 1",
               set_count: 18,
               total_reps: 144,
               default_recovery_sec: 15,
               default_recovery_label: "15s recovery",
               rows: rows
             }
           ] = outline.blocks

    assert %{
             from_set: 1,
             to_set: 12,
             reps: 8,
             recovery_sec: 15,
             recovery_label: "15s recovery"
           } = Enum.at(rows, 0)

    assert %{from_set: 13, to_set: 13, reps: 8, recovery_sec: 90, recovery_label: "90s recovery"} =
             Enum.at(rows, 1)

    assert %{from_set: 14, to_set: 16, reps: 8, recovery_sec: 15, recovery_label: "15s recovery"} =
             Enum.at(rows, 2)

    assert %{from_set: 17, to_set: 17, reps: 8, recovery_sec: 90, recovery_label: "90s recovery"} =
             Enum.at(rows, 3)

    assert %{from_set: 18, to_set: 18, reps: 8, recovery_sec: 0, recovery_label: "No recovery"} =
             Enum.at(rows, 4)
  end
end
