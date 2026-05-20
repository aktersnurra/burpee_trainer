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

    test "Load more button appears when more sessions exist", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      for _ <- 1..21, do: session_from_plan_fixture(user, plan)
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "Load more"
    end

    test "Load more appends next page of sessions", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      for _ <- 1..21, do: session_from_plan_fixture(user, plan)
      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-click='load_more_sessions']") |> render_click()
      # After loading more, the extra session is visible and no more pages
      refute render(view) =~ "Load more"
    end

    test "FAB opens log modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-click='open_log_modal']") |> render_click()
      assert render(view) =~ "Log session"
    end
  end

  describe "goal creation modal" do
    test "Set goal button opens modal", %{conn: conn, user: user} do
      _session =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "duration_sec_actual" => 1200
        })

      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-value-type='six_count']") |> render_click()
      assert render(view) =~ "Set 6-Count goal"
    end

    test "modal shows no-session state when user has no qualifying sessions", %{
      conn: conn,
      user: user
    } do
      _short =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 600
        })

      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-value-type='six_count']") |> render_click()
      assert render(view) =~ "20+ minutes"
    end

    test "modal shows form when baseline session exists", %{conn: conn, user: user} do
      _session =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 1200
        })

      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-value-type='six_count']") |> render_click()
      assert render(view) =~ "Target burpees"
      assert render(view) =~ "Baseline: 30 burpees"
    end

    test "saving goal closes modal and updates goal slot", %{conn: conn, user: user} do
      _session =
        free_form_session_fixture(user, %{
          "burpee_type" => "six_count",
          "burpee_count_actual" => 30,
          "duration_sec_actual" => 1200
        })

      today = Date.utc_today()

      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-value-type='six_count']") |> render_click()

      view
      |> form("#goal-form-goal-form", %{
        "goal" => %{
          "burpee_count_target" => "60",
          "date_target" => Date.to_iso8601(Date.add(today, 30))
        }
      })
      |> render_submit()

      html = render(view)
      refute html =~ "Set 6-Count goal"
      assert html =~ "/ 60"
    end

    test "navy seal goal slot opens modal for navy_seal type", %{conn: conn, user: user} do
      _session =
        free_form_session_fixture(user, %{
          "burpee_type" => "navy_seal",
          "burpee_count_actual" => 20,
          "duration_sec_actual" => 1200
        })

      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-value-type='navy_seal']") |> render_click()
      assert render(view) =~ "Set Navy SEAL goal"
    end
  end
end
