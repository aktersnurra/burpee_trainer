defmodule BurpeeTrainerWeb.LogLive do
  @moduledoc """
  Free-form session entry. No plan, no timer — just record that a
  workout happened, how many burpees, how long, and any notes.
  The session date defaults to today and is editable.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession

  @mood_options [{"hero-face-frown", "Tired", -1}, {"hero-minus-circle", "OK", 0}, {"hero-bolt", "Hyped", 1}]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, build_form(socket)}
  end

  defp build_form(socket) do
    changeset = Workouts.change_free_form_session(%WorkoutSession{})

    assign(socket,
      form: to_form(changeset),
      date: Date.utc_today(),
      duration_min: "",
      mood: 0,
      log_tags: []
    )
  end

  @impl true
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
    params = maybe_override_inserted_at(params)

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

  defp maybe_override_inserted_at(%{"date" => date} = params)
       when is_binary(date) and date != "" do
    with {:ok, parsed} <- Date.from_iso8601(date),
         {:ok, datetime} <- DateTime.new(parsed, ~T[12:00:00], "Etc/UTC") do
      Map.put(params, "inserted_at", DateTime.truncate(datetime, :second))
    else
      _ -> params
    end
  end

  defp maybe_override_inserted_at(params), do: params

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
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level} current_page={:log}>
      <div class="max-w-xl mx-auto space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Log session</h1>
          <p class="text-sm text-base-content/60">
            Record a workout you did without the built-in timer.
          </p>
        </div>

        <.form
          for={@form}
          id="log-form"
          phx-change="validate"
          phx-submit="save"
          class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-5"
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

          <div>
            <label class="block text-sm font-medium mb-1" for="session-date">Session date</label>
            <input
              id="session-date"
              type="date"
              name="workout_session[date]"
              value={Date.to_iso8601(@date)}
              class="w-full rounded-md border border-base-300 bg-base-100 px-3 py-2"
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
              navigate={~p"/"}
              class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
            >
              Cancel
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
    </Layouts.app>
    """
  end
end
