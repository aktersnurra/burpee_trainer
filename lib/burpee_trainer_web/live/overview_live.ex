defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc "Present-tense home surface for the current deterministic recommendation."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Coach, CoachReconciler, History, Repo, Workouts}
  alias BurpeeTrainer.Coach.{Catalog, Guidance, Policy}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Inspection, WorkoutSession}

  alias BurpeeTrainerWeb.{
    CreationParameters,
    Fmt,
    HomeAdjustment,
    HomeCoachComponents,
    HomeDayBoundary,
    HomeHistoryComponents,
    HomeWorkoutComponents,
    HomeWorkoutRequest
  }

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:start_client_session_id, Ecto.UUID.generate())
      |> assign_new(:home_now, fn -> fn -> DateTime.utc_now(:second) end end)
      |> assign(
        home_day_timer: nil,
        home_day_generation: 0,
        history_open?: false,
        coach_open?: false,
        coach_return_to: "#home-result-coach",
        editing_source: nil,
        history_period: "twelve_weeks",
        history_show_sessions?: false,
        history_weeks: [],
        history_streak: 0,
        history_week_start: nil,
        history_week_days: [],
        history_session_return_to: "#home-history-heading",
        history_selected_id: nil,
        history_selected_session: nil,
        history_confirm_delete?: false,
        history_return_to: "#home-history-toggle",
        history_error: nil,
        history_cursor: nil,
        history_has_more?: false,
        history_empty?: true,
        history_expanded: MapSet.new(),
        history_points: %{six_count: [], navy_seal: []},
        history_summary: History.summary([]),
        history_loaded_ids: [],
        history_loaded_count: 0,
        coach_guidance_form: to_form(%{"text" => ""}, as: :coach_guidance),
        coach_guidance_status: nil,
        review_inspection_rows: [],
        coach_summary: "",
        coach_details_open?: false,
        coach_guidance_edit_id: nil,
        coach_guidance_edit_form: to_form(%{"text" => ""}, as: :coach_memory)
      )
      |> stream_configure(:history_sessions, dom_id: &"home-history-session-#{&1.id}")
      |> stream(:history_sessions, [])
      |> stream_configure(:result_sessions, dom_id: &"home-result-session-#{&1.id}")
      |> stream(:result_sessions, [])
      |> stream_configure(:coach_guidance_entries, dom_id: &"history-coach-entry-#{&1.id}")
      |> stream(:coach_guidance_entries, Guidance.list(socket.assigns.current_user))
      |> assign_home()
      |> assign_workspace()
      |> schedule_home_day()

    socket =
      if params["history"] == "1" do
        socket
        |> assign(:history_open?, true)
        |> load_history(true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:home_day_boundary, generation}, socket) do
    if generation == socket.assigns.home_day_generation do
      previous_state = socket.assigns.slot && socket.assigns.slot.home_state

      {:noreply,
       socket
       |> refresh_home_facts()
       |> initialize_transition_selection(previous_state)
       |> schedule_home_day()}
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
        case HomeDayBoundary.delay_ms(a.current_user, a.home_snapshot_now) do
          {:ok, delay} -> Process.send_after(self(), {:home_day_boundary, generation}, delay)
          {:error, :invalid_timezone} -> nil
        end
      end

    assign(socket, home_day_timer: timer, home_day_generation: generation)
  end

  defp refresh_home_facts(socket) do
    socket = assign_home(socket)

    if socket.assigns.history_open? do
      load_history(socket, true, socket.assigns.home_snapshot_now, true)
    else
      socket
    end
  end

  # The sole refresh write exception: initialize the existing deterministic fallback
  # after a completion state expires, never replace a draft or reset its editor.
  defp initialize_transition_selection(socket, previous_state) do
    a = socket.assigns

    if previous_state in [:done_today, :week_complete] and
         match?(%{home_state: :workout_needed}, a.slot) and
         is_nil(a.home_selection) and is_nil(a.started_session) and not a.busy? do
      result =
        Repo.immediate_transaction(fn ->
          with {:ok, %{home_state: :workout_needed} = fresh_slot} <-
                 Policy.required_slot(a.current_user, a.home_now.()),
               nil <- Workouts.current_started_session(a.current_user),
               {:ok, entry_state} <- Workouts.home_entry_state(a.current_user, fresh_slot) do
            case entry_state do
              :bootstrap ->
                {:bootstrap, fresh_slot}

              :existing ->
                with {:ok, selected} <- Workouts.ensure_home_selection(a.current_user, fresh_slot),
                     do: {:selected, fresh_slot, selected}
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
          |> refresh_alternatives()

        {:ok, {:bootstrap, slot}} ->
          socket
          |> assign(
            slot: slot,
            home_selection: nil,
            bootstrap?: true,
            bootstrap_id: nil,
            local_error: nil
          )
          |> bootstrap_form("")
          |> refresh_alternatives()

        {:error, _} ->
          assign(socket,
            local_error: "The next workout is unavailable. Reload Home to try again.",
            started_session: Workouts.current_started_session(a.current_user)
          )
      end
    else
      socket
    end
  end

  defp refresh_coach_guidance(socket) do
    entries = Guidance.list(socket.assigns.current_user)

    summary =
      entries
      |> Enum.filter(&(&1.kind in ["pending", "lasting", "temporary"]))
      |> Enum.take(12)
      |> Enum.map(&(&1.summary || &1.text))
      |> Enum.uniq()
      |> Enum.join("\n")

    socket
    |> assign(coach_summary: summary)
    |> stream(:coach_guidance_entries, entries, reset: true)
  end

  @impl true
  def handle_event("open_coach", _, socket) do
    a = socket.assigns
    from_history = a.history_open? and is_nil(a.history_selected_session)

    completed =
      a.slot && a.slot.home_state in [:done_today, :week_complete] && is_nil(a.started_session)

    if from_history || completed do
      {:noreply,
       socket
       |> assign(
         coach_open?: true,
         history_open?: false,
         coach_return_to: if(from_history, do: "#history-coach-open", else: "#home-result-coach")
       )
       |> refresh_coach_guidance()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_coach", _, socket) do
    {:noreply,
     assign(socket,
       coach_open?: false,
       history_open?: socket.assigns.coach_return_to == "#history-coach-open"
     )}
  end

  def handle_event("coach_details_toggle", _, socket),
    do: {:noreply, assign(socket, coach_details_open?: not socket.assigns.coach_details_open?)}

  def handle_event("coach_guidance_change", %{"coach_guidance" => %{"text" => text}}, socket)
      when is_binary(text) do
    {:noreply,
     assign(socket,
       coach_guidance_form: to_form(%{"text" => text}, as: :coach_guidance),
       coach_guidance_status: nil
     )}
  end

  def handle_event("coach_guidance_submit", %{"coach_guidance" => %{"text" => text}}, socket) do
    case Guidance.add(socket.assigns.current_user, text) do
      {:ok, entry} ->
        _ = Guidance.start_review(entry)

        {:noreply,
         socket
         |> assign(:coach_guidance_form, to_form(%{"text" => ""}, as: :coach_guidance))
         |> assign(:coach_guidance_status, "Saved for your coach.")
         |> refresh_coach_guidance()}

      {:error, :invalid_text} ->
        {:noreply,
         socket
         |> assign(:coach_guidance_form, to_form(%{"text" => text}, as: :coach_guidance))
         |> assign(:coach_guidance_status, "Enter an instruction of up to 1,000 characters.")}
    end
  end

  def handle_event("coach_guidance_remove", %{"id" => raw}, socket) do
    with {id, ""} <- Integer.parse(raw),
         :ok <- Guidance.remove(socket.assigns.current_user, id) do
      {:noreply,
       socket
       |> assign(coach_guidance_edit_id: nil, coach_guidance_status: "Removed from coach memory.")
       |> refresh_coach_guidance()}
    else
      _ -> {:noreply, assign(socket, :coach_guidance_status, "Could not remove that entry.")}
    end
  end

  def handle_event("coach_guidance_edit", %{"id" => raw}, socket) do
    with {id, ""} <- Integer.parse(raw),
         entry when not is_nil(entry) <-
           Enum.find(Guidance.list(socket.assigns.current_user), &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(
         coach_guidance_edit_id: id,
         coach_guidance_edit_form: to_form(%{"text" => entry.text}, as: :coach_memory)
       )
       |> refresh_coach_guidance()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("coach_guidance_edit_change", %{"coach_memory" => params}, socket) do
    {:noreply, assign(socket, coach_guidance_edit_form: to_form(params, as: :coach_memory))}
  end

  def handle_event("coach_guidance_edit_cancel", _, socket) do
    {:noreply, socket |> assign(coach_guidance_edit_id: nil) |> refresh_coach_guidance()}
  end

  def handle_event("coach_guidance_edit_save", %{"coach_memory" => %{"text" => text}}, socket) do
    case Guidance.update(socket.assigns.current_user, socket.assigns.coach_guidance_edit_id, text) do
      {:ok, entry} ->
        _ = Guidance.start_review(entry)

        {:noreply,
         socket
         |> assign(coach_guidance_edit_id: nil, coach_guidance_status: "Saved.")
         |> refresh_coach_guidance()}

      _ ->
        {:noreply,
         assign(socket,
           coach_guidance_status: "Enter info of up to 1,000 characters.",
           coach_guidance_edit_form: to_form(%{"text" => text}, as: :coach_memory)
         )}
    end
  end

  def handle_event("open_history", params, socket) do
    return_to =
      if params["return_to"] in ["#home-result-history", "#home-coach-memory-link"],
        do: params["return_to"],
        else: "#home-history-toggle"

    {:noreply,
     socket
     |> assign(
       history_open?: true,
       coach_open?: false,
       history_show_sessions?: false,
       history_return_to: return_to
     )
     |> load_history(true)}
  end

  def handle_event("close_history", _, socket),
    do:
      {:noreply,
       assign(socket,
         history_open?: false,
         history_show_sessions?: false,
         history_selected_id: nil,
         history_selected_session: nil,
         history_confirm_delete?: false,
         history_expanded: MapSet.new()
       )}

  def handle_event("history_period", %{"period" => period}, socket)
      when period in ["twelve_weeks", "year", "all"] do
    if socket.assigns.history_open? do
      {:noreply,
       socket
       |> assign(
         history_period: period,
         history_week_start: nil,
         history_week_days: [],
         history_expanded: MapSet.new(),
         history_selected_id: nil,
         history_selected_session: nil
       )
       |> load_history(true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("history_density_mode", %{"mode" => mode}, socket)
      when mode in ["chart", "sessions"] do
    if socket.assigns.history_open? do
      {:noreply, assign(socket, :history_show_sessions?, mode == "sessions")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("history_more", _, socket) do
    if socket.assigns.history_open? and socket.assigns.history_has_more?,
      do: {:noreply, load_history(socket, false)},
      else: {:noreply, socket}
  end

  def handle_event("history_week", %{"start" => raw}, socket) when is_binary(raw) do
    a = socket.assigns

    with true <- a.history_open? and is_nil(a.history_error),
         {:ok, date} <- Date.from_iso8601(raw),
         %{start: ^date} <- Enum.find(a.history_weeks, &(&1.start == date)),
         {:ok, days} <-
           History.week_days(
             Workouts.list_sessions(a.current_user),
             a.current_user,
             a.home_now.(),
             date
           ) do
      {:noreply, assign(socket, history_week_start: date, history_week_days: days)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("history_week_back", _, socket),
    do: {:noreply, assign(socket, history_week_start: nil, history_week_days: [])}

  def handle_event("history_session", %{"id" => raw} = params, socket) when is_binary(raw) do
    a = socket.assigns

    with true <- a.history_open?,
         {id, ""} when id > 0 <- Integer.parse(raw),
         %{state: :completed} = session <- Workouts.get_session(a.current_user, id),
         {:ok, [_]} <-
           History.filter_sessions([session], a.current_user, a.home_now.(), a.history_period) do
      expanded =
        if MapSet.member?(a.history_expanded, id),
          do: MapSet.delete(a.history_expanded, id),
          else: MapSet.put(a.history_expanded, id)

      ids = Enum.uniq(a.history_loaded_ids ++ [id])
      selected? = MapSet.member?(expanded, id)

      {:noreply,
       socket
       |> assign(
         history_expanded: expanded,
         history_loaded_ids: ids,
         history_selected_id: if(selected?, do: id),
         history_selected_session: if(selected?, do: session),
         history_session_return_to:
           if(params["source"] == "point",
             do: "#home-history-point-#{id}",
             else: "#home-history-inspect-#{id}"
           ),
         history_confirm_delete?: false
       )
       |> restream_history_rows(nil, a.history_loaded_ids)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("history_close_session", _, socket) do
    a = socket.assigns

    {:noreply,
     socket
     |> assign(
       history_selected_id: nil,
       history_selected_session: nil,
       history_confirm_delete?: false,
       history_expanded: MapSet.delete(a.history_expanded, a.history_selected_id)
     )
     |> restream_history_rows(nil, a.history_loaded_ids)}
  end

  def handle_event("history_confirm_delete", _, socket) do
    if socket.assigns.history_open? and socket.assigns.history_selected_id,
      do: {:noreply, assign(socket, history_confirm_delete?: true)},
      else: {:noreply, socket}
  end

  def handle_event("history_cancel_delete", _, socket),
    do: {:noreply, assign(socket, history_confirm_delete?: false)}

  def handle_event("history_delete_session", _, socket) do
    a = socket.assigns

    with true <- a.history_open? and a.history_confirm_delete?,
         id when is_integer(id) <- a.history_selected_id,
         %{state: :completed} = session <- Workouts.get_session(a.current_user, id),
         {:ok, [_]} <-
           History.filter_sessions([session], a.current_user, a.home_now.(), a.history_period),
         {:ok, _} <- Workouts.delete_session(a.current_user, session) do
      refreshed =
        socket
        |> assign(
          history_selected_id: nil,
          history_selected_session: nil,
          history_confirm_delete?: false,
          history_expanded: MapSet.new()
        )
        |> assign_home()

      refreshed =
        if refreshed.assigns.slot && refreshed.assigns.slot.home_state == :workout_needed &&
             is_nil(refreshed.assigns.home_selection) && is_nil(refreshed.assigns.started_session),
           do: assign_workspace(refreshed),
           else: refreshed

      {:noreply, load_history(refreshed, true)}
    else
      _ ->
        {:noreply,
         assign(socket,
           history_error: "Couldn’t delete this session. Reload Home to try again.",
           history_session_return_to: "#home-history-heading"
         )}
    end
  end

  def handle_event("submit_bootstrap", %{"home_bootstrap" => %{"prompt" => prompt}}, socket)
      when is_binary(prompt) do
    a = socket.assigns

    cond do
      not a.bootstrap? or a.busy? or not is_nil(a.pending_request) ->
        {:noreply, socket}

      not valid_bootstrap_prompt?(prompt) ->
        {:noreply,
         socket
         |> assign(local_error: "Enter a request of at most 500 characters.")
         |> bootstrap_form(prompt)}

      true ->
        id = make_ref()
        user = a.current_user
        expected_slot = a.slot

        {:noreply,
         socket
         |> assign(
           busy?: true,
           bootstrap_id: id,
           bootstrap_prompt: prompt,
           bootstrap_slot: expected_slot,
           local_error: nil
         )
         |> bootstrap_form(prompt)
         |> start_async({:home_bootstrap_request, id}, fn ->
           Coach.prepare_home_bootstrap(user, expected_slot, prompt)
         end)}
    end
  end

  # Bootstrap owns only its prompt and catalog controls. Selected-workspace events
  # cannot act without a persisted selection, including in bootstrap presentation.
  def handle_event("change_adjustment", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("submit_home_action", _params, %{assigns: %{home_selection: nil}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, %{assigns: %{busy?: true, authoring_stage: stage}} = socket)
      when event in [
             "abort_new_workout",
             "change_new_workout",
             "choose_workout_value",
             "change_current_edit"
           ] and
             stage in [:new, :editing] do
    handle_event(event, params, discard_preparation(socket))
  end

  def handle_event(_event, _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{home_selection: nil, bootstrap?: false}} = socket)
      when event not in ["resume_recommendation", "retry_recommendation"],
      do: {:noreply, socket}

  def handle_event("toggle_summary", _, socket),
    do: {:noreply, assign(socket, expanded?: not socket.assigns.expanded?)}

  def handle_event("start_workout", %{"client_session_id" => token}, socket) do
    a = socket.assigns

    if (a.authoring_stage == :idle and a.home_selection) && token == a.start_client_session_id do
      start_result(socket, Workouts.start_home_workout(a.current_user, a.home_selection, token))
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_current_workout", _, socket) do
    if not is_nil(socket.assigns.home_selection) and socket.assigns.expanded? and
         socket.assigns.authoring_stage == :idle do
      case Workouts.verify_home_selection(
             socket.assigns.current_user,
             socket.assigns.home_selection
           ) do
        {:ok, source} ->
          params = HomeWorkoutRequest.from_definition(source.definition_json)

          {:noreply,
           socket
           |> assign(
             authoring_stage: :editing,
             editing_source: source,
             workout_parameters: params,
             creation_key: "variation:#{Ecto.UUID.generate()}",
             created_plan: nil,
             pending_request: nil,
             instruction: "",
             local_error: nil
           )
           |> adjustment_form("")
           |> workout_form(params, %{})}

        _ ->
          {:noreply,
           assign(socket, local_error: "That workout changed. Reopen it before editing.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "change_current_edit",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :editing, editing_source: source}} = socket
      )
      when not is_nil(source) and is_binary(text) do
    {:noreply,
     socket |> discard_preparation() |> assign(instruction: text) |> adjustment_form(text)}
  end

  def handle_event(
        "review_current_edit",
        %{"home_adjustment" => %{"instruction" => text}},
        %{assigns: %{authoring_stage: :editing, editing_source: source}} = socket
      )
      when not is_nil(source) do
    a = socket.assigns

    cond do
      not valid_bootstrap_prompt?(text) ->
        {:noreply, assign(socket, local_error: "Enter a change of at most 500 characters.")}

      verify_edit_selection(socket) != :ok ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      true ->
        id = make_ref()
        user = a.current_user
        expected = a.home_selection
        key = a.creation_key

        {:noreply,
         socket
         |> discard_preparation()
         |> assign(busy?: true, update_id: id, instruction: text)
         |> adjustment_form(text)
         |> start_async({:new_request, id}, fn ->
           with {:ok, interpreted} <- Coach.prepare_home_revision(user, expected, text),
                {:ok, _} <- Workouts.verify_home_selection(user, expected) do
             Coach.prepare_plan(user, text, interpreted.request,
               workspace_key: key,
               edit_source: source
             )
           end
         end)}
    end
  end

  def handle_event("new_workout", _, socket) do
    if socket.assigns.expanded? and socket.assigns.authoring_stage == :idle do
      params = %HomeWorkoutRequest{}

      {:noreply,
       socket
       |> assign(
         authoring_stage: :new,
         editing_source: nil,
         workout_parameters: params,
         creation_key: "creator:#{Ecto.UUID.generate()}",
         created_plan: nil,
         pending_request: nil,
         local_error: nil
       )
       |> workout_form(params, %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("abort_new_workout", _, socket) do
    {:noreply,
     socket
     |> discard_preparation()
     |> assign(authoring_stage: :idle, created_plan: nil, local_error: nil)}
  end

  def handle_event("change_new_workout", %{"home_workout" => attrs}, socket) do
    if socket.assigns.authoring_stage in [:new, :editing],
      do:
        {:noreply,
         socket |> discard_preparation() |> workout_form(socket.assigns.workout_parameters, attrs)},
      else: {:noreply, socket}
  end

  def handle_event("choose_workout_value", %{"field" => field, "value" => value}, socket)
      when field in ["burpee_type", "pacing_style"] do
    if socket.assigns.authoring_stage in [:new, :editing] do
      attrs = Map.put(socket.assigns.workout_form.params, field, value)

      {:noreply,
       socket |> discard_preparation() |> workout_form(socket.assigns.workout_parameters, attrs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "review_new_workout",
        %{"home_workout" => attrs},
        %{assigns: %{authoring_stage: stage}} = socket
      )
      when stage in [:new, :editing] do
    begin_plan_review(socket, attrs)
  end

  def handle_event("edit_workout_request", _, %{assigns: %{authoring_stage: :review}} = socket) do
    params = socket.assigns.workout_parameters

    {:noreply,
     socket
     |> discard_preparation()
     |> assign(authoring_stage: :editing)
     |> workout_form(params, %{})}
  end

  def handle_event(
        "save_workout_request",
        %{"home_workout" => attrs},
        %{assigns: %{authoring_stage: :editing}} = socket
      ) do
    begin_plan_review(socket, attrs)
  end

  def handle_event("select_created_workout", _, %{assigns: %{authoring_stage: :saved}} = socket) do
    a = socket.assigns

    with {:ok, _} <- Workouts.verify_home_selection(a.current_user, a.home_selection),
         {:ok, selected} <-
           Workouts.select_home_workout(a.current_user, a.home_selection, a.created_plan.id) do
      {:noreply,
       socket
       |> assign(authoring_stage: :idle, created_plan: nil)
       |> show_selection(selected, true)}
    else
      _ ->
        {:noreply,
         assign(socket,
           local_error: "The current workout changed. Reopen Home to select your saved workout."
         )}
    end
  end

  def handle_event("toggle_other", _, socket),
    do: {:noreply, assign(socket, alternatives_open?: not socket.assigns.alternatives_open?)}

  def handle_event("open_chooser", _, socket) do
    if socket.assigns.home_selection,
      do: {:noreply, assign(socket, chooser_open?: true, alternatives_open?: true)},
      else: {:noreply, socket}
  end

  def handle_event("close_chooser", _, socket),
    do: {:noreply, assign(socket, chooser_open?: false)}

  def handle_event("start_collapsed", %{"client_session_id" => token}, socket) do
    a = socket.assigns

    if not is_nil(a.home_selection) and not a.expanded? and
         token == a.start_client_session_id do
      start_result(socket, Workouts.start_home_workout(a.current_user, a.home_selection, token))
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_filters", _, socket),
    do:
      {:noreply,
       assign(socket, filters_open?: not socket.assigns.filters_open?, alternatives_open?: true)}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["workouts", "videos"] do
    {:noreply,
     socket
     |> assign(active_tab: if(tab == "workouts", do: :workouts, else: :videos))
     |> refresh_alternatives()}
  end

  def handle_event("filter", %{"kind" => kind, "filter" => value}, socket)
      when kind in ["type", "level"] do
    {key, allowed} =
      if kind == "type",
        do: {:types, [:six_count, :navy_seal]},
        else: {:levels, BurpeeTrainer.Levels.all_levels()}

    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil ->
        {:noreply, socket}

      atom ->
        set = Map.fetch!(socket.assigns.filters, key)

        set =
          if MapSet.member?(set, atom), do: MapSet.delete(set, atom), else: MapSet.put(set, atom)

        {:noreply,
         socket
         |> assign(filters: Map.put(socket.assigns.filters, key, set))
         |> refresh_alternatives()}
    end
  end

  def handle_event("reset_filters", _, socket),
    do:
      {:noreply,
       socket
       |> assign(filters: Catalog.default_filters(socket.assigns.current_level))
       |> refresh_alternatives()}

  def handle_event("toggle_group", %{"id" => id}, socket) do
    rows =
      if socket.assigns.authoring_stage == :review,
        do: socket.assigns.review_inspection_rows,
        else: socket.assigns.inspection_rows

    if Enum.any?(rows, &(&1.id == id and &1.count > 1)) do
      set = socket.assigns.expanded_groups
      set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
      {:noreply, assign(socket, expanded_groups: set)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_workout", %{"id" => id}, socket) when is_binary(id) do
    with {id, ""} <- Integer.parse(id),
         {:ok, _archived} <- Workouts.archive_plan(socket.assigns.current_user, id) do
      a = socket.assigns

      {:noreply,
       socket
       |> assign_workspace()
       |> assign(
         chooser_open?: true,
         alternatives_open?: true,
         expanded?: a.expanded?,
         filters: a.filters,
         filters_open?: a.filters_open?,
         active_tab: a.active_tab
       )
       |> refresh_alternatives()}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That workout could not be deleted. Your history is unchanged."
         )}
    end
  end

  def handle_event("select_alternative", %{"id" => id, "kind" => kind}, socket)
      when is_binary(id) do
    with {id, ""} <- Integer.parse(id) do
      a = socket.assigns

      case kind do
        "plan" ->
          result =
            if a.bootstrap?,
              do: Workouts.select_bootstrap_home_workout(a.current_user, a.slot, id),
              else: Workouts.select_home_workout(a.current_user, a.home_selection, id)

          case result do
            {:ok, selected} -> {:noreply, show_selection(socket, selected, true)}
            _ -> {:noreply, assign(socket, local_error: "That workout is no longer available.")}
          end

        "video" ->
          result =
            if a.bootstrap?,
              do:
                Workouts.start_bootstrap_home_video(
                  a.current_user,
                  a.slot,
                  id,
                  a.start_client_session_id
                ),
              else:
                Workouts.start_home_video(
                  a.current_user,
                  a.home_selection,
                  id,
                  a.start_client_session_id
                )

          start_result(socket, result)

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("change_adjustment", %{"home_adjustment" => %{"instruction" => text}}, socket)
      when is_binary(text),
      do: {:noreply, socket |> assign(instruction: text) |> adjustment_form(text)}

  def handle_event("submit_home_action", params, socket) do
    text =
      case params do
        %{"home_adjustment" => %{"instruction" => text}} -> text
        _ -> nil
      end

    a = socket.assigns

    with true <- is_nil(a.pending_request),
         true <- params["client_session_id"] == a.start_client_session_id,
         {:ok, operation} <- HomeAdjustment.operation(text) do
      case operation do
        {:start, ""} ->
          start_result(
            socket,
            Workouts.start_home_workout(
              a.current_user,
              a.home_selection,
              a.start_client_session_id
            )
          )

        {:update, instruction} ->
          id = make_ref()
          user = a.current_user
          expected = a.home_selection

          {:noreply,
           socket
           |> assign(busy?: true, update_id: id, instruction: text, local_error: nil)
           |> start_async({:home_revision_request, id}, fn ->
             Coach.prepare_home_revision(user, expected, instruction)
           end)}
      end
    else
      _ ->
        {:noreply, assign(socket, local_error: "Enter an adjustment of at most 500 characters.")}
    end
  end

  def handle_event("confirm_workout_request", _, %{assigns: %{authoring_stage: :review}} = socket) do
    a = socket.assigns
    id = make_ref()
    user = a.current_user
    prepared = a.pending_request

    if prepared && verify_edit_selection(socket) == :ok do
      {:noreply,
       socket
       |> assign(busy?: true, update_id: id, local_error: nil)
       |> start_async({:new_plan, id}, fn -> Coach.approve_plan(user, prepared) end)}
    else
      {:noreply, assign(socket, local_error: "That workout changed. Abort and open Edit again.")}
    end
  end

  def handle_event(
        "confirm_workout_request",
        _params,
        %{assigns: %{pending_request: %{scope: %{kind: :bootstrap}} = prepared, busy?: false}} =
          socket
      ) do
    id = make_ref()
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(busy?: true, bootstrap_id: id, local_error: nil)
     |> start_async({:home_bootstrap, id}, fn ->
       Coach.confirm_home_bootstrap(user, prepared)
     end)}
  end

  def handle_event(
        "confirm_workout_request",
        _params,
        %{assigns: %{pending_request: %{scope: %{kind: :revision}} = prepared, busy?: false}} =
          socket
      ) do
    id = make_ref()
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(busy?: true, update_id: id, local_error: nil)
     |> start_async({:home_revision, id}, fn ->
       Coach.confirm_home_revision(user, prepared)
     end)}
  end

  def handle_event("back_to_workout_request", _params, %{assigns: %{busy?: false}} = socket) do
    {:noreply,
     socket
     |> assign(pending_request: nil, local_error: nil)
     |> bootstrap_form(socket.assigns.bootstrap_prompt)
     |> adjustment_form(socket.assigns.instruction)}
  end

  def handle_event("resume_recommendation", %{"session-id" => session_id}, socket) do
    with {session_id, ""} <- Integer.parse(session_id),
         {:ok, session} <- Workouts.resume_session(socket.assigns.current_user, session_id) do
      {:noreply, push_navigate(socket, to: session_path(session))}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "That session cannot be resumed.")
         |> assign_home()
         |> assign_workspace()}
    end
  end

  def handle_event("retry_recommendation", _params, socket) do
    :ok = CoachReconciler.wake(socket.assigns.current_user.id, :retry)
    {:noreply, put_flash(socket, :info, "Looking for another option.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:new_request, id},
        {:ok, {:ok, prepared}},
        %{assigns: %{update_id: id}} = socket
      ) do
    if verify_edit_selection(socket) != :ok do
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         pending_request: nil,
         local_error: "That workout changed. Abort and open Edit again."
       )}
    else
      params =
        HomeWorkoutRequest.from_request(prepared.request, socket.assigns.workout_parameters)

      {:noreply,
       socket
       |> assign(
         authoring_stage: :review,
         review_inspection_rows: prepared_inspection(prepared),
         pending_request: prepared,
         workout_parameters: params,
         busy?: false,
         update_id: nil
       )
       |> workout_form(params, %{})}
    end
  end

  def handle_async(
        {:new_request, id},
        {:ok, {:error, error}},
        %{assigns: %{update_id: id}} = socket
      ) do
    {message, field, field_message} = review_failure(error)

    socket =
      assign(socket,
        busy?: false,
        update_id: nil,
        pending_request: nil,
        local_error:
          if(socket.assigns.editing_source && field_message, do: field_message, else: message)
      )

    socket =
      if field do
        changeset =
          Ecto.Changeset.add_error(socket.assigns.workout_form.source, field, field_message)

        params =
          Map.put(
            changeset.params || %{},
            Atom.to_string(field),
            socket.assigns.workout_form[field].value
          )

        assign(socket,
          workout_form:
            to_form(%{changeset | action: :validate, params: params}, as: :home_workout)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async({:new_request, id}, _, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         pending_request: nil,
         local_error: "Coach unavailable. Try again later; your current workout is unchanged."
       )}

  def handle_async({:new_plan, id}, {:ok, {:ok, plan}}, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       socket
       |> assign(
         busy?: false,
         update_id: nil,
         authoring_stage: :saved,
         pending_request: nil,
         created_plan: plan
       )
       |> refresh_alternatives()}

  def handle_async(
        {:new_plan, id},
        {:ok, {:error, %{code: code}}},
        %{assigns: %{update_id: id}} = socket
      )
      when code in [
             :provider_unavailable,
             :provider_timeout,
             :provider_request_failed,
             :invalid_provider_response
           ] do
    {:noreply,
     assign(socket,
       busy?: false,
       update_id: nil,
       local_error: "Coach unavailable. Try again later; your current workout is unchanged."
     )}
  end

  def handle_async({:new_plan, id}, _, %{assigns: %{update_id: id}} = socket),
    do:
      {:noreply,
       assign(socket,
         busy?: false,
         update_id: nil,
         local_error:
           "Couldn’t produce a validated plan. Update the targets or recovery and try again; your current workout is unchanged."
       )}

  def handle_async({kind, _}, _, socket) when kind in [:new_request, :new_plan],
    do: {:noreply, socket}

  def handle_async(
        {:home_bootstrap_request, id},
        {:ok, {:ok, prepared}},
        %{assigns: %{bootstrap_id: id, bootstrap?: true}} = socket
      ) do
    a = socket.assigns

    with {:ok, current_slot} <- Policy.required_slot(a.current_user, a.home_now.()),
         true <- current_slot.slot_key == a.bootstrap_slot.slot_key,
         true <- current_slot.slot_date == a.bootstrap_slot.slot_date,
         :workout_needed <- current_slot.home_state,
         nil <- Workouts.current_started_session(a.current_user) do
      {:noreply,
       assign(socket,
         busy?: false,
         bootstrap_id: nil,
         pending_request: prepared,
         local_error: nil
       )}
    else
      _ -> {:noreply, bootstrap_delivery_failure(socket)}
    end
  end

  def handle_async(
        {:home_bootstrap_request, id},
        _result,
        %{assigns: %{bootstrap_id: id}} = socket
      ),
      do: {:noreply, bootstrap_delivery_failure(socket)}

  def handle_async({:home_bootstrap_request, _id}, _result, socket), do: {:noreply, socket}

  def handle_async(
        {:home_bootstrap, id},
        {:ok, {:ok, selected}},
        %{assigns: %{bootstrap_id: id}} = socket
      ) do
    a = socket.assigns

    with {:ok, _plan} <- Workouts.verify_home_selection(a.current_user, selected),
         {:ok, current_slot} <- Policy.required_slot(a.current_user, a.home_now.()),
         %CoachRecommendation{} = recommendation <-
           Repo.get_by(CoachRecommendation,
             id: selected.recommendation_id,
             user_id: a.current_user.id
           ),
         true <- recommendation.slot_key == a.bootstrap_slot.slot_key,
         true <- recommendation.slot_date == a.bootstrap_slot.slot_date,
         true <- recommendation.slot_key == current_slot.slot_key,
         true <- recommendation.slot_date == current_slot.slot_date,
         :workout_needed <- current_slot.home_state,
         nil <- Workouts.current_started_session(a.current_user) do
      {:noreply,
       socket
       |> assign(busy?: false, bootstrap_id: nil, bootstrap?: false, bootstrap_slot: nil)
       |> show_selection(selected, true)}
    else
      _ -> {:noreply, bootstrap_delivery_failure(socket)}
    end
  end

  def handle_async({:home_bootstrap, id}, _result, %{assigns: %{bootstrap_id: id}} = socket),
    do: {:noreply, bootstrap_delivery_failure(socket)}

  def handle_async({:home_bootstrap, _id}, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:home_revision_request, id},
        {:ok, {:ok, prepared}},
        %{assigns: %{update_id: id}} = socket
      ) do
    case Workouts.verify_home_selection(socket.assigns.current_user, prepared.scope.expected) do
      {:ok, _plan} ->
        {:noreply,
         assign(socket, busy?: false, update_id: nil, pending_request: prepared, local_error: nil)}

      {:error, _} ->
        {:noreply,
         assign(socket,
           busy?: false,
           update_id: nil,
           pending_request: nil,
           local_error: "The training day or workout changed. Reopen Home before updating."
         )}
    end
  end

  def handle_async(
        {:home_revision_request, id},
        _result,
        %{assigns: %{update_id: id}} = socket
      ) do
    {:noreply,
     socket
     |> assign(
       busy?: false,
       update_id: nil,
       pending_request: nil,
       local_error: "Couldn’t interpret that request. Your workout is unchanged."
     )
     |> adjustment_form(socket.assigns.instruction)}
  end

  def handle_async({:home_revision_request, _id}, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:home_revision, id},
        {:ok, {:ok, selected}},
        %{assigns: %{update_id: id}} = socket
      ) do
    case Workouts.verify_home_selection(socket.assigns.current_user, selected) do
      {:ok, _plan} ->
        {:noreply,
         socket |> assign(busy?: false, update_id: nil) |> show_selection(selected, true)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(
           busy?: false,
           update_id: nil,
           local_error:
             "The training day or workout changed. Reopen Home before starting or updating."
         )
         |> adjustment_form(socket.assigns.instruction)}
    end
  end

  def handle_async({:home_revision, id}, result, %{assigns: %{update_id: id}} = socket) do
    message =
      case result do
        {:ok, {:error, %{code: :authoring_context_too_large}}} ->
          "This design history is too large to send. Your previous workout is unchanged."

        _ ->
          "Couldn’t update. Your previous workout is unchanged."
      end

    {:noreply,
     socket
     |> assign(busy?: false, update_id: nil, pending_request: nil, local_error: message)
     |> adjustment_form(socket.assigns.instruction)
     |> refresh_alternatives()}
  end

  def handle_async({:home_revision, _id}, _result, socket), do: {:noreply, socket}

  defp load_history(socket, reset?, now \\ nil, retain_loaded? \\ false) do
    a = socket.assigns
    now = now || a.home_now.()
    cursor = if reset?, do: nil, else: a.history_cursor

    with {:ok, rows, next, more?} <-
           History.page(a.current_user, now, a.history_period, cursor) do
      {points, summary} =
        if reset? do
          history_sessions =
            Map.new([:six_count, :navy_seal], fn type ->
              {:ok, sessions} =
                History.filter_sessions(
                  Workouts.list_sessions_for_chart(a.current_user, type),
                  a.current_user,
                  now,
                  a.history_period
                )

              {type, sessions}
            end)

          points =
            Map.new(history_sessions, fn {type, sessions} ->
              {type, History.points(sessions)}
            end)

          summary =
            history_sessions
            |> Map.values()
            |> List.flatten()
            |> Enum.uniq_by(& &1.id)
            |> History.summary()

          {points, summary}
        else
          {a.history_points, a.history_summary}
        end

      ids =
        Enum.uniq(
          if(reset? and not retain_loaded?, do: [], else: a.history_loaded_ids) ++
            Enum.map(rows, & &1.id)
        )

      all_sessions = Workouts.list_sessions(a.current_user)

      {:ok, available_sessions} =
        History.filter_sessions(all_sessions, a.current_user, now, "all")

      history_available? = available_sessions != []
      {:ok, weeks} = History.weeks(all_sessions, a.current_user, now, a.history_period)
      {:ok, all_weeks} = History.weeks(all_sessions, a.current_user, now, "all")

      selected_week =
        if Enum.any?(weeks, &(&1.start == a.history_week_start)),
          do: a.history_week_start,
          else: nil

      days =
        if selected_week do
          {:ok, days} = History.week_days(all_sessions, a.current_user, now, selected_week)
          days
        else
          []
        end

      socket
      |> assign(
        history_available?: history_available?,
        history_weeks: weeks,
        history_week_start: selected_week,
        history_week_days: days,
        history_streak: History.streak(all_weeks),
        history_error: nil,
        history_cursor: next,
        history_has_more?: more?,
        history_empty?: ids == [],
        history_points: points,
        history_summary: summary,
        history_loaded_ids: ids,
        history_loaded_count: length(ids)
      )
      |> restream_history_rows(now, if(retain_loaded?, do: a.history_loaded_ids))
    else
      {:error, _} ->
        socket
        |> assign(
          history_error: "History is unavailable. Reload Home to try again.",
          history_session_return_to: "#home-history-heading",
          history_cursor: nil,
          history_has_more?: false,
          history_empty?: true,
          history_loaded_ids: [],
          history_loaded_count: 0,
          history_weeks: [],
          history_week_start: nil,
          history_week_days: [],
          history_streak: 0,
          history_points: %{six_count: [], navy_seal: []},
          history_summary: History.summary([])
        )
        |> stream(:history_sessions, [], reset: true)
    end
  end

  # Retain only explicitly displayed IDs. Scoped re-reads keep inspected older points
  # in compound-key order as intervening pages arrive, without changing the cursor.
  defp restream_history_rows(socket, now, previous_ids) do
    a = socket.assigns
    now = now || a.home_now.()

    rows =
      a.history_loaded_ids
      |> Enum.map(&Workouts.get_session(a.current_user, &1))
      |> Enum.filter(&match?(%{state: :completed}, &1))

    {:ok, rows} =
      History.filter_sessions(rows, a.current_user, now, a.history_period)

    rows = Enum.sort_by(rows, &{DateTime.to_unix(&1.completed_at, :microsecond), &1.id}, :desc)

    ids = Enum.map(rows, & &1.id)

    socket =
      assign(socket,
        history_loaded_ids: ids,
        history_loaded_count: length(rows),
        history_empty?: rows == []
      )

    if is_list(previous_ids) do
      # A stream reset detaches even retained buttons. Incremental reconciliation
      # deletes only expired rows and inserts new rows at their compound-key rank.
      socket =
        Enum.reduce(previous_ids -- ids, socket, fn id, acc ->
          stream_delete_by_dom_id(acc, :history_sessions, "home-history-session-#{id}")
        end)

      rows
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {row, index}, acc ->
        stream_insert(acc, :history_sessions, row, at: index)
      end)
    else
      stream(socket, :history_sessions, rows, reset: true)
    end
  end

  defp assign_workspace(socket) do
    socket =
      socket
      |> assign(
        home_selection: nil,
        expanded?: false,
        alternatives_open?: false,
        chooser_open?: false,
        filters_open?: false,
        active_tab: :workouts,
        filters: Catalog.default_filters(socket.assigns.current_level),
        instruction: "",
        authoring_stage: :idle,
        workout_parameters: %HomeWorkoutRequest{},
        workout_form:
          to_form(HomeWorkoutRequest.changeset(%HomeWorkoutRequest{}, %{}), as: :home_workout),
        creation_key: nil,
        created_plan: nil,
        pending_request: nil,
        busy?: false,
        update_id: nil,
        bootstrap?: false,
        bootstrap_id: nil,
        bootstrap_prompt: "",
        bootstrap_slot: nil,
        local_error: nil,
        expanded_groups: MapSet.new(),
        inspection_rows: [],
        alternatives_empty?: true
      )
      |> adjustment_form("")
      |> stream(:alternatives, [], dom_id: &"home-alternative-#{&1.id}")

    if not is_nil(socket.assigns.slot) and socket.assigns.slot.home_state == :workout_needed and
         socket.assigns.started_session == nil do
      case Workouts.home_entry_state(socket.assigns.current_user, socket.assigns.slot) do
        {:ok, :bootstrap} ->
          socket
          |> assign(bootstrap?: true)
          |> bootstrap_form("")
          |> refresh_alternatives()

        {:ok, :existing} ->
          case Workouts.ensure_home_selection(socket.assigns.current_user, socket.assigns.slot) do
            {:ok, selected} -> show_selection(socket, selected, false)
            {:error, _} -> socket
          end

        {:error, _} ->
          socket
      end
    else
      socket
    end
  end

  defp workout_form(socket, params, attrs) do
    changeset = HomeWorkoutRequest.changeset(params, attrs)

    assign(socket,
      workout_parameters: Ecto.Changeset.apply_changes(changeset),
      workout_form: to_form(changeset, as: :home_workout)
    )
  end

  defp review_failure(%{code: code})
       when code in [:provider_unavailable, :provider_timeout, :invalid_provider_response],
       do: {"Coach unavailable. Try again later; your current workout is unchanged.", nil, nil}

  defp review_failure(%{
         context: %{field: :set_reps, actual_count: actual, expected_count: expected}
       }) do
    {"The returned plan changed your ordered set pattern. Edit or Review again; your current workout is unchanged.",
     :sets, "Returned #{actual} sets; expected #{expected}. The ordered rep sequence must match."}
  end

  defp review_failure(%{
         context: %{field: :timed_rests, start_sec: start, duration_sec: duration}
       }) do
    {"The returned plan missed #{duration}s at #{CreationParameters.duration_label(start)}. Try a different time or shorter pause, then Review again; your current workout is unchanged.",
     :rests, "Returned plan did not meet this total pause."}
  end

  defp review_failure(%{context: %{field: :requested_pace_sec}}),
    do:
      {"Returned movement time exceeds the requested duration. Edit or Review again; your current workout is unchanged.",
       :pace, "Returned movement time exceeds the requested duration."}

  defp review_failure(_),
    do:
      {"The returned plan did not meet your constraints. Check the set pattern and total pauses, then Review again; your current workout is unchanged.",
       nil, nil}

  defp discard_preparation(socket) do
    socket =
      if socket.assigns.busy? && socket.assigns.update_id,
        do: cancel_async(socket, {:new_request, socket.assigns.update_id}),
        else: socket

    assign(socket,
      pending_request: nil,
      busy?: false,
      update_id: nil,
      local_error: nil
    )
  end

  defp verify_edit_selection(%{assigns: %{editing_source: nil}}), do: :ok

  defp verify_edit_selection(%{assigns: %{home_selection: nil}}), do: {:error, :selection_changed}

  defp verify_edit_selection(%{assigns: assigns}) do
    source = assigns.editing_source

    case Workouts.verify_home_selection(assigns.current_user, assigns.home_selection) do
      {:ok, %{id: id, content_hash: hash}} when id == source.id and hash == source.content_hash ->
        :ok

      _ ->
        {:error, :selection_changed}
    end
  end

  defp begin_plan_review(socket, attrs) do
    changeset = HomeWorkoutRequest.changeset(socket.assigns.workout_parameters, attrs)

    with {:ok, params} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- verify_edit_selection(socket),
         {:ok, request} <- HomeWorkoutRequest.request(params) do
      id = make_ref()
      user = socket.assigns.current_user
      key = socket.assigns.creation_key
      source = socket.assigns.editing_source
      text = HomeWorkoutRequest.instruction(params)

      {:noreply,
       socket
       |> discard_preparation()
       |> workout_form(params, %{})
       |> assign(busy?: true, update_id: id, instruction: text)
       |> start_async({:new_request, id}, fn ->
         Coach.prepare_plan(user, text, request, workspace_key: key, edit_source: source)
       end)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, workout_form: to_form(changeset, as: :home_workout))}

      {:error, :selection_changed} ->
        {:noreply,
         assign(socket, local_error: "That workout changed. Abort and open Edit again.")}

      _ ->
        {:noreply, assign(socket, local_error: "Check the set pattern and total pauses.")}
    end
  end

  defp prepared_inspection(prepared) do
    {:ok, definition} = BurpeeTrainer.PlanCompiler.WorkoutDefinition.new(prepared.definition)
    {:ok, program} = BurpeeTrainer.PlanCompiler.compile(definition)

    BurpeeTrainer.Workouts.Inspection.rows(%BurpeeTrainer.Workouts.WorkoutPlan{
      definition_json: prepared.definition,
      program_json: BurpeeTrainer.PlanCompiler.ProgramHash.canonical_map(program),
      updated_at: DateTime.utc_now()
    })
  end

  defp bootstrap_form(socket, prompt),
    do: assign(socket, bootstrap_form: to_form(%{"prompt" => prompt}, as: :home_bootstrap))

  defp valid_bootstrap_prompt?(prompt),
    do: String.trim(prompt) != "" and String.length(prompt) <= 500 and byte_size(prompt) <= 4_000

  defp bootstrap_delivery_failure(socket) do
    socket
    |> assign(
      busy?: false,
      bootstrap_id: nil,
      bootstrap?: true,
      bootstrap_slot: nil,
      pending_request: nil,
      local_error: "Couldn’t prepare that workout. Please try again."
    )
    |> bootstrap_form(socket.assigns.bootstrap_prompt)
    |> refresh_alternatives()
  end

  defp adjustment_form(socket, text),
    do:
      assign(socket,
        adjustment_form:
          to_form(HomeAdjustment.changeset(%HomeAdjustment{}, %{"instruction" => text}))
      )

  defp show_selection(socket, selected, expanded?) do
    socket
    |> assign(
      home_selection: selected,
      expanded?: expanded?,
      instruction: "",
      pending_request: nil,
      local_error: nil,
      bootstrap?: false,
      bootstrap_slot: nil,
      expanded_groups: MapSet.new(),
      alternatives_open?: false,
      chooser_open?: false,
      inspection_rows: Inspection.rows(selected.plan),
      start_client_session_id: Ecto.UUID.generate()
    )
    |> adjustment_form("")
    |> notify_adjustment_reset()
    |> refresh_alternatives()
  end

  defp notify_adjustment_reset(socket) do
    if connected?(socket), do: push_event(socket, "home_adjustment_reset", %{}), else: socket
  end

  defp refresh_alternatives(%{assigns: %{slot: nil}} = socket), do: socket

  defp refresh_alternatives(%{assigns: %{bootstrap?: true}} = socket) do
    a = socket.assigns

    items =
      Workouts.bootstrap_alternatives(a.current_user, a.slot, a.filters, a.active_tab)
      |> Enum.map(&alternative_item/1)

    socket
    |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true)
  end

  defp refresh_alternatives(socket) do
    a = socket.assigns

    r =
      Repo.get_by!(CoachRecommendation,
        id: a.home_selection.recommendation_id,
        user_id: a.current_user.id
      )

    items =
      case a.active_tab do
        :workouts ->
          plans =
            Catalog.order_plans(
              Workouts.list_library(a.current_user),
              Map.get(r.ranked_plan_ids, "ids", []),
              a.slot,
              a.current_level
            )

          plans =
            case Workouts.get_draft(a.current_user, r.pending_draft_id) do
              {:ok, pending} -> [pending | plans]
              _ -> plans
            end

          plans
          |> Catalog.filter(a.filters, &Catalog.plan_level/1)
          |> Enum.map(
            &%{
              id: "plan-#{&1.id}",
              source_id: &1.id,
              kind: :plan,
              name: &1.name,
              owned?: &1.user_id == a.current_user.id and &1.state == :published,
              duration_sec: &1.target_duration_sec,
              reps: &1.target_reps
            }
          )

        :videos ->
          BurpeeTrainer.Videos.list_home_videos()
          |> Catalog.order_videos()
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
          |> Enum.map(
            &%{
              id: "video-#{&1.id}",
              source_id: &1.id,
              kind: :video,
              name: &1.name,
              duration_sec: &1.duration_sec,
              reps: &1.burpee_count
            }
          )
      end

    socket
    |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true)
  end

  defp alternative_item(%BurpeeTrainer.Workouts.WorkoutPlan{} = plan) do
    %{
      id: "plan-#{plan.id}",
      source_id: plan.id,
      kind: :plan,
      name: plan.name,
      owned?: not is_nil(plan.user_id) and plan.state == :published,
      duration_sec: plan.target_duration_sec,
      reps: plan.target_reps
    }
  end

  defp alternative_item(%BurpeeTrainer.Workouts.WorkoutVideo{} = video) do
    %{
      id: "video-#{video.id}",
      source_id: video.id,
      kind: :video,
      name: video.name,
      duration_sec: video.duration_sec,
      reps: video.burpee_count
    }
  end

  defp start_result(socket, {:ok, session}),
    do: {:noreply, push_navigate(socket, to: session_path(session))}

  defp start_result(socket, _),
    do:
      {:noreply,
       assign(socket,
         local_error: "This workout changed or is no longer available. Reopen Home."
       )}

  defp assign_home(socket) do
    user = socket.assigns.current_user
    now = socket.assigns.home_now.()

    {slot, error} =
      case Policy.required_slot(user, now) do
        {:ok, slot} ->
          {slot, nil}

        {:error, _reason} ->
          {nil, "Weekly progress is unavailable because your timezone could not be read."}
      end

    socket
    |> assign(slot: slot, home_error: error, home_snapshot_now: now)
    |> assign(:history_available?, history_available?(user, now))
    |> assign(:recommendation, Workouts.current_coach_recommendation(user))
    |> assign(:started_session, Workouts.current_started_session(user))
    |> assign_results(now)
    |> retain_history_return_target()
  end

  defp history_available?(user, now) do
    case History.page(user, now, "all") do
      {:ok, rows, _, _} -> rows != []
      {:error, _} -> true
    end
  end

  defp retain_history_return_target(socket) do
    a = socket.assigns

    if is_nil(a.started_session) and not is_nil(a.slot) and
         a.slot.home_state in [:done_today, :week_complete],
       do: socket,
       else: assign(socket, history_return_to: "#home-history-toggle")
  end

  defp assign_results(socket, now) do
    case History.results(socket.assigns.current_user, now) do
      {:ok, results} ->
        rows =
          if socket.assigns.slot.home_state == :done_today, do: results.today, else: results.week

        reps =
          Map.new([:six_count, :navy_seal], fn type ->
            {type,
             rows
             |> Enum.filter(&(&1.burpee_type == type))
             |> Enum.sum_by(&(&1.burpee_count_actual || 0))}
          end)

        latest_today = List.first(results.today)

        socket
        |> assign(
          result_actual_seconds: Enum.sum_by(results.today, &(&1.duration_sec_actual || 0)),
          result_today_reps: Enum.sum_by(results.today, &(&1.burpee_count_actual || 0)),
          result_today_count: length(results.today),
          result_today_session: latest_today,
          result_mood: latest_today && mood_label(latest_today.mood),
          result_reps: reps
        )
        |> stream(:result_sessions, results.today, reset: true)

      {:error, _} ->
        socket
        |> assign(
          result_actual_seconds: nil,
          result_today_reps: 0,
          result_today_count: 0,
          result_today_session: nil,
          result_mood: nil,
          result_reps: %{six_count: 0, navy_seal: 0}
        )
        |> stream(:result_sessions, [], reset: true)
    end
  end

  defp mood_label(-1), do: "Rough"
  defp mood_label(0), do: "OK"
  defp mood_label(1), do: "Good"
  defp mood_label(_), do: nil

  defp session_path(%WorkoutSession{source_kind: :video, workout_video_id: video_id, id: id}),
    do: ~p"/videos/#{video_id}/session/#{id}"

  defp session_path(%WorkoutSession{id: id}), do: ~p"/session/#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_scope={assigns[:current_scope]}
      current_page={:home}
      navigation?={false}
      flash?={false}
    >
      <main id="home-page" class="mx-auto w-full max-w-3xl px-5 py-10 sm:px-8 sm:py-16">
        <div class="adaptive-home">
          <div id="home-progress-history" class="relative min-h-11">
            <%= if @slot do %>
              <HomeWorkoutComponents.week_progress slot={@slot} />
            <% else %>
              <p id="home-progress-unavailable">Weekly progress unavailable</p>
            <% end %>
            <button
              id="home-history-toggle"
              type="button"
              class="absolute inset-0 min-h-11 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4"
              aria-label={if(@history_open?, do: "Close History", else: "Open History")}
              aria-controls="home-history"
              aria-expanded={to_string(@history_open?)}
              inert={not is_nil(@history_selected_session)}
              phx-click={
                if(@history_open?,
                  do: HomeWorkoutComponents.close_history(),
                  else: HomeWorkoutComponents.open_history()
                )
              }
            >
              <span class="sr-only">View training history</span>
            </button>
          </div>
          <HomeHistoryComponents.panel :if={@history_open?} state={assigns} />
          <HomeCoachComponents.panel :if={@coach_open?} state={assigns} />
          <div
            id="home-state-content"
            hidden={@history_open? || @coach_open?}
            inert={@history_open? || @coach_open?}
          >
            <%= cond do %>
              <% not is_nil(@started_session) -> %>
                <section
                  id="home-ready-recommendation"
                  class="home-result home-resume"
                  phx-hook="HomePendingSession"
                  data-session-id={@started_session.id}
                  data-content-hash={@started_session.content_hash}
                >
                  <p id="home-session-state" class="home-eyebrow">In progress</p>
                  <div class="home-hero">
                    <h1 class="home-state-heading">
                      {@started_session.display_name_snapshot ||
                        Fmt.burpee_type(@started_session.burpee_type)}
                    </h1>
                    <p class="home-resume-style">
                      {Fmt.burpee_type(@started_session.burpee_type)}
                      <span :if={@started_session.style_name}>
                        · {@started_session.style_name}
                      </span>
                    </p>
                    <p class="home-resume-meta">
                      <span :if={@started_session.burpee_count_planned}>
                        {@started_session.burpee_count_planned} reps
                      </span>
                      <span :if={@started_session.duration_sec_planned}>
                        {Fmt.duration_sec(@started_session.duration_sec_planned)} planned
                      </span>
                    </p>
                  </div>
                  <button
                    id="resume-recommended-workout"
                    type="button"
                    phx-click="resume_recommendation"
                    phx-value-session-id={@started_session.id}
                    class="home-resume-action min-h-11 focus-visible:outline-2 focus-visible:outline-offset-4"
                  >
                    <span id="home-resume-action-label">Resume workout</span>
                    <.icon name="hero-arrow-right" class="size-4" />
                  </button>
                </section>
              <% @home_error -> %>
                <section id="home-unavailable" class="home-result">
                  <p role="status">{@home_error}</p>
                  <a
                    id="home-reload"
                    href={~p"/"}
                    class="mt-4 inline-flex min-h-11 items-center underline focus-visible:outline-2"
                  >
                    Reload Home
                  </a>
                </section>
              <% @slot && @slot.home_state in [:done_today, :week_complete] && @result_today_session -> %>
                <section id="home-done-today" class="home-result">
                  <p class="home-state-label">Today</p>
                  <h1 class="home-state-heading">
                    {@result_today_session.display_name_snapshot ||
                      Fmt.burpee_type(@result_today_session.burpee_type)}
                  </h1>
                  <p
                    id={
                      if(@result_today_count == 1,
                        do: "home-result-actual-seconds",
                        else: "home-today-session-meta"
                      )
                    }
                    data-duration-sec={@result_today_session.duration_sec_actual}
                    class="home-result-meta"
                  >
                    {Fmt.duration_sec(@result_today_session.duration_sec_actual)} · {@result_today_session.burpee_count_actual ||
                      0} reps
                  </p>
                  <p :if={@result_mood} id="home-today-mood" class="home-result-mood">
                    {@result_mood}
                  </p>
                  <p
                    :if={@result_today_count > 1}
                    id="home-result-actual-seconds"
                    data-duration-sec={@result_actual_seconds}
                    class="home-result-meta"
                  >
                    Today total · {Fmt.duration_sec(@result_actual_seconds)} · {@result_today_reps} reps
                  </p>
                  <HomeCoachComponents.entry id="home-result-coach" />
                </section>
              <% @slot && @slot.home_state == :week_complete -> %>
                <section
                  id="home-week-complete"
                  class="home-result"
                >
                  <p class="home-state-label">
                    This week
                  </p>
                  <h1 class="home-state-heading">
                    Training target complete
                  </h1>
                  <p
                    id="home-result-actual-seconds"
                    data-duration-sec={@slot.completed_sec}
                    class="home-result-meta"
                  >
                    {Fmt.duration_sec(@slot.completed_sec)} · {@result_reps.six_count +
                      @result_reps.navy_seal} reps
                  </p>
                  <HomeCoachComponents.entry id="home-result-coach" />
                </section>
              <% @bootstrap? -> %>
                <HomeWorkoutComponents.bootstrap state={assigns} />
              <% not is_nil(@home_selection) -> %>
                <HomeWorkoutComponents.workspace state={assigns} />
              <% true -> %>
                <section
                  id="home-ready-recommendation"
                  class="home-result"
                >
                  <h1 class="home-state-heading">
                    Your workout is being prepared
                  </h1>
                  <p :if={@local_error} id="home-initialization-error" role="status">
                    {@local_error}
                  </p>
                  <a
                    :if={@local_error}
                    id="home-fallback-reload"
                    href={~p"/"}
                    class="mt-4 inline-flex min-h-11 items-center underline focus-visible:outline-2"
                  >
                    Reload Home
                  </a>
                  <button
                    :if={is_nil(@local_error)}
                    id="retry-recommendation-button"
                    phx-click="retry_recommendation"
                    class="home-state-action min-h-11 focus-visible:outline-2 focus-visible:outline-offset-4"
                  >
                    Retry
                  </button>
                </section>
            <% end %>
          </div>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
