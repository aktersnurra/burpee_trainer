defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Streak, Workouts}
  alias BurpeeTrainer.Streak.State
  alias BurpeeTrainerWeb.Fmt

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
     |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))}
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
    user = socket.assigns.current_user
    today = socket.assigns.today
    {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

    # Find goals just achieved and tag the achieving session in the DB
    newly_achieved =
      socket.assigns.goals
      |> Enum.filter(&(&1.status == :active))
      |> Enum.flat_map(fn goal ->
        best = Workouts.best_qualifying_session(user, goal.burpee_type)

        if best &&
             round(best.burpee_count_actual / best.duration_sec_actual * 1200.0) >=
               goal.burpee_count_target do
          Goals.mark_achieved(goal)
          Workouts.tag_session_as_goal_reached(best, goal.id)
          [goal]
        else
          []
        end
      end)

    goals = Goals.list_current_goals(user)

    socket =
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

    socket =
      Enum.reduce(newly_achieved, socket, fn goal, acc ->
        type_label = if goal.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
        put_flash(acc, :info, "#{type_label} goal reached!")
      end)

    {:noreply, socket}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <div class="space-y-5 pb-20">
        <.streak_card streak={@streak} today={@today} current_level={@current_level} />
        <.goals_section
          goals={@goals}
          six_progress={@six_progress}
          seal_progress={@seal_progress}
          six_has_sessions={@six_count_sessions != []}
          seal_has_sessions={@navy_seal_sessions != []}
        />
        <.trends_section
          weekly_data={@weekly_data}
          six_count_sessions={@six_count_sessions}
          navy_seal_sessions={@navy_seal_sessions}
          goals={@goals}
        />
        <.sessions_section sessions={@sessions} has_more={@sessions_has_more} />
      </div>

      <%!-- FAB --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-6 z-40">
        <button
          type="button"
          phx-click="open_log_modal"
          class="w-12 h-12 rounded-full bg-[#141B26] border border-[#1E2535] text-[#4A9EFF] flex items-center justify-center hover:bg-[#1E2535] transition"
          aria-label="Log session"
        >
          <.icon name="hero-plus" class="size-5" />
        </button>
      </div>

      <%!-- Log modal --%>
      <%= if @log_modal_open do %>
        <div
          id="log-modal"
          class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/60"
        >
          <div class="w-full sm:max-w-md bg-[#0D1017] border border-[#1E2535] rounded-t-2xl sm:rounded-2xl p-6">
            <.live_component
              module={BurpeeTrainerWeb.LogFormComponent}
              id="log-form"
              current_user={@current_user}
              on_save={:session_saved}
            />
          </div>
        </div>
      <% end %>

      <%!-- Goal modal --%>
      <%= if @goal_modal_type do %>
        <div
          id="goal-modal"
          class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/60"
        >
          <div class="w-full sm:max-w-md bg-[#0D1017] border border-[#1E2535] rounded-t-2xl sm:rounded-2xl p-6">
            <.live_component
              module={BurpeeTrainerWeb.GoalFormComponent}
              id="goal-form"
              current_user={@current_user}
              burpee_type={@goal_modal_type}
              baseline_session={@goal_baseline_session}
              on_save={:goal_saved}
            />
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :streak, State, required: true
  attr :today, Date, required: true
  attr :current_level, :atom, default: nil

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    assigns = assign(assigns, :week_days, Enum.map(0..6, &Date.add(week_start, &1)))

    ~H"""
    <div class="rounded-[10px] bg-base-300 p-5 space-y-4">
      <div class="flex items-start justify-between">
        <div class="tabular-nums leading-none">
          <div class="flex items-baseline gap-2">
            <span class="text-8xl font-bold tracking-tight">
              {trunc(@streak.current_week_minutes)}
            </span>
            <span class="text-base-content/50 text-base">/ 80 min</span>
          </div>
        </div>
        <div class="text-right space-y-1">
          <%= if @current_level do %>
            <p class="text-xs font-semibold text-base-content/40">
              Level <span class="text-base-content/70">{level_label(@current_level)}</span>
            </p>
          <% end %>
          <div class="text-sm text-base-content/60">
            <%= if @streak.streak_weeks == 0 do %>
              No active streak
            <% else %>
              {@streak.streak_weeks} week streak
            <% end %>
          </div>
        </div>
      </div>

      <div class="h-3 rounded-full bg-[#1E2535] overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-500",
            @streak.current_week_minutes >= 80 && "bg-primary",
            @streak.current_week_minutes < 80 && @streak.on_pace? && "bg-primary/70",
            !@streak.on_pace? && "bg-primary/30"
          ]}
          style={"width: #{max(min(@streak.current_week_minutes / 80 * 100, 100), if(@streak.current_week_minutes > 0, do: 2, else: 0))}%"}
        />
      </div>

      <div class="flex justify-between">
        <%= for day <- @week_days do %>
          <div class="flex flex-col items-center gap-1">
            <span class={[
              "text-[10px] font-medium",
              day == @today && "text-primary",
              day != @today && "text-base-content/50"
            ]}>
              {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
            </span>
            <div class={[
              "rounded-full",
              day in @streak.days_active_this_week && "w-4 h-4 bg-primary",
              day == @today && day not in @streak.days_active_this_week &&
                "w-4 h-4 ring-2 ring-primary ring-offset-2 ring-offset-base-200 bg-transparent",
              day > @today && "w-3 h-3 bg-[#1E2535]",
              day < @today && day not in @streak.days_active_this_week && "w-3 h-3 bg-[#1E2535]"
            ]} />
          </div>
        <% end %>
      </div>

      <%= if @streak.streak_weeks == 0 && @streak.previous_best_weeks > 0 do %>
        <p class="text-xs text-base-content/30">
          Previous best: {@streak.previous_best_weeks} weeks
        </p>
      <% end %>
    </div>
    """
  end

  attr :goals, :list, required: true
  attr :six_progress, :any, required: true
  attr :seal_progress, :any, required: true
  attr :six_has_sessions, :boolean, required: true
  attr :seal_has_sessions, :boolean, required: true

  defp goals_section(assigns) do
    assigns =
      assigns
      |> assign(:six, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
      |> assign(:seal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

    ~H"""
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
    """
  end

  attr :burpee_type, :atom, required: true
  attr :label, :string, required: true
  attr :goal, :any, required: true
  attr :progress, :any, required: true
  attr :has_sessions, :boolean, required: true

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
    <div class="rounded-[10px] bg-base-300 p-4 space-y-3">
      <%= cond do %>
        <% @goal && @goal.status == :achieved -> %>
          <div class="space-y-2">
            <div class="flex items-center gap-2 text-primary">
              <.icon name="hero-trophy" class="size-4 shrink-0" />
              <span class="text-sm font-semibold">Goal reached</span>
            </div>
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
              {@label}
            </p>
            <p class="text-sm font-semibold tabular-nums">
              {@goal.burpee_count_target}
              <span class="text-xs font-normal text-base-content/40 ml-0.5">burpees</span>
            </p>
            <p class="text-[10px] text-base-content/30">
              {Calendar.strftime(DateTime.to_date(@goal.updated_at), "%-d %b %Y")}
            </p>
            <button
              type="button"
              phx-click="open_goal_modal"
              phx-value-type={@burpee_type}
              class="text-xs text-primary hover:underline"
            >
              Set new goal
            </button>
          </div>
        <% @goal && @goal.status == :active -> %>
          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
              {@label}
            </p>
            <div class="flex items-baseline justify-between">
              <div class="tabular-nums">
                <span class="text-lg font-semibold">{@current_reps}</span>
                <span class="text-xs text-base-content/40 ml-1">
                  / {@goal.burpee_count_target}
                </span>
              </div>
              <%= if @weekly_pace && @days_left > 0 do %>
                <span class="text-[10px] text-base-content/40 tabular-nums">~{@weekly_pace}/wk</span>
              <% end %>
            </div>

            <div class="h-1.5 rounded-full bg-[#1E2535] overflow-hidden">
              <div
                class="h-full rounded-full bg-primary transition-all duration-500"
                style={"width: #{@pct}%"}
              />
            </div>

            <%= if @current_reps == 0 do %>
              <p class="text-[10px] text-base-content/30">Log a 20-min session to track progress</p>
            <% end %>

            <p class="text-[10px] text-base-content/30">
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
              class="text-[10px] text-base-content/30 hover:text-primary transition"
            >
              Update goal
            </button>
          </div>
        <% true -> %>
          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">
              {@label}
            </p>
            <%= if @has_sessions do %>
              <p class="text-xs text-base-content/40">No goal set</p>
              <button
                type="button"
                phx-click="open_goal_modal"
                phx-value-type={@burpee_type}
                class="text-xs text-primary hover:underline"
              >
                Set goal
              </button>
            <% else %>
              <p class="text-xs text-base-content/40">No sessions yet</p>
              <p class="text-[10px] text-base-content/30">Log a session to set a goal</p>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end

  attr :sessions, :list, required: true
  attr :has_more, :boolean, required: true

  defp sessions_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">Sessions</p>
      <%= if @sessions == [] do %>
        <p class="text-sm text-base-content/40">No sessions yet.</p>
      <% else %>
        <div class="rounded-[10px] bg-base-300 divide-y divide-[#1E2535] px-4">
          <%= for session <- @sessions do %>
            <.session_row session={session} />
          <% end %>
        </div>

        <%= if @has_more do %>
          <div class="flex justify-center pt-1">
            <button
              phx-click="load_more_sessions"
              class="px-4 py-1.5 rounded-full border border-[#1E2535] text-xs text-base-content/40 hover:text-base-content/70 hover:border-[#2E3A4E] transition"
            >
              Load more
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :session, :any, required: true

  defp session_row(assigns) do
    today = Date.utc_today()
    date = DateTime.to_date(assigns.session.inserted_at)

    date_str =
      if date.year == today.year,
        do: Calendar.strftime(date, "%-d %b"),
        else: Calendar.strftime(date, "%-d %b %Y")

    assigns = assign(assigns, date_str: date_str)

    ~H"""
    <div class="flex items-center justify-between gap-4 py-2.5">
      <div class="flex items-center gap-3 min-w-0">
        <span class="text-sm font-semibold tabular-nums w-10 shrink-0">
          {if @session.burpee_count_actual, do: @session.burpee_count_actual, else: "—"}
        </span>
        <span class="text-sm text-base-content/70 shrink-0">
          {Fmt.burpee_type(@session.burpee_type)}
        </span>
        <span class="text-sm text-base-content/40 tabular-nums shrink-0">
          {Fmt.duration_sec(@session.duration_sec_actual)}
        </span>
        <%= if @session.goal do %>
          <span class="flex items-center gap-1 text-[10px] text-primary shrink-0">
            <.icon name="hero-trophy" class="size-3" /> Goal reached
          </span>
        <% end %>
        <%= if @session.plan do %>
          <span class="text-xs text-base-content/25 truncate">{@session.plan.name}</span>
        <% end %>
      </div>
      <span class="text-xs text-base-content/30 shrink-0">{@date_str}</span>
    </div>
    """
  end

  attr :weekly_data, :list, required: true
  attr :six_count_sessions, :list, required: true
  attr :navy_seal_sessions, :list, required: true
  attr :goals, :list, required: true

  defp trends_section(assigns) do
    assigns =
      assigns
      |> assign(:six_goal, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
      |> assign(:seal_goal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

    ~H"""
    <div class="space-y-3">
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

  attr :weekly_data, :list, required: true

  defp weekly_minutes_chart(assigns) do
    # Always show 12 slots; pad with empty weeks at the start if less data
    raw_weeks =
      assigns.weekly_data
      |> Enum.take(12)
      |> Enum.reverse()

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

    ~H"""
    <div class="rounded-[10px] bg-base-300 p-4">
      <svg viewBox={"0 0 #{@chart_w} 96"} class="w-full" aria-hidden="true">
        <%!-- y-axis: 0 only --%>
        <text x={@y_axis_w - 2} y="76" text-anchor="end" font-size="7" fill="#3A4A5E">0</text>

        <%!-- bars --%>
        <%= for {week, i} <- @chart_weeks do %>
          <% cx = @y_axis_w + (i + 0.5) * @slot_w
          x = cx - @bar_w / 2
          height = max(min(week.minutes / @max_m * 70, 70), if(week.minutes > 0, do: 1, else: 0))
          y = 75 - height
          color = if week.met_goal, do: "#4A9EFF", else: "#2A3A4E" %>
          <%= if height > 0 do %>
            <rect x={x} y={y} width={@bar_w} height={height} fill={color} rx="2" />
          <% end %>
        <% end %>

        <%!-- 80 min target line — label on lhs --%>
        <text x={@y_axis_w - 2} y={@target_y + 3} text-anchor="end" font-size="7" fill="#3A4A5E">
          80
        </text>
        <line
          x1={@y_axis_w}
          y1={@target_y}
          x2={@chart_w}
          y2={@target_y}
          stroke="#3A4A5E"
          stroke-width="0.5"
          stroke-dasharray="3,3"
        />

        <%!-- x-axis: label data weeks only --%>
        <%= for {week, i} <- @chart_weeks, week.iso_week != nil do %>
          <% cx = @y_axis_w + (i + 0.5) * @slot_w %>
          <text x={cx} y="90" text-anchor="middle" font-size="6" fill="#3A4A5E">
            W{week.iso_week}
          </text>
        <% end %>
      </svg>
    </div>
    """
  end

  attr :six_count_sessions, :list, required: true
  attr :navy_seal_sessions, :list, required: true
  attr :six_goal, :any, required: true
  attr :seal_goal, :any, required: true

  defp progress_chart(assigns) do
    to_points = fn sessions ->
      Enum.map(sessions, fn s ->
        {_y, w} = :calendar.iso_week_number(Date.to_erl(DateTime.to_date(s.inserted_at)))
        %{reps: round(s.burpee_count_actual / s.duration_sec_actual * 1200.0), iso_week: w}
      end)
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

    ~H"""
    <div class="rounded-[10px] bg-base-300 p-5">
      <div class="flex items-start justify-between mb-1">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">Progress</p>
          <p class="text-[10px] text-base-content/30 mt-0.5">Normalized reps / 20 min</p>
        </div>
        <div class="flex items-center gap-3 pt-0.5">
          <span class="flex items-center gap-1 text-[10px] text-base-content/50">
            <span class="inline-block w-2 h-2 rounded-full bg-[#4A9EFF]"></span>6-Count
          </span>
          <span class="flex items-center gap-1 text-[10px] text-base-content/50">
            <span class="inline-block w-2 h-2 rounded-full bg-[#F97316]"></span>Navy SEAL
          </span>
        </div>
      </div>

      <%= if @all_empty do %>
        <p class="text-xs text-base-content/30 mt-4">No sessions yet.</p>
      <% else %>
        <svg
          viewBox={"0 0 #{@chart_w} #{@total_h}"}
          class="w-full mt-3 overflow-visible"
          aria-hidden="true"
        >
          <%!-- gridlines — only for 0 tick, targets get their own labels --%>
          <%= for tick <- @y_ticks, tick == 0 do %>
            <% gy = @to_y.(tick * 1.0) %>
            <line x1={@y_axis_w} y1={gy} x2={@chart_w} y2={gy} stroke="#1E2535" stroke-width="0.5" />
            <text x={@y_axis_w - 4} y={gy + 3} text-anchor="end" font-size="8" fill="#3A4A5E">
              {tick}
            </text>
          <% end %>

          <%!-- 6-Count target line — label anchored to right end of line --%>
          <%= if @six_target do %>
            <% ty = @to_y.(@six_target * 1.0) %>
            <line
              x1={@y_axis_w}
              y1={ty}
              x2={@chart_w}
              y2={ty}
              stroke="#4A9EFF"
              stroke-width="0.75"
              stroke-dasharray="4,3"
              opacity="0.4"
            />
            <text x={@chart_w} y={ty - 2} text-anchor="end" font-size="7" fill="#4A9EFF" opacity="0.7">
              {@six_target}
            </text>
          <% end %>

          <%!-- Navy SEAL target line — label anchored to right end of line --%>
          <%= if @seal_target do %>
            <% ty = @to_y.(@seal_target * 1.0) %>
            <line
              x1={@y_axis_w}
              y1={ty}
              x2={@chart_w}
              y2={ty}
              stroke="#F97316"
              stroke-width="0.75"
              stroke-dasharray="4,3"
              opacity="0.4"
            />
            <text x={@chart_w} y={ty - 2} text-anchor="end" font-size="7" fill="#F97316" opacity="0.7">
              {@seal_target}
            </text>
          <% end %>

          <%!-- 6-Count line + dots --%>
          <%= if length(@six_points) > 1 do %>
            <polyline
              points={@six_polyline}
              fill="none"
              stroke="#4A9EFF"
              stroke-width="1.5"
              stroke-linejoin="round"
            />
          <% end %>
          <%= for p <- @six_points do %>
            <circle cx={@to_x.(p.iso_week)} cy={@to_y.(p.reps * 1.0)} r="2.5" fill="#4A9EFF" />
          <% end %>

          <%!-- Navy SEAL line + dots --%>
          <%= if length(@seal_points) > 1 do %>
            <polyline
              points={@seal_polyline}
              fill="none"
              stroke="#F97316"
              stroke-width="1.5"
              stroke-linejoin="round"
            />
          <% end %>
          <%= for p <- @seal_points do %>
            <circle cx={@to_x.(p.iso_week)} cy={@to_y.(p.reps * 1.0)} r="2.5" fill="#F97316" />
          <% end %>

          <%!-- x-axis week labels --%>
          <%= for w <- @x_label_weeks do %>
            <text
              x={@to_x.(w)}
              y={@top_pad + @plot_h + 14}
              text-anchor="middle"
              font-size="8"
              fill="#3A4A5E"
            >
              W{w}
            </text>
          <% end %>
        </svg>
      <% end %>
    </div>
    """
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
