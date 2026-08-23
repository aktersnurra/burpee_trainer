defmodule BurpeeTrainerWeb.SessionResolutionLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.{CoreComponents, Fmt}

  @mood_options [{"Tired", -1}, {"OK", 0}, {"Hyped", 1}]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case unresolved_session(user, id) do
      %WorkoutSession{} = workout_session ->
        {:ok,
         socket
         |> assign(:session, workout_session)
         |> assign(:started_at, Fmt.session_started_at(workout_session.inserted_at))
         |> assign(:source_name, source_name(workout_session))
         |> assign(:count_estimated?, is_nil(workout_session.burpee_count_actual))
         |> assign(:duration_estimated?, is_nil(workout_session.duration_sec_actual))
         |> assign(:form, report_form(workout_session))
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
      {:ok, reported, _result} ->
        {:reply,
         %{
           status: "ok",
           session_id: reported.id,
           client_session_id: reported.client_session_id,
           redirect_to: ~p"/stats"
         }, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, %{status: "error"},
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

  def handle_event(
        "reconcile_local_completion",
        %{"client_session_id" => client_session_id},
        socket
      ) do
    session = socket.assigns.session

    with true <- client_session_id == session.client_session_id,
         :running <- session.status,
         {:ok, reconciled} <-
           Workouts.mark_report_pending(socket.assigns.current_user, client_session_id) do
      {:reply, lifecycle_reply(reconciled),
       socket
       |> assign(:session, reconciled)
       |> assign(:form, report_form(reconciled))}
    else
      _ -> {:reply, lifecycle_error_reply(), socket}
    end
  end

  def handle_event("reconcile_local_completion", _params, socket) do
    {:reply, lifecycle_error_reply(), socket}
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
    assigns = assign(assigns, mood_options: @mood_options, tag_options: @tag_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:workouts}
    >
      <div
        id="session-resolution"
        phx-hook="SessionRecoveryHook"
        data-client-session-id={@session.client_session_id}
        data-session-status={@session.status}
        class="session-surface mx-auto max-w-lg space-y-6 pb-24 text-[var(--session-ink)]"
      >
        <section id="session-resolution-info" class="space-y-3">
          <p class="text-sm font-medium text-[var(--session-muted)]">Unfinished workout</p>
          <h1 class="qs-heading-tight text-3xl font-medium">Finish your workout record</h1>
          <p
            id="session-resolution-status"
            class="text-sm leading-relaxed text-[var(--session-muted)]"
          >
            This workout was left unfinished. Log what you completed or discard it before starting another.
          </p>
          <dl class="space-y-1 text-sm text-[var(--session-muted)]">
            <div class="flex justify-between gap-4">
              <dt>Started</dt>
              <dd
                id="session-resolution-started"
                class="text-right font-medium text-[var(--session-ink)]"
              >
                Started {@started_at}
              </dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt>Source</dt>
              <dd
                id="session-resolution-source"
                class="text-right font-medium text-[var(--session-ink)]"
              >
                {@source_name}
              </dd>
            </div>
          </dl>
        </section>

        <section
          id="session-resolution-workout-details"
          class="space-y-3 border-t border-[var(--session-border)] pt-6"
        >
          <h2 class="text-lg font-semibold">Workout details</h2>
          <dl class="grid grid-cols-3 gap-3 text-sm">
            <div>
              <dt class="text-[var(--session-muted)]">Type</dt>
              <dd id="session-resolution-type" class="mt-1 font-medium">
                {Fmt.burpee_type(@session.burpee_type)}
              </dd>
            </div>
            <div>
              <dt class="text-[var(--session-muted)]">Planned reps</dt>
              <dd id="session-resolution-planned-count" class="qs-tabular mt-1 font-medium">
                {@session.burpee_count_planned || "—"}
              </dd>
            </div>
            <div>
              <dt class="text-[var(--session-muted)]">Planned duration</dt>
              <dd id="session-resolution-planned-duration" class="qs-tabular mt-1 font-medium">
                {Fmt.duration_sec(@session.duration_sec_planned)}
              </dd>
            </div>
          </dl>
        </section>

        <.form for={@form} id="session-resolution-form" class="space-y-6">
          <section
            id="session-resolution-recorded-details"
            class="space-y-4 border-t border-[var(--session-border)] pt-6"
          >
            <div>
              <h2 class="text-lg font-semibold">Recorded details</h2>
              <p class="mt-1 text-sm text-[var(--session-muted)]">
                Review these values before logging your workout.
              </p>
            </div>
            <div
              :if={@form_errors != []}
              id="session-resolution-errors"
              role="alert"
              class="rounded-xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
            >
              <p :for={message <- @form_errors}>{message}</p>
            </div>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div>
                <.input
                  field={@form[:burpee_count_actual]}
                  id="session-resolution-count"
                  type="number"
                  label="Actual reps"
                  min="0"
                  inputmode="numeric"
                  data-estimated={if(@count_estimated?, do: "true")}
                />
                <p id="session-resolution-count-source" class="text-xs text-[var(--session-muted)]">
                  {if(@count_estimated?, do: "Estimated", else: "Recorded")}
                </p>
              </div>
              <div>
                <.input
                  field={@form[:duration_sec_actual]}
                  id="session-resolution-duration"
                  type="number"
                  label="Actual duration (seconds)"
                  min="0"
                  inputmode="numeric"
                  data-estimated={if(@duration_estimated?, do: "true")}
                />
                <p id="session-resolution-duration-source" class="text-xs text-[var(--session-muted)]">
                  {if(@duration_estimated?, do: "Estimated", else: "Recorded")}
                </p>
              </div>
            </div>
          </section>

          <section
            class="space-y-4 border-t border-[var(--session-border)] pt-6"
            aria-label="Reflection"
          >
            <h2 class="text-lg font-semibold">Reflection</h2>
            <.input
              field={@form[:mood]}
              id="session-resolution-mood"
              type="select"
              label="Mood"
              prompt="Choose a mood (optional)"
              options={@mood_options}
            />
            <div>
              <p class="label mb-1">Tags</p>
              <.input field={@form[:tags]} id="session-resolution-tags" type="hidden" />
              <div class="flex flex-wrap gap-2" aria-label="Tags">
                <%= for tag <- @tag_options do %>
                  <button
                    id={"session-resolution-tag-#{tag}"}
                    type="button"
                    data-tag={tag}
                    aria-pressed="false"
                    class="rounded-full border border-[var(--session-border)] px-3 py-1.5 text-xs font-medium text-[var(--session-muted)] transition hover:bg-[var(--session-track)] hover:text-[var(--session-ink)]"
                  >
                    {String.replace(tag, "_", " ")}
                  </button>
                <% end %>
              </div>
            </div>
            <.input
              field={@form[:note_post]}
              id="session-resolution-notes"
              type="textarea"
              label="Notes"
              rows="3"
              placeholder="How did it go?"
            />
          </section>

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

  defp report_form(session) do
    session
    |> Workouts.change_session_for_report(report_defaults(session))
    |> to_form()
  end

  defp report_defaults(session) do
    %{}
    |> maybe_put(
      :burpee_count_actual,
      session.burpee_count_actual || session.burpee_count_planned
    )
    |> maybe_put(
      :duration_sec_actual,
      session.duration_sec_actual || session.duration_sec_planned
    )
  end

  defp maybe_put(attrs, _field, nil), do: attrs
  defp maybe_put(attrs, field, value), do: Map.put(attrs, field, value)

  defp lifecycle_reply(session) do
    %{
      status: "ok",
      session_id: session.id,
      client_session_id: session.client_session_id,
      lifecycle_status: Atom.to_string(session.status)
    }
  end

  defp lifecycle_error_reply do
    %{
      status: "error",
      message: "Could not update workout lifecycle. Try again.",
      retryable: true
    }
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
