defmodule BurpeeTrainerWeb.AuthFlashTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "landing on the app logged out redirects to login without an error", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
  end

  test "the login page itself shows no error", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert html_response(conn, 200)
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
  end

  test "a live route reached logged out redirects to login without an error", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"} = redirect}} = live(conn, ~p"/stats")

    assert Map.get(redirect, :flash) in [nil, %{}]
  end
end
