defmodule BurpeeTrainerWeb.AuthTest do
  use BurpeeTrainerWeb.ConnCase

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Accounts.Scope

  test "the plug assigns the scope for a logged-in user", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> BurpeeTrainerWeb.Auth.fetch_current_scope([])

    assert %Scope{user: %{id: id}} = conn.assigns.current_scope
    assert id == user.id
    refute Map.has_key?(conn.assigns, :current_user)
  end

  test "guest and deleted-user sessions stay unauthenticated", %{conn: conn} do
    for session <- [%{}, %{user_id: -1}] do
      guest =
        conn
        |> init_test_session(session)
        |> BurpeeTrainerWeb.Auth.fetch_current_scope([])

      assert guest.assigns.current_scope == nil
      refute Map.has_key?(guest.assigns, :current_user)
      redirected = BurpeeTrainerWeb.Auth.require_authenticated_user(guest, [])
      assert redirected.halted
      assert redirected_to(redirected) == "/login"
    end
  end
end
