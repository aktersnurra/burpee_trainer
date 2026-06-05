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
      {:ok, session} ->
        events = Workouts.session_milestones(user, session)
        send(self(), {socket.assigns.on_save, events})
        {:noreply, build_form(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="session-surface space-y-3 text-[var(--session-ink)]">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-[var(--session-border)] pb-3">
        <h2 class="text-sm font-semibold text-[var(--session-muted)] uppercase tracking-widest">
          Log session
        </h2>
        <button
          type="button"
          phx-click="close_log_modal"
          class="text-[var(--session-muted)] hover:text-[var(--session-ink)] transition"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <%!-- Card 1: Type --%>
      <div class="flex border border-[var(--session-border)] bg-[var(--session-bg)]">
        <%= for {label, val} <- [{"6-Count", :six_count}, {"Navy SEAL", :navy_seal}] do %>
          <button
            type="button"
            phx-click="set_type"
            phx-value-type={val}
            phx-target={@myself}
            class={[
              "flex-1 py-3 text-sm font-medium tracking-wide transition",
              @burpee_type == val && "bg-[var(--session-ink)] text-[var(--session-bg)]",
              @burpee_type != val &&
                "text-[var(--session-muted)] hover:bg-[var(--session-track)] hover:text-[var(--session-ink)]"
            ]}
          >
            {label}
          </button>
          <%= if val == :six_count do %>
            <div class="w-px bg-[var(--session-border)]" />
          <% end %>
        <% end %>
      </div>

      <%!-- Card 2: Reps + Duration + Date --%>
      <.form
        for={@form}
        id={"log-form-#{@id}"}
        phx-submit="save"
        phx-change="validate"
        phx-target={@myself}
      >
        <div class="grid grid-cols-3 border border-[var(--session-border)] bg-[var(--session-bg)]">
          <div class="p-5 space-y-1 border-r border-[var(--session-border)]">
            <p class="text-[10px] text-[var(--session-muted)] uppercase tracking-widest">Reps</p>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name="workout_session[burpee_count_actual]"
              value={@form[:burpee_count_actual].value}
              class="w-full bg-transparent text-4xl font-bold tabular-nums text-[var(--session-ink)] focus:outline-none leading-none placeholder:text-[var(--session-muted)]"
              placeholder="—"
            />
          </div>
          <div class="p-5 space-y-1 border-r border-[var(--session-border)]">
            <p class="text-[10px] text-[var(--session-muted)] uppercase tracking-widest">Min</p>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name="workout_session[duration_sec_actual]"
              value={@form[:duration_sec_actual].value}
              class="w-full bg-transparent text-4xl font-bold tabular-nums text-[var(--session-ink)] focus:outline-none leading-none placeholder:text-[var(--session-muted)]"
              placeholder="—"
            />
          </div>
          <div class="p-5 space-y-1">
            <p class="text-[10px] text-[var(--session-muted)] uppercase tracking-widest">Date</p>
            <input
              type="date"
              name="workout_session[log_date]"
              value={Date.to_iso8601(@log_date)}
              max={Date.to_iso8601(Date.utc_today())}
              class="w-full bg-transparent text-sm tabular-nums text-[var(--session-ink)] focus:outline-none leading-none"
            />
          </div>
        </div>

        <%!-- Card 3: Mood --%>
        <div class="mt-3 flex border border-[var(--session-border)] bg-[var(--session-bg)]">
          <%= for {icon, label, val} <- @mood_options do %>
            <button
              type="button"
              phx-click="set_mood"
              phx-value-mood={val}
              phx-target={@myself}
              class={[
                "flex-1 flex flex-col items-center gap-1.5 py-4 text-[10px] uppercase tracking-widest transition",
                @mood == val && "bg-[var(--session-ink)] text-[var(--session-bg)]",
                @mood != val &&
                  "text-[var(--session-muted)] hover:bg-[var(--session-track)] hover:text-[var(--session-ink)]"
              ]}
            >
              <.icon name={icon} class="size-5" />
              {label}
            </button>
            <%= if val != 1 do %>
              <div class="w-px bg-[var(--session-border)] self-stretch" />
            <% end %>
          <% end %>
        </div>

        <%!-- Card 4: Tags --%>
        <div class="mt-3 flex flex-wrap gap-2 border border-[var(--session-border)] bg-[var(--session-bg)] px-4 py-3">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              phx-target={@myself}
              class={[
                "border px-3 py-1 text-xs transition",
                tag in @log_tags &&
                  "border-[var(--session-ink)] bg-[var(--session-ink)] text-[var(--session-bg)]",
                tag not in @log_tags &&
                  "border-[var(--session-border)] text-[var(--session-muted)] hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <%!-- Save --%>
        <button
          type="submit"
          class="mt-3 flex w-full items-center justify-center gap-2 bg-[var(--session-ink)] py-4 text-sm font-semibold tracking-wide text-[var(--session-bg)] transition hover:opacity-90"
        >
          Save session <.icon name="hero-arrow-right" class="size-4" />
        </button>
      </.form>
    </div>
    """
  end
end
