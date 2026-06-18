defmodule BurpeeTrainer.CatchUpPlannerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.{CatchUpPlanner, PerformanceGoal, PerformanceModel, WeeklyTrainingContract}
  alias BurpeeTrainer.CatchUpPlanner.{Input, Plan}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "requires a selected burpee type and never emits mixed-type plans" do
    history = [session(:navy_seal, 42, 20, ~U[2026-06-01 10:00:00Z])]
    training_state = PerformanceModel.build_training_state(history)
    weekly_status = WeeklyTrainingContract.status([], ~D[2026-06-01])
    remaining_slots = WeeklyTrainingContract.remaining_slots([], ~D[2026-06-01])

    input = %Input{
      weekly_status: weekly_status,
      remaining_slots: remaining_slots,
      selected_burpee_type: :navy_seal,
      performance_goal: %PerformanceGoal{
        burpee_type: :navy_seal,
        target_reps: 80,
        target_duration_min: 20
      },
      training_state: training_state,
      history: history,
      duration_min: 40,
      today: ~D[2026-06-02]
    }

    assert {:ok, %Plan{} = plan} = CatchUpPlanner.plan(input)
    assert plan.selected_burpee_type == :navy_seal
    assert plan.total_duration_min == 40
    assert length(plan.selected_sessions) == 2
    assert Enum.all?(plan.selected_sessions, &(&1.duration_min == 20))
    assert Enum.all?(plan.selected_sessions, &(&1.burpee_type == :navy_seal))
    refute Enum.any?(plan.selected_sessions, &(&1.burpee_type == :mixed))
  end

  test "labels selected-type catch-up as non-standard when it does not preserve remaining canonical slots" do
    week_start = ~D[2026-06-01]

    completed = [
      session(:six_count, 100, 20, ~U[2026-06-01 10:00:00Z]),
      session(:navy_seal, 42, 20, ~U[2026-06-02 10:00:00Z])
    ]

    input = %Input{
      weekly_status: WeeklyTrainingContract.status(completed, week_start),
      remaining_slots: WeeklyTrainingContract.remaining_slots(completed, week_start),
      selected_burpee_type: :navy_seal,
      performance_goal: %PerformanceGoal{
        burpee_type: :navy_seal,
        target_reps: 80,
        target_duration_min: 20
      },
      training_state: PerformanceModel.build_training_state(completed),
      history: completed,
      duration_min: 40,
      today: ~D[2026-06-03]
    }

    assert {:ok, plan} = CatchUpPlanner.plan(input)
    assert plan.weekly_split_effect == :counts_but_non_standard
    refute plan.canonical?

    assert "This completes your 80 min week, but does not preserve the normal 2+2 split." in plan.rationale
  end

  test "splits 40 minute catch-up into two standard sessions" do
    week_start = ~D[2026-06-01]
    history = [session(:six_count, 150, 20, ~U[2026-06-01 10:00:00Z])]

    input = %Input{
      weekly_status: WeeklyTrainingContract.status(history, week_start),
      remaining_slots: WeeklyTrainingContract.remaining_slots(history, week_start),
      selected_burpee_type: :six_count,
      performance_goal: %PerformanceGoal{
        burpee_type: :six_count,
        target_reps: 200,
        target_duration_min: 20
      },
      training_state: PerformanceModel.build_training_state(history),
      history: history,
      duration_min: 40,
      today: ~D[2026-06-03]
    }

    assert {:ok, plan} = CatchUpPlanner.plan(input)
    assert length(plan.selected_sessions) == 2
    assert Enum.map(plan.selected_sessions, & &1.duration_min) == [20, 20]
    assert Enum.map(plan.selected_sessions, & &1.target_reps) == [113, 113]
    assert Enum.all?(plan.selected_sessions, &(&1.suggestion_kind == :maintenance))
  end

  test "uses duration-specific intensity factors for long manual sessions" do
    week_start = ~D[2026-06-01]
    history = [session(:six_count, 150, 20, ~U[2026-06-01 10:00:00Z])]

    for {duration_min, expected_reps} <- [{30, 191}, {40, 225}, {60, 270}, {80, 300}] do
      input = %Input{
        weekly_status: WeeklyTrainingContract.status(history, week_start),
        remaining_slots: WeeklyTrainingContract.remaining_slots(history, week_start),
        selected_burpee_type: :six_count,
        performance_goal: %PerformanceGoal{
          burpee_type: :six_count,
          target_reps: 200,
          target_duration_min: 20
        },
        training_state: PerformanceModel.build_training_state(history),
        history: history,
        duration_min: duration_min,
        today: ~D[2026-06-03]
      }

      assert {:ok, plan} = CatchUpPlanner.plan(input)

      expected_sessions =
        case duration_min do
          30 -> [%{duration_min: 30, target_reps: expected_reps}]
          40 -> [%{duration_min: 20, target_reps: 113}, %{duration_min: 20, target_reps: 113}]
          60 -> List.duplicate(%{duration_min: 20, target_reps: 90}, 3)
          80 -> List.duplicate(%{duration_min: 20, target_reps: 75}, 4)
        end

      assert expected_sessions ==
               Enum.map(plan.selected_sessions, fn session ->
                 %{duration_min: session.duration_min, target_reps: session.target_reps}
               end)
    end
  end

  test "derates split 40 minute catch-up targets instead of repeating 20 minute max efforts" do
    week_start = ~D[2026-06-01]
    history = [session(:six_count, 150, 20, ~U[2026-06-01 10:00:00Z])]

    input = %Input{
      weekly_status: WeeklyTrainingContract.status(history, week_start),
      remaining_slots: WeeklyTrainingContract.remaining_slots(history, week_start),
      selected_burpee_type: :six_count,
      performance_goal: %PerformanceGoal{
        burpee_type: :six_count,
        target_reps: 200,
        target_duration_min: 20
      },
      training_state: PerformanceModel.build_training_state(history),
      history: history,
      duration_min: 40,
      today: ~D[2026-06-03]
    }

    assert {:ok, plan} = CatchUpPlanner.plan(input)

    assert [
             %{duration_min: 20, target_reps: 113, suggestion_kind: :maintenance},
             %{duration_min: 20, target_reps: 113, suggestion_kind: :maintenance}
           ] = plan.selected_sessions
  end

  test "returns structured error when no performance goal exists" do
    input = %Input{
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      remaining_slots: WeeklyTrainingContract.remaining_slots([], ~D[2026-06-01]),
      selected_burpee_type: :six_count,
      performance_goal: nil,
      training_state: PerformanceModel.build_training_state([]),
      history: [],
      duration_min: 40,
      today: ~D[2026-06-03]
    }

    assert {:error, %{reason: :performance_goal_required, burpee_type: :six_count}} =
             CatchUpPlanner.plan(input)
  end

  test "returns structured error when selected_burpee_type is missing" do
    input = %Input{
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      remaining_slots: WeeklyTrainingContract.remaining_slots([], ~D[2026-06-01]),
      selected_burpee_type: nil,
      performance_goal: nil,
      training_state: PerformanceModel.build_training_state([]),
      history: [],
      duration_min: 40,
      today: ~D[2026-06-03]
    }

    assert {:error, %{reason: :selected_burpee_type_required}} = CatchUpPlanner.plan(input)
  end

  defp session(type, reps, duration_min, inserted_at) do
    %WorkoutSession{
      burpee_type: type,
      burpee_count_actual: reps,
      duration_sec_actual: duration_min * 60,
      inserted_at: inserted_at
    }
  end
end
