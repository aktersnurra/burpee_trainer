defmodule BurpeeTrainerWeb.OverviewAuthoringUXTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, Workouts, Repo}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.WorkoutPlan

  setup %{conn: conn} = context do
    parent = self()
    hold_plan? = context[:hold_edit_plan] || false
    previous_req = Req.default_options()
    previous_provider = Application.get_env(:burpee_trainer, :llm_provider)

    on_exit(fn ->
      Req.default_options(previous_req)
      Application.put_env(:burpee_trainer, :llm_provider, previous_provider)
    end)

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "https://provider.test/v1",
      api_key: "test",
      model: "test"
    )

    Req.default_options(
      adapter: fn request ->
        body = Jason.decode!(request.body)
        send(parent, {:provider_request, body})

        constraints =
          Enum.find_value(body["messages"], fn message ->
            case Jason.decode(message["content"]) do
              {:ok, %{"scope" => "confirmed_workout_request", "request" => attrs}} -> attrs
              _ -> nil
            end
          end)

        if constraints && hold_plan? do
          send(parent, {:edit_planning_waiting, self()})

          receive do
            :release_plan -> :ok
          end
        end

        extracting? = is_nil(constraints)

        constraints =
          constraints ||
            %{
              "burpee_type" => "six_count",
              "target_reps" =>
                if(
                  Enum.any?(
                    body["messages"],
                    &String.contains?(&1["content"], "Increase to 150")
                  ),
                  do: 150,
                  else: 120
                ),
              "target_duration_sec" => 1200,
              "pacing_style" => "unbroken",
              "recovery" => "required",
              "requested_pace_sec" => 5,
              "timed_rests" => []
            }

        constraints =
          if extracting?,
            do:
              Map.put(
                constraints,
                "set_reps",
                List.duplicate(div(constraints["target_reps"], 2), 2)
              ),
            else: constraints

        reps = constraints["target_reps"]
        duration = constraints["target_duration_sec"]

        work = fn reps ->
          %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
        end

        definition = %{
          "version" => 1,
          "name" => "Independent new workout",
          "burpee_type" => constraints["burpee_type"],
          "target_reps" => reps,
          "target_duration_sec" => duration,
          "pacing_style" => constraints["pacing_style"],
          "rationale" => "Continuous sets and local recovery.",
          "events" => [
            work.(div(reps, 2)),
            %{"kind" => "rest", "duration_sec" => duration - reps * 5},
            work.(reps - div(reps, 2))
          ]
        }

        definition =
          if body["response_format"]["json_schema"]["name"] == "phased_workout_definition" do
            [first, pause, last] = definition["events"]

            definition
            |> Map.delete("events")
            |> Map.put("rest_1", pause)
            |> Map.put("phase_2", %{"work_rest_pairs" => [], "last_work" => last})
            |> Map.put("phase_1", %{
              "work_rest_pairs" => [],
              "last_work" => first
            })
          else
            definition
          end

        {request,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "choices" => [
                 %{
                   "message" => %{
                     "content" =>
                       Jason.encode!(if(extracting?, do: constraints, else: definition))
                   }
                 }
               ]
             })
         }}
      end
    )

    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(user, slot)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    %{view: view, user: user, selected: selected}
  end

  test "chooser soft deletes an owned selected workout without losing history", %{
    conn: conn,
    user: user
  } do
    definition = %{
      "version" => 1,
      "name" => "Remove this variation",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" => "Preserve history.",
      "events" => [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 500},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ]
    }

    original = plan_fixture(user, %{"definition" => definition, "state" => "published"})
    used_at = DateTime.add(DateTime.utc_now(:second), -86400, :second)

    used =
      Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        plan_id: original.id,
        state: :completed,
        source_kind: :plan,
        client_session_id: Ecto.UUID.generate(),
        display_name_snapshot: original.name,
        workout_type_snapshot: original.burpee_type,
        burpee_type: original.burpee_type,
        program_snapshot: original.program_json,
        content_hash: original.content_hash,
        burpee_count_planned: 140,
        duration_sec_planned: 1200,
        burpee_count_actual: 140,
        duration_sec_actual: 1200,
        capture_mode: :timed,
        started_at: DateTime.add(used_at, -1200, :second),
        completed_at: used_at
      })

    {:ok, selected} = Workouts.ensure_home_selection(user, selected_slot(user))
    {:ok, _pin} = Workouts.select_home_workout(user, selected, original.id)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed=false]"
      if has_element?(view, selector), do: view |> element(selector) |> render_click()
    end

    assert has_element?(view, "#home-delete-workout-#{original.id}[data-confirm]")
    view |> element("#home-delete-workout-#{original.id}") |> render_click()
    archived = Repo.get!(WorkoutPlan, original.id)
    assert archived.state == :archived
    assert archived.definition_json == original.definition_json
    assert archived.program_json == original.program_json
    assert archived.content_hash == original.content_hash
    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutSession, used.id) == used
    refute has_element?(view, "#home-alternative-plan-#{original.id}")
    {:ok, fallback} = Workouts.ensure_home_selection(user, selected_slot(user))
    refute fallback.plan.id == original.id
    refute has_element?(view, "#home-delete-workout-#{fallback.plan.id}")
    foreign = plan_fixture(user_fixture(), %{"definition" => definition, "state" => "published"})
    render_click(view, "delete_workout", %{"id" => to_string(foreign.id)})
    assert Repo.get!(WorkoutPlan, foreign.id).state == :published
    render_click(view, "delete_workout", %{"id" => to_string(fallback.plan.id)})
    assert Repo.get!(WorkoutPlan, fallback.plan.id).state == :published
    {:ok, reloaded, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    reloaded |> element("#home-summary") |> render_click()
    reloaded |> element("#home-title-action") |> render_click()
    reloaded |> element("#home-filter-toggle") |> render_click()

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed=false]"
      if has_element?(reloaded, selector), do: reloaded |> element(selector) |> render_click()
    end

    refute has_element?(reloaded, "#home-alternative-plan-#{original.id}")
    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutSession, used.id) == used
    refute_received {:provider_request, _}
  end

  @tag hold_edit_plan: true
  test "Edit reviews and saves a new variation while the original and a used session stay unchanged",
       %{conn: conn, user: user} do
    definition = %{
      "version" => 1,
      "name" => "140 rep favourite",
      "burpee_type" => "six_count",
      "target_reps" => 140,
      "target_duration_sec" => 1200,
      "pacing_style" => "unbroken",
      "rationale" => "Two continuous sets with recovery.",
      "events" => [
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 500},
        %{"kind" => "work", "reps" => 70, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      ]
    }

    original = plan_fixture(user, %{"definition" => definition, "state" => "published"})
    used_at = DateTime.add(DateTime.utc_now(:second), -86400, :second)
    # Seed history directly: completed session timestamps cannot be backdated after first use.
    used =
      Repo.insert!(%BurpeeTrainer.Workouts.WorkoutSession{
        user_id: user.id,
        plan_id: original.id,
        state: :completed,
        source_kind: :plan,
        client_session_id: Ecto.UUID.generate(),
        display_name_snapshot: original.name,
        workout_type_snapshot: original.burpee_type,
        burpee_type: original.burpee_type,
        program_snapshot: original.program_json,
        content_hash: original.content_hash,
        burpee_count_planned: 140,
        duration_sec_planned: 1200,
        burpee_count_actual: 140,
        duration_sec_actual: 1200,
        capture_mode: :timed,
        started_at: DateTime.add(used_at, -1200, :second),
        completed_at: used_at
      })

    {:ok, selected} = Workouts.ensure_home_selection(user, selected_slot(user))
    {:ok, pin} = Workouts.select_home_workout(user, selected, original.id)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-edit-workout") |> render_click()
    refute has_element?(view, "#home-new-form, #home-new-reps, #home-workout-budget")

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: "Increase to 160 reps"})
    |> render_change()

    view |> element("#home-request-abort") |> render_click()
    assert {:ok, ^pin} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert Workouts.list_drafts(user) == []
    refute_received {:provider_request, _}
    view |> element("#home-edit-workout") |> render_click()
    assert has_element?(view, "#home-edit-instruction[placeholder='What do you want to change?']")
    instruction = "Increase to 150 reps, keep 20 minutes, 5 seconds active pace and two sets."

    view
    |> form("#home-edit-form", home_adjustment: %{instruction: instruction})
    |> render_change()

    view |> element("#home-history-toggle") |> render_click()
    view |> element("#history-coach-open") |> render_click()
    view |> element("#home-coach-back") |> render_click()
    view |> element("#home-history-toggle") |> render_click()
    assert has_element?(view, "#home-edit-instruction", instruction)
    refute_received {:provider_request, _}
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-edit-form") |> render_submit()
    assert_receive {:edit_planning_waiting, planner}, 1_000
    assert has_element?(view, "#home-update-loading[role=status] .home-loading-animation")
    assert has_element?(view, "#home-request-abort:not([disabled])")
    refute has_element?(view, "#home-edit-form, #home-edit-review")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    send(planner, :release_plan)
    render_async(view)
    assert_receive {:provider_request, _interpretation}
    assert_receive {:provider_request, body}

    source =
      Enum.find_value(body["messages"], fn message ->
        case Jason.decode(message["content"]) do
          {:ok, %{"scope" => "edit_workout_source"} = source} -> source
          _ -> nil
        end
      end)

    assert source["definition"]["target_reps"] == 140
    refute has_element?(view, "#home-new-form")
    assert has_element?(view, "#home-edit-review-reps", "150")
    refute has_element?(view, "#home-edit-review-sets, .home-edit-structure")
    assert has_element?(view, "#home-edit-review #home-inspection table")
    assert has_element?(view, "#home-edit-review .home-prescription-reps", "75")
    assert has_element?(view, "#home-edit-review .home-prescription-pace", "5s")
    assert has_element?(view, "#home-edit-review .home-prescription-rest", "450s")
    refute has_element?(view, "#home-update-loading")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved")
    assert Workouts.list_drafts(user) == []

    [saved] =
      Enum.filter(Workouts.list_library(user), &(&1.user_id == user.id and &1.target_reps == 150))

    assert saved.state == :published
    assert saved.id != original.id
    assert saved.definition_json["target_reps"] == 150
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1
    refute_received {:provider_request, _}
    assert {:ok, ^pin} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert Repo.get!(WorkoutPlan, original.id).definition_json == original.definition_json

    assert Repo.get!(BurpeeTrainer.Workouts.WorkoutSession, used.id).program_snapshot ==
             used.program_snapshot

    view |> element("#home-new-select") |> render_click()
    {:ok, reopened, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    assert has_element?(reopened, "#home-ready-recommendation .home-workout-name", saved.name)
    assert Enum.any?(Workouts.list_library(user), &(&1.id == original.id))

    assert {:ok, %{plan: %{id: saved_id}}} =
             Workouts.ensure_home_selection(user, selected_slot(user))

    assert saved_id == saved.id
  end

  test "a changed current selection cannot approve an outdated edit", %{
    view: view,
    user: user,
    selected: selected
  } do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-edit-workout") |> render_click()

    view
    |> form("#home-edit-form",
      home_adjustment: %{
        instruction: "Change to 120 reps in 20 minutes, in two sets at 5 seconds active pace"
      }
    )
    |> render_submit()

    render_async(view)
    assert_receive {:provider_request, _}
    assert_receive {:provider_request, _}
    assert has_element?(view, "#home-request-confirm")
    other = plan_fixture(user, %{"state" => "published"})
    {:ok, changed} = Workouts.select_home_workout(user, selected, other.id)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    refute has_element?(view, "#home-new-saved")
    assert has_element?(view, "#home-adjustment-error", "changed")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert {:ok, ^changed} = Workouts.ensure_home_selection(user, selected_slot(user))
    refute_received {:provider_request, _}
  end

  test "Review prepares without a source or a plan; approval saves with no provider", %{
    view: view,
    user: user,
    selected: selected
  } do
    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"}) |> render_submit()
    render_async(view)
    assert_receive {:provider_request, body}

    context =
      Enum.find_value(body["messages"], fn message ->
        case Jason.decode(message["content"]) do
          {:ok, %{"scope" => "workout_design"} = context} -> context
          _ -> nil
        end
      end)

    assert context["current_definition"] == nil
    assert has_element?(view, "#home-new-form[data-stage=review]")
    assert has_element?(view, "#home-new-reps[disabled][value='10']")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved")
    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert unchanged.plan.id == selected.plan.id
    view |> element("#home-new-select") |> render_click()
    assert has_element?(view, "#home-summary", "Independent new workout")
    refute_received {:provider_request, _}
  end

  test "a saved workout stays selectable after dismissing the saved notice", %{
    view: view,
    user: user,
    selected: selected
  } do
    open_new(view)
    view |> element("#home-pill-pacing_style-even") |> render_click()
    view |> form("#home-new-form", home_workout: %{reps: 10, duration: "2:00"}) |> render_submit()
    render_async(view)
    assert_receive {:provider_request, _}
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved")
    view |> element("#home-new-dismiss") |> render_click()
    refute has_element?(view, "#home-new-saved")

    [saved] = Enum.filter(Workouts.list_library(user), &(&1.name == "Independent new workout"))
    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert unchanged.plan.id == selected.plan.id

    render_click(view, "open_chooser", %{})
    assert has_element?(view, "#home-alternative-plan-#{saved.id}")
    assert has_element?(view, "#home-delete-workout-#{saved.id}")
    view |> element("#home-alternative-plan-#{saved.id}-select") |> render_click()
    assert has_element?(view, "#home-summary", "Independent new workout")
    refute_received {:provider_request, _}
  end

  test "provider failure retains input and current pin without offering approval", %{
    view: view,
    user: user,
    selected: selected
  } do
    Application.put_env(:burpee_trainer, :llm_provider, enabled: false)
    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-new-form", home_workout: %{reps: 140}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#home-new-reps[value='140']")
    refute has_element?(view, "#home-request-confirm")
    assert has_element?(view, "#home-adjustment-error", "Coach unavailable")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    assert {:ok, unchanged} = Workouts.ensure_home_selection(user, selected_slot(user))
    assert unchanged.plan.id == selected.plan.id
  end

  test "all three states use the same fields, pills and local budget; pencil invalidates approval",
       %{view: view, user: user, selected: selected} do
    open_new(view)
    ids = field_ids(view)

    view
    |> form("#home-new-form", home_workout: %{reps: 140, pace: "5", sets: "", duration: "20:00"})
    |> render_change()

    assert has_element?(view, "#home-workout-budget", "11:40")
    assert has_element?(view, "#home-workout-budget", "8:20")
    refute_received {:provider_request, _}
    view |> element("#home-pill-pacing_style-even") |> render_click()
    assert has_element?(view, "#home-pill-pacing_style-even[aria-pressed=true]")
    refute_received {:provider_request, _}
    view |> form("#home-new-form") |> render_submit()
    render_async(view)
    assert_receive {:provider_request, _}
    assert field_ids(view) == ids
    assert has_element?(view, "#home-request-edit[aria-label='Edit workout']")
    view |> element("#home-request-edit") |> render_click()
    assert field_ids(view) == ids
    refute has_element?(view, "#home-request-confirm")
    view |> form("#home-new-form", home_workout: %{reps: 130, sets: ""}) |> render_change()
    assert has_element?(view, "#home-workout-budget", "10:50")
    refute_received {:provider_request, _}
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
    assert {:ok, unchanged} = Workouts.verify_home_selection(user, selected)
    assert unchanged.id == selected.plan.id
    assert Workouts.current_started_session(user) == nil
  end

  test "malformed rests and contradictory patterns are local errors", %{view: view} do
    open_new(view)
    view |> form("#home-new-form", home_workout: %{rests: "not a rest"}) |> render_submit()
    assert has_element?(view, "#home-new-form")
    assert has_element?(view, "#home-new-form", "Use 60s at 11:00")
    refute_received {:provider_request, _}
    view |> form("#home-new-form", home_workout: %{rests: "", sets: "5x8"}) |> render_submit()
    assert has_element?(view, "#home-new-form", "Pattern contains 40 reps")
    refute_received {:provider_request, _}
  end

  test "a returned pattern mismatch is explained before any save", %{view: view} do
    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)

    view
    |> form("#home-new-form", home_workout: %{reps: 140, pace: 5, sets: "5x8,5x7,5x(7,6)"})
    |> render_submit()

    render_async(view)
    assert_receive {:provider_request, _}
    assert_receive {:provider_request, _}
    assert has_element?(view, "#home-adjustment-error", "ordered set pattern")
    assert has_element?(view, "#home-new-form", "Returned 2 sets; expected 20")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    refute_received {:provider_request, _}
  end

  test "editing during preparation cancels the task and a late result cannot save", %{view: view} do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:planning_started, self()})

        receive do
          :release -> {request, %Req.Response{status: 500}}
        end
      end
    )

    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)
    view |> form("#home-new-form", home_workout: %{reps: 140}) |> render_submit()
    assert_receive {:planning_started, task}
    monitor = Process.monitor(task)
    view |> form("#home-new-form", home_workout: %{reps: 130}) |> render_change()
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    send(task, :release)
    render_async(view)
    assert has_element?(view, "#home-new-reps[value='130']")
    refute has_element?(view, "#home-request-confirm")
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-request-abort") |> render_click()
    assert has_element?(view, "#home-inspection")
  end

  test "validated alternate pauses require a separate explicit choice", %{view: view} do
    parent = self()

    work = fn reps ->
      %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
    end

    proposal = %{
      "version" => 1,
      "name" => "Chosen pauses",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 110,
      "pacing_style" => "unbroken",
      "rationale" => "A validated alternate pause.",
      "phase_1" => %{"work_rest_pairs" => [], "last_work" => work.(6)},
      "rest_1" => %{"kind" => "rest", "duration_sec" => 60},
      "phase_2" => %{"work_rest_pairs" => [], "last_work" => work.(4)}
    }

    Req.default_options(
      adapter: fn request ->
        send(parent, :alternate_request)

        {request,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "choices" => [%{"message" => %{"content" => Jason.encode!(proposal)}}]
             })
         }}
      end
    )

    open_new(view)
    count = Repo.aggregate(WorkoutPlan, :count)

    view
    |> form("#home-new-form",
      home_workout: %{reps: 10, duration: "1:50", pace: 5, sets: "1x6,1x4", rests: "60s at 0:45"}
    )
    |> render_submit()

    render_async(view)
    assert_receive :alternate_request
    assert_receive :alternate_request
    assert has_element?(view, "#home-request-confirm[disabled]")
    assert has_element?(view, "#home-rest-alternative", "0:45 → 60s at 0:30")
    assert has_element?(view, "#home_workout_rests", "60s at 0:45")
    render_click(view, "confirm_workout_request", %{"definition" => %{}})
    assert Repo.aggregate(WorkoutPlan, :count) == count
    view |> element("#home-use-rest-alternative") |> render_click()
    assert has_element?(view, "#home_workout_rests", "60s at 0:30")
    refute has_element?(view, "#home-request-confirm[disabled]")
    view |> element("#home-request-confirm") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-new-saved")
    assert Repo.aggregate(WorkoutPlan, :count) == count + 1
    refute_received :alternate_request
  end

  defp open_new(view) do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
  end

  defp field_ids(view) do
    render(view)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "#home-new-form input:not([type=hidden]), #home-new-form textarea, #home-workout-budget"
    )
    |> LazyHTML.attribute("id")
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(user, DateTime.utc_now(:second))
    slot
  end
end
