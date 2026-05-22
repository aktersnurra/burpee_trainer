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
    {:ok, assign(socket, assigns)}
  end

  defp build_form(socket) do
    today = Date.utc_today()
    changeset = Workouts.change_free_form_session(%WorkoutSession{})

    assign(socket,
      form: to_form(changeset),
      mood: 0,
      log_tags: [],
      burpee_type: :six_count,
      log_date: today,
      mood_options: @mood_options,
      tag_options: @tag_options
    )
  end

  @impl true
  def handle_event("set_type", %{"type" => type_str}, socket) do
    burpee_type = String.to_existing_atom(type_str)
    {:noreply, assign(socket, :burpee_type, burpee_type)}
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
    log_date =
      case Date.from_iso8601(params["log_date"] || "") do
        {:ok, d} -> d
        _ -> socket.assigns.log_date
      end

    changeset =
      %WorkoutSession{}
      |> Workouts.change_free_form_session(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(:form, to_form(changeset)) |> assign(:log_date, log_date)}
  end

  def handle_event("save", %{"workout_session" => params}, socket) do
    user = socket.assigns.current_user
    tags_str = socket.assigns.log_tags |> Enum.sort() |> Enum.join(",")

    duration_sec =
      case Integer.parse(params["duration_sec_actual"] || "") do
        {min, ""} -> to_string(min * 60)
        _ -> params["duration_sec_actual"]
      end

    log_date =
      case Date.from_iso8601(params["log_date"] || "") do
        {:ok, d} -> d
        _ -> socket.assigns.log_date
      end

    full_params =
      params
      |> Map.put("burpee_type", to_string(socket.assigns.burpee_type))
      |> Map.put("mood", to_string(socket.assigns.mood))
      |> Map.put("tags", tags_str)
      |> Map.put("duration_sec_actual", duration_sec)
      |> Map.put("inserted_at", DateTime.new!(log_date, ~T[12:00:00], "Etc/UTC"))

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
      <div class="flex items-center justify-between mb-5">
        <h2 class="text-lg font-semibold">Log session</h2>
        <button
          type="button"
          phx-click="close_log_modal"
          class="text-base-content/40 hover:text-base-content/70 transition"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <%!-- Burpee type pills (outside form — socket assign) --%>
      <div class="mb-4">
        <p class="text-sm font-medium mb-2">Type</p>
        <div class="flex gap-2">
          <%= for {label, val} <- [{"6-Count", :six_count}, {"Navy SEAL", :navy_seal}] do %>
            <button
              type="button"
              phx-click="set_type"
              phx-value-type={val}
              phx-target={@myself}
              class={[
                "flex-1 rounded-full px-4 py-2 text-sm font-medium border transition",
                @burpee_type == val && "border-primary bg-primary/10 text-primary",
                @burpee_type != val &&
                  "border-[#222840] text-base-content/50 hover:text-base-content/80"
              ]}
            >
              {label}
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Date — inside form so validate captures it without resetting --%>

      <.form
        for={@form}
        id={"log-form-#{@id}"}
        phx-submit="save"
        phx-change="validate"
        phx-target={@myself}
        class="space-y-4"
      >
        <.input
          field={@form[:burpee_count_actual]}
          type="text"
          inputmode="numeric"
          pattern="[0-9]*"
          label="Burpees done"
        />
        <.input
          field={@form[:duration_sec_actual]}
          type="text"
          inputmode="numeric"
          pattern="[0-9]*"
          label="Duration (minutes)"
        />

        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Date</span>
            <input
              type="date"
              name="workout_session[log_date]"
              value={Date.to_iso8601(@log_date)}
              max={Date.to_iso8601(Date.utc_today())}
              class="w-full input"
            />
          </label>
        </div>

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
                  @mood != val && "border-[#222840] text-base-content/40 hover:text-base-content/70"
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
                    "border-[#222840] text-base-content/40 hover:text-base-content/70"
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
