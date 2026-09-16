defmodule BurpeeTrainerWeb.StatsLiveCrashTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "an unknown legacy goal type safely redirects to Home History", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/?history=1"}}} =
             live(conn, ~p"/stats?#{%{"type" => "not_a_real_type"}}")
  end
end
