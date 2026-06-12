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

  describe "app layout session surface pages" do
    test "home, workouts, stats, plans, and tracking test use session surface chrome" do
      for page <- [:home, :workouts, :stats, :plans, :tracking_test] do
        html =
          render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
            flash: %{},
            current_user: %{id: 1},
            current_page: page,
            current_level: nil,
            inner_block: []
          )

        assert html =~ "session-surface"
        assert html =~ "bg-[var(--session-bg)]"
        assert html =~ "text-[var(--session-ink)]"
        refute html =~ "bg-base-nav"
      end
    end

    test "authenticated app pages render theme toggle" do
      html =
        render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
          flash: %{},
          current_user: %{id: 1},
          current_page: :home,
          current_level: nil,
          inner_block: []
        )

      assert html =~ "phx:toggle-theme"
      assert html =~ "Toggle color theme"
    end

    test "session screens without current page omit theme toggle" do
      html =
        render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
          flash: %{},
          current_user: %{id: 1},
          current_page: nil,
          current_level: nil,
          inner_block: []
        )

      refute html =~ "phx:toggle-theme"
      refute html =~ "Toggle light and dark theme"
    end

    test "non-session pages keep existing centered dark shell" do
      html =
        render_to_string(BurpeeTrainerWeb.Layouts, "app", "html",
          flash: %{},
          current_user: %{id: 1},
          current_page: :video,
          current_level: nil,
          inner_block: []
        )

      assert html =~ "bg-base-nav"
      assert html =~ "mx-auto max-w-2xl"
    end
  end
end
