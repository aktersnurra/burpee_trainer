defmodule BurpeeTrainer.Workouts.WorkoutSessionTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.DataCase, only: [errors_on: 1]

  alias BurpeeTrainer.Workouts.WorkoutSession

  test "final schema has no authorization or persisted execution-program shims" do
    session = %WorkoutSession{}

    refute Map.has_key?(session, :execution_program_id)
    refute Map.has_key?(session, :prepared_workout_id)
  end

  test "start changeset accepts a fully snapshotted plan identity" do
    changeset =
      WorkoutSession.start_changeset(%WorkoutSession{
        user_id: 1,
        state: :started,
        source_kind: :plan,
        plan_id: 2,
        display_name_snapshot: "Intervals",
        workout_type_snapshot: :six_count,
        program_snapshot: %{"events" => []},
        content_hash: String.duplicate("a", 64),
        client_session_id: Ecto.UUID.generate(),
        started_at: ~U[2026-08-27 10:00:00Z],
        burpee_type: :six_count,
        burpee_count_planned: 20,
        duration_sec_planned: 1_200
      })

    assert changeset.valid?
  end

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

  test "typed feedback rejects mutually exclusive energy context" do
    changeset =
      WorkoutSession.free_form_changeset(%WorkoutSession{}, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 20,
        "duration_sec_actual" => 600,
        "completed_at" => DateTime.add(DateTime.utc_now(), -60, :second),
        "context_low_energy" => true,
        "context_high_energy" => true
      })

    refute changeset.valid?

    assert errors_on(changeset).context_high_energy == [
             "cannot be true when low energy is also true"
           ]
  end

  test "manual history rejects a future completion" do
    changeset =
      WorkoutSession.free_form_changeset(%WorkoutSession{}, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 20,
        "duration_sec_actual" => 600,
        "completed_at" => DateTime.add(DateTime.utc_now(), 60, :second)
      })

    refute changeset.valid?
    assert errors_on(changeset).completed_at == ["cannot be in the future"]
  end
end
