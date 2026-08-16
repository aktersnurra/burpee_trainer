defmodule BurpeeTrainer.StreakTest do
  use BurpeeTrainer.DataCase, async: true

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Streak, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "computes weekly totals from reported sessions only" do
    user = user_fixture()
    plan = plan_fixture(user)
    today = ~D[2026-01-07]
    reported = free_form_session_fixture(user, %{"duration_sec_actual" => 3_600})

    Repo.update_all(
      from(s in WorkoutSession, where: s.id == ^reported.id),
      set: [inserted_at: ~U[2026-01-07 10:00:00Z]]
    )

    client_session_id = Ecto.UUID.generate()
    assert {:ok, lifecycle} = Workouts.begin_plan_session(user, plan, client_session_id)

    Repo.update_all(
      from(s in WorkoutSession, where: s.id == ^lifecycle.id),
      set: [duration_sec_actual: 1_800, inserted_at: ~U[2026-01-07 11:00:00Z]]
    )

    assert %Streak.State{current_week_minutes: 60.0} = Streak.compute(user, today)

    assert {:ok, _} = Workouts.mark_report_pending(user, client_session_id)
    assert %Streak.State{current_week_minutes: 60.0} = Streak.compute(user, today)

    assert {:ok, _} = Workouts.abort_session(user, client_session_id)
    assert %Streak.State{current_week_minutes: 60.0} = Streak.compute(user, today)
  end
end
