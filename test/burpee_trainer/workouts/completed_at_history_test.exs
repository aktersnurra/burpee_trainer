defmodule BurpeeTrainer.Workouts.CompletedAtHistoryTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "weekly history uses completed_at in the user timezone, not insertion metadata" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")

    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: 1_200,
      completed_at: ~U[2025-09-01 06:30:00Z],
      capture_mode: :logged
    })

    assert [%{week_start: ~D[2025-08-25], minutes: 20.0}] = Workouts.weekly_minutes(user)
  end

  defp provision_timezone(user, timezone) do
    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user.id),
      set: [timezone: timezone, timezone_provisioned: true]
    )

    Repo.get!(BurpeeTrainer.Accounts.User, user.id)
  end
end
