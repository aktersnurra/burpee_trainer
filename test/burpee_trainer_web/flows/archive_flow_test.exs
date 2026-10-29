defmodule BurpeeTrainerWeb.Flows.ArchiveFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, ReqStub, Workouts, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

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

    ReqStub.default(fn request ->
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

      work = fn reps ->
        %{"kind" => "work", "reps" => reps, "sec_per_rep" => 5, "sec_per_burpee" => 5}
      end

      layout = %{
        "name" => "Independent new workout",
        "rationale" => "Continuous sets and local recovery.",
        "phases" => [
          %{
            "sets" => [
              Map.delete(work.(div(reps, 2)), "kind"),
              Map.delete(work.(reps - div(reps, 2)), "kind")
            ],
            "rests" => [%{"share" => 1}]
          }
        ]
      }

      {request,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "choices" => [
               %{
                 "message" => %{
                   "content" => Jason.encode!(if(extracting?, do: constraints, else: layout))
                 }
               }
             ]
           })
       }}
    end)

    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
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

    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
    {:ok, _pin} = Workouts.select_home_workout(Scope.for_user(user), selected, original.id)
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
    # Observe the replacement immediately, before any external ensure or reload.
    after_archive = :sys.get_state(view.pid).socket.assigns
    assert {:start, immediate_fallback} = after_archive.home_state
    assert immediate_fallback == after_archive.home_facts.selection
    assert after_archive.home_selection == immediate_fallback
    refute immediate_fallback.plan.id == original.id

    assert after_archive.inspection_rows ==
             BurpeeTrainer.Workouts.Inspection.rows(immediate_fallback.plan)

    assert has_element?(view, "#home-summary .home-workout-name", immediate_fallback.plan.name)
    {:ok, fallback} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
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
    # The original view (not a reload or separately ensured fallback) must offer
    # the genuine replacement and successfully start its displayed snapshot.
    view |> element("#home-chooser-close") |> render_click()
    state = :sys.get_state(view.pid).socket.assigns
    assert {:start, shown} = state.home_state
    assert shown == state.home_facts.selection
    assert state.home_selection == shown
    assert shown.plan.id == fallback.plan.id
    assert state.inspection_rows == BurpeeTrainer.Workouts.Inspection.rows(shown.plan)
    assert has_element?(view, "#home-summary .home-workout-name", shown.plan.name)
    view |> element("#home-action[data-primary-action=start]") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.plan_id == shown.plan.id
    assert started.program_snapshot == shown.plan.program_json
    assert started.content_hash == shown.plan.content_hash
    assert_redirect(view, "/session/#{started.id}")
    assert Repo.reload!(used) == used
    assert Repo.reload!(foreign).state == :published
    refute_received {:provider_request, _}
  end

  test "archive from the chooser retains completed snapshot and chooses a fallback", %{conn: conn} do
    user = user_fixture()
    plan = plan_fixture(user, %{name: "Archived source"})
    fallback = plan_fixture(user, %{name: "Fallback"})

    {:ok, slot} =
      BurpeeTrainer.Coach.Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))

    {:ok, shown} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    {:ok, _} = Workouts.select_home_workout(Scope.for_user(user), shown, plan.id)
    completed_at = DateTime.add(DateTime.utc_now(:second), -86_400, :second)

    completed =
      Repo.insert!(%WorkoutSession{
        user_id: user.id,
        plan_id: plan.id,
        state: :completed,
        source_kind: :plan,
        client_session_id: Ecto.UUID.generate(),
        display_name_snapshot: plan.name,
        workout_type_snapshot: plan.burpee_type,
        burpee_type: plan.burpee_type,
        program_snapshot: plan.program_json,
        content_hash: plan.content_hash,
        burpee_count_planned: plan.target_reps,
        duration_sec_planned: plan.target_duration_sec,
        burpee_count_actual: 1,
        duration_sec_actual: 1,
        capture_mode: :timed,
        started_at: DateTime.add(completed_at, -1, :second),
        completed_at: completed_at
      })

    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-summary") |> render_click()
    view |> element("#home-title-action") |> render_click()
    view |> element("#home-delete-workout-#{plan.id}") |> render_click()
    assert Repo.get!(WorkoutPlan, plan.id).state == :archived
    assert Repo.get!(WorkoutSession, completed.id).program_snapshot == completed.program_snapshot
    assert has_element?(view, "#home-alternative-plan-#{fallback.id}")
  end

  test "settled real adjustment defers archive without changing workspace or database", %{
    conn: conn,
    user: user
  } do
    original =
      plan_fixture(user, %{
        "definition" => %{
          "version" => 1,
          "name" => "Keep prepared source",
          "burpee_type" => "six_count",
          "target_reps" => 30,
          "target_duration_sec" => 1200,
          "pacing_style" => "even",
          "rationale" => "Preserve prepared identity and expanded group.",
          "events" =>
            List.duplicate(
              %{"kind" => "work", "reps" => 15, "sec_per_rep" => 40, "sec_per_burpee" => 40},
              2
            )
        }
      })

    foreign = plan_fixture(user_fixture(), %{name: "Foreign source"})
    completed_at = DateTime.add(DateTime.utc_now(:second), -86_400, :second)

    completed =
      Repo.insert!(%WorkoutSession{
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
        burpee_count_planned: original.target_reps,
        duration_sec_planned: original.target_duration_sec,
        burpee_count_actual: 1,
        duration_sec_actual: 1,
        capture_mode: :timed,
        started_at: DateTime.add(completed_at, -1, :second),
        completed_at: completed_at
      })

    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(user), selected_slot(user))
    {:ok, pinned} = Workouts.select_home_workout(Scope.for_user(user), selected, original.id)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/")
    view |> element("#home-history-toggle") |> render_click()
    view |> element("#home-history-close") |> render_click()
    view |> element("#home-summary") |> render_click()
    initial = :sys.get_state(view.pid).socket.assigns
    assert initial.home_selection == pinned

    for row <- initial.inspection_rows, row.count > 1 do
      render_click(view, "toggle_group", %{"id" => row.id})
    end

    assert MapSet.size(:sys.get_state(view.pid).socket.assigns.expanded_groups) == 1
    view |> element("#home-new-workout") |> render_click()
    view |> element("#home-request-abort") |> render_click()

    instruction = "Change to 120 reps in 20 minutes, in two sets at 5 seconds active pace"

    render_change(view, "change_adjustment", %{
      "home_adjustment" => %{"instruction" => instruction}
    })

    render_submit(view, "submit_home_action", %{
      "client_session_id" => initial.start_client_session_id,
      "home_adjustment" => %{"instruction" => instruction}
    })

    render_async(view)
    assert_receive {:provider_request, _}
    assert has_element?(view, "#home-request-confirmation")
    prepared = :sys.get_state(view.pid).socket.assigns
    assert prepared.busy? == false
    assert prepared.authoring_stage == :idle
    assert prepared.pending_request.scope.kind == :revision
    assert prepared.pending_request.scope.expected == pinned
    assert prepared.instruction == instruction
    assert prepared.home_selection == prepared.home_facts.selection
    assert prepared.home_state == {:start, pinned}

    view |> element("#home-title-action:not([disabled])") |> render_click()
    view |> element("#home-filter-toggle") |> render_click()

    for level <- BurpeeTrainer.Levels.all_levels() do
      selector = "#home-level-#{level}[aria-pressed=false]"
      if has_element?(view, selector), do: view |> element(selector) |> render_click()
    end

    assert has_element?(view, "#home-delete-workout-#{original.id}[data-confirm]")
    before = :sys.get_state(view.pid).socket.assigns
    rows = database_rows()
    view |> element("#home-delete-workout-#{original.id}") |> render_click()
    after_rejection = :sys.get_state(view.pid).socket.assigns
    assert database_rows() == rows
    # All assigns (including streams/forms/identities/facts/snapshot/timer/token)
    # stay identical; only the existing rejection flash may change.
    assert Map.drop(after_rejection, [:flash, :__changed__]) ==
             Map.drop(before, [:flash, :__changed__])

    assert after_rejection.flash["error"] ==
             "That workout could not be deleted. Your history is unchanged."

    assert Repo.reload!(original) == original
    assert Repo.reload!(foreign) == foreign
    assert Repo.reload!(completed) == completed
    assert has_element?(view, "#home-alternative-plan-#{original.id}")
    assert has_element?(view, "#home-summary .home-workout-name", original.name)
    assert has_element?(view, "#home-request-confirmation")
    refute_received {:provider_request, _}

    view |> element("#home-chooser-close") |> render_click()
    view |> element("#home-request-back") |> render_click()
    cancelled = :sys.get_state(view.pid).socket.assigns
    assert cancelled.pending_request == nil
    assert cancelled.instruction == instruction
    assert cancelled.home_selection == pinned
    assert cancelled.home_facts == before.home_facts
    assert cancelled.home_snapshot_now == before.home_snapshot_now
    assert cancelled.start_client_session_id == before.start_client_session_id
    assert database_rows() == rows
    view |> element("#home-action[data-primary-action=start]:not([disabled])") |> render_click()
    started = Workouts.current_started_session(Scope.for_user(user))
    assert started.plan_id == pinned.plan.id
    assert started.program_snapshot == pinned.plan.program_json
    assert started.content_hash == pinned.plan.content_hash
    assert started.client_session_id == before.start_client_session_id
    assert_redirect(view, "/session/#{started.id}")
    assert Repo.reload!(original) == original
    assert Repo.reload!(foreign) == foreign
    assert Repo.reload!(completed) == completed
    refute_received {:provider_request, _}
  end

  defp database_rows do
    %{rows: tables} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
        []
      )

    Enum.map(tables, fn [table] ->
      quoted = String.replace(table, "\"", "\"\"")

      {table,
       Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM \"#{quoted}\" ORDER BY rowid", []).rows}
    end)
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end
end
