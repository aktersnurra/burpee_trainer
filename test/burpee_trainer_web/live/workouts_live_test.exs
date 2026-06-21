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

    test "exposes camera debug as a quiet utility action", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts")
      assert html =~ "Camera debug"
      assert has_element?(view, "#workouts-camera-debug[href='/tracking-test']")
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

      assert has_element?(view, "#workouts-page.session-surface")
      assert has_element?(view, "#workouts-featured-card")
      assert has_element?(view, "#workouts-options-section")
      assert has_element?(view, "#workouts-filter-panel")
      assert has_element?(view, "#workouts-new-workout[href='/workouts/new']")
      assert render(view) =~ "Saved plans"
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

    test "Saved plans filter shows only plans", %{conn: conn, user: user} do
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

    test "workout outline renders block summary without duplicated graph", %{
      conn: conn,
      user: user
    } do
      plan = plan_fixture(user, %{"name" => "Timeline Plan"})
      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#workout-outline")
      assert html =~ "Block 1"
      assert html =~ "30 reps"
      assert html =~ "3 sets"
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ ~s(id="graph-inspector")
    end

    test "pace override is available without opening graph inspector", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Timeline Edit Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-pace-form input[name='pace']")
      refute has_element?(view, "#graph-inspector")
    end

    test "outline does not expose solver graph inspector for multiple blocks", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Two Block Plan",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 10,
                  "sec_per_rep" => 6.0,
                  "sec_per_burpee" => 3.0,
                  "end_of_set_rest" => 0
                }
              ]
            },
            %{
              "position" => 2,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 8,
                  "sec_per_rep" => 7.0,
                  "sec_per_burpee" => 4.0,
                  "end_of_set_rest" => 0
                }
              ]
            }
          ]
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#workout-outline")
      assert html =~ "Block 1"
      refute has_element?(view, "#graph-inspector")
    end

    test "timeline splits a long single block around additional rest", %{conn: conn, user: user} do
      sets =
        for position <- 1..40 do
          %{
            "position" => position,
            "burpee_count" => 5,
            "sec_per_rep" => 6.0,
            "sec_per_burpee" => 3.0,
            "end_of_set_rest" => 0
          }
        end

      plan =
        plan_fixture(user, %{
          "name" => "Long Block Rest Plan",
          "additional_rests" => Jason.encode!([%{"target_min" => 18, "rest_sec" => 10}]),
          "blocks" => [%{"position" => 1, "repeat_count" => 1, "sets" => sets}]
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ "Block 1"
      assert has_element?(view, "#workout-outline")
      assert html =~ "200 reps"
      refute html =~ "Block 1 · 36 × Block 1"
      refute html =~ "Block 1 continued"
    end

    test "outline renders repeated block with additional rest", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Repeated Block Rest Plan",
          "additional_rests" => Jason.encode!([%{"target_min" => 12, "rest_sec" => 10}]),
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 10,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 4,
                  "sec_per_rep" => 15.0,
                  "sec_per_burpee" => 8.0,
                  "end_of_set_rest" => 0
                },
                %{
                  "position" => 2,
                  "burpee_count" => 3,
                  "sec_per_rep" => 20.0,
                  "sec_per_burpee" => 8.0,
                  "end_of_set_rest" => 0
                }
              ]
            }
          ]
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#workout-outline")
      assert html =~ "70 reps"
      assert html =~ "20 sets"
      refute html =~ "Block 1 · 6 × Block 1"
    end

    test "generated unbroken outline renders executable steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "200"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "5"})

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "200 reps"
      assert html =~ "15s recovery"
      refute html =~ ~s(id="plan-prescription-timeline")
    end

    test "removed timeline does not offer invalid rest near finish", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "144"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      refute has_element?(view, "[data-timeline-edge-action][phx-value-target-min='19']")
      refute has_element?(view, "#plan-prescription-timeline")
    end

    test "block pattern editor reruns solver", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("button[phx-value-type='navy_seal']") |> render_click()

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

      html = render(view)
      assert html =~ "70 reps"
      assert html =~ "20:00"
      assert html =~ "7 reps/block"
      assert html =~ "10×"
      assert html =~ ~s(value="4")
      assert html =~ ~s(value="3")
    end

    test "block pattern set can be removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})
      assert has_element?(view, "button[data-remove-pattern-set][phx-value-index='1']")

      view
      |> element("button[data-remove-pattern-set][phx-value-index='1']")
      |> render_click()

      html = render(view)
      assert html =~ "4 reps/block"
      refute html =~ ~s(name="pattern[1]")
    end

    test "visible pace control exposes editable pace override", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

      assert has_element?(view, "#plan-pace-form input[name='pace']")
      refute has_element?(view, "#graph-inspector")
      assert render(view) =~ "Auto pace"
      refute render(view) =~ "Recovery · 0s auto"

      view
      |> element("#plan-pace-form")
      |> render_change(%{"pace" => "6.4"})

      html = render(view)
      assert html =~ "Manual pace"
      assert html =~ ~s(value="6.4")
    end

    test "saves generated pattern plan and reloads steps", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("button[phx-value-type='navy_seal']") |> render_click()

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      assert_redirect(view, ~p"/workouts")

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      plan = BurpeeTrainer.Workouts.get_plan!(user, plan.id)

      assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
               [4, 3]
             ]

      assert [%{kind: :block_run, repeat_count: 10}] = plan.steps
    end

    test "new plan renders normalized workout outline instead of solver-fragment blocks", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "144"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "20:00 · 144 reps · 18 sets"
      assert html =~ "Block 1"
      assert html =~ "Sets 1–12"
      assert html =~ "Set 13"
      assert html =~ "Sets 14–16"
      assert html =~ "No recovery"
    end

    test "new plan explains smart recommendation and optional reset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "160"})

      html = render(view)
      assert html =~ "Recommended"
      assert html =~ "recovery"
      assert html =~ "Optional reset"
      assert has_element?(view, "button[data-accept-rest-suggestion]")

      view
      |> element("button[data-accept-rest-suggestion]")
      |> render_click()

      assert has_element?(view, "#workout-outline")
      refute has_element?(view, "#plan-prescription-timeline")
      refute render(view) =~ "Optional reset"
    end

    test "changing to one rep after accepting rest suggestion shows an error instead of crashing",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "144"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      view
      |> element("button[data-accept-rest-suggestion]")
      |> render_click()

      html =
        view
        |> element("#plan-goal-controls")
        |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "1"})

      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "Rest at minute 12"
    end

    test "accepting reset suggestion twice does not create duplicate same-minute rests", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "160"})

      view
      |> element("button[data-accept-rest-suggestion]")
      |> render_click()

      html = render(view)
      assert has_element?(view, "#workout-outline")
      refute html =~ ~s(id="plan-prescription-timeline")
    end

    test "outline replaces graph interactions for generated plans", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "144"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "20:00 · 144 reps · 18 sets"
      assert html =~ "15s recovery"
      assert html =~ "90s recovery"
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ ~s(id="graph-inspector")
      refute html =~ "[data-timeline-rest-editor]"
    end

    test "existing grouped plan shows block pattern editor", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Grouped Plan"})
      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#block-pattern-editor")
      assert html =~ "Block pattern"
      assert html =~ "30 reps/block"
      refute html =~ "Show structure"
      refute html =~ "Adjust sets"
    end

    test "generated even plan keeps pace populated on edit", %{conn: conn, user: user} do
      input = %BurpeeTrainer.PlanSolver.Input{
        name: "Catch-up Six-count 1",
        burpee_type: :six_count,
        target_duration_min: 20,
        burpee_count_target: 120,
        pacing_style: :even,
        level: :level_1c,
        block_pattern: [12]
      }

      {:ok, solution} = BurpeeTrainer.PlanSolver.solve(input)

      plan =
        plan_fixture(user, %{
          "name" => solution.plan.name,
          "burpee_type" => Atom.to_string(solution.plan.burpee_type),
          "target_duration_min" => solution.plan.target_duration_min,
          "burpee_count_target" => solution.plan.burpee_count_target,
          "sec_per_burpee" => solution.plan.sec_per_burpee,
          "pacing_style" => Atom.to_string(solution.plan.pacing_style),
          "blocks" =>
            Enum.map(solution.plan.blocks, fn block ->
              %{
                "position" => block.position,
                "repeat_count" => block.repeat_count,
                "sets" =>
                  Enum.map(block.sets, fn set ->
                    %{
                      "position" => set.position,
                      "burpee_count" => set.burpee_count,
                      "sec_per_rep" => set.sec_per_rep,
                      "sec_per_burpee" => set.sec_per_burpee,
                      "end_of_set_rest" => set.end_of_set_rest
                    }
                  end)
              }
            end),
          "steps" =>
            Enum.map(solution.plan.steps, fn step ->
              %{
                "position" => step.position,
                "kind" => Atom.to_string(step.kind),
                "block_position" => step.block_position,
                "repeat_count" => step.repeat_count,
                "rest_sec" => step.rest_sec
              }
            end)
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#plan-prescription-pace", "6.0s")
      refute has_element?(view, "#plan-prescription-pace", "—")

      assert has_element?(view, ~s(#plan-pace-form input[name="pace"][value="6.0"]))
      refute has_element?(view, ~s(#plan-pace-form input[name="pace"][value=""]))
      assert has_element?(view, "#workout-outline")
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
      {:ok, _view, html} = live(conn, ~p"/workouts/new")

      assert html =~ "session-surface"
      assert html =~ ~s(id="plan-form")
      assert html =~ "Custom session"
      assert html =~ "Type"
      assert html =~ "Duration"
      assert html =~ "Goal"
      assert html =~ "Style"
      assert html =~ "Prescription"
      assert html =~ "Workout"
      assert html =~ "Block pattern"
      refute html =~ "Show structure"
      assert html =~ ~s(id="workout-outline")
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ ~s(data-timeline-primary-graph)
      refute html =~ ~s(data-timeline-edge-action)
      refute html =~ ~s(data-timeline-block-node)
      assert html =~ "Six-Count"
      assert html =~ "Navy SEAL"
      assert html =~ "Create session"
      refute html =~ ">Reps<"
      refute html =~ ">Pace<"
    end

    test "invalid manual prescription shows actionable feedback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-form")
      |> render_change(%{
        "workout_plan" => %{
          "blocks" => %{
            "0" => %{
              "position" => "1",
              "repeat_count" => "1",
              "sets" => %{
                "0" => %{
                  "position" => "1",
                  "burpee_count" => "1",
                  "sec_per_rep" => "5.0",
                  "sec_per_burpee" => "5.0",
                  "end_of_set_rest" => "0"
                }
              }
            }
          }
        }
      })

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "Prescription does not match target"
      assert html =~ "Reps are 1"
      refute html =~ ">—<"
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
      refute html =~ "No runnable prescription yet"
      assert html =~ "Workout"
      refute html =~ "Predicted finish"
    end

    test "impossible prescription shows actionable feedback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "1", "burpee_count_target" => "200"})

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "No workable prescription"
      assert html =~ "needs at least"
      assert html =~ "Increase the duration"
      assert html =~ "Reduce the rep target"
      assert html =~ "No runnable prescription yet"
      refute html =~ "Recommended"
      refute html =~ "Prescription graph"
      refute html =~ "Predicted finish"
    end

    test "impossible prescription cannot be saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "1", "burpee_count_target" => "200"})

      assert has_element?(view, "button[form='plan-form'][disabled]")

      html =
        view
        |> element("#plan-form")
        |> render_submit(%{"workout_plan" => %{}})

      assert html =~ "Fix prescription before saving"
      assert has_element?(view, "#plan-form")
    end

    test "new editor uses block pattern instead of show structure", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "#block-pattern-editor")
      assert html =~ "Block pattern"
      refute html =~ "Show structure"
      refute html =~ "Segment 1"
    end

    test "unbroken awkward targets show actual final set reps", %{conn: conn, user: user} do
      sets =
        for position <- 1..10 do
          %{
            "position" => position,
            "burpee_count" => 10,
            "sec_per_rep" => 5.5,
            "sec_per_burpee" => 5.5,
            "end_of_set_rest" => 61
          }
        end ++
          [
            %{
              "position" => 11,
              "burpee_count" => 7,
              "sec_per_rep" => 5.5,
              "sec_per_burpee" => 5.5,
              "end_of_set_rest" => 0
            }
          ]

      plan =
        plan_fixture(user, %{
          "name" => "Awkward 107",
          "burpee_type" => "six_count",
          "target_duration_min" => 20,
          "burpee_count_target" => 107,
          "pacing_style" => "unbroken",
          "blocks" => [%{"position" => 1, "repeat_count" => 1, "sets" => sets}]
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ "Block pattern"
      assert has_element?(view, "#workout-outline")
      refute html =~ "Show structure"
    end

    test "picking Navy SEAL keeps the editor rendered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-click='pick_type'][phx-value-type='navy_seal']")
      |> render_click()

      html = render(view)
      assert html =~ "Navy SEAL"
      assert html =~ ~s(id="plan-form")
    end
  end
end
