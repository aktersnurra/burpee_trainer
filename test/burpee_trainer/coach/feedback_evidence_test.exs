defmodule BurpeeTrainer.Coach.FeedbackEvidenceTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.{Repo, Workouts.WorkoutSession}

  test "completed immutable plan snapshots contribute typed feedback at completed_at" do
    user = provisioned_user()
    completed_at = ~U[2025-09-01 12:00:00Z]

    session =
      completed_session(user, completed_at,
        context_low_energy: true,
        context_heat_affected: true,
        primary_limiter: :breathing,
        preference_feedback: :choose_again
      )

    assert session.state == :completed
    assert session.completed_at == completed_at
    assert session.display_name_snapshot == "Snapshot workout"
    assert session.program_snapshot == program_snapshot()

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-02 12:00:00Z])
    assert slot.completed_sec == 1_200
    assert slot.feedback.transient == [:heat_affected_performance, :low_energy]
    assert slot.feedback.limiters == [:breathing]
    assert slot.feedback.preferences == [:choose_again]
  end

  test "feedback evidence is ordered by completed_at and limited to three completions" do
    user = provisioned_user()

    completed_session(user, ~U[2025-08-20 12:00:00Z],
      primary_limiter: :legs,
      preference_feedback: :avoid
    )

    completed_session(user, ~U[2025-08-30 12:00:00Z], context_high_energy: true)
    completed_session(user, ~U[2025-08-31 12:00:00Z], primary_limiter: :upper_body)
    completed_session(user, ~U[2025-09-01 12:00:00Z], preference_feedback: :choose_again)

    assert {:ok, slot} = Policy.required_slot(user, ~U[2025-09-02 12:00:00Z])
    assert slot.feedback.transient == [:high_energy]
    assert slot.feedback.limiters == [:upper_body]
    assert slot.feedback.preferences == [:choose_again]
    refute :legs in slot.feedback.limiters
    refute :avoid in slot.feedback.preferences
  end

  defp completed_session(user, completed_at, feedback) do
    attrs = Map.new(feedback)

    %WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :plan,
      display_name_snapshot: "Snapshot workout",
      workout_type_snapshot: :six_count,
      program_snapshot: program_snapshot(),
      content_hash: String.duplicate("a", 64),
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: 1_200,
      completed_at: completed_at,
      capture_mode: :logged,
      context_low_energy: Map.get(attrs, :context_low_energy, false),
      context_high_energy: Map.get(attrs, :context_high_energy, false),
      context_heat_affected: Map.get(attrs, :context_heat_affected, false),
      primary_limiter: Map.get(attrs, :primary_limiter),
      preference_feedback: Map.get(attrs, :preference_feedback)
    }
    |> Repo.insert!()
  end

  defp program_snapshot do
    %{
      "burpee_type" => "six_count",
      "events" => [
        %{
          "kind" => "work",
          "reps" => 20,
          "sec_per_rep_us" => 60_000_000,
          "sec_per_burpee_us" => 60_000_000
        }
      ],
      "semantics" => %{"pacing_style" => "even"}
    }
  end

  defp provisioned_user do
    user = user_fixture()

    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user.id),
      set: [timezone: "Etc/UTC", timezone_provisioned: true]
    )

    Repo.get!(BurpeeTrainer.Accounts.User, user.id)
  end
end
