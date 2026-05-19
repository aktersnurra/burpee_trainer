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
     |> assign(:goals, Goals.list_active_goals(user))
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

    {:noreply,
     socket
     |> assign(:log_modal_open, false)
     |> assign(:streak, Streak.compute(user, today))
     |> assign(:sessions, sessions)
     |> assign(:sessions_has_more, has_more)
     |> assign(:weekly_data, Workouts.weekly_minutes(user))
     |> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
     |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))}
  end

  def handle_info(:goal_saved, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:goal_modal_type, nil)
     |> assign(:goal_baseline_session, nil)
     |> assign(:goals, Goals.list_active_goals(user))}
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

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    assigns = assign(assigns, :week_days, Enum.map(0..6, &Date.add(week_start, &1)))

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-5 space-y-4">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">THIS WEEK</p>

      <div class="flex items-end justify-between">
        <div class="tabular-nums leading-none">
          <span class="text-7xl font-semibold tracking-tight">
            {trunc(@streak.current_week_minutes)}
          </span>
          <span class="text-base-content/50 text-base ml-2">/ 80 min</span>
        </div>
        <div class="text-sm text-base-content/60 pb-1">
          <%= if @streak.streak_weeks == 0 do %>
            No active streak
          <% else %>
            {@streak.streak_weeks} week streak
          <% end %>
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
          <div class="flex flex-col items-center gap-0.5">
            <span class="text-[10px] text-base-content/30">
              {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
            </span>
            <div class={[
              "w-4 h-4 rounded-full",
              day in @streak.days_active_this_week && "bg-primary",
              day == @today && day not in @streak.days_active_this_week &&
                "ring-2 ring-primary ring-offset-1 ring-offset-base-200 bg-transparent",
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
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="text-xs text-base-content/30 hover:text-primary transition"
          >
            Replace
          </button>
        </div>
      <% else %>
        <div class="space-y-2">
          <p class="text-xs text-base-content/50">No goal set</p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="text-xs text-primary hover:underline"
          >
            Set goal
          </button>
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
      <h2 class="text-base font-semibold text-base-content">Sessions</h2>

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
        <div class="min-w-0 space-y-0.5">
          <p class="text-sm font-semibold leading-snug tabular-nums">
            <%= if @session.burpee_count_actual do %>
              {@session.burpee_count_actual} burpees · {Fmt.duration_sec(@session.duration_sec_actual)}
            <% else %>
              {Fmt.duration_sec(@session.duration_sec_actual)}
            <% end %>
          </p>
          <p class="text-xs text-base-content/40">
            {Fmt.burpee_type(@session.burpee_type)}
            <%= if @session.plan do %>
              <span class="text-base-content/20 mx-1">·</span>{@session.plan.name}
            <% end %>
          </p>
        </div>
        <span class="text-xs text-base-content/30 shrink-0 pt-0.5">
          {Calendar.strftime(DateTime.to_date(@session.inserted_at), "%-d %b")}
        </span>
      </div>
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
      <h2 class="text-base font-semibold text-base-content">Trends</h2>
      <.weekly_minutes_chart weekly_data={@weekly_data} />
      <.progress_chart
        sessions={@six_count_sessions}
        label="6-Count progress"
        color="#4A9EFF"
        goal={@six_goal}
      />
      <.progress_chart
        sessions={@navy_seal_sessions}
        label="Navy SEAL progress"
        color="#F97316"
        goal={@seal_goal}
      />
    </div>
    """
  end

  attr :weekly_data, :list, required: true

  defp weekly_minutes_chart(assigns) do
    chart_weeks = assigns.weekly_data |> Enum.take(12) |> Enum.reverse()

    chart_weeks_with_labels =
      Enum.with_index(chart_weeks, fn week, i ->
        {_y, w} = :calendar.iso_week_number(Date.to_erl(week.week_start))
        show_label = i == 0 or rem(i, 4) == 0 or i == length(chart_weeks) - 1
        Map.merge(week, %{index: i, iso_week: w, show_label: show_label})
      end)

    assigns = assign(assigns, :chart_weeks, chart_weeks_with_labels)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">Weekly minutes</p>
      <% bar_w = 18
      gap = 7
      chart_w = 300
      y_axis_w = 16

      max_m = 120
      target_y = 75 - 80 / max_m * 70 %>
      <svg viewBox={"0 0 #{chart_w} 96"} class="w-full" aria-hidden="true">
        <%!-- y-axis labels --%>
        <text x={y_axis_w - 2} y="10" text-anchor="end" font-size="7" fill="#3A4A5E">120</text>
        <text x={y_axis_w - 2} y={76 - 80 / max_m * 70} text-anchor="end" font-size="7" fill="#3A4A5E">
          80
        </text>
        <text x={y_axis_w - 2} y="76" text-anchor="end" font-size="7" fill="#3A4A5E">0</text>

        <%!-- bars --%>
        <%= for week <- @chart_weeks do %>
          <% x = y_axis_w + week.index * (bar_w + gap)
          height = max(min(week.minutes / max_m * 70, 70), 1)
          y = 75 - height
          color = if week.met_goal, do: "#4A9EFF", else: "#2A3A4E" %>
          <rect x={x} y={y} width={bar_w} height={height} fill={color} rx="2" />
        <% end %>

        <%!-- 80 min target line + label --%>
        <line
          x1={y_axis_w}
          y1={target_y}
          x2={chart_w}
          y2={target_y}
          stroke="#3A4A5E"
          stroke-width="0.5"
          stroke-dasharray="3,3"
        />
        <text x={chart_w} y={target_y - 2} text-anchor="end" font-size="6" fill="#3A4A5E">
          80 min
        </text>

        <%!-- x-axis week labels --%>
        <%= for week <- @chart_weeks, week.show_label do %>
          <% x = y_axis_w + week.index * (bar_w + gap) + bar_w / 2 %>
          <text x={x} y="90" text-anchor="middle" font-size="6" fill="#3A4A5E">W{week.iso_week}</text>
        <% end %>
      </svg>
    </div>
    """
  end

  attr :sessions, :list, required: true
  attr :label, :string, required: true
  attr :color, :string, required: true
  attr :goal, :any, required: true

  defp progress_chart(assigns) do
    points =
      Enum.map(assigns.sessions, fn s ->
        normalized = round(s.burpee_count_actual / s.duration_sec_actual * 1200)
        date = DateTime.to_date(s.inserted_at)
        %{date: date, reps: normalized}
      end)

    target = if assigns.goal, do: assigns.goal.burpee_count_target, else: nil
    all_vals = Enum.map(points, & &1.reps) ++ if(target, do: [target], else: [])
    max_val = if all_vals == [], do: 1, else: Enum.max(all_vals)
    n = length(points)

    y_axis_w = 24
    chart_w = 300
    top_pad = 8
    plot_h = 60
    bot_pad = 16
    total_h = top_pad + plot_h + bot_pad
    step = if n > 1, do: (chart_w - y_axis_w) / (n - 1), else: chart_w - y_axis_w

    to_x = fn i -> y_axis_w + i * step end
    to_y = fn v -> top_pad + plot_h - v / max_val * plot_h end

    indexed = Enum.with_index(points)

    polyline =
      Enum.map_join(indexed, " ", fn {p, i} ->
        "#{Float.round(to_x.(i * 1.0), 1)},#{Float.round(to_y.(p.reps * 1.0), 1)}"
      end)

    x_labels =
      Enum.filter(indexed, fn {_p, i} ->
        i == 0 or i == n - 1 or (n > 4 and rem(i, 3) == 0)
      end)

    target_y = if target, do: to_y.(target * 1.0), else: nil

    assigns =
      assign(assigns,
        points: points,
        indexed: indexed,
        polyline: polyline,
        x_labels: x_labels,
        target_y: target_y,
        target: target,
        max_val: max_val,
        to_x: to_x,
        to_y: to_y,
        top_pad: top_pad,
        plot_h: plot_h,
        total_h: total_h,
        chart_w: chart_w,
        y_axis_w: y_axis_w
      )

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">{@label}</p>

      <%= if @points == [] do %>
        <p class="text-xs text-base-content/30">No sessions yet.</p>
      <% else %>
        <svg viewBox={"0 0 #{@chart_w} #{@total_h}"} class="w-full overflow-visible" aria-hidden="true">
          <%!-- y-axis labels --%>
          <text x={@y_axis_w - 3} y={@top_pad + 4} text-anchor="end" font-size="7" fill="#3A4A5E">{@max_val}</text>
          <text x={@y_axis_w - 3} y={@top_pad + @plot_h} text-anchor="end" font-size="7" fill="#3A4A5E">0</text>

          <%!-- zero baseline --%>
          <line
            x1={@y_axis_w}
            y1={@top_pad + @plot_h}
            x2={@chart_w}
            y2={@top_pad + @plot_h}
            stroke="#1E2535"
            stroke-width="0.5"
          />

          <%!-- target line --%>
          <%= if @target_y do %>
            <line
              x1={@y_axis_w}
              y1={@target_y}
              x2={@chart_w}
              y2={@target_y}
              stroke={@color}
              stroke-width="0.5"
              stroke-dasharray="3,3"
              opacity="0.5"
            />
            <text x={@chart_w} y={@target_y - 2} text-anchor="end" font-size="6" fill={@color} opacity="0.7">{@target}</text>
          <% end %>

          <%!-- line --%>
          <%= if length(@indexed) > 1 do %>
            <polyline
              points={@polyline}
              fill="none"
              stroke={@color}
              stroke-width="1.5"
              stroke-linejoin="round"
            />
          <% end %>

          <%!-- dots --%>
          <%= for {p, i} <- @indexed do %>
            <circle cx={@to_x.(i * 1.0)} cy={@to_y.(p.reps * 1.0)} r="2.5" fill={@color} />
          <% end %>

          <%!-- x-axis date labels --%>
          <%= for {p, i} <- @x_labels do %>
            <text
              x={@to_x.(i * 1.0)}
              y={@top_pad + @plot_h + 12}
              text-anchor="middle"
              font-size="6"
              fill="#3A4A5E"
            >{Calendar.strftime(p.date, "%-d %b")}</text>
          <% end %>
        </svg>
      <% end %>
    </div>
    """
  end
end
