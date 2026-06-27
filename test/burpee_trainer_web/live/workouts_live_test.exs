defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  defp open_advanced_constraints(view) do
    view |> element("#advanced-constraints-toggle") |> render_click()
    view
  end

  defp classes_for(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree(skip_whitespace_nodes: true)
    |> Enum.map(fn {_, attrs, _children} ->
      attrs |> Map.new() |> Map.get("class", "")
    end)
  end

  defp texts_for(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree(skip_whitespace_nodes: true)
    |> Enum.map(&node_text/1)
  end

  defp feedback_buttons(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#plan-solver-impossible button")
    |> LazyHTML.to_tree(skip_whitespace_nodes: true)
    |> Enum.map(fn {_, attrs, children} ->
      {Map.new(attrs), node_text(children)}
    end)
  end

  defp enabled_unimplemented_feedback_actions(html) do
    html
    |> feedback_buttons()
    |> Enum.reject(fn {_attrs, text} -> text =~ "Rebalance unlocked blocks" end)
    |> Enum.reject(fn {attrs, _text} -> Map.has_key?(attrs, "disabled") end)
    |> Enum.map(fn {_attrs, text} -> String.trim(text) end)
  end

  defp node_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, " ", &node_text/1)
  defp node_text({_tag, _attrs, children}), do: node_text(children)
  defp node_text(text) when is_binary(text), do: text

  defp generate_workout(view) do
    view |> element("#generate-workout") |> render_click()
    view |> element("#edit-workout") |> render_click()
    open_advanced_constraints(view)
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

    test "existing plan edit page opens directly to editor overview", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Readable Edit"})

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      assert has_element?(view, "#workout-editor-overview")
      assert html =~ "Edit workout"
      assert html =~ "Readable Edit"
      assert html =~ "Custom workout"
      assert html =~ "Save workout"
      refute html =~ "Custom session"
      refute html =~ "Save session"
      assert has_element?(view, "[data-workout-block-row]")
      refute html =~ "Prescription graph"
    end

    test "existing workout Start submits visible edits before session navigation", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Start Saves Edits",
          "target_duration_min" => 2,
          "burpee_count_target" => 17,
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 10,
                  "sec_per_rep" => 7.5,
                  "sec_per_burpee" => 7.5,
                  "end_of_set_rest" => 45
                }
              ]
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "reps" => "17",
          "sec_per_rep" => "4.2",
          "rest_sec" => "45"
        }
      })

      assert has_element?(view, "#editor-save-start-form #editor-start-workout[type='submit']")
      view |> form("#editor-save-start-form", %{}) |> render_submit()
      assert_redirect(view, ~p"/session/#{plan.id}")

      updated = BurpeeTrainer.Workouts.get_plan!(user, plan.id)
      [first_block | _] = Enum.sort_by(updated.blocks, & &1.position)
      [first_set | _] = Enum.sort_by(first_block.sets, & &1.position)

      assert first_set.burpee_count == 17
      assert_in_delta first_set.sec_per_rep, 4.2, 0.01
      assert first_set.end_of_set_rest == 45
    end

    test "workout outline renders block summary without duplicated graph", %{
      conn: conn,
      user: user
    } do
      plan = plan_fixture(user, %{"name" => "Timeline Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

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
      open_advanced_constraints(view)

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

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

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

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

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

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

      assert has_element?(view, "#workout-outline")
      assert html =~ "70 reps"
      assert html =~ "20 sets"
      refute html =~ "Block 1 · 6 × Block 1"
    end

    test "generated unbroken outline renders executable steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "200"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "5"})
      generate_workout(view)

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "200 reps"
      assert html =~ "8s recovery"
      refute html =~ ~s(id="plan-prescription-timeline")
    end

    test "removed timeline does not offer invalid rest near finish", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "144"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "8"})
      generate_workout(view)

      refute has_element?(view, "[data-timeline-edge-action][phx-value-target-min='19']")
      refute has_element?(view, "#plan-prescription-timeline")
    end

    test "block pattern editor reruns solver", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("button[phx-value-type='navy_seal']") |> render_click()

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "70"
      })

      generate_workout(view)
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
      generate_workout(view)

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
      generate_workout(view)

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

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "70"
      })

      generate_workout(view)
      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      flash = assert_redirect(view, ~p"/workouts")
      assert flash["info"] == "Workout created."

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      plan = BurpeeTrainer.Workouts.get_plan!(user, plan.id)

      assert Enum.map(plan.blocks, fn block -> Enum.map(block.sets, & &1.burpee_count) end) == [
               [4, 3]
             ]

      assert [%{kind: :block_run, repeat_count: 10}] = plan.steps
      assert metadata_value(plan.plan_solver_metadata, :solver_version) == 3
      assert metadata_value(plan.plan_solver_metadata, :structure_key) == "10x[4,3]"
    end

    test "new plan renders normalized workout outline instead of solver-fragment blocks", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "144"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "8"})
      generate_workout(view)

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "20:00 · 144 reps · 18 sets"
      assert html =~ "18 sets × 8 reps"
      assert html =~ "Sets 1–11"
      assert html =~ "Set 12"
      assert html =~ "Sets 13–16"
      assert html =~ "Set 17"
      assert html =~ "No recovery"
    end

    test "new even plan explains cadence recommendation without reset suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "160"
      })

      generate_workout(view)
      html = render(view)
      assert html =~ "Recommended"
      assert html =~ "even cadence"
      refute html =~ "Optional reset"
      refute has_element?(view, "button[data-accept-rest-suggestion]")
      assert has_element?(view, "#workout-outline")
      refute has_element?(view, "#plan-prescription-timeline")
    end

    test "outline replaces graph interactions for generated plans", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "144"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      generate_workout(view)
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#workout-outline")
      assert html =~ "20:00 · 144 reps · 18 sets"
      assert html =~ "20s recovery"
      assert html =~ "60s recovery"
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ ~s(id="graph-inspector")
      refute html =~ "[data-timeline-rest-editor]"
    end

    test "existing grouped plan shows block pattern editor", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Grouped Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

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
      open_advanced_constraints(view)

      assert has_element?(view, "#plan-prescription-pace", "5.3s")
      refute has_element?(view, "#plan-prescription-pace", "—")

      assert has_element?(view, ~s(#plan-pace-form input[name="pace"][value="5.3"]))
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

      {path, flash} = assert_redirect(view)
      assert path =~ ~r"/workouts/\d+/edit"
      refute path == "/workouts/#{plan.id}/edit"
      assert flash["info"] == "Workout copied."
    end

    test "deleting a plan from the edit page returns to workouts", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      view |> element("#plan-delete") |> render_click()

      flash = assert_redirect(view, "/workouts")
      assert flash["info"] == "Workout deleted."
    end

    test "video card has no edit link", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})
      {:ok, _view, html} = live(conn, ~p"/workouts")

      refute html =~ ~r"/workouts/\d+/edit"
    end
  end

  describe "/workouts/new" do
    test "new workout opens as an intent-first creator, not a solver panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "#creator-intent-screen")
      assert html =~ "Create workout"
      assert html =~ "What are we doing?"
      assert html =~ "Six-count"
      assert html =~ "Navy SEAL"
      assert html =~ "20 min"
      assert html =~ "30 min"
      assert html =~ "Planned workout"
      assert html =~ "Catch up"
      assert html =~ "Easy technique"
      assert html =~ "Max reps"
      assert html =~ "Difficulty"
      assert html =~ "Generate workout"

      refute html =~ "Block pattern"
      refute html =~ "Prescription graph"
      refute html =~ "Solver computes"
      refute html =~ ">Pace<"
    end

    test "generated review shows a readable workout contract before block data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()

      html = render(view)
      assert has_element?(view, "#workout-contract-review")
      assert html =~ "20 min Six-count"
      assert html =~ "reps ·"
      assert html =~ "block"
      assert html =~ "Expected feel:"
      assert has_element?(view, "[data-structure-map]")
      assert has_element?(view, "#start-workout")
      assert has_element?(view, "#edit-workout")

      refute html =~ "Block pattern"
      refute html =~ "Prescription graph"
      refute html =~ "Solver computes"
    end

    test "editor overview is readable block cards, not a field table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()

      html = render(view)
      assert has_element?(view, "#workout-editor-overview")
      assert html =~ "Edit workout"
      assert html =~ "20 min Six-count"
      assert html =~ "reps ·"
      assert html =~ "block"
      assert has_element?(view, "[data-structure-map]")
      assert has_element?(view, "[data-workout-block-row]")
      assert html =~ "Rep every"
      assert html =~ "rest"
      assert html =~ "Rebalance unlocked blocks"

      refute html =~ "Prescription graph"
      refute html =~ "Solver computes"
      refute html =~ ">Pace<"
    end

    test "selecting a block opens a focused edit sheet and locking labels the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()
      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      assert has_element?(view, "#block-edit-sheet")
      html = render(view)
      assert html =~ "Reps"
      assert html =~ "Seconds per rep"
      assert html =~ "Rest after"
      assert html =~ "Lock this block pattern"
      assert html =~ "Duplicate"
      assert html =~ "Delete block"
      assert has_element?(view, "#block-delete[disabled][aria-disabled='true']")

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "reps" => "17",
          "sec_per_rep" => "4.2",
          "rest_sec" => "45"
        }
      })

      html = render(view)
      assert html =~ "Locked by you"
      assert html =~ "17 reps"
      assert html =~ "Rep every 4.2s"
      assert html =~ "0:45 rest"
    end

    test "locking a repeated block row uses the source block index", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Repeated Row Lock",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 3,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 10,
                  "sec_per_rep" => 6.0,
                  "sec_per_burpee" => 6.0,
                  "end_of_set_rest" => 30
                }
              ]
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      view |> element("[data-workout-block-row][phx-value-index='1']") |> render_click()

      assert has_element?(
               view,
               "#block-sheet-form input[name='block[source_block_index]'][value='0']"
             )

      view |> element("#block-lock-toggle") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "reps" => "19",
          "sec_per_rep" => "4.4",
          "rest_sec" => "50"
        }
      })

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Locked by you"
      assert first_row_text =~ "19 reps"
      assert length(Regex.scan(~r/Locked by you/, html)) > 1

      view |> element("#rebalance-unlocked-blocks") |> render_click()

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Locked by you"
      assert first_row_text =~ "19 reps"
    end

    test "editor overview keeps one primary CTA while save remains available", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()

      html = render(view)

      primary_actions =
        html
        |> classes_for("a, button")
        |> Enum.count(fn classes ->
          classes |> String.split() |> Enum.member?("bg-[var(--session-ink)]")
        end)

      assert primary_actions == 1
      assert has_element?(view, "#editor-start-workout")
      assert has_element?(view, "#editor-save-session[form='plan-form']")
      assert html =~ "Create workout"
      refute html =~ "Create session"

      [save_classes] = classes_for(html, "#editor-save-session")
      save_class_tokens = String.split(save_classes)
      assert "border" in save_class_tokens
      refute "bg-[var(--session-ink)]" in save_class_tokens
    end

    test "invalid editor overview shows feedback and disables Start before advanced is opened", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()

      render_change(view, "change_basics", %{
        "target_duration_min" => "1",
        "burpee_count_target" => "200"
      })

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "This cannot fit in 1:00"
      assert html =~ "The locked blocks and rests exceed the duration."
      assert html =~ "Show locked blocks"
      assert html =~ "Unlock all"
      assert html =~ "Allow longer workout"
      assert html =~ "Undo"
      assert enabled_unimplemented_feedback_actions(html) == []
      refute html =~ "No runnable prescription yet"
      refute html =~ "No workable prescription"
      assert has_element?(view, "#editor-start-workout[disabled]")
      refute html =~ ~s(id="advanced-constraints-panel")
    end

    test "advanced constraints are collapsed until requested", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "#advanced-constraints-toggle")
      refute html =~ ~s(id="advanced-constraints-panel")

      view |> element("#advanced-constraints-toggle") |> render_click()

      assert has_element?(view, "#advanced-constraints-panel")
      html = render(view)
      assert html =~ "Manual target reps"
      assert html =~ "Unbroken cap"
      assert html =~ "Minimum rest"
      assert html =~ "Maximum pace"
      assert html =~ "Solver strictness"
    end

    test "advanced constraints toggle exposes collapsed and expanded state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      assert has_element?(
               view,
               "#advanced-constraints-toggle[aria-controls='advanced-constraints-panel'][aria-expanded='false']"
             )

      view |> element("#advanced-constraints-toggle") |> render_click()

      assert has_element?(view, "#advanced-constraints-toggle[aria-expanded='true']")
      assert has_element?(view, "#advanced-constraints-panel")
    end

    test "invalid manual prescription shows actionable feedback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

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
                  "burpee_count" => "200",
                  "sec_per_rep" => "6.21",
                  "sec_per_burpee" => "6.21",
                  "end_of_set_rest" => "0"
                }
              }
            }
          }
        }
      })

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "Workout no longer fits 20:00"
      assert html =~ "You are 0:42 over."
      assert html =~ "Rebalance unlocked blocks"
      assert html =~ "Keep 20:42"
      assert html =~ "Undo change"
      assert enabled_unimplemented_feedback_actions(html) == []
      refute html =~ ">—<"
    end

    test "aggressive impossible prescription explains alternatives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "300"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "This cannot fit in 20:00"
      assert html =~ "The locked blocks and rests exceed the duration."
      assert html =~ "Allow longer workout"
      refute html =~ "No runnable prescription yet"
      refute html =~ "No workable prescription"
      refute html =~ "Prescription graph"
      refute html =~ "Predicted finish"
    end

    test "impossible prescription uses product conflict copy and actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      render_change(view, "change_basics", %{
        "target_duration_min" => "1",
        "burpee_count_target" => "200"
      })

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "This cannot fit in 1:00"
      assert html =~ "The locked blocks and rests exceed the duration."
      assert html =~ "Show locked blocks"
      assert html =~ "Unlock all"
      assert html =~ "Allow longer workout"
      assert html =~ "Undo"
      assert enabled_unimplemented_feedback_actions(html) == []
      refute html =~ "No runnable prescription yet"
      refute html =~ "No workable prescription"
      refute html =~ "Recommended"
      refute html =~ "Prescription graph"
      refute html =~ "Predicted finish"
    end

    test "impossible prescription cannot be saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      render_change(view, "change_basics", %{
        "target_duration_min" => "1",
        "burpee_count_target" => "200"
      })

      assert has_element?(view, "button[form='plan-form'][disabled]")

      html =
        view
        |> element("#plan-form")
        |> render_submit(%{"workout_plan" => %{}})

      assert html =~ "This cannot fit in 1:00"
      assert html =~ "The locked blocks and rests exceed the duration."
      assert has_element?(view, "#plan-form")
    end

    test "generated workout review uses block pattern instead of show structure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      html = render(view)
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

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

      assert html =~ "Block pattern"
      assert has_element?(view, "#workout-outline")
      refute html =~ "Show structure"
    end

    test "picking Navy SEAL keeps creator usable before generated editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-click='pick_type'][phx-value-type='navy_seal']")
      |> render_click()

      html = render(view)
      assert html =~ "Navy SEAL"
      assert has_element?(view, "#creator-intent-screen")

      generate_workout(view)
      assert has_element?(view, "#plan-form")
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata || %{}, key) || Map.get(metadata || %{}, Atom.to_string(key))
  end
end
