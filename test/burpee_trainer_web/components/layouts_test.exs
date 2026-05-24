defmodule BurpeeTrainerWeb.LayoutsTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "root layout keeps app bundle and omits inline theme initializer" do
    html = render_to_string(BurpeeTrainerWeb.Layouts, "root", "html", inner_content: "")

    assert html =~ ~s(src="/assets/js/app.js")
    assert html =~ ~r/<script(?=[^>]*\bsrc="\/assets\/js\/app\.js")(?=[^>]*\bdefer\b)[^>]*>/

    inline_scripts =
      Regex.scan(~r/<script\b(?![^>]*\bsrc=)[^>]*>(.*?)<\/script>/s, html,
        capture: :all_but_first
      )

    assert inline_scripts == []
    refute html =~ "const setTheme"
    refute html =~ "localStorage.getItem(\"phx:theme\")"
  end
end
