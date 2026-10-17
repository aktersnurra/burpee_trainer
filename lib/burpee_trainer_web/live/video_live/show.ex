defmodule BurpeeTrainerWeb.VideoLive.Show do
  @moduledoc "Loads one exact immutable video-session snapshot."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.{Fmt, Params, SessionComponents}

  # The plan session's finish screen choices, so a video logs the same way.
  @mood_options SessionComponents.mood_options()
  @tag_options SessionComponents.tag_options()
  @tag_values Enum.map(@tag_options, &elem(&1, 1))

  @impl true
  def mount(%{"video_id" => video_id, "session_id" => session_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, video_id} <- Params.positive_id(video_id),
         {:ok, session_id} <- Params.positive_id(session_id),
         {:ok,
          %WorkoutSession{
            source_kind: :video,
            workout_video_id: ^video_id,
            video_snapshot: snapshot
          } = workout_session} <- Workouts.resume_session(scope, session_id) do
      {:ok, mount_video_session(socket, video_id, snapshot, workout_session)}
    else
      _unavailable -> unavailable_video(socket)
    end
  end

  defp mount_video_session(socket, video_id, snapshot, session) do
    video = %{
      id: video_id,
      name: snapshot["name"],
      filename: snapshot["filename"],
      burpee_type: String.to_existing_atom(snapshot["type"]),
      duration_sec: snapshot["duration"],
      burpee_count: snapshot["count"],
      format: String.to_existing_atom(snapshot["format"])
    }

    socket
    |> assign(:video, video)
    |> assign(:workout_session, session)
    |> assign(:finished?, false)
    |> assign(:watched_sec, video.duration_sec)
    |> assign(:confirm_discard?, false)
    |> assign(:reps, video.burpee_count || 0)
    |> assign(:mood, nil)
    |> assign(:tags, [])
    |> assign(:note, "")
    |> assign(:form, to_form(Ecto.Changeset.change(session)))
  end

  defp unavailable_video(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Video session not found.")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  # The hook sends how far the video got: its end, or where Finish early stopped it.
  def handle_event("video_ended", params, socket) do
    duration = socket.assigns.video.duration_sec

    watched =
      case params do
        %{"watched_sec" => sec} when is_integer(sec) and sec in 0..duration//1 -> sec
        _whole_video -> duration
      end

    {:noreply, assign(socket, finished?: true, confirm_discard?: false, watched_sec: watched)}
  end

  def handle_event("ask_discard", _params, socket),
    do: {:noreply, assign(socket, :confirm_discard?, true)}

  def handle_event("keep", _params, socket),
    do: {:noreply, assign(socket, :confirm_discard?, false)}

  def handle_event("discard", _params, socket) do
    with {:ok, session} <- own_video_session(socket),
         {:ok, _discarded} <-
           Workouts.discard_started_session(socket.assigns.current_scope, session.id) do
      {:noreply, socket |> put_flash(:info, "Workout discarded.") |> push_navigate(to: ~p"/")}
    else
      :refused ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm_discard?, false)
         |> put_flash(:error, "Could not discard this workout. Please try again.")}
    end
  end

  def handle_event("step_reps", %{"step" => step}, socket) when step in ["-1", "1"] do
    reps = max(socket.assigns.reps + String.to_integer(step), 0)
    {:noreply, assign(socket, :reps, reps)}
  end

  def handle_event("step_reps", _params, socket), do: {:noreply, socket}

  def handle_event("set_mood", %{"mood" => mood}, socket) do
    case Enum.find(@mood_options, fn {_label, value} -> Integer.to_string(value) == mood end) do
      # Tapping the chosen mood again clears it: mood is optional.
      {_label, value} when value == socket.assigns.mood -> {:noreply, assign(socket, :mood, nil)}
      {_label, value} -> {:noreply, assign(socket, :mood, value)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("set_mood", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_tag", %{"tag" => tag}, socket) when tag in @tag_values do
    tags = socket.assigns.tags
    tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :tags, tags)}
  end

  def handle_event("toggle_tag", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"workout_session" => params}, socket) when is_map(params) do
    case own_video_session(socket) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> assign(:note, string_param(params, "note_post", socket.assigns.note))
         |> assign(:reps, typed_reps(params, socket.assigns.reps))}

      :refused ->
        {:noreply, socket}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"workout_session" => params}, socket) when is_map(params) do
    case own_video_session(socket) do
      {:ok, session} -> save(socket, session, completion_params(params, socket.assigns))
      :refused -> {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp save(socket, session, params) do
    scope = socket.assigns.current_scope

    case Workouts.complete_session(scope, session.id, params, :logged) do
      {:ok, session} ->
        _events = Workouts.session_milestones(scope, session)
        {:noreply, socket |> put_flash(:info, "Session logged.") |> push_navigate(to: ~p"/")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not log this session. Please try again.")}
    end
  end

  # Only the signed-in user's own started video session is completed or discarded here.
  defp own_video_session(%{
         assigns: %{
           current_scope: %{user: %{id: user_id}},
           workout_session:
             %WorkoutSession{state: :started, source_kind: :video, user_id: user_id} = session
         }
       }),
       do: {:ok, session}

  defp own_video_session(_socket), do: :refused

  # The time taken is how far the video got. The count is what was typed or stepped to;
  # anything that is not a whole number goes to the changeset as given.
  defp completion_params(params, assigns) do
    %{
      "burpee_count_actual" => Map.get(params, "burpee_count_actual", assigns.reps),
      "duration_sec_actual" => assigns.watched_sec,
      "note_post" => Map.get(params, "note_post", assigns.note),
      "mood" => assigns.mood,
      "tags" => assigns.tags |> Enum.sort() |> Enum.join(",")
    }
  end

  defp typed_reps(params, reps) do
    case Integer.parse(string_param(params, "burpee_count_actual", "")) do
      {typed, ""} when typed >= 0 -> typed
      _not_a_count -> reps
    end
  end

  defp string_param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _missing -> default
    end
  end

  defp field_errors(form, field) do
    Enum.map(form[field].errors, fn {message, _opts} -> message end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, mood_options: @mood_options, tag_options: @tag_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_level={@current_level}
      current_scope={@current_scope}
      navigation?={false}
    >
      <div
        id="video-session"
        data-session-id={@workout_session.id}
        data-client-session-id={@workout_session.client_session_id}
        data-content-hash={@workout_session.content_hash}
        class="session-surface mx-auto w-full max-w-[480px] px-1 pb-10 pt-[max(2rem,env(safe-area-inset-top))] text-[var(--session-ink)]"
      >
        <section :if={!@finished?} id="video-watch" aria-labelledby="video-heading">
          <h1 id="video-heading" class="qs-heading-tight text-2xl font-medium">{@video.name}</h1>
          <p class="qs-tabular mt-1 text-sm text-[var(--session-muted)]">
            {Fmt.burpee_type(@video.burpee_type)} · {Fmt.duration_sec(@video.duration_sec)}
          </p>
          <video
            id="workout-video"
            phx-hook="VideoHook"
            src={~p"/videos/stream/#{@video.filename}"}
            controls
            playsinline
            class="mt-6 aspect-video w-full rounded-2xl bg-black"
          ></video>
          <%!-- As when a workout is paused: finish early, or abort it. --%>
          <div
            :if={!@confirm_discard?}
            id="video-watch-actions"
            class="mx-auto mt-10 flex max-w-[360px] flex-col items-center gap-1.5"
          >
            <button
              id="video-finish-early"
              type="button"
              class="session-finish-early-action px-6 py-4 text-lg font-medium"
            >
              Finish early
            </button>
            <button
              id="video-discard-btn"
              type="button"
              phx-click="ask_discard"
              aria-controls="video-discard-confirm"
              class="min-h-14 px-6 text-base font-medium text-[var(--session-muted)] transition-colors hover:text-[var(--session-ink)]"
            >
              Abort
            </button>
          </div>
          <.discard_confirm :if={@confirm_discard?} verb="Abort" />
        </section>

        <section
          :if={@finished?}
          id="video-completion"
          aria-labelledby="video-completion-heading"
          class="pt-6"
        >
          <.form for={@form} id="video-log-form" phx-change="validate" phx-submit="save">
            <div class="text-center">
              <h1 id="video-completion-heading" class="qs-heading-tight text-3xl font-medium">
                Workout complete
              </h1>
              <%!-- The count is the result: type it, or correct it with − and +. --%>
              <div class="session-reps-stepper mt-10">
                <button
                  id="video-reps-less"
                  type="button"
                  phx-click="step_reps"
                  phx-value-step="-1"
                  disabled={@reps == 0}
                  aria-label="One rep fewer"
                  title="One rep fewer"
                  aria-controls="video-actual-reps"
                  class="session-reps-step"
                >
                  <.icon name="hero-minus" class="size-6" />
                </button>
                <label for="video-actual-reps" class="sr-only">Burpees done</label>
                <input
                  id="video-actual-reps"
                  name={@form[:burpee_count_actual].name}
                  value={@reps}
                  type="text"
                  inputmode="numeric"
                  pattern="[0-9]*"
                  autocomplete="off"
                  aria-describedby="video-reps-error"
                  class="session-reps-input qs-tabular"
                />
                <button
                  id="video-reps-more"
                  type="button"
                  phx-click="step_reps"
                  phx-value-step="1"
                  aria-label="One rep more"
                  title="One rep more"
                  aria-controls="video-actual-reps"
                  class="session-reps-step"
                >
                  <.icon name="hero-plus" class="size-6" />
                </button>
              </div>
              <p class="qs-tabular mt-5 text-lg text-[var(--session-muted)]">
                <span :if={@video.burpee_count}>of {@video.burpee_count} · </span>{Fmt.duration_sec(
                  @watched_sec
                )}
              </p>
              <p
                :for={message <- field_errors(@form, :burpee_count_actual)}
                id="video-reps-error"
                class="mt-2 text-sm text-[var(--session-error-ink)]"
              >
                {message}
              </p>
            </div>

            <div id="video-completion-mood" class="mt-12 flex border-y border-[var(--session-border)]">
              <button
                :for={{label, value} <- @mood_options}
                type="button"
                phx-click="set_mood"
                phx-value-mood={value}
                aria-pressed={to_string(@mood == value)}
                class="session-choice-toggle min-h-16 flex-1 text-sm font-medium text-[var(--session-muted)] transition-colors duration-150 active:scale-[0.98]"
              >
                {label}
              </button>
            </div>
            <div id="video-completion-tags" role="group" aria-label="Tags" class="session-tags">
              <button
                :for={{label, value} <- @tag_options}
                type="button"
                phx-click="toggle_tag"
                phx-value-tag={value}
                aria-pressed={to_string(value in @tags)}
                class="session-tag-pill"
              >
                {label}
              </button>
            </div>
            <div class="session-note-field">
              <label for="video-note-input" class="sr-only">Note</label>
              <textarea
                id="video-note-input"
                name={@form[:note_post].name}
                rows="1"
                placeholder="How did it go?"
                class="session-note-input"
              >{@note}</textarea>
            </div>
            <p
              :for={message <- field_errors(@form, :note_post)}
              class="mt-2 text-sm text-[var(--session-error-ink)]"
            >
              {message}
            </p>

            <%!-- A finished workout is saved or discarded; nothing else. --%>
            <div
              :if={!@confirm_discard?}
              id="video-completion-actions"
              class="mt-12 flex items-center justify-between gap-3"
            >
              <button
                id="video-discard-btn"
                type="button"
                phx-click="ask_discard"
                aria-label="Discard session"
                title="Discard session"
                aria-controls="video-discard-confirm"
                class="inline-flex size-14 items-center justify-center rounded-full border border-[var(--session-border)] text-[var(--session-ink)] transition-colors hover:bg-[var(--session-border)]/35"
              >
                <.icon name="hero-trash" class="size-6" />
              </button>
              <button
                id="video-save-btn"
                type="submit"
                aria-label="Save session"
                title="Save session"
                phx-disable-with
                class="inline-flex size-14 items-center justify-center rounded-full bg-[var(--session-ink)] text-[var(--session-bg)] transition-opacity hover:opacity-90"
              >
                <.icon name="hero-check" class="size-6" />
              </button>
            </div>
          </.form>
          <.discard_confirm :if={@confirm_discard?} verb="Discard" />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:verb, :string, required: true)

  # The question takes the actions' place; Keep puts them back.
  defp discard_confirm(assigns) do
    ~H"""
    <div
      id="video-discard-confirm"
      role="group"
      aria-labelledby="video-discard-question"
      aria-describedby="video-discard-consequence"
      class="mt-12 text-center"
    >
      <p id="video-discard-question" class="text-lg font-medium">{@verb} this workout?</p>
      <p id="video-discard-consequence" class="mt-1 text-sm text-[var(--session-muted)]">
        Nothing will be saved.
      </p>
      <div class="mt-5 grid grid-cols-2 gap-3">
        <button
          id="video-discard-keep"
          type="button"
          phx-click="keep"
          class="min-h-14 rounded-full border border-[var(--session-border)] text-base font-medium text-[var(--session-ink)] transition-colors hover:bg-[var(--session-border)]/35"
        >
          Keep
        </button>
        <button
          id="video-discard-yes"
          type="button"
          phx-click="discard"
          class="min-h-14 rounded-full bg-[var(--session-error-ink)] text-base font-medium text-white transition-opacity hover:opacity-90"
        >
          {@verb}
        </button>
      </div>
    </div>
    """
  end
end
