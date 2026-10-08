defmodule BurpeeTrainerWeb.InsightPresentationTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Insights}
  alias BurpeeTrainer.Accounts.Scope

  test "stored insight appears on shared Home and selected History without changing process", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    session = free_form_session_fixture(user)
    scope = Scope.for_user(user)

    assert {:ok, _} =
             Insights.store(
               scope,
               session.id,
               %{
                 "headline" => "Steady progress",
                 "points" => [
                   %{"text" => "25 reps last session.", "metric_ids" => ["session.reps"]}
                 ]
               },
               "llm"
             )

    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/")
    pid = view.pid

    assert has_element?(
             view,
             "[data-home-state=done_today] #home-insight-headline",
             "Steady progress"
           )

    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/history")
    view |> element("#home-history-inspect-#{session.id}") |> render_click()
    assert has_element?(view, "#history-insight-points li", "25 reps last session.")
    assert view.pid == pid
  end

  test "narration arriving after Home mount is read on same-process History roundtrip", %{
    conn: conn
  } do
    scope = scope_fixture(%{"timezone" => "Etc/UTC"})
    session = free_form_session_fixture(scope.user)
    conn = init_test_session(conn, %{user_id: scope.user.id})
    {:ok, view, _} = live(conn, ~p"/")
    pid = view.pid
    refute has_element?(view, "#home-insight-headline")

    assert {:ok, _} =
             Insights.store(
               scope,
               session.id,
               %{"headline" => "Session saved", "points" => []},
               "fallback"
             )

    view |> element("#home-history-toggle") |> render_click()
    assert_patch(view, "/history")
    view |> element("#home-history-close") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#home-insight-headline", "Session saved")
    assert view.pid == pid
  end
end
