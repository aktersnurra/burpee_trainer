defmodule BurpeeTrainerWeb.Flows.ArchiveFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BurpeeTrainerWeb.StudioHelpers
  import BurpeeTrainer.Fixtures
  alias BurpeeTrainer.{Accounts, ReqStub, Workouts, Repo}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.WorkoutPlan

  setup do
    parent = self()
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

    ReqStub.default(fn _request -> send(parent, :provider_request) end)
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    %{user: user}
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
    open_swap(view)

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
    open_swap(reloaded)

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
    refute_received :provider_request
  end

  defp selected_slot(user) do
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))
    slot
  end
end
