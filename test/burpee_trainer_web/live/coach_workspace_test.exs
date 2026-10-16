defmodule BurpeeTrainerWeb.CoachWorkspaceTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  test "workspace menu uses patches but session menu crosses LiveViews with navigation", %{
    conn: _conn
  } do
    user = user_fixture()

    for page <- [:home, :history, :coach, :session] do
      document =
        render_component(&BurpeeTrainerWeb.Layouts.app/1,
          flash: %{},
          current_scope: BurpeeTrainer.Accounts.Scope.for_user(user),
          current_page: page,
          inner_block: []
        )
        |> LazyHTML.from_fragment()

      for id <- [
            "desktop-home-nav",
            "mobile-home-nav",
            "desktop-history-nav",
            "mobile-history-nav"
          ] do
        node = LazyHTML.query(document, "##{id}")

        assert LazyHTML.attribute(node, "data-phx-link") == [
                 if(page == :session, do: "redirect", else: "patch")
               ]

        assert LazyHTML.attribute(node, "href") == [
                 if(String.contains?(id, "history"), do: "/progress", else: "/")
               ]
      end
    end
  end
end
