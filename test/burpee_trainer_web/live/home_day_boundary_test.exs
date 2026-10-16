defmodule BurpeeTrainerWeb.HomeLiveDayBoundaryTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import BurpeeTrainer.Fixtures
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias BurpeeTrainer.{Accounts, Repo, Workouts}
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutPlan, WorkoutSession}
  alias BurpeeTrainerWeb.HomeLive

  @tuesday ~U[2025-09-02 12:00:00Z]
  @wednesday ~U[2025-09-03 12:00:00Z]
  @monday ~U[2025-09-08 00:00:00Z]
  @workspace_keys [
    :home_selection,
    :instruction,
    :expanded?,
    :expanded_groups,
    :filters,
    :alternatives_open?,
    :filters_open?,
    :start_client_session_id,
    :busy?,
    :update_id
  ]

  setup do
    user = user_fixture()
    {:ok, user} = Accounts.update_timezone(user, "Etc/UTC")
    previous = Req.default_options()
    parent = self()

    Req.default_options(
      adapter: fn _ ->
        send(parent, :unexpected_provider)
        raise "unexpected provider"
      end
    )

    on_exit(fn -> Req.default_options(previous) end)
    %{user: user}
  end

  test "Tuesday completion becomes weekly completion then a usable Monday fallback without resetting presentation",
       %{user: user} do
    complete(user, @tuesday, 4800)
    socket = mount_home(user, @tuesday)
    assert socket.assigns.slot.home_state == :done_today
    assert socket.assigns.home_selection == nil

    {:noreply, socket} =
      workspace_screen(socket, :history)

    {:noreply, socket} = HomeLive.handle_event("history_period", %{"period" => "all"}, socket)
    socket = assign(socket, instruction: "Keep this text", expanded?: true, filters_open?: true)
    before = Map.take(socket.assigns, @workspace_keys -- [:home_selection])
    socket = refresh(socket, @wednesday)
    assert socket.assigns.slot.home_state == :week_complete
    assert socket.assigns.slot.completed_sec == 4800
    assert socket.assigns.workspace_screen == :history
    assert present?(socket, "#home-history-heading")
    refute present?(socket, "#home-week-complete, #home-action")
    {:noreply, home} = workspace_screen(socket, :home)
    assert present?(home, "#home-week-complete")

    socket = refresh(socket, @monday)
    assert socket.assigns.slot.home_state == :workout_needed
    assert socket.assigns.slot.completed_sec == 0
    assert socket.assigns.home_selection.plan.id
    assert socket.assigns.inspection_rows != []
    assert socket.assigns.history_open?
    assert socket.assigns.history_period == "all"
    assert present?(socket, "#home-history-close[phx-click=close_history]")
    assert Map.take(socket.assigns, @workspace_keys -- [:home_selection]) == before
    refute present?(socket, "#home-action")
    {:noreply, home} = workspace_screen(socket, :home)
    assert present?(home, "#home-action")
    selection = socket.assigns.home_selection
    recommendation = Repo.get!(CoachRecommendation, selection.recommendation_id)
    repeated = refresh(socket, @monday)
    assert repeated.assigns.home_selection == selection
    assert Repo.reload!(recommendation) == recommendation
    assert Repo.aggregate(CoachRecommendation, :count) == 1
    assert socket.assigns.home_day_timer == nil
    refute_received :unexpected_provider
  end

  test "idle selected slot rollover reconciles the offered card and Start without resetting drafts",
       %{user: user} do
    now = DateTime.utc_now(:second)
    plan_fixture(user)
    socket = mount_home(user, DateTime.add(now, -86_400))
    old = socket.assigns.home_selection

    {:noreply, socket} =
      HomeLive.handle_event(
        "change_adjustment",
        %{"home_adjustment" => %{"instruction" => "Unsent adjustment"}},
        socket
      )

    socket =
      assign(socket, expanded?: true, expanded_groups: MapSet.new(["group"]), filters_open?: true)

    before =
      Map.take(
        socket.assigns,
        (@workspace_keys -- [:home_selection]) ++
          [:adjustment_form, :coach_message_form, :workout_form]
      )

    refreshed = refresh(socket, now)
    assert {:start, selected} = refreshed.assigns.home_state
    refute selected.recommendation_id == old.recommendation_id
    assert refreshed.assigns.home_facts.selection == selected
    assert refreshed.assigns.home_selection == selected

    assert refreshed.assigns.inspection_rows ==
             BurpeeTrainer.Workouts.Inspection.rows(selected.plan)

    assert Map.take(
             refreshed.assigns,
             (@workspace_keys -- [:home_selection]) ++
               [:adjustment_form, :coach_message_form, :workout_form]
           ) == before

    assert present?(refreshed, "#home-action[data-primary-action=start]")
    assert card_name(refreshed) == selected.plan.name
    assert_started_selection(refreshed, selected)
  end

  test "idle intervening pointer and corrupt pointer repair reconcile genuine revisions before Start",
       %{user: user} do
    now = DateTime.utc_now(:second)
    plan_fixture(user)
    replacement = plan_fixture(user, %{name: "Intervening selection", target_reps: 60})
    socket = mount_home(user, now)
    old = socket.assigns.home_selection
    {:ok, intervening} = Workouts.select_home_workout(Scope.for_user(user), old, replacement.id)
    refreshed = refresh(socket, now)
    assert refreshed.assigns.home_facts.selection == intervening
    assert refreshed.assigns.home_selection == intervening

    assert refreshed.assigns.inspection_rows ==
             BurpeeTrainer.Workouts.Inspection.rows(replacement)

    assert card_name(refreshed) == replacement.name
    assert refreshed.assigns.start_client_session_id == socket.assigns.start_client_session_id

    # Persist a genuinely corrupt pointer. The real loader repairs it through the
    # unchanged Domain API; WEB must project that new revision, not invent a pin.
    Repo.get!(CoachRecommendation, intervening.recommendation_id)
    |> Ecto.Changeset.change(home_workout_plan_id: nil)
    |> Repo.update!()

    repaired = refresh(refreshed, now)
    assert {:start, selected} = repaired.assigns.home_state
    assert selected.home_revision > intervening.home_revision
    assert repaired.assigns.home_facts.selection == selected
    assert repaired.assigns.home_selection == selected

    assert repaired.assigns.inspection_rows ==
             BurpeeTrainer.Workouts.Inspection.rows(selected.plan)

    assert card_name(repaired) == selected.plan.name
    assert present?(repaired, "#home-action[data-primary-action=start]")
    assert_started_selection(repaired, selected)
  end

  test "idle corrupt pointer repair alone replaces the old inspection and Start revision", %{
    user: user
  } do
    now = DateTime.utc_now(:second)
    plan_fixture(user)
    socket = mount_home(user, now)
    old = socket.assigns.home_selection

    Repo.get!(CoachRecommendation, old.recommendation_id)
    |> Ecto.Changeset.change(home_workout_plan_id: nil)
    |> Repo.update!()

    repaired = refresh(socket, now)
    assert {:start, selected} = repaired.assigns.home_state
    assert selected.home_revision > old.home_revision
    assert repaired.assigns.home_selection == selected
    assert repaired.assigns.home_facts.selection == selected

    assert repaired.assigns.inspection_rows ==
             BurpeeTrainer.Workouts.Inspection.rows(selected.plan)

    assert card_name(repaired) == selected.plan.name
    assert_started_selection(repaired, selected)
  end

  test "ordinary next day initializes once and does not claim first use", %{user: user} do
    complete(user, @tuesday, 600)
    socket = mount_home(user, @tuesday) |> refresh(@wednesday)
    assert socket.assigns.slot.home_state == :workout_needed
    assert socket.assigns.slot.completed_sec == 600
    assert socket.assigns.home_selection.plan.origin == :built_in
    assert refresh(socket, @wednesday).assigns.home_selection == socket.assigns.home_selection
    refute_received :unexpected_provider
  end

  test "busy completion transition never initializes a selection", %{user: user} do
    complete(user, @tuesday, 600)
    id = make_ref()

    socket =
      mount_home(user, @tuesday) |> assign(busy?: true, update_id: id, instruction: "Waiting")

    refreshed = refresh(socket, @wednesday)
    assert refreshed.assigns.home_selection == nil
    assert refreshed.assigns.busy?
    assert refreshed.assigns.update_id == id
    assert refreshed.assigns.instruction == "Waiting"
    assert Repo.aggregate(CoachRecommendation, :count) == 0
    refute_received :unexpected_provider
  end

  test "busy History refresh keeps the entire genuine Home snapshot coherent until a safe idle boundary",
       %{user: user} do
    complete(user, @tuesday, 600)
    socket = mount_home(user, @tuesday)
    {:noreply, socket} = workspace_screen(socket, :history)
    socket = assign(socket, busy?: true, instruction: "Keep this draft", expanded?: true)

    keys = [
      :home_facts,
      :home_state,
      :home_primary_action,
      :slot,
      :home_selection,
      :started_session,
      :home_snapshot_now
    ]

    before = Map.take(socket.assigns, keys)
    refreshed = refresh(socket, @wednesday)
    assert Map.take(refreshed.assigns, keys) == before
    assert refreshed.assigns.history_snapshot_now == @wednesday
    assert Repo.aggregate(CoachRecommendation, :count) == 0

    idle = refreshed |> assign(busy?: false) |> refresh(@wednesday)
    assert idle.assigns.home_snapshot_now == @wednesday
    assert {:start, selected} = idle.assigns.home_state
    assert idle.assigns.home_facts.selection == selected
    assert idle.assigns.home_selection == selected
    assert idle.assigns.instruction == "Keep this draft"
    assert idle.assigns.expanded?
    assert Repo.aggregate(CoachRecommendation, :count) == 1
  end

  test "persisted unfinished session remains Resume across today, week and Monday", %{user: user} do
    complete(user, @tuesday, 4800)
    socket = mount_home(user, @tuesday)
    plan = plan_fixture(user)
    {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())

    for now <- [@tuesday, @wednesday, @monday] do
      refreshed = refresh(socket, now)
      assert refreshed.assigns.started_session.id == started.id
      assert refreshed.assigns.home_selection == nil

      assert present?(
               refreshed,
               "#resume-recommended-workout[phx-value-session-id='#{started.id}']"
             )

      refute present?(refreshed, "#home-action")
      assert Repo.reload!(started) == started
    end

    assert Repo.aggregate(CoachRecommendation, :count) == 0
    refute_received :unexpected_provider
  end

  test "transaction rechecks a newly persisted unfinished session before fallback write", %{
    user: user
  } do
    complete(user, @tuesday, 600)
    socket = mount_home(user, @tuesday)
    plan = plan_fixture(user)
    parent = self()

    clock = fn ->
      count = Process.get(:boundary_clock_reads, 0) + 1
      Process.put(:boundary_clock_reads, count)

      if count == 2 do
        {:ok, started} = Workouts.start_plan(Scope.for_user(user), plan.id, Ecto.UUID.generate())
        send(parent, {:started_in_recheck, started.id})
      end

      @wednesday
    end

    {:noreply, refreshed} =
      HomeLive.handle_info(
        {:home_day_boundary, 1},
        assign(socket, home_now: clock, home_day_generation: 1)
      )

    # The injected competing write shares the outer transaction and is rolled back
    # with it; the important assertion is that the persisted recheck vetoed initialization.
    assert_received {:started_in_recheck, _}
    assert refreshed.assigns.home_selection == nil
    assert refreshed.assigns.local_error =~ "next workout is unavailable"
    assert Repo.aggregate(CoachRecommendation, :count) == 0
  end

  test "transaction rechecks policy rather than applying an expired completion transition", %{
    user: user
  } do
    complete(user, @tuesday, 600)
    socket = mount_home(user, @tuesday)

    clock = fn ->
      count = Process.get(:policy_clock_reads, 0) + 1
      Process.put(:policy_clock_reads, count)
      if count == 1, do: @wednesday, else: @tuesday
    end

    {:noreply, refreshed} =
      HomeLive.handle_info(
        {:home_day_boundary, 1},
        assign(socket, home_now: clock, home_day_generation: 1)
      )

    assert refreshed.assigns.home_selection == nil
    assert refreshed.assigns.local_error =~ "next workout is unavailable"
    assert Repo.aggregate(CoachRecommendation, :count) == 0
  end

  test "isolated missing fallback fails locally and History never retries initialization", %{
    user: user
  } do
    complete(user, @tuesday, 600)
    socket = mount_home(user, @tuesday)
    # Sandbox-only fallback failure; this is not an onboarding fixture.
    Repo.update_all(
      from(p in WorkoutPlan,
        where: is_nil(p.user_id) and p.origin == :built_in and p.state == :published
      ),
      set: [state: :archived, archived_at: DateTime.utc_now(:second)]
    )

    refreshed = refresh(socket, @wednesday)
    assert refreshed.assigns.home_selection == nil
    assert present?(refreshed, "#home-initialization-error")
    assert present?(refreshed, "a#home-fallback-reload[href='/']")
    refute present?(refreshed, "#retry-recommendation-button")
    {:noreply, opened} = workspace_screen(refreshed, :history)
    {:noreply, closing} = HomeLive.handle_event("close_history", %{}, opened)
    {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
    assert closed.assigns.local_error == refreshed.assigns.local_error
    assert Repo.aggregate(CoachRecommendation, :count) == 0
    assert refresh(closed, @wednesday).assigns.home_selection == nil
    refute_received :unexpected_provider
  end

  test "invalid timezone has no fabricated slot, selection or writes and History can close", %{
    user: user
  } do
    user = %{user | timezone: "Invalid/Zone"}
    counts = counts()
    socket = mount_home(user, @tuesday)
    assert socket.assigns.slot == nil
    assert socket.assigns.home_selection == nil
    assert socket.assigns.home_day_timer == nil
    assert present?(socket, "#home-progress-unavailable")
    assert present?(socket, "#home-history-toggle")
    assert present?(socket, "a#home-reload[href='/']")
    refute present?(socket, "#home-week-track, #home-action, #retry-recommendation-button")
    {:noreply, opened} = workspace_screen(socket, :history)
    assert present?(opened, "#home-history-error")

    assert present?(
             opened,
             "#home-history-close[aria-label='Back to Home'][phx-click=close_history]"
           )

    refute present?(opened, "#home-history-toggle, #home-state-content")
    {:noreply, closing} = HomeLive.handle_event("close_history", %{}, opened)
    {:noreply, closed} = workspace_screen(%{closing | redirected: nil}, :home)
    refute closed.assigns.history_open?
    assert closed.assigns.home_error == socket.assigns.home_error
    assert counts() == counts
    refute_received :unexpected_provider
  end

  test "working owned draft, token, input, groups, filters and in-flight identity survive refresh",
       %{user: user} do
    now = DateTime.utc_now(:second)
    draft = workout_plan_draft_fixture(user)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
    {:ok, _selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    socket = mount_home(user, now)

    Repo.get!(CoachRecommendation, socket.assigns.home_selection.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: draft.id)
    |> Repo.update!()

    {:noreply, socket} =
      HomeLive.handle_event(
        "select_alternative",
        %{"kind" => "plan", "id" => to_string(draft.id)},
        socket
      )

    assert socket.assigns.home_selection.plan.id == draft.id

    socket =
      assign(socket,
        instruction: "My unsent text",
        expanded_groups: MapSet.new(["group"]),
        filters_open?: true,
        alternatives_open?: true,
        busy?: true,
        update_id: make_ref()
      )

    before = Map.take(socket.assigns, @workspace_keys)

    recommendation =
      Repo.get!(CoachRecommendation, socket.assigns.home_selection.recommendation_id)

    refreshed = refresh(socket, @monday)
    assert Map.take(refreshed.assigns, @workspace_keys) == before
    assert refreshed.assigns.slot.completed_sec == 0
    assert Repo.reload!(recommendation) == recommendation
    assert Repo.reload!(draft) == draft
    refute_received :unexpected_provider
  end

  test "boundary retains inspected older rows in period, removes expired rows and captures time once",
       %{user: user} do
    rows = for _ <- 1..8, do: complete(user, @tuesday, 600)
    oldest = hd(rows)
    socket = mount_home(user, @tuesday)
    {:noreply, socket} = workspace_screen(socket, :history)

    {:noreply, socket} =
      HomeLive.handle_event("history_session", %{"id" => to_string(oldest.id)}, socket)

    assert length(socket.assigns.history_loaded_ids) == 6
    parent = self()

    clock = fn ->
      send(parent, :clock_read)
      @wednesday
    end

    {:noreply, socket} =
      HomeLive.handle_info(
        {:home_day_boundary, 1},
        assign(socket, home_now: clock, home_day_generation: 1)
      )

    assert_received :clock_read
    refute_received :clock_read
    assert oldest.id in socket.assigns.history_loaded_ids
    assert MapSet.member?(socket.assigns.history_expanded, oldest.id)
    assert length(socket.assigns.history_loaded_ids) == 6
    new = complete(user, @wednesday, 60)
    socket = socket |> prune_history_stream() |> refresh(@wednesday)
    refute socket.assigns.streams.history_sessions.reset?
    assert hd(socket.assigns.history_loaded_ids) == new.id
    assert oldest.id in socket.assigns.history_loaded_ids
    assert length(socket.assigns.history_loaded_ids) == 7
    repeated = socket |> prune_history_stream() |> refresh(@wednesday)
    refute repeated.assigns.streams.history_sessions.reset?
    assert repeated.assigns.streams.history_sessions.deletes == []
    assert repeated.assigns.history_loaded_ids == socket.assigns.history_loaded_ids
    {:noreply, socket} = HomeLive.handle_event("history_more", %{}, repeated)
    assert socket.assigns.history_loaded_ids == [new.id | Enum.map(Enum.reverse(rows), & &1.id)]
    refute socket.assigns.history_has_more?
    expired_at = DateTime.add(@monday, 12 * 7 * 86_400)
    socket = socket |> prune_history_stream() |> refresh(expired_at)
    refute socket.assigns.streams.history_sessions.reset?
    assert length(socket.assigns.streams.history_sessions.deletes) == 9
    assert socket.assigns.history_loaded_ids == []
    assert socket.assigns.history_empty?
    assert socket.assigns.history_open?
    {:noreply, socket} = HomeLive.handle_event("history_period", %{"period" => "all"}, socket)
    assert length(socket.assigns.history_loaded_ids) == 5
    refute oldest.id in socket.assigns.history_loaded_ids
  end

  test "unavailable refresh preserves draft and busy text, and a late failure stays recoverable",
       %{user: user} do
    complete(user, @tuesday, 1200)
    socket = mount_home(user, DateTime.utc_now(:second))
    {:noreply, socket} = workspace_screen(socket, :history)
    id = make_ref()

    socket =
      assign(socket,
        busy?: true,
        update_id: id,
        instruction: "Keep text",
        current_scope: BurpeeTrainer.Accounts.Scope.for_user(%{user | timezone: "Invalid/Zone"})
      )

    before = Map.take(socket.assigns, @workspace_keys)
    socket = refresh(socket, @wednesday)
    assert Map.take(socket.assigns, @workspace_keys) == before
    assert socket.assigns.slot == nil
    assert present?(socket, "#home-history-error")

    {:noreply, socket} =
      HomeLive.handle_async({:home_revision, id}, {:ok, {:error, :unavailable}}, socket)

    refute socket.assigns.busy?
    assert socket.assigns.instruction == "Keep text"
    assert socket.assigns.home_selection == before.home_selection
    assert present?(socket, "#home-history-error")
    {:noreply, home} = workspace_screen(socket, :home)
    assert present?(home, "#home-unavailable")
  end

  test "fresh mount recomputes time and preserves the persisted owned pin", %{user: user} do
    now = DateTime.utc_now(:second)
    draft = workout_plan_draft_fixture(user)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
    {:ok, _selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    socket = mount_home(user, now)

    Repo.get!(CoachRecommendation, socket.assigns.home_selection.recommendation_id)
    |> Ecto.Changeset.change(pending_draft_id: draft.id)
    |> Repo.update!()

    {:noreply, socket} =
      HomeLive.handle_event(
        "select_alternative",
        %{"kind" => "plan", "id" => to_string(draft.id)},
        socket
      )

    reopened = mount_home(user, now)
    assert reopened.assigns.home_selection == socket.assigns.home_selection
    assert reopened.assigns.home_snapshot_now == now
    # A new process does not promise recovery of unsent editor text.
    assert reopened.assigns.instruction == ""
    refute_received :unexpected_provider
  end

  test "stale generation and mismatched async identity leave the socket unchanged", %{user: user} do
    socket = mount_home(user, @tuesday)
    assert {:noreply, ^socket} = HomeLive.handle_info({:home_day_boundary, -1}, socket)

    assert {:noreply, ^socket} =
             HomeLive.handle_async({:home_revision, make_ref()}, {:ok, {:ok, %{}}}, socket)
  end

  test "formerly successful async selection must still pass domain authorization", %{user: user} do
    now = DateTime.utc_now(:second)
    {:ok, slot} = Policy.required_slot(Scope.for_user(user), now)
    {:ok, _selected} = Workouts.ensure_home_selection(Scope.for_user(user), slot)
    socket = mount_home(user, now)
    selected = socket.assigns.home_selection

    Repo.get!(CoachRecommendation, selected.recommendation_id)
    |> Ecto.Changeset.change(slot_key: "obsolete-slot")
    |> Repo.update!()

    id = make_ref()

    socket =
      assign(socket,
        busy?: true,
        update_id: id,
        instruction: "Keep this adjustment",
        history_open?: true
      )

    {:noreply, result} =
      HomeLive.handle_async({:home_revision, id}, {:ok, {:ok, selected}}, socket)

    refute result.assigns.busy?
    assert result.assigns.update_id == nil
    assert result.assigns.home_selection == selected
    assert result.assigns.instruction == "Keep this adjustment"
    assert result.assigns.history_open?
    assert result.assigns.start_client_session_id == socket.assigns.start_client_session_id

    assert result.assigns.local_error ==
             "The training day or workout changed. Reopen Home before starting or updating."

    assert Workouts.current_started_session(Scope.for_user(user)) == nil
  end

  test "connected scheduling cancels old timers and invalid timezone stops scheduling", %{
    user: user
  } do
    socket = mount_home(user, @tuesday, true)
    first = socket.assigns.home_day_timer
    on_exit(fn -> Process.cancel_timer(first) end)
    assert is_integer(Process.read_timer(first))
    refreshed = refresh(socket, @wednesday)
    second = refreshed.assigns.home_day_timer
    on_exit(fn -> Process.cancel_timer(second) end)
    assert Process.read_timer(first) == false
    assert is_integer(Process.read_timer(second))
    assert refreshed.assigns.home_day_generation == socket.assigns.home_day_generation + 1

    refreshed =
      refresh(
        assign(refreshed,
          current_scope: BurpeeTrainer.Accounts.Scope.for_user(%{user | timezone: "Invalid/Zone"})
        ),
        @wednesday
      )

    assert refreshed.assigns.home_day_timer == nil
    assert Process.read_timer(second) == false
    assert refreshed.assigns.slot == nil
  end

  defp mount_home(user, now, connected? \\ false) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: BurpeeTrainerWeb.Endpoint,
      transport_pid: if(connected?, do: self()),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
      assigns: %{
        __changed__: %{},
        current_scope: BurpeeTrainer.Accounts.Scope.for_user(user),
        current_level: :level_1a,
        flash: %{},
        home_now: fn -> now end
      }
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket
  end

  defp refresh(socket, now) do
    {:noreply, refreshed} =
      HomeLive.handle_info(
        {:home_day_boundary, socket.assigns.home_day_generation},
        assign(socket, home_now: fn -> now end)
      )

    refreshed
  end

  defp complete(user, at, seconds) do
    Repo.insert!(%WorkoutSession{
      user_id: user.id,
      state: :completed,
      source_kind: :manual,
      capture_mode: :logged,
      burpee_type: :six_count,
      completed_at: at,
      burpee_count_actual: 30,
      duration_sec_actual: seconds
    })
  end

  # Direct callbacks do not execute LiveView's after-render pruning lifecycle.
  defp prune_history_stream(socket) do
    streams =
      Map.update!(socket.assigns.streams, :history_sessions, &Phoenix.LiveView.LiveStream.prune/1)

    %{socket | assigns: Map.put(socket.assigns, :streams, streams)}
  end

  defp card_name(socket) do
    render_component(&HomeLive.render/1, socket.assigns)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#home-summary .home-workout-name")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp assert_started_selection(socket, selected) do
    {:noreply, started_socket} =
      HomeLive.handle_event(
        "start_workout",
        %{"client_session_id" => socket.assigns.start_client_session_id},
        socket
      )

    session = Workouts.current_started_session(socket.assigns.current_scope)
    assert session.plan_id == selected.plan.id
    assert session.content_hash == selected.plan.content_hash
    assert session.program_snapshot == selected.plan.program_json
    assert session.client_session_id == socket.assigns.start_client_session_id

    assert started_socket.redirected ==
             {:live, :redirect, %{to: "/session/#{session.id}", kind: :push}}
  end

  defp counts,
    do: Enum.map([WorkoutPlan, WorkoutSession, CoachRecommendation], &Repo.aggregate(&1, :count))

  defp present?(socket, selector) do
    render_component(&HomeLive.render/1, socket.assigns)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.any?()
  end
end
