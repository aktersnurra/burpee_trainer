defmodule BurpeeTrainerWeb.SessionAnalysisLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Repo, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "redirects away from a tracked session that is not reported", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    assert {:ok, session} =
             Workouts.create_tracked_session_from_plan(user, plan, %{
               "burpee_count_actual" => 3,
               "duration_sec_actual" => 15,
               "cadence_ms" => [5_000, 10_000, 15_000],
               "target_pace_sec" => 5.0
             })

    Repo.update_all(
      from(s in WorkoutSession, where: s.id == ^session.id),
      set: [status: :running]
    )

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/stats/sessions/#{session.id}")
  end

  test "renders analysis for a reported tracked session", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    assert {:ok, session} =
             Workouts.create_tracked_session_from_plan(user, plan, %{
               "burpee_count_actual" => 3,
               "duration_sec_actual" => 15,
               "cadence_ms" => [5_000, 10_000, 15_000],
               "target_pace_sec" => 5.0
             })

    assert {:ok, view, _html} = live(conn, ~p"/stats/sessions/#{session.id}")
    assert has_element?(view, ".session-surface")
  end
end
