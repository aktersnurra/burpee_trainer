defmodule BurpeeTrainer.Planning.CompilerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{Compiler, DraftGenerator, Goal, TimelineItem}
  alias BurpeeTrainer.Workouts.{PlanStep, WorkoutPlan}

  test "compiles even units into an executable workout plan" do
    {:ok,
     goal = %Goal{
       duration_sec: 1200,
       target_reps: 150,
       burpee_type: :six_count,
       style: :even
     }}

    {:ok, draft} = DraftGenerator.generate(goal)

    assert {:ok, %WorkoutPlan{} = plan} = Compiler.to_workout_plan(draft, name: "150 in 20")

    assert plan.name == "150 in 20"
    assert plan.burpee_type == :six_count
    assert plan.burpee_count_target == 150
    assert plan.target_duration_min == 20
    assert length(plan.blocks) == 10
    assert Enum.all?(plan.blocks, &(length(&1.sets) == 1))
    assert Enum.sum(for block <- plan.blocks, set <- block.sets, do: set.burpee_count) == 150

    assert Enum.map(plan.steps, &{&1.kind, &1.block_position}) ==
             Enum.map(1..10, fn position -> {:block_run, position} end)
  end

  test "compiles meaningful pattern blocks with preserved repeat counts" do
    draft = %BurpeeTrainer.Planning.Draft{
      goal: %Goal{
        duration_sec: 120,
        target_reps: 18,
        burpee_type: :six_count,
        style: :custom
      },
      status: :verified,
      timeline: [
        %TimelineItem.MeaningfulPattern{
          id: "pattern-1",
          start_sec: 0,
          repeat_count: 3,
          pattern: [4, 2]
        }
      ],
      metadata: %{}
    }

    assert {:ok, %WorkoutPlan{} = plan} = Compiler.to_workout_plan(draft, name: "pattern")

    assert [%{repeat_count: 3, sets: sets}] = plan.blocks
    assert Enum.map(sets, &{&1.position, &1.burpee_count}) == [{1, 4}, {2, 2}]
    assert [%PlanStep{kind: :block_run, repeat_count: 3, block_position: 1}] = plan.steps
  end

  test "compiles standalone rest into a rest plan step without shifting block positions" do
    {:ok,
     goal = %Goal{
       duration_sec: 1200,
       target_reps: 160,
       burpee_type: :six_count,
       style: :even,
       requested_rest: %{target_sec: 720, duration_sec: 45}
     }}

    {:ok, draft} = DraftGenerator.generate(goal)

    assert {:ok, %WorkoutPlan{} = plan} = Compiler.to_workout_plan(draft, name: "160 with reset")

    assert Enum.any?(plan.steps, &match?(%PlanStep{kind: :rest, rest_sec: 45}, &1))

    assert Enum.map(plan.steps, &{&1.kind, &1.block_position}) == [
             {:block_run, 1},
             {:block_run, 2},
             {:block_run, 3},
             {:block_run, 4},
             {:block_run, 5},
             {:block_run, 6},
             {:rest, nil},
             {:block_run, 7},
             {:block_run, 8},
             {:block_run, 9},
             {:block_run, 10}
           ]
  end
end
