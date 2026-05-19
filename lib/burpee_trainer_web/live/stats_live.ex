defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Streak, Workouts}
  alias BurpeeTrainer.Streak.State
  alias BurpeeTrainerWeb.Fmt

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    today = Date.utc_today()
    {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

    {:ok,
     socket
     |> assign(:streak, Streak.compute(user, today))
     |> assign(:today, today)
     |> assign(:goals, Goals.list_active_goals(user))
     |> assign(:sessions, sessions)
     |> assign(:sessions_has_more, has_more)
     |> assign(:show_more_trends, false)
     |> assign(:log_modal_open, false)
     |> assign(:weekly_data, Workouts.weekly_minutes(user))}
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

  def handle_event("toggle_trends", _, socket) do
    {:noreply, update(socket, :show_more_trends, &(!&1))}
  end

  @impl true
  def handle_info(:session_saved, socket) do
    user = socket.assigns.current_user
    today = socket.assigns.today
    {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

    {:noreply,
     socket
     |> assign(:log_modal_open, false)
     |> assign(:streak, Streak.compute(user, today))
     |> assign(:sessions, sessions)
     |> assign(:sessions_has_more, has_more)
     |> assign(:weekly_data, Workouts.weekly_minutes(user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <div class="space-y-5 pb-20">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Stats</h1>
          <p class="text-sm text-base-content/60">How you're tracking.</p>
        </div>

        <.streak_card streak={@streak} today={@today} />
        <.goals_section goals={@goals} />
        <.trends_section weekly_data={@weekly_data} show_more={@show_more_trends} />
        <.sessions_section sessions={@sessions} has_more={@sessions_has_more} />
      </div>

      <%!-- FAB --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-6 z-40">
        <button
          type="button"
          phx-click="open_log_modal"
          class="w-10 h-10 rounded-full bg-[#141B26] border border-[#1E2535] text-[#4A9EFF] flex items-center justify-center hover:bg-[#1E2535] transition"
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
          phx-click="close_log_modal"
        >
          <div
            class="w-full sm:max-w-md bg-[#0D1017] border border-[#1E2535] rounded-t-2xl sm:rounded-2xl p-6"
            phx-click-away="close_log_modal"
            phx-click.stop
          >
            <.live_component
              module={BurpeeTrainerWeb.LogFormComponent}
              id="log-form"
              current_user={@current_user}
              on_save={:session_saved}
            />
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :streak, State, required: true
  attr :today, Date, required: true

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    assigns = assign(assigns, :week_days, Enum.map(0..6, &Date.add(week_start, &1)))

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-5 space-y-4">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">THIS WEEK</p>

      <div class="flex items-baseline justify-between">
        <div class="tabular-nums">
          <span class="text-3xl font-semibold">{trunc(@streak.current_week_minutes)}</span>
          <span class="text-base-content/50 text-sm ml-1">/ 80 min</span>
        </div>
        <div class="text-sm text-base-content/60">
          <%= if @streak.streak_weeks == 0 do %>
            No active streak
          <% else %>
            {@streak.streak_weeks} week streak
          <% end %>
        </div>
      </div>

      <div class="h-2 rounded-full bg-[#1E2535] overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-500",
            @streak.current_week_minutes >= 80 && "bg-primary",
            @streak.current_week_minutes < 80 && @streak.on_pace? && "bg-primary/70",
            !@streak.on_pace? && "bg-base-content/20"
          ]}
          style={"width: #{min(@streak.current_week_minutes / 80 * 100, 100)}%"}
        />
      </div>

      <div class="flex justify-between">
        <%= for day <- @week_days do %>
          <div class="flex flex-col items-center gap-1">
            <span class="text-[10px] text-base-content/30">
              {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
            </span>
            <div class={[
              "w-2 h-2 rounded-full",
              day in @streak.days_active_this_week && "bg-primary",
              day == @today && day not in @streak.days_active_this_week && "border border-primary",
              day > @today && "bg-[#1E2535]",
              day < @today && day not in @streak.days_active_this_week && "bg-[#1E2535]"
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

  defp goals_section(assigns) do
    assigns =
      assigns
      |> assign(:six, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
      |> assign(:seal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <.goal_slot burpee_type={:six_count} label="6-COUNT" goal={@six} />
      <.goal_slot burpee_type={:navy_seal} label="NAVY SEAL" goal={@seal} />
    </div>
    """
  end

  attr :burpee_type, :atom, required: true
  attr :label, :string, required: true
  attr :goal, :any, required: true

  defp goal_slot(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
      <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/40">{@label}</p>
      <%= if @goal do %>
        <div class="space-y-1">
          <p class="text-sm font-medium">{@goal.burpee_count_target} burpees</p>
          <p class="text-xs text-base-content/50">
            by {Calendar.strftime(@goal.date_target, "%-d %b")}
          </p>
        </div>
      <% else %>
        <div class="space-y-2">
          <p class="text-xs text-base-content/50">No goal set</p>
          <.link navigate={~p"/stats"} class="text-xs text-primary hover:underline">Set goal</.link>
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
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">Sessions</h2>

      <%= if @sessions == [] do %>
        <p class="text-sm text-base-content/40">No sessions yet.</p>
      <% else %>
        <div class="space-y-2">
          <%= for session <- @sessions do %>
            <.session_row session={session} />
          <% end %>
        </div>

        <%= if @has_more do %>
          <button
            phx-click="load_more_sessions"
            class="w-full py-2 text-xs text-base-content/40 hover:text-base-content/70 transition"
          >
            Load more
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :session, :any, required: true

  defp session_row(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 px-4 py-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 space-y-1">
          <p class="text-sm font-semibold leading-snug truncate">
            <%= if @session.plan do %>
              {@session.plan.name}
            <% else %>
              <span class="text-base-content/50">Logged manually</span>
            <% end %>
          </p>
          <p class="text-xs text-base-content/50 tabular-nums">
            <%= if @session.burpee_count_actual do %>
              {@session.burpee_count_actual} burpees ·
            <% end %>
            {Fmt.duration_sec(@session.duration_sec_actual)}
          </p>
          <p class="text-xs text-base-content/30">{Fmt.burpee_type(@session.burpee_type)}</p>
        </div>
        <span class="text-xs text-base-content/30 shrink-0 pt-0.5">
          {Calendar.strftime(DateTime.to_date(@session.inserted_at), "%-d %b")}
        </span>
      </div>
    </div>
    """
  end

  attr :weekly_data, :list, required: true
  attr :show_more, :boolean, required: true

  defp trends_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">Trends</h2>
        <button phx-click="toggle_trends" class="text-xs text-primary hover:underline">
          {if @show_more, do: "Show less", else: "Show more"}
        </button>
      </div>

      <.weekly_minutes_chart weekly_data={@weekly_data} />

      <%= if @show_more do %>
        <.volume_chart weekly_data={@weekly_data} />
      <% end %>
    </div>
    """
  end

  attr :weekly_data, :list, required: true

  defp weekly_minutes_chart(assigns) do
    # Show last 12 weeks, oldest first for left-to-right time order
    chart_weeks = assigns.weekly_data |> Enum.take(12) |> Enum.reverse()
    assigns = assign(assigns, :chart_weeks, chart_weeks)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">Weekly minutes</p>
      <svg viewBox="0 0 300 80" class="w-full" aria-hidden="true">
        <%= for {week, i} <- Enum.with_index(@chart_weeks) do %>
          <% bar_w = 18
          gap = 7
          x = i * (bar_w + gap)
          max_m = 120
          height = max(min(week.minutes / max_m * 70, 70), 1)
          y = 75 - height
          color = if week.met_goal, do: "#4A9EFF", else: "#2A3A4E" %>
          <rect x={x} y={y} width={bar_w} height={height} fill={color} rx="2" />
        <% end %>
        <line
          x1="0"
          y1={75 - 80 / 120 * 70}
          x2="300"
          y2={75 - 80 / 120 * 70}
          stroke="#3A4A5E"
          stroke-width="0.5"
          stroke-dasharray="3,3"
        />
      </svg>
    </div>
    """
  end

  attr :weekly_data, :list, required: true

  defp volume_chart(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-2 uppercase tracking-wide">Volume over time</p>
      <p class="text-xs text-base-content/30 italic">Per-type breakdown coming in a follow-up.</p>
    </div>
    """
  end
end
