defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  Session runner — client-driven execution model.

  On mount the server loads the persisted workout plan and pushes serialized
  plan data via `session_ready`. The client derives warmup/workout timelines,
  owns the clock, state machine, beeps, and high-frequency DOM updates. The
  server stays idle during the workout and only validates/saves completion.

  State machine (server-side phase):
      :idle → :running → :done

  The client drives everything in between. When the workout completes the
  client pushes `session_complete` and the server shows the save modal.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Duration, Mood, Planner, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        summary = Planner.summary(plan)

        socket =
          socket
          |> assign(:plan, plan)
          |> assign(:summary, summary)
          |> assign(:phase, if(plan.blocks == [], do: :not_runnable, else: :idle))
          |> assign(:mood, nil)
          |> assign(:warmup_asked, false)
          |> assign(:completion_tags, [])
          |> assign(:completion_form, nil)
          |> assign(:celebration, nil)
          |> assign(:capture_mode, :timed)
          |> assign(:tracking_state, :idle)
          |> assign(:tracked_finish, nil)
          |> assign(:tracking_error, nil)

        {:ok, push_event(socket, "session_ready", %{plan: serialize_plan(plan)})}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/workouts")}
    end
  end

  @impl true
  def handle_event("session_started", _params, socket) do
    {:noreply, socket |> assign(:phase, :running) |> assign(:warmup_asked, true)}
  end

  def handle_event("choose_tracked", _, socket) do
    {:noreply, socket |> assign(:capture_mode, :tracked) |> assign(:tracking_state, :arming)}
  end

  def handle_event("tracker_ready", _, socket) do
    {:noreply, assign(socket, :tracking_state, :ready)}
  end

  def handle_event("track", %{"state" => "lost"}, socket) do
    {:noreply, assign(socket, :tracking_state, :degraded)}
  end

  def handle_event("track", %{"state" => "live"}, socket) do
    {:noreply, assign(socket, :tracking_state, :running)}
  end

  def handle_event(
        "finish",
        %{"reps" => reps, "duration_ms" => duration_ms, "cadence_ms" => cadence},
        socket
      ) do
    duration_sec = div(duration_ms + 999, 1000)

    finish = %{
      reps: reps,
      duration_ms: duration_ms,
      cadence_ms: cadence
    }

    socket =
      socket
      |> assign(:phase, :done)
      |> assign(:tracked_finish, finish)
      |> assign(:tracking_state, :review)
      |> assign(:completion_form, build_completion_form(socket, reps, duration_sec))

    {:noreply, socket}
  end

  def handle_event("session_complete", payload, socket) do
    case parse_completion_payload(payload) do
      {:ok, %{main: main}} ->
        socket =
          socket
          |> assign(:phase, :done)
          |> assign(
            :completion_form,
            build_completion_form(socket, main.burpee_count_done, main.duration_sec)
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Invalid session result. Please try the workout again.")}
    end
  end

  def handle_event("set_mood", %{"mood" => mood_str}, socket) do
    mood =
      case Mood.parse(mood_str) do
        {:ok, mood} -> mood
        {:error, _reason} -> socket.assigns.mood
      end

    {:noreply, assign(socket, :mood, mood)}
  end

  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    tags = socket.assigns.completion_tags
    new_tags = if tag in tags, do: List.delete(tags, tag), else: [tag | tags]
    {:noreply, assign(socket, :completion_tags, new_tags)}
  end

  def handle_event("validate_session", %{"workout_session" => params}, socket) do
    changeset =
      socket.assigns.plan
      |> blank_session()
      |> WorkoutSession.from_plan_changeset(coerce_duration(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :completion_form, to_form(changeset))}
  end

  def handle_event("save_session", %{"workout_session" => params}, socket) do
    %{current_user: user, plan: plan, mood: mood, completion_tags: tags} = socket.assigns

    session_params =
      params
      |> coerce_duration()
      |> Map.put("mood", mood)
      |> Map.put("tags", tags |> Enum.sort() |> Enum.join(","))

    create_session =
      if socket.assigns.capture_mode == :tracked && socket.assigns.tracked_finish do
        tracked = socket.assigns.tracked_finish

        Workouts.create_tracked_session_from_plan(
          user,
          plan,
          Map.merge(session_params, %{
            "cadence_ms" => tracked.cadence_ms,
            "target_pace_sec" => plan.sec_per_burpee
          })
        )
      else
        Workouts.create_session_from_plan(user, plan, session_params)
      end

    case create_session do
      {:ok, session} ->
        case Workouts.session_milestones(user, session) do
          [] ->
            {:noreply,
             socket
             |> put_flash(:info, "Session saved.")
             |> push_navigate(to: ~p"/stats")}

          events ->
            {:noreply, assign(socket, :celebration, events)}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :completion_form, to_form(changeset))}
    end
  end

  def handle_event("dismiss_celebration", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/stats")}
  end

  def handle_event("discard", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workouts")}
  end

  defp serialize_plan(plan) do
    %{
      sec_per_burpee: plan.sec_per_burpee,
      blocks:
        Enum.map(plan.blocks, fn block ->
          %{
            position: block.position,
            repeat_count: block.repeat_count,
            sets:
              Enum.map(block.sets, fn set ->
                %{
                  position: set.position,
                  burpee_count: set.burpee_count,
                  sec_per_rep: set.sec_per_rep,
                  sec_per_burpee: set.sec_per_burpee,
                  end_of_set_rest: set.end_of_set_rest
                }
              end)
          }
        end)
    }
  end

  defp blank_session(plan), do: %WorkoutSession{user_id: plan.user_id, plan_id: plan.id}

  defp coerce_duration(params) do
    case Duration.parse_minutes_to_seconds(Map.get(params, "duration_min", "")) do
      {:ok, seconds} -> Map.put(params, "duration_sec_actual", seconds)
      {:error, _reason} -> params
    end
  end

  defp parse_completion_payload(%{"main" => main}) when is_map(main) do
    with {:ok, main_result} <- parse_completion_result(main) do
      {:ok, %{main: main_result}}
    end
  end

  defp parse_completion_payload(_payload), do: {:error, :invalid_payload}

  defp parse_completion_result(result) do
    with {:ok, burpee_count_done} <- non_negative_integer(result, "burpee_count_done"),
         {:ok, duration_sec} <- non_negative_integer(result, "duration_sec") do
      {:ok, %{burpee_count_done: burpee_count_done, duration_sec: duration_sec}}
    end
  end

  defp non_negative_integer(result, key) do
    case Map.get(result, key, 0) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, :invalid_number}
    end
  end

  defp build_completion_form(socket, burpee_count_done, duration_sec_actual) do
    %{plan: plan, summary: summary} = socket.assigns

    attrs = %{
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "burpee_count_planned" => summary.burpee_count_total,
      "duration_sec_planned" => round(summary.duration_sec_total),
      "burpee_count_actual" => burpee_count_done,
      "duration_sec_actual" => duration_sec_actual
    }

    plan
    |> blank_session()
    |> WorkoutSession.from_plan_changeset(attrs)
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_level={@current_level}>
      <.celebration_overlay :if={@celebration} events={@celebration} />
      <div
        id="burpee-session"
        phx-hook="SessionHook"
        class="fixed inset-0 z-[60] flex flex-col bg-[var(--session-bg)] text-[var(--session-ink)]"
      >
        <div class="pointer-events-none absolute inset-x-0 top-0 z-20 flex items-center justify-between px-5 pt-5 text-[var(--session-muted)] sm:px-8 sm:pt-8">
          <.link
            navigate={~p"/workouts"}
            class="pointer-events-auto flex size-9 items-center justify-center rounded-full text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
            aria-label="Back to workouts"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <span aria-hidden="true"></span>
          <button
            id="finish-early-btn"
            type="button"
            class="pointer-events-auto flex size-9 items-center justify-center rounded-full text-[var(--session-muted)] opacity-0 transition enabled:opacity-60 enabled:hover:text-[var(--session-ink)] disabled:cursor-not-allowed"
            disabled
            aria-label="Finish session early"
          >
            <.icon name="hero-flag" class="size-4" />
          </button>
        </div>

        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <div
              :if={@tracking_state == :review}
              id="tracked-review"
              class="mx-auto mt-24 w-full max-w-[430px] border-y border-[var(--session-border)] px-6 py-6 text-center font-mono text-[var(--session-ink)]"
            >
              <h2 class="text-[10px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
                Review tracked session
              </h2>
              <p class="mt-3 text-5xl font-black tracking-[-0.06em] tabular-nums">
                {@tracked_finish.reps}
              </p>
              <p class="mt-1 text-[8px] uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
                Reps
              </p>
              <span class="sr-only">{@tracked_finish.reps} reps</span>
            </div>
            <.completion_panel
              plan={@plan}
              summary={@summary}
              form={@completion_form}
              mood={@mood}
              completion_tags={@completion_tags}
            />
          <% phase when phase in [:idle, :running] -> %>
            <%= if @capture_mode == :tracked do %>
              <div
                id="pose-tracker"
                phx-hook="PoseTracker"
                phx-update="ignore"
                data-target-pace-sec={@plan.sec_per_burpee}
              />
            <% end %>

            <.session_runner
              phase={phase}
              summary={@summary}
              warmup_asked={@warmup_asked}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp not_runnable_panel(assigns) do
    ~H"""
    <div class="flex min-h-dvh items-center justify-center bg-[var(--session-bg)] px-8 text-center text-[var(--session-ink)]">
      <div class="max-w-xs border-y border-[var(--session-border)] py-8 font-mono">
        <p class="text-[11px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
          No timed events
        </p>
        <p class="mt-4 text-sm leading-relaxed text-[var(--session-ink)]">
          Add at least one block with one set before running.
        </p>
      </div>
    </div>
    """
  end

  attr(:phase, :atom, required: true)
  attr(:summary, :map, required: true)
  attr(:warmup_asked, :boolean, required: true)

  defp session_runner(assigns) do
    ~H"""
    <div
      id="session-runner-client"
      class="relative flex min-h-dvh w-full overflow-hidden bg-[var(--session-bg)] px-5 py-8 text-[var(--session-ink)]"
      phx-update="ignore"
    >
      <div class="mx-auto flex min-h-[calc(100dvh-4rem)] w-full max-w-[430px] flex-col items-center justify-start pt-[8vh]">
        <div
          id="phase-label"
          class="mx-auto mb-6 hidden w-fit font-mono uppercase leading-none text-[var(--session-ink)]"
        >
        </div>

        <div
          id="ring-container"
          class="group relative mx-auto h-[320px] w-[320px] cursor-pointer select-none touch-manipulation sm:h-[340px] sm:w-[340px]"
          style="flex: 0 0 320px;"
          role="button"
          tabindex="0"
          aria-label="Pause or resume session"
        >
          <svg
            id="ring-svg"
            viewBox="0 0 280 280"
            class="absolute inset-0 z-10 size-full"
            aria-hidden="true"
          >
          </svg>

          <svg
            viewBox="0 0 280 280"
            class="pointer-events-none absolute inset-0 z-20 size-full"
            aria-hidden="true"
          >
            <circle
              id="flash-circle"
              cx="140"
              cy="140"
              r="107"
              fill="none"
              stroke="var(--session-ink)"
              stroke-width="10"
              opacity="0"
              transform="rotate(-90 140 140)"
            />
          </svg>

          <div
            id="instrument-face"
            class="pointer-events-none absolute inset-0 z-0 flex flex-col items-center justify-center rounded-full transition-colors duration-200"
          >
            <div id="rest-ripples" class="absolute inset-0 hidden" aria-hidden="true">
              <span class="rest-ripple rest-ripple-outer"></span>
              <span class="rest-ripple rest-ripple-middle"></span>
              <span class="rest-ripple rest-ripple-inner"></span>
            </div>
            <span
              id="count"
              class="text-[132px] leading-none tracking-[-0.085em] tabular-nums text-[var(--session-ink)] sm:text-[144px]"
            >
              —
            </span>
            <span
              id="down-word"
              class="absolute mt-28 font-mono text-[10px] font-semibold uppercase tracking-[0.32em] text-[var(--session-soft-muted)]"
              style="display: none;"
            >
              Down
            </span>

            <svg
              id="pause-icon"
              viewBox="0 0 48 48"
              fill="currentColor"
              class="absolute h-16 w-16 text-[var(--session-ink)]"
              style="display: none; opacity: 0.8;"
              aria-hidden="true"
            >
              <rect x="10" y="8" width="10" height="32" rx="2" />
              <rect x="28" y="8" width="10" height="32" rx="2" />
            </svg>
          </div>
        </div>

        <div
          id="set-glyphs"
          class="mt-6 flex min-h-7 w-full items-end justify-center gap-5"
          aria-label="Workout sets"
        >
        </div>

        <div class="mt-8 grid w-full grid-cols-2 border-y border-[var(--session-border)] text-center font-mono">
          <div class="border-r border-[var(--session-border)] px-2 py-4">
            <div
              id="total-done"
              class="text-[40px] font-medium leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)]"
            >
              0
            </div>
            <div class="mt-1 text-[8px] font-semibold uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
              Done / <span id="total-plan">{@summary.burpee_count_total}</span>
            </div>
          </div>
          <div class="px-2 py-4">
            <div
              id="time-left"
              class="text-[40px] font-medium leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)]"
            >
              {Fmt.duration_sec(round(@summary.duration_sec_total))}
            </div>
            <div class="mt-1 text-[8px] font-semibold uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
              Time left
            </div>
          </div>
        </div>
      </div>

      <%= if @phase == :idle do %>
        <.tap_to_start_overlay warmup_asked={@warmup_asked} />
      <% end %>
    </div>
    """
  end

  attr(:warmup_asked, :boolean, required: true)

  defp tap_to_start_overlay(assigns) do
    ~H"""
    <div
      id="start-overlay"
      class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-6 bg-[var(--session-bg)] text-center text-[var(--session-ink)]"
    >
      <%= if not @warmup_asked do %>
        <span class="font-mono text-[11px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
          Warmup?
        </span>
        <div class="flex gap-2">
          <button
            type="button"
            id="warmup-yes-btn"
            class="min-w-24 border border-[var(--session-border)] px-6 py-4 font-mono text-[10px] uppercase tracking-[0.2em] text-[var(--session-ink)] transition active:scale-[0.98] hover:border-[var(--session-ink)]"
          >
            Yes
          </button>
          <button
            type="button"
            id="warmup-skip-btn"
            class="min-w-24 border border-[var(--session-border)] px-6 py-4 font-mono text-[10px] uppercase tracking-[0.2em] text-[var(--session-soft-muted)] transition active:scale-[0.98] hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]"
          >
            Skip
          </button>
        </div>
      <% else %>
        <span class="font-mono text-[11px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
          How do you feel?
        </span>
        <div class="flex gap-2">
          <%= for {icon, label, value} <- [{"hero-face-frown", "Tired", -1}, {"hero-minus-circle", "OK", 0}, {"hero-bolt", "Hyped", 1}] do %>
            <button
              type="button"
              phx-click="session_started"
              phx-value-mood={value}
              class="min-w-20 border border-[var(--session-border)] px-4 py-4 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--session-ink)] transition active:scale-[0.98] hover:border-[var(--session-ink)]"
            >
              {label}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:plan, :any, required: true)
  attr(:summary, :map, required: true)
  attr(:form, :any, required: true)
  attr(:mood, :integer, default: nil)
  attr(:completion_tags, :list, default: [])

  @mood_options [
    {"hero-face-frown", "Tired", -1},
    {"hero-minus-circle", "OK", 0},
    {"hero-bolt", "Hyped", 1}
  ]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  defp completion_panel(assigns) do
    assigns =
      assign(assigns,
        mood_options: @mood_options,
        tag_options: @tag_options
      )

    ~H"""
    <div class="mx-auto flex min-h-dvh w-full max-w-[430px] flex-col justify-start bg-[var(--session-bg)] px-5 pb-10 pt-[12vh] text-[var(--session-ink)]">
      <%!-- Header --%>
      <div class="text-center font-mono">
        <p class="text-[11px] font-semibold uppercase tracking-[0.28em] text-[var(--session-soft-muted)]">
          Session complete
        </p>
        <p class="mt-3 text-[10px] uppercase tracking-[0.2em] text-[var(--session-soft-muted)] tabular-nums">
          {@summary.burpee_count_total} reps · {Fmt.duration_sec(round(@summary.duration_sec_total))} planned
        </p>
      </div>

      <%!-- Mood --%>
      <div class="mt-8 flex border-y border-[var(--session-border)] font-mono">
        <%= for {icon, label, value} <- @mood_options do %>
          <button
            type="button"
            phx-click="set_mood"
            phx-value-mood={value}
            class={[
              "flex flex-1 flex-col items-center py-4 text-[10px] uppercase tracking-[0.2em] transition",
              if(@mood == value,
                do: "bg-[var(--session-ink)] text-[var(--session-bg)]",
                else: "text-[var(--session-soft-muted)] hover:text-[var(--session-ink)]"
              )
            ]}
          >
            {label}
          </button>
          <%= if value != 1 do %>
            <div class="w-px self-stretch bg-[var(--session-border)]" />
          <% end %>
        <% end %>
      </div>

      <.form
        for={@form}
        id="session-completion-form"
        phx-change="validate_session"
        phx-submit="save_session"
        class="mt-6 space-y-4"
      >
        <%!-- Reps + Duration dials --%>
        <div class="grid grid-cols-2 overflow-hidden border-y border-[var(--session-border)] font-mono">
          <div class="space-y-1 border-r border-[var(--session-border)] p-5">
            <p class="text-[8px] uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
              Reps
            </p>
            <input
              type="number"
              name={@form[:burpee_count_actual].name}
              value={@form[:burpee_count_actual].value}
              min="0"
              inputmode="numeric"
              class="w-full bg-transparent text-4xl font-black leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)] focus:outline-none"
            />
          </div>
          <div class="space-y-1 p-5">
            <p class="text-[8px] uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">Min</p>
            <input
              type="number"
              name="workout_session[duration_min]"
              value={
                if v = @form[:duration_sec_actual].value,
                  do: Float.round(v / 60, 1),
                  else: ""
              }
              min="0"
              step="0.1"
              inputmode="decimal"
              class="w-full bg-transparent text-4xl font-black leading-none tracking-[-0.04em] tabular-nums text-[var(--session-ink)] focus:outline-none"
            />
          </div>
        </div>

        <%!-- Tags --%>
        <div class="flex flex-wrap gap-2 font-mono">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              class={[
                "border px-3 py-2 text-[9px] uppercase tracking-[0.16em] transition",
                tag in @completion_tags &&
                  "border-[var(--session-ink)] bg-[var(--session-ink)] text-[var(--session-bg)]",
                tag not in @completion_tags &&
                  "border-[var(--session-border)] text-[var(--session-soft-muted)] hover:border-[var(--session-ink)] hover:text-[var(--session-ink)]"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <%!-- Note --%>
        <div class="border-y border-[var(--session-border)] p-4 font-mono">
          <p class="mb-2 text-[8px] uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
            Note
          </p>
          <textarea
            name={@form[:note_post].name}
            rows="2"
            placeholder="How did it go?"
            class="w-full resize-none bg-transparent text-sm text-[var(--session-ink)] placeholder:text-[var(--session-muted)] focus:outline-none"
          >{@form[:note_post].value}</textarea>
        </div>

        <%!-- Hidden fields --%>
        <div class="hidden">
          <.input field={@form[:burpee_type]} type="text" />
          <.input field={@form[:burpee_count_planned]} type="number" />
          <.input field={@form[:duration_sec_planned]} type="number" />
        </div>

        <%!-- Actions --%>
        <button
          type="submit"
          class="flex w-full items-center justify-center border border-[var(--session-ink)] bg-[var(--session-ink)] py-4 font-mono text-[10px] font-semibold uppercase tracking-[0.2em] text-[var(--session-bg)] transition active:scale-[0.99]"
        >
          Save session
        </button>
        <div class="text-center">
          <button
            type="button"
            phx-click="discard"
            data-confirm="Discard this session without saving?"
            class="font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--session-soft-muted)] transition hover:text-[var(--session-ink)]"
          >
            Discard
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr(:events, :list, required: true)

  defp celebration_overlay(assigns) do
    ~H"""
    <div
      id="celebration-overlay"
      class="fixed inset-0 z-50 flex flex-col items-center justify-center px-6"
      style="background-color: #0C0E14;"
    >
      <div class="flex w-full max-w-[420px] flex-col items-center gap-6">
        <p class="text-xs font-semibold uppercase tracking-[0.3em]" style="color: #4A9EFF;">
          {if length(@events) > 1, do: "New achievements", else: "New achievement"}
        </p>

        <div class="flex w-full flex-col gap-3">
          <%= for {event, idx} <- Enum.with_index(@events) do %>
            <div
              class="rounded-[10px] bg-base-300 p-5 text-center"
              style={if idx == 0, do: "border: 1px solid #4A9EFF;", else: ""}
            >
              <p class="text-[10px] uppercase tracking-widest text-base-content/40">
                {celebration_title(event)}
              </p>
              <p class="mt-2 text-3xl font-bold tabular-nums" style="color: #C8D8F0;">
                {celebration_headline(event)}
              </p>
              <p class="mt-1 text-sm text-base-content/60">
                {celebration_detail(event)}
              </p>
            </div>
          <% end %>
        </div>

        <button
          type="button"
          phx-click="dismiss_celebration"
          class="w-full max-w-[420px] py-4 rounded-[10px] text-sm font-semibold tracking-wide bg-primary/75 text-primary-content hover:bg-primary/85 transition"
        >
          Continue
        </button>
      </div>
    </div>
    """
  end

  defp celebration_title(%{type: :level_up}), do: "Level up"
  defp celebration_title(%{type: :goal_reached}), do: "Goal reached"
  defp celebration_title(%{type: :week_pushup_pr}), do: "Weekly record"
  defp celebration_title(%{type: :lifetime_milestone}), do: "Lifetime milestone"
  defp celebration_title(%{type: :session_pushup_pr}), do: "Session record"
  defp celebration_title(%{type: :pace_pr}), do: "Fastest pace"
  defp celebration_title(%{type: :balanced_week}), do: "Balanced week"
  defp celebration_title(%{type: :comeback}), do: "Welcome back"

  defp celebration_headline(%{type: :level_up, value: %{to: to}}), do: "Level #{level_label(to)}"
  defp celebration_headline(%{type: :goal_reached, value: %{target: target}}), do: "#{target}"
  defp celebration_headline(%{type: :week_pushup_pr, value: v}), do: "#{v}"
  defp celebration_headline(%{type: :lifetime_milestone, value: v}), do: "#{v}"
  defp celebration_headline(%{type: :session_pushup_pr, value: v}), do: "#{v}"

  defp celebration_headline(%{type: :pace_pr, value: v}),
    do: "#{:erlang.float_to_binary(v * 1.0, decimals: 2)}s"

  defp celebration_headline(%{type: :balanced_week}), do: "40 / 40"
  defp celebration_headline(%{type: :comeback, value: v}), do: "#{v} days"

  defp celebration_detail(%{type: :level_up}), do: "Both disciplines, same week"

  defp celebration_detail(%{type: :goal_reached, value: %{deadline: :early}}),
    do: "Reps target hit ahead of schedule"

  defp celebration_detail(%{type: :goal_reached, value: %{deadline: :on_time}}),
    do: "Reps target hit right on time"

  defp celebration_detail(%{type: :goal_reached}), do: "Reps target hit"
  defp celebration_detail(%{type: :week_pushup_pr}), do: "Push-ups this week — a new best"
  defp celebration_detail(%{type: :lifetime_milestone}), do: "Total push-ups, all-time"
  defp celebration_detail(%{type: :session_pushup_pr}), do: "Push-ups in a single session"
  defp celebration_detail(%{type: :pace_pr}), do: "Per burpee — your quickest yet"
  defp celebration_detail(%{type: :balanced_week}), do: "Six-count and navy seal, evenly trained"
  defp celebration_detail(%{type: :comeback}), do: "Since your last session — back at it"

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()
end
