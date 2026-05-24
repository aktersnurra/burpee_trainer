defmodule BurpeeTrainerWeb.LayoutsTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "root layout keeps app bundle and omits inline theme initializer" do
    html = render_to_string(BurpeeTrainerWeb.Layouts, "root", "html", inner_content: "")

    assert html =~ ~s(src="/assets/js/app.js")
    refute html =~ "const setTheme"
    refute html =~ "localStorage.getItem(\"phx:theme\")"
  end
end
