defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc "Present-tense home surface for the current deterministic recommendation."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{CoachReconciler, Workouts}
  alias BurpeeTrainer.Coach.Policy
  alias BurpeeTrainer.Workouts.{CoachRecommendation, WorkoutSession}
  alias BurpeeTrainerWeb.HomeCoachComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:start_client_session_id, Ecto.UUID.generate())
     |> assign_home()}
  end

  @impl true
  def handle_event("start_recommendation", params, socket) do
    user = socket.assigns.current_user

    result =
      with client_session_id when is_binary(client_session_id) <- params["client-session-id"],
           true <- client_session_id == socket.assigns.start_client_session_id do
        case rendered_selection(params) do
          {:plan, plan_id} -> Workouts.start_plan(user, plan_id, client_session_id)
          {:video, video_id} -> Workouts.start_video(user, video_id, client_session_id)
          :invalid -> {:error, :invalid_selection}
        end
      else
        _invalid -> {:error, :invalid_start_token}
      end

    case result do
      {:ok, %WorkoutSession{} = session} ->
        {:noreply, push_navigate(socket, to: session_path(session))}

      _error ->
        {:noreply, put_flash(socket, :error, "That workout is no longer available.")}
    end
  end

  def handle_event("resume_recommendation", %{"session-id" => session_id}, socket) do
    with {session_id, ""} <- Integer.parse(session_id),
         {:ok, session} <- Workouts.resume_session(socket.assigns.current_user, session_id) do
      {:noreply, push_navigate(socket, to: session_path(session))}
    else
      _error ->
        {:noreply,
         socket |> put_flash(:error, "That session cannot be resumed.") |> assign_home()}
    end
  end

  def handle_event("use_candidate", params, socket) do
    with %CoachRecommendation{id: recommendation_id, pending_draft_id: draft_id}
         when is_integer(draft_id) <- socket.assigns.recommendation,
         {candidate_id, ""} <- Integer.parse(params["draft-id"] || ""),
         true <- candidate_id == draft_id,
         expected when expected != :invalid <- rendered_selection(params),
         {:ok, _recommendation} <-
           Workouts.accept_candidate(
             socket.assigns.current_user,
             recommendation_id,
             draft_id,
             expected
           ) do
      {:noreply, socket |> put_flash(:info, "Workout added to your library.") |> assign_home()}
    else
      _error ->
        {:noreply,
         socket |> put_flash(:error, "That option is no longer current.") |> assign_home()}
    end
  end

  def handle_event("keep_current", params, socket) do
    with %CoachRecommendation{id: recommendation_id, pending_draft_id: draft_id}
         when is_integer(draft_id) <- socket.assigns.recommendation,
         {candidate_id, ""} <- Integer.parse(params["draft-id"] || ""),
         true <- candidate_id == draft_id,
         expected when expected != :invalid <- rendered_selection(params),
         :ok <-
           Workouts.reject_candidate(
             socket.assigns.current_user,
             recommendation_id,
             draft_id,
             expected
           ) do
      {:noreply, socket |> put_flash(:info, "Current workout kept.") |> assign_home()}
    else
      _error ->
        {:noreply,
         socket |> put_flash(:error, "That option is no longer current.") |> assign_home()}
    end
  end

  def handle_event("retry_recommendation", _params, socket) do
    :ok = CoachReconciler.wake(socket.assigns.current_user.id, :retry)
    {:noreply, put_flash(socket, :info, "Looking for another option.")}
  end

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

  defp rendered_selection(%{"plan-id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> {:plan, id}
      _invalid -> :invalid
    end
  end

  defp rendered_selection(%{"video-id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> {:video, id}
      _invalid -> :invalid
    end
  end

  defp rendered_selection(_params), do: :invalid

  defp selection_params(%CoachRecommendation{selected_workout_plan_id: id})
       when is_integer(id),
       do: [plan_id: id]

  defp selection_params(%CoachRecommendation{selected_workout_video_id: id})
       when is_integer(id),
       do: [video_id: id]

  defp selection_params(_recommendation), do: []

  defp selection_title(%CoachRecommendation{selected_workout_plan: %{name: name}}), do: name
  defp selection_title(%CoachRecommendation{selected_workout_video: %{name: name}}), do: name
  defp selection_title(_recommendation), do: "Ready workout"

  defp selection_detail(%CoachRecommendation{selected_workout_plan: plan})
       when not is_nil(plan) do
    "#{plan.target_reps} reps · #{div(plan.target_duration_sec, 60)} min"
  end

  defp selection_detail(%CoachRecommendation{selected_workout_video: video})
       when not is_nil(video) do
    "#{div(video.duration_sec, 60)} min video"
  end

  defp selection_detail(_recommendation), do: "Ready when you are"

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
          <% not is_nil(@recommendation) -> %>
            <section
              id="home-ready-recommendation"
              class="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm"
            >
              <HomeCoachComponents.recommendation_heading
                eyebrow="Ready now"
                title={selection_title(@recommendation)}
                detail={selection_detail(@recommendation)}
              />
              <button
                id="start-recommended-workout"
                phx-click="start_recommendation"
                phx-value-plan-id={selection_params(@recommendation)[:plan_id]}
                phx-value-video-id={selection_params(@recommendation)[:video_id]}
                phx-value-client-session-id={@start_client_session_id}
                class="mt-8 inline-flex min-h-12 items-center justify-center rounded-full bg-slate-950 px-7 text-base font-semibold text-white transition hover:bg-slate-800 disabled:opacity-60"
                phx-disable-with="Starting…"
              >
                Start workout
              </button>
            </section>
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

        <%= if @slot.home_state == :workout_needed && @recommendation &&
              @recommendation.pending_draft do %>
          <section
            id="home-pending-candidate"
            class="mt-6 rounded-3xl border border-amber-200 bg-amber-50 p-6"
          >
            <p class="text-sm font-semibold uppercase tracking-[0.18em] text-amber-800">
              Another option
            </p>
            <h2 class="mt-2 text-xl font-semibold text-slate-950">
              {@recommendation.pending_draft.name}
            </h2>
            <div class="mt-5 flex flex-wrap gap-3">
              <button
                id="use-candidate-button"
                phx-click="use_candidate"
                phx-value-draft-id={@recommendation.pending_draft_id}
                phx-value-plan-id={selection_params(@recommendation)[:plan_id]}
                phx-value-video-id={selection_params(@recommendation)[:video_id]}
                class="rounded-full bg-slate-950 px-5 py-2.5 font-semibold text-white transition hover:bg-slate-800"
              >
                Use this workout
              </button>
              <button
                id="keep-current-workout-button"
                phx-click="keep_current"
                phx-value-draft-id={@recommendation.pending_draft_id}
                phx-value-plan-id={selection_params(@recommendation)[:plan_id]}
                phx-value-video-id={selection_params(@recommendation)[:video_id]}
                class="rounded-full border border-amber-300 px-5 py-2.5 font-semibold text-slate-800 transition hover:border-amber-500"
              >
                Current workout is better
              </button>
            </div>
          </section>
        <% end %>
      </main>
    </Layouts.app>
    """
  end
end
