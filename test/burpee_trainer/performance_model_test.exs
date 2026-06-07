defmodule BurpeeTrainer.PerformanceModelTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PerformanceModel
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "capacity is type-specific and does not mix six-count with Navy SEAL" do
    history = [
      session(:six_count, 100, 20, ~U[2026-06-01 10:00:00Z]),
      session(:six_count, 110, 20, ~U[2026-06-03 10:00:00Z]),
      session(:navy_seal, 40, 20, ~U[2026-06-04 10:00:00Z])
    ]

    six = PerformanceModel.current_capacity(history, :six_count, 20)
    navy = PerformanceModel.current_capacity(history, :navy_seal, 20)

    assert six.burpee_type == :six_count
    assert navy.burpee_type == :navy_seal
    assert six.estimated_reps > navy.estimated_reps
    assert navy.recent_best_reps == 40
  end

  test "warmup sessions do not affect capacity" do
    history = [
      session(:six_count, 200, 20, ~U[2026-06-01 10:00:00Z], tags: "warmup"),
      session(:six_count, 100, 20, ~U[2026-06-02 10:00:00Z])
    ]

    capacity = PerformanceModel.current_capacity(history, :six_count, 20)

    assert capacity.recent_best_reps == 100
    assert capacity.estimated_reps <= 100
  end

  test "manual 40 minute sessions are not blindly treated as 20 minute capacity" do
    history = [
      session(:six_count, 200, 40, ~U[2026-06-01 10:00:00Z]),
      session(:six_count, 100, 20, ~U[2026-06-02 10:00:00Z])
    ]

    capacity = PerformanceModel.current_capacity(history, :six_count, 20)

    assert capacity.recent_best_reps == 100
    assert capacity.estimated_reps <= 100
  end

  test "build_training_state returns separate level and capacity per type" do
    history = [
      session(:six_count, 110, 20, ~U[2026-06-01 10:00:00Z]),
      session(:navy_seal, 42, 20, ~U[2026-06-02 10:00:00Z])
    ]

    state = PerformanceModel.build_training_state(history)

    assert Map.has_key?(state.level_by_type, :six_count)
    assert Map.has_key?(state.level_by_type, :navy_seal)
    assert state.current_capacity_by_type.six_count.burpee_type == :six_count
    assert state.current_capacity_by_type.navy_seal.burpee_type == :navy_seal
    assert is_float(state.confidence)
  end

  defp session(type, reps, duration_min, inserted_at, attrs \\ []) do
    struct!(
      WorkoutSession,
      Keyword.merge(
        [
          burpee_type: type,
          burpee_count_actual: reps,
          duration_sec_actual: duration_min * 60,
          inserted_at: inserted_at
        ],
        attrs
      )
    )
  end
end
