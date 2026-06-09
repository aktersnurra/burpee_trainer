defmodule BurpeeTrainer.PlanSolver.ApplyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{Apply, Input}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  defp even_input(n, dur_min) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: dur_min,
      burpee_count_target: n,
      pacing_style: :even,
      level: :level_1c
    }
  end

  defp unbroken_input(n, dur_min, rps) do
    %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: dur_min,
      burpee_count_target: n,
      pacing_style: :unbroken,
      level: :level_1c,
      reps_per_set: rps
    }
  end

  test ":even, no reservations — defaults to human-sized block runs" do
    input = even_input(10, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert %WorkoutPlan{} = plan
    assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
             [8],
             [2]
           ]

    assert Enum.map(plan.steps, &{&1.kind, &1.block_position, &1.repeat_count}) == [
             {:block_run, 1, 1},
             {:block_run, 2, 1}
           ]
  end

  test ":even — executable total duration matches target within 1s" do
    input = even_input(20, 10)
    target_sec = 600.0
    p = 6.0
    rest_budget = target_sec - 20 * p
    r = List.duplicate(rest_budget / 19, 19)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert_in_delta BurpeeTrainer.Planner.summary(plan).duration_sec_total, target_sec, 1.0
  end

  test ":even with preferred block pattern — reusable block-run step" do
    input = %{even_input(70, 20) | burpee_type: :navy_seal, block_pattern: [4, 3]}

    {:ok, plan} = Apply.to_workout_plan(input, 8.0, [70], [], [])

    [block] = plan.blocks
    assert Enum.map(block.sets, & &1.burpee_count) == [4, 3]
    assert [%{kind: :block_run, block_position: 1, repeat_count: 10}] = plan.steps
    assert BurpeeTrainer.Planner.summary(plan).burpee_count_total == 70
    assert round(BurpeeTrainer.Planner.summary(plan).duration_sec_total) == 1200
  end

  test ":even with preferred block pattern — automatic remainder block" do
    input = %{even_input(75, 20) | burpee_type: :navy_seal, block_pattern: [4, 3]}

    {:ok, plan} = Apply.to_workout_plan(input, 8.0, [75], [], [])

    assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
             [4, 3],
             [4, 1]
           ]

    assert Enum.map(plan.steps, &{&1.kind, &1.block_position, &1.repeat_count}) == [
             {:block_run, 1, 10},
             {:block_run, 2, 1}
           ]

    assert BurpeeTrainer.Planner.summary(plan).burpee_count_total == 75
  end

  test ":even with preferred block pattern and rest — split around first-class rest" do
    input = %Input{
      name: "Pattern rest",
      burpee_type: :navy_seal,
      level: :level_1a,
      target_duration_min: 20,
      burpee_count_target: 70,
      pacing_style: :even,
      reps_per_set: nil,
      block_pattern: [4, 3],
      additional_rests: [%{target_min: 12, rest_sec: 20}],
      sec_per_burpee_override: nil
    }

    {:ok, sol} = BurpeeTrainer.PlanSolver.solve(input)

    assert Enum.map(sol.plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
             [4, 3]
           ]

    assert Enum.map(sol.plan.steps, & &1.kind) == [:block_run, :rest, :block_run]

    assert [%{repeat_count: before_count}, %{rest_sec: 20}, %{repeat_count: after_count}] =
             sol.plan.steps

    assert before_count + after_count == 10
    assert BurpeeTrainer.Planner.summary(sol.plan).burpee_count_total == 70
    assert round(BurpeeTrainer.Planner.summary(sol.plan).duration_sec_total) == 1200
  end

  test ":even with one reservation — two blocks" do
    input = %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      pacing_style: :even,
      level: :level_1c,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    }

    p = 6.0
    r = List.duplicate(0.0, 9)
    reservations = [%{slot: 5, rest_sec: 60.0, target_min: 5}]

    {:ok, plan} = Apply.to_workout_plan(input, p, r, reservations)

    assert length(plan.blocks) == 2
    [b1, b2] = Enum.sort_by(plan.blocks, & &1.position)
    [s1] = b1.sets
    [s2] = b2.sets
    assert s1.burpee_count == 5
    assert s2.burpee_count == 5
    assert s1.end_of_set_rest == 0
    assert s2.end_of_set_rest == 0
    assert plan.additional_rests == ~s([{"rest_sec":60,"target_min":5}])
  end

  test ":unbroken with multiple reservations places rests against absolute timeline" do
    input = %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 200,
      pacing_style: :unbroken,
      level: :level_1c,
      reps_per_set: 5,
      additional_rests: [%{rest_sec: 10, target_min: 6}, %{rest_sec: 10, target_min: 12}]
    }

    p = 5.0
    r = List.duplicate(5.0, 39)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert Enum.map(plan.steps, & &1.kind) == [:block_run, :rest, :block_run, :rest, :block_run]
    assert Enum.map(plan.steps, & &1.repeat_count) == [12, nil, 12, nil, 16]
  end

  test ":unbroken with reservation keeps additional rest separate from set rest" do
    input = %Input{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 200,
      pacing_style: :unbroken,
      level: :level_1c,
      reps_per_set: 5,
      additional_rests: [%{rest_sec: 10, target_min: 18}]
    }

    p = 5.0
    r = List.duplicate(0.0, 199)
    reservations = [%{slot: 180, rest_sec: 10.0, target_min: 18}]

    {:ok, plan} = Apply.to_workout_plan(input, p, r, reservations)

    [block] = plan.blocks
    [set] = block.sets
    assert set.burpee_count == 5
    assert set.end_of_set_rest == 5
    assert plan.additional_rests == ~s([{"rest_sec":10,"target_min":18}])
    assert Enum.map(plan.steps, & &1.kind) == [:block_run, :rest, :block_run]
    assert Enum.map(plan.steps, & &1.repeat_count) == [36, nil, 4]
    assert Enum.at(plan.steps, 1).rest_sec == 10
  end

  test ":unbroken — reusable block definition plus block-run step" do
    input = unbroken_input(10, 5, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    [block] = plan.blocks
    [set] = block.sets
    assert set.burpee_count == 5
    assert_in_delta set.sec_per_burpee, p, 1.0e-6
    assert Enum.map(plan.steps, & &1.kind) == [:block_run]
    assert hd(plan.steps).repeat_count == 2
  end

  test "solved p is stored in plan.sec_per_burpee" do
    input = even_input(5, 5)
    p = 7.3
    r = List.duplicate(0.0, 4)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert_in_delta plan.sec_per_burpee, 7.3, 1.0e-6
  end
end
