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

    test "prescription timeline renders block nodes with timing", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Timeline Plan"})
      {:ok, _view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ ~s(id="plan-prescription-timeline")
      assert html =~ ~s(data-timeline-block-node)
      assert html =~ "0:00"
      assert html =~ "Block 1"
      assert html =~ "30 reps"
      assert html =~ "3 sets"
      assert html =~ "4:00"
      refute html =~ "2 × 30s recovery"
    end

    test "block timeline node expands set children and edits a set", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Timeline Edit Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view
      |> element("[data-timeline-row-index='1'] [data-timeline-block-toggle]")
      |> render_click()

      assert has_element?(view, "[data-timeline-set-node]")
      assert has_element?(view, "[data-timeline-set-editor]")
      html = render(view)
      assert html =~ "Set 1"
      assert html =~ "Reps"
      assert html =~ "Pace"
      assert html =~ "Recovery"

      view
      |> element("[data-timeline-set-editor='0-0']")
      |> render_change(%{
        "set" => %{
          "block_index" => "0",
          "set_index" => "0",
          "burpee_count" => "12",
          "sec_per_rep" => "5.5",
          "end_of_set_rest" => "20"
        }
      })

      html = render(view)
      assert has_element?(view, "[data-timeline-set-editor='0-0']")
      assert html =~ "Set 1"
      assert html =~ "12 reps"
      assert html =~ "5.5s/rep"
      assert html =~ "20s recovery"
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

      {:ok, _view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ "Block 1"
      assert html =~ "180 reps"
      assert html =~ "+10s recovery"
      assert html =~ "Block 1 continued"
      assert html =~ "20 reps"
      assert html =~ "20:10"
    end

    test "timeline splits repeated block around additional rest", %{conn: conn, user: user} do
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

      {:ok, _view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ "6 × Block 1"
      assert html =~ "42 reps"
      assert html =~ "+10s recovery"
      assert html =~ "4 × Block 1"
      assert html =~ "28 reps"
      assert html =~ "20:10"
      refute html =~ "Block 1 · 6 × Block 1"
    end

    test "generated unbroken timeline renders executable steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "200"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "5"})

      view
      |> element("[data-timeline-edge-index='1'][data-timeline-edge-action]")
      |> render_click()

      view
      |> element("[data-timeline-rest-editor]")
      |> render_change(%{"rest" => %{"index" => "1", "rest_sec" => "10", "target_min" => "18"}})

      html = render(view)
      assert html =~ "180 reps"
      assert html =~ "+10s recovery"
      assert html =~ "4 × Block 1 · 20 reps"
      assert html =~ "20:00"
      refute html =~ "20:10"
      refute html =~ "2 × Block 1 · 10 reps"
      refute html =~ "34 × Block 1 · 170 reps"
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

    test "generated even timeline accepts rest by recalculating cadence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-value-type='navy_seal']")
      |> render_click()

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "70"})

      view
      |> element("[data-timeline-edge-index='1'][data-timeline-edge-action]")
      |> render_click()

      view
      |> element("[data-timeline-rest-editor]")
      |> render_change(%{"rest" => %{"index" => "1", "rest_sec" => "20", "target_min" => "12"}})

      html = render(view)
      assert html =~ "+20s recovery"
      assert html =~ "20:00"
      refute html =~ "Rest cannot be placed at minute 12"
    end

    test "generated timeline rejects impossible rest placement", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#plan-goal-controls")
      |> render_change(%{"target_duration_min" => "20", "burpee_count_target" => "200"})

      view
      |> element("button[phx-value-style='unbroken']")
      |> render_click()

      render_change(view, "change_basics", %{"reps_per_set" => "7"})

      view
      |> element("[data-timeline-edge-index='1'][data-timeline-edge-action]")
      |> render_click()

      view
      |> element("[data-timeline-rest-editor]")
      |> render_change(%{"rest" => %{"index" => "1", "rest_sec" => "10", "target_min" => "18"}})

      html = render(view)
      assert html =~ "Rest cannot be placed at minute 18"
      refute html =~ "+10s recovery"
    end

    test "timeline add rest handle injects editable rest node", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "[data-timeline-edge-action]")

      view
      |> element("[data-timeline-edge-index='0'][data-timeline-edge-action]")
      |> render_click()

      assert has_element?(view, "[data-timeline-rest-node]")
      assert has_element?(view, "[data-timeline-rest-editor]")
      assert has_element?(view, "[data-timeline-remove-rest]")
      html = render(view)
      assert html =~ "+30s recovery"
      assert html =~ "at minute"

      view
      |> element("[data-timeline-rest-editor]")
      |> render_change(%{"rest" => %{"index" => "0", "rest_sec" => "45", "target_min" => "8"}})

      html = render(view)
      assert html =~ "+45s recovery"
      refute html =~ "Rest cannot be placed at minute 8"

      view |> element("[data-timeline-remove-rest]") |> render_click()
      refute render(view) =~ "+45s recovery"
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
      assert html =~ "Predicted"
      assert html =~ "Block pattern"
      refute html =~ "Show structure"
      assert html =~ ~s(id="plan-prescription-timeline")
      assert html =~ ~s(data-timeline-primary-graph)
      assert html =~ ~s(data-timeline-edge)
      assert html =~ "left-[5.625rem]"
      assert html =~ ~s(data-timeline-edge-action)
      assert html =~ ~s(data-timeline-block-node)
      assert html =~ "Start"
      assert html =~ "Finish"
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

      {:ok, _view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert html =~ "10×"
      assert html =~ "10</span>"
      assert html =~ "1×"
      assert html =~ "7</span>"
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
