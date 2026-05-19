defmodule BurpeeTrainerWeb.StatsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Goals

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/stats" do
    test "renders streak card with zero state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "THIS WEEK"
      assert html =~ "/ 80 min"
      assert html =~ "No active streak"
    end

    test "renders two goal slots always", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "6-COUNT"
      assert html =~ "NAVY SEAL"
    end

    test "empty goal slot shows Set goal link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "Set goal"
    end

    test "active goal slot shows burpee target", %{conn: conn, user: user} do
      today = Date.utc_today()

      {:ok, _goal} =
        Goals.create_goal(user, %{
          "burpee_type" => "six_count",
          "burpee_count_target" => 500,
          "duration_sec_target" => 1200,
          "date_target" => Date.add(today, 30),
          "burpee_count_baseline" => 0,
          "duration_sec_baseline" => 0,
          "date_baseline" => today
        })

      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "500"
    end

    test "shows recent session plan name", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      _session = session_from_plan_fixture(user, plan)
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "My Plan"
    end

    test "Show all expands session list", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      for _ <- 1..12, do: session_from_plan_fixture(user, plan)
      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button", "Show all") |> render_click()
      assert render(view) =~ "Show less"
    end

    test "FAB opens log modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-click='open_log_modal']") |> render_click()
      assert render(view) =~ "Log session"
    end
  end
end
