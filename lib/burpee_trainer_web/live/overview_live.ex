defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc "Present-tense home surface for the current deterministic recommendation."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Coach, CoachReconciler, Repo, Workouts}
  alias BurpeeTrainer.Coach.{Catalog, Policy}
  alias BurpeeTrainer.Workouts.{CoachRecommendation, Inspection, WorkoutSession}
  alias BurpeeTrainerWeb.{HomeAdjustment, HomeWorkoutComponents}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:start_client_session_id, Ecto.UUID.generate())
     |> assign_home()
     |> assign_workspace()}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{busy?: true}} = socket), do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{home_selection: nil}} = socket)
      when event not in ["resume_recommendation", "retry_recommendation"],
      do: {:noreply, socket}

  def handle_event("toggle_summary", _, socket),
    do: {:noreply, assign(socket, expanded?: not socket.assigns.expanded?)}

  def handle_event("toggle_other", _, socket),
    do: {:noreply, assign(socket, alternatives_open?: not socket.assigns.alternatives_open?)}

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

  def handle_event("filter", %{"kind" => kind, "value" => value}, socket)
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
    if Enum.any?(socket.assigns.inspection_rows, &(&1.id == id and &1.count > 1)) do
      set = socket.assigns.expanded_groups
      set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
      {:noreply, assign(socket, expanded_groups: set)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_alternative", %{"id" => id, "kind" => kind}, socket)
      when is_binary(id) do
    with {id, ""} <- Integer.parse(id) do
      a = socket.assigns

      case kind do
        "plan" ->
          case Workouts.select_home_workout(a.current_user, a.home_selection, id) do
            {:ok, selected} -> {:noreply, show_selection(socket, selected, true)}
            _ -> {:noreply, assign(socket, local_error: "That workout is no longer available.")}
          end

        "video" ->
          start_result(
            socket,
            Workouts.start_home_video(
              a.current_user,
              a.home_selection,
              id,
              a.start_client_session_id
            )
          )

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

    with true <- params["client_session_id"] == a.start_client_session_id,
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
           |> start_async({:home_revision, id}, fn ->
             Coach.revise_home_workout(user, expected, instruction)
           end)}
      end
    else
      _ ->
        {:noreply, assign(socket, local_error: "Enter an adjustment of at most 500 characters.")}
    end
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
        {:home_revision, id},
        {:ok, {:ok, selected}},
        %{assigns: %{update_id: id}} = socket
      ) do
    {:noreply, socket |> assign(busy?: false, update_id: nil) |> show_selection(selected, true)}
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
     |> assign(busy?: false, update_id: nil, local_error: message)
     |> adjustment_form(socket.assigns.instruction)
     |> refresh_alternatives()}
  end

  def handle_async({:home_revision, _id}, _result, socket), do: {:noreply, socket}

  defp assign_workspace(socket) do
    socket =
      socket
      |> assign(
        home_selection: nil,
        expanded?: false,
        alternatives_open?: false,
        filters_open?: false,
        active_tab: :workouts,
        filters: Catalog.default_filters(socket.assigns.current_level),
        instruction: "",
        busy?: false,
        update_id: nil,
        local_error: nil,
        expanded_groups: MapSet.new(),
        inspection_rows: [],
        alternatives_empty?: true
      )
      |> adjustment_form("")
      |> stream(:alternatives, [], dom_id: &"home-alternative-#{&1.id}")

    if socket.assigns.slot.home_state == :workout_needed and socket.assigns.started_session == nil do
      case Workouts.ensure_home_selection(socket.assigns.current_user, socket.assigns.slot) do
        {:ok, selected} -> show_selection(socket, selected, false)
        {:error, _} -> socket
      end
    else
      socket
    end
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
      local_error: nil,
      expanded_groups: MapSet.new(),
      alternatives_open?: false,
      inspection_rows: Inspection.rows(selected.plan),
      start_client_session_id: Ecto.UUID.generate()
    )
    |> adjustment_form("")
    |> refresh_alternatives()
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
          |> Enum.map(&%{id: "plan-#{&1.id}", source_id: &1.id, kind: :plan, name: &1.name})

        :videos ->
          BurpeeTrainer.Videos.list_home_videos()
          |> Catalog.order_videos()
          |> Catalog.filter(a.filters, &Catalog.video_level/1)
          |> Enum.map(&%{id: "video-#{&1.id}", source_id: &1.id, kind: :video, name: &1.name})
      end

    socket
    |> assign(alternatives_empty?: items == [])
    |> stream(:alternatives, items, reset: true)
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

    slot =
      case Policy.required_slot(user, DateTime.utc_now(:second)) do
        {:ok, slot} -> slot
        {:error, _reason} -> %{home_state: :workout_needed}
      end

    socket
    |> assign(:slot, slot)
    |> assign(:recommendation, Workouts.current_coach_recommendation(user))
    |> assign(:started_session, Workouts.current_started_session(user))
  end

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
        <%= cond do %>
          <% @slot.home_state == :week_complete -> %>
            <section
              id="home-week-complete"
              class="rounded-3xl border border-emerald-200 bg-emerald-50 p-8"
            >
              <p class="text-sm font-semibold uppercase tracking-[0.18em] text-emerald-700">
                This week
              </p>
              <h1 class="mt-3 text-3xl font-semibold tracking-tight text-slate-950">
                Training target complete
              </h1>
              <p class="mt-3 text-base leading-7 text-slate-600">
                Your next week starts fresh on Monday.
              </p>
            </section>
          <% @slot.home_state == :done_today -> %>
            <section
              id="home-done-today"
              class="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm"
            >
              <p class="text-sm font-semibold uppercase tracking-[0.18em] text-slate-500">Today</p>
              <h1 class="mt-3 text-3xl font-semibold tracking-tight text-slate-950">Workout saved</h1>
              <p class="mt-3 text-base leading-7 text-slate-600">Recovery is the useful next step.</p>
            </section>
          <% not is_nil(@started_session) -> %>
            <section
              id="home-ready-recommendation"
              class="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm"
            >
              <p class="text-sm font-semibold uppercase tracking-[0.18em] text-slate-500">
                In progress
              </p>
              <h1 class="mt-3 text-3xl font-semibold tracking-tight text-slate-950">
                Continue your workout
              </h1>
              <button
                id="resume-recommended-workout"
                phx-click="resume_recommendation"
                phx-value-session-id={@started_session.id}
                class="mt-8 inline-flex min-h-12 items-center justify-center rounded-full bg-slate-950 px-7 text-base font-semibold text-white transition hover:bg-slate-800"
              >
                Resume
              </button>
            </section>
          <% not is_nil(@home_selection) -> %>
            <HomeWorkoutComponents.workspace state={assigns} />
          <% true -> %>
            <section
              id="home-ready-recommendation"
              class="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm"
            >
              <h1 class="text-3xl font-semibold tracking-tight text-slate-950">
                Your workout is being prepared
              </h1>
              <button
                id="retry-recommendation-button"
                phx-click="retry_recommendation"
                class="mt-8 rounded-full border border-slate-300 px-6 py-3 font-semibold text-slate-800 transition hover:border-slate-500"
              >
                Retry
              </button>
            </section>
        <% end %>
      </main>
    </Layouts.app>
    """
  end
end
