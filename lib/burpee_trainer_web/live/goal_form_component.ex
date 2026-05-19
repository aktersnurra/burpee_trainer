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
     |> assign(:type_label, type_label(burpee_type))}
  end

  def update(%{baseline_session: _session, burpee_type: burpee_type} = assigns, socket) do
    changeset = Goals.change_goal(%Goals.Goal{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:type_label, type_label(burpee_type))}
  end

  @impl true
  def handle_event("save", %{"goal" => params}, socket) do
    user = socket.assigns.current_user
    session = socket.assigns.baseline_session
    burpee_type = socket.assigns.burpee_type
    today = Date.utc_today()

    burpee_count_target = String.to_integer(params["burpee_count_target"] || "0")

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
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp type_label(:six_count), do: "6-Count"
  defp type_label(:navy_seal), do: "Navy SEAL"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold mb-5">Set {@type_label} goal</h2>

      <%= if @baseline_session == nil do %>
        <p class="text-sm text-base-content/50">
          Log at least one {@type_label} session before setting a goal.
        </p>
      <% else %>
        <.form
          for={@form}
          id={"goal-form-#{@id}"}
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            field={@form[:burpee_count_target]}
            type="number"
            label="Target burpees"
            min={@baseline_session.burpee_count_actual + 1}
          />
          <.input
            field={@form[:date_target]}
            type="date"
            label="Target date"
            min={Date.to_iso8601(Date.add(Date.utc_today(), 1))}
          />
          <p class="text-xs text-base-content/40">
            Baseline: {@baseline_session.burpee_count_actual} burpees from your last session.
          </p>
          <button
            type="submit"
            class="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-content hover:bg-primary/90 transition"
          >
            Save goal
          </button>
        </.form>
      <% end %>
    </div>
    """
  end
end
