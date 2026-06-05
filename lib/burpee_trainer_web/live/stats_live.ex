defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Levels, Scoring, Streak, Workouts}
  alias BurpeeTrainer.Stats.Series
  alias BurpeeTrainer.Streak.State
  alias BurpeeTrainerWeb.Fmt

  embed_templates("stats_live/*")

  @page_size 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    today = Date.utc_today()
    {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

    {:ok,
     socket
     |> assign(:streak, Streak.compute(user, today))
     |> assign(:today, today)
     |> assign(:goals, Goals.list_current_goals(user))
     |> then(&compute_goal_progress(&1, user, &1.assigns.goals))
     |> assign(:sessions, sessions)
     |> assign(:sessions_has_more, has_more)
     |> assign(:log_modal_open, false)
     |> assign(:goal_modal_type, nil)
     |> assign(:goal_baseline_session, nil)
     |> assign(:weekly_data, Workouts.weekly_minutes(user))
     |> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
     |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))
     |> assign_gamification(user, today)}
  end

  # Push-up score, personal best, balance, and level-maintenance status.
  defp assign_gamification(socket, user, today) do
    sessions = Workouts.list_sessions(user)
    week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Enum.filter(sessions, fn s ->
        Date.compare(
          DateTime.to_date(s.inserted_at) |> Date.beginning_of_week(:monday),
          week_start
        ) == :eq
      end)

    socket
    |> assign(:level_status, Levels.level_status(sessions, today))
    |> assign(:week_pushups, Scoring.total_pushups(this_week))
    |> assign(:best_week_pushups, Workouts.gamification_stats(user).best_week_pushups)
    |> assign(:week_balanced, Scoring.balanced_week?(this_week))
  end

  @impl true
  def handle_event("open_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, true)}
  end

  def handle_event("close_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, false)}
  end

  def handle_event("load_more_sessions", _, socket) do
    user = socket.assigns.current_user
    cursor = socket.assigns.sessions |> List.last() |> Map.get(:inserted_at)
    {new_sessions, has_more} = Workouts.list_sessions_page(user, @page_size, before: cursor)

    {:noreply,
     socket
     |> update(:sessions, &(&1 ++ new_sessions))
     |> assign(:sessions_has_more, has_more)}
  end

  def handle_event("open_goal_modal", %{"type" => type_str}, socket) do
    user = socket.assigns.current_user
    burpee_type = String.to_existing_atom(type_str)
    baseline = Workouts.last_session_for_type(user, burpee_type)

    {:noreply,
     socket
     |> assign(:goal_modal_type, burpee_type)
     |> assign(:goal_baseline_session, baseline)}
  end

  def handle_event("close_goal_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:goal_modal_type, nil)
     |> assign(:goal_baseline_session, nil)}
  end

  @impl true
  def handle_info(:session_saved, socket) do
    {:noreply, refresh_after_session_save(socket, [])}
  end

  def handle_info({:session_saved, events}, socket) do
    {:noreply, refresh_after_session_save(socket, events)}
  end

  def handle_info(:goal_saved, socket) do
    user = socket.assigns.current_user
    goals = Goals.list_current_goals(user)

    {:noreply,
     socket
     |> assign(:goal_modal_type, nil)
     |> assign(:goal_baseline_session, nil)
     |> assign(:goals, goals)
     |> compute_goal_progress(user, goals)}
  end

  defp refresh_after_session_save(socket, events) do
    user = socket.assigns.current_user
    today = socket.assigns.today
    {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)
    goals = Goals.list_current_goals(user)

    socket
    |> assign(:log_modal_open, false)
    |> assign(:streak, Streak.compute(user, today))
    |> assign(:sessions, sessions)
    |> assign(:sessions_has_more, has_more)
    |> assign(:weekly_data, Workouts.weekly_minutes(user))
    |> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
    |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))
    |> assign(:goals, goals)
    |> compute_goal_progress(user, goals)
    |> assign_gamification(user, today)
    |> put_milestone_flashes(events)
  end

  defp put_milestone_flashes(socket, events) do
    Enum.reduce(events, socket, fn
      %{type: :goal_reached, value: %{burpee_type: type}}, acc ->
        put_flash(acc, :info, "#{goal_type_label(type)} goal reached!")

      _event, acc ->
        acc
    end)
  end

  defp goal_type_label(:six_count), do: "6-Count"
  defp goal_type_label(:navy_seal), do: "Navy SEAL"

  attr(:status, :map, required: true)

  defp at_risk_banner(assigns) do
    ~H"""
    <div
      :if={@status.at_risk?}
      class="border border-[var(--session-border)] bg-[var(--session-track)]/40 px-4 py-3 flex items-start gap-3"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-[var(--session-ink)]" />
      <div class="space-y-0.5">
        <p class="text-sm font-semibold text-[var(--session-ink)]">
          Level {level_label(@status.level)} expires in {@status.days_left}d
        </p>
        <p class="text-xs text-[var(--session-muted)]">
          Do a six-count and a navy seal landmark this week to keep it.
        </p>
      </div>
    </div>
    """
  end

  attr(:streak, State, required: true)
  attr(:today, Date, required: true)
  attr(:current_level, :atom, default: nil)
  attr(:week_pushups, :integer, default: 0)
  attr(:best_week_pushups, :integer, default: 0)
  attr(:week_balanced, :boolean, default: false)

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    minutes_done = trunc(assigns.streak.current_week_minutes)
    pct = max(min(assigns.streak.current_week_minutes / 80 * 100, 100), 0)
    ring_offset = 264 - pct * 2.64
    minutes_left = max(80 - minutes_done, 0)

    assigns =
      assign(assigns,
        week_days: Enum.map(0..6, &Date.add(week_start, &1)),
        minutes_done: minutes_done,
        ring_offset: ring_offset,
        minutes_left: minutes_left
      )

    ~H"""
    <div class="border border-[var(--session-border)] bg-[var(--session-surface)] px-5 py-5 space-y-5">
      <div class="flex items-center gap-7">
        <div class="relative size-[108px] shrink-0" aria-label={"#{@minutes_done} of 80 minutes"}>
          <svg viewBox="0 0 100 100" class="size-full -rotate-90">
            <circle
              cx="50"
              cy="50"
              r="42"
              fill="none"
              stroke="var(--session-ring-track)"
              stroke-width="7"
            />
            <circle
              cx="50"
              cy="50"
              r="42"
              fill="none"
              stroke="var(--session-ink)"
              stroke-width="7"
              stroke-linecap="butt"
              stroke-dasharray="264"
              stroke-dashoffset={@ring_offset}
            />
          </svg>
          <div class="absolute inset-0 flex flex-col items-center justify-center text-center">
            <span class="text-4xl font-semibold leading-none tracking-[-0.05em] tabular-nums">
              {@minutes_done}
            </span>
            <span class="mt-1 text-xs font-medium text-[var(--session-muted)]">/ 80 min</span>
          </div>
        </div>
        <div class="min-w-0 flex-1 space-y-2">
          <%= if @current_level do %>
            <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
              Level {level_label(@current_level)}
            </p>
          <% end %>
          <p class="text-lg font-semibold text-[var(--session-ink)] tabular-nums">
            {@minutes_left} min left
          </p>
          <p class="text-xs text-[var(--session-muted)]">
            <%= if @streak.streak_weeks == 0 do %>
              No active streak
            <% else %>
              {@streak.streak_weeks} week streak
            <% end %>
          </p>
        </div>
      </div>

      <div class="flex justify-between">
        <%= for day <- @week_days do %>
          <div class="flex flex-col items-center gap-1">
            <span class={[
              "text-[10px] font-medium",
              day == @today && "text-[var(--session-ink)]",
              day != @today && "text-[var(--session-muted)]"
            ]}>
              {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
            </span>
            <div class={[
              "rounded-full",
              day in @streak.days_active_this_week && "w-4 h-4 bg-[var(--session-ink)]",
              day == @today && day not in @streak.days_active_this_week &&
                "w-4 h-4 ring-2 ring-[var(--session-muted)] ring-offset-2 ring-offset-[var(--session-bg)] bg-transparent",
              day > @today && "w-3 h-3 bg-[var(--session-track)]",
              day < @today && day not in @streak.days_active_this_week &&
                "w-3 h-3 bg-[var(--session-track)]"
            ]} />
          </div>
        <% end %>
      </div>

      <div class="flex items-center justify-between border-t border-[var(--session-border)] pt-3">
        <div class="flex items-baseline gap-1.5 tabular-nums">
          <span class="text-lg font-bold text-[var(--session-ink)]">{@week_pushups}</span>
          <span class="text-xs text-[var(--session-muted)]">push-ups this week</span>
          <span :if={@best_week_pushups > 0} class="text-xs text-[var(--session-muted)]">
            · best {@best_week_pushups}
          </span>
        </div>
        <span
          :if={@week_balanced}
          class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-[var(--session-track)] text-[var(--session-ink)] text-[10px] font-medium shrink-0"
        >
          <.icon name="hero-scale" class="size-2.5" /> Balanced
        </span>
      </div>

      <%= if @streak.streak_weeks == 0 && @streak.previous_best_weeks > 0 do %>
        <p class="text-xs text-[var(--session-muted)]">
          Previous best: {@streak.previous_best_weeks} weeks
        </p>
      <% end %>
    </div>
    """
  end

  attr(:goals, :list, required: true)
  attr(:six_progress, :any, required: true)
  attr(:seal_progress, :any, required: true)
  attr(:six_has_sessions, :boolean, required: true)
  attr(:seal_has_sessions, :boolean, required: true)

  defp goals_section(assigns) do
    assigns =
      assigns
      |> assign(:six, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
      |> assign(:seal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

    ~H"""
    <div class="space-y-3">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">Goals</p>
      <div class="grid grid-cols-2 gap-3">
        <.goal_slot
          burpee_type={:six_count}
          label="6-COUNT"
          goal={@six}
          progress={@six_progress}
          has_sessions={@six_has_sessions}
        />
        <.goal_slot
          burpee_type={:navy_seal}
          label="NAVY SEAL"
          goal={@seal}
          progress={@seal_progress}
          has_sessions={@seal_has_sessions}
        />
      </div>
    </div>
    """
  end

  attr(:burpee_type, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:goal, :any, required: true)
  attr(:progress, :any, required: true)
  attr(:has_sessions, :boolean, required: true)

  defp goal_slot(assigns) do
    today = Date.utc_today()

    current_reps =
      if assigns.progress do
        round(
          assigns.progress.burpee_count_actual / assigns.progress.duration_sec_actual * 1200.0
        )
      else
        0
      end

    {pct, days_left, weekly_pace} =
      if assigns.goal && assigns.goal.status == :active do
        target = assigns.goal.burpee_count_target
        pct = min(round(current_reps / target * 100), 100)
        days = Date.diff(assigns.goal.date_target, today)
        weeks_remaining = max(ceil(days / 7), 1)
        reps_needed = max(target - current_reps, 0)
        pace = ceil(reps_needed / weeks_remaining)
        {pct, days, pace}
      else
        {100, nil, nil}
      end

    assigns =
      assign(assigns,
        current_reps: current_reps,
        pct: pct,
        days_left: days_left,
        weekly_pace: weekly_pace
      )

    ~H"""
    <div class="border border-[var(--session-border)] bg-[var(--session-surface)] px-4 py-4 flex flex-col gap-3">
      <%= cond do %>
        <% @goal && @goal.status == :achieved -> %>
          <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
            {@label}
          </p>
          <div class="flex items-baseline gap-1.5 tabular-nums">
            <span class="text-2xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
              {@goal.burpee_count_target}
            </span>
            <span class="text-xs text-[var(--session-muted)]">reps</span>
          </div>
          <div class="flex items-center gap-1.5 text-[var(--session-ink)]">
            <.icon name="hero-trophy" class="size-3.5 shrink-0" />
            <span class="text-xs font-medium">
              Reached {Calendar.strftime(DateTime.to_date(@goal.updated_at), "%-d %b %Y")}
            </span>
          </div>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="mt-auto w-full border border-[var(--session-ink)] bg-[var(--session-surface)] py-2 text-sm text-[var(--session-ink)] hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition text-center"
          >
            Set new goal
          </button>
        <% @goal && @goal.status == :active -> %>
          <div class="flex items-start justify-between gap-2">
            <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
              {@label}
            </p>
            <%= if @weekly_pace && @days_left > 0 do %>
              <span class="text-[10px] text-[var(--session-muted)] tabular-nums shrink-0">
                ~{@weekly_pace}/wk
              </span>
            <% end %>
          </div>
          <div class="tabular-nums">
            <div class="flex items-baseline gap-1">
              <span class="text-2xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
                {@current_reps}
              </span>
              <span class="text-xs text-[var(--session-muted)]">/ {@goal.burpee_count_target}</span>
            </div>
          </div>
          <div class="h-1.5 bg-[var(--session-track)] overflow-hidden">
            <div
              class="h-full bg-[var(--session-ink)] transition-all duration-500"
              style={"width: #{@pct}%"}
            />
          </div>
          <p class="text-xs text-[var(--session-muted)]">
            by {Calendar.strftime(@goal.date_target, "%-d %b")}
            <%= cond do %>
              <% @days_left > 0 -> %>
                · {@days_left}d left
              <% @days_left == 0 -> %>
                · Today
              <% true -> %>
                · Overdue
            <% end %>
          </p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="mt-auto w-full border border-[var(--session-ink)] bg-[var(--session-surface)] py-2 text-sm text-[var(--session-ink)] hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition text-center"
          >
            Update goal
          </button>
        <% @has_sessions -> %>
          <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
            {@label}
          </p>
          <p class="text-sm text-[var(--session-muted)]">No goal set</p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="mt-auto w-full border border-[var(--session-ink)] bg-[var(--session-surface)] py-2 text-sm font-medium text-[var(--session-ink)] hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition text-center"
          >
            Set goal
          </button>
        <% true -> %>
          <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
            {@label}
          </p>
          <p class="text-sm text-[var(--session-muted)]">No sessions yet</p>
          <p class="text-xs text-[var(--session-muted)] opacity-70">Log a session first</p>
      <% end %>
    </div>
    """
  end

  attr(:sessions, :list, required: true)
  attr(:has_more, :boolean, required: true)

  defp sessions_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
        Recent sessions
      </p>
      <%= if @sessions == [] do %>
        <p class="text-sm text-[var(--session-muted)]">No sessions yet.</p>
      <% else %>
        <div class="border border-[var(--session-border)] bg-[var(--session-surface)] px-4">
          <%= for session <- @sessions do %>
            <.session_row session={session} />
          <% end %>
          <%= if @has_more do %>
            <button
              phx-click="load_more_sessions"
              class="w-full py-3 text-xs text-[var(--session-ink)] hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)] transition text-center"
            >
              Load more
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:session, :any, required: true)

  defp session_row(assigns) do
    today = Date.utc_today()
    date = DateTime.to_date(assigns.session.inserted_at)

    date_str =
      if date.year == today.year,
        do: Calendar.strftime(date, "%-d %b"),
        else: Calendar.strftime(date, "%-d %b %Y")

    assigns = assign(assigns, date_str: date_str, capture_badge: capture_badge(assigns.session))

    ~H"""
    <div class="relative flex items-start justify-between gap-3 border-b border-[var(--session-border)] py-4 last:border-b-0">
      <.link
        :if={@capture_badge && @capture_badge.label == "Tracked"}
        navigate={~p"/stats/sessions/#{@session.id}"}
        class="absolute inset-0"
        aria-label="Open session analysis"
      >
        <span class="sr-only">Open session analysis</span>
      </.link>
      <div class="min-w-0 space-y-0.5">
        <div class="flex items-baseline gap-2">
          <span class="text-base font-semibold tabular-nums leading-none text-[var(--session-ink)]">
            {if @session.burpee_count_actual, do: @session.burpee_count_actual, else: "—"}
          </span>
          <span class="text-xs text-[var(--session-ink)]">
            {Fmt.burpee_type(@session.burpee_type)}
          </span>
          <span class="text-xs text-[var(--session-muted)] tabular-nums">
            {Fmt.duration_sec(@session.duration_sec_actual)}
          </span>
        </div>
        <div class="flex items-center gap-2 min-w-0">
          <%= if @session.plan do %>
            <span class="text-xs text-[var(--session-muted)] truncate">{@session.plan.name}</span>
          <% end %>
          <%= if @session.goal do %>
            <span class="inline-flex items-center gap-1 border border-[var(--session-border)] bg-[var(--session-track)] px-1.5 py-0.5 text-[var(--session-ink)] text-[10px] font-medium shrink-0">
              <.icon name="hero-trophy" class="size-2.5" /> Goal
            </span>
          <% end %>
          <%= if @capture_badge do %>
            <span class="inline-flex items-center border border-[var(--session-border)] bg-[var(--session-track)] px-2 py-0.5 text-[10px] uppercase tracking-wide text-[var(--session-ink)]">
              {@capture_badge.label}
            </span>
            <span :if={@capture_badge.detail} class="text-xs text-[var(--session-muted)]">
              {@capture_badge.detail}
            </span>
          <% end %>
        </div>
      </div>
      <span class="text-xs text-[var(--session-muted)] shrink-0 pt-0.5">{@date_str}</span>
    </div>
    """
  end

  defp capture_badge(%{capture_mode: :tracked, pace_consistency: consistency})
       when is_float(consistency) do
    %{label: "Tracked", detail: "#{round(consistency * 100)}% consistent"}
  end

  defp capture_badge(%{capture_mode: :timed}), do: %{label: "Timed", detail: nil}
  defp capture_badge(_), do: nil

  attr(:weekly_data, :list, required: true)
  attr(:six_count_sessions, :list, required: true)
  attr(:navy_seal_sessions, :list, required: true)
  attr(:goals, :list, required: true)

  defp trends_section(assigns) do
    assigns =
      assigns
      |> assign(:six_goal, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
      |> assign(:seal_goal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

    ~H"""
    <div class="space-y-3">
      <p class="text-xs font-medium uppercase tracking-[0.14em] text-[var(--session-muted)]">
        Trends
      </p>
      <.weekly_minutes_chart weekly_data={@weekly_data} />
      <.progress_chart
        six_count_sessions={@six_count_sessions}
        navy_seal_sessions={@navy_seal_sessions}
        six_goal={@six_goal}
        seal_goal={@seal_goal}
      />
    </div>
    """
  end

  attr(:weekly_data, :list, required: true)

  defp weekly_minutes_chart(assigns) do
    # Always show 12 slots; pad with empty weeks at the start if less data
    weekly_model = Series.weekly_minutes(assigns.weekly_data)

    raw_weeks =
      weekly_model.points
      |> Enum.take(12)

    n_slots = 12
    n_data = length(raw_weeks)
    n_empty = n_slots - n_data

    # Build index-labelled list: empty slots first, then real data
    chart_weeks =
      List.duplicate(%{minutes: 0, met_goal: false, iso_week: nil}, n_empty) ++
        Enum.map(raw_weeks, fn week ->
          {_y, w} = :calendar.iso_week_number(Date.to_erl(week.week_start))
          Map.put(week, :iso_week, w)
        end)

    chart_w = 300
    y_axis_w = 20
    plot_w = chart_w - y_axis_w
    slot_w = plot_w / n_slots
    bar_w = max(slot_w * 0.6, 2)
    max_m = 120
    target_y = 75 - 80 / max_m * 70

    assigns =
      assign(assigns,
        chart_weeks: Enum.with_index(chart_weeks),
        chart_w: chart_w,
        y_axis_w: y_axis_w,
        slot_w: slot_w,
        bar_w: bar_w,
        max_m: max_m,
        target_y: target_y
      )

    weekly_minutes_chart_template(assigns)
  end

  attr(:six_count_sessions, :list, required: true)
  attr(:navy_seal_sessions, :list, required: true)
  attr(:six_goal, :any, required: true)
  attr(:seal_goal, :any, required: true)

  defp progress_chart(assigns) do
    to_points = fn sessions ->
      sessions
      |> Series.progress()
      |> Map.fetch!(:points)
      |> Enum.map(&%{reps: &1.normalized_reps, iso_week: &1.iso_week})
    end

    six_points = to_points.(assigns.six_count_sessions)
    seal_points = to_points.(assigns.navy_seal_sessions)
    six_target = assigns.six_goal && assigns.six_goal.burpee_count_target
    seal_target = assigns.seal_goal && assigns.seal_goal.burpee_count_target

    all_vals =
      Enum.map(six_points, & &1.reps) ++
        Enum.map(seal_points, & &1.reps) ++
        Enum.reject([six_target, seal_target], &is_nil/1)

    # Y-axis ceiling is the highest target; if no goals, fall back to actual data max
    targets = Enum.reject([six_target, seal_target], &is_nil/1)

    max_val =
      cond do
        targets != [] -> Enum.max(targets)
        all_vals != [] -> Enum.max(all_vals)
        true -> 1
      end

    # Meaningful y-axis ticks: targets + 0, sorted desc
    y_ticks =
      [six_target, seal_target, 0]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort(:desc)

    y_axis_w = 32
    chart_w = 320
    top_pad = 12
    plot_h = 90
    bot_pad = 20
    total_h = top_pad + plot_h + bot_pad

    to_y = fn v -> top_pad + plot_h - v / (max_val * 1.0) * plot_h end

    # Build per-series x coords: use all sessions merged and sorted by week for shared x-axis
    all_weeks =
      (Enum.map(six_points, & &1.iso_week) ++ Enum.map(seal_points, & &1.iso_week))
      |> Enum.uniq()
      |> Enum.sort()

    n_weeks = length(all_weeks)
    week_index = all_weeks |> Enum.with_index() |> Map.new()

    step =
      if n_weeks > 1, do: (chart_w - y_axis_w) / (n_weeks - 1), else: (chart_w - y_axis_w) * 1.0

    to_x = fn week -> y_axis_w + Map.fetch!(week_index, week) * step end

    build_polyline = fn points ->
      Enum.map_join(points, " ", fn p ->
        "#{Float.round(to_x.(p.iso_week), 1)},#{Float.round(to_y.(p.reps * 1.0), 1)}"
      end)
    end

    six_polyline = build_polyline.(six_points)
    seal_polyline = build_polyline.(seal_points)

    x_label_weeks =
      Enum.filter(all_weeks, fn w ->
        i = Map.fetch!(week_index, w)
        i == 0 or i == n_weeks - 1 or (n_weeks > 4 and rem(i, 3) == 0)
      end)

    all_empty = six_points == [] and seal_points == []

    assigns =
      assign(assigns,
        six_points: six_points,
        seal_points: seal_points,
        six_target: six_target,
        seal_target: seal_target,
        six_polyline: six_polyline,
        seal_polyline: seal_polyline,
        x_label_weeks: x_label_weeks,
        y_ticks: y_ticks,
        max_val: max_val,
        all_empty: all_empty,
        to_x: to_x,
        to_y: to_y,
        top_pad: top_pad,
        plot_h: plot_h,
        total_h: total_h,
        chart_w: chart_w,
        y_axis_w: y_axis_w
      )

    progress_chart_template(assigns)
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  defp compute_goal_progress(socket, user, goals) do
    six_goal = Enum.find(goals, &(&1.burpee_type == :six_count))
    seal_goal = Enum.find(goals, &(&1.burpee_type == :navy_seal))

    socket
    |> assign(:six_progress, six_goal && Workouts.best_qualifying_session(user, :six_count))
    |> assign(:seal_progress, seal_goal && Workouts.best_qualifying_session(user, :navy_seal))
  end
end
