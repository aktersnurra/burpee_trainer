defmodule BurpeeTrainerWeb.SessionControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import BurpeeTrainer.Fixtures

  describe "GET /login" do
    test "renders the Pocket ID sign-in button", %{conn: conn} do
      conn = get(conn, ~p"/login")
      html = html_response(conn, 200)

      assert html =~ "Sign in with Pocket ID"
      assert html =~ ~p"/auth/oidc"
    end

    test "offers no password form", %{conn: conn} do
      conn = get(conn, ~p"/login")
      html = html_response(conn, 200)

      refute html =~ "type=\"password\""
      refute html =~ "Password"
    end

    test "redirects authenticated users to the overview", %{conn: conn} do
      user = user_fixture()
      conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/login")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "DELETE /logout" do
    test "clears the session and redirects to login", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{user_id: user.id})
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end
  end
end
