defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "an unknown filter value does not crash the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workouts")

    for {key, value} <- [
          {"source", "not_a_real_source"},
          {"burpee_type", "not_a_real_type"},
          {"level", "not_a_real_level"}
        ] do
      render_click(view, "toggle_filter", %{key => value})
      assert render(view)
    end
  end

  test "a known filter value still applies", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workouts")

    render_click(view, "toggle_filter", %{"burpee_type" => "six_count"})

    assert_patched(view, ~p"/workouts?burpee_type=six_count")
  end
end
