defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Levels, Scoring, Streak, Workouts}
  alias BurpeeTrainer.Stats.Series
  alias BurpeeTrainer.Streak.State
  alias BurpeeTrainerWeb.Fmt

  embed_templates("stats_live/*")

  @page_size 5
  @period_options [{"7d", "7d"}, {"30d", "30d"}, {"90d", "90d"}, {"All", "all"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       goal_modal_type: nil,
       goal_baseline_session: nil,
       sessions_visible_count: @page_size
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = decode_period(params["period"])
    {:noreply, assign_stats(socket, period, @page_size)}
  end

  defp assign_stats(socket, period, visible_count) do
    user = socket.assigns.current_user
    today = Date.utc_today()
    all_sessions = Workouts.list_sessions(user)
    {detailed_sessions, _has_more} = Workouts.list_sessions_page(user, 5_000)
    period_start = period_start_date(period, today)
    period_sessions = filter_sessions(all_sessions, period_start)
    period_detailed_sessions = filter_sessions(detailed_sessions, period_start)
    goals = Goals.list_current_goals(user)
    all_six_sessions = Workouts.list_sessions_for_chart(user, :six_count)
    all_seal_sessions = Workouts.list_sessions_for_chart(user, :navy_seal)

    socket
    |> assign(:streak, Streak.compute(user, today))
    |> assign(:today, today)
    |> assign(:period, period)
    |> assign(:period_label, period_label(period))
    |> assign(:period_options, @period_options)
    |> assign(:period_start, period_start)
    |> assign(:period_pushups, Scoring.total_pushups(period_sessions))
    |> assign(:all_time_pushups, Scoring.total_pushups(all_sessions))
    |> assign(:goals, goals)
    |> assign(:sessions_visible_count, visible_count)
    |> assign_period_sessions(period_detailed_sessions, visible_count)
    |> assign(:goal_modal_type, socket.assigns[:goal_modal_type])
    |> assign(:goal_baseline_session, socket.assigns[:goal_baseline_session])
    |> assign(:weekly_data, Workouts.weekly_minutes(user) |> filter_weekly_data(period_start))
    |> assign(:six_count_sessions, all_six_sessions |> filter_sessions(period_start))
    |> assign(:navy_seal_sessions, all_seal_sessions |> filter_sessions(period_start))
    |> assign(:six_has_sessions, all_six_sessions != [])
    |> assign(:seal_has_sessions, all_seal_sessions != [])
    |> compute_goal_progress(user, goals)
    |> assign_gamification(all_sessions, today)
  end

  defp assign_period_sessions(socket, period_detailed_sessions, visible_count) do
    assign(socket,
      period_detailed_sessions: period_detailed_sessions,
      sessions: Enum.take(period_detailed_sessions, visible_count),
      sessions_has_more: length(period_detailed_sessions) > visible_count
    )
  end

  # Push-up score, personal best, balance, and level-maintenance status.
  defp assign_gamification(socket, sessions, today) do
    week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Enum.filter(sessions, fn s ->
        Date.compare(
          DateTime.to_date(s.inserted_at) |> Date.beginning_of_week(:monday),
          week_start
        ) == :eq
      end)

    best_week_pushups =
      sessions
      |> Scoring.weekly_pushups()
      |> Enum.map(& &1.pushups)
      |> Enum.max(fn -> 0 end)

    socket
    |> assign(:level_status, Levels.level_status(sessions, today))
    |> assign(:week_balanced, Scoring.balanced_week?(this_week))
    |> assign(:best_week_pushups, best_week_pushups)
  end

  @impl true
  def handle_event("load_more_sessions", _, socket) do
    visible_count = socket.assigns.sessions_visible_count + @page_size

    {:noreply,
     socket
     |> assign(:sessions_visible_count, visible_count)
     |> assign_period_sessions(socket.assigns.period_detailed_sessions, visible_count)}
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
  def handle_info(:goal_saved, socket) do
    {:noreply,
     socket
     |> assign(:goal_modal_type, nil)
     |> assign(:goal_baseline_session, nil)
     |> assign_stats(socket.assigns.period, socket.assigns.sessions_visible_count)}
  end

  defp decode_period(period) when period in ["7d", "30d", "90d", "all"], do: period
  defp decode_period(_), do: "30d"

  defp period_start_date("7d", today), do: Date.add(today, -6)
  defp period_start_date("30d", today), do: Date.add(today, -29)
  defp period_start_date("90d", today), do: Date.add(today, -89)
  defp period_start_date("all", _today), do: nil

  defp period_label("7d"), do: "Last 7 days"
  defp period_label("30d"), do: "Last 30 days"
  defp period_label("90d"), do: "Last 90 days"
  defp period_label("all"), do: "All time"

  defp filter_sessions(sessions, nil), do: sessions

  defp filter_sessions(sessions, start_date) do
    Enum.filter(sessions, fn session ->
      Date.compare(DateTime.to_date(session.inserted_at), start_date) in [:gt, :eq]
    end)
  end

  defp filter_weekly_data(weekly_data, nil), do: weekly_data

  defp filter_weekly_data(weekly_data, start_date) do
    start_week = Date.beginning_of_week(start_date, :monday)

    Enum.filter(weekly_data, fn week ->
      Date.compare(week.week_start, start_week) in [:gt, :eq]
    end)
  end

  attr(:status, :map, required: true)

  defp at_risk_banner(assigns) do
    ~H"""
    <.qs_info_note
      :if={@status.at_risk?}
      title={"Level #{level_label(@status.level)} expires in #{@status.days_left}d"}
      icon="hero-exclamation-triangle"
      class="bg-[var(--session-track)]/40"
    >
      Do a six-count and a navy seal landmark this week to keep it.
    </.qs_info_note>
    """
  end

  attr(:streak, State, required: true)
  attr(:today, Date, required: true)
  attr(:current_level, :atom, default: nil)
  attr(:week_balanced, :boolean, default: false)

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    minutes_done = trunc(assigns.streak.current_week_minutes)
    pct = max(min(assigns.streak.current_week_minutes / 80 * 100, 100), 0)
    minutes_left = max(80 - minutes_done, 0)

    assigns =
      assign(assigns,
        week_days: Enum.map(0..6, &Date.add(week_start, &1)),
        minutes_done: minutes_done,
        minutes_left: minutes_left,
        progress_pct: pct
      )

    ~H"""
    <.qs_surface class="space-y-6 bg-[var(--session-surface)]/60 px-5 py-5">
      <div class="space-y-3">
        <div class="flex items-start justify-between gap-4">
          <div class="space-y-1">
            <p class="text-sm font-medium text-[var(--session-muted)]">This week</p>
            <p class="qs-tabular text-3xl font-semibold tracking-[-0.05em] text-[var(--session-ink)]">
              {@minutes_done} <span class="text-[var(--session-muted)]">/ 80 min</span>
            </p>
          </div>
          <div class="shrink-0 text-right">
            <p class="text-base font-medium tabular-nums text-[var(--session-ink)]">
              {@minutes_left} min left
            </p>
            <p :if={@current_level} class="mt-1 text-sm text-[var(--session-muted)]">
              Level {level_label(@current_level)}
            </p>
          </div>
        </div>
        <div class="h-1.5 overflow-hidden rounded-full bg-[var(--session-border)]">
          <div
            class="h-full rounded-full bg-[var(--session-progress)]"
            style={"width: #{@progress_pct}%"}
          />
        </div>
        <p class="text-sm text-[var(--session-muted)]">
          <%= if @streak.streak_weeks == 0 do %>
            No active streak
          <% else %>
            {@streak.streak_weeks} week streak
          <% end %>
        </p>
      </div>

      <div class="grid grid-cols-7 gap-2 text-center">
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
              "mx-auto block size-2 rounded-full",
              day in @streak.days_active_this_week && "bg-[var(--session-progress)]",
              day == @today && day not in @streak.days_active_this_week &&
                "ring-2 ring-[var(--session-muted)] ring-offset-2 ring-offset-[var(--session-bg)] bg-transparent",
              day > @today && "bg-[var(--session-track)]",
              day < @today && day not in @streak.days_active_this_week &&
                "bg-[var(--session-track)]"
            ]} />
          </div>
        <% end %>
      </div>

      <.qs_property_tag :if={@week_balanced} class="gap-1 w-fit">
        <.icon name="hero-scale" class="size-2.5" /> Balanced week
      </.qs_property_tag>

      <%= if @streak.streak_weeks == 0 && @streak.previous_best_weeks > 0 do %>
        <p class="text-xs text-[var(--session-muted)]">
          Previous best: {@streak.previous_best_weeks} weeks
        </p>
      <% end %>
    </.qs_surface>
    """
  end

  attr(:period, :string, required: true)
  attr(:period_options, :list, required: true)

  defp period_selector(assigns) do
    ~H"""
    <div id="stats-period-selector" class="space-y-2">
      <p class="text-sm font-medium text-[var(--session-muted)]">Period</p>
      <div class="grid grid-cols-4 overflow-hidden rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/45">
        <.link
          :for={{label, value} <- @period_options}
          patch={~p"/stats?period=#{value}"}
          class={[
            "border-r border-[var(--session-border)] px-3 py-2 text-center text-sm font-medium transition last:border-r-0",
            @period == value &&
              "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
            @period != value &&
              "text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          ]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  attr(:period_label, :string, required: true)
  attr(:period_pushups, :integer, required: true)
  attr(:all_time_pushups, :integer, required: true)
  attr(:best_week_pushups, :integer, required: true)

  defp pushups_section(assigns) do
    ~H"""
    <.qs_surface id="stats-pushups-card" class="space-y-4 bg-[var(--session-surface)]/60 px-5 py-5">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="text-sm font-medium text-[var(--session-muted)]">Push-ups</p>
          <p class="mt-1 text-xs text-[var(--session-muted)]">Six-count = 1, Navy SEAL = 3</p>
        </div>
        <.qs_property_tag>{@period_label}</.qs_property_tag>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div>
          <p class="text-xs text-[var(--session-muted)]">This period</p>
          <p
            id="stats-pushups-period"
            class="qs-tabular mt-1 text-3xl font-semibold tracking-[-0.05em] tabular-nums text-[var(--session-ink)]"
          >
            {@period_pushups}
          </p>
        </div>
        <div>
          <p class="text-xs text-[var(--session-muted)]">All time</p>
          <p
            id="stats-pushups-all-time"
            class="qs-tabular mt-1 text-3xl font-semibold tracking-[-0.05em] tabular-nums text-[var(--session-ink)]"
          >
            {@all_time_pushups}
          </p>
        </div>
      </div>
      <p :if={@best_week_pushups > 0} class="text-xs text-[var(--session-muted)]">
        Best week: {@best_week_pushups} push-ups
      </p>
    </.qs_surface>
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
      <p class="text-sm font-medium text-[var(--session-muted)]">Goals</p>
      <div class="grid grid-cols-2 gap-3">
        <.goal_slot
          burpee_type={:six_count}
          label="6-Count"
          goal={@six}
          progress={@six_progress}
          has_sessions={@six_has_sessions}
        />
        <.goal_slot
          burpee_type={:navy_seal}
          label="Navy SEAL"
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
    <.qs_surface class="flex flex-col gap-3 bg-[var(--session-surface)]/60 px-4 py-4">
      <%= cond do %>
        <% @goal && @goal.status == :achieved -> %>
          <p class="text-sm font-medium text-[var(--session-muted)]">{@label}</p>
          <div class="flex items-baseline gap-1.5 tabular-nums">
            <span class="text-2xl font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
              {@goal.burpee_count_target}
            </span>
            <span class="text-xs text-[var(--session-muted)]">reps</span>
          </div>
          <.qs_property_tag class="gap-1 w-fit">
            <.icon name="hero-trophy" class="size-2.5 shrink-0" />
            Reached {Calendar.strftime(DateTime.to_date(@goal.updated_at), "%-d %b %Y")}
          </.qs_property_tag>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="mt-auto w-full rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 py-2 text-center text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
          >
            Set new goal
          </button>
        <% @goal && @goal.status == :active -> %>
          <div class="flex items-start justify-between gap-2">
            <p class="text-sm font-medium text-[var(--session-muted)]">{@label}</p>
            <%= if @weekly_pace && @days_left > 0 do %>
              <.qs_property_tag class="shrink-0 tabular-nums">
                ~{@weekly_pace}/wk
              </.qs_property_tag>
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
          <div class="h-1.5 overflow-hidden rounded-full bg-[var(--session-track)]">
            <div
              class="h-full rounded-full bg-[var(--session-progress)] transition-all duration-500"
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
            class="mt-auto w-full rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 py-2 text-center text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
          >
            Update goal
          </button>
        <% @has_sessions -> %>
          <p class="text-sm font-medium text-[var(--session-muted)]">{@label}</p>
          <p class="text-sm text-[var(--session-muted)]">No goal set</p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="mt-auto w-full rounded-md border border-[var(--session-border)] bg-[var(--session-bg)]/55 py-2 text-center text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-track)]/70"
          >
            Set goal
          </button>
        <% true -> %>
          <p class="text-sm font-medium text-[var(--session-muted)]">{@label}</p>
          <p class="text-sm text-[var(--session-muted)]">No sessions yet</p>
          <p class="text-xs text-[var(--session-muted)] opacity-70">Log a session first</p>
      <% end %>
    </.qs_surface>
    """
  end

  attr(:sessions, :list, required: true)
  attr(:has_more, :boolean, required: true)
  attr(:period_label, :string, required: true)

  defp sessions_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-end justify-between gap-4">
        <p class="text-sm font-medium text-[var(--session-muted)]">
          Recent sessions
        </p>
        <p class="text-xs text-[var(--session-muted)]">{@period_label}</p>
      </div>
      <%= if @sessions == [] do %>
        <.qs_surface class="bg-[var(--session-surface)]/45 px-5 py-8 text-center">
          <p class="text-sm text-[var(--session-muted)]">No sessions yet.</p>
        </.qs_surface>
      <% else %>
        <.qs_surface class="overflow-hidden bg-[var(--session-surface)]/45">
          <div class="grid grid-cols-[3.75rem_4rem_1fr_4.25rem] gap-3 border-b border-[var(--session-border)] px-4 py-2 text-xs font-medium text-[var(--session-muted)]">
            <span>Reps</span>
            <span>Duration</span>
            <span>Style & tags</span>
            <span class="text-right">Date</span>
          </div>
          <div class="divide-y divide-[var(--session-border)]">
            <%= for session <- @sessions do %>
              <.session_row session={session} />
            <% end %>
          </div>
          <%= if @has_more do %>
            <button
              phx-click="load_more_sessions"
              class="w-full border-t border-[var(--session-border)] py-3 text-sm font-medium text-[var(--session-ink)] transition hover:bg-[var(--session-bg)]/45"
            >
              Load more
            </button>
          <% end %>
        </.qs_surface>
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

    assigns =
      assign(assigns,
        date_str: date_str,
        capture_badge: capture_badge(assigns.session),
        session_tags: session_tags(assigns.session)
      )

    ~H"""
    <div class="relative grid grid-cols-[3.75rem_4rem_1fr_4.25rem] items-start gap-3 px-4 py-3 transition hover:bg-[var(--session-bg)]/45">
      <.link
        :if={@capture_badge && @capture_badge.label == "Tracked"}
        navigate={~p"/stats/sessions/#{@session.id}"}
        class="absolute inset-0"
        aria-label="Open session analysis"
      >
        <span class="sr-only">Open session analysis</span>
      </.link>

      <p class="text-lg font-semibold leading-none tabular-nums text-[var(--session-ink)]">
        {if @session.burpee_count_actual, do: @session.burpee_count_actual, else: "—"}
      </p>

      <p class="text-sm tabular-nums text-[var(--session-muted)]">
        {Fmt.duration_sec(@session.duration_sec_actual)}
      </p>

      <div class="min-w-0 space-y-1.5">
        <div class="flex min-w-0 items-center gap-2">
          <span class="text-sm font-medium text-[var(--session-ink)]">
            {Fmt.burpee_type(@session.burpee_type)}
          </span>
          <span :if={@session.plan} class="truncate text-xs text-[var(--session-muted)]">
            {@session.plan.name}
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-1.5">
          <.qs_property_tag :for={tag <- @session_tags} tone={tag.tone} class="gap-1">
            <.icon :if={tag[:icon]} name={tag.icon} class="size-2.5" />
            {tag.label}
          </.qs_property_tag>
          <span
            :if={@capture_badge && @capture_badge.detail}
            class="text-xs text-[var(--session-muted)]"
          >
            {@capture_badge.detail}
          </span>
        </div>
      </div>

      <span class="shrink-0 pt-0.5 text-right text-xs text-[var(--session-muted)]">
        {@date_str}
      </span>
    </div>
    """
  end

  defp capture_badge(%{capture_mode: :tracked, pace_consistency: consistency})
       when is_float(consistency) do
    %{label: "Tracked", detail: "#{round(consistency * 100)}% consistent"}
  end

  defp capture_badge(%{capture_mode: :tracked}), do: %{label: "Tracked", detail: nil}
  defp capture_badge(%{capture_mode: :timed}), do: %{label: "Plan", detail: nil}
  defp capture_badge(%{capture_mode: :logged}), do: %{label: "Manual", detail: nil}
  defp capture_badge(_), do: nil

  defp session_tags(session) do
    base =
      []
      |> maybe_add_tag(session.goal, %{label: "Goal reached", tone: "tag", icon: "hero-trophy"})
      |> maybe_add_tag(session.plan == nil, %{
        label: "Manual",
        tone: "neutral",
        icon: "hero-pencil-square"
      })
      |> maybe_add_tag(session.capture_mode == :tracked, %{
        label: "Tracked",
        tone: "info",
        icon: "hero-camera"
      })
      |> maybe_add_tag(session.capture_mode == :timed, %{
        label: "Plan",
        tone: "neutral",
        icon: "hero-clock"
      })

    session.tags
    |> split_tags()
    |> Enum.reduce(base, fn tag, acc ->
      [%{label: tag_label(tag), tone: if(tag == "video", do: "info", else: "tag")} | acc]
    end)
    |> Enum.reverse()
  end

  defp maybe_add_tag(tags, nil, _tag), do: tags
  defp maybe_add_tag(tags, false, _tag), do: tags
  defp maybe_add_tag(tags, _present, tag), do: [tag | tags]

  defp split_tags(nil), do: []
  defp split_tags(""), do: []
  defp split_tags(tags), do: tags |> String.split(",", trim: true)

  defp tag_label(tag), do: tag |> String.replace("_", " ") |> String.capitalize()

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
      <p class="text-sm font-medium text-[var(--session-muted)]">
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
