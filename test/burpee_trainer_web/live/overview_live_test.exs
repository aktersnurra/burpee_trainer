defmodule BurpeeTrainerWeb.OverviewLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup_all do
    previous_today = Application.get_env(:burpee_trainer, :today_override)
    saturday = Date.utc_today() |> Date.beginning_of_week(:monday) |> Date.add(5)
    Application.put_env(:burpee_trainer, :today_override, saturday)

    on_exit(fn ->
      if previous_today,
        do: Application.put_env(:burpee_trainer, :today_override, previous_today),
        else: Application.delete_env(:burpee_trainer, :today_override)
    end)

    :ok
  end

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  test "completed week shows rest state without workout or catch-up CTA", %{
    conn: conn,
    user: user
  } do
    plan_fixture(user, %{
      "name" => "Saved Six-count",
      "burpee_type" => "six_count",
      "target_duration_min" => 20,
      "burpee_count_target" => 100
    })

    for type <- ["six_count", "six_count", "navy_seal", "navy_seal"] do
      free_form_session_fixture(user, %{
        "burpee_type" => type,
        "burpee_count_actual" => 50,
        "duration_sec_actual" => 1200
      })
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-primary-workout")
    refute has_element?(view, "#home-start-workout")
    refute has_element?(view, "#home-catch-up-panel")

    html = render(view)
    assert html =~ "Week complete"
    assert html =~ "You’re done for the week."
    refute html =~ "Saved Six-count"
    refute html =~ "100 reps"
  end

  test "home primary action starts an existing plan even if it has never been run", %{
    conn: conn,
    user: user
  } do
    plan_fixture(user, %{
      "name" => "Saved Six-count",
      "burpee_type" => "six_count",
      "target_duration_min" => 20,
      "burpee_count_target" => 100
    })

    {:ok, view, _html} = live(conn, ~p"/")

    html = render(view)
    assert html =~ "20 min · 6-Count"
    assert html =~ "100 reps"
    assert html =~ "Start session"
    refute html =~ "Start 20 min"
    refute html =~ "Create your first training session"
  end

  test "home renders quiet action-first structure", %{conn: conn, user: user} do
    plan = plan_fixture(user, %{"name" => "Default Work"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-status-strip")
    assert has_element?(view, "#home-week-progress")
    assert has_element?(view, "#home-primary-workout")
    assert has_element?(view, "#home-prescription")
    assert has_element?(view, "#home-coach-guidance")
    assert has_element?(view, "#home-start-workout[href='/session/#{plan.id}']")
    assert has_element?(view, "#home-start-workout .hero-play-solid")
    assert has_element?(view, "#home-secondary-actions")
    assert has_element?(view, "#home-change-workout")
    assert has_element?(view, "#home-log-session")
    assert has_element?(view, "#home-theme-toggle[phx-click]")

    html = render(view)
    assert html =~ "Choose a different session"
    assert html =~ "Add a session you already completed"
    assert html =~ "Theme"
    assert html =~ "Today’s prescription"
    assert html =~ "Coach note"
    assert html =~ "Level"
    assert html =~ "Default Work"
    refute html =~ "Start before"
    refute html =~ "12-week"
    refute html =~ "Dashboard"
  end

  test "incomplete home integrates coach guidance with catch-up preview action", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 150,
      "duration_sec_actual" => 1200
    })

    goal_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 200,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 150,
      "duration_sec_baseline" => 1200
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-prescription")
    assert has_element?(view, "#home-coach-guidance")
    html = render(view)
    assert html =~ "Coach"
    assert has_element?(view, "#home-catch-up-panel")
    assert has_element?(view, "#catch-up-six-count")
    refute has_element?(view, "[data-home-coach-suggestion]")
    refute has_element?(view, "[data-home-weekly-split]")
  end

  test "catch-up panel previews split sessions and creates plans", %{conn: conn, user: user} do
    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 150,
      "duration_sec_actual" => 1200
    })

    goal_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 200,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 150,
      "duration_sec_baseline" => 1200
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-catch-up-panel")

    view
    |> element("#catch-up-six-count")
    |> render_click()

    assert has_element?(view, "#home-catch-up-preview")
    assert render(view) =~ "Creates 3 × 20 min Six-count sessions"
    assert has_element?(view, "#home-create-catch-up")

    view
    |> element("#home-create-catch-up")
    |> render_click()

    {path, _flash} = assert_redirect(view)
    assert path =~ ~r"/workouts/\d+/edit"
  end

  test "non-standard completed week hides catch-up choices and coach suggestions", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 150,
      "duration_sec_actual" => 2400
    })

    free_form_session_fixture(user, %{
      "burpee_type" => "navy_seal",
      "burpee_count_actual" => 80,
      "duration_sec_actual" => 2400
    })

    goal_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 200,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 150,
      "duration_sec_baseline" => 1200
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-catch-up-panel")
    refute has_element?(view, "#catch-up-six-count")
    refute has_element?(view, "[data-home-coach-suggestion]")
    refute has_element?(view, "[data-home-weekly-split]")
  end

  test "completed week hides catch-up choices and coach suggestions", %{conn: conn, user: user} do
    for type <- ["six_count", "six_count", "navy_seal", "navy_seal"] do
      free_form_session_fixture(user, %{
        "burpee_type" => type,
        "burpee_count_actual" => 50,
        "duration_sec_actual" => 1200
      })
    end

    goal_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_target" => 100,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 50,
      "duration_sec_baseline" => 1200
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-week-complete")
    refute has_element?(view, "#home-catch-up-panel")
    refute has_element?(view, "#catch-up-six-count")
    refute has_element?(view, "[data-home-coach-suggestion]")
    refute has_element?(view, "[data-home-weekly-split]")
  end
end
