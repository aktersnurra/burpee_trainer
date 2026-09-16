defmodule BurpeeTrainerWeb.StatsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  test "old Stats URL opens the inline Home history", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})

    assert {:error, {:redirect, %{to: "/?history=1"}}} = live(conn, ~p"/stats")

    assert {:error, {:redirect, %{to: "/?history=1"}}} =
             live(conn, ~p"/stats/sessions/42")
  end
end
