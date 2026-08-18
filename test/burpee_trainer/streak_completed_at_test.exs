defmodule BurpeeTrainer.StreakCompletedAtTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{Repo, Streak}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "classifies completed sessions by completed_at in the user timezone" do
    user = user_fixture() |> provision_timezone("America/Los_Angeles")

    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: 4_800,
      completed_at: ~U[2025-09-01 06:30:00Z],
      capture_mode: :logged
    })

    state = Streak.compute(user, ~D[2025-09-01])

    assert state.current_week_minutes == 0
    assert state.streak_weeks == 1
  end

  defp provision_timezone(user, timezone) do
    Repo.update_all(from(u in BurpeeTrainer.Accounts.User, where: u.id == ^user.id),
      set: [timezone: timezone, timezone_provisioned: true]
    )

    Repo.get!(BurpeeTrainer.Accounts.User, user.id)
  end
end
