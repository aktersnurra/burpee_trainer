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
    |> Enum.reject(fn {_attrs, text} -> text =~ "Balance remaining work" end)
    |> Enum.reject(fn {attrs, _text} -> Map.has_key?(attrs, "disabled") end)
    |> Enum.map(fn {_attrs, text} -> String.trim(text) end)
  end

  defp node_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, " ", &node_text/1)
  defp node_text({_tag, _attrs, children}), do: node_text(children)
  defp node_text(text) when is_binary(text), do: text

  defp generate_workout(view) do
    view |> element("#generate-workout") |> render_click()
    view |> element("#edit-workout") |> render_click()
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

    test "existing plan name edit does not regenerate saved structure", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Keep Structure",
          "target_duration_min" => 2,
          "burpee_count_target" => 10,
          "pacing_style" => "even",
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

      view
      |> element("form[phx-change='change_basics']")
      |> render_change(%{"name" => "Renamed Structure"})

      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      assert_redirect(view, ~p"/workouts")

      source_json = plan.source_json
      execution_program_id = plan.current_execution_program_id
      updated = BurpeeTrainer.Workouts.get_plan!(user, plan.id)

      assert updated.name == "Renamed Structure"
      assert Map.drop(updated.source_json, ["pace_bias", "load_shape"]) == source_json
      assert updated.source_json["pace_bias"] == "balanced"
      assert updated.source_json["load_shape"] == "even"
      assert updated.current_execution_program_id == execution_program_id
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
          "block_pattern" => [17],
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 17,
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
          "repeat_count" => "1",
          "sets" => %{
            "0" => %{"burpee_count" => "17", "sec_per_rep" => "4.2", "end_of_set_rest" => "45"}
          }
        }
      })

      assert has_element?(view, "#editor-save-start-form #editor-start-workout[type='submit']")
      view |> form("#editor-save-start-form", %{}) |> render_submit()
      assert_redirect(view, ~p"/session/#{plan.id}")

      updated = BurpeeTrainer.Workouts.get_plan!(user, plan.id)
      assert updated.source_json["block_pattern"] == [17]
      assert updated.source_json["target_reps"] == 17
      assert updated.source_json["sec_per_rep_override"] == 4.2
      assert updated.current_execution_program_id
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

    test "generated unbroken editor renders readable block rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "200"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "5"})
      generate_workout(view)

      html = render(view)
      assert has_element?(view, "#workout-editor-overview")
      assert has_element?(view, "[data-workout-block-row]")
      assert html =~ "200 reps"
      assert html =~ "Rep every"
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ "Tune details"
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

    test "existing manual structure editor reruns solver", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Manual structure source",
          "burpee_type" => "navy_seal",
          "target_duration_min" => 20,
          "burpee_count_target" => 70
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})

      html = render(view)
      assert html =~ "70 reps"
      assert html =~ "20:00"
      assert html =~ "7 reps/block"
      assert html =~ "10×"
      assert html =~ ~s(value="4")
      assert html =~ ~s(value="3")
    end

    test "manual structure set can be removed on saved edit pages", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Manual structure remove"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})
      assert has_element?(view, "button[data-remove-pattern-set][phx-value-index='1']")

      view
      |> element("button[data-remove-pattern-set][phx-value-index='1']")
      |> render_click()

      html = render(view)
      assert html =~ "4 reps/block"
      refute html =~ ~s(name="pattern[1]")
    end

    test "visible pace control exposes editable pace override on saved edit pages", %{
      conn: conn,
      user: user
    } do
      plan = plan_fixture(user, %{"name" => "Pace override"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)

      assert has_element?(view, "#plan-pace-form input[name='pace']")
      refute has_element?(view, "#graph-inspector")
      assert render(view) =~ "Automatic"
      refute render(view) =~ "Recovery · 0s auto"

      view
      |> element("#plan-pace-form")
      |> render_change(%{"pace" => "6.4"})

      html = render(view)
      assert html =~ "Manual pace"
      assert html =~ ~s(value="6.4")
    end

    test "saves generated plan and reloads current execution program", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("button[phx-value-type='navy_seal']") |> render_click()

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "70"
      })

      generate_workout(view)

      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      flash = assert_redirect(view, ~p"/workouts")
      assert flash["info"] == "Workout created."

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      plan = BurpeeTrainer.Workouts.get_plan!(user, plan.id)

      assert plan.burpee_count_target == 70
      assert plan.burpee_type == :navy_seal
      assert plan.source_json["target_reps"] == 70
      assert plan.source_json["target_duration_sec"] == 1_200
      assert plan.source_json["burpee_type"] == "navy_seal"
      assert plan.current_execution_program_id

      program = BurpeeTrainer.ExecutionPrograms.get!(plan.current_execution_program_id)
      assert program.solver_version == 4
      assert program.target_reps == 70
      assert program.target_duration_sec == 1_200
    end

    test "new workout editor accepts submitted source JSON and compiles current program", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      view
      |> element("#plan-form")
      |> render_submit(%{
        "workout_plan" => %{
          "name" => "Posted source",
          "source_json" => %{
            "burpee_type" => "six_count",
            "target_reps" => 100,
            "target_duration_sec" => 1_200,
            "pacing_style" => "even",
            "block_pattern" => [10],
            "explicit_rests" => [],
            "pace_bias" => "slower",
            "load_shape" => "front_loaded",
            "sec_per_rep_override" => 6.0
          }
        }
      })

      assert_redirect(view, ~p"/workouts")

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      assert plan.name == "Posted source"
      assert plan.source_json["target_reps"] == 100
      assert plan.source_json["target_duration_sec"] == 1_200
      assert plan.source_json["block_pattern"] == [10]
      assert plan.source_json["pace_bias"] == "slower"
      assert plan.source_json["load_shape"] == "front_loaded"
      assert plan.source_json["sec_per_rep_override"] == 6.0
      assert plan.current_execution_program_id
    end

    test "submitted source JSON preserves all compiler fields", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      view
      |> element("#plan-form")
      |> render_submit(%{
        "workout_plan" => %{
          "name" => "Posted unbroken source",
          "source_json" => %{
            "burpee_type" => "six_count",
            "target_reps" => 100,
            "target_duration_sec" => 900,
            "pacing_style" => "unbroken",
            "max_unbroken_reps" => 5,
            "block_pattern" => [5],
            "explicit_rests" => [],
            "pace_bias" => "slower",
            "load_shape" => "front_loaded"
          }
        }
      })

      assert_redirect(view, ~p"/workouts")

      [plan | _] = BurpeeTrainer.Workouts.list_plans(user)
      assert plan.name == "Posted unbroken source"
      assert plan.pacing_style == :unbroken
      assert plan.source_json["pacing_style"] == "unbroken"
      assert plan.source_json["max_unbroken_reps"] == 5
      assert plan.source_json["pace_bias"] == "slower"
      assert plan.source_json["load_shape"] == "front_loaded"
      assert plan.current_execution_program_id
    end

    test "new plan renders readable editor rows instead of solver-fragment blocks", %{
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
      assert has_element?(view, "#workout-editor-overview")
      assert has_element?(view, "[data-workout-block-row]")
      assert html =~ "20:00 · Six-count"
      assert html =~ "144 reps"
      assert html =~ "Rep every"
      refute html =~ "Tune details"
      refute html =~ ~s(id="plan-prescription-timeline")
    end

    test "new even plan explains pace recommendation without reset suggestions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "160"
      })

      view |> element("#generate-workout") |> render_click()
      html = render(view)
      assert html =~ "Even"
      refute html =~ "Optional reset"
      refute has_element?(view, "button[data-accept-rest-suggestion]")
      assert has_element?(view, "#workout-contract-review")
      refute has_element?(view, "#plan-prescription-timeline")
    end

    test "editor rows replace graph interactions for generated plans", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "20",
        "burpee_count_target" => "144"
      })

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      generate_workout(view)
      render_change(view, "change_basics", %{"reps_per_set" => "8"})

      html = render(view)
      assert has_element?(view, "#workout-editor-overview")
      assert has_element?(view, "[data-workout-block-row]")
      assert html =~ "144 reps"
      assert html =~ "Rep every"
      refute html =~ ~s(id="plan-prescription-timeline")
      refute html =~ ~s(id="graph-inspector")
      refute html =~ "[data-timeline-rest-editor]"
      refute html =~ "Tune details"
    end

    test "existing grouped plan shows manual structure editor", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Grouped Plan"})
      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      open_advanced_constraints(view)
      html = render(view)

      assert has_element?(view, "#block-pattern-editor")
      assert html =~ "Manual structure"
      assert html =~ "30 reps/block"
      refute html =~ "Show structure"
      refute html =~ "Adjust sets"
    end

    test "generated even plan keeps pace populated on edit", %{conn: conn, user: user} do
      input = %BurpeeTrainer.PlanSolver.Input{
        name: "Catch-up Six-count 1",
        burpee_type: :six_count,
        target_duration_sec: 1_200,
        burpee_count_target: 120,
        pacing_style: :even,
        level: :level_1c,
        block_pattern: [12]
      }

      {:ok, solution} = BurpeeTrainer.PlanSolver.generate_plan(input)

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

    test "plan edit page does not depend on removed legacy solver metadata", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Coach Six-count",
          "coach_suggestion_kind" => "recommended",
          "coach_target_reps" => 150
        })

      {:ok, view, html} = live(conn, ~p"/workouts/#{plan.id}/edit")

      refute has_element?(view, "#plan-metadata")
      assert html =~ "Coach Six-count"
      assert has_element?(view, "#workout-editor-overview")
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
    test "new workout can be named before saving", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#workout-name-form")
      |> render_change(%{"name" => "Morning plan"})

      generate_workout(view)
      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      assert_redirect(view, ~p"/workouts")

      assert [plan] = BurpeeTrainer.Workouts.list_plans(user)
      assert plan.name == "Morning plan"
    end

    test "new workout opens as a training-contract creator, not a solver panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      assert has_element?(view, "#creator-intent-screen")
      assert html =~ "Create workout"
      assert html =~ "Choose the target. Review the structure before starting."
      assert html =~ "Six-count"
      assert html =~ "Navy SEAL"
      assert html =~ "Target"
      assert html =~ "Format"
      assert html =~ "Even"
      assert html =~ "Unbroken sets"
      assert html =~ "Structure"
      assert html =~ "Let planner choose"
      assert html =~ "Repeating pattern"
      refute html =~ "Steady reps"
      assert html =~ "Feel"
      assert html =~ "Slower"
      assert html =~ "Balanced"
      assert html =~ "Faster"
      assert html =~ "Load"
      assert html =~ "Flat"
      assert html =~ "Front-loaded"
      assert html =~ "Back-loaded"
      assert html =~ "Generate workout"
      assert has_element?(view, "#pace-bias-form button[phx-value-bias='faster']")
      assert has_element?(view, "button[phx-value-shape='front_loaded']")

      refute has_element?(view, "#pace-bias-form input[type='range']")
      refute html =~ "Build a training contract"
      refute html =~ "Style"
      refute html =~ "Shape"
      refute html =~ "Even pace"
      refute html =~ "Tuning"
      refute html =~ "Tune details"
      refute html =~ "20:00 default"
      refute html =~ "30:00"
      refute html =~ "Faster means denser work"
      refute html =~ "Custom workout"
      refute html =~ "Catch up"
      refute html =~ "Easy technique"
      refute html =~ "Max reps"
      refute html =~ "Block pattern"
      refute html =~ "Prescription graph"
      refute html =~ "Solver computes"
    end

    test "creator exposes the target-count maximum for unbroken set size", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("#creator-contract-form")
      |> render_change(%{"burpee_count_target" => "200"})

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      html = render(view)

      assert has_element?(view, "#plan-pacing-controls input[name='reps_per_set'][max='200']")
      assert html =~ "Max per set"

      render_change(view, "change_basics", %{"reps_per_set" => "200"})
      html = render(view)

      assert has_element?(view, "#plan-pacing-controls input[name='reps_per_set'][value='200']")
      assert html =~ "200 reps max"
    end

    test "creator can prefer a repeating structure pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_click(view, "pick_type", %{"type" => "navy_seal"})

      view
      |> element("#creator-contract-form")
      |> render_change(%{"burpee_count_target" => "70"})

      view |> element("#structure-pattern-mode") |> render_click()

      view
      |> element("#creator-structure-form")
      |> render_change(%{"pattern" => %{"0" => "4", "1" => "3"}})

      html = render(view)
      assert html =~ "Preferred structure"
      assert html =~ "7 reps per block · 10 blocks for 70 reps"

      view |> element("#generate-workout") |> render_click()
      html = render(view)

      assert html =~ "20:00 · Navy SEAL"
      assert html =~ "70 reps"
      assert html =~ "Even"
      assert html =~ "10 blocks"
      assert html =~ "7 reps each"
      refute html =~ "Block pattern"
      refute html =~ "Manual structure"
    end

    test "creator preferred structure grows beyond two pattern entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_click(view, "pick_type", %{"type" => "navy_seal"})

      view
      |> element("#creator-contract-form")
      |> render_change(%{"burpee_count_target" => "90"})

      view |> element("#structure-pattern-mode") |> render_click()

      assert has_element?(view, "#creator-structure-form input[name='pattern[0]']")
      refute has_element?(view, "#creator-structure-form input[name='pattern[1]']")

      view |> element("#creator-add-pattern-set") |> render_click()
      view |> element("#creator-add-pattern-set") |> render_click()

      assert has_element?(view, "#creator-structure-form input[name='pattern[2]']")

      view
      |> element("#creator-structure-form")
      |> render_change(%{"pattern" => %{"0" => "4", "1" => "3", "2" => "2"}})

      html = render(view)
      assert html =~ "Preferred structure"
      assert html =~ "9 reps per block · 10 blocks for 90 reps"

      view |> element("#generate-workout") |> render_click()
      html = render(view)

      assert html =~ "20:00 · Navy SEAL"
      assert html =~ "90 reps"
      assert html =~ "10 blocks"
      assert html =~ "9 reps each"
    end

    test "creator pace and shape controls update the training contract", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view
      |> element("button[phx-click='set_pace_bias'][phx-value-bias='faster']")
      |> render_click()

      view
      |> element("button[phx-value-shape='front_loaded']")
      |> render_click()

      html = render(view)
      assert html =~ "Faster"
      assert has_element?(view, "button[phx-value-shape='front_loaded']")

      view |> element("#generate-workout") |> render_click()
      assert render(view) =~ "Faster"
    end

    test "creator shows solver feedback before generation when constraints are impossible", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_basics", %{
        "target_duration_min" => "1",
        "burpee_count_target" => "200"
      })

      html = render(view)
      assert has_element?(view, "#creator-prescription-feedback")
      assert html =~ "This cannot fit in 1:00"
      assert has_element?(view, "#generate-workout[disabled]")
    end

    test "default generated review honors the visible training contract", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      html = render(view)

      assert has_element?(view, "#workout-contract-review")
      assert html =~ "20:00"
      assert html =~ "100 reps"
      assert html =~ "Even"
      assert html =~ "Flat load"
      refute html =~ "144 reps"
      refute html =~ "unbroken"
    end

    test "unbroken generated review preserves target and format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_click(view, "pick_pacing", %{"style" => "unbroken"})
      render_change(view, "change_basics", %{"reps_per_set" => "5"})
      view |> element("#generate-workout") |> render_click()
      html = render(view)

      assert has_element?(view, "#workout-contract-review")
      assert html =~ "100 reps"
      assert html =~ "Unbroken sets"
      assert html =~ "reps each"
      assert html =~ "Flat load"
      refute html =~ "200 reps"
      refute html =~ "Even"
    end

    test "generated review hides solver internals", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      html = render(view)

      refute html =~ "Block pattern"
      refute html =~ "Prescription"
      refute html =~ "Auto pace"
      refute html =~ "Solver computes"
      refute html =~ "Recommended"
    end

    test "generated review shows a readable workout contract before block data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()

      html = render(view)
      assert has_element?(view, "#workout-contract-review")
      assert html =~ "20:00 · Six-count"
      assert html =~ "reps ·"
      assert html =~ "block"
      assert html =~ "Steady and repeatable"
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
      assert html =~ "20:00 · Six-count"
      assert html =~ "reps ·"
      assert html =~ "block"
      assert has_element?(view, "[data-structure-map]")
      assert has_element?(view, "[data-workout-block-row]")
      assert has_element?(view, "#block-row-lock-0")
      refute has_element?(view, "#block-row-actions-0")
      refute html =~ "…"
      assert html =~ "Rep every"
      assert html =~ "rest"
      assert html =~ "Add rest"
      assert html =~ "Balance remaining work"

      refute has_element?(view, "#advanced-constraints-toggle")
      refute html =~ "Tune details"
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
      assert html =~ "Rep interval"
      assert html =~ "Rest after"
      assert html =~ "Lock this block"
      assert html =~ "Duplicate"
      refute has_element?(view, "#block-sheet-form input[name='block[reps]']")
      refute has_element?(view, "#block-sheet-form input[name='block[sec_per_rep]']")
      refute has_element?(view, "#block-sheet-form input[name='block[rest_sec]']")
      refute html =~ "More actions"
      refute html =~ "Delete block"
      refute has_element?(view, "#block-delete")

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "1",
          "sets" => %{
            "0" => %{"burpee_count" => "17", "sec_per_rep" => "4.2", "end_of_set_rest" => "45"}
          }
        }
      })

      html = render(view)
      assert html =~ "Locked by you"
      assert html =~ "17 reps"
      assert html =~ "Rep every 4.2s"
      assert html =~ "0:45 rest"
    end

    test "block row lock action marks the block without an overflow menu", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()

      assert has_element?(view, "#block-row-lock-0")
      refute has_element?(view, "#block-row-actions-0")

      view |> element("#block-row-lock-0") |> render_click()

      html = render(view)
      assert html =~ "Edited"
      assert html =~ "Locked by you"
    end

    test "block sheet repeat count updates generated structure rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()
      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "2",
          "sets" => %{
            "0" => %{"burpee_count" => "100", "sec_per_rep" => "12.0", "end_of_set_rest" => "0"}
          }
        }
      })

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Blocks 1–2"
      assert first_row_text =~ "100 reps each"
    end

    test "block sheet edits repeat count and individual sets", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Set Sheet Plan",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 6,
                  "sec_per_rep" => 5.0,
                  "sec_per_burpee" => 5.0,
                  "end_of_set_rest" => 10
                },
                %{
                  "position" => 2,
                  "burpee_count" => 4,
                  "sec_per_rep" => 5.0,
                  "sec_per_burpee" => 5.0,
                  "end_of_set_rest" => 20
                }
              ]
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      assert has_element?(view, "#block-sheet-form input[name='block[repeat_count]']")
      assert has_element?(view, "#block-sheet-form input[name='block[sets][0][burpee_count]']")
      assert has_element?(view, "#block-sheet-form input[name='block[sets][1][end_of_set_rest]']")

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "2",
          "sets" => %{
            "0" => %{"burpee_count" => "5", "sec_per_rep" => "4.5", "end_of_set_rest" => "15"},
            "1" => %{"burpee_count" => "4", "sec_per_rep" => "4.5", "end_of_set_rest" => "20"}
          }
        }
      })

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Blocks 1–2"
      assert first_row_text =~ "9 reps each"
      assert first_row_text =~ "0:20 rest"
    end

    test "adding rest to generated workout recalibrates rep intervals to keep duration", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_click(view, "pick_type", %{"type" => "navy_seal"})

      view
      |> element("#creator-contract-form")
      |> render_change(%{"burpee_count_target" => "80"})

      view |> element("#structure-pattern-mode") |> render_click()

      view
      |> element("#creator-structure-form")
      |> render_change(%{"pattern" => %{"0" => "4", "1" => "3"}})

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()
      view |> element("#editor-add-rest") |> render_click()

      view
      |> element("#rest-placement-form")
      |> render_submit(%{"rest" => %{"edge_index" => "2", "rest_sec" => "45"}})

      html = render(view)
      rows = texts_for(html, "[data-workout-structure-row]")

      assert Enum.at(rows, 1) =~ "0:45 recovery"
      assert html =~ "Rep every 14.4s"
      refute html =~ "Workout no longer fits"
    end

    test "add rest prompts for duration and expanded repeat placement before inserting", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Repeated Rest Placement",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 5,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 8,
                  "sec_per_rep" => 5.0,
                  "sec_per_burpee" => 5.0,
                  "end_of_set_rest" => 20
                }
              ]
            }
          ],
          "steps" => [
            %{
              "position" => 1,
              "kind" => "block_run",
              "block_position" => 1,
              "repeat_count" => 5
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      view |> element("#editor-add-rest") |> render_click()

      html = render(view)
      assert has_element?(view, "#rest-placement-sheet")
      assert html =~ "How long"
      assert html =~ "Where"
      assert html =~ "After block 1 of 5"
      assert html =~ "After block 3 of 5"
      assert html =~ "After block 4 of 5"
      refute html =~ "After block 5 of 5"
      refute html =~ "End of workout"
      assert has_element?(view, "#rest-placement-form select[name='rest[edge_index]']")
      assert has_element?(view, "#rest-placement-form input[name='rest[rest_sec]']")

      view
      |> element("#rest-placement-form")
      |> render_submit(%{"rest" => %{"edge_index" => "2", "rest_sec" => "45"}})

      rows = texts_for(render(view), "[data-workout-structure-row]")
      html = render(view)

      assert Enum.at(rows, 0) =~ "Blocks 1–2"
      assert Enum.at(rows, 1) =~ "0:45 recovery"
      assert Enum.at(rows, 2) =~ "Blocks 3–5"
      assert html =~ "20:00"
      refute html =~ "Workout no longer fits"

      view |> element("#plan-form") |> render_submit(%{"workout_plan" => %{}})
      assert_redirect(view, ~p"/workouts")

      updated = BurpeeTrainer.Workouts.get_plan!(user, plan.id)
      rest = Enum.find(updated.source_json["explicit_rests"], &(&1["duration_sec"] == 45))
      assert rest
      assert rest["target_elapsed_sec"] > 0
      assert rest["tolerance_sec"] == 60

      program = BurpeeTrainer.ExecutionPrograms.get!(updated.current_execution_program_id)

      assert Enum.any?(program.program_json["events"], fn
               %{"kind" => "rest", "duration_ms" => 45_000} -> true
               _event -> false
             end)
    end

    test "block sheet edits only the selected segment after a repeated block is split", %{
      conn: conn,
      user: user
    } do
      plan =
        plan_fixture(user, %{
          "name" => "Split Segment Edit",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 10,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 8,
                  "sec_per_rep" => 5.0,
                  "sec_per_burpee" => 5.0,
                  "end_of_set_rest" => 0
                }
              ]
            }
          ],
          "steps" => [
            %{
              "position" => 1,
              "kind" => "block_run",
              "block_position" => 1,
              "repeat_count" => 10
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/workouts/#{plan.id}/edit")
      view |> element("#editor-add-rest") |> render_click()

      view
      |> element("#rest-placement-form")
      |> render_submit(%{"rest" => %{"edge_index" => "5", "rest_sec" => "15"}})

      rows = texts_for(render(view), "[data-workout-structure-row]")
      assert Enum.at(rows, 0) =~ "Blocks 1–5"
      assert Enum.at(rows, 1) =~ "0:15 recovery"
      assert Enum.at(rows, 2) =~ "Blocks 6–10"

      view |> element("[data-workout-block-row][phx-value-index='5']") |> render_click()

      assert render(view) =~ "Blocks 6–10"

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "step_position" => "3",
          "repeat_count" => "5",
          "sets" => %{
            "0" => %{"burpee_count" => "10", "sec_per_rep" => "5.0", "end_of_set_rest" => "0"}
          }
        }
      })

      rows = texts_for(render(view), "[data-workout-structure-row]")

      assert Enum.at(rows, 0) =~ "Blocks 1–5"
      assert Enum.at(rows, 0) =~ "8 reps each"
      assert Enum.at(rows, 2) =~ "Blocks 6–10"
      assert Enum.at(rows, 2) =~ "10 reps each"
    end

    test "block sheet edits the displayed multi-set block total, not only its first set", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")

      render_change(view, "change_block_pattern", %{"pattern" => %{"0" => "4", "1" => "3"}})
      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()
      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "14",
          "sets" => %{
            "0" => %{"burpee_count" => "9", "sec_per_rep" => "4.2", "end_of_set_rest" => "0"},
            "1" => %{"burpee_count" => "8", "sec_per_rep" => "4.2", "end_of_set_rest" => "45"}
          }
        }
      })

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "17 reps"
      refute first_row_text =~ "20 reps"
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

      html = render(view)
      assert html =~ "Blocks 1–3"

      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

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
          "repeat_count" => "3",
          "sets" => %{
            "0" => %{"burpee_count" => "19", "sec_per_rep" => "4.4", "end_of_set_rest" => "50"}
          }
        }
      })

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Locked by you"
      assert first_row_text =~ "19 reps"
      assert length(Regex.scan(~r/Locked by you/, html)) == 1

      view |> element("#rebalance-unlocked-blocks") |> render_click()

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert first_row_text =~ "Locked by you"
      assert first_row_text =~ "19 reps"
    end

    test "locked block edits survive LiveView regeneration", %{conn: conn, user: user} do
      plan =
        plan_fixture(user, %{
          "name" => "Locked Regen",
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
      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()
      view |> element("#block-lock-toggle") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "3",
          "sets" => %{
            "0" => %{"burpee_count" => "19", "sec_per_rep" => "4.4", "end_of_set_rest" => "50"}
          }
        }
      })

      [first_row_text] = texts_for(render(view), "[data-workout-block-row][phx-value-index='0']")
      assert first_row_text =~ "19 reps"

      render_change(view, "change_basics", %{"name" => "Locked Regen Renamed"})

      html = render(view)
      [first_row_text] = texts_for(html, "[data-workout-block-row][phx-value-index='0']")

      assert html =~ "Locked Regen Renamed"
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

    test "new workout page has no duplicate tune details panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/workouts/new")

      refute has_element?(view, "#advanced-constraints-toggle")
      refute html =~ ~s(id="advanced-constraints-panel")
      refute html =~ "Tuning"
      refute html =~ "Tune details"

      view |> element("#generate-workout") |> render_click()
      view |> element("#edit-workout") |> render_click()
      html = render(view)

      refute has_element?(view, "#advanced-constraints-toggle")
      refute html =~ ~s(id="advanced-constraints-panel")
      refute html =~ "Tuning"
      refute html =~ "Tune details"
    end

    test "invalid manual prescription shows actionable feedback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      generate_workout(view)

      view |> element("[data-workout-block-row][phx-value-index='0']") |> render_click()

      view
      |> element("#block-sheet-form")
      |> render_change(%{
        "block" => %{
          "source_block_index" => "0",
          "repeat_count" => "1",
          "sets" => %{
            "0" => %{
              "burpee_count" => "200",
              "sec_per_rep" => "6.21",
              "sec_per_burpee" => "6.21",
              "end_of_set_rest" => "0"
            }
          }
        }
      })

      html = render(view)
      assert has_element?(view, "#plan-solver-impossible")
      assert html =~ "Workout no longer fits 20:00"
      assert html =~ "You are 0:42 over."
      assert html =~ "Balance remaining work"
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

    test "generated workout review uses contract summary instead of block pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workouts/new")
      view |> element("#generate-workout") |> render_click()

      html = render(view)
      assert has_element?(view, "#workout-contract-review")
      refute has_element?(view, "#block-pattern-editor")
      refute html =~ "Block pattern"
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

      assert html =~ "Manual structure"
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
end
