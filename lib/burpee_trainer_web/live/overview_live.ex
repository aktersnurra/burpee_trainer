defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Home screen. Action-first: status strip + suggested workout card + log link.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainerWeb.Layouts

  @goal_min 80.0

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    today = Date.utc_today()
    current_week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Workouts.weekly_minutes(user)
      |> Enum.find(%{minutes: 0.0, met_goal: false}, &(&1.week_start == current_week_start))

    trained_days = Workouts.this_week_trained_days(user)
    last_plan = Workouts.last_run_plan(user)
    coach_suggestion = Coach.suggest(user, :six_count)

    {:ok,
     socket
     |> assign(:this_week, this_week)
     |> assign(:trained_days, trained_days)
     |> assign(:last_plan, last_plan)
     |> assign(:goal_min, @goal_min)
     |> assign(:today, today)
     |> assign(:week_start, current_week_start)
     |> assign(:coach_suggestion, coach_suggestion)}
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
          trained_days={@trained_days}
          today={@today}
          week_start={@week_start}
          goal_min={@goal_min}
        />
        <.coach_suggestion suggestion={@coach_suggestion} />
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
  attr :trained_days, :any, required: true
  attr :today, :any, required: true
  attr :week_start, :any, required: true
  attr :goal_min, :float, required: true

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
    <div class="flex items-end justify-between px-1">
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
              !dot.trained && "bg-[#1E2535]"
            ]} />
            <span class={[
              "text-[11px] font-medium uppercase leading-none",
              dot.is_today && "text-base-content rounded px-0.5 ring-1 ring-base-content/40",
              !dot.is_today && dot.trained && "text-primary",
              !dot.is_today && !dot.trained && "text-base-content/25"
            ]}>
              {dot.label}
            </span>
          </div>
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
      <div class="text-center mt-2">
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

  attr :suggestion, :any, default: nil

  defp coach_suggestion(%{suggestion: nil} = assigns), do: ~H""

  defp coach_suggestion(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-primary/20 bg-primary/5 p-4 space-y-3">
      <div class="space-y-0.5">
        <p class="text-xs text-primary/70 font-medium uppercase tracking-wide">Coach</p>
        <p class="text-sm font-semibold">
          <%= case @suggestion.dimension do %>
            <% :reps -> %>
              Push volume
            <% :pace -> %>
              Push intensity
            <% :rest -> %>
              Push density
            <% :baseline -> %>
              Confirm your level
          <% end %>
        </p>
        <p class="text-xs text-base-content/50">{@suggestion.rationale}</p>
      </div>
      <div class="flex items-center gap-4 text-xs text-base-content/60">
        <span><strong class="text-base-content">{@suggestion.burpee_count}</strong> reps</span>
        <span><strong class="text-base-content">{@suggestion.sec_per_burpee}s</strong> pace</span>
        <%= if @suggestion.rest_sec > 0 do %>
          <span><strong class="text-base-content">{@suggestion.rest_sec}s</strong> rest</span>
        <% end %>
      </div>
      <.link
        navigate={"/workouts/new?count=#{@suggestion.burpee_count}&pace=#{@suggestion.sec_per_burpee}&rest=#{@suggestion.rest_sec}"}
        class="text-sm text-primary hover:text-primary/80 transition font-medium"
      >
        Try it →
      </.link>
    </div>
    """
  end

  defp day_label(:monday), do: "M"
  defp day_label(:tuesday), do: "T"
  defp day_label(:wednesday), do: "W"
  defp day_label(:thursday), do: "T"
  defp day_label(:friday), do: "F"
  defp day_label(:saturday), do: "S"
  defp day_label(:sunday), do: "S"
end
