defmodule BurpeeTrainerWeb.StatsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Goals, Workouts}

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/stats" do
    test "renders streak card with zero state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "/ 80 min"
      assert html =~ "No active streak"
    end

    test "renders two goal slots always", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "6-Count"
      assert html =~ "Navy SEAL"
    end

    test "empty goal slot shows No sessions yet when no sessions exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "No sessions yet"
    end

    test "empty goal slot shows Set goal when sessions exist but no goal", %{
      conn: conn,
      user: user
    } do
      free_form_session_fixture(user, %{"burpee_type" => "six_count"})
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "Set goal"
    end

    test "active goal slot shows burpee target", %{conn: conn, user: user} do
      today = Date.utc_today()

      {:ok, _goal} =
        Goals.create_goal(user, %{
          "burpee_type" => "six_count",
          "burpee_count_target" => 300,
          "duration_sec_target" => 1200,
          "date_target" => Date.add(today, 30),
          "burpee_count_baseline" => 0,
          "duration_sec_baseline" => 0,
          "date_baseline" => today
        })

      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "300"
    end

    test "shows recent session plan name", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      _session = session_from_plan_fixture(user, plan)
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "My Plan"
    end

    test "period selector scopes push-ups and recent sessions", %{conn: conn, user: user} do
      today = Date.utc_today()

      recent_plan = plan_fixture(user, %{"name" => "Recent Plan"})
      old_plan = plan_fixture(user, %{"name" => "Old Plan", "burpee_type" => "navy_seal"})

      recent =
        session_from_plan_fixture(user, recent_plan, %{
          "burpee_count_actual" => 10,
          "duration_sec_actual" => 600
        })

      old =
        session_from_plan_fixture(user, old_plan, %{
          "burpee_type" => "navy_seal",
          "burpee_count_actual" => 20,
          "duration_sec_actual" => 600
        })

      BurpeeTrainer.Repo.update!(
        Ecto.Changeset.change(recent,
          inserted_at: DateTime.new!(Date.add(today, -3), ~T[12:00:00], "Etc/UTC")
        )
      )

      BurpeeTrainer.Repo.update!(
        Ecto.Changeset.change(old,
          inserted_at: DateTime.new!(Date.add(today, -40), ~T[12:00:00], "Etc/UTC")
        )
      )

      {:ok, view, html} = live(conn, ~p"/stats?period=30d")

      assert html =~ "Recent Plan"
      refute html =~ "Old Plan"
      assert has_element?(view, "#stats-pushups-period", "10")
      assert has_element?(view, "#stats-pushups-all-time", "70")
    end

    test "tracked sessions show consistency badge and link", %{conn: conn, user: user} do
      plan = plan_fixture(user)

      {:ok, session} =
        Workouts.create_tracked_session_from_plan(user, plan, %{
          "burpee_type" => "six_count",
          "burpee_count_planned" => "3",
          "duration_sec_planned" => "15",
          "burpee_count_actual" => "3",
          "duration_sec_actual" => "15",
          "target_pace_sec" => "5.0",
          "cadence_ms" => [5000, 10000, 15000]
        })

      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "Tracked"
      assert html =~ "100% consistent"
      assert html =~ ~s(href="/stats/sessions/#{session.id}")
    end

    test "timed sessions are not clickable", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan)

      {:ok, _view, html} = live(conn, ~p"/stats")
      refute html =~ ~s(href="/stats/sessions/#{session.id}")
    end

    test "Load more button appears when more sessions exist", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      for _ <- 1..21, do: session_from_plan_fixture(user, plan)
      {:ok, _view, html} = live(conn, ~p"/stats")
      assert html =~ "Load more"
    end

    test "Load more appends next page of sessions", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      for _ <- 1..6, do: session_from_plan_fixture(user, plan)
      {:ok, view, _html} = live(conn, ~p"/stats")
      view |> element("button[phx-click='load_more_sessions']") |> render_click()
      # After loading the last page, Load more disappears
      refute render(view) =~ "Load more"
    end

    test "recent sessions can be deleted", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      session = session_from_plan_fixture(user, plan)

      {:ok, view, _html} = live(conn, ~p"/stats")
      assert has_element?(view, "#session-delete-#{session.id}")

      view |> element("#session-delete-#{session.id}") |> render_click()

      refute has_element?(view, "#session-delete-#{session.id}")
      assert Workouts.list_sessions(user) == []
    end

    test "uses session surface visual system without stats log action", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stats")
      html = render(view)

      assert has_element?(view, "[data-stats-page].session-surface")
      refute has_element?(view, "#stats-log-button")
      refute has_element?(view, "button[phx-click='open_log_modal']")
      refute html =~ "fixed bottom-28 right-4"
      assert html =~ "text-[var(--session-ink)]"
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
