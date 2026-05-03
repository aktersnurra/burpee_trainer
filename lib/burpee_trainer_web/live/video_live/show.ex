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
    video = Videos.get_video!(String.to_integer(id))
    duration_min = div(video.duration_sec, 60)

    changeset =
      Workouts.change_free_form_session(%WorkoutSession{}, %{
        "burpee_type" => Atom.to_string(video.burpee_type),
        "duration_sec_actual" => video.duration_sec
      })

    {:ok,
     socket
     |> assign(:video, video)
     |> assign(:log_visible, false)
     |> assign(:mood, 0)
     |> assign(:log_tags, [])
     |> assign(:duration_min, to_string(duration_min))
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("video_ended", _params, socket) do
    {:noreply, assign(socket, :log_visible, true)}
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

    changeset =
      %WorkoutSession{}
      |> Workouts.change_free_form_session(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), duration_min: duration_min)}
  end

  def handle_event("save", %{"workout_session" => params}, socket) do
    {params, duration_min} = apply_duration_min(params)

    params =
      params
      |> Map.put("mood", socket.assigns.mood)
      |> Map.put("tags", socket.assigns.log_tags |> Enum.sort() |> Enum.join(","))

    case Workouts.create_free_form_session(socket.assigns.current_user, params) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> put_flash(:info, "Session logged.")
         |> push_navigate(to: ~p"/history")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), duration_min: duration_min)}
    end
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
      <div class="space-y-6">
        <div class="flex items-center gap-3">
          <.link
            navigate={~p"/videos"}
            class="text-sm text-base-content/50 hover:text-base-content transition-colors"
          >
            ← Videos
          </.link>
          <span class="text-base-content/20">/</span>
          <h1 class="text-lg font-semibold tracking-tight">{@video.name}</h1>
        </div>

        <div class="rounded-lg overflow-hidden border border-base-300 bg-black">
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
          <div class="rounded-lg border border-base-300 bg-base-100 p-5 flex items-center justify-between">
            <div>
              <p class="text-sm font-medium">{@video.name}</p>
              <p class="text-xs text-base-content/50 mt-0.5">
                {burpee_label(@video.burpee_type)} · {format_duration(@video.duration_sec)}
              </p>
            </div>
            <p class="text-xs text-base-content/40">Log form appears when video ends</p>
          </div>
        <% else %>
          <div class="rounded-lg border border-primary/30 bg-base-100 p-6 space-y-5">
            <div>
              <h2 class="text-base font-semibold">Log this session</h2>
              <p class="text-sm text-base-content/50">
                Pre-filled from the video — adjust if needed.
              </p>
            </div>

            <.form
              for={@form}
              id="video-log-form"
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
                <p class="text-sm font-medium">Mood</p>
                <div class="flex gap-2">
                  <%= for {icon, label, value} <- @mood_options do %>
                    <button
                      type="button"
                      phx-click="set_mood"
                      phx-value-mood={value}
                      class={[
                        "flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm transition",
                        if(@mood == value,
                          do: "border-primary bg-primary/10 font-medium",
                          else: "border-base-300 hover:bg-base-200"
                        )
                      ]}
                    >
                      <.icon name={icon} class="size-4" /> {label}
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="space-y-1.5">
                <p class="text-sm font-medium">Tags</p>
                <div class="flex flex-wrap gap-2">
                  <%= for tag <- @tag_options do %>
                    <button
                      type="button"
                      phx-click="toggle_tag"
                      phx-value-tag={tag}
                      class={[
                        "rounded-full border px-3 py-1 text-xs transition",
                        if(tag in @log_tags,
                          do: "border-primary bg-primary/10 font-medium",
                          else: "border-base-300 hover:bg-base-200"
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
                  navigate={~p"/videos"}
                  class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
                >
                  Skip
                </.link>
                <button
                  type="submit"
                  class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
                >
                  Save session
                </button>
              </div>
            </.form>
          </div>
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
