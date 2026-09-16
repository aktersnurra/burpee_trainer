defmodule BurpeeTrainerWeb.PlansEditCrashTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "malformed legacy editor indices safely redirect to Home", %{conn: conn} do
    for params <- [
          %{"index" => "not_a_number"},
          %{"index" => "-1"},
          %{"row-index" => "1.5"}
        ] do
      assert conn |> get(~p"/workouts/new?#{params}") |> redirected_to() == ~p"/"
    end
  end
end
