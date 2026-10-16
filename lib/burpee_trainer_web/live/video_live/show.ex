defmodule BurpeeTrainerWeb.VideoLive.Show do
  @moduledoc "Loads one exact immutable video-session snapshot."

  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession

  @mood_options [
    {"hero-face-frown", "Tired", -1},
    {"hero-minus-circle", "OK", 0},
    {"hero-bolt", "Hyped", 1}
  ]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]
  @completion_string_fields ~w[
    burpee_count_actual
    duration_min
    note_pre
    note_post
    context_low_energy
    context_high_energy
    context_heat_affected
    primary_limiter
    preference_feedback
  ]

  @impl true
  def mount(%{"video_id" => video_id, "session_id" => session_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, video_id} <- parse_positive_id(video_id),
         {:ok, session_id} <- parse_positive_id(session_id),
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
    |> assign(:log_visible, false)
    |> assign(:mood, 0)
    |> assign(:log_tags, [])
    |> assign(:duration_min, Integer.to_string(div(video.duration_sec, 60)))
    |> assign(:form, to_form(Ecto.Changeset.change(session)))
  end

  defp unavailable_video(socket) do
    {:ok,
     socket
     |> put_flash(:error, "Video session not found.")
     |> push_navigate(to: ~p"/")}
  end

  defp parse_positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  defp parse_positive_id(_forged), do: {:error, :invalid_id}

  @impl true
  def handle_event(
        "video_ended",
        _params,
        %{assigns: %{workout_session: %WorkoutSession{}}} = socket
      ) do
    {:noreply, assign(socket, :log_visible, true)}
  end

  def handle_event("video_ended", _params, socket), do: {:noreply, socket}

  def handle_event("set_mood", %{"mood" => mood_str}, socket) when is_binary(mood_str) do
    mood =
      case Integer.parse(mood_str) do
        {mood, ""} when mood in [-1, 0, 1] -> mood
        _invalid -> socket.assigns.mood
      end

    {:noreply, assign(socket, :mood, mood)}
  end

  def handle_event("set_mood", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_tag", %{"tag" => tag}, socket)
      when is_binary(tag) and tag in @tag_options do
    tags = socket.assigns.log_tags
    tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :log_tags, tags)}
  end

  def handle_event("toggle_tag", _params, socket), do: {:noreply, socket}

  def handle_event(
        "validate",
        %{"workout_session" => params},
        %{
          assigns: %{
            current_scope: %{user: %{id: user_id}},
            workout_session:
              %WorkoutSession{state: :started, source_kind: :video} = workout_session
          }
        } = socket
      )
      when is_map(params) and workout_session.user_id == user_id do
    {params, duration_min} = params |> normalize_completion_params() |> apply_duration_min()

    changeset =
      workout_session
      |> WorkoutSession.completion_changeset(params, DateTime.utc_now(:second))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), duration_min: duration_min)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save",
        %{"workout_session" => params},
        %{
          assigns: %{
            current_scope: %{user: %{id: user_id}} = scope,
            workout_session:
              %WorkoutSession{state: :started, source_kind: :video} = workout_session
          }
        } = socket
      )
      when is_map(params) and workout_session.user_id == user_id do
    {params, duration_min} = params |> normalize_completion_params() |> apply_duration_min()

    params =
      params
      |> Map.put("mood", socket.assigns.mood)
      |> Map.put("tags", socket.assigns.log_tags |> Enum.sort() |> Enum.join(","))

    case Workouts.complete_session(
           scope,
           workout_session.id,
           params,
           :logged
         ) do
      {:ok, session} ->
        _events = Workouts.session_milestones(socket.assigns.current_scope, session)

        {:noreply,
         socket
         |> put_flash(:info, "Session logged.")
         |> push_navigate(to: ~p"/")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), duration_min: duration_min)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not log this session. Please try again.")
         |> assign(duration_min: duration_min)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp normalize_completion_params(params) do
    Map.new(@completion_string_fields, fn field ->
      value = Map.get(params, field, "")
      {field, if(is_binary(value), do: value, else: "")}
    end)
  end

  defp apply_duration_min(params) do
    raw = Map.get(params, "duration_min", "")

    params =
      case Integer.parse(String.trim(raw)) do
        {minutes, ""} when minutes >= 0 -> Map.put(params, "duration_sec_actual", minutes * 60)
        _invalid -> Map.put(params, "duration_sec_actual", "")
      end

    {Map.delete(params, "duration_min"), raw}
  end

  defp duration_errors(form) do
    field = form[:duration_sec_actual]

    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, fn {message, _opts} -> message end)
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
      current_level={@current_level}
      current_scope={@current_scope}
      current_page={:session}
    >
      <div
        id="video-session"
        data-session-id={@workout_session.id}
        data-client-session-id={@workout_session.client_session_id}
        data-content-hash={@workout_session.content_hash}
        class="session-surface mx-auto max-w-lg space-y-6 pb-24 text-[var(--session-ink)]"
      >
        <div class="flex items-center gap-3">
          <.link
            id="videos-back-link"
            navigate={~p"/"}
            class="text-sm font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
          >
            ← Home
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
            controls
            class="w-full"
          >
          </video>
        </div>

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
                Confirm the reps and time you completed.
              </p>
            </div>

            <.form
              for={@form}
              id="video-log-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-5"
            >
              <div
                id="video-burpee-type"
                class="rounded-lg border border-[var(--session-border)] px-4 py-3"
              >
                <p class="text-sm font-semibold text-[var(--session-ink)]">
                  {burpee_label(@video.burpee_type)}
                </p>
              </div>

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

              <fieldset
                id="video-typed-feedback"
                class="space-y-5 border-t border-[var(--session-border)] pt-5"
              >
                <legend class="text-sm font-semibold text-[var(--session-ink)]">
                  Workout feedback
                </legend>
                <.input
                  field={@form[:context_low_energy]}
                  id="video-context-low-energy"
                  type="checkbox"
                  label="Low energy"
                />
                <.input
                  field={@form[:context_high_energy]}
                  id="video-context-high-energy"
                  type="checkbox"
                  label="High energy"
                />
                <.input
                  field={@form[:context_heat_affected]}
                  id="video-context-heat-affected"
                  type="checkbox"
                  label="Heat affected performance"
                />
                <.input
                  field={@form[:primary_limiter]}
                  id="video-primary-limiter"
                  type="select"
                  label="Primary limiter"
                  prompt="No primary limiter"
                  options={[
                    {"Breathing", "breathing"},
                    {"Whole-body recovery", "whole_body"},
                    {"Upper body", "upper_body"},
                    {"Legs", "legs"}
                  ]}
                />
                <.input
                  field={@form[:preference_feedback]}
                  id="video-preference-feedback"
                  type="select"
                  label="Workout preference"
                  prompt="No preference"
                  options={[
                    {"Would choose this workout again", "choose_again"},
                    {"Would avoid this workout", "avoid"}
                  ]}
                />
              </fieldset>

              <div class="flex flex-wrap gap-2">
                <%= for {icon, label, value} <- @mood_options do %>
                  <button
                    type="button"
                    phx-click="set_mood"
                    phx-value-mood={value}
                    class="rounded-md border px-3 py-1.5 text-sm"
                  >
                    <.icon name={icon} class="size-4" /> {label}
                  </button>
                <% end %>
              </div>

              <div class="flex flex-wrap gap-2">
                <%= for tag <- @tag_options do %>
                  <button
                    type="button"
                    phx-click="toggle_tag"
                    phx-value-tag={tag}
                    class="rounded-md border px-3 py-1 text-xs"
                  >
                    {String.replace(tag, "_", " ")}
                  </button>
                <% end %>
              </div>

              <.input field={@form[:note_pre]} type="textarea" label="Pre-session notes (optional)" />
              <.input
                field={@form[:note_post]}
                type="textarea"
                label="Post-session notes (optional)"
              />

              <button
                type="submit"
                class="w-full rounded-md bg-[var(--session-ink)] px-4 py-2 text-sm font-medium text-[var(--session-bg)]"
              >
                Save session
              </button>
            </.form>
          </.qs_surface>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp burpee_label(:six_count), do: "Six-count"
  defp burpee_label(:navy_seal), do: "Navy SEAL"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)
    if remainder == 0, do: "#{minutes} min", else: "#{minutes}m #{remainder}s"
  end
end
