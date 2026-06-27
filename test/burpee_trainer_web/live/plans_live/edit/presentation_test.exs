defmodule BurpeeTrainerWeb.PlansLive.Edit.PresentationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}
  alias BurpeeTrainerWeb.PlansLive.Edit.Presentation

  defp set(position, reps, sec_per_rep, rest) do
    %Set{
      position: position,
      burpee_count: reps,
      sec_per_rep: sec_per_rep,
      sec_per_burpee: sec_per_rep,
      end_of_set_rest: rest
    }
  end

  defp plan do
    %WorkoutPlan{
      name: "Contract plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 45,
      pacing_style: :unbroken,
      blocks: [
        %Block{position: 1, repeat_count: 3, sets: [set(1, 15, 3.8, 38)]}
      ]
    }
  end

  test "contract summarizes duration, type, reps, blocks, and feel" do
    contract = Presentation.contract(plan(), %{duration_sec: 1_200, burpee_count: 45})

    assert contract.title == "20:00 · Six-count"
    assert contract.stats == "45 reps · Unbroken sets · 3 blocks"
    assert contract.structure == "15 reps each · grouped sets"
    assert contract.feel == "Controlled, not all-out"
  end

  test "block rows group repeated blocks into readable rows" do
    rows = Presentation.block_rows(plan())

    assert length(rows) == 1
    assert Enum.at(rows, 0).title == "Blocks 1–3"
    assert Enum.at(rows, 0).headline == "15 reps each"
    assert Enum.at(rows, 0).detail == "Rep every 3.8s · 0:38 rest"
    assert Enum.at(rows, 0).source_block_index == 0
  end

  test "block rows display at most one decimal place" do
    plan = %WorkoutPlan{
      name: "Precise pace",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 9,
      pacing_style: :unbroken,
      blocks: [
        %Block{position: 1, repeat_count: 1, sets: [set(1, 9, 4.826388888888889, 25)]}
      ]
    }

    [row] = Presentation.block_rows(plan)

    assert row.detail =~ "Rep every 4.8s"
    refute row.detail =~ "4.826388888888889"
  end

  test "locked indexes are exposed as Locked by you" do
    [first | _] = Presentation.block_rows(plan(), MapSet.new([0]))

    assert first.locked? == true
    assert first.lock_label == "Locked by you"
  end

  test "contract includes explicit rest steps in structure rows" do
    plan = %WorkoutPlan{
      name: "Rest plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 30,
      pacing_style: :unbroken,
      blocks: [
        %Block{position: 1, repeat_count: 1, sets: [set(1, 10, 5.0, 0)]},
        %Block{position: 2, repeat_count: 1, sets: [set(1, 20, 5.0, 0)]}
      ],
      steps: [
        %PlanStep{position: 1, kind: :block_run, block_position: 1, repeat_count: 1},
        %PlanStep{position: 2, kind: :rest, rest_sec: 60},
        %PlanStep{position: 3, kind: :block_run, block_position: 2, repeat_count: 1}
      ]
    }

    contract = Presentation.contract(plan, %{duration_sec: 1_200, burpee_count: 30})

    assert Enum.map(contract.structure_rows, & &1.kind) == [:block, :rest, :block]
    assert Enum.at(contract.structure_rows, 1).headline == "1:00 recovery"
  end

  test "structure map marks expose height, gap, and label" do
    rows = Presentation.block_rows(plan())
    marks = Presentation.structure_map(rows)

    assert length(marks) == 1
    assert hd(marks).label == "Blocks 1–3 · 15 reps"
    assert is_integer(hd(marks).height)
    assert is_integer(hd(marks).gap)
  end

  test "structure groups compact adjacent similar block rows" do
    rows = Presentation.block_rows(plan())

    assert [%{range: "1", label: "15 reps each · 0:38 rest"}] =
             Presentation.structure_groups(rows)
  end

  test "plan feedback separates too-long duration conflicts" do
    feedback =
      Presentation.plan_feedback(
        nil,
        %{
          both_ok: false,
          duration_ok: false,
          reps_ok: true,
          duration_sec: 1_242,
          burpee_count: 100
        },
        %{target_duration_min: 20, burpee_count_target: 100}
      )

    assert feedback.title == "Workout no longer fits 20:00"
    assert feedback.message == "You are 0:42 over."
  end

  test "plan feedback separates too-short duration conflicts" do
    feedback =
      Presentation.plan_feedback(
        nil,
        %{
          both_ok: false,
          duration_ok: false,
          reps_ok: true,
          duration_sec: 1_192,
          burpee_count: 100
        },
        %{target_duration_min: 20, burpee_count_target: 100}
      )

    assert feedback.title == "Workout ends before 20:00"
    assert feedback.message == "You have 0:08 unused."
    assert "Add rest at end" in feedback.actions
  end

  test "plan feedback separates reps mismatch conflicts" do
    feedback =
      Presentation.plan_feedback(
        nil,
        %{
          both_ok: false,
          duration_ok: true,
          reps_ok: false,
          duration_sec: 1_200,
          burpee_count: 200
        },
        %{target_duration_min: 20, burpee_count_target: 100}
      )

    assert feedback.title == "Reps do not match target"
    assert feedback.message == "Planned: 200\nTarget: 100"
    assert "Update target to 200" in feedback.actions
  end

  test "plan feedback accepts real derived count_ok key for reps mismatch conflicts" do
    feedback =
      Presentation.plan_feedback(
        nil,
        %{
          both_ok: false,
          duration_ok: true,
          count_ok: false,
          duration_sec: 1_200,
          burpee_count: 200
        },
        %{target_duration_min: 20, burpee_count_target: 100}
      )

    assert feedback.title == "Reps do not match target"
    assert feedback.message == "Planned: 200\nTarget: 100"
  end
end
