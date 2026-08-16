defmodule BurpeeTrainer.WorkoutFeedTest do
  use BurpeeTrainer.DataCase, async: true

  import Ecto.Query
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, WorkoutFeed, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  test "uses only reported sessions for a plan's last-used time" do
    user = user_fixture()
    plan = plan_fixture(user)
    reported = session_from_plan_fixture(user, plan)
    reported_at = ~U[2026-01-01 10:00:00Z]

    Repo.update_all(
      from(s in WorkoutSession, where: s.id == ^reported.id),
      set: [inserted_at: reported_at]
    )

    client_session_id = Ecto.UUID.generate()
    assert {:ok, lifecycle} = Workouts.begin_plan_session(user, plan, client_session_id)

    Repo.update_all(
      from(s in WorkoutSession, where: s.id == ^lifecycle.id),
      set: [inserted_at: ~U[2026-01-02 10:00:00Z]]
    )

    assert [item] = WorkoutFeed.list(user, %{source: :mine})
    assert item.id == plan.id
    assert item.last_used_at == reported_at

    assert {:ok, _} = Workouts.mark_report_pending(user, client_session_id)
    assert [item] = WorkoutFeed.list(user, %{source: :mine})
    assert item.last_used_at == reported_at

    assert {:ok, _} = Workouts.abort_session(user, client_session_id)
    assert [item] = WorkoutFeed.list(user, %{source: :mine})
    assert item.last_used_at == reported_at
  end
end
