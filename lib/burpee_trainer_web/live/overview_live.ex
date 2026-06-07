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
    {:ok, socket |> assign_overview() |> assign(:log_modal_open, false)}
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
    {:noreply, socket |> assign_overview() |> assign(:log_modal_open, false)}
  end

  def handle_info({:session_saved, events}, socket) do
    {:noreply,
     socket
     |> assign_overview()
     |> assign(:log_modal_open, false)
     |> put_milestone_flashes(events)}
  end

  defp assign_overview(socket) do
    user = socket.assigns.current_user
    today = Date.utc_today()
    current_week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Workouts.weekly_minutes(user)
      |> Enum.find(%{minutes: 0.0, met_goal: false}, &(&1.week_start == current_week_start))

    socket
    |> assign(:this_week, this_week)
    |> assign(:trained_days, Workouts.this_week_trained_days(user))
    |> assign(:last_plan, Workouts.last_run_plan(user))
    |> assign(:goal_min, @goal_min)
    |> assign(:today, today)
    |> assign(:week_start, current_week_start)
    |> assign(:coach_suggestions, Coach.suggest_all(user))
    |> assign(:level_status, Levels.level_status(Workouts.list_sessions(user), today))
    |> assign(:week_pushups, Workouts.current_week_pushups(user, today))
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:home}
    >
      <div class="mx-auto max-w-lg space-y-7 pb-20 text-[var(--session-ink)]">
        <div
          :if={@level_status.at_risk?}
          class="border border-[var(--session-border)] rounded-2xl bg-[var(--session-track)]/40 px-4 py-3 flex items-start gap-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-[var(--session-ink)]" />
          <p class="text-sm text-[var(--session-muted)]">
            <span class="font-semibold text-[var(--session-ink)]">
              Level {level_label(@level_status.level)} expires in {@level_status.days_left}d
            </span>
            — train both burpee types this week to keep it.
          </p>
        </div>
        <.home_coach_card
          this_week={@this_week}
          trained_days={@trained_days}
          today={@today}
          week_start={@week_start}
          goal_min={@goal_min}
          week_pushups={@week_pushups}
          current_level={@current_level}
          last_plan={@last_plan}
        />
        <%= for suggestion <- @coach_suggestions do %>
          <.coach_suggestion suggestion={suggestion} />
        <% end %>
        <div class="text-center">
          <button
            type="button"
            phx-click="open_log_modal"
            class="text-sm text-[var(--session-muted)] hover:text-[var(--session-ink)] transition"
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
            class="session-surface relative z-10 w-full sm:max-w-md max-h-[calc(100dvh-1rem)] sm:max-h-[calc(100dvh-3rem)] overflow-y-auto bg-[var(--session-surface)] text-[var(--session-ink)] border border-[var(--session-border)] rounded-2xl rounded-t-2xl sm:rounded-2xl p-5 sm:p-6"
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
  attr(:current_level, :atom, default: nil)
  attr(:last_plan, :any, default: nil)

  defp home_coach_card(assigns) do
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

    ring_offset = 264 - pct * 2.64

    level_text =
      if assigns.current_level, do: "Level #{level_label(assigns.current_level)}", else: "Level —"

    primary_action = primary_home_action(assigns.last_plan, min_done, goal)

    assigns =
      assign(assigns,
        min_done: min_done,
        goal: goal,
        rhythm_segments: rhythm_segments,
        session_count: session_count,
        pct: pct,
        ring_offset: ring_offset,
        level_text: level_text,
        primary_action: primary_action
      )

    ~H"""
    <section
      id="home-coach-card"
      class="space-y-5 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] px-5 py-5"
    >
      <div class="space-y-1">
        <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
          What should I do now?
        </p>
      </div>
      <div class="flex items-center gap-7">
        <div class="relative size-[108px] shrink-0" aria-label={"#{@min_done} of #{@goal} minutes"}>
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
              {@min_done}
            </span>
            <span class="mt-1 text-xs font-medium text-[var(--session-muted)]">/ {@goal} min</span>
          </div>
        </div>
        <div class="min-w-0 flex-1 space-y-2">
          <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
            {@level_text}
          </p>
          <div class="flex items-baseline gap-1.5">
            <span class="text-2xl font-semibold tracking-[-0.04em] tabular-nums text-[var(--session-ink)]">
              {@min_done}
            </span>
            <span class="text-sm font-semibold text-[var(--session-ink)]">/ {@goal} min</span>
          </div>
          <p class="text-sm font-semibold text-[var(--session-ink)] tabular-nums">
            {max(@goal - @min_done, 0)} min left
          </p>
          <p class="text-xs text-[var(--session-muted)] tabular-nums">
            <%= if @session_count == 1 do %>
              1 session this week
            <% else %>
              {@session_count} sessions this week
            <% end %>
          </p>
          <p :if={@week_pushups > 0} class="text-xs text-[var(--session-muted)] tabular-nums">
            {@week_pushups} push-ups
          </p>
        </div>
      </div>

      <div id="home-week-rhythm" class="space-y-1.5" aria-label="Weekly training rhythm">
        <div class="grid grid-cols-7 gap-1">
          <%= for segment <- @rhythm_segments do %>
            <div
              data-week-rhythm-segment
              aria-label={segment.aria_label}
              class={[
                "h-1 transition-colors",
                segment.trained && "bg-[var(--session-ink)]",
                !segment.trained && segment.is_today && "bg-[var(--session-muted)]",
                !segment.trained && !segment.is_today && "bg-[var(--session-track)]"
              ]}
            />
          <% end %>
        </div>
        <div class="grid grid-cols-7 gap-1 text-center">
          <%= for segment <- @rhythm_segments do %>
            <span class={[
              "text-[10px] font-medium uppercase leading-none",
              segment.is_today && "text-[var(--session-ink)]",
              !segment.is_today && segment.trained && "text-[var(--session-ink)]",
              !segment.is_today && !segment.trained && "text-[var(--session-muted)]"
            ]}>
              {segment.label}
            </span>
          <% end %>
        </div>
      </div>

      <div class="border-t border-[var(--session-border)] pt-4">
        <div class="flex items-center justify-between gap-4">
          <div class="min-w-0 space-y-1">
            <p class="text-lg font-semibold leading-snug tracking-[-0.02em] text-[var(--session-ink)]">
              {@primary_action.title}
            </p>
            <p class="text-sm text-[var(--session-muted)]">{@primary_action.reason}</p>
          </div>
          <.link
            id="home-primary-action"
            navigate={@primary_action.path}
            class="shrink-0 rounded-2xl border border-[var(--session-ink)] px-4 py-3 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--session-ink)] transition hover:bg-[var(--session-ink)] hover:text-[var(--session-bg)]"
          >
            {@primary_action.label}
          </.link>
        </div>
      </div>
    </section>
    """
  end

  defp primary_home_action(nil, _min_done, _goal) do
    %{
      title: "Create your first training session",
      reason: "Set your burpee type, reps, and duration before starting.",
      label: "Create",
      path: ~p"/workouts/new"
    }
  end

  defp primary_home_action(plan, min_done, goal) do
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
    minutes_left = max(goal - min_done, 0)

    %{
      title: "Start #{plan.target_duration_min} min · #{type_label}",
      reason: "#{minutes_left} min left this week. One session now moves the week forward.",
      label: "Start",
      path: ~p"/session/#{plan.id}"
    }
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
      class="border border-[var(--session-border)] rounded-2xl bg-[var(--session-track)]/25 px-4 py-3 flex items-center gap-3"
    >
      <div class="flex-1 min-w-0">
        <span class="text-xs text-[var(--session-muted)] font-medium uppercase tracking-[0.12em]">
          Coach · {@type_label}
        </span>
        <span class="text-xs text-[var(--session-muted)] mx-1.5">·</span>
        <span class="text-xs font-semibold text-[var(--session-ink)]">{@dimension_label}</span>
        <span class="text-xs text-[var(--session-muted)] mx-1">—</span>
        <span class="text-xs text-[var(--session-muted)] truncate">{@suggestion.rationale}</span>
      </div>
      <.link
        navigate={"/workouts/new?count=#{@suggestion.burpee_count}&pace=#{@suggestion.sec_per_burpee}&rest=#{@suggestion.rest_sec}"}
        class="shrink-0 text-sm text-[var(--session-ink)] hover:text-[var(--session-muted)] transition font-medium whitespace-nowrap"
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
