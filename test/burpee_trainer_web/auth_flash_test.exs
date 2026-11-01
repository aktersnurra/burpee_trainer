defmodule BurpeeTrainerWeb.AuthFlashTest do
  use BurpeeTrainerWeb.ConnCase

  import Phoenix.LiveViewTest

  test "reaching the app logged out redirects to login without an error", %{conn: conn} do
    landed = get(conn, ~p"/")
    assert redirected_to(landed) == ~p"/login"
    assert Phoenix.Flash.get(landed.assigns.flash, :error) == nil

    assert {:error, {:redirect, %{to: "/login"} = redirect}} = live(conn, ~p"/session/1")
    assert Map.get(redirect, :flash) in [nil, %{}]
  end
end
