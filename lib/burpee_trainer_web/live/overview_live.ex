defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Home screen. Action-first: status strip + suggested workout card + log link.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{
    CatchUpPlanner,
    CoachTargetPlanner,
    Levels,
    Goals,
    PerformanceModel,
    PlanSolver,
    WeeklyTrainingContract,
    Workouts
  }

  alias BurpeeTrainer.CatchUpPlanner.Input, as: CatchUpInput
  alias BurpeeTrainer.CoachTargetPlanner.Input, as: CoachTargetInput
  alias BurpeeTrainerWeb.{Layouts, LogFormComponent}

  @goal_min 80.0

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_overview()
     |> assign(:log_modal_open, false)
     |> assign(:catch_up_plan, nil)
     |> assign(:catch_up_selected_type, nil)}
  end

  @impl true
  def handle_event("open_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, true)}
  end

  def handle_event("close_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, false)}
  end

  def handle_event("plan_catch_up", %{"type" => type}, socket) do
    case parse_burpee_type(type) do
      {:ok, burpee_type} ->
        plan = build_catch_up_plan(socket.assigns, burpee_type)

        {:noreply,
         socket
         |> assign(:catch_up_selected_type, burpee_type)
         |> assign(:catch_up_plan, plan)}

      :error ->
        {:noreply, put_flash(socket, :error, "Choose Six-count or Navy SEAL.")}
    end
  end

  def handle_event("use_coach_target", %{"type" => type} = params, socket) do
    role = Map.get(params, "role", "hard")

    suggestion =
      with {:ok, burpee_type} <- parse_burpee_type(type),
           split when not is_nil(split) <-
             Enum.find(socket.assigns.weekly_split_suggestions, &(&1.burpee_type == burpee_type)) do
        if role == "easy", do: split.easy, else: split.hard
      else
        _ -> nil
      end

    case create_coach_plan(socket.assigns.current_user, socket.assigns.training_state, suggestion) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, "Coach plan created.")
         |> push_navigate(to: ~p"/workouts/#{plan.id}/edit")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create coach plan.")}
    end
  end

  def handle_event("use_catch_up_plan", _, socket) do
    case create_catch_up_plans(socket.assigns.current_user, socket.assigns.catch_up_plan) do
      {:ok, [plan | _]} ->
        {:noreply,
         socket
         |> put_flash(:info, "Catch-up plan created.")
         |> push_navigate(to: ~p"/workouts/#{plan.id}/edit")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create catch-up plan.")}
    end
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
    today = today()
    current_week_start = Date.beginning_of_week(today, :monday)

    sessions = Workouts.list_sessions(user)

    this_week =
      Workouts.weekly_minutes(user)
      |> Enum.find(%{minutes: 0.0, met_goal: false}, &(&1.week_start == current_week_start))

    weekly_status = WeeklyTrainingContract.status(sessions, current_week_start)
    remaining_slots = WeeklyTrainingContract.remaining_slots(sessions, current_week_start)
    training_state = PerformanceModel.build_training_state(sessions)

    primary_plan = Workouts.last_run_plan(user) || List.first(Workouts.list_plans(user))

    socket
    |> assign(:this_week, this_week)
    |> assign(:trained_days, Workouts.this_week_trained_days(user))
    |> assign(:last_plan, primary_plan)
    |> assign(:goal_min, @goal_min)
    |> assign(:today, today)
    |> assign(:week_start, current_week_start)
    |> assign(
      :weekly_split_suggestions,
      weekly_split_suggestions(user, sessions, training_state, weekly_status, today)
    )
    |> assign(:level_status, Levels.level_status(sessions, today))
    |> assign(:sessions, sessions)
    |> assign(:weekly_status, weekly_status)
    |> assign(:remaining_slots, remaining_slots)
    |> assign(:training_state, training_state)
    |> assign(:week_pushups, Workouts.current_week_pushups(user, today))
  end

  defp weekly_split_suggestions(
         _user,
         _sessions,
         _training_state,
         %{remaining_min: remaining},
         _today
       )
       when remaining <= 0,
       do: []

  defp weekly_split_suggestions(user, sessions, training_state, weekly_status, today) do
    user
    |> Goals.list_active_goals()
    |> Enum.flat_map(fn goal ->
      performance_goal = Goals.to_performance_goal(goal)

      input = %CoachTargetInput{
        goal: performance_goal,
        history: sessions,
        training_state: training_state,
        weekly_status: weekly_status,
        burpee_type: performance_goal.burpee_type,
        target_duration_min: 20,
        today: today
      }

      case CoachTargetPlanner.suggest_targets(input) do
        {:ok, suggestions} ->
          List.wrap(home_weekly_split_suggestion(suggestions))

        {:error, _reason} ->
          []
      end
    end)
  end

  defp home_weekly_split_suggestion(suggestions) do
    hard =
      Enum.find(suggestions, &(&1.kind == :recommended)) ||
        Enum.find(suggestions, &(&1.kind == :on_track)) ||
        List.first(suggestions)

    easy =
      Enum.find(suggestions, &(&1.kind == :safe_progress)) ||
        Enum.find(suggestions, &(&1.kind == :maintenance)) ||
        hard

    if hard, do: %{burpee_type: hard.burpee_type, hard: hard, easy: easy}
  end

  defp today, do: Application.get_env(:burpee_trainer, :today_override) || Date.utc_today()

  defp parse_burpee_type("six_count"), do: {:ok, :six_count}
  defp parse_burpee_type("navy_seal"), do: {:ok, :navy_seal}
  defp parse_burpee_type(_), do: :error

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

  defp build_catch_up_plan(assigns, burpee_type) do
    duration_min = max(assigns.weekly_status.remaining_min, 20)

    input = %CatchUpInput{
      weekly_status: assigns.weekly_status,
      remaining_slots: assigns.remaining_slots,
      selected_burpee_type: burpee_type,
      performance_goal: Goals.get_active_performance_goal(assigns.current_user, burpee_type),
      training_state: assigns.training_state,
      history: assigns.sessions,
      duration_min: duration_min,
      today: assigns.today
    }

    case CatchUpPlanner.plan(input) do
      {:ok, plan} -> plan
      {:error, _reason} -> nil
    end
  end

  defp create_coach_plan(_user, _training_state, nil), do: {:error, :no_coach_suggestion}

  defp create_coach_plan(user, training_state, suggestion) do
    level = Map.fetch!(training_state.level_by_type, suggestion.burpee_type)

    plan_input = %PlanSolver.Input{
      name: "Coach #{catch_up_type_label(suggestion.burpee_type)}",
      burpee_type: suggestion.burpee_type,
      target_duration_min: suggestion.target_duration_min,
      burpee_count_target: suggestion.burpee_count_target,
      pacing_style: suggestion.plan_input_defaults.pacing_style,
      additional_rests: suggestion.plan_input_defaults.additional_rests,
      level: level
    }

    metadata = %{
      "source" => "coach_target",
      "solver_version" => "deterministic-v2",
      "suggestion_kind" => Atom.to_string(suggestion.kind),
      "risk" => Atom.to_string(suggestion.risk),
      "confidence" => suggestion.confidence,
      "rationale" => suggestion.rationale
    }

    with {:ok, solution} <- PlanSolver.solve(plan_input),
         attrs =
           generated_plan_attrs(solution.plan,
             coach_suggestion_kind: Atom.to_string(suggestion.kind),
             coach_target_reps: suggestion.burpee_count_target,
             plan_solver_metadata: metadata
           ),
         {:ok, plan} <- Workouts.create_plan(user, attrs) do
      {:ok, plan}
    end
  end

  defp create_catch_up_plans(_user, nil), do: {:error, :no_catch_up_plan}

  defp create_catch_up_plans(user, catch_up_plan) do
    catch_up_plan.selected_sessions
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {session, index}, {:ok, plans} ->
      metadata = %{
        "source" => "catch_up",
        "solver_version" => "deterministic-v2",
        "suggestion_kind" => Atom.to_string(session.suggestion_kind),
        "weekly_split_effect" => Atom.to_string(catch_up_plan.weekly_split_effect),
        "total_duration_min" => catch_up_plan.total_duration_min,
        "fatigue_cost" => catch_up_plan.fatigue_cost,
        "risk" => Atom.to_string(catch_up_plan.risk),
        "rationale" => catch_up_plan.rationale
      }

      with {:ok, solution} <- PlanSolver.solve(named_plan_input(session.plan_input, index)),
           attrs =
             generated_plan_attrs(solution.plan,
               coach_suggestion_kind: Atom.to_string(session.suggestion_kind),
               coach_target_reps: session.target_reps,
               plan_solver_metadata: metadata
             ),
           {:ok, plan} <- Workouts.create_plan(user, attrs) do
        {:cont, {:ok, [plan | plans]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp named_plan_input(plan_input, index) do
    type_label = catch_up_type_label(plan_input.burpee_type)
    %{plan_input | name: "Catch-up #{type_label} #{index}"}
  end

  defp generated_plan_attrs(plan, opts) do
    plan
    |> workout_plan_attrs()
    |> Map.merge(%{
      "coach_suggestion_kind" => Keyword.fetch!(opts, :coach_suggestion_kind),
      "coach_target_reps" => Keyword.fetch!(opts, :coach_target_reps),
      "plan_solver_metadata" => Keyword.fetch!(opts, :plan_solver_metadata)
    })
  end

  defp workout_plan_attrs(plan) do
    %{
      "name" => plan.name,
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "target_duration_min" => plan.target_duration_min,
      "burpee_count_target" => plan.burpee_count_target,
      "sec_per_burpee" => plan.sec_per_burpee,
      "pacing_style" => Atom.to_string(plan.pacing_style),
      "additional_rests" => plan.additional_rests,
      "fatigue_factor" => plan.fatigue_factor,
      "blocks" => Enum.map(plan.blocks, &block_attrs/1)
    }
  end

  defp block_attrs(block) do
    %{
      "position" => block.position,
      "repeat_count" => block.repeat_count,
      "sets" => Enum.map(block.sets, &set_attrs/1)
    }
  end

  defp set_attrs(set) do
    %{
      "position" => set.position,
      "burpee_count" => set.burpee_count,
      "sec_per_rep" => set.sec_per_rep,
      "sec_per_burpee" => set.sec_per_burpee,
      "end_of_set_rest" => set.end_of_set_rest
    }
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
        <.weekly_split_panel suggestions={@weekly_split_suggestions} />
        <.catch_up_panel
          weekly_status={@weekly_status}
          catch_up_available?={WeeklyTrainingContract.catch_up_available?(@today)}
          catch_up_plan={@catch_up_plan}
          catch_up_selected_type={@catch_up_selected_type}
        />
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

  attr(:weekly_status, :any, required: true)
  attr(:catch_up_available?, :boolean, required: true)
  attr(:catch_up_plan, :any, default: nil)
  attr(:catch_up_selected_type, :atom, default: nil)

  defp catch_up_panel(assigns) do
    remaining = assigns.weekly_status.remaining_min
    assigns = assign(assigns, :remaining, remaining)

    ~H"""
    <section
      id="home-catch-up-panel"
      class="space-y-4 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] px-5 py-5"
    >
      <div class="space-y-1">
        <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
          Plan remaining work
        </p>
        <p class="text-sm text-[var(--session-muted)]">
          {@remaining} min left this week. Choose the burpee type first.
        </p>
      </div>

      <div
        :if={@remaining <= 0}
        id="home-catch-up-complete"
        class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/30 px-4 py-4"
      >
        <p class="text-sm font-semibold text-[var(--session-ink)]">Weekly work is complete.</p>
        <p class="mt-1 text-xs text-[var(--session-muted)]">
          Catch-up planning appears again when there is time left in the weekly contract.
        </p>
      </div>

      <div
        :if={@remaining > 0 and !@catch_up_available?}
        id="home-catch-up-too-early"
        class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/30 px-4 py-4"
      >
        <p class="text-sm font-semibold text-[var(--session-ink)]">
          Stay with the weekly split for now.
        </p>
        <p class="mt-1 text-xs text-[var(--session-muted)]">
          Catch-up opens on Saturday when there are 2 days left or less.
        </p>
      </div>

      <div :if={@remaining > 0 and @catch_up_available?} class="grid grid-cols-2 gap-2">
        <button
          id="catch-up-six-count"
          type="button"
          phx-click="plan_catch_up"
          phx-value-type="six_count"
          class="rounded-2xl border border-[var(--session-border)] px-3 py-3 text-xs font-semibold uppercase tracking-[0.14em] text-[var(--session-ink)] transition hover:border-[var(--session-ink)]"
        >
          Six-count
        </button>
        <button
          id="catch-up-navy-seal"
          type="button"
          phx-click="plan_catch_up"
          phx-value-type="navy_seal"
          class="rounded-2xl border border-[var(--session-border)] px-3 py-3 text-xs font-semibold uppercase tracking-[0.14em] text-[var(--session-ink)] transition hover:border-[var(--session-ink)]"
        >
          Navy SEAL
        </button>
      </div>

      <%= if is_nil(@catch_up_plan) and @catch_up_selected_type do %>
        <div
          id="home-catch-up-no-goal"
          data-selected-type={@catch_up_selected_type}
          class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/30 px-4 py-4"
        >
          <p class="text-sm font-semibold text-[var(--session-ink)]">
            Set a {catch_up_type_label(@catch_up_selected_type)} performance goal first.
          </p>
          <p class="mt-1 text-xs text-[var(--session-muted)]">
            Catch-up targets need a real type-specific goal; no temporary goal is used.
          </p>
        </div>
      <% end %>

      <%= if @catch_up_plan do %>
        <div
          id="home-catch-up-result"
          data-selected-type={@catch_up_plan.selected_burpee_type}
          class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/30 px-4 py-4"
        >
          <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
            Maintenance catch-up
          </p>
          <p class="mt-2 text-lg font-semibold tracking-[-0.03em] text-[var(--session-ink)]">
            {catch_up_type_label(@catch_up_plan.selected_burpee_type)} · {@catch_up_plan.total_duration_min} min
          </p>
          <p class="mt-1 text-sm text-[var(--session-muted)]">
            One {@catch_up_plan.total_duration_min} min session · Split: {catch_up_split_label(
              @catch_up_plan.weekly_split_effect
            )}
          </p>
          <ol class="mt-3 space-y-2 text-sm text-[var(--session-muted)]">
            <li :for={{session, index} <- Enum.with_index(@catch_up_plan.selected_sessions, 1)}>
              {index}. {session.target_reps} reps · {catch_up_kind_label(session.suggestion_kind)}
            </li>
          </ol>
          <p class="mt-3 text-xs text-[var(--session-muted)]">
            {catch_up_intensity_copy(@catch_up_plan.total_duration_min)}
          </p>
          <p class="mt-2 text-xs text-[var(--session-muted)]">
            {List.first(@catch_up_plan.rationale)}
          </p>
          <button
            id="use-catch-up-plan"
            type="button"
            phx-click="use_catch_up_plan"
            class="mt-4 inline-flex w-full items-center justify-center rounded-2xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-4 py-3 text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--session-bg)] transition active:scale-95 hover:opacity-90"
          >
            Use this plan
          </button>
        </div>
      <% end %>
    </section>
    """
  end

  defp catch_up_type_label(:six_count), do: "Six-count"
  defp catch_up_type_label(:navy_seal), do: "Navy SEAL"

  defp catch_up_intensity_copy(duration_min) when duration_min <= 20,
    do: "Standard 20-minute target based on your current capacity."

  defp catch_up_intensity_copy(duration_min) when duration_min <= 30,
    do:
      "Reduced for longer catch-up work — targets use about 85% of your current 20-minute capacity."

  defp catch_up_intensity_copy(duration_min) when duration_min <= 40,
    do:
      "Reduced for longer catch-up work — targets use about 75% of your current 20-minute capacity."

  defp catch_up_intensity_copy(duration_min) when duration_min <= 60,
    do:
      "Reduced for longer catch-up work — targets use about 60% of your current 20-minute capacity."

  defp catch_up_intensity_copy(_duration_min),
    do:
      "Reduced for longer catch-up work — targets use about 50% of your current 20-minute capacity."

  defp catch_up_split_label(:preserves_contract), do: "standard"
  defp catch_up_split_label(:counts_but_non_standard), do: "non-standard"
  defp catch_up_split_label(:over_target), do: "over target"

  defp catch_up_kind_label(:safe_progress), do: "small step"
  defp catch_up_kind_label(kind), do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp primary_home_action(nil, _min_done, _goal) do
    %{
      title: "Create your first training session",
      reason: "Set your burpee type, reps, and duration before starting.",
      label: "Create",
      path: ~p"/workouts/new"
    }
  end

  defp primary_home_action(plan, min_done, goal) when min_done >= goal do
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"

    %{
      title: "Weekly work is complete",
      reason:
        "#{plan.name} · #{plan.burpee_count_target} reps · #{plan.target_duration_min} min · #{type_label} is ready if you want extra work.",
      label: "Start",
      path: ~p"/session/#{plan.id}"
    }
  end

  defp primary_home_action(plan, min_done, goal) do
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
    minutes_left = max(goal - min_done, 0)

    %{
      title: "Start #{plan.target_duration_min} min · #{type_label}",
      reason:
        "#{plan.name} · #{plan.burpee_count_target} reps · #{minutes_left} min left this week.",
      label: "Start",
      path: ~p"/session/#{plan.id}"
    }
  end

  attr(:suggestions, :list, required: true)

  defp weekly_split_panel(%{suggestions: []} = assigns), do: ~H""

  defp weekly_split_panel(assigns) do
    ~H"""
    <section
      id="home-weekly-split-panel"
      data-home-weekly-split
      class="space-y-4 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)] px-5 py-5"
    >
      <div class="space-y-1">
        <p class="text-[10px] font-medium uppercase tracking-[0.18em] text-[var(--session-muted)]">
          This week's split
        </p>
        <p class="text-sm text-[var(--session-muted)]">
          Aim for one harder session and one easier session per burpee type.
        </p>
      </div>

      <div class="space-y-4">
        <div :for={split <- @suggestions} class="space-y-2">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-[var(--session-ink)]">
            {catch_up_type_label(split.burpee_type)}
          </p>
          <div class="grid grid-cols-2 gap-2">
            <.weekly_split_action split={split} role="hard" suggestion={split.hard} />
            <.weekly_split_action split={split} role="easy" suggestion={split.easy} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:split, :map, required: true)
  attr(:role, :string, required: true)
  attr(:suggestion, :any, required: true)

  defp weekly_split_action(assigns) do
    label = if assigns.role == "easy", do: "Easier", else: "Harder"
    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/25 px-3 py-3">
      <p class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--session-muted)]">
        {@label}
      </p>
      <p class="mt-1 text-lg font-semibold tabular-nums text-[var(--session-ink)]">
        {@suggestion.burpee_count_target} reps
      </p>
      <p class="text-xs text-[var(--session-muted)]">
        {@suggestion.target_duration_min} min · {catch_up_kind_label(@suggestion.kind)}
      </p>
      <button
        id={"use-coach-target-#{Atom.to_string(@split.burpee_type) |> String.replace("_", "-")}-#{@role}"}
        type="button"
        phx-click="use_coach_target"
        phx-value-type={@split.burpee_type}
        phx-value-role={@role}
        class="mt-3 text-sm text-[var(--session-ink)] hover:text-[var(--session-muted)] transition font-medium whitespace-nowrap"
      >
        Plan {@label |> String.downcase()} →
      </button>
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
