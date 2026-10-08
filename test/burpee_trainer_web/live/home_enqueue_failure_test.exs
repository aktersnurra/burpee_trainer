defmodule BurpeeTrainerWeb.HomeEnqueueFailureTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import BurpeeTrainer.Fixtures
  import Phoenix.LiveViewTest
  alias BurpeeTrainer.Repo

  test "real current-clock boundary admission failure remains observable", %{conn: conn} do
    user = user_fixture()

    free_form_session_fixture(user, %{
      completed_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    })

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), "/")
    assert has_element?(view, "[data-home-state=start]")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER refuse_boundary_admission BEFORE INSERT ON oban_jobs BEGIN SELECT RAISE(ABORT, 'CHECK constraint failed: attempt_range'); END",
      []
    )

    send(view.pid, {:home_day_boundary, 1})
    assert has_element?(view, "#home-planning-error[role=status]")
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "real retry admission failure is visible and Home stays alive", %{conn: conn} do
    user = user_fixture()
    plan_fixture(user)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), "/")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER refuse_home_admission BEFORE INSERT ON oban_jobs BEGIN SELECT RAISE(ABORT, 'CHECK constraint failed: attempt_range'); END",
      []
    )

    render_hook(view, "retry_recommendation", %{})
    assert has_element?(view, "#home-planning-error[role=status]")
    assert Repo.aggregate(Oban.Job, :count) == 0
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER refuse_home_admission", [])
    render_hook(view, "retry_recommendation", %{})
    refute has_element?(view, "#home-planning-error")
    assert Repo.aggregate(Oban.Job, :count) == 1
  end
end
