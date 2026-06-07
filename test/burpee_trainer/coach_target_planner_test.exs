defmodule BurpeeTrainer.CoachTargetPlannerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.{
    CoachTargetPlanner,
    PerformanceGoal,
    PerformanceModel,
    WeeklyTrainingContract
  }

  alias BurpeeTrainer.CoachTargetPlanner.{Input, NoActiveGoal}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "generates type-specific 20 minute suggestions without days or time of day" do
    history = [session(:six_count, 104, 20, ~U[2026-06-01 10:00:00Z])]
    training_state = PerformanceModel.build_training_state(history)
    weekly_status = WeeklyTrainingContract.status([], ~D[2026-06-01])

    input = %Input{
      goal: %PerformanceGoal{
        burpee_type: :six_count,
        target_reps: 160,
        target_duration_min: 20,
        target_date: ~D[2026-07-20]
      },
      history: history,
      training_state: training_state,
      weekly_status: weekly_status,
      burpee_type: :six_count,
      target_duration_min: 20,
      today: ~D[2026-06-01]
    }

    assert {:ok, suggestions} = CoachTargetPlanner.suggest_targets(input)
    assert Enum.any?(suggestions, &(&1.kind == :on_track))
    assert Enum.any?(suggestions, &(&1.kind == :recommended))
    assert Enum.all?(suggestions, &(&1.burpee_type == :six_count))
    assert Enum.all?(suggestions, &(&1.target_duration_min == 20))
    refute Enum.any?(suggestions, &Map.has_key?(&1, :day))
    refute Enum.any?(suggestions, &Map.has_key?(&1, :time_of_day_bucket))
  end

  test "preserves aggressive on-track target while clamping recommended target" do
    history = [session(:six_count, 100, 20, ~U[2026-06-01 10:00:00Z])]
    training_state = PerformanceModel.build_training_state(history)

    input = %Input{
      goal: %PerformanceGoal{
        burpee_type: :six_count,
        target_reps: 200,
        target_duration_min: 20,
        target_date: ~D[2026-06-15]
      },
      history: history,
      training_state: training_state,
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      burpee_type: :six_count,
      target_duration_min: 20,
      today: ~D[2026-06-01]
    }

    assert {:ok, suggestions} = CoachTargetPlanner.suggest_targets(input)
    on_track = Enum.find(suggestions, &(&1.kind == :on_track))
    recommended = Enum.find(suggestions, &(&1.kind == :recommended))

    assert on_track.burpee_count_target > recommended.burpee_count_target
    assert on_track.risk == :high
    assert recommended.risk in [:low, :normal]
  end

  test "safe progress does not exceed recommended when already ahead of goal" do
    history = [session(:six_count, 220, 20, ~U[2026-06-01 10:00:00Z])]
    training_state = PerformanceModel.build_training_state(history)

    input = %Input{
      goal: %PerformanceGoal{
        burpee_type: :six_count,
        target_reps: 200,
        target_duration_min: 20,
        target_date: ~D[2026-07-20]
      },
      history: history,
      training_state: training_state,
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      burpee_type: :six_count,
      target_duration_min: 20,
      today: ~D[2026-06-01]
    }

    assert {:ok, suggestions} = CoachTargetPlanner.suggest_targets(input)
    recommended = Enum.find(suggestions, &(&1.kind == :recommended))
    safe = Enum.find(suggestions, &(&1.kind == :safe_progress))

    assert safe.burpee_count_target <= recommended.burpee_count_target
  end

  test "uses goal baseline when there is no matching history" do
    input = %Input{
      goal: %PerformanceGoal{
        burpee_type: :navy_seal,
        start_reps: 40,
        target_reps: 80,
        target_duration_min: 20,
        target_date: ~D[2026-07-20]
      },
      history: [],
      training_state: PerformanceModel.build_training_state([]),
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      burpee_type: :navy_seal,
      target_duration_min: 20,
      today: ~D[2026-06-01]
    }

    assert {:ok, suggestions} = CoachTargetPlanner.suggest_targets(input)
    recommended = Enum.find(suggestions, &(&1.kind == :recommended))

    assert recommended.current_estimate_reps == 40
    assert recommended.burpee_count_target > 1
  end

  test "returns structured error when the selected type has no active goal" do
    input = %Input{
      goal: nil,
      history: [],
      training_state: PerformanceModel.build_training_state([]),
      weekly_status: WeeklyTrainingContract.status([], ~D[2026-06-01]),
      burpee_type: :navy_seal,
      target_duration_min: 20,
      today: ~D[2026-06-01]
    }

    assert {:error, %NoActiveGoal{burpee_type: :navy_seal}} =
             CoachTargetPlanner.suggest_targets(input)
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
