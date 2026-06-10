defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/workouts" do
    test "empty state renders when no plans or videos", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      assert html =~ "No workouts yet"
    end

    test "does not expose diagnostics in the normal workouts header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      refute html =~ "Tracking Test"
      refute html =~ "Diagnostics"
      refute html =~ ~s(href="/tracking-test")
    end

    test "lists plans and videos together", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, _view, html} = live(conn, ~p"/workouts")

      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "renders workout page with featured instrument and rounded list", %{
      conn: conn,
      user: user
    } do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")

      assert has_element?(view, "#workouts-featured-card")
      assert has_element?(view, "#workouts-options-section")
      assert has_element?(view, "#workouts-filter-panel")
      assert has_element?(view, "#workouts-custom-session[href='/workouts/new']")
      assert has_element?(view, "#workouts-list")
      assert has_element?(view, "[data-workout-row]")
    end

    test "Workouts page does not render a floating new-plan action", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~s(id="workouts-floating-new-plan")
    end

    test "completed weekly contract hides featured training but keeps workout list", %{
      conn: conn,
      user: user
    } do
      _plan = plan_fixture(user, %{"name" => "Coach Navy SEAL", "burpee_type" => "navy_seal"})

      for type <- ["six_count", "six_count", "navy_seal", "navy_seal"] do
        free_form_session_fixture(user, %{
          "burpee_type" => type,
          "burpee_count_actual" => 50,
          "duration_sec_actual" => 1200
        })
      end

      {:ok, view, _html} = live(conn, ~p"/workouts")

      refute has_element?(view, "#workouts-featured-card")
      assert has_element?(view, "[data-workout-row]")
      assert render(view) =~ "Coach Navy SEAL"
      refute render(view) =~ "Featured training"
    end

    test "Mine filter shows only plans", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      refute html =~ "BDT Video"
    end

    test "Videos filter shows only videos", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='videos']") |> render_click()

      html = render(view)
      refute html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "clicking active source filter deselects it", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "type filter restricts list", %{conn: conn, user: user} do
      _six = plan_fixture(user, %{"name" => "Six plan", "burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-burpee_type='six_count']") |> render_click()

      html = render(view)
      assert html =~ "Six plan"
      refute html =~ "SEAL plan"
    end

    test "Mine empty state shows when user has no plans", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert render(view) =~ "have not built any plans"
    end

    test "filter state reflected in URL", %{conn: conn, user: user} do
      _plan = plan_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert_patch(view, "/workouts?source=mine")
    end

    test "plan card opens editor and exposes an explicit play button", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts")

      assert has_element?(view, "#workout-card-plan-#{plan.id}[href='/workouts/#{plan.id}/edit']")
      assert has_element?(view, "#workout-play-plan-#{plan.id}[href='/session/#{plan.id}']")
    end

    test "edit page renders the saved structure as notation with a timeline", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Timeline Plan",
          "target_duration_min" => 4,
          "burpee_count_target" => 30
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-notation")
      assert html =~ "[10,10,10]"
      assert has_element?(view, "[data-segment-row='0']")
      assert has_element?(view, "#plan-timeline")
      assert html =~ "Finish"
      assert html =~ "0:00"
    end

    test "edit page flags a structure that misses the rep target and fixes it in one tap", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Mismatch Plan",
          "target_duration_min" => 5,
          "burpee_count_target" => 50
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "[data-plan-problem='reps_mismatch']")
      assert html =~ "blocks total 30 reps"
      assert has_element?(view, "#plan-save[disabled]")

      view |> element("button[data-fix='reps']", "Make 30 the target") |> render_click()

      refute has_element?(view, "[data-plan-problem='reps_mismatch']")
      refute has_element?(view, "#plan-save[disabled]")
    end

    test "unbroken targets generate a human plan that saves with exact duration", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "140"})

      view |> element("button[phx-value-style='unbroken']") |> render_click()
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert html =~ "14×[8] 4×[7]"
      assert html =~ "Matches your targets"
      refute has_element?(view, "#plan-save[disabled]")

      view |> element("#plan-save") |> render_click()
      assert_redirect(view, ~p"/workouts")

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      plan = BurpeeTrainer.Workouts.get_plan!(user, plan.id)
      summary = BurpeeTrainer.Planner.summary(plan)

      assert summary.burpee_count_total == 140
      assert_in_delta summary.duration_sec_total, 1200.0, 1.0
      assert BurpeeTrainer.PlanEditor.Segments.from_plan(plan) |> length() == 2
    end

    test "inserting a rest keeps the plan on target", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "140"})

      view |> element("button[phx-value-style='unbroken']") |> render_click()
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      view |> element("[data-insert-rest='0']") |> render_click()

      assert has_element?(view, "[data-rest-row='1']")

      view
      |> element("[data-rest-row='1']")
      |> render_change(%{"rest_sec" => "45"})

      html = render(view)
      assert html =~ "Matches your targets"
      assert html =~ "(rest 45s)"
      assert html =~ "20:00"
    end

    test "editing a segment marks the plan custom and reports the delta with fixes", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "140"})

      view |> element("button[phx-value-style='unbroken']") |> render_click()
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      view
      |> element("[data-segment-row='0']")
      |> render_change(%{"index" => "0", "repeat" => "13"})

      assert has_element?(view, "#plan-regenerate")
      assert has_element?(view, "[data-plan-problem='reps_mismatch']")
      assert render(view) =~ "blocks total 132 reps"

      view |> element("button[data-fix='reps']", "Make 132 the target") |> render_click()

      refute has_element?(view, "[data-plan-problem='reps_mismatch']")
      assert render(view) =~ "Matches your targets"
    end

    test "regenerate restores the solver structure after manual edits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "140"})

      view |> element("button[phx-value-style='unbroken']") |> render_click()
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      view
      |> element("[data-segment-row='0']")
      |> render_change(%{"index" => "0", "repeat" => "13"})

      assert has_element?(view, "[data-plan-problem='reps_mismatch']")

      view |> element("#plan-regenerate") |> render_click()

      refute has_element?(view, "[data-plan-problem='reps_mismatch']")
      assert render(view) =~ "14×[8] 4×[7]"
    end

    test "plan edit page shows generated plan metadata", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Coach Six-count",
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 150,
          "plan_solver_metadata" => %{
            "source" => "coach_target",
            "risk" => "normal",
            "rationale" => ["Your current estimate is 150 six-count burpees in 20 min."]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-metadata")
      html = render(view)
      assert html =~ "Why this?"
      assert html =~ "Coach target"
      assert html =~ "Recommended · 150 reps"
      assert html =~ "Risk: normal"
      assert html =~ "Your current estimate is 150 six-count burpees in 20 min."
    end

    test "plan edit page exposes duplicate and delete actions", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-duplicate")
      assert has_element?(view, "#plan-delete")
    end

    test "copying a plan from the edit page opens the copied plan", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("#plan-duplicate") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r"/workouts/\d+/edit"
      refute path == "/workouts/#{plan.id}/edit"
    end

    test "deleting a plan from the edit page returns to workouts", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("#plan-delete") |> render_click()

      assert_redirect(view, "/workouts")
    end

    test "video card has no edit link", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~r"/workouts/\d+/edit"
    end
  end

  describe "/workouts/new" do
    test "renders the new plan editor surface", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      assert html =~ "session-surface"
      assert html =~ "Custom session"
      assert html =~ "Type"
      assert html =~ "Duration"
      assert html =~ "Reps"
      assert html =~ "Style"
      assert html =~ "Six-Count"
      assert html =~ "Navy SEAL"
      assert html =~ "Workout"
      assert html =~ "Structure"
      assert html =~ "Timeline"
      assert html =~ "Finish"
      assert html =~ "Create session"
      assert has_element?(view, "#plan-notation")
      assert has_element?(view, "[data-segment-row='0']")
      assert has_element?(view, "#plan-save")
    end

    test "impossible targets show the reason and one-tap fixes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "1", "burpee_count_target" => "200"})

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "These targets don&#39;t work"
      assert html =~ "needs at least"
      assert has_element?(view, "#plan-solver-impossible button[data-fix='duration']")

      view
      |> element("#plan-solver-impossible button[data-fix='duration']")
      |> render_click()

      refute has_element?(view, "#plan-solver-impossible")
      assert render(view) =~ "Matches your targets"
    end

    test "aggressive impossible prescription explains alternatives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "300"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "Try lowering reps"
    end

    test "structure rows support adding sets and blocks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("[data-segment-row='0'] button[phx-click='add_set']") |> render_click()

      assert has_element?(view, "[data-segment-row='0'] input[name='sets[1]']")

      view |> element("[data-insert-block='0']") |> render_click()

      assert has_element?(view, "[data-segment-row='1']")
      assert has_element?(view, "#plan-regenerate")
    end

    test "picking Navy SEAL keeps the editor rendered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-click='pick_type'][phx-value-type='navy_seal']")
      |> render_click()

      html = render(view)
      assert html =~ "Navy SEAL"
      assert has_element?(view, "#plan-save")
    end
  end
end
