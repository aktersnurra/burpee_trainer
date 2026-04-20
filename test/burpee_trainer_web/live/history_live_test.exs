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
end
