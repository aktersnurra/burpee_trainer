defmodule BurpeeTrainer.Workouts.WorkoutSessionTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.WorkoutSession

  test "completion transition changes only outcome and feedback fields" do
    session = %WorkoutSession{
      state: :started,
      source_kind: :plan,
      plan_id: 2,
      display_name_snapshot: "Intervals",
      workout_type_snapshot: :six_count,
      program_snapshot: %{"events" => []},
      content_hash: String.duplicate("b", 64),
      client_session_id: Ecto.UUID.generate(),
      started_at: ~U[2026-08-27 10:00:00Z],
      burpee_type: :six_count,
      burpee_count_planned: 20,
      duration_sec_planned: 1_200
    }

    changeset =
      WorkoutSession.completion_changeset(
        session,
        %{
          "burpee_count_actual" => 18,
          "duration_sec_actual" => 1_180,
          "preference_feedback" => "choose_again",
          "display_name_snapshot" => "forged",
          "program_snapshot" => %{"forged" => true}
        },
        ~U[2026-08-27 10:20:00Z]
      )

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :state) == :completed
    assert Ecto.Changeset.get_change(changeset, :burpee_count_actual) == 18
    assert Ecto.Changeset.get_change(changeset, :preference_feedback) == :choose_again
    refute Ecto.Changeset.get_change(changeset, :display_name_snapshot)
    refute Ecto.Changeset.get_change(changeset, :program_snapshot)
  end
end
