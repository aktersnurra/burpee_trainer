defmodule BurpeeTrainerWeb.HomeLive do
  @moduledoc "Present-tense home surface for the current deterministic recommendation."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Home, Repo, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{Inspection, WorkoutSession}

  alias BurpeeTrainerWeb.{
    HomeScreen,
    HomeAuthoring,
    HomeChooser,
    HomeWorkspace,
    CoachScreen,
    HistoryScreen,
    HomeDayBoundary
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:start_client_session_id, Ecto.UUID.generate())
      |> assign_new(:home_now, fn -> fn -> DateTime.utc_now(:second) end end)
      |> assign(
        home_day_timer: nil,
        home_day_generation: 0,
        home_planning_error: nil,
        editing_source: nil,
        workspace_screen: :home,
        home_focus_return?: false,
        home_coach_focus_return?: false,
        history_focus_return?: false,
        review_inspection_rows: []
      )
      |> stream_configure(:result_sessions, dom_id: &"home-result-session-#{&1.id}")
      |> stream(:result_sessions, [])
      |> assign_home()
      |> HomeWorkspace.assign_workspace()
      |> HistoryScreen.initialize()
      |> CoachScreen.initialize()
      |> assign(history_open?: false)
      |> schedule_home_day()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"history" => "1"}, _uri, socket),
    do: {:noreply, push_patch(socket, to: ~p"/history")}

  def handle_params(params, _uri, socket) do
    screen = socket.assigns[:live_action] || :home
    previous = socket.assigns.workspace_screen

    coach_entry? =
      previous == :coach and screen == :home and is_nil(socket.assigns.started_session) and
        match?(
          %{home_state: state} when state in [:done_today, :week_complete],
          socket.assigns.slot
        )

    socket =
      assign(socket,
        workspace_screen: screen,
        history_open?: screen == :history,
        coach_open?: screen == :coach,
        home_focus_return?: screen == :home and previous != :home and not coach_entry?,
        home_coach_focus_return?: coach_entry?,
        history_focus_return?: screen == :history and previous == :coach
      )

    socket =
      case screen do
        :history ->
          HistoryScreen.open(socket)

        :coach ->
          CoachScreen.open(socket, params)

        :home when previous != :home ->
          if socket.assigns.bootstrap? or socket.assigns.home_state == :choose or
               not is_nil(socket.assigns.home_selection),
             do: HomeChooser.refresh_alternatives(socket),
             else: socket

        :home ->
          socket
      end

    socket =
      if screen == :home,
        do:
          assign(
            socket,
            :home_insight,
            BurpeeTrainer.Insights.latest(
              socket.assigns.current_scope,
              socket.assigns.home_now.()
            )
          ),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info({:home_day_boundary, generation}, socket) do
    if generation == socket.assigns.home_day_generation do
      now = socket.assigns.home_now.()

      socket = socket |> refresh_at_boundary(now) |> schedule_home_day()

      socket =
        if socket.assigns.slot && socket.assigns.slot.home_state == :workout_needed &&
             (socket.assigns.home_state == :choose or
                match?({:start, %{plan: %{origin: :built_in}}}, socket.assigns.home_state)) do
          enqueue_planner(socket)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp schedule_home_day(socket) do
    a = socket.assigns
    if a.home_day_timer, do: Process.cancel_timer(a.home_day_timer)
    generation = a.home_day_generation + 1

    timer =
      if connected?(socket) do
        case HomeDayBoundary.delay_ms(a.current_scope.user, a.home_snapshot_now) do
          {:ok, delay} -> Process.send_after(self(), {:home_day_boundary, generation}, delay)
          {:error, :invalid_timezone} -> nil
        end
      end

    assign(socket, home_day_timer: timer, home_day_generation: generation)
  end

  defp refresh_home_facts(socket, now) do
    socket |> assign_home(now) |> HomeWorkspace.refresh_projection() |> refresh_history_at(now)
  end

  defp refresh_history_at(socket, now) do
    if socket.assigns.workspace_screen == :history,
      do: HistoryScreen.refresh(socket, now),
      else: socket
  end

  defp refresh_at_boundary(socket, now) do
    a = socket.assigns

    case Policy.required_slot(a.current_scope, now) do
      {:error, _} ->
        # The loader's genuine timezone error path cannot initialize a selection.
        refresh_home_facts(socket, now)

      {:ok, fresh_slot} ->
        previous_state = a.slot && a.slot.home_state

        cond do
          a.busy? or not is_nil(a.pending_request) or a.authoring_stage != :idle ->
            # Keep all Home facts, projections and their timestamp together. History
            # has its own captured timestamp; do not label deferred Home facts fresh.
            refresh_history_at(socket, now)

          previous_state in [:done_today, :week_complete] and
            fresh_slot.home_state == :workout_needed and is_nil(a.home_selection) and
              is_nil(Workouts.current_started_session(a.current_scope)) ->
            updated = initialize_transition_selection(socket, previous_state, fresh_slot, now)

            if updated.assigns.home_selection || updated.assigns.bootstrap?,
              do: refresh_home_facts(updated, now),
              else: refresh_history_at(updated, now)

          true ->
            refresh_home_facts(socket, now)
        end
    end
  end

  # Deletion can return a completion-only mount to a workout-needed slot. Initialize
  # only an absent idle workspace; never replace an existing selection or pending editor.

  defp restore_workspace_after_history_delete(socket) do
    socket = refresh_home_facts(socket, socket.assigns.home_now.())
    a = socket.assigns

    if match?(%{home_state: :workout_needed}, a.slot) and is_nil(a.home_selection) and
         is_nil(a.started_session) and not a.bootstrap? and not a.busy? and
         is_nil(a.pending_request) and a.authoring_stage == :idle,
       do: HomeWorkspace.assign_workspace(socket),
       else: socket
  end

  # Day-boundary refresh write exception: initialize the existing deterministic fallback
  # after a completion state expires, never replace a draft or reset its editor.

  defp initialize_transition_selection(socket, previous_state, fresh_slot, now) do
    a = socket.assigns

    if previous_state in [:done_today, :week_complete] and
         fresh_slot.home_state == :workout_needed and
         is_nil(a.home_selection) and is_nil(a.started_session) and not a.busy? do
      result =
        Repo.immediate_transaction(fn ->
          with {:ok, %{home_state: :workout_needed} = fresh_slot} <-
                 Policy.required_slot(a.current_scope, a.home_now.()),
               nil <- Workouts.current_started_session(a.current_scope),
               {:ok, entry_state} <- Workouts.home_entry_state(a.current_scope, fresh_slot) do
            case entry_state do
              :bootstrap ->
                {:bootstrap, fresh_slot}

              :existing ->
                case Workouts.ensure_home_selection(a.current_scope, fresh_slot) do
                  {:ok, selected} -> {:selected, fresh_slot, selected}
                  {:error, _} -> Repo.rollback({:home_refresh_unavailable, :missing_selection})
                end
            end
          else
            _ -> Repo.rollback(:home_refresh_unavailable)
          end
        end)

      case result do
        {:ok, {:selected, slot, selected}} ->
          socket
          |> assign(
            slot: slot,
            home_selection: selected,
            inspection_rows: Inspection.rows(selected.plan),
            local_error: nil
          )
          |> HomeChooser.refresh_alternatives()

        {:ok, {:bootstrap, slot}} ->
          socket
          |> assign(
            slot: slot,
            home_selection: nil,
            bootstrap?: true,
            bootstrap_id: nil,
            local_error: nil
          )
          |> HomeAuthoring.bootstrap_form("")
          |> HomeChooser.refresh_alternatives()

        {:error, {:home_refresh_unavailable, :missing_selection}} ->
          # An actual failed fallback rolls back before the loader derives :choose.
          socket
          |> assign_home(now)
          |> HomeChooser.refresh_alternatives()
          |> assign(local_error: "The next workout is unavailable. Reload Home to try again.")

        {:error, _} ->
          assign(socket,
            local_error: "The next workout is unavailable. Reload Home to try again."
          )
      end
    else
      socket
    end
  end

  @impl true
  def handle_event(event, params, socket)
      when event in [
             "close_history",
             "history_period",
             "history_density_mode",
             "history_more",
             "history_week",
             "history_week_back",
             "history_session",
             "history_close_session",
             "history_confirm_delete",
             "history_cancel_delete",
             "history_delete_session"
           ] do
    if socket.assigns.workspace_screen == :history do
      {:noreply, updated} = HistoryScreen.handle_event(event, params, socket)

      updated =
        if event == "history_delete_session" and socket.assigns.history_confirm_delete? and
             not is_nil(socket.assigns.history_selected_session) and
             is_nil(updated.assigns.history_selected_session) and
             is_nil(updated.assigns.history_error),
           do: restore_workspace_after_history_delete(updated),
           else: updated

      {:noreply, updated}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, params, socket)
      when event in [
             "close_coach",
             "coach_details_toggle",
             "coach_message_change",
             "coach_message",
             "coach_notebook_change",
             "coach_notebook_save",
             "coach_notebook_clear",
             "coach_goal_confirm",
             "coach_goal_dismiss"
           ] do
    if socket.assigns.workspace_screen == :coach,
      do: CoachScreen.handle_event(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, %{assigns: %{workspace_screen: screen}} = socket)
      when screen != :home, do: {:noreply, socket}

  def handle_event("submit_bootstrap", params, socket),
    do: HomeAuthoring.handle_event("submit_bootstrap", params, socket)

  def handle_event(event, params, %{assigns: %{busy?: true, authoring_stage: stage}} = socket)
      when event in [
             "abort_new_workout",
             "change_new_workout",
             "choose_workout_value",
             "change_current_edit"
           ] and
             stage in [:new, :editing] do
    handle_event(event, params, HomeAuthoring.discard_preparation(socket))
  end

  def handle_event(_event, _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}

  def handle_event(
        event,
        params,
        %{assigns: %{home_selection: nil, home_state: :choose}} = socket
      )
      when event in [
             "open_chooser",
             "close_chooser",
             "toggle_filters",
             "tab",
             "filter",
             "reset_filters",
             "select_alternative",
             "delete_workout"
           ] do
    HomeChooser.handle_event(event, params, socket)
  end

  def handle_event(event, _params, %{assigns: %{home_selection: nil, bootstrap?: false}} = socket)
      when event not in ["resume_recommendation", "retry_recommendation"],
      do: {:noreply, socket}

  def handle_event(event, params, socket)
      when event in [
             "abort_new_workout",
             "back_to_workout_request",
             "change_adjustment",
             "change_current_edit",
             "change_new_workout",
             "choose_workout_value",
             "confirm_workout_request",
             "edit_current_workout",
             "edit_workout_request",
             "new_workout",
             "review_current_edit",
             "review_new_workout",
             "save_workout_request",
             "select_created_workout",
             "submit_home_action"
           ] do
    HomeAuthoring.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "close_chooser",
             "delete_workout",
             "filter",
             "open_chooser",
             "reset_filters",
             "select_alternative",
             "tab",
             "toggle_filters",
             "toggle_group",
             "toggle_other"
           ] do
    HomeChooser.handle_event(event, params, socket)
  end

  def handle_event("toggle_summary", _, socket),
    do: {:noreply, assign(socket, expanded?: not socket.assigns.expanded?)}

  def handle_event("start_workout", %{"client_session_id" => token}, socket) do
    a = socket.assigns

    if (a.authoring_stage == :idle and a.home_selection) && token == a.start_client_session_id do
      start_result(socket, Workouts.start_home_workout(a.current_scope, a.home_selection, token))
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_collapsed", %{"client_session_id" => token}, socket) do
    a = socket.assigns

    if not is_nil(a.home_selection) and not a.expanded? and
         token == a.start_client_session_id do
      start_result(socket, Workouts.start_home_workout(a.current_scope, a.home_selection, token))
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume_recommendation", %{"session-id" => session_id}, socket) do
    with {session_id, ""} <- Integer.parse(session_id),
         {:ok, session} <- Workouts.resume_session(socket.assigns.current_scope, session_id) do
      {:noreply, push_navigate(socket, to: session_path(session))}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "That session cannot be resumed.")
         |> assign_home()
         |> HomeWorkspace.assign_workspace()}
    end
  end

  def handle_event("retry_recommendation", _params, socket) do
    socket = enqueue_planner(socket)

    socket =
      if is_nil(socket.assigns.home_planning_error),
        do: put_flash(socket, :info, "Looking for another option."),
        else: socket

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp enqueue_planner(socket) do
    case BurpeeTrainer.Coach.PlanNextWorkoutJob.enqueue(socket.assigns.current_scope) do
      :ok ->
        assign(socket, home_planning_error: nil)

      {:error, _reason} ->
        assign(socket, home_planning_error: "Planning is unavailable. Try again later.")
    end
  end

  def start_result(socket, {:ok, session}),
    do: {:noreply, push_navigate(socket, to: session_path(session))}

  def start_result(socket, _),
    do:
      {:noreply,
       assign(socket,
         local_error: "This workout changed or is no longer available. Reopen Home."
       )}

  def assign_home(socket), do: assign_home(socket, socket.assigns.home_now.())

  def assign_home(socket, now) do
    socket = assign(socket, home_snapshot_now: now)

    case Home.facts(socket.assigns.current_scope, now) do
      {:ok, facts} ->
        state = Home.state(facts)

        socket
        |> assign(
          home_facts: facts,
          home_insight: BurpeeTrainer.Insights.latest(socket.assigns.current_scope, now),
          home_state: state,
          home_primary_action: BurpeeTrainer.Home.State.primary_action(state),
          slot: facts.slot,
          started_session: facts.started_session,
          home_error: nil,
          history_available?: facts.history?
        )
        |> HomeScreen.assign_results(facts.results)

      {:error, :invalid_timezone} ->
        socket
        |> assign(
          home_facts: nil,
          home_insight: nil,
          home_state: nil,
          home_primary_action: nil,
          slot: nil,
          started_session: nil,
          history_available?: false,
          home_error: "Weekly progress is unavailable because your timezone could not be read."
        )
        |> HomeScreen.assign_results(nil)
    end
  end

  def session_path(%WorkoutSession{source_kind: :video, workout_video_id: video_id, id: id}),
    do: ~p"/videos/#{video_id}/session/#{id}"

  def session_path(%WorkoutSession{id: id}), do: ~p"/session/#{id}"

  @impl true
  def handle_async(:coach_reply, result, socket),
    do: CoachScreen.handle_async(:coach_reply, result, socket)

  def handle_async({kind, _id} = operation, result, socket)
      when kind in [
             :new_request,
             :new_plan,
             :home_bootstrap_request,
             :home_bootstrap,
             :home_revision_request,
             :home_revision
           ] do
    HomeAuthoring.handle_async(operation, result, socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_level={@current_level}
      current_page={@workspace_screen}
      navigation?={false}
      flash?={false}
    >
      <%= case @workspace_screen do %>
        <% :history -> %>
          <HistoryScreen.screen {assigns} />
        <% :coach -> %>
          <CoachScreen.screen {assigns} />
        <% :home -> %>
          <HomeScreen.screen {assigns} />
      <% end %>
    </Layouts.app>
    """
  end
end
