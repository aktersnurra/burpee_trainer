defmodule BurpeeTrainerWeb.StatsLiveCrashTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "an unknown goal type does not crash the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stats")

    render_click(view, "open_goal_modal", %{"type" => "not_a_real_type"})

    assert render(view)
  end
end
