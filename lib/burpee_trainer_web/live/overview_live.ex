defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Home screen. Action-first: status strip + suggested workout card + log link.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.Layouts

  @goal_min 80.0

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

    trained_days = Workouts.this_week_trained_days(user)
    last_plan = Workouts.last_run_plan(user)

    {:ok,
     socket
     |> assign(:this_week, this_week)
     |> assign(:streak, streak)
     |> assign(:trained_days, trained_days)
     |> assign(:last_plan, last_plan)
     |> assign(:goal_min, @goal_min)
     |> assign(:today, today)
     |> assign(:week_start, current_week_start)}
  end

  defp compute_streak(completed_weeks) do
    completed_weeks
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
    |> Enum.reduce_while(0, fn week, count ->
      if week.met_goal, do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:home}
    >
      <div class="space-y-8 max-w-lg mx-auto">
        <.status_strip
          this_week={@this_week}
          streak={@streak}
          trained_days={@trained_days}
          today={@today}
          week_start={@week_start}
          goal_min={@goal_min}
          current_level={@current_level}
        />
        <.workout_card last_plan={@last_plan} />
        <div class="text-center">
          <.link
            navigate={~p"/stats"}
            class="text-sm text-base-content/30 hover:text-base-content/60 transition"
          >
            + Log a past session
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :this_week, :map, required: true
  attr :streak, :integer, required: true
  attr :trained_days, :any, required: true
  attr :today, :any, required: true
  attr :week_start, :any, required: true
  attr :goal_min, :float, required: true
  attr :current_level, :atom, default: nil

  defp status_strip(assigns) do
    min_done = assigns.this_week.minutes |> Float.round(0) |> trunc()
    goal = trunc(assigns.goal_min)
    days = [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

    day_dots =
      days
      |> Enum.with_index()
      |> Enum.map(fn {day, offset} ->
        date = Date.add(assigns.week_start, offset)
        trained = MapSet.member?(assigns.trained_days, date)
        is_today = date == assigns.today
        %{trained: trained, is_today: is_today, label: day_label(day)}
      end)

    assigns = assign(assigns, min_done: min_done, goal: goal, day_dots: day_dots)

    ~H"""
    <div class="space-y-3 px-1">
      <%!-- Row 1: headline minutes + day strip --%>
      <div class="flex items-end justify-between">
        <div class="flex items-baseline gap-1.5">
          <span class={[
            "text-4xl font-bold leading-none tabular-nums",
            @this_week.met_goal && "text-primary",
            !@this_week.met_goal && "text-base-content"
          ]}>
            {@min_done}
          </span>
          <span class="text-sm text-base-content/40">/ {@goal} min</span>
        </div>
        <div class="flex items-end gap-3">
          <%= for dot <- @day_dots do %>
            <div class="flex flex-col items-center gap-1">
              <div class={[
                "w-1.5 h-1.5 rounded-full",
                dot.trained && "bg-primary",
                !dot.trained && dot.is_today && "border border-primary bg-transparent",
                !dot.trained && !dot.is_today && "bg-[#1E2535]"
              ]} />
              <span class={[
                "text-[11px] font-medium uppercase",
                dot.trained && "text-primary",
                !dot.trained && dot.is_today && "text-base-content/80",
                !dot.trained && !dot.is_today && "text-base-content/25"
              ]}>
                {dot.label}
              </span>
            </div>
          <% end %>
        </div>
      </div>
      <%!-- Row 2: streak + level chip --%>
      <div class="flex items-center justify-between">
        <span class="text-xs text-base-content/50">
          <%= if @streak > 0 do %>
            {@streak} {if @streak == 1, do: "week", else: "weeks"} streak
          <% else %>
            No streak yet
          <% end %>
        </span>
        <%= if @current_level do %>
          <span class="flex items-baseline gap-1">
            <span class="text-[10px] font-medium text-base-content/40 uppercase tracking-wide">
              Level
            </span>
            <span class="text-xs font-bold text-primary uppercase tracking-widest">
              {level_label(@current_level)}
            </span>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  attr :last_plan, :any, default: nil

  defp workout_card(%{last_plan: nil} = assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-6 space-y-5">
      <div class="space-y-1">
        <p class="text-sm text-base-content/50">Start your first workout</p>
        <p class="text-lg font-semibold leading-snug">Create a plan to begin</p>
        <p class="text-sm text-base-content/40">Set your burpee type, reps, and duration</p>
      </div>
      <.link
        navigate={~p"/workouts/new"}
        class="flex items-center justify-center gap-2 w-full h-14 rounded-lg bg-primary text-primary-content text-base font-semibold hover:bg-primary/90 transition-colors"
      >
        <.icon name="hero-plus" class="size-5" /> Create a plan
      </.link>
      <div class="text-center">
        <.link
          navigate={~p"/workouts"}
          class="text-sm text-base-content/50 hover:text-base-content/80 transition underline-offset-2 hover:underline"
        >
          Browse workouts →
        </.link>
      </div>
    </div>
    """
  end

  defp workout_card(assigns) do
    type_label = if assigns.last_plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
    assigns = assign(assigns, :type_label, type_label)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-6 space-y-5">
      <div class="space-y-1">
        <p class="text-sm text-base-content/50">Pick up where you left off</p>
        <p class="text-lg font-semibold leading-snug">{@last_plan.name}</p>
        <p class="text-sm text-base-content/50">
          {@last_plan.burpee_count_target} {@type_label}
          <span class="text-base-content/30"> · </span>
          {@last_plan.target_duration_min} min
        </p>
      </div>
      <.link
        navigate={~p"/session/#{@last_plan.id}"}
        class="flex items-center justify-center gap-2 w-full h-14 rounded-lg bg-primary text-primary-content text-base font-semibold hover:bg-primary/90 transition-colors"
      >
        <.icon name="hero-play" class="size-5" /> Start
      </.link>
      <div class="text-center">
        <.link
          navigate={~p"/workouts"}
          class="text-sm text-base-content/50 hover:text-base-content/80 transition underline-offset-2 hover:underline"
        >
          Pick another workout →
        </.link>
      </div>
    </div>
    """
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  defp day_label(:monday), do: "M"
  defp day_label(:tuesday), do: "T"
  defp day_label(:wednesday), do: "W"
  defp day_label(:thursday), do: "T"
  defp day_label(:friday), do: "F"
  defp day_label(:saturday), do: "S"
  defp day_label(:sunday), do: "S"
end
