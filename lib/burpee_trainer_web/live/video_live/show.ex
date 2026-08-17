defmodule BurpeeTrainerWeb.VideoLive.Show do
  @moduledoc """
  Full-width video player. When the video ends, a log form slides up
  pre-filled with the video's burpee_type and duration.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Videos
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession

  @mood_options [
    {"hero-face-frown", "Tired", -1},
    {"hero-minus-circle", "OK", 0},
    {"hero-bolt", "Hyped", 1}
  ]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Workouts.get_unresolved_session(user) do
      %WorkoutSession{} = workout_session ->
        {:ok, push_navigate(socket, to: ~p"/sessions/#{workout_session.id}/resolve")}

      nil ->
        video = Videos.get_video!(String.to_integer(id))

        {:ok,
         socket
         |> assign(:video, video)
         |> assign(:client_session_id, nil)
         |> assign(:lifecycle_session, nil)
         |> assign(:video_started, false)
         |> assign(:log_visible, false)
         |> assign(:mood, 0)
         |> assign(:log_tags, [])
         |> assign(:duration_min, to_string(div(video.duration_sec, 60)))
         |> assign(:form, to_form(Workouts.change_free_form_session(%WorkoutSession{})))}
    end
  end

  @impl true
  def handle_event("begin_video_session", %{"client_session_id" => client_session_id}, socket) do
    case begin_video_session(socket, client_session_id) do
      {:ok, session} ->
        {:reply, lifecycle_reply({:ok, session}),
         socket
         |> assign(:client_session_id, session.client_session_id)
         |> assign(:lifecycle_session, session)
         |> assign(:video_started, true)}

      {:error, reason} ->
        {:reply, lifecycle_error_reply(reason), socket}
    end
  end

  def handle_event("begin_video_session", _params, socket) do
    {:reply, lifecycle_error_reply(:not_found), socket}
  end

  def handle_event(
        "mark_video_report_pending",
        %{"client_session_id" => client_session_id},
        socket
      ) do
    case mark_video_report_pending(socket, client_session_id) do
      {:ok, session} ->
        {:reply, lifecycle_reply({:ok, session}),
         socket
         |> assign(:lifecycle_session, session)
         |> assign(:log_visible, true)
         |> assign(:form, to_form(report_changeset(session, default_report_attrs(session))))
         |> assign(:duration_min, to_string(div(session.duration_sec_planned || 0, 60)))}

      {:error, reason} ->
        {:reply, lifecycle_error_reply(reason), socket}
    end
  end

  def handle_event("mark_video_report_pending", _params, socket) do
    {:reply, lifecycle_error_reply(:not_found), socket}
  end

  def handle_event("set_mood", %{"mood" => mood_str}, socket) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> socket.assigns.mood
      end

    {:noreply, assign(socket, :mood, mood)}
  end

  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    tags = socket.assigns.log_tags
    new_tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :log_tags, new_tags)}
  end

  def handle_event("validate", %{"workout_session" => params}, socket) do
    {params, duration_min} = apply_duration_min(params)
    changeset = report_changeset(socket.assigns.lifecycle_session, params)

    {:noreply,
     assign(socket,
       form: to_form(Map.put(changeset, :action, :validate)),
       duration_min: duration_min
     )}
  end

  def handle_event("save", %{"workout_session" => params}, socket) do
    {params, duration_min} = apply_duration_min(params)

    params =
      params
      |> Map.put("mood", socket.assigns.mood)
      |> Map.put("tags", socket.assigns.log_tags |> Enum.sort() |> Enum.join(","))

    case report_video_session(socket, params) do
      {:ok, session, _result} ->
        _events = Workouts.session_milestones(socket.assigns.current_user, session)

        {:noreply,
         socket
         |> put_flash(:info, "Session logged.")
         |> push_navigate(to: ~p"/stats")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), duration_min: duration_min)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not save this workout. Try again.")
         |> assign(:duration_min, duration_min)}
    end
  end

  defp begin_video_session(socket, client_session_id) do
    with :ok <- claim_client_session_id(socket, client_session_id) do
      Workouts.begin_video_session(
        socket.assigns.current_user,
        socket.assigns.video,
        client_session_id
      )
    end
  end

  defp mark_video_report_pending(socket, client_session_id) do
    with :ok <- mounted_client_session?(socket, client_session_id) do
      Workouts.mark_report_pending(socket.assigns.current_user, client_session_id)
    end
  end

  defp report_video_session(socket, params) do
    with :ok <- mounted_client_session?(socket, socket.assigns.client_session_id) do
      Workouts.report_session(
        socket.assigns.current_user,
        socket.assigns.client_session_id,
        params,
        %{"enabled" => false, "trust" => "manual"}
      )
    end
  end

  defp claim_client_session_id(socket, client_session_id) do
    if socket.assigns.client_session_id in [nil, client_session_id] and
         match?({:ok, _}, Ecto.UUID.cast(client_session_id)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp mounted_client_session?(socket, client_session_id) do
    if socket.assigns.client_session_id == client_session_id and
         match?({:ok, _}, Ecto.UUID.cast(client_session_id)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp default_report_attrs(session) do
    %{
      "burpee_count_actual" => session.burpee_count_planned,
      "duration_sec_actual" => session.duration_sec_planned
    }
  end

  defp report_changeset(session, attrs)

  defp report_changeset(%WorkoutSession{} = session, attrs) do
    Workouts.change_session_for_report(session, attrs)
  end

  defp report_changeset(nil, attrs) do
    Workouts.change_free_form_session(%WorkoutSession{}, attrs)
  end

  defp lifecycle_reply({:ok, session}) do
    %{
      status: "ok",
      client_session_id: session.client_session_id,
      session_id: session.id,
      lifecycle_status: Atom.to_string(session.status)
    }
  end

  defp lifecycle_error_reply({:unresolved_session, %WorkoutSession{} = session}) do
    %{
      status: "error",
      reason: "unresolved_session",
      message: "Finish or discard your current workout before starting another one.",
      retryable: true,
      session_id: session.id,
      resolve_to: ~p"/sessions/#{session.id}/resolve"
    }
  end

  defp lifecycle_error_reply(reason) when is_atom(reason) do
    %{
      status: "error",
      reason: Atom.to_string(reason),
      message: "Could not update workout lifecycle. Try again.",
      retryable: reason not in [:aborted, :already_reported, :report_conflict]
    }
  end

  defp lifecycle_error_reply(_reason) do
    %{status: "error", message: "Could not update workout lifecycle. Try again.", retryable: true}
  end

  defp apply_duration_min(params) do
    raw = Map.get(params, "duration_min", "")

    params =
      case parse_minutes(raw) do
        {:ok, minutes} -> Map.put(params, "duration_sec_actual", minutes * 60)
        :error -> Map.put(params, "duration_sec_actual", "")
      end

    {Map.delete(params, "duration_min"), to_string(raw)}
  end

  defp parse_minutes(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_minutes(_), do: :error

  defp duration_errors(form) do
    field = form[:duration_sec_actual]

    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, fn {msg, _} -> msg end)
    else
      []
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
      current_page={:videos}
    >
      <div class="session-surface mx-auto max-w-lg space-y-6 pb-24 text-[var(--session-ink)]">
        <div class="flex items-center gap-3">
          <.link
            navigate={~p"/workouts"}
            class="text-sm font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
          >
            ← Videos
          </.link>
          <span class="text-[var(--session-muted)]/40">/</span>
          <h1 class="text-lg font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
            {@video.name}
          </h1>
        </div>

        <div class="overflow-hidden rounded-xl border border-[var(--session-border)] bg-black">
          <video
            id="workout-video"
            phx-hook="VideoHook"
            src={~p"/videos/stream/#{@video.filename}"}
            controls={@video_started}
            class="w-full"
          >
          </video>
        </div>

        <section class="space-y-3" aria-label="Video workout lifecycle">
          <button
            id="video-start-workout"
            type="button"
            disabled={@video_started}
            class="w-full rounded-md bg-[var(--session-ink)] px-4 py-3 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"
          >
            {if @video_started, do: "Workout started", else: "Start workout"}
          </button>
          <p
            id="video-lifecycle-status"
            role="status"
            aria-live="polite"
            class="text-sm text-[var(--session-muted)]"
          >
            Start the workout to enable video playback and durable reporting.
          </p>
          <p
            id="video-lifecycle-error"
            role="alert"
            hidden
            class="text-sm text-red-700"
          >
          </p>
          <.link
            id="video-resolve-session"
            navigate={~p"/workouts"}
            hidden
            class="text-sm font-medium text-[var(--session-ink)] underline underline-offset-4"
          >
            Finish your current workout
          </.link>
          <button
            id="video-report-retry"
            type="button"
            hidden
            class="rounded-md border border-[var(--session-border)] px-4 py-2 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
          >
            Retry showing the report form
          </button>
        </section>

        <%= if not @log_visible do %>
          <.qs_surface class="flex items-center justify-between gap-4 bg-[var(--session-surface)]/55 p-5">
            <div>
              <p class="text-sm font-medium text-[var(--session-ink)]">{@video.name}</p>
              <p class="mt-0.5 text-xs text-[var(--session-muted)]">
                {burpee_label(@video.burpee_type)} · {format_duration(@video.duration_sec)}
              </p>
            </div>
            <p class="text-right text-xs text-[var(--session-muted)]">
              Log form appears when video ends
            </p>
          </.qs_surface>
        <% else %>
          <.qs_surface class="space-y-5 bg-[var(--session-surface)]/55 p-6">
            <div>
              <h2 class="text-base font-semibold text-[var(--session-ink)]">Log this session</h2>
              <p class="text-sm text-[var(--session-muted)]">
                Pre-filled from the video — adjust if needed.
              </p>
            </div>

            <.form
              for={@form}
              id="video-log-form"
              data-client-session-id={@client_session_id}
              phx-change="validate"
              phx-submit="save"
              class="space-y-5"
            >
              <.input
                field={@form[:burpee_type]}
                type="select"
                label="Burpee type"
                options={[{"6-count", "six_count"}, {"Navy SEAL", "navy_seal"}]}
              />

              <div class="grid gap-4 sm:grid-cols-2">
                <.input
                  field={@form[:burpee_count_actual]}
                  type="number"
                  label="Burpees done"
                  min="0"
                />
                <.input
                  name="workout_session[duration_min]"
                  value={@duration_min}
                  type="number"
                  label="Duration (minutes)"
                  min="0"
                  errors={duration_errors(@form)}
                />
              </div>

              <div class="space-y-1.5">
                <p class="text-sm font-medium text-[var(--session-ink)]">Mood</p>
                <div class="flex flex-wrap gap-2">
                  <%= for {icon, label, value} <- @mood_options do %>
                    <button
                      type="button"
                      phx-click="set_mood"
                      phx-value-mood={value}
                      class={[
                        "flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm transition",
                        if(@mood == value,
                          do:
                            "border-[var(--session-toggle-border)] bg-[var(--session-toggle-bg)] font-medium text-[var(--session-toggle-ink)]",
                          else:
                            "border-[var(--session-border)] bg-[var(--session-bg)]/45 text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
                        )
                      ]}
                    >
                      <.icon name={icon} class="size-4" /> {label}
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="space-y-1.5">
                <p class="text-sm font-medium text-[var(--session-ink)]">Tags</p>
                <div class="flex flex-wrap gap-2">
                  <%= for tag <- @tag_options do %>
                    <button
                      type="button"
                      phx-click="toggle_tag"
                      phx-value-tag={tag}
                      class={[
                        "rounded-md border px-3 py-1 text-xs transition",
                        if(tag in @log_tags,
                          do:
                            "border-[var(--session-tag-border)] bg-[var(--session-tag-bg)] font-medium text-[var(--session-tag-ink)]",
                          else:
                            "border-[var(--session-border)] bg-[var(--session-bg)]/45 text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
                        )
                      ]}
                    >
                      {String.replace(tag, "_", " ")}
                    </button>
                  <% end %>
                </div>
              </div>

              <.input field={@form[:note_pre]} type="textarea" label="Pre-session notes (optional)" />
              <.input field={@form[:note_post]} type="textarea" label="Post-session notes (optional)" />

              <div class="flex justify-end gap-2 pt-2">
                <.link
                  navigate={~p"/workouts"}
                  class="rounded-md border border-[var(--session-border)] px-4 py-2 text-sm text-[var(--session-muted)] transition hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
                >
                  Skip
                </.link>
                <button
                  type="submit"
                  class="rounded-md bg-[var(--session-ink)] px-4 py-2 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90"
                >
                  Save session
                </button>
              </div>
            </.form>
          </.qs_surface>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp burpee_label(:six_count), do: "6-Count"
  defp burpee_label(:navy_seal), do: "Navy SEAL"

  defp format_duration(sec) do
    min = div(sec, 60)
    rem = rem(sec, 60)
    if rem == 0, do: "#{min} min", else: "#{min}m #{rem}s"
  end
end
