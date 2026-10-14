defmodule BurpeeTrainerWeb.Flows.OwnershipFlowTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.{Coach, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Exchange, Memory, MemoryJob, WorkoutRequest}
  alias BurpeeTrainer.Workouts.{WorkoutPlan, WorkoutSession}

  test "foreign prepared approval, selection, archive, memory, and session mount leave rows unchanged",
       %{conn: conn} do
    owner = user_fixture()
    attacker = user_fixture()
    counter = fake_authoring_provider(%{"workout_layout" => layout()})
    {:ok, request} = request()

    {:ok, prepared} =
      Coach.prepare_plan(Scope.for_user(owner), "10 reps in 2 minutes", request,
        workspace_key: "owned-review"
      )

    assert Agent.get(counter, & &1.calls) == ["workout_layout"]
    plans_before = Repo.all(WorkoutPlan)
    assert {:error, _} = Coach.approve_plan(Scope.for_user(attacker), prepared)
    assert Repo.all(WorkoutPlan) == plans_before

    own = plan_fixture(attacker)
    foreign = plan_fixture(owner)

    {:ok, slot} =
      BurpeeTrainer.Coach.Policy.required_slot(
        Scope.for_user(attacker),
        DateTime.utc_now(:second)
      )

    {:ok, selected} = Workouts.ensure_home_selection(Scope.for_user(attacker), slot)
    {:ok, _selected} = Workouts.select_home_workout(Scope.for_user(attacker), selected, own.id)
    selected_before = Workouts.ensure_home_selection(Scope.for_user(attacker), slot)
    {:ok, view, _} = live(init_test_session(conn, %{user_id: attacker.id}), ~p"/")
    render_click(view, "select_alternative", %{"id" => "#{foreign.id}", "kind" => "plan"})
    assert Workouts.ensure_home_selection(Scope.for_user(attacker), slot) == selected_before
    render_click(view, "delete_workout", %{"id" => "#{foreign.id}"})
    assert Repo.get!(WorkoutPlan, foreign.id).state == :published

    owner_scope = Scope.for_user(owner)
    {:ok, _} = Memory.apply_ops(owner_scope, [%{"op" => "add", "text" => "Trains mornings"}])
    [owner_note] = Memory.list(owner_scope)
    {:ok, owner_exchange} = Exchange.record(owner_scope, "Mornings?", "Yes.")
    coach_plans_before = Repo.all(WorkoutPlan)
    pid = view.pid
    # The old notebook event is gone, and the memory job reads only the owner's own events.
    render_submit(view, "coach_notebook_save", %{"coach_notebook" => %{"text" => "Attacker"}})
    assert view.pid == pid

    assert {:cancel, :event_missing} =
             MemoryJob.perform(%Oban.Job{
               args: %{"user_id" => attacker.id, "exchange_id" => owner_exchange.id}
             })

    assert Memory.list(owner_scope) == [owner_note]
    assert Memory.list(Scope.for_user(attacker)) == []
    assert Workouts.ensure_home_selection(Scope.for_user(attacker), slot) == selected_before
    assert Repo.all(WorkoutPlan) == coach_plans_before

    {:ok, foreign_session} =
      Workouts.start_plan(Scope.for_user(owner), foreign.id, Ecto.UUID.generate())

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(
               init_test_session(conn, %{user_id: attacker.id}),
               ~p"/session/#{foreign_session.id}"
             )

    assert Repo.get!(WorkoutSession, foreign_session.id).state == :started
  end

  test "stale selection is rejected without changing the current selected tuple", _context do
    user = user_fixture()
    first = plan_fixture(user)
    second = plan_fixture(user)
    third = plan_fixture(user)

    {:ok, slot} =
      BurpeeTrainer.Coach.Policy.required_slot(Scope.for_user(user), DateTime.utc_now(:second))

    {:ok, stale} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    {:ok, current} = Workouts.select_home_workout(Scope.for_user(user), stale, first.id)
    assert {:ok, _} = Workouts.select_home_workout(Scope.for_user(user), current, second.id)
    before = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    assert {:error, _} = Workouts.select_home_workout(Scope.for_user(user), stale, third.id)
    assert Workouts.ensure_home_selection(Scope.for_user(user), slot) == before
  end

  test "foreign prepared approval and archived replay leave persisted rows unchanged", _context do
    user = user_fixture()
    counter = fake_authoring_provider(%{"workout_layout" => layout()})
    {:ok, request} = request()

    assert {:ok, stale} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "replayed-review"
             )

    assert {:ok, _current} =
             Coach.prepare_plan(Scope.for_user(user), "10 reps in 2 minutes", request,
               workspace_key: "replayed-review"
             )

    plans_before = Repo.all(WorkoutPlan)
    assert {:error, _} = Coach.approve_plan(scope_fixture(), stale)
    assert Repo.all(WorkoutPlan) == plans_before
    assert Agent.get(counter, & &1.calls) == ["workout_layout", "workout_layout"]

    plan = plan_fixture(user)
    assert {:ok, archived} = Workouts.archive_plan(Scope.for_user(user), plan.id)
    archived_before = Repo.get!(WorkoutPlan, archived.id)
    assert {:error, _} = Workouts.archive_plan(Scope.for_user(user), archived.id)
    assert Repo.get!(WorkoutPlan, archived.id) == archived_before
  end

  test "foreign and completed-session completion attempts leave sealed rows unchanged",
       _context do
    owner = user_fixture()
    intruder = user_fixture()
    plan = plan_fixture(owner)

    assert {:ok, started} =
             Workouts.start_plan(Scope.for_user(owner), plan.id, Ecto.UUID.generate())

    attrs = %{"burpee_count_actual" => 1, "duration_sec_actual" => 1}
    started_before = Repo.get!(WorkoutSession, started.id)

    assert {:error, _} =
             Workouts.complete_session(Scope.for_user(intruder), started.id, attrs, :timed)

    assert Repo.get!(WorkoutSession, started.id) == started_before

    assert {:ok, completed} =
             Workouts.complete_session(Scope.for_user(owner), started.id, attrs, :timed)

    completed_before = Repo.get!(WorkoutSession, completed.id)

    assert {:error, _} =
             Workouts.complete_session(Scope.for_user(owner), completed.id, attrs, :timed)

    assert Repo.get!(WorkoutSession, completed.id) == completed_before
  end

  defp request do
    WorkoutRequest.new(%{
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => nil
    })
  end

  defp layout do
    %{
      "name" => "Prepared plan",
      "rationale" => "Ten steady reps.",
      "phases" => [
        %{
          "sets" => [%{"reps" => 10, "sec_per_rep" => 12, "sec_per_burpee" => 12}],
          "rest_weights" => []
        }
      ]
    }
  end

  defp fake_authoring_provider(responses) do
    original = Application.fetch_env!(:burpee_trainer, :llm_provider)
    on_exit(fn -> Application.put_env(:burpee_trainer, :llm_provider, original) end)
    counter = start_supervised!({Agent, fn -> %{responses: responses, calls: []} end})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    start_supervised!(
      {Bandit,
       plug: {BurpeeTrainer.TestAuthoringProviderPlug, counter: counter},
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false}
    )

    Application.put_env(:burpee_trainer, :llm_provider,
      enabled: true,
      url: "http://127.0.0.1:#{port}/chat/completions",
      api_key: "test-key",
      model: "test-model",
      timeout_ms: 20_000
    )

    counter
  end
end
