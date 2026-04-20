defmodule BurpeeTrainerWeb.GoalsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Goals

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "shows set-a-goal prompts when no active goals", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/goals")

    assert html =~ "No active goal for 6-count"
    assert html =~ "No active goal for Navy SEAL"
    assert html =~ "Set a goal"
  end

  test "active goal renders recommendation and progress bar", %{conn: conn, user: user} do
    _ = goal_fixture(user, %{"burpee_type" => "six_count"})

    {:ok, _view, html} = live(conn, ~p"/goals")

    assert html =~ "Next session"
    assert html =~ "Build plan"
    assert html =~ "Log session"
    assert html =~ "Baseline: 50"
    assert html =~ "Target: 70"
    assert html =~ "weeks remaining"
  end

  test "start_goal opens form and save creates a goal", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/goals")

    view
    |> element("button[phx-click='start_goal'][phx-value-type='six_count']")
    |> render_click()

    assert has_element?(view, "form#goal-form-six_count")

    today = Date.utc_today()

    params = %{
      "burpee_type" => "six_count",
      "burpee_count_target" => "80",
      "duration_sec_target" => "360",
      "date_target" => Date.to_iso8601(Date.add(today, 28)),
      "burpee_count_baseline" => "40",
      "duration_sec_baseline" => "200",
      "date_baseline" => Date.to_iso8601(today)
    }

    html =
      view
      |> form("#goal-form-six_count", goal: params)
      |> render_submit()

    assert html =~ "Goal created."
    assert html =~ "Baseline: 40"
    assert html =~ "Target: 80"

    assert [%{burpee_count_target: 80}] = Goals.list_active_goals(user)
  end

  test "abandon moves goal to past goals section", %{conn: conn, user: user} do
    goal = goal_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/goals")

    html =
      view
      |> element("button[phx-click='abandon'][phx-value-id='#{goal.id}']")
      |> render_click()

    assert html =~ "Goal abandoned."
    assert html =~ "Past goals"
    assert html =~ "Abandoned"
    assert html =~ "No active goal for 6-count"
  end

  test "mark_achieved moves goal to past goals section", %{conn: conn, user: user} do
    goal = goal_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/goals")

    html =
      view
      |> element("button[phx-click='mark_achieved'][phx-value-id='#{goal.id}']")
      |> render_click()

    assert html =~ "Goal marked achieved."
    assert html =~ "Past goals"
    assert html =~ "Achieved"
  end
end
