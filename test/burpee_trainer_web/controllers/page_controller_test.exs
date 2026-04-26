defmodule BurpeeTrainerWeb.PageControllerTest do
  use BurpeeTrainerWeb.ConnCase

  import BurpeeTrainer.Fixtures

  test "GET / redirects unauthenticated users to /login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / renders the dashboard for an authenticated user", %{conn: conn} do
    user = user_fixture(%{"username" => "alice"})
    conn = conn |> init_test_session(%{user_id: user.id}) |> get(~p"/")
    html = html_response(conn, 200)
    assert html =~ "alice"
    assert html =~ "Plans"
  end
end
