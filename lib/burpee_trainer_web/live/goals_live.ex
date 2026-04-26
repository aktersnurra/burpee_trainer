defmodule BurpeeTrainerWeb.GoalsLive do
  @moduledoc """
  Goals dashboard. Per burpee_type shows either the active goal card
  with a `Progression.recommend/2` panel, or a "Set a goal" prompt. A
  collapsible history of achieved/abandoned goals lives below.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Levels, Progression, StyleRecommender, Workouts}
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.StyleRecommender.StyleSuggestion
  alias BurpeeTrainerWeb.Fmt

  @burpee_types [:six_count, :navy_seal]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form_type, nil)
     |> assign(:form, nil)
     |> assign(:goal_tab, :level)
     |> assign(:rec_status, :idle)
     |> assign(:rec_type, nil)
     |> assign(:rec_suggestions, [])
     |> load_data()}
  end

  defp load_data(socket) do
    user = socket.assigns.current_user
    sessions = Workouts.list_sessions(user)
    performances = Workouts.list_style_performances(user)
    active_by_type = Goals.list_active_goals(user) |> Map.new(&{&1.burpee_type, &1})

    cards =
      for type <- @burpee_types do
        goal = Map.get(active_by_type, type)
        {type, goal, goal && Progression.recommend(goal, sessions)}
      end

    past_goals =
      Goals.list_goals(user)
      |> Enum.reject(&(&1.status == :active))

    level_six = Levels.level_for_type(sessions, :six_count)
    level_navy = Levels.level_for_type(sessions, :navy_seal)
    overall_level = Levels.current_level(sessions)

    socket
    |> assign(:sessions, sessions)
    |> assign(:performances, performances)
    |> assign(:cards, cards)
    |> assign(:past_goals, past_goals)
    |> assign(:overall_level, overall_level)
    |> assign(:level_six, level_six)
    |> assign(:level_navy, level_navy)
    |> assign(:next_six, Levels.next_landmark(sessions, :six_count))
    |> assign(:next_navy, Levels.next_landmark(sessions, :navy_seal))
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
     |> assign(:goal_tab, :level)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("switch_goal_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :goal_tab, String.to_existing_atom(tab))}
  end

  def handle_event("start_level_goal", %{"type" => type_str}, socket) do
    type = String.to_existing_atom(type_str)
    next = if type == :six_count, do: socket.assigns.next_six, else: socket.assigns.next_navy

    if next do
      today = Date.utc_today()
      baseline = baseline_from_sessions(type, socket.assigns.sessions)

      attrs = %{
        "burpee_type" => type_str,
        "burpee_count_target" => next.burpee_count_required,
        "duration_sec_target" => 1200,
        "date_target" => Date.to_iso8601(Date.add(today, 28)),
        "date_baseline" => Date.to_iso8601(today),
        "burpee_count_baseline" => baseline.burpee_count,
        "duration_sec_baseline" => baseline.duration_sec
      }

      case Goals.create_goal(socket.assigns.current_user, attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Goal set: reach #{format_level(next.level)}.")
           |> assign(form_type: nil, form: nil)
           |> load_data()}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, socket}
    end
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

  def handle_event("get_recommendation", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:rec_type, String.to_existing_atom(type))
     |> assign(:rec_status, :picking_mood)
     |> assign(:rec_suggestions, [])}
  end

  def handle_event("dismiss_recommendation", _, socket) do
    {:noreply,
     socket
     |> assign(:rec_status, :idle)
     |> assign(:rec_type, nil)
     |> assign(:rec_suggestions, [])}
  end

  def handle_event("pick_rec_mood", %{"mood" => mood_str}, socket) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> 0
      end

    %{rec_type: burpee_type, sessions: sessions, performances: performances, cards: cards} =
      socket.assigns

    level = Levels.level_for_type(sessions, burpee_type)
    bucket = time_of_day_bucket_now()

    rec = Enum.find_value(cards, fn {type, _goal, r} -> if type == burpee_type, do: r end)

    suggestions =
      if rec do
        StyleRecommender.recommend(%{
          burpee_type: burpee_type,
          mood: mood,
          level: level,
          time_of_day_bucket: bucket,
          sessions: sessions,
          performances: performances,
          progression_rec: rec
        })
      else
        []
      end

    {:noreply,
     socket
     |> assign(:rec_suggestions, suggestions)
     |> assign(:rec_status, :showing_results)}
  end

  def handle_event("use_suggestion", %{"style" => style}, socket) do
    suggestion = find_suggestion(socket.assigns.rec_suggestions, style)

    if suggestion do
      case Workouts.save_generated_plan(socket.assigns.current_user, suggestion.plan) do
        {:ok, plan} ->
          {:noreply, push_navigate(socket, to: ~p"/plans/#{plan.id}/edit")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save plan.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("run_suggestion", %{"style" => style}, socket) do
    suggestion = find_suggestion(socket.assigns.rec_suggestions, style)

    if suggestion do
      case Workouts.save_generated_plan(socket.assigns.current_user, suggestion.plan) do
        {:ok, plan} ->
          {:noreply, push_navigate(socket, to: ~p"/session/#{plan.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save plan.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp find_suggestion(suggestions, style_str) do
    Enum.find(suggestions, fn %StyleSuggestion{style_name: name} ->
      Atom.to_string(name) == style_str
    end)
  end

  defp time_of_day_bucket_now do
    case DateTime.utc_now().hour do
      h when h in 6..11 -> "morning"
      h when h in 12..16 -> "afternoon"
      h when h in 17..20 -> "evening"
      _ -> "night"
    end
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
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <div class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Goals</h1>
          <p class="text-sm text-base-content/60">
            Targets by burpee type, with next-session recommendations.
          </p>
        </div>

        <.level_panel
          overall_level={@overall_level}
          level_six={@level_six}
          level_navy={@level_navy}
          next_six={@next_six}
          next_navy={@next_navy}
        />

        <%= if @rec_status != :idle do %>
          <.recommendation_panel
            rec_status={@rec_status}
            rec_type={@rec_type}
            rec_suggestions={@rec_suggestions}
          />
        <% end %>

        <div class="grid gap-6 lg:grid-cols-2">
          <%= for {type, goal, rec} <- @cards do %>
            <.goal_card
              type={type}
              goal={goal}
              rec={rec}
              form={@form}
              form_type={@form_type}
              goal_tab={@goal_tab}
              next_landmark={if type == :six_count, do: @next_six, else: @next_navy}
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
  attr :goal_tab, :atom, default: :level
  attr :next_landmark, :any, default: nil

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
          <.goal_new_panel
            type={@type}
            form={@form}
            goal_tab={@goal_tab}
            next_landmark={@next_landmark}
          />
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
  attr :form, :any, required: true
  attr :goal_tab, :atom, required: true
  attr :next_landmark, :any, default: nil

  defp goal_new_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex gap-1 rounded-lg bg-base-200 p-1 text-sm">
        <button
          type="button"
          phx-click="switch_goal_tab"
          phx-value-tab="level"
          class={[
            "flex-1 rounded-md px-3 py-1.5 font-medium transition",
            if(@goal_tab == :level,
              do: "bg-base-100 shadow-sm",
              else: "text-base-content/60 hover:text-base-content"
            )
          ]}
        >
          Level up
        </button>
        <button
          type="button"
          phx-click="switch_goal_tab"
          phx-value-tab="custom"
          class={[
            "flex-1 rounded-md px-3 py-1.5 font-medium transition",
            if(@goal_tab == :custom,
              do: "bg-base-100 shadow-sm",
              else: "text-base-content/60 hover:text-base-content"
            )
          ]}
        >
          Custom
        </button>
      </div>

      <%= if @goal_tab == :level do %>
        <.goal_level_tab type={@type} next_landmark={@next_landmark} />
      <% else %>
        <.new_goal_form type={@type} form={@form} />
      <% end %>
    </div>
    """
  end

  attr :type, :atom, required: true
  attr :next_landmark, :any, default: nil

  defp goal_level_tab(assigns) do
    ~H"""
    <%= if @next_landmark do %>
      <div class="rounded-md bg-base-200/40 p-4 space-y-1">
        <p class="font-semibold text-sm">Reach {format_level(@next_landmark.level)}</p>
        <p class="text-sm text-base-content/60">
          {@next_landmark.burpee_count_required} burpees in under 20 min · 28-day target
        </p>
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          phx-click="start_level_goal"
          phx-value-type={Atom.to_string(@type)}
          class="flex-1 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          Set this goal
        </button>
        <button
          type="button"
          phx-click="cancel_goal"
          class="rounded-md border border-base-300 px-3 py-1.5 text-sm hover:bg-base-200 transition"
        >
          Cancel
        </button>
      </div>
    <% else %>
      <div class="rounded-md bg-base-200/40 p-4 text-center space-y-2">
        <p class="text-sm font-medium">You've graduated!</p>
        <p class="text-sm text-base-content/60">Use the Custom tab to set a freestyle goal.</p>
        <button
          type="button"
          phx-click="cancel_goal"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          Cancel
        </button>
      </div>
    <% end %>
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
          <button
            type="button"
            phx-click="get_recommendation"
            phx-value-type={Atom.to_string(@type)}
            class="flex-1 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
          >
            Get style recommendation
          </button>
          <.link
            navigate={~p"/log"}
            class="rounded-md border border-base-300 bg-base-100 px-3 py-1.5 text-sm hover:bg-base-200 transition"
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

  # -- level panel --

  attr :overall_level, :atom, required: true
  attr :level_six, :atom, required: true
  attr :level_navy, :atom, required: true
  attr :next_six, :any, required: true
  attr :next_navy, :any, required: true

  defp level_panel(assigns) do
    six_is_bottleneck = level_index(assigns.level_six) < level_index(assigns.level_navy)
    navy_is_bottleneck = level_index(assigns.level_navy) < level_index(assigns.level_six)

    assigns =
      assign(assigns, six_bottleneck: six_is_bottleneck, navy_bottleneck: navy_is_bottleneck)

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-5 space-y-3">
      <div class="flex items-center gap-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Level</h2>
        <span class="inline-flex items-center rounded-full bg-primary/10 px-3 py-0.5 text-sm font-semibold text-primary">
          {format_level(@overall_level)}
        </span>
      </div>
      <div class="grid gap-2 sm:grid-cols-2 text-sm">
        <.level_row
          label="6-count"
          level={@level_six}
          next={@next_six}
          bottleneck={@six_bottleneck}
        />
        <.level_row
          label="Navy Seal"
          level={@level_navy}
          next={@next_navy}
          bottleneck={@navy_bottleneck}
        />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :level, :atom, required: true
  attr :next, :any, required: true
  attr :bottleneck, :boolean, required: true

  defp level_row(assigns) do
    ~H"""
    <div class={[
      "flex items-center justify-between rounded-md px-3 py-2",
      if(@bottleneck, do: "bg-warning/10", else: "bg-base-200/50")
    ]}>
      <div class="flex items-center gap-2">
        <span class={["font-medium", @bottleneck && "text-warning"]}>{@label}</span>
        <span class={[
          "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold",
          if(@bottleneck, do: "bg-warning/20 text-warning", else: "bg-base-300 text-base-content/70")
        ]}>
          {format_level(@level)}
        </span>
      </div>
      <%= if @next do %>
        <span class="text-xs text-base-content/60">
          next: {@next.burpee_count_required} for {format_level(@next.level)}
        </span>
      <% else %>
        <span class="text-xs text-success font-medium">Graduated</span>
      <% end %>
    </div>
    """
  end

  # -- recommendation panel --

  attr :rec_status, :atom, required: true
  attr :rec_type, :atom, default: nil
  attr :rec_suggestions, :list, default: []

  @rec_mood_options [{"😮‍💨", "Tired", -1}, {"😐", "OK", 0}, {"💪", "Hyped", 1}]

  defp recommendation_panel(assigns) do
    assigns = assign(assigns, mood_options: @rec_mood_options)

    ~H"""
    <section class="rounded-lg border border-primary/30 bg-base-100 p-5 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
          Style recommendation · {Fmt.burpee_type(@rec_type)}
        </h2>
        <button
          type="button"
          phx-click="dismiss_recommendation"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          Dismiss
        </button>
      </div>

      <%= if @rec_status == :picking_mood do %>
        <div class="space-y-2">
          <p class="text-sm text-base-content/70">How do you feel right now?</p>
          <div class="flex gap-3">
            <%= for {emoji, label, value} <- @mood_options do %>
              <button
                type="button"
                phx-click="pick_rec_mood"
                phx-value-mood={value}
                class="flex flex-col items-center gap-1.5 rounded-xl border border-base-300 px-5 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
              >
                <span class="text-2xl">{emoji}</span>
                <span>{label}</span>
              </button>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @rec_status == :showing_results and @rec_suggestions != [] do %>
        <div class="space-y-3">
          <%= for %{style_name: name, rationale: rationale, score: score} = suggestion <- @rec_suggestions do %>
            <div class="rounded-lg border border-base-200 bg-base-200/30 p-4 space-y-2">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <span class="font-semibold text-sm">{format_style_name(name)}</span>
                  <p class="text-xs text-base-content/60 mt-0.5">{rationale}</p>
                </div>
                <span class="shrink-0 text-xs text-base-content/50 tabular-nums">
                  {Float.round(score, 2)}
                </span>
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  phx-click="use_suggestion"
                  phx-value-style={Atom.to_string(name)}
                  class="flex-1 rounded-md border border-base-300 bg-base-100 px-3 py-1.5 text-xs font-medium hover:bg-base-200 transition"
                >
                  Use this (editor)
                </button>
                <button
                  type="button"
                  phx-click="run_suggestion"
                  phx-value-style={Atom.to_string(name)}
                  class="flex-1 rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:bg-primary/90 transition"
                >
                  Run directly
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @rec_status == :showing_results and @rec_suggestions == [] do %>
        <p class="text-sm text-base-content/60">
          No styles available at your current level for this type.
        </p>
      <% end %>
    </section>
    """
  end

  defp format_level(:graduated), do: "Grad"

  defp format_level(level) do
    level
    |> Atom.to_string()
    |> String.replace("level_", "")
    |> String.upcase()
  end

  defp level_index(level) do
    [:level_1a, :level_1b, :level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated]
    |> Enum.find_index(&(&1 == level))
    |> Kernel.||(0)
  end

  defp format_style_name(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
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
