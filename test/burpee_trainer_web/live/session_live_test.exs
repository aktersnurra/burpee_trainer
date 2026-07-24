defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders without a dead warmup/mood overlay", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    {:ok, view, html} = live(conn, ~p"/session/#{plan.id}")

    refute html =~ "How do you feel?"
    refute has_element?(view, "[phx-click=\"session_started\"]")
    refute has_element?(view, "#start-overlay")
  end

  test "camera setup panel no longer renders a manual start button", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    refute has_element?(view, "#camera-setup-start-btn")
  end
end
