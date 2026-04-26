defmodule BurpeeTrainerWeb.HistoryLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "empty state when no sessions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/history")
    assert html =~ "No sessions recorded yet"
  end

  test "renders chart element and session rows", %{conn: conn, user: user} do
    _ =
      free_form_session_fixture(user, %{"burpee_type" => "six_count", "burpee_count_actual" => 30})

    _ =
      free_form_session_fixture(user, %{"burpee_type" => "navy_seal", "burpee_count_actual" => 18})

    {:ok, _view, html} = live(conn, ~p"/history")

    assert html =~ ~s(id="history-chart")
    assert html =~ ~s(phx-hook="ChartHook")
    assert html =~ "data-chart="
    assert html =~ "6-count PRs"
    assert html =~ "Navy SEAL PRs"
  end

  test "goal and trend overlays are included in chart data", %{conn: conn, user: user} do
    for count <- [20, 22, 25, 28] do
      _ =
        free_form_session_fixture(user, %{
          "burpee_count_actual" => count,
          "burpee_type" => "six_count"
        })
    end

    _ = goal_fixture(user, %{"burpee_type" => "six_count"})

    {:ok, _view, html} = live(conn, ~p"/history")

    assert html =~ "6-count goal"
    assert html =~ "6-count trend"
  end

  describe "weekly progress section" do
    test "shows 'No sessions recorded yet' when no sessions exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/history")
      assert html =~ "Weekly Progress"
      assert html =~ "No sessions recorded yet"
    end

    test "shows week rows with progress bar and minutes", %{conn: conn, user: user} do
      # 60 min in the week of 2026-04-20
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 3600,
        "inserted_at" => ~U[2026-04-22 08:00:00Z]
      })

      {:ok, _view, html} = live(conn, ~p"/history")

      assert html =~ "Weekly Progress"
      assert html =~ "goal: 80 min / week"
      assert html =~ "Apr 20"
      assert html =~ "/ 80 min"
    end

    test "shows checkmark for a completed week and X for a missed week", %{conn: conn, user: user} do
      # Week of 2026-04-06 — met goal (90 min), clearly in the past
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 5400,
        "inserted_at" => ~U[2026-04-07 08:00:00Z]
      })

      # Week of 2026-04-13 — missed (30 min), clearly in the past
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 1800,
        "inserted_at" => ~U[2026-04-14 08:00:00Z]
      })

      {:ok, _view, html} = live(conn, ~p"/history")

      assert html =~ "✓"
      assert html =~ "✗"
    end

    test "warmup sessions are excluded from weekly minutes", %{conn: conn, user: user} do
      alias BurpeeTrainer.Workouts

      # Use a past week so it shows ✗/✓ badge (not "in progress")
      past_dt = ~U[2026-04-14 08:00:00Z]

      # 75 min main — should NOT meet goal
      free_form_session_fixture(user, %{
        "duration_sec_actual" => 4500,
        "inserted_at" => past_dt
      })

      # 30 min warmup — must not push it over 80
      {:ok, _} =
        Workouts.create_warmup_session(user, %{
          burpee_type: :six_count,
          burpee_count_done: 5,
          duration_sec: 1800
        })

      {:ok, _view, html} = live(conn, ~p"/history")

      assert html =~ "✗"
      refute html =~ "✓"
    end

    test "show all weeks toggle reveals older weeks", %{conn: conn, user: user} do
      # Create 9 sessions in 9 different weeks (each Mon, going back)
      for i <- 1..9 do
        date = Date.add(~D[2026-04-20], -(i - 1) * 7)
        dt = DateTime.new!(date, ~T[08:00:00], "Etc/UTC")

        free_form_session_fixture(user, %{
          "duration_sec_actual" => 3600,
          "inserted_at" => dt
        })
      end

      {:ok, view, html} = live(conn, ~p"/history")

      assert html =~ "Show all weeks"
      refute html =~ "Show less"

      html2 = view |> element("button", "Show all weeks") |> render_click()

      assert html2 =~ "Show less"
      refute html2 =~ "Show all weeks"
    end
  end
end
