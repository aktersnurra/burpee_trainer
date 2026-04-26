defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Landing page. Weekly streak, 12-week calendar grid, quick actions.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts

  @goal_min 80.0
  @calendar_weeks 12

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    weeks = Workouts.weekly_minutes(user)

    today = Date.utc_today()
    current_week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Enum.find(weeks, %{minutes: 0.0, met_goal: false}, &(&1.week_start == current_week_start))

    completed_weeks = Enum.reject(weeks, &(&1.week_start == current_week_start))

    streak = compute_streak(completed_weeks)
    calendar = build_calendar(weeks, current_week_start)

    {:ok,
     socket
     |> assign(:this_week, this_week)
     |> assign(:streak, streak)
     |> assign(:calendar, calendar)
     |> assign(:goal_min, @goal_min)}
  end

  # Count consecutive met-goal weeks going back from the most recent completed week.
  # If this week already meets the goal, count it too.
  defp compute_streak(completed_weeks) do
    completed_weeks
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
    |> Enum.reduce_while(0, fn week, count ->
      if week.met_goal, do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  defp build_calendar(weeks, current_week_start) do
    weeks_by_start = Map.new(weeks, &{&1.week_start, &1})

    0..(@calendar_weeks - 1)
    |> Enum.map(fn offset ->
      week_start = Date.add(current_week_start, -offset * 7)
      data = Map.get(weeks_by_start, week_start, %{minutes: 0.0, met_goal: false})
      is_current = week_start == current_week_start

      %{
        week_start: week_start,
        minutes: data.minutes,
        met_goal: data.met_goal,
        is_current: is_current
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <div class="space-y-4">
        <.streak_card
          streak={@streak}
          this_week={@this_week}
          goal_min={@goal_min}
          current_level={@current_level}
        />
        <.calendar_card calendar={@calendar} goal_min={@goal_min} />
        <.quick_actions />
      </div>
    </Layouts.app>
    """
  end

  attr :streak, :integer, required: true
  attr :this_week, :map, required: true
  attr :goal_min, :float, required: true
  attr :current_level, :atom, default: nil

  defp streak_card(assigns) do
    pct = min(assigns.this_week.minutes / assigns.goal_min * 100, 100.0)
    min_done = Float.round(assigns.this_week.minutes, 1)
    assigns = assign(assigns, pct: pct, min_done: min_done)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-5 flex items-center gap-4">
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2">
          <span class="text-[32px] font-semibold leading-none tracking-tight text-base-content">
            {@streak}
          </span>
          <span class="text-sm text-base-content/40">
            {if @streak == 1, do: "week", else: "weeks"}
          </span>
        </div>
        <p class="mt-1 text-xs text-base-content/40 uppercase tracking-wide">current streak</p>
      </div>

      <div class="w-px self-stretch bg-[#1E2535]"></div>

      <div class="flex-1 min-w-0 space-y-2">
        <div class="flex items-center justify-between">
          <span class="text-xs text-base-content/40 uppercase tracking-wide">This week</span>
          <%= if @this_week.met_goal do %>
            <span class="text-xs font-medium text-success">Goal met ✓</span>
          <% else %>
            <span class="text-xs text-base-content/40">
              {@min_done |> :erlang.float_to_binary(decimals: 0)} / {trunc(@goal_min)} min
            </span>
          <% end %>
        </div>
        <div class="h-2 rounded-full bg-[#1E2535] overflow-hidden">
          <div
            class={[
              "h-full rounded-full transition-all duration-500",
              @this_week.met_goal && "bg-success",
              !@this_week.met_goal && "bg-primary"
            ]}
            style={"width: #{@pct}%"}
          >
          </div>
        </div>
      </div>

      <%= if @current_level do %>
        <div class="w-px self-stretch bg-[#1E2535]"></div>

        <div class="flex flex-col items-center gap-1 min-w-[48px]">
          <span class="text-[11px] font-semibold tracking-widest text-primary uppercase px-2 py-0.5 rounded border border-primary/30 bg-primary/10">
            {level_label(@current_level)}
          </span>
          <p class="text-[10px] text-base-content/40 uppercase tracking-wide">level</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  attr :calendar, :list, required: true
  attr :goal_min, :float, required: true

  defp calendar_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 overflow-hidden">
      <div class="flex items-center justify-between px-5 py-4 border-b border-[#1E2535]">
        <h2 class="text-xs font-medium uppercase tracking-wide text-base-content/50">
          Weekly progress
        </h2>
        <span class="text-xs text-base-content/30">goal: {trunc(@goal_min)} min / week</span>
      </div>

      <div class="p-4 grid grid-cols-4 sm:grid-cols-6 gap-2">
        <%= for week <- @calendar do %>
          <.week_cell week={week} goal_min={@goal_min} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :week, :map, required: true
  attr :goal_min, :float, required: true

  defp week_cell(assigns) do
    pct = min(assigns.week.minutes / assigns.goal_min * 100, 100.0)
    min_str = trunc(assigns.week.minutes)

    assigns = assign(assigns, pct: pct, min_str: min_str)

    ~H"""
    <div class={[
      "rounded-lg border p-2.5 flex flex-col gap-1.5 min-w-0",
      @week.is_current && "border-primary/40 bg-primary/5",
      !@week.is_current && "border-[#1E2535] bg-base-100"
    ]}>
      <span class="text-[10px] text-base-content/30 tabular-nums">
        {Calendar.strftime(@week.week_start, "%b %-d")}
      </span>

      <div class="h-[3px] rounded-full bg-[#1E2535] overflow-hidden">
        <div
          class={[
            "h-full rounded-full",
            @week.met_goal && "bg-success",
            !@week.met_goal && @week.minutes > 0 && "bg-primary",
            @week.minutes == 0 && "bg-transparent"
          ]}
          style={"width: #{@pct}%"}
        >
        </div>
      </div>

      <div class="flex items-center justify-between gap-1">
        <span class="text-[11px] font-medium text-base-content/60 tabular-nums">
          {if @week.minutes > 0, do: "#{@min_str}m", else: "—"}
        </span>
        <span class={[
          "text-[10px] font-medium",
          @week.is_current && "text-primary",
          !@week.is_current && @week.met_goal && "text-success",
          !@week.is_current && !@week.met_goal && @week.minutes > 0 && "text-base-content/20",
          @week.minutes == 0 && "text-transparent"
        ]}>
          <%= cond do %>
            <% @week.is_current -> %>
              →
            <% @week.met_goal -> %>
              ✓
            <% @week.minutes > 0 -> %>
              ·
            <% true -> %>
              ·
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  defp quick_actions(assigns) do
    ~H"""
    <div class="space-y-2">
      <.link
        navigate={~p"/plans"}
        class="flex items-center justify-center gap-2 w-full h-12 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
      >
        <.icon name="hero-play" class="size-4" /> Run a plan
      </.link>
      <.link
        navigate={~p"/log"}
        class="flex items-center justify-center gap-2 w-full h-12 rounded-lg border border-[#1E2535] text-base-content/60 text-sm hover:text-base-content hover:border-base-content/20 transition-colors"
      >
        <.icon name="hero-plus" class="size-4" /> Log a session
      </.link>
    </div>
    """
  end
end
