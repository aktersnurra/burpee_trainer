defmodule BurpeeTrainerWeb.AuthTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope

  test "the plug assigns the scope for a logged-in user", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> BurpeeTrainerWeb.Auth.fetch_current_user([])

    assert %Scope{user: %{id: id}} = conn.assigns.current_scope
    assert id == user.id
  end
end
