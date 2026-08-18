defmodule BurpeeTrainerWeb.LogFormComponent do
  use BurpeeTrainerWeb, :live_component

  alias BurpeeTrainer.{BurpeeType, UserTime, Workouts}
  alias BurpeeTrainer.Workouts.{SessionLog, WorkoutSession}

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
    socket = assign(socket, assigns)

    socket =
      if assigns[:current_user] && !socket.assigns.user_date_initialized? do
        today = local_today(socket.assigns.current_user)

        assign(socket,
          log_date: Date.to_iso8601(today),
          max_log_date: Date.to_iso8601(today),
          user_date_initialized?: true
        )
      else
        socket
      end

    {:ok, socket}
  end

  defp build_form(socket) do
    today =
      case socket.assigns[:current_user] do
        nil -> Date.utc_today()
        user -> local_today(user)
      end

    changeset = Workouts.change_free_form_session(%WorkoutSession{})

    assign(socket,
      form: to_form(changeset),
      mood: 0,
      log_tags: [],
      burpee_type: :six_count,
      log_date: Date.to_iso8601(today),
      max_log_date: Date.to_iso8601(today),
      log_date_error: nil,
      user_date_initialized?: socket.assigns[:current_user] != nil,
      mood_options: @mood_options,
      tag_options: @tag_options
    )
  end

  defp local_today(user) do
    case UserTime.context(user, DateTime.utc_now(:second)) do
      {:ok, context} -> context.date
      {:error, :invalid_timezone} -> Date.utc_today()
    end
  end

  @impl true
  def handle_event("set_type", %{"type" => type_str}, socket) when is_binary(type_str) do
    burpee_type =
      case BurpeeType.parse(type_str) do
        {:ok, burpee_type} -> burpee_type
        {:error, _reason} -> socket.assigns.burpee_type
      end

    {:noreply, assign(socket, :burpee_type, burpee_type)}
  end

  def handle_event("set_type", _params, socket), do: {:noreply, socket}

  def handle_event("set_mood", %{"mood" => mood_str}, socket) when is_binary(mood_str) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> socket.assigns.mood
      end

    {:noreply, assign(socket, :mood, mood)}
  end

  def handle_event("set_mood", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_tag", %{"tag" => tag}, socket)
      when is_binary(tag) and tag in @tag_options do
    tags = socket.assigns.log_tags
    new_tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :log_tags, new_tags)}
  end

  def handle_event("toggle_tag", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"workout_session" => params}, socket) when is_map(params) do
    {:noreply, assign_log_form(socket, params)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"workout_session" => params}, socket) when is_map(params) do
    user = socket.assigns.current_user

    case normalized_attrs(socket, params) do
      {:ok, full_params} ->
        case Workouts.create_free_form_session(user, full_params) do
          {:ok, session} ->
            events = Workouts.session_milestones(user, session)
            send(self(), {socket.assigns.on_save, events})
            {:noreply, build_form(socket)}

          {:error, changeset} ->
            {:noreply,
             assign(socket,
               form: to_form(changeset),
               log_date: log_date_value(params),
               log_date_error: nil
             )}
        end

      {:error, reason} ->
        {:noreply, assign_log_form(socket, params, reason)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp assign_log_form(socket, params) do
    case normalized_attrs(socket, params) do
      {:ok, attrs} -> assign_log_form(socket, params, attrs, nil)
      {:error, reason} -> assign_log_form(socket, params, reason)
    end
  end

  defp assign_log_form(socket, params, reason) when is_atom(reason) do
    changeset =
      Workouts.change_free_form_session(
        %WorkoutSession{},
        SessionLog.normalize_form_params(params)
      )

    assign_log_form(socket, params, changeset, log_date_error(reason))
  end

  defp assign_log_form(socket, params, attrs, nil) when is_map(attrs) do
    changeset = Workouts.change_free_form_session(%WorkoutSession{}, attrs)
    assign_log_form(socket, params, changeset, nil)
  end

  defp assign_log_form(socket, params, changeset, date_error) do
    changeset = Map.put(changeset, :action, :validate)

    assign(socket,
      form: to_form(changeset),
      log_date: log_date_value(params),
      log_date_error: date_error
    )
  end

  defp log_date_value(params) do
    case params["log_date"] do
      value when is_binary(value) -> value
      _forged_or_missing -> ""
    end
  end

  defp normalized_attrs(socket, params) do
    SessionLog.to_attrs(
      params,
      socket.assigns.burpee_type,
      socket.assigns.mood,
      socket.assigns.log_tags,
      socket.assigns.current_user,
      DateTime.utc_now(:second)
    )
  end

  defp log_date_error(:future_log_date), do: "Date cannot be in the future."
  defp log_date_error(:invalid_timezone), do: "Date could not be resolved for your timezone."
  defp log_date_error(:invalid_log_date), do: "Enter a valid date."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="session-surface space-y-4 text-[var(--session-ink)]">
      <%!-- Header --%>
      <.qs_surface class="flex items-start justify-between gap-4 px-5 py-4">
        <div class="space-y-1">
          <h2 class="text-xl font-semibold tracking-[-0.04em] text-[var(--session-ink)]">
            Log past session
          </h2>
          <p class="text-sm leading-6 text-[var(--session-muted)]">
            Add work you already completed so your week and level stay accurate.
          </p>
        </div>
        <button
          type="button"
          phx-click="close_log_modal"
          class="inline-flex size-9 shrink-0 items-center justify-center rounded-lg border border-[var(--session-border)] bg-[var(--session-bg)]/70 text-[var(--session-muted)] transition-colors hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          aria-label="Close log session"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </.qs_surface>

      <%!-- Type --%>
      <div class="grid grid-cols-2 overflow-hidden rounded-xl divide-x divide-[var(--session-border)] border border-[var(--session-border)] bg-[var(--session-surface)]/55">
        <%= for {label, val} <- [{"6-Count", :six_count}, {"Navy SEAL", :navy_seal}] do %>
          <button
            type="button"
            phx-click="set_type"
            phx-value-type={val}
            phx-target={@myself}
            class={[
              "py-4 text-sm font-semibold transition-colors",
              @burpee_type == val &&
                "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
              @burpee_type != val &&
                "text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
            ]}
          >
            {label}
          </button>
        <% end %>
      </div>

      <%!-- Reps + Duration + Date --%>
      <.form
        for={@form}
        id={"log-form-#{@id}"}
        phx-submit="save"
        phx-change="validate"
        phx-target={@myself}
      >
        <div class="grid grid-cols-2 overflow-hidden rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/55 sm:grid-cols-3">
          <div class="space-y-2 border-r border-[var(--session-border)] p-5">
            <p class="text-sm font-medium text-[var(--session-muted)]">Reps</p>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name="workout_session[burpee_count_actual]"
              value={@form[:burpee_count_actual].value}
              class="w-full bg-transparent text-5xl font-semibold leading-none tabular-nums text-[var(--session-ink)] placeholder:text-[var(--session-muted)] focus:outline-none"
              placeholder="—"
            />
          </div>
          <div class="space-y-2 border-r-0 border-[var(--session-border)] p-5 sm:border-r">
            <p class="text-sm font-medium text-[var(--session-muted)]">Minutes</p>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name="workout_session[duration_sec_actual]"
              value={@form[:duration_sec_actual].value}
              class="w-full bg-transparent text-5xl font-semibold leading-none tabular-nums text-[var(--session-ink)] placeholder:text-[var(--session-muted)] focus:outline-none"
              placeholder="—"
            />
          </div>
          <div class="col-span-2 space-y-2 border-t border-[var(--session-border)] p-5 sm:col-span-1 sm:border-t-0">
            <p class="text-sm font-medium text-[var(--session-muted)]">Date</p>
            <input
              type="date"
              name="workout_session[log_date]"
              value={@log_date}
              max={@max_log_date}
              class="w-full bg-transparent text-base tabular-nums text-[var(--session-ink)] focus:outline-none"
            />
            <p
              :if={@log_date_error}
              id="log-date-error"
              class="text-xs font-medium text-red-600"
              role="alert"
            >
              {@log_date_error}
            </p>
          </div>
        </div>

        <%!-- Mood --%>
        <div class="mt-4 grid grid-cols-3 overflow-hidden rounded-xl divide-x divide-[var(--session-border)] border border-[var(--session-border)] bg-[var(--session-surface)]/55">
          <%= for {icon, label, val} <- @mood_options do %>
            <button
              type="button"
              phx-click="set_mood"
              phx-value-mood={val}
              phx-target={@myself}
              class={[
                "flex flex-col items-center gap-2 py-4 text-xs font-medium transition-colors",
                @mood == val && "bg-[var(--session-ink)] text-[var(--session-bg)]",
                @mood != val &&
                  "text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
              ]}
            >
              <.icon name={icon} class="size-5" />
              {label}
            </button>
          <% end %>
        </div>

        <%!-- Tags --%>
        <div class="mt-4 flex flex-wrap gap-2 rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/55 px-4 py-3">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              phx-target={@myself}
              class={[
                "rounded-md border px-3 py-1.5 text-xs font-medium transition-colors",
                tag in @log_tags &&
                  "border-[var(--session-tag-border)] bg-[var(--session-tag-bg)] text-[var(--session-tag-ink)]",
                tag not in @log_tags &&
                  "border-[var(--session-border)] bg-[var(--session-bg)]/45 text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <%!-- Form footer --%>
        <div class="mt-4 flex justify-end border-t border-[var(--session-border)] pt-4">
          <button
            type="submit"
            class="rounded-md bg-[var(--session-ink)] px-4 py-2 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90"
          >
            Save session
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
