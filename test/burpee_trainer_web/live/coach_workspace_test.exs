defmodule BurpeeTrainerWeb.CoachWorkspaceTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.Guidance

  test "History coach entry navigates to Coach and close returns to History", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, history, _html} = live(conn, ~p"/history")

    history |> element("#history-coach-open") |> render_click()
    assert_patch(history, "/coach?from=history")
    coach = history
    assert coach.module == BurpeeTrainerWeb.HomeLive
    assert has_element?(coach, "#home-coach-summary")

    assert has_element?(
             coach,
             "#home-coach-back[phx-click=close_coach][aria-label='Back to History']"
           )

    refute has_element?(coach, "#home-state-content, #home-history")
    coach |> element("#home-coach-back") |> render_click()
    assert_patch(coach, "/history")

    [commands] =
      render(coach)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-history-heading")
      |> LazyHTML.attribute("phx-mounted")

    assert [["focus", %{"to" => "#history-coach-open"}]] = Jason.decode!(commands)
  end

  test "Home, missing and hostile referrers have safe Close and Escape bindings", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})

    for path <- [
          "/coach?from=home",
          "/coach",
          "/coach?from=https://evil.example",
          "/coach?from=//evil.example"
        ] do
      {:ok, view, _} = live(conn, path)

      assert has_element?(
               view,
               "#home-coach-back[phx-click=close_coach][aria-label='Back to workout']"
             )

      assert has_element?(
               view,
               "#home-coach-panel[phx-window-keydown=close_coach][phx-key=Escape]"
             )

      assert has_element?(view, "#home-coach-heading[tabindex='-1']")

      [commands] =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#home-coach-panel")
        |> LazyHTML.attribute("phx-mounted")

      assert [["focus", %{"to" => "#home-coach-heading"}]] = Jason.decode!(commands)
      refute has_element?(view, "#home-state-content, #home-history")
      view |> element("#home-coach-back") |> render_click()
      assert_patch(view, "/")
    end
  end

  test "completed Home Coach Escape restores the actual Coach entry", %{conn: conn} do
    user = user_fixture()

    %BurpeeTrainer.Workouts.WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      display_name_snapshot: "Saved",
      workout_type_snapshot: :six_count,
      burpee_type: :six_count,
      burpee_count_actual: 20,
      duration_sec_actual: 1200,
      completed_at: DateTime.utc_now(:second),
      capture_mode: :logged
    }
    |> BurpeeTrainer.Repo.insert!()

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-result-coach") |> render_click()
    assert_patch(view, "/coach?from=home")
    view |> element("#home-coach-panel") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, "/")

    [commands] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#home-result-coach")
      |> LazyHTML.attribute("phx-mounted")

    assert [["focus", %{"to" => "#home-result-coach"}]] = Jason.decode!(commands)
  end

  test "workspace menu uses patches but session menu crosses LiveViews with navigation", %{
    conn: _conn
  } do
    user = user_fixture()

    memory =
      render_component(&BurpeeTrainerWeb.HomeCoachComponents.guidance_form/1,
        id: "test-guidance-form",
        form: Phoenix.Component.to_form(%{"text" => ""}, as: :coach_guidance),
        memory_link?: true
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(memory, "#home-coach-memory-link[href='/history'][data-phx-link=patch]")
           |> Enum.count() == 1

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
                 if(String.contains?(id, "history"), do: "/history", else: "/")
               ]
      end
    end
  end

  test "malformed Coach controls do not mutate guidance", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/coach")

    for event <- ["coach_guidance_remove", "coach_guidance_edit", "coach_guidance_submit"] do
      for params <- [%{}, %{"id" => %{}}, %{"id" => "bogus"}] do
        render_click(view, event, params)
        assert Guidance.list(BurpeeTrainer.Accounts.Scope.for_user(user)) == []
        assert has_element?(view, "#home-coach-panel")
      end
    end
  end

  test "Coach guidance is saved through the real form", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/coach?from=home")

    view
    |> form("#home-coach-guidance-form", coach_guidance: %{text: "Keep sets shorter"})
    |> render_submit()

    assert has_element?(view, "#home-coach-guidance-status[role=status]", "Saved for your coach")

    assert [%{text: "Keep sets shorter"}] =
             Guidance.list(BurpeeTrainer.Accounts.Scope.for_user(user))
  end
end
