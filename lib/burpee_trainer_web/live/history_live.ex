defmodule BurpeeTrainerWeb.HistoryLive do
  @moduledoc """
  Session history — stat row, interactive chart, compact session feed.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Levels, Progression, Workouts}
  alias BurpeeTrainerWeb.Fmt

  @series_colors %{
    six_count: %{solid: "rgb(74, 158, 255)", faint: "rgba(74, 158, 255, 0.08)"},
    navy_seal: %{solid: "rgb(249, 115, 22)", faint: "rgba(249, 115, 22, 0.08)"}
  }

  @preview_count 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    sessions = Workouts.list_sessions(user)
    active_goals = Goals.list_active_goals(user)

    level_unlocks =
      sessions
      |> Levels.landmark_history()
      |> Enum.group_by(& &1.session_id)
      |> Map.new(fn {session_id, unlocks} ->
        highest = Enum.max_by(unlocks, &history_level_index(&1.level))
        {session_id, highest}
      end)

    {:ok,
     socket
     |> assign(:sessions, sessions)
     |> assign(:prs, compute_prs(sessions, :six_count))
     |> assign(:level_unlocks, level_unlocks)
     |> assign(:active_goals, active_goals)
     |> assign(:chart_series, :six_count)
     |> assign(:chart_range, :month6)
     |> assign(:show_all, false)
     |> push_chart(sessions, active_goals, :six_count, :month6)}
  end

  @impl true
  def handle_event("set_series", %{"series" => series}, socket) do
    series = String.to_existing_atom(series)

    {:noreply,
     socket
     |> assign(:chart_series, series)
     |> assign(:prs, compute_prs(socket.assigns.sessions, series))
     |> push_chart(socket.assigns.sessions, socket.assigns.active_goals, series, socket.assigns.chart_range)}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    range = String.to_existing_atom(range)

    {:noreply,
     socket
     |> assign(:chart_range, range)
     |> push_chart(socket.assigns.sessions, socket.assigns.active_goals, socket.assigns.chart_series, range)}
  end

  @impl true
  def handle_event("toggle_all", _params, socket) do
    {:noreply, assign(socket, :show_all, !socket.assigns.show_all)}
  end

  defp push_chart(socket, sessions, active_goals, series, range) do
    user = socket.assigns.current_user
    chart = build_chart(sessions, active_goals, user, series, range)
    assign(socket, :chart, chart)
  end

  defp filter_by_range(sessions, :all), do: sessions

  defp filter_by_range(sessions, range) do
    days =
      case range do
        :week4 -> 28
        :month3 -> 90
        :month6 -> 182
        :year1 -> 365
      end

    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    Enum.filter(sessions, &(DateTime.compare(&1.inserted_at, cutoff) != :lt))
  end

  defp build_chart(sessions, active_goals, user, series_type, range) do
    filtered = filter_by_range(sessions, range)
    datasets = [
      build_main_dataset(series_type, filtered),
      build_goal_dataset(series_type, active_goals),
      build_trend_dataset(series_type, user, filtered)
    ] |> Enum.reject(&is_nil/1)

    %{datasets: datasets}
  end

  defp build_main_dataset(type, sessions) do
    points =
      sessions
      |> Enum.filter(&(&1.burpee_type == type))
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.map(fn s -> %{x: DateTime.to_date(s.inserted_at), y: s.burpee_count_actual} end)

    colors = Map.fetch!(@series_colors, type)

    %{
      label: Fmt.burpee_type(type),
      data: points,
      borderColor: colors.solid,
      backgroundColor: colors.faint,
      tension: 0.3,
      pointRadius: 4,
      pointBackgroundColor: colors.solid,
      borderWidth: 2
    }
  end

  defp build_goal_dataset(type, active_goals) do
    case Enum.find(active_goals, &(&1.burpee_type == type)) do
      nil -> nil
      goal ->
        colors = Map.fetch!(@series_colors, type)
        %{
          label: "Goal",
          data: [
            %{x: goal.date_baseline, y: goal.burpee_count_baseline},
            %{x: goal.date_target, y: goal.burpee_count_target}
          ],
          borderColor: colors.solid,
          borderDash: [6, 4],
          pointRadius: 0,
          borderWidth: 1
        }
    end
  end

  defp build_trend_dataset(type, user, sessions) do
    typed = Enum.filter(sessions, &(&1.burpee_type == type))
    if length(typed) >= 2 do
      recent = Workouts.list_recent_sessions(user, type, 4)
      case Progression.project_trend(recent) do
        [] -> nil
        points ->
          colors = Map.fetch!(@series_colors, type)
          %{
            label: "Trend",
            data: Enum.map(points, fn {date, count} -> %{x: date, y: count} end),
            borderColor: colors.solid,
            borderDash: [2, 2],
            pointRadius: 0,
            borderWidth: 1,
            fill: false
          }
      end
    end
  end

  defp compute_prs(sessions, type) do
    typed =
      sessions
      |> Enum.filter(&(&1.burpee_type == type))
      |> Enum.reject(&((&1.tags || "") =~ "warmup"))

    if typed == [], do: nil, else: do_compute_prs(typed)
  end

  defp do_compute_prs(sessions) do
    burpees_max = Enum.max_by(sessions, & &1.burpee_count_actual)
    duration_max = Enum.max_by(sessions, & &1.duration_sec_actual)

    rate_best =
      sessions
      |> Enum.filter(&(&1.duration_sec_actual > 0))
      |> case do
        [] -> nil
        rated -> Enum.max_by(rated, &(&1.burpee_count_actual / &1.duration_sec_actual))
      end

    %{burpees_max: burpees_max, duration_max: duration_max, rate_best: rate_best}
  end

  @impl true
  def render(assigns) do
    visible_sessions =
      if assigns.show_all,
        do: assigns.sessions,
        else: Enum.take(assigns.sessions, @preview_count)

    assigns = assign(assigns, :visible_sessions, visible_sessions)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight text-base-content">History</h1>
          <p class="mt-0.5 text-sm text-base-content/40">Your sessions over time.</p>
        </div>
        <.link
          navigate={~p"/log"}
          class="text-sm text-primary hover:text-primary/80 transition-colors font-medium"
        >
          + Log session
        </.link>
      </div>

      <%= if @sessions == [] do %>
        <.empty_state />
      <% else %>
        <.stats_row prs={@prs} chart_series={@chart_series} />
        <.chart_card chart={@chart} chart_series={@chart_series} chart_range={@chart_range} />
        <.sessions_card
          sessions={@visible_sessions}
          all_sessions={@sessions}
          level_unlocks={@level_unlocks}
          show_all={@show_all}
        />
      <% end %>
    </div>
    </Layouts.app>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-dashed border-[#1E2535] bg-base-200 p-12 text-center space-y-4">
      <p class="text-sm text-base-content/40">No sessions yet.</p>
      <p class="text-xs text-base-content/30">Run a plan or log a session to see your history here.</p>
      <.link
        navigate={~p"/log"}
        class="inline-flex items-center gap-1.5 text-sm text-primary hover:text-primary/80 transition-colors"
      >
        <.icon name="hero-plus" class="size-3.5" /> Log a session
      </.link>
    </div>
    """
  end

  attr :prs, :any, required: true
  attr :chart_series, :atom, required: true

  defp stats_row(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 overflow-hidden">
      <div class="px-5 py-2.5 border-b border-[#1E2535]">
        <span class="text-[11px] uppercase tracking-wide text-base-content/40">
          {Fmt.burpee_type(@chart_series)} bests
        </span>
      </div>
      <div class="grid grid-cols-3 divide-x divide-[#1E2535]">
      <%= if @prs do %>
        <.stat_cell
          icon="hero-arrow-trending-up"
          label="Most burpees"
          value={to_string(@prs.burpees_max.burpee_count_actual)}
          sub={Calendar.strftime(@prs.burpees_max.inserted_at, "%b %-d, %Y")}
        />
        <.stat_cell
          icon="hero-clock"
          label="Longest session"
          value={Fmt.duration_sec(@prs.duration_max.duration_sec_actual)}
          sub={Calendar.strftime(@prs.duration_max.inserted_at, "%b %-d, %Y")}
        />
        <%= if @prs.rate_best do %>
          <.stat_cell
            icon="hero-bolt"
            label="Best rate"
            value={:erlang.float_to_binary(@prs.rate_best.burpee_count_actual / @prs.rate_best.duration_sec_actual * 60, decimals: 1)}
            sub="burpees / min"
          />
        <% else %>
          <.stat_cell icon="hero-bolt" label="Best rate" value="—" sub="" />
        <% end %>
      <% else %>
        <.stat_cell icon="hero-arrow-trending-up" label="Most burpees" value="—" sub="" />
        <.stat_cell icon="hero-clock" label="Longest session" value="—" sub="" />
        <.stat_cell icon="hero-bolt" label="Best rate" value="—" sub="" />
      <% end %>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, required: true

  defp stat_cell(assigns) do
    ~H"""
    <div class="p-5 flex flex-col gap-1 min-w-0">
      <.icon name={@icon} class="size-4 text-primary shrink-0" />
      <p class="mt-2 text-[11px] uppercase tracking-wide text-base-content/40">{@label}</p>
      <p class="text-[26px] font-semibold leading-none tracking-tight text-base-content">{@value}</p>
      <p class="text-[11px] text-base-content/30">{@sub}</p>
    </div>
    """
  end

  attr :chart, :map, required: true
  attr :chart_series, :atom, required: true
  attr :chart_range, :atom, required: true

  defp chart_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 overflow-hidden">
      <div class="flex items-center justify-between px-5 py-4 border-b border-[#1E2535]">
        <h2 class="text-sm font-medium text-base-content">Burpees over time</h2>
        <div class="flex items-center gap-1">
          <.series_btn series={:six_count} active={@chart_series == :six_count} label="6-count" />
          <.series_btn series={:navy_seal} active={@chart_series == :navy_seal} label="Navy Seal" />
        </div>
      </div>

      <div class="px-5 pt-4 pb-2 h-56">
        <canvas
          id="history-chart"
          phx-hook="ChartHook"
          data-chart={Jason.encode!(@chart)}
        >
        </canvas>
      </div>

      <div class="flex items-center justify-center gap-1 px-5 py-3 border-t border-[#1E2535]">
        <.range_btn range={:week4} active={@chart_range == :week4} label="4W" />
        <.range_btn range={:month3} active={@chart_range == :month3} label="3M" />
        <.range_btn range={:month6} active={@chart_range == :month6} label="6M" />
        <.range_btn range={:year1} active={@chart_range == :year1} label="1Y" />
        <.range_btn range={:all} active={@chart_range == :all} label="All" />
      </div>
    </div>
    """
  end

  attr :series, :atom, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true

  defp series_btn(assigns) do
    ~H"""
    <button
      phx-click="set_series"
      phx-value-series={@series}
      class={[
        "px-2.5 py-1 rounded-md text-xs transition-colors",
        @active && "bg-primary/15 text-primary font-medium",
        !@active && "text-base-content/40 hover:text-base-content/70"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :range, :atom, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true

  defp range_btn(assigns) do
    ~H"""
    <button
      phx-click="set_range"
      phx-value-range={@range}
      class={[
        "px-3 py-1 rounded text-xs transition-colors",
        @active && "bg-base-300 text-base-content font-medium",
        !@active && "text-base-content/40 hover:text-base-content/60"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :sessions, :list, required: true
  attr :all_sessions, :list, required: true
  attr :level_unlocks, :map, required: true
  attr :show_all, :boolean, required: true

  defp sessions_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 overflow-hidden">
      <div class="px-5 py-4 border-b border-[#1E2535]">
        <h2 class="text-sm font-medium text-base-content">Recent sessions</h2>
      </div>

      <ul class="divide-y divide-[#1E2535]">
        <%= for session <- @sessions do %>
          <.session_row session={session} unlock={Map.get(@level_unlocks, session.id)} />
        <% end %>
      </ul>

      <%= if length(@all_sessions) > 5 do %>
        <button
          phx-click="toggle_all"
          class="flex items-center justify-between w-full px-5 py-3.5 border-t border-[#1E2535] text-sm text-base-content/40 hover:text-base-content/70 transition-colors"
        >
          <span>{if @show_all, do: "Show less", else: "View all sessions"}</span>
          <.icon name="hero-chevron-right" class={["size-4 transition-transform", @show_all && "rotate-90"]} />
        </button>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :unlock, :any, required: true

  defp session_row(assigns) do
    ~H"""
    <li class="flex items-center gap-4 px-5 py-3.5 hover:bg-base-300/50 transition-colors">
      <div class="flex-1 min-w-0 space-y-0.5">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-base-content">
            {Calendar.strftime(@session.inserted_at, "%b %-d, %Y")}
          </span>
          <%= if @unlock do %>
            <span class="inline-flex items-center rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary">
              Level {history_level_label(@unlock.level)}
            </span>
          <% end %>
        </div>
        <p class="text-xs text-base-content/40">
          {Fmt.burpee_type(@session.burpee_type)}
          <%= if plan_label(@session) do %>
            · {plan_label(@session)}
          <% end %>
        </p>
      </div>

      <div class="flex items-center gap-4 shrink-0">
        <span class="text-sm font-medium text-base-content tabular-nums">
          {@session.burpee_count_actual} burpees
        </span>
        <span class="text-sm text-base-content/40 tabular-nums">
          {Fmt.duration_sec(@session.duration_sec_actual)}
        </span>
        <.icon name="hero-chevron-right" class="size-4 text-base-content/20" />
      </div>
    </li>
    """
  end

  defp plan_label(%{style_name: s}) when not is_nil(s), do: s |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp plan_label(_), do: nil

  @level_order [:level_1a, :level_1b, :level_1c, :level_1d, :level_2, :level_3, :level_4, :graduated]
  defp history_level_index(level), do: Enum.find_index(@level_order, &(&1 == level)) || 0

  defp history_level_label(:graduated), do: "Grad"
  defp history_level_label(l), do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()
end
