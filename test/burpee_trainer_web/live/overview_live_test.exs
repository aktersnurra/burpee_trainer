defmodule BurpeeTrainerWeb.OverviewLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

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

  test "completed week primary action does not claim another session moves the week forward", %{
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

    html = render(view)
    assert html =~ "Weekly work is complete"
    assert html =~ "Saved Six-count"
    assert html =~ "100 reps"
    refute html =~ "One session now moves the week forward."
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
    assert html =~ "Start 20 min · 6-Count"
    assert html =~ "100 reps"
    refute html =~ "Create your first training session"
  end

  test "catch-up panel requires the user to choose the burpee type", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-catch-up-panel")
    assert has_element?(view, "#catch-up-six-count")
    assert has_element?(view, "#catch-up-navy-seal")
    refute has_element?(view, "#catch-up-standard-chunks")
    refute has_element?(view, "#catch-up-one-long")
  end

  test "home coach suggestions use active performance goals", %{conn: conn, user: user} do
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

    assert has_element?(view, "[data-home-weekly-split]")
    assert has_element?(view, "#use-coach-target-six-count-hard")
    assert has_element?(view, "#use-coach-target-six-count-easy")
    html = render(view)
    assert html =~ "Six-count"
    assert html =~ "Harder"
    assert html =~ "Easier"
    assert html =~ "20 min"
  end

  test "using a coach target creates a 20 minute workout plan", %{conn: conn, user: user} do
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

    view |> element("#use-coach-target-six-count-hard") |> render_click()

    plans = Workouts.list_plans(user)
    coach_plans = Enum.filter(plans, &String.starts_with?(&1.name, "Coach Six-count"))

    assert length(coach_plans) == 1
    [plan] = coach_plans
    assert plan.burpee_type == :six_count
    assert plan.target_duration_min == 20
    assert plan.burpee_count_target > 0
    assert plan.coach_suggestion_kind == "recommended"
    assert plan.coach_target_reps == plan.burpee_count_target
    assert plan.plan_solver_metadata["source"] == "coach_target"
    assert plan.plan_solver_metadata["solver_version"] == "deterministic-v2"
    assert_redirect(view, "/workouts/#{plan.id}/edit")
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

    assert has_element?(view, "#home-catch-up-complete")
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

    assert has_element?(view, "#home-catch-up-complete")
    refute has_element?(view, "#catch-up-six-count")
    refute has_element?(view, "[data-home-coach-suggestion]")
    refute has_element?(view, "[data-home-weekly-split]")
  end

  test "choosing a type without an active goal asks for a goal first", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#catch-up-navy-seal") |> render_click()

    assert has_element?(view, "#home-catch-up-no-goal[data-selected-type='navy_seal']")
    assert render(view) =~ "Set a Navy SEAL performance goal first."
  end

  test "choosing Navy SEAL produces a type-locked catch-up recommendation", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 100,
      "duration_sec_actual" => 1200
    })

    goal_fixture(user, %{
      "burpee_type" => "navy_seal",
      "burpee_count_target" => 80,
      "duration_sec_target" => 1200,
      "burpee_count_baseline" => 40,
      "duration_sec_baseline" => 1200
    })

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#catch-up-navy-seal") |> render_click()

    assert has_element?(view, "#home-catch-up-result[data-selected-type='navy_seal']")
    html = render(view)
    assert html =~ "Navy SEAL · 60 min"
    assert html =~ "One 60 min session"
    assert html =~ "Reduced for longer catch-up work"
    refute html =~ "Mixed"
  end

  test "using a catch-up plan creates one unscheduled long workout plan", %{
    conn: conn,
    user: user
  } do
    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 150,
      "duration_sec_actual" => 1200
    })

    free_form_session_fixture(user, %{
      "burpee_type" => "navy_seal",
      "burpee_count_actual" => 40,
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

    view |> element("#catch-up-six-count") |> render_click()
    view |> element("#use-catch-up-plan") |> render_click()

    plans = Workouts.list_plans(user)
    catch_up_plans = Enum.filter(plans, &String.starts_with?(&1.name, "Catch-up Six-count"))

    assert length(catch_up_plans) == 1
    [plan] = catch_up_plans
    assert plan.burpee_type == :six_count
    assert plan.target_duration_min == 40
    assert plan.burpee_count_target == 225
    assert plan.coach_suggestion_kind == "maintenance"
    assert plan.coach_target_reps == 225
    assert plan.plan_solver_metadata["source"] == "catch_up"
    assert plan.plan_solver_metadata["solver_version"] == "deterministic-v2"
    assert plan.plan_solver_metadata["weekly_split_effect"] == "counts_but_non_standard"
    assert_redirect(view, "/workouts/#{plan.id}/edit")
  end
end
