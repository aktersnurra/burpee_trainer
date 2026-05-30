defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Home screen. Action-first: status strip + suggested workout card + log link.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.{Levels, Workouts}
  alias BurpeeTrainerWeb.{Layouts, LogFormComponent}

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
    coach_suggestions = Coach.suggest_all(user)

    {:ok,
     socket
     |> assign(:this_week, this_week)
     |> assign(:trained_days, trained_days)
     |> assign(:last_plan, last_plan)
     |> assign(:goal_min, @goal_min)
     |> assign(:today, today)
     |> assign(:week_start, current_week_start)
     |> assign(:coach_suggestions, coach_suggestions)
     |> assign(:level_status, Levels.level_status(Workouts.list_sessions(user), today))
     |> assign(:week_pushups, Workouts.current_week_pushups(user, today))
     |> assign(:log_modal_open, false)}
  end

  @impl true
  def handle_event("open_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, true)}
  end

  def handle_event("close_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, false)}
  end

  @impl true
  def handle_info(:session_saved, socket) do
    {:noreply, assign(socket, :log_modal_open, false)}
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
        <div
          :if={@level_status.at_risk?}
          class="rounded-[10px] bg-base-300 p-4 flex items-start gap-3"
          style="border: 1px solid #4A9EFF;"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" style="color: #4A9EFF;" />
          <p class="text-sm text-base-content/80">
            <span class="font-semibold">
              Level {level_label(@level_status.level)} expires in {@level_status.days_left}d
            </span>
            — train both burpee types this week to keep it.
          </p>
        </div>
        <.status_strip
          this_week={@this_week}
          trained_days={@trained_days}
          today={@today}
          week_start={@week_start}
          goal_min={@goal_min}
          week_pushups={@week_pushups}
        />
        <.workout_card last_plan={@last_plan} />
        <%= for suggestion <- @coach_suggestions do %>
          <.coach_suggestion suggestion={suggestion} />
        <% end %>
        <div class="text-center">
          <button
            type="button"
            phx-click="open_log_modal"
            class="text-sm text-base-content/30 hover:text-base-content/60 transition"
          >
            + Log a past session
          </button>
        </div>
      </div>

      <%= if @log_modal_open do %>
        <div
          id="home-log-modal"
          class="fixed inset-0 z-50 flex items-end sm:items-center justify-center px-0 sm:px-4 py-0 sm:py-6"
        >
          <button
            id="home-log-modal-backdrop"
            type="button"
            phx-click="close_log_modal"
            class="absolute inset-0 bg-black/60"
            aria-label="Close log session"
          />
          <div
            id="home-log-modal-sheet"
            class="relative z-10 w-full sm:max-w-md max-h-[calc(100dvh-1rem)] sm:max-h-[calc(100dvh-3rem)] overflow-y-auto bg-base-nav border border-base-border rounded-t-2xl sm:rounded-2xl p-5 sm:p-6 shadow-2xl"
          >
            <.live_component
              module={LogFormComponent}
              id="home-log-form"
              current_user={@current_user}
              on_save={:session_saved}
            />
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr(:this_week, :map, required: true)
  attr(:trained_days, :any, required: true)
  attr(:today, :any, required: true)
  attr(:week_start, :any, required: true)
  attr(:goal_min, :float, required: true)
  attr(:week_pushups, :integer, default: 0)

  defp status_strip(assigns) do
    min_done = assigns.this_week.minutes |> Float.round(0) |> trunc()
    goal = trunc(assigns.goal_min)
    days = [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

    rhythm_segments =
      days
      |> Enum.with_index()
      |> Enum.map(fn {day, offset} ->
        date = Date.add(assigns.week_start, offset)
        trained = MapSet.member?(assigns.trained_days, date)
        is_today = date == assigns.today
        state_label = rhythm_state_label(trained, is_today)

        %{
          trained: trained,
          is_today: is_today,
          label: day_label(day),
          aria_label: "#{day_name(day)}: #{state_label}"
        }
      end)

    session_count = MapSet.size(assigns.trained_days)
    pct = min(trunc(min_done / goal * 100), 100)

    assigns =
      assign(assigns,
        min_done: min_done,
        goal: goal,
        rhythm_segments: rhythm_segments,
        session_count: session_count,
        pct: pct
      )

    ~H"""
    <div class="space-y-3 px-1">
      <div class="flex items-end justify-between gap-4">
        <div class="space-y-1">
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
        </div>
        <div class="pb-1 text-right space-y-0.5">
          <p class="text-xs text-base-content/45 tabular-nums">
            <%= if @session_count == 1 do %>
              1 session
            <% else %>
              {@session_count} sessions
            <% end %>
          </p>
          <p :if={@week_pushups > 0} class="text-xs tabular-nums" style="color: #4A9EFF;">
            {@week_pushups} push-ups
          </p>
        </div>
      </div>

      <div class="h-1 w-full rounded-full bg-base-border">
        <div
          class="h-1 rounded-full bg-primary transition-all duration-500"
          style={"width: #{@pct}%"}
          aria-label={"#{@min_done} of #{@goal} minutes"}
        />
      </div>

      <div id="home-week-rhythm" class="space-y-1.5" aria-label="Weekly training rhythm">
        <div class="grid grid-cols-7 gap-1">
          <%= for segment <- @rhythm_segments do %>
            <div
              data-week-rhythm-segment
              aria-label={segment.aria_label}
              class={[
                "h-1 rounded-full transition-colors",
                segment.trained && "bg-primary",
                !segment.trained && segment.is_today && "bg-base-content/25",
                !segment.trained && !segment.is_today && "bg-base-border"
              ]}
            />
          <% end %>
        </div>
        <div class="grid grid-cols-7 gap-1 text-center">
          <%= for segment <- @rhythm_segments do %>
            <span class={[
              "text-[10px] font-medium uppercase leading-none",
              segment.is_today && "text-base-content/70",
              !segment.is_today && segment.trained && "text-primary/80",
              !segment.is_today && !segment.trained && "text-base-content/25"
            ]}>
              {segment.label}
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:last_plan, :any, default: nil)

  defp workout_card(%{last_plan: nil} = assigns) do
    ~H"""
    <div
      id="home-workout-card"
      class="rounded-[10px] bg-base-300 p-6 space-y-5"
    >
      <div class="space-y-1">
        <p class="text-xl font-bold leading-snug">Create a plan to begin</p>
        <p class="text-sm text-base-content/40">Set your burpee type, reps, and duration</p>
      </div>
      <div class="flex justify-center">
        <.link
          navigate={~p"/workouts/new"}
          class="w-12 h-12 rounded-full bg-base-raised border border-base-border text-primary flex items-center justify-center hover:bg-base-border transition"
          aria-label="Create a plan"
        >
          <.icon name="hero-plus" class="size-5" />
        </.link>
      </div>
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
    <div id="home-workout-card" class="rounded-[10px] bg-base-300 px-5 py-4">
      <div class="flex items-center justify-between gap-4">
        <div class="min-w-0 space-y-0.5">
          <p class="text-base font-semibold leading-snug truncate">{@last_plan.name}</p>
          <p class="text-sm text-base-content/40 tabular-nums">
            {@last_plan.burpee_count_target} {@type_label}
            <span class="text-base-content/20"> · </span>
            {@last_plan.target_duration_min} min
          </p>
        </div>
        <.link
          navigate={~p"/session/#{@last_plan.id}"}
          class="w-11 h-11 shrink-0 rounded-full bg-base-raised border border-base-border text-primary flex items-center justify-center hover:bg-base-border transition"
          aria-label="Start workout"
        >
          <.icon name="hero-play" class="size-4" />
        </.link>
      </div>
      <div class="mt-3 pt-3 border-t border-base-border">
        <.link
          navigate={~p"/workouts"}
          class="text-xs text-base-content/35 hover:text-base-content/60 transition"
        >
          Pick another workout →
        </.link>
      </div>
    </div>
    """
  end

  attr(:suggestion, :any, default: nil)

  defp coach_suggestion(%{suggestion: nil} = assigns), do: ~H""

  defp coach_suggestion(assigns) do
    type_label = if assigns.suggestion.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"

    dimension_label =
      case assigns.suggestion.dimension do
        :reps -> "Push volume"
        :pace -> "Push intensity"
        :rest -> "Push density"
        :baseline -> "Confirm your level"
      end

    assigns = assign(assigns, type_label: type_label, dimension_label: dimension_label)

    ~H"""
    <div
      data-home-coach-suggestion
      class="rounded-[10px] border border-primary/20 bg-primary/5 px-4 py-3 flex items-center gap-3"
    >
      <div class="flex-1 min-w-0">
        <span class="text-xs text-primary/70 font-medium uppercase tracking-wide">
          Coach · {@type_label}
        </span>
        <span class="text-xs text-base-content/50 mx-1.5">·</span>
        <span class="text-xs font-semibold text-base-content">{@dimension_label}</span>
        <span class="text-xs text-base-content/40 mx-1">—</span>
        <span class="text-xs text-base-content/50 truncate">{@suggestion.rationale}</span>
      </div>
      <.link
        navigate={"/workouts/new?count=#{@suggestion.burpee_count}&pace=#{@suggestion.sec_per_burpee}&rest=#{@suggestion.rest_sec}"}
        class="shrink-0 text-sm text-primary hover:text-primary/80 transition font-medium whitespace-nowrap"
      >
        Try it →
      </.link>
    </div>
    """
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  defp rhythm_state_label(true, _is_today), do: "trained"
  defp rhythm_state_label(false, true), do: "today"
  defp rhythm_state_label(false, false), do: "not trained"

  defp day_label(:monday), do: "M"
  defp day_label(:tuesday), do: "T"
  defp day_label(:wednesday), do: "W"
  defp day_label(:thursday), do: "T"
  defp day_label(:friday), do: "F"
  defp day_label(:saturday), do: "S"
  defp day_label(:sunday), do: "S"

  defp day_name(:monday), do: "Monday"
  defp day_name(:tuesday), do: "Tuesday"
  defp day_name(:wednesday), do: "Wednesday"
  defp day_name(:thursday), do: "Thursday"
  defp day_name(:friday), do: "Friday"
  defp day_name(:saturday), do: "Saturday"
  defp day_name(:sunday), do: "Sunday"
end
