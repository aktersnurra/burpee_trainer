defmodule BurpeeTrainerWeb.SessionControllerTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures

  describe "GET /login" do
    test "renders the login form when logged out", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Sign in"
    end

    test "redirects home when already logged in", %{conn: conn} do
      user = user_fixture()
      conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/login")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /login" do
    test "signs a user in with valid credentials", %{conn: conn} do
      _ = user_fixture(%{"username" => "alice", "password" => "longenoughpw"})

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"username" => "alice", "password" => "longenoughpw"}
        })

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id)
    end

    test "rejects invalid credentials", %{conn: conn} do
      _ = user_fixture(%{"username" => "alice", "password" => "longenoughpw"})

      conn =
        post(conn, ~p"/login", %{
          "user" => %{"username" => "alice", "password" => "wrongpass"}
        })

      html = html_response(conn, 200)
      assert html =~ "Invalid username or password"
      refute get_session(conn, :user_id)
    end
  end

  describe "DELETE /logout" do
    test "clears the session", %{conn: conn} do
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
