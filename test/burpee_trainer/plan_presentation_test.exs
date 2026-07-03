defmodule BurpeeTrainer.PlanPresentationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.{PlanPresentation, PlanSolver}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  test "renders v3 solver plan from persisted prescription metadata" do
    input = %PlanSolver.Input{
      name: "144 in 20",
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 144,
      pacing_style: :unbroken,
      level: :level_1a,
      max_unbroken_reps: 8
    }

    assert {:ok, solution} = PlanSolver.generate_plan(input)

    outline = PlanPresentation.outline(solution.plan)

    assert outline.summary =~ "20:00 · 144 reps"

    assert [block] = outline.blocks
    assert block.set_count == length(solution.set_pattern)
    assert block.total_reps == 144
    assert block.default_recovery_label =~ "recovery"
    assert block.rows != []
    assert List.last(block.rows).recovery_label == "No recovery"
  end

  test "v3 metadata outline includes explicit rest steps" do
    input = %PlanSolver.Input{
      name: "Explicit rest",
      burpee_type: :six_count,
      target_duration_sec: 600,
      burpee_count_target: 10,
      pacing_style: :even,
      level: :level_1a,
      block_pattern: [5],
      explicit_rests: [
        %PlanSolver.ExplicitRest{target_elapsed_sec: 300, duration_sec: 60, tolerance_sec: 60}
      ]
    }

    assert {:ok, solution} = PlanSolver.generate_plan(input)
    assert Enum.any?(solution.plan.steps, &(&1.kind == :rest and &1.rest_sec == 60))

    outline = PlanPresentation.outline(solution.plan)
    rows = outline.blocks |> hd() |> Map.fetch!(:rows)

    assert Enum.any?(rows, &(&1.recovery_label == "60s recovery"))
  end

  test "outline prefers persisted prescription blocks when available" do
    plan = %WorkoutPlan{
      name: "140",
      burpee_type: :six_count,
      target_duration_min: 20,
      pacing_style: :unbroken,
      sec_per_burpee: 5.5,
      plan_solver_metadata: %{
        solver_version: 3,
        structure_key: "20x[7]",
        blocks: [%{repeat: 20, motif: [7]}],
        normal_recovery_sec: 15,
        sec_per_rep: 5.5,
        auto_resets: []
      },
      blocks: [],
      steps: []
    }

    outline = PlanPresentation.outline(plan)

    assert [%{title: title, rows: rows}] = outline.blocks
    assert title =~ "20"
    assert Enum.any?(rows, &(&1.recovery_label == "15s recovery"))
    assert List.last(rows).recovery_label == "No recovery"
  end
end
