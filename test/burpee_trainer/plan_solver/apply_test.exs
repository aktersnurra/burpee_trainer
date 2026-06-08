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

  test ":even, no reservations — one block, one set, all reps" do
    input = even_input(10, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert %WorkoutPlan{} = plan
    assert length(plan.blocks) == 1
    [block] = plan.blocks
    assert length(block.sets) == 1
    [set] = block.sets
    assert set.burpee_count == 10
    assert_in_delta set.sec_per_burpee, 6.0, 1.0e-6
  end

  test ":even — total duration matches target within 1s" do
    input = even_input(20, 10)
    target_sec = 600.0
    p = 6.0
    rest_budget = target_sec - 20 * p
    r = List.duplicate(rest_budget / 19, 19)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    sets = Enum.flat_map(plan.blocks, & &1.sets)

    duration =
      Enum.reduce(sets, 0.0, fn s, acc ->
        acc + s.burpee_count * s.sec_per_rep + s.end_of_set_rest
      end)

    assert_in_delta duration, target_sec, 1.0
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

    sets = List.first(plan.blocks).sets
    assert Enum.max_by(sets, & &1.end_of_set_rest).end_of_set_rest == 5
    assert plan.additional_rests == ~s([{"rest_sec":10,"target_min":18}])
  end

  test ":unbroken — correct set count" do
    input = unbroken_input(10, 5, 5)
    p = 6.0
    r = List.duplicate(0.0, 9)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    sets = List.first(plan.blocks).sets
    assert length(sets) == 2
    Enum.each(sets, &assert_in_delta(&1.sec_per_burpee, p, 1.0e-6))
  end

  test "solved p is stored in plan.sec_per_burpee" do
    input = even_input(5, 5)
    p = 7.3
    r = List.duplicate(0.0, 4)

    {:ok, plan} = Apply.to_workout_plan(input, p, r, [])

    assert_in_delta plan.sec_per_burpee, 7.3, 1.0e-6
  end
end
