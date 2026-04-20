defmodule BurpeeTrainerWeb.GoalsLive do
  @moduledoc """
  Goals dashboard. Per burpee_type shows either the active goal card
  with a `Progression.recommend/2` panel, or a "Set a goal" prompt. A
  collapsible history of achieved/abandoned goals lives below.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Progression, Workouts}
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainerWeb.Fmt

  @burpee_types [:six_count, :navy_seal]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form_type, nil)
     |> assign(:form, nil)
     |> load_data()}
  end

  defp load_data(socket) do
    user = socket.assigns.current_user
    sessions = Workouts.list_sessions(user)
    active_by_type = Goals.list_active_goals(user) |> Map.new(&{&1.burpee_type, &1})

    cards =
      for type <- @burpee_types do
        goal = Map.get(active_by_type, type)
        {type, goal, goal && Progression.recommend(goal, sessions)}
      end

    past_goals =
      Goals.list_goals(user)
      |> Enum.reject(&(&1.status == :active))

    socket
    |> assign(:sessions, sessions)
    |> assign(:cards, cards)
    |> assign(:past_goals, past_goals)
  end

  @impl true
  def handle_event("start_goal", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)
    today = Date.utc_today()

    baseline = baseline_from_sessions(type_atom, socket.assigns.sessions)

    attrs = %{
      "burpee_type" => type,
      "burpee_count_baseline" => baseline.burpee_count,
      "duration_sec_baseline" => baseline.duration_sec,
      "date_baseline" => Date.to_iso8601(today),
      "date_target" => Date.to_iso8601(Date.add(today, 28))
    }

    changeset = Goals.change_goal(%Goal{}, attrs)

    {:noreply,
     socket
     |> assign(:form_type, type_atom)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("cancel_goal", _, socket) do
    {:noreply, assign(socket, form_type: nil, form: nil)}
  end

  def handle_event("validate", %{"goal" => params}, socket) do
    changeset =
      %Goal{}
      |> Goals.change_goal(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"goal" => params}, socket) do
    case Goals.create_goal(socket.assigns.current_user, params) do
      {:ok, _goal} ->
        {:noreply,
         socket
         |> put_flash(:info, "Goal created.")
         |> assign(form_type: nil, form: nil)
         |> load_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("abandon", %{"id" => id}, socket) do
    goal = Goals.get_goal!(socket.assigns.current_user, String.to_integer(id))
    {:ok, _} = Goals.abandon_goal(goal)

    {:noreply,
     socket
     |> put_flash(:info, "Goal abandoned.")
     |> load_data()}
  end

  def handle_event("mark_achieved", %{"id" => id}, socket) do
    goal = Goals.get_goal!(socket.assigns.current_user, String.to_integer(id))
    {:ok, _} = Goals.mark_achieved(goal)

    {:noreply,
     socket
     |> put_flash(:info, "Goal marked achieved.")
     |> load_data()}
  end

  defp baseline_from_sessions(type, sessions) do
    sessions
    |> Enum.filter(&(&1.burpee_type == type))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> case do
      [most_recent | _] ->
        %{
          burpee_count: most_recent.burpee_count_actual,
          duration_sec: most_recent.duration_sec_actual
        }

      [] ->
        %{burpee_count: 0, duration_sec: 0}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Goals</h1>
          <p class="text-sm text-base-content/60">
            Targets by burpee type, with next-session recommendations.
          </p>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <%= for {type, goal, rec} <- @cards do %>
            <.goal_card
              type={type}
              goal={goal}
              rec={rec}
              form={@form}
              form_type={@form_type}
            />
          <% end %>
        </div>

        <%= if @past_goals != [] do %>
          <section class="space-y-3">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Past goals
            </h2>
            <ul class="divide-y divide-base-200 rounded-lg border border-base-300 bg-base-100">
              <%= for goal <- @past_goals do %>
                <li class="px-4 py-3 flex items-center justify-between gap-4 text-sm">
                  <div>
                    <div class="font-medium">
                      {Fmt.burpee_type(goal.burpee_type)} · {goal.burpee_count_target} burpees
                      in {Fmt.duration_sec(goal.duration_sec_target)}
                    </div>
                    <div class="text-xs text-base-content/60">
                      Target {Calendar.strftime(goal.date_target, "%Y-%m-%d")}
                    </div>
                  </div>
                  <span class={[
                    "inline-flex items-center rounded-full px-2 py-0.5 text-xs",
                    goal.status == :achieved && "bg-success/10 text-success",
                    goal.status == :abandoned && "bg-base-200 text-base-content/60"
                  ]}>
                    {String.capitalize(Atom.to_string(goal.status))}
                  </span>
                </li>
              <% end %>
            </ul>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -- goal card --

  attr :type, :atom, required: true
  attr :goal, :any, required: true
  attr :rec, :any, required: true
  attr :form, :any, default: nil
  attr :form_type, :any, default: nil

  defp goal_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold tracking-tight">{Fmt.burpee_type(@type)}</h2>
        <%= if @goal do %>
          <button
            type="button"
            phx-click="abandon"
            phx-value-id={@goal.id}
            data-confirm="Abandon this goal?"
            class="text-xs text-base-content/60 hover:text-error"
          >
            Abandon
          </button>
        <% end %>
      </div>

      <%= cond do %>
        <% @form_type == @type -> %>
          <.new_goal_form type={@type} form={@form} />
        <% @goal -> %>
          <.active_goal type={@type} goal={@goal} rec={@rec} />
        <% true -> %>
          <.goal_empty type={@type} />
      <% end %>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp goal_empty(assigns) do
    ~H"""
    <div class="rounded-md bg-base-200/40 p-6 text-center space-y-3">
      <p class="text-sm text-base-content/60">No active goal for {Fmt.burpee_type(@type)}.</p>
      <button
        type="button"
        phx-click="start_goal"
        phx-value-type={Atom.to_string(@type)}
        class="inline-flex rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
      >
        Set a goal
      </button>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :goal, :any, required: true
  attr :rec, :any, required: true

  defp active_goal(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="text-sm text-base-content/80">
        <span class="font-semibold text-base-content">
          {@goal.burpee_count_target} {Fmt.burpee_type(@type)}s
        </span>
        in <span class="font-semibold">{Fmt.duration_sec(@goal.duration_sec_target)}</span>
        by <span class="font-semibold">{Calendar.strftime(@goal.date_target, "%b %-d, %Y")}</span>.
      </div>

      <.progress_bar goal={@goal} rec={@rec} />

      <div class="flex flex-wrap gap-2 text-xs">
        <span class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5">
          {phase_label(@rec.phase)}
        </span>
        <span class={[
          "inline-flex items-center rounded-full px-2 py-0.5",
          trend_class(@rec.trend_status)
        ]}>
          {trend_label(@rec.trend_status)}
        </span>
        <span class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5">
          {@rec.weeks_remaining} weeks remaining
        </span>
      </div>

      <div class="rounded-md border border-base-200 bg-base-200/40 p-4 space-y-2">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Next session
        </h3>
        <p class="text-sm">{@rec.rationale}</p>
        <dl class="grid grid-cols-3 gap-3 pt-1">
          <div>
            <dt class="text-xs text-base-content/60">Burpees</dt>
            <dd class="font-semibold">{@rec.burpee_count_suggested}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/60">Duration</dt>
            <dd class="font-semibold">{Fmt.duration_sec(@rec.duration_sec_suggested)}</dd>
          </div>
          <div>
            <dt class="text-xs text-base-content/60">Sec / rep</dt>
            <dd class="font-semibold">
              {:erlang.float_to_binary(@rec.sec_per_rep_suggested, decimals: 2)}
            </dd>
          </div>
        </dl>
        <div class="flex gap-2 pt-2">
          <.link
            navigate={~p"/plans/new"}
            class="flex-1 text-center rounded-md border border-base-300 bg-base-100 px-3 py-1.5 text-sm hover:bg-base-200 transition"
          >
            Build plan
          </.link>
          <.link
            navigate={~p"/log"}
            class="flex-1 text-center rounded-md border border-base-300 bg-base-100 px-3 py-1.5 text-sm hover:bg-base-200 transition"
          >
            Log session
          </.link>
        </div>
      </div>

      <div class="pt-2">
        <button
          type="button"
          phx-click="mark_achieved"
          phx-value-id={@goal.id}
          data-confirm="Mark this goal as achieved?"
          class="text-xs text-success hover:underline"
        >
          Mark achieved
        </button>
      </div>
    </div>
    """
  end

  attr :goal, :any, required: true
  attr :rec, :any, required: true

  defp progress_bar(assigns) do
    assigns = assign(assigns, :positions, progress_positions(assigns.goal, assigns.rec))

    ~H"""
    <div class="space-y-2">
      <div class="h-2 rounded-full bg-base-200 relative overflow-hidden">
        <div
          class="absolute top-0 left-0 h-full bg-primary/30"
          style={"width: #{@positions.today_pct}%"}
        />
        <div
          class="absolute top-0 h-full w-1 bg-primary"
          style={"left: #{@positions.today_pct}%"}
        />
      </div>
      <div class="flex justify-between text-xs text-base-content/60">
        <span>Baseline: {@goal.burpee_count_baseline}</span>
        <%= if @positions.today do %>
          <span>Projected today: {@positions.today}</span>
        <% end %>
        <span>Target: {@goal.burpee_count_target}</span>
      </div>
    </div>
    """
  end

  defp progress_positions(goal, rec) do
    today = rec.burpee_count_projected_at_goal || rec.burpee_count_suggested
    baseline = goal.burpee_count_baseline
    target = goal.burpee_count_target
    span = max(target - baseline, 1)
    today_pct = ((today - baseline) / span * 100) |> clamp_pct()

    %{today: today, today_pct: today_pct}
  end

  defp clamp_pct(x) when x < 0, do: 0.0
  defp clamp_pct(x) when x > 100, do: 100.0
  defp clamp_pct(x), do: x

  # -- new-goal form --

  attr :type, :atom, required: true
  attr :form, :any, required: true

  defp new_goal_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"goal-form-#{@type}"}
      phx-change="validate"
      phx-submit="save"
      class="space-y-4"
    >
      <input type="hidden" name="goal[burpee_type]" value={Atom.to_string(@type)} />

      <div class="grid gap-3 sm:grid-cols-2">
        <.input
          field={@form[:burpee_count_target]}
          type="number"
          label="Target burpees"
          min="1"
        />
        <.input
          field={@form[:duration_sec_target]}
          type="number"
          label="Target duration (sec)"
          min="1"
        />
        <.input field={@form[:date_target]} type="date" label="Target date" />
        <.input field={@form[:date_baseline]} type="date" label="Baseline date" />
        <.input
          field={@form[:burpee_count_baseline]}
          type="number"
          label="Baseline burpees"
          min="0"
        />
        <.input
          field={@form[:duration_sec_baseline]}
          type="number"
          label="Baseline duration (sec)"
          min="0"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button
          type="button"
          phx-click="cancel_goal"
          class="rounded-md border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200 transition"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          Save goal
        </button>
      </div>
    </.form>
    """
  end

  # -- labels --

  defp phase_label(:build_1), do: "Build W1"
  defp phase_label(:build_2), do: "Build W2"
  defp phase_label(:build_3), do: "Build W3"
  defp phase_label(:deload), do: "Deload"

  defp trend_label(:on_track), do: "On track"
  defp trend_label(:ahead), do: "Ahead"
  defp trend_label(:behind), do: "Behind"
  defp trend_label(:low_consistency), do: "Low consistency"

  defp trend_class(:on_track), do: "bg-success/10 text-success"
  defp trend_class(:ahead), do: "bg-success/10 text-success"
  defp trend_class(:behind), do: "bg-warning/10 text-warning"
  defp trend_class(:low_consistency), do: "bg-base-200 text-base-content/60"
end
