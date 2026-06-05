defmodule BurpeeTrainerWeb.GoalFormComponent do
  use BurpeeTrainerWeb, :live_component

  alias BurpeeTrainer.Goals

  @impl true
  def mount(socket) do
    {:ok, assign(socket, form: nil)}
  end

  @impl true
  def update(%{baseline_session: nil, burpee_type: burpee_type} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, nil)
     |> assign(:type_label, type_label(burpee_type))
     |> assign(:ceiling, ceiling(burpee_type))}
  end

  def update(%{baseline_session: _session, burpee_type: burpee_type} = assigns, socket) do
    changeset = Goals.change_goal(%Goals.Goal{})
    ceiling = ceiling(burpee_type)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:type_label, type_label(burpee_type))
     |> assign(:ceiling, ceiling)}
  end

  @impl true
  def handle_event("save", %{"goal" => params}, socket) do
    user = socket.assigns.current_user
    session = socket.assigns.baseline_session
    burpee_type = socket.assigns.burpee_type
    today = Date.utc_today()

    raw_count = String.trim(params["burpee_count_target"] || "")

    case Integer.parse(raw_count) do
      {burpee_count_target, ""} when burpee_count_target > 0 ->
        duration_sec_target =
          round(burpee_count_target * session.duration_sec_actual / session.burpee_count_actual)

        full_attrs = %{
          "burpee_type" => to_string(burpee_type),
          "burpee_count_target" => burpee_count_target,
          "duration_sec_target" => duration_sec_target,
          "date_target" => params["date_target"],
          "burpee_count_baseline" => session.burpee_count_actual,
          "duration_sec_baseline" => session.duration_sec_actual,
          "date_baseline" => Date.to_iso8601(today)
        }

        case Goals.create_goal(user, full_attrs) do
          {:ok, _goal} ->
            send(self(), socket.assigns.on_save)
            {:noreply, socket}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :validate)))}
        end

      _ ->
        changeset =
          %Goals.Goal{}
          |> Goals.change_goal(%{"burpee_count_target" => raw_count})
          |> Ecto.Changeset.add_error(
            :burpee_count_target,
            "must be a whole number greater than 0"
          )
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp type_label(:six_count), do: "6-Count"
  defp type_label(:navy_seal), do: "Navy SEAL"

  defp ceiling(:six_count), do: 325
  defp ceiling(:navy_seal), do: 150

  @impl true
  def render(assigns) do
    ~H"""
    <div class="session-surface text-[var(--session-ink)]">
      <div class="mb-5 flex items-center justify-between border-b border-[var(--session-border)] pb-3">
        <h2 class="text-lg font-semibold">Set {@type_label} goal</h2>
        <button
          type="button"
          phx-click="close_goal_modal"
          class="text-[var(--session-muted)] hover:text-[var(--session-ink)] transition"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <%= if @baseline_session == nil do %>
        <p class="text-sm text-[var(--session-muted)]">
          Log at least one {@type_label} session of 20+ minutes before setting a goal.
        </p>
      <% else %>
        <.form
          for={@form}
          id={"goal-form-#{@id}"}
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <label class="block space-y-1">
            <span class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
              Target burpees (max {@ceiling})
            </span>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name={@form[:burpee_count_target].name}
              value={@form[:burpee_count_target].value}
              class="w-full border border-[var(--session-border)] rounded-2xl bg-[var(--session-surface)] px-3 py-3 text-lg font-semibold tabular-nums text-[var(--session-ink)] focus:border-[var(--session-ink)] focus:outline-none"
            />
          </label>
          <label class="block space-y-1">
            <span class="text-[10px] uppercase tracking-widest text-[var(--session-muted)]">
              Target date
            </span>
            <input
              type="date"
              name={@form[:date_target].name}
              value={@form[:date_target].value}
              min={Date.to_iso8601(Date.add(Date.utc_today(), 1))}
              class="w-full border border-[var(--session-border)] rounded-2xl bg-[var(--session-surface)] px-3 py-3 text-sm tabular-nums text-[var(--session-ink)] focus:border-[var(--session-ink)] focus:outline-none"
            />
          </label>
          <p class="text-xs text-[var(--session-muted)]">
            Baseline: {@baseline_session.burpee_count_actual} burpees from your last session.
          </p>
          <button
            type="submit"
            class="w-full bg-[var(--session-ink)] py-3 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90"
          >
            Save goal
          </button>
        </.form>
      <% end %>
    </div>
    """
  end
end
