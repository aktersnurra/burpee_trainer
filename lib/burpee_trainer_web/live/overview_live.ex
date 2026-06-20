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

  defp trained_day_count(%MapSet{} = trained_days), do: MapSet.size(trained_days)
  defp trained_day_count(trained_days) when is_list(trained_days), do: length(trained_days)

  defp week_complete?(this_week, goal_min), do: this_week.minutes >= goal_min

  defp week_progress_pct(this_week, goal_min) when goal_min > 0 do
    this_week.minutes
    |> Kernel./(goal_min)
    |> Kernel.*(100)
    |> min(100)
    |> max(0)
  end

  defp week_progress_pct(_this_week, _goal_min), do: 0

  defp minutes_left(this_week, goal_min), do: max(round(goal_min - this_week.minutes), 0)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:home}
    >
      <div
        id="home-page"
        class="session-surface mx-auto max-w-lg space-y-7 pb-24 text-[var(--session-ink)]"
      >
        <.qs_info_note
          :if={@level_status.at_risk?}
          title={"Level #{level_label(@level_status.level)} expires in #{@level_status.days_left}d"}
          icon="hero-exclamation-triangle"
          class="bg-[var(--session-track)]/40"
        >
          Train both burpee types this week to keep it.
        </.qs_info_note>

        <% week_complete? = week_complete?(@this_week, @goal_min) %>
        <% progress_pct = week_progress_pct(@this_week, @goal_min) %>

        <.qs_surface
          id="home-status-strip"
          class="space-y-6 px-5 py-5 text-sm text-[var(--session-muted)]"
        >
          <div class="flex items-start justify-between gap-4">
            <p class="qs-tabular text-xl font-medium tracking-[-0.03em] text-[var(--session-ink)]">
              {round(@this_week.minutes)}
              <span class="text-[var(--session-muted)]">/ {round(@goal_min)} min this week</span>
            </p>
            <p class="shrink-0 text-right text-base tabular-nums">
              {if week_complete?,
                do: "Complete",
                else: "#{minutes_left(@this_week, @goal_min)} min left"}
            </p>
          </div>
          <div
            id="home-week-progress"
            class="h-1.5 overflow-hidden rounded-full bg-[var(--session-border)]"
            role="progressbar"
            aria-valuemin="0"
            aria-valuemax={round(@goal_min)}
            aria-valuenow={min(round(@this_week.minutes), round(@goal_min))}
            aria-label="Weekly training minutes"
          >
            <div
              class="h-full rounded-full bg-[var(--session-progress)]"
              style={"width: #{progress_pct}%"}
            />
          </div>
          <div class="flex items-center justify-between gap-4">
            <p class="text-base">{trained_day_count(@trained_days)} trained days</p>
            <p class="qs-meta text-sm tracking-[0.14em] text-[var(--session-muted)]">
              Level {level_label(@level_status.level)}
            </p>
          </div>
          <div class="grid grid-cols-7 gap-2 pt-1 text-center text-sm">
            <div :for={day <- ~w(M T W T F S S)} class="space-y-2">
              <p>{day}</p>
              <span class="mx-auto block size-2 rounded-full bg-[var(--session-border)]" />
            </div>
          </div>
        </.qs_surface>

        <%= if week_complete? do %>
          <.qs_surface
            id="home-week-complete"
            class="space-y-4 bg-[var(--session-surface)]/60 px-5 py-6"
          >
            <div class="space-y-2">
              <h1 class="qs-heading-tight text-4xl font-semibold leading-none text-[var(--session-ink)]">
                Week complete
              </h1>
              <p id="home-coach-guidance" class="text-sm leading-6 text-[var(--session-muted)]">
                Coach says: You’re done for the week. Come back Monday.
              </p>
            </div>
            <button
              id="home-log-session"
              type="button"
              phx-click="open_log_modal"
              class="text-sm font-medium text-[var(--session-ink)] hover:text-[var(--session-muted)]"
            >
              Log past session
            </button>
          </.qs_surface>
        <% else %>
          <section id="home-primary-workout" class="space-y-6">
            <%= if @last_plan do %>
              <% action = primary_home_action(@last_plan, round(@this_week.minutes), round(@goal_min)) %>
              <.qs_surface id="home-prescription" class="bg-[var(--session-surface)]/60">
                <div class="space-y-6 px-5 py-6">
                  <div class="space-y-3">
                    <p class="text-lg text-[var(--session-muted)]">Today’s prescription</p>
                    <div class="space-y-1.5">
                      <h2 class="qs-heading-tight text-5xl font-semibold leading-none text-[var(--session-ink)] md:text-6xl">
                        {action.title}
                      </h2>
                      <p class="text-base tabular-nums text-[var(--session-muted)]">
                        {action.detail}
                      </p>
                    </div>
                  </div>

                  <.qs_info_note id="home-coach-guidance" title="Coach note">
                    {action.reason}
                  </.qs_info_note>
                </div>

                <.qs_action_row
                  id="home-start-workout"
                  navigate={action.path}
                  icon="hero-play-solid"
                  label={action.label}
                  class="border-t border-[var(--session-border)]"
                />
              </.qs_surface>
            <% end %>

            <.qs_surface
              :if={!@last_plan}
              id="home-prescription"
              class="bg-[var(--session-surface)]/60"
            >
              <div class="space-y-6 px-5 py-6">
                <div class="space-y-3">
                  <p class="text-lg text-[var(--session-muted)]">Today’s prescription</p>
                  <h2 class="qs-heading-tight text-5xl font-semibold leading-none text-[var(--session-ink)]">
                    No workout yet
                  </h2>
                </div>

                <.qs_info_note id="home-coach-guidance" title="Coach note">
                  Choose a workout to get moving.
                </.qs_info_note>
              </div>

              <.qs_action_row
                id="home-start-workout"
                navigate={~p"/workouts"}
                icon="hero-play-solid"
                label="Choose workout"
                class="border-t border-[var(--session-border)]"
              />
            </.qs_surface>

            <.qs_surface
              id="home-secondary-actions"
              class="overflow-hidden divide-y divide-[var(--session-border)] bg-[var(--session-surface)]/45"
            >
              <.qs_action_row
                id="home-change-workout"
                navigate={~p"/workouts"}
                icon="hero-arrows-right-left"
                label="Change workout"
                description="Choose a different session"
              />
              <.qs_action_row
                id="home-log-session"
                icon="hero-document-text"
                label="Log past session"
                description="Add a session you already completed"
                phx-click="open_log_modal"
              />
              <div
                id="home-theme-action"
                class="flex items-center justify-between gap-4 px-5 py-4"
              >
                <div class="space-y-1">
                  <p class="text-sm font-medium text-[var(--session-ink)]">Theme</p>
                  <p class="text-sm text-[var(--session-muted)]">Switch light or dark mode</p>
                </div>
                <Layouts.theme_button
                  id="home-theme-toggle"
                  label={false}
                  session_nav?={true}
                  class="shrink-0"
                />
              </div>
            </.qs_surface>

            <.qs_surface
              id="home-catch-up-panel"
              class="space-y-5 bg-[var(--session-surface)]/35 px-5 py-5"
            >
              <div class="space-y-2">
                <p class="qs-meta text-xs tracking-[0.16em] text-[var(--session-muted)]">
                  Finish the week
                </p>
                <h2 class="qs-heading-tight text-2xl font-semibold text-[var(--session-ink)]">
                  Build catch-up sessions
                </h2>
                <p class="text-sm leading-6 text-[var(--session-muted)]">
                  Turn the remaining weekly minutes into standard training sessions you can edit before starting.
                </p>
              </div>

              <div class="grid grid-cols-2 gap-2">
                <button
                  id="catch-up-six-count"
                  type="button"
                  phx-click="plan_catch_up"
                  phx-value-type="six_count"
                  class={[
                    "rounded-xl border px-4 py-3 text-left text-sm transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]",
                    if(@catch_up_selected_type == :six_count,
                      do:
                        "border-[var(--session-ink)] bg-[var(--session-track)]/45 text-[var(--session-ink)]",
                      else: "border-[var(--session-border)] text-[var(--session-muted)]"
                    )
                  ]}
                >
                  <span class="block font-medium">Six-count</span>
                  <span class="block text-xs opacity-80">Bodyweight volume</span>
                </button>
                <button
                  id="catch-up-navy-seal"
                  type="button"
                  phx-click="plan_catch_up"
                  phx-value-type="navy_seal"
                  class={[
                    "rounded-xl border px-4 py-3 text-left text-sm transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]",
                    if(@catch_up_selected_type == :navy_seal,
                      do:
                        "border-[var(--session-ink)] bg-[var(--session-track)]/45 text-[var(--session-ink)]",
                      else: "border-[var(--session-border)] text-[var(--session-muted)]"
                    )
                  ]}
                >
                  <span class="block font-medium">Navy SEAL</span>
                  <span class="block text-xs opacity-80">Push-up focused</span>
                </button>
              </div>

              <%= if @catch_up_plan do %>
                <div
                  id="home-catch-up-preview"
                  class="space-y-4 rounded-2xl border border-[var(--session-border)] bg-[var(--session-track)]/25 p-4"
                >
                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <p class="text-sm text-[var(--session-muted)]">Catch-up preview</p>
                      <p class="qs-tabular text-xl font-medium text-[var(--session-ink)]">
                        {length(@catch_up_plan.selected_sessions)} sessions · {@catch_up_plan.total_duration_min} min
                      </p>
                    </div>
                    <p class="qs-meta text-xs tracking-[0.14em] text-[var(--session-muted)]">
                      {String.replace(Atom.to_string(@catch_up_plan.risk), "_", " ")}
                    </p>
                  </div>

                  <ul class="space-y-2 text-sm leading-6 text-[var(--session-muted)]">
                    <li :for={reason <- @catch_up_plan.rationale}>{reason}</li>
                  </ul>

                  <button
                    id="home-create-catch-up"
                    type="button"
                    phx-click="use_catch_up_plan"
                    class="w-full rounded-xl bg-[var(--session-ink)] px-4 py-3 text-sm font-medium text-[var(--session-bg)] transition hover:opacity-90"
                  >
                    Create catch-up plan
                  </button>
                </div>
              <% end %>
            </.qs_surface>
          </section>
        <% end %>
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
            class="session-surface relative z-10 w-full sm:max-w-md max-h-[calc(100dvh-1rem)] sm:max-h-[calc(100dvh-3rem)] overflow-y-auto bg-[var(--session-surface)] text-[var(--session-ink)] border border-[var(--session-border)] rounded-xl rounded-t-xl sm:rounded-xl p-5 sm:p-6"
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

  defp catch_up_type_label(:six_count), do: "Six-count"
  defp catch_up_type_label(:navy_seal), do: "Navy SEAL"

  defp primary_home_action(plan, min_done, goal) when min_done >= goal do
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"

    %{
      title: "#{plan.target_duration_min} min · #{type_label}",
      detail: "#{plan.burpee_count_target} reps",
      reason:
        "#{plan.name} is ready, but the weekly target is already complete. No extra work is needed — only log a missed session if your history is incomplete.",
      label: "Start session",
      path: ~p"/session/#{plan.id}"
    }
  end

  defp primary_home_action(plan, min_done, goal) do
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
    minutes_left = max(goal - min_done, 0)

    %{
      title: "#{plan.target_duration_min} min · #{type_label}",
      detail: "#{plan.burpee_count_target} reps",
      reason:
        "#{plan.name} is the next planned session. Start with this #{plan.target_duration_min}-minute #{type_label} workout to move the week forward; you still have #{minutes_left} min left right now.",
      label: "Start session",
      path: ~p"/session/#{plan.id}"
    }
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()
end
