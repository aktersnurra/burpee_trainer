defmodule BurpeeTrainerWeb.SessionAnalysisLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders tracked pace analytics", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    {:ok, session} =
      Workouts.create_tracked_session_from_plan(user, plan, %{
        "burpee_type" => "six_count",
        "burpee_count_planned" => "4",
        "duration_sec_planned" => "24",
        "burpee_count_actual" => "4",
        "duration_sec_actual" => "24",
        "target_pace_sec" => "6.0",
        "cadence_ms" => [4000, 9000, 15000, 22000]
      })

    {:ok, _view, html} = live(conn, ~p"/stats/sessions/#{session.id}")

    assert html =~ "Session analysis"
    assert html =~ "Pace by rep"
    assert html =~ "5.0s"
    assert html =~ "6.0s"
    assert html =~ "7.0s"
    assert html =~ "Best window"
    assert html =~ "Pace drift"
  end

  test "untracked session redirects to stats", %{conn: conn, user: user} do
    plan = plan_fixture(user)
    session = session_from_plan_fixture(user, plan)

    assert {:error, {:live_redirect, %{to: "/stats"}}} =
             live(conn, ~p"/stats/sessions/#{session.id}")
  end
end
