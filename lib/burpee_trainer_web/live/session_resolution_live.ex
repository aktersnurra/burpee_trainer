defmodule BurpeeTrainerWeb.SessionResolutionLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.{CoreComponents, Fmt}

  @mood_options [{"Tired", -1}, {"OK", 0}, {"Hyped", 1}]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case unresolved_session(user, id) do
      %WorkoutSession{} = workout_session ->
        {:ok,
         socket
         |> assign(:session, workout_session)
         |> assign(:source_name, source_name(workout_session))
         |> assign(:form, to_form(Workouts.change_session_for_report(workout_session)))
         |> assign(:form_errors, [])}

      nil ->
        {:ok, push_navigate(socket, to: ~p"/stats")}
    end
  end

  @impl true
  def handle_event("report", %{"workout_session" => attrs}, socket) when is_map(attrs) do
    session = socket.assigns.session

    case Workouts.report_session(
           socket.assigns.current_user,
           session.client_session_id,
           attrs,
           %{}
         ) do
      {:ok, _reported, _result} ->
        {:noreply, push_navigate(socket, to: ~p"/stats")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset, action: :validate))
         |> assign(:form_errors, error_messages(changeset))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "This workout is no longer available to report.")
         |> push_navigate(to: ~p"/stats")}
    end
  end

  def handle_event("report", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Workout report data is invalid.")
     |> push_navigate(to: ~p"/stats")}
  end

  @impl true
  def handle_event("abort", _params, socket) do
    session = socket.assigns.session

    case Workouts.abort_session(socket.assigns.current_user, session.client_session_id) do
      {:ok, _aborted} ->
        {:noreply, push_navigate(socket, to: ~p"/workouts")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "This workout is no longer available to discard.")
         |> push_navigate(to: ~p"/workouts")}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, mood_options: @mood_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:workouts}
    >
      <div
        id="session-resolution"
        data-client-session-id={@session.client_session_id}
        class="session-surface mx-auto max-w-lg space-y-6 pb-24 text-[var(--session-ink)]"
      >
        <section class="space-y-2">
          <p class="text-sm font-medium text-[var(--session-muted)]">Unfinished workout</p>
          <h1 class="qs-heading-tight text-3xl font-medium">Finish your workout record</h1>
          <p
            id="session-resolution-status"
            class="text-sm leading-relaxed text-[var(--session-muted)]"
          >
            This unfinished workout must be logged or discarded before you start another one.
          </p>
        </section>

        <section class="grid grid-cols-2 gap-3" aria-label="Planned workout details">
          <div class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)]/60 p-4">
            <p class="text-xs font-medium text-[var(--session-muted)]">Source</p>
            <p id="session-resolution-source" class="mt-1 font-medium">{@source_name}</p>
          </div>
          <div class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)]/60 p-4">
            <p class="text-xs font-medium text-[var(--session-muted)]">Type</p>
            <p id="session-resolution-type" class="mt-1 font-medium">
              {Fmt.burpee_type(@session.burpee_type)}
            </p>
          </div>
          <div class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)]/60 p-4">
            <p class="text-xs font-medium text-[var(--session-muted)]">Planned reps</p>
            <p id="session-resolution-planned-count" class="qs-tabular mt-1 text-xl font-semibold">
              {@session.burpee_count_planned || "—"}
            </p>
          </div>
          <div class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)]/60 p-4">
            <p class="text-xs font-medium text-[var(--session-muted)]">Planned duration</p>
            <p id="session-resolution-planned-duration" class="qs-tabular mt-1 text-xl font-semibold">
              {Fmt.duration_sec(@session.duration_sec_planned)}
            </p>
          </div>
        </section>

        <.form for={@form} id="session-resolution-form" phx-submit="report" class="space-y-4">
          <div
            :if={@form_errors != []}
            id="session-resolution-errors"
            role="alert"
            class="rounded-xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
          >
            <p :for={message <- @form_errors}>{message}</p>
          </div>
          <.input
            field={@form[:burpee_count_actual]}
            id="session-resolution-count"
            type="number"
            label="Actual reps"
            min="0"
            inputmode="numeric"
          />
          <.input
            field={@form[:duration_sec_actual]}
            id="session-resolution-duration"
            type="number"
            label="Actual duration (seconds)"
            min="0"
            inputmode="numeric"
          />
          <.input
            field={@form[:mood]}
            id="session-resolution-mood"
            type="select"
            label="Mood"
            prompt="Choose a mood (optional)"
            options={@mood_options}
          />
          <.input
            field={@form[:tags]}
            id="session-resolution-tags"
            type="text"
            label="Tags"
            placeholder="e.g. tired, great_energy"
          />
          <.input
            field={@form[:note_post]}
            id="session-resolution-notes"
            type="textarea"
            label="Notes"
            rows="3"
            placeholder="How did it go?"
          />

          <button
            id="session-resolution-report"
            type="submit"
            class="min-h-12 w-full rounded-xl bg-[var(--session-ink)] px-5 py-3 font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99]"
          >
            Log workout
          </button>
        </.form>

        <button
          id="session-resolution-abort"
          type="button"
          phx-click="abort"
          data-confirm="Discard this unfinished workout?"
          class="min-h-11 w-full px-5 py-3 text-sm font-medium text-[var(--session-muted)] underline underline-offset-4 transition hover:text-[var(--session-ink)]"
        >
          Discard workout
        </button>
      </div>
    </Layouts.app>
    """
  end

  defp unresolved_session(user, id) do
    with {session_id, ""} <- Integer.parse(id),
         %WorkoutSession{id: ^session_id} = session <- Workouts.get_unresolved_session(user) do
      session
    else
      _ -> nil
    end
  end

  defp error_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
    |> Map.values()
    |> List.flatten()
  end

  defp source_name(%WorkoutSession{source: :plan, plan: %{name: name}}) when is_binary(name),
    do: name

  defp source_name(%WorkoutSession{source: :video, video: %{name: name}}) when is_binary(name),
    do: name

  defp source_name(%WorkoutSession{source: :plan}), do: "Workout plan"
  defp source_name(%WorkoutSession{source: :video}), do: "Workout video"
  defp source_name(%WorkoutSession{}), do: "Workout"
end
