defmodule BurpeeTrainerWeb.LogFormComponent do
  use BurpeeTrainerWeb, :live_component

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession

  @mood_options [
    {"hero-face-frown", "Tired", -1},
    {"hero-minus-circle", "OK", 0},
    {"hero-bolt", "Hyped", 1}
  ]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  @impl true
  def mount(socket) do
    {:ok, build_form(socket)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  defp build_form(socket) do
    changeset = Workouts.change_free_form_session(%WorkoutSession{})

    assign(socket,
      form: to_form(changeset),
      mood: 0,
      log_tags: [],
      mood_options: @mood_options,
      tag_options: @tag_options
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

  def handle_event("save", %{"workout_session" => params}, socket) do
    user = socket.assigns.current_user
    tags_str = socket.assigns.log_tags |> Enum.sort() |> Enum.join(",")

    full_params =
      params
      |> Map.put("mood", to_string(socket.assigns.mood))
      |> Map.put("tags", tags_str)

    case Workouts.create_free_form_session(user, full_params) do
      {:ok, _session} ->
        send(self(), socket.assigns.on_save)
        {:noreply, build_form(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold mb-5">Log session</h2>

      <.form
        for={@form}
        id={"log-form-#{@id}"}
        phx-submit="save"
        phx-target={@myself}
        class="space-y-4"
      >
        <.input
          field={@form[:burpee_type]}
          type="select"
          label="Burpee type"
          options={[{"6-Count", "six_count"}, {"Navy SEAL", "navy_seal"}]}
        />
        <.input
          field={@form[:burpee_count_actual]}
          type="number"
          label="Burpees done"
          min="0"
        />
        <.input
          field={@form[:duration_sec_actual]}
          type="number"
          label="Duration (seconds)"
          min="0"
        />

        <div>
          <p class="text-sm font-medium mb-2">How did it feel?</p>
          <div class="flex gap-2">
            <%= for {icon, label, val} <- @mood_options do %>
              <button
                type="button"
                phx-click="set_mood"
                phx-value-mood={val}
                phx-target={@myself}
                class={[
                  "flex-1 flex flex-col items-center gap-1 rounded-lg border py-2.5 text-xs transition",
                  @mood == val && "border-primary text-primary bg-primary/10",
                  @mood != val && "border-[#1E2535] text-base-content/40 hover:text-base-content/70"
                ]}
              >
                <.icon name={icon} class="size-5" />
                {label}
              </button>
            <% end %>
          </div>
        </div>

        <div>
          <p class="text-sm font-medium mb-2">Tags</p>
          <div class="flex flex-wrap gap-2">
            <%= for tag <- @tag_options do %>
              <button
                type="button"
                phx-click="toggle_tag"
                phx-value-tag={tag}
                phx-target={@myself}
                class={[
                  "rounded-full px-3 py-1 text-xs border transition",
                  tag in @log_tags && "border-primary text-primary bg-primary/10",
                  tag not in @log_tags &&
                    "border-[#1E2535] text-base-content/40 hover:text-base-content/70"
                ]}
              >
                {String.replace(tag, "_", " ")}
              </button>
            <% end %>
          </div>
        </div>

        <button
          type="submit"
          class="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-content hover:bg-primary/90 transition"
        >
          Save session
        </button>
      </.form>
    </div>
    """
  end
end
