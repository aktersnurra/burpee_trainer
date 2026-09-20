defmodule BurpeeTrainerWeb.PlansEditCrashTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "malformed index params do not crash the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workouts/new")

    for {event, params} <- [
          {"toggle_block_menu", %{"index" => "not_a_number"}},
          {"toggle_block_expand", %{"index" => "-1"}},
          {"toggle_timeline_block", %{"row-index" => "1.5"}}
        ] do
      render_click(view, event, params)
      assert render(view), "#{event} killed the view"
    end
  end
end
