defmodule BurpeeTrainer.CoachReconcilerTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures
  import Ecto.Query

  alias BurpeeTrainer.{CoachReconciler, CoachSupervisor, Repo, Workouts}
  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Error, WorkoutPlan, WorkoutSession}

  @now ~U[2025-09-01 12:00:00Z]
  @disabled_config [enabled: false, url: nil, api_key: nil, model: "test-model"]
  @enabled_config [
    enabled: true,
    url: "https://provider.example/v1/chat/completions",
    api_key: "test-key",
    model: "test-model",
    timeout_ms: 1_000
  ]

  test "startup and explicit periodic scans page users and restore fallback-backed desired state" do
    users = [user_fixture(), user_fixture()]
    parent = self()

    page_query = fn
      nil ->
        send(parent, {:page, nil})
        users

      cursor ->
        send(parent, {:page, cursor})
        []
    end

    reconciler =
      start_reconciler(
        user_page_query: page_query,
        provider_options: [config: @disabled_config]
      )

    await_idle(reconciler)
    assert_receive {:page, nil}
    assert_receive {:page, cursor}
    assert cursor == List.last(users).id

    for user <- users do
      recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
      assert_fallback_startable(user, recommendation)
    end

    Repo.delete_all(CoachRecommendation)
    send(reconciler, :periodic_scan)
    await_idle(reconciler)
    assert Repo.aggregate(CoachRecommendation, :count) == 2

    Repo.delete_all(CoachRecommendation)
    CoachReconciler.scan_now()
    await_idle(reconciler)
    assert Repo.aggregate(CoachRecommendation, :count) == 2

    first_user = List.first(users)
    Repo.delete_all(from(r in CoachRecommendation, where: r.user_id == ^first_user.id))
    assert :ok = CoachReconciler.wake(first_user.id, :retry)
    await_idle(reconciler)
    assert Repo.get_by!(CoachRecommendation, user_id: first_user.id)
  end

  test "provider request includes bounded recent history, feedback, constraints, and published library" do
    user = user_fixture()
    library_plan = plan_fixture(user, %{"name" => "Reusable strength"})

    history =
      %WorkoutSession{
        user_id: user.id,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Historical strength",
        burpee_type: :six_count,
        burpee_count_actual: 12,
        duration_sec_actual: 1_200,
        completed_at: DateTime.add(@now, -86_400, :second),
        capture_mode: :logged,
        primary_limiter: :legs,
        preference_feedback: :choose_again
      }
      |> Repo.insert!()

    parent = self()

    req =
      Req.new(
        adapter: fn request ->
          body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
          send(parent, {:provider_context, body["messages"]})
          {request, %Req.Response{status: 503, body: "review context only"}}
        end
      )

    reconciler =
      start_reconciler(
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    assert_receive {:provider_context, messages}, 5_000
    await_idle(reconciler)

    context = messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()

    assert context["deterministic_slot"]["slot_key"] == "2025-09-01:standard"

    assert Enum.any?(context["published_library"], fn plan ->
             plan["id"] == library_plan.id and plan["name"] == "Reusable strength"
           end)

    assert Enum.any?(context["recent_history"], fn session ->
             session["id"] == history.id and session["primary_limiter"] == "legs" and
               session["preference_feedback"] == "choose_again"
           end)

    assert length(context["recent_history"]) <= 16
  end

  test "in-memory queue bounds provider concurrency and drains without polling" do
    users = Enum.map(1..3, fn _ -> user_fixture() end)
    parent = self()
    req = blocking_req(parent, valid_proposal("Bounded candidate"))

    reconciler =
      start_reconciler(
        max_concurrency: 2,
        user_page_query: paged_users(users),
        provider_options: [req: req, config: @enabled_config]
      )

    first = receive_request_task()
    second = receive_request_task()
    refute_receive {:provider_request, _pid}

    state = :sys.get_state(reconciler)
    assert map_size(state.in_flight) == 2
    assert :queue.len(state.queue) == 1

    send(first, :release_provider)
    third = receive_request_task()
    refute third in [first, second]

    send(second, :release_provider)
    send(third, :release_provider)
    await_idle(reconciler)

    assert map_size(:sys.get_state(reconciler).in_flight) == 0
  end

  test "async_nolink provider crash is contained and fallback remains startable" do
    user = user_fixture()
    parent = self()

    req =
      Req.new(
        adapter: fn request ->
          send(parent, {:provider_request, self()})

          receive do
            :crash_provider -> exit(:provider_boom)
          end

          {request, %Req.Response{status: 500, body: "unreachable"}}
        end
      )

    reconciler =
      start_reconciler(
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    task_pid = receive_request_task()
    task_ref = Process.monitor(task_pid)
    send(task_pid, :crash_provider)
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :provider_boom}, 5_000
    _ = :sys.get_state(reconciler)

    recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
    assert is_nil(recommendation.pending_draft_id)
    assert_fallback_startable(user, recommendation)
  end

  test "CoachSupervisor restarts a crashed reconciler and the replacement performs a fresh scan" do
    user = user_fixture()
    parent = self()
    task_supervisor = unique_name(:restart_tasks)
    reconciler_name = unique_name(:restart_reconciler)
    supervisor_name = unique_name(:restart_supervisor)
    req = blocking_req(parent, valid_proposal("Restart candidate"))

    supervisor =
      start_supervised!(
        {CoachSupervisor,
         name: supervisor_name,
         task_supervisor: task_supervisor,
         reconciler_options: [
           name: reconciler_name,
           now: fn -> @now end,
           scan_interval_ms: :infinity,
           user_page_query: paged_users([user]),
           provider_options: [req: req, config: @enabled_config]
         ]}
      )

    child_ids = supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert task_supervisor in child_ids
    assert CoachReconciler in child_ids

    first_task = receive_request_task()
    first_reconciler = Process.whereis(reconciler_name)
    reconciler_ref = Process.monitor(first_reconciler)
    Process.exit(first_reconciler, :kill)
    assert_receive {:DOWN, ^reconciler_ref, :process, ^first_reconciler, :killed}, 5_000

    second_task = receive_request_task()
    second_reconciler = Process.whereis(reconciler_name)
    refute second_reconciler == first_reconciler
    _ = :sys.get_state(supervisor)

    first_task_ref = Process.monitor(first_task)
    assert_receive {:DOWN, ^first_task_ref, :process, ^first_task, _reason}, 5_000

    send(second_task, :release_provider)
    await_idle(second_reconciler)
  end

  test "stopping CoachSupervisor terminates active provider work and date timers" do
    user = user_fixture() |> put_timezone("Etc/UTC")
    parent = self()
    task_supervisor = unique_name(:shutdown_tasks)
    reconciler_name = unique_name(:shutdown_reconciler)
    supervisor_name = unique_name(:shutdown_supervisor)
    req = blocking_req(parent, valid_proposal("Blocked until shutdown"))

    supervisor =
      start_supervised!(
        {CoachSupervisor,
         name: supervisor_name,
         task_supervisor: task_supervisor,
         reconciler_options: [
           name: reconciler_name,
           now: fn -> @now end,
           scan_interval_ms: :infinity,
           user_page_query: paged_users([user]),
           provider_options: [req: req, config: @enabled_config]
         ]}
      )

    task_pid = receive_request_task()
    reconciler = Process.whereis(reconciler_name)
    timer_ref = :sys.get_state(reconciler).date_timers[user.id].ref

    supervisor_ref = Process.monitor(supervisor)
    reconciler_ref = Process.monitor(reconciler)
    task_ref = Process.monitor(task_pid)

    stop_supervised!(CoachSupervisor)

    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :shutdown}, 5_000
    assert_receive {:DOWN, ^reconciler_ref, :process, ^reconciler, _reason}, 5_000
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _reason}, 5_000
    assert Process.read_timer(timer_ref) == false
  end

  test "duplicate provider results attach only one valid candidate" do
    user = user_fixture()
    parent = self()
    req = blocking_req(parent, valid_proposal("Duplicate candidate"))

    first =
      start_reconciler(
        name: unique_name(:duplicate_reconciler),
        task_supervisor: unique_name(:duplicate_tasks),
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    second =
      start_reconciler(
        name: unique_name(:duplicate_reconciler),
        task_supervisor: unique_name(:duplicate_tasks),
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    first_task = receive_request_task()
    second_task = receive_request_task()
    send(first_task, :release_provider)
    send(second_task, :release_provider)
    await_idle(first)
    await_idle(second)

    recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
    assert recommendation.pending_draft_id

    assert Repo.aggregate(
             from(plan in WorkoutPlan,
               where: plan.user_id == ^user.id and plan.origin == :coach and plan.state == :draft
             ),
             :count
           ) == 1
  end

  test "a provider response cannot overwrite a newer manual selection" do
    user = user_fixture()
    provider_plan = plan_fixture(user, %{"name" => "Provider choice"})
    manual_plan = plan_fixture(user, %{"name" => "Manual choice"})
    parent = self()

    req =
      blocking_req(parent, %{
        "action" => "select_existing",
        "workout_plan_id" => provider_plan.id,
        "rationale" => "Provider selection"
      })

    reconciler =
      start_reconciler(
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    task_pid = receive_request_task()
    recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)

    assert {:ok, manually_selected} =
             Workouts.select_recommendation(
               user,
               recommendation.id,
               {:plan, manual_plan.id},
               "User chose this workout"
             )

    send(task_pid, :release_provider)
    await_idle(reconciler)

    persisted = Repo.reload(manually_selected)
    assert persisted.selected_workout_plan_id == manual_plan.id
    assert is_nil(persisted.selected_workout_video_id)
    assert persisted.rationale == "User chose this workout"
  end

  test "a stale create response cannot attach a draft after a newer manual selection" do
    user = user_fixture()
    manual_plan = plan_fixture(user, %{"name" => "Manual choice"})
    parent = self()
    req = blocking_req(parent, valid_proposal("Stale generated candidate"))

    reconciler =
      start_reconciler(
        user_page_query: paged_users([user]),
        provider_options: [req: req, config: @enabled_config]
      )

    task_pid = receive_request_task()
    recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)

    assert {:ok, manually_selected} =
             Workouts.select_recommendation(
               user,
               recommendation.id,
               {:plan, manual_plan.id},
               "User chose this workout"
             )

    send(task_pid, :release_provider)
    await_idle(reconciler)

    persisted = Repo.reload(manually_selected)
    assert persisted.selected_workout_plan_id == manual_plan.id
    assert is_nil(persisted.pending_draft_id)

    assert Repo.aggregate(
             from(plan in WorkoutPlan,
               where: plan.user_id == ^user.id and plan.origin == :coach and plan.state == :draft
             ),
             :count
           ) == 0
  end

  test "disabled or credential-less provider makes no request and persists no AI draft" do
    for config <- [
          @disabled_config,
          Keyword.put(@enabled_config, :api_key, nil),
          Keyword.put(@enabled_config, :url, nil)
        ] do
      user = user_fixture()
      parent = self()

      req =
        Req.new(
          adapter: fn request ->
            send(parent, :unexpected_provider_request)
            {request, %Req.Response{status: 500, body: "unexpected"}}
          end
        )

      reconciler =
        start_reconciler(
          name: unique_name(:unavailable_reconciler),
          task_supervisor: unique_name(:unavailable_tasks),
          user_page_query: paged_users([user]),
          provider_options: [req: req, config: config]
        )

      await_idle(reconciler)
      refute_receive :unexpected_provider_request
      recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
      assert is_nil(recommendation.pending_draft_id)
      assert_fallback_startable(user, recommendation)
    end
  end

  test "provider failure and invalid output leave zero AI drafts and a usable fallback" do
    cases = [
      {503, "provider failed"},
      {200, Jason.encode!(%{"choices" => [%{"message" => %{"content" => "not-json"}}]})}
    ]

    for {status, body} <- cases do
      user = user_fixture()
      parent = self()

      req =
        Req.new(
          adapter: fn request ->
            send(parent, :provider_request_finished)
            {request, %Req.Response{status: status, body: body}}
          end
        )

      reconciler =
        start_reconciler(
          name: unique_name(:failure_reconciler),
          task_supervisor: unique_name(:failure_tasks),
          user_page_query: paged_users([user]),
          provider_options: [req: req, config: @enabled_config]
        )

      assert_receive :provider_request_finished, 5_000
      await_idle(reconciler)
      recommendation = Repo.get_by!(CoachRecommendation, user_id: user.id)
      assert is_nil(recommendation.pending_draft_id)
      assert_fallback_startable(user, recommendation)
    end

    assert Repo.aggregate(
             from(plan in WorkoutPlan, where: plan.origin == :coach and plan.state == :draft),
             :count
           ) == 0
  end

  test "completion wakes only after commit while every failure path stays silent" do
    user = user_fixture()
    plan = plan_fixture(user)
    parent = self()

    req =
      Req.new(
        adapter: fn request ->
          persisted = Repo.get_by!(WorkoutSession, user_id: user.id, state: :completed)
          send(parent, {:completion_wake, self(), persisted.id})

          receive do
            :release_provider ->
              {request, %Req.Response{status: 503, body: "best effort unavailable"}}
          end
        end
      )

    reconciler =
      start_reconciler(
        user_page_query: paged_users([]),
        provider_options: [req: req, config: @enabled_config]
      )

    await_idle(reconciler)
    assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    assert {:ok, completed} =
             Workouts.complete_session(
               user,
               started.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :timed
             )

    assert_receive {:completion_wake, task_pid, completed_id}, 5_000
    assert completed_id == completed.id
    send(task_pid, :release_provider)
    await_idle(reconciler)

    assert {:error, %Error{code: :session_already_completed}} =
             Workouts.complete_session(
               user,
               completed.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :timed
             )

    _ = :sys.get_state(reconciler)
    refute_receive {:completion_wake, _, _}

    assert {:ok, invalid_started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    assert {:error, %Ecto.Changeset{}} =
             Workouts.complete_session(
               user,
               invalid_started.id,
               %{
                 "burpee_count_actual" => 1,
                 "duration_sec_actual" => 1,
                 "context_low_energy" => true,
                 "context_high_energy" => true
               },
               :timed
             )

    _ = :sys.get_state(reconciler)
    refute_receive {:completion_wake, _, _}

    assert {:ok, rolled_back} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())

    assert {:error, %Ecto.Changeset{}} =
             Workouts.complete_session(
               user,
               rolled_back.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :invalid_capture
             )

    assert Repo.get!(WorkoutSession, rolled_back.id).state == :started
    _ = :sys.get_state(reconciler)
    refute_receive {:completion_wake, _, _}

    intruder = user_fixture()

    assert {:error, %Error{code: :session_not_owned}} =
             Workouts.complete_session(
               intruder,
               invalid_started.id,
               %{"burpee_count_actual" => 1, "duration_sec_actual" => 1},
               :timed
             )

    _ = :sys.get_state(reconciler)
    refute_receive {:completion_wake, _, _}
  end

  test "failed goal-attributing completion rolls back and sends no wake" do
    user = user_fixture()
    plan = plan_fixture(user)

    _goal =
      goal_fixture(user, %{
        "burpee_count_target" => 10,
        "burpee_count_baseline" => 5
      })

    assert {:ok, started} = Workouts.start_plan(user, plan.id, Ecto.UUID.generate())
    parent = self()

    req =
      Req.new(
        adapter: fn request ->
          send(parent, :unexpected_goal_failure_wake)
          {request, %Req.Response{status: 503, body: "unexpected"}}
        end
      )

    reconciler =
      start_reconciler(
        user_page_query: paged_users([]),
        provider_options: [req: req, config: @enabled_config]
      )

    await_idle(reconciler)

    assert {:error, %Ecto.Changeset{}} =
             Workouts.complete_session(
               user,
               started.id,
               %{
                 "burpee_count_actual" => 10,
                 "duration_sec_actual" => 1_200,
                 "context_low_energy" => true,
                 "context_high_energy" => true
               },
               :timed
             )

    _ = :sys.get_state(reconciler)
    refute_receive :unexpected_goal_failure_wake
    assert Repo.get!(WorkoutSession, started.id).state == :started
  end

  test "date transition schedules the next local boundary and Monday follows the same path" do
    user = user_fixture() |> put_timezone("Etc/UTC")
    sunday = ~U[2025-09-07 12:00:00Z]

    reconciler =
      start_reconciler(
        now: fn -> sunday end,
        user_page_query: paged_users([user]),
        provider_options: [config: @disabled_config]
      )

    await_idle(reconciler)
    first = :sys.get_state(reconciler).date_timers[user.id]
    assert first.transition_at == ~U[2025-09-08 00:00:00Z]

    send(reconciler, {:date_transition, user.id, first.token, first.transition_at})
    await_idle(reconciler)

    assert Repo.get_by!(CoachRecommendation,
             user_id: user.id,
             slot_key: "2025-09-08:standard"
           )

    next = :sys.get_state(reconciler).date_timers[user.id]
    refute next.token == first.token
    assert next.transition_at == ~U[2025-09-09 00:00:00Z]
  end

  test "DST transition day uses UserTime local boundaries" do
    user = user_fixture() |> put_timezone("America/New_York")
    before_spring_forward = ~U[2025-03-08 12:00:00Z]

    reconciler =
      start_reconciler(
        now: fn -> before_spring_forward end,
        user_page_query: paged_users([user]),
        provider_options: [config: @disabled_config]
      )

    await_idle(reconciler)
    first = :sys.get_state(reconciler).date_timers[user.id]
    assert first.transition_at == ~U[2025-03-09 05:00:00Z]

    send(reconciler, {:date_transition, user.id, first.token, first.transition_at})
    await_idle(reconciler)

    next = :sys.get_state(reconciler).date_timers[user.id]
    assert next.transition_at == ~U[2025-03-10 04:00:00Z]
    assert DateTime.diff(next.transition_at, first.transition_at, :hour) == 23
  end

  test "timezone changes replace timers and stale transition messages are inert" do
    user = user_fixture() |> put_timezone("Etc/UTC")
    now = ~U[2025-09-01 12:00:00Z]

    reconciler =
      start_reconciler(
        now: fn -> now end,
        user_page_query: paged_users([user]),
        provider_options: [config: @disabled_config]
      )

    await_idle(reconciler)
    stale = :sys.get_state(reconciler).date_timers[user.id]
    updated_user = put_timezone(user, "America/Los_Angeles")

    GenServer.cast(reconciler, {:wake, updated_user.id, :timezone_changed})
    await_idle(reconciler)
    replacement = :sys.get_state(reconciler).date_timers[user.id]

    refute replacement.token == stale.token
    assert replacement.timezone == "America/Los_Angeles"
    assert replacement.transition_at == ~U[2025-09-02 07:00:00Z]

    send(reconciler, {:date_transition, user.id, stale.token, stale.transition_at})
    _ = :sys.get_state(reconciler)

    assert :sys.get_state(reconciler).date_timers[user.id] == replacement

    refute Repo.get_by(CoachRecommendation,
             user_id: user.id,
             slot_key: "2025-09-02:standard"
           )
  end

  test "reconciler restart reconstructs date timers from a persisted-user scan" do
    user = user_fixture() |> put_timezone("Europe/Stockholm")
    now = ~U[2025-10-25 12:00:00Z]

    first =
      start_reconciler(
        now: fn -> now end,
        user_page_query: &BurpeeTrainer.Accounts.list_users_page/1,
        provider_options: [config: @disabled_config]
      )

    await_idle(first)
    first_timer = :sys.get_state(first).date_timers[user.id]
    first_ref = Process.monitor(first)
    stop_supervised!(CoachReconciler)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :shutdown}, 5_000

    replacement =
      start_reconciler(
        now: fn -> now end,
        user_page_query: &BurpeeTrainer.Accounts.list_users_page/1,
        provider_options: [config: @disabled_config]
      )

    await_idle(replacement)
    replacement_timer = :sys.get_state(replacement).date_timers[user.id]

    refute replacement_timer.token == first_timer.token
    assert replacement_timer.timezone == "Europe/Stockholm"
    assert replacement_timer.transition_at == first_timer.transition_at
  end

  test "scan restores archived plan and unavailable video selections atomically without changing pending draft" do
    user = user_fixture()
    archived = plan_fixture(user)
    unavailable_video = video_fixture(%{available: false})

    {:ok, recommendation} =
      Workouts.ensure_recommendation(user, %{
        slot_key: "2025-09-01:standard",
        slot_date: ~D[2025-09-01],
        rationale: "Fallback"
      })

    {:ok, attached} =
      Workouts.attach_candidate(user, recommendation.id, candidate_attrs("Pending candidate"))

    pending_draft_id = attached.pending_draft_id
    {:ok, _archived} = Workouts.archive_plan(user, archived.id)

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: archived.id, selected_workout_video_id: nil]
    )

    reconciler =
      start_reconciler(
        user_page_query: paged_users([user]),
        provider_options: [config: @disabled_config]
      )

    await_idle(reconciler)
    available_plan = Repo.reload(recommendation)
    assert available_plan.pending_draft_id == pending_draft_id
    assert_fallback_selection(available_plan)

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: nil, selected_workout_video_id: unavailable_video.id]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    available_video = Repo.reload(recommendation)
    assert available_video.pending_draft_id == pending_draft_id
    assert_fallback_selection(available_video)

    # Missing foreign rows are not reachable through normal writes because the
    # schema uses RESTRICT FKs. Deferred constraints let this test characterize
    # reconciliation of a corrupted/imported row without committing corruption.
    Ecto.Adapters.SQL.query!(Repo, "PRAGMA defer_foreign_keys = ON")
    missing_plan_id = Repo.aggregate(WorkoutPlan, :max, :id) + 10_000

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: missing_plan_id, selected_workout_video_id: nil]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    available_missing_plan = Repo.reload(recommendation)
    assert available_missing_plan.pending_draft_id == pending_draft_id
    assert_fallback_selection(available_missing_plan)

    missing_video_id = unavailable_video.id + 10_000

    Repo.update_all(from(r in CoachRecommendation, where: r.id == ^recommendation.id),
      set: [selected_workout_plan_id: nil, selected_workout_video_id: missing_video_id]
    )

    CoachReconciler.scan_now()
    await_idle(reconciler)
    available_missing_video = Repo.reload(recommendation)
    assert available_missing_video.pending_draft_id == pending_draft_id
    assert_fallback_selection(available_missing_video)
  end

  defp start_reconciler(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, unique_name(:coach_tasks))
    name = Keyword.get(opts, :name, CoachReconciler)

    start_supervised!(
      Supervisor.child_spec({Task.Supervisor, name: task_supervisor}, id: task_supervisor)
    )

    reconciler_opts =
      opts
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:now, fn -> @now end)
      |> Keyword.put_new(:scan_interval_ms, :infinity)

    start_supervised!(Supervisor.child_spec({CoachReconciler, reconciler_opts}, id: name))
  end

  defp paged_users(users) do
    fn
      nil -> users
      _cursor -> []
    end
  end

  defp blocking_req(test_pid, proposal) do
    body = provider_body(proposal)

    Req.new(
      adapter: fn request ->
        send(test_pid, {:provider_request, self()})

        receive do
          :release_provider -> {request, %Req.Response{status: 200, body: body}}
        end
      end
    )
  end

  defp receive_request_task do
    receive do
      {:provider_request, pid} -> pid
    after
      2_000 -> flunk("provider task did not reach adapter")
    end
  end

  defp await_idle(reconciler) do
    state = :sys.get_state(reconciler)

    case {Map.values(state.in_flight), :queue.is_empty(state.queue)} do
      {[], true} ->
        :ok

      {tasks, _queue_empty?} ->
        refs = Enum.map(tasks, fn %{pid: pid} -> {pid, Process.monitor(pid)} end)

        Enum.each(refs, fn {pid, ref} ->
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        end)

        _ = :sys.get_state(reconciler)
        await_idle(reconciler)
    end
  end

  defp assert_fallback_startable(user, recommendation) do
    assert_fallback_selection(recommendation)

    assert {:ok, _session} =
             Workouts.start_plan(
               user,
               recommendation.selected_workout_plan_id,
               Ecto.UUID.generate()
             )
  end

  defp assert_fallback_selection(recommendation) do
    fallback = Repo.get!(WorkoutPlan, recommendation.selected_workout_plan_id)
    assert fallback.origin == :built_in
    assert fallback.state == :published
    assert is_nil(recommendation.selected_workout_video_id)
  end

  defp provider_body(content) do
    Jason.encode!(%{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]
    })
  end

  defp valid_proposal(name) do
    %{
      "action" => "create",
      "definition" => candidate_attrs(name).definition,
      "rationale" => "One measured change"
    }
  end

  defp candidate_attrs(name) do
    %{
      request_text: "Make a focused workout",
      definition: %{
        "version" => 1,
        "name" => name,
        "burpee_type" => "six_count",
        "target_duration_sec" => 1_200,
        "target_reps" => 10,
        "pacing_style" => "even",
        "rationale" => "Focused work",
        "events" => [
          %{
            "kind" => "work",
            "reps" => 10,
            "sec_per_burpee" => 120.0,
            "sec_per_rep" => 120.0
          }
        ]
      }
    }
  end

  defp put_timezone(%User{} = user, timezone) do
    user
    |> User.timezone_changeset(%{timezone: timezone})
    |> Repo.update!()
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
  end
end
