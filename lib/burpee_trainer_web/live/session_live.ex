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

  alias BurpeeTrainer.{Duration, Mood, Planner, PrescriptionGraph, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        summary = session_summary(plan)

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
          |> assign(:capture_setup_state, :idle)
          |> assign(:pose_capture_run, nil)
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
    %{current_user: user, plan: plan} = socket.assigns

    case Workouts.start_pose_capture_run(user, plan) do
      {:ok, run} ->
        {:noreply,
         socket
         |> assign(:capture_mode, :tracked)
         |> assign(:capture_setup_state, :arming)
         |> assign(:pose_capture_run, run)
         |> assign(:tracking_state, :arming)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:capture_mode, :timed)
         |> assign(:capture_setup_state, :idle)
         |> put_flash(:error, "Could not start camera capture. Use timer mode for this session.")}
    end
  end

  def handle_event("tracker_ready", _, socket) do
    {:noreply,
     socket
     |> assign(:capture_setup_state, :ready)
     |> assign(:tracking_state, :ready)}
  end

  def handle_event("pose_capture_chunk", params, socket) do
    %{current_user: user, pose_capture_run: run} = socket.assigns

    if run do
      case Workouts.append_pose_trace_chunk(user, run, normalize_pose_chunk_params(params)) do
        {:ok, _chunk} ->
          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, assign(socket, :tracking_error, "capture_chunk_failed")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("pose_capture_abort", params, socket) do
    reason = Map.get(params, "reason") || "client_aborted"
    {:noreply, abort_active_pose_capture(socket, reason)}
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
        maybe_complete_pose_capture_run(socket, session)

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
    {:noreply,
     socket
     |> abort_active_pose_capture("user_discarded")
     |> push_navigate(to: ~p"/workouts")}
  end

  defp abort_active_pose_capture(socket, reason) do
    %{current_user: user, pose_capture_run: run} = socket.assigns

    if run do
      case Workouts.abort_pose_capture_run(user, run, reason) do
        :ok ->
          socket
          |> assign(:pose_capture_run, nil)
          |> assign(:capture_setup_state, :aborted)

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  defp maybe_complete_pose_capture_run(socket, session) do
    %{current_user: user, pose_capture_run: run, capture_mode: capture_mode} = socket.assigns

    if capture_mode == :tracked && run do
      Workouts.complete_pose_capture_run(user, run, session)
    else
      :ok
    end
  end

  defp normalize_pose_chunk_params(params) do
    payload = Map.get(params, "payload_json") || Map.get(params, "payload") || %{}

    payload_json =
      if is_binary(payload) do
        payload
      else
        Jason.encode!(payload)
      end

    params
    |> Map.take(["segment", "chunk_index", "started_at_ms", "ended_at_ms", "sample_count"])
    |> Map.put("payload_json", payload_json)
  end

  defp session_summary(plan) do
    summary = Planner.summary(plan)
    timeline = serialize_execution_timeline(plan)

    case Enum.sum(Enum.map(timeline, &(&1.duration_sec || 0))) do
      0 -> summary
      duration_sec_total -> %{summary | duration_sec_total: duration_sec_total}
    end
  end

  defp serialize_plan(plan) do
    %{
      sec_per_burpee: plan.sec_per_burpee,
      timeline: serialize_execution_timeline(plan),
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

  defp serialize_execution_timeline(%{steps: steps} = plan) when is_list(steps) and steps != [] do
    blocks_by_position = Map.new(plan.blocks || [], &{&1.position, &1})

    steps
    |> Enum.sort_by(& &1.position)
    |> Enum.flat_map(&serialize_plan_step(&1, blocks_by_position))
  end

  defp serialize_execution_timeline(plan) do
    rests = decode_additional_rests(plan.additional_rests)
    finish_sec = Planner.summary(plan).duration_sec_total

    plan
    |> PrescriptionGraph.build(rests, finish_sec)
    |> Map.fetch!(:nodes)
    |> Enum.flat_map(&serialize_execution_node/1)
  end

  defp serialize_plan_step(
         %{kind: :block_run, block_position: block_position, repeat_count: repeat_count},
         blocks_by_position
       ) do
    case Map.fetch(blocks_by_position, block_position) do
      {:ok, block} -> block |> Map.put(:repeat_count, repeat_count) |> block_events()
      :error -> []
    end
  end

  defp serialize_plan_step(%{kind: :rest, rest_sec: rest_sec}, _blocks_by_position) do
    [
      %{
        phase: "rest",
        duration_sec: rest_sec,
        burpee_count: nil,
        sec_per_burpee: nil,
        label: "Rest"
      }
    ]
  end

  defp serialize_plan_step(_step, _blocks_by_position), do: []

  defp serialize_execution_node(%PrescriptionGraph.BlockRunNode{} = node) do
    node.block
    |> Map.put(:repeat_count, node.repeat_count)
    |> block_events()
  end

  defp serialize_execution_node(%PrescriptionGraph.RestNode{} = node) do
    [
      %{
        phase: "rest",
        duration_sec: node.duration_sec,
        burpee_count: nil,
        sec_per_burpee: nil,
        label: "Rest"
      }
    ]
  end

  defp serialize_execution_node(_node), do: []

  defp block_events(block) do
    sets = Enum.sort_by(block.sets || [], & &1.position)

    for _round <- 1..(block.repeat_count || 1), set <- sets, reduce: [] do
      events ->
        work = %{
          phase: "work",
          duration_sec: set.burpee_count * set.sec_per_rep,
          burpee_count: set.burpee_count,
          sec_per_burpee: set.sec_per_rep,
          label: "Block #{block.position}"
        }

        rest =
          if (set.end_of_set_rest || 0) > 0 do
            [
              %{
                phase: "rest",
                duration_sec: set.end_of_set_rest,
                burpee_count: nil,
                sec_per_burpee: nil,
                label: "Rest"
              }
            ]
          else
            []
          end

        events ++ [work | rest]
    end
  end

  defp decode_additional_rests(rests_json) do
    case Jason.decode(rests_json || "[]") do
      {:ok, rests} when is_list(rests) ->
        Enum.map(rests, fn %{"rest_sec" => rest_sec, "target_min" => target_min} ->
          %{rest_sec: rest_sec, target_min: target_min}
        end)

      _ ->
        []
    end
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
        class="session-surface fixed inset-0 z-[60] flex min-h-dvh flex-col bg-[var(--session-bg)] text-[var(--session-ink)]"
      >
        <div
          id="session-pause-actions"
          class="pointer-events-none absolute inset-x-0 bottom-7 z-20 translate-y-2 px-5 opacity-0 transition duration-150"
          aria-hidden="true"
        >
          <div
            class="mx-auto flex w-full max-w-[360px] items-center justify-center gap-1.5 rounded-2xl border border-[var(--session-border)] bg-[var(--session-surface)]/95 p-1.5 shadow-[0_18px_45px_rgba(32,32,29,0.10)] backdrop-blur-sm"
            aria-label="Paused session actions"
          >
            <button
              id="session-abort-btn"
              type="button"
              phx-click="discard"
              data-confirm="Abort this session without saving?"
              class="flex flex-1 items-center justify-center gap-2 rounded-xl border border-transparent px-4 py-3 text-sm font-medium text-[var(--session-muted)] transition hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
              aria-label="Abort session without saving"
            >
              <.icon name="hero-x-mark" class="size-4" />
              <span>Abort</span>
            </button>
            <button
              id="finish-early-btn"
              type="button"
              class="flex flex-1 items-center justify-center gap-2 rounded-xl bg-[var(--session-ink)] px-4 py-3 text-sm font-medium text-[var(--session-bg)] transition enabled:hover:opacity-90 disabled:hidden"
              disabled
            >
              <.icon name="hero-flag" class="size-4" />
              <span>Finish early</span>
            </button>
          </div>
        </div>

        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <.qs_surface
              :if={@tracking_state == :review}
              id="tracked-review"
              class="mx-auto mt-24 w-full max-w-[430px] bg-[var(--session-surface)]/45 px-6 py-6 text-center text-[var(--session-ink)]"
            >
              <h2 class="text-sm font-medium text-[var(--session-muted)]">
                Review tracked session
              </h2>
              <p class="qs-tabular mt-3 text-5xl font-semibold tracking-[-0.06em] tabular-nums">
                {@tracked_finish.reps}
              </p>
              <p class="mt-1 text-xs text-[var(--session-muted)]">
                Reps
              </p>
              <span class="sr-only">{@tracked_finish.reps} reps</span>
            </.qs_surface>
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
              <.camera_setup_panel setup_state={@capture_setup_state} />
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

  attr(:setup_state, :atom, required: true)

  defp camera_setup_panel(assigns) do
    ~H"""
    <div
      id="camera-setup-panel"
      data-setup-state={@setup_state}
      class="pointer-events-none absolute inset-x-0 top-8 z-20 mx-auto w-full max-w-[430px] px-5 text-[var(--session-ink)]"
    >
      <.qs_surface class="bg-[var(--session-surface)]/80 px-5 py-4 shadow-[0_18px_45px_rgba(32,32,29,0.12)] backdrop-blur-sm">
        <p class="font-mono text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--session-soft-muted)]">
          Camera setup
        </p>
        <p class="mt-2 text-sm font-medium text-[var(--session-ink)]">
          <%= if @setup_state == :ready do %>
            Camera ready
          <% else %>
            Adjust your camera
          <% end %>
        </p>
        <p class="mt-1 text-xs leading-relaxed text-[var(--session-muted)]">
          Make sure your full body is visible. We’ll save pose traces for warmup and main workout.
        </p>
      </.qs_surface>
    </div>
    """
  end

  defp not_runnable_panel(assigns) do
    ~H"""
    <div class="flex min-h-dvh items-center justify-center bg-[var(--session-bg)] px-8 text-center text-[var(--session-ink)]">
      <.qs_surface class="max-w-xs bg-[var(--session-surface)]/45 px-6 py-8">
        <p class="text-sm font-semibold text-[var(--session-ink)]">
          No timed events
        </p>
        <p class="mt-3 text-sm leading-relaxed text-[var(--session-muted)]">
          Add at least one block with one set before running.
        </p>
      </.qs_surface>
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
      <div class="mx-auto flex min-h-[calc(100dvh-4rem)] w-full max-w-[430px] flex-col items-center justify-start pt-[10vh] sm:pt-[9vh]">
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
              class="absolute mt-28 text-xs font-medium text-[var(--session-muted)]"
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
          class="mt-8 flex min-h-7 w-full items-end justify-center gap-5"
          aria-label="Workout sets"
        >
        </div>

        <div id="session-status-line" class="mt-12 w-full max-w-[340px] px-2">
          <div class="flex items-baseline justify-between gap-10 tabular-nums text-[var(--session-ink)]">
            <div class="flex items-baseline gap-1.5">
              <span
                id="total-done"
                data-total-plan={@summary.burpee_count_total}
                class="qs-tabular text-[28px] font-semibold leading-none tracking-[-0.045em]"
              >
                0
              </span>
              <span class="text-sm font-medium text-[var(--session-muted)]">
                / <span id="total-plan" class="qs-tabular">{@summary.burpee_count_total}</span> reps
              </span>
            </div>
            <div
              id="time-left"
              class="qs-tabular text-[28px] font-semibold leading-none tracking-[-0.045em] tabular-nums text-[var(--session-ink)]"
            >
              {Fmt.duration_sec(round(@summary.duration_sec_total))}
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
        <span class="text-sm font-medium text-[var(--session-muted)]">
          Warmup?
        </span>
        <div class="flex gap-2">
          <button
            type="button"
            id="warmup-yes-btn"
            class="min-w-24 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-6 py-4 text-sm font-medium text-[var(--session-ink)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70"
          >
            Yes
          </button>
          <button
            type="button"
            id="warmup-skip-btn"
            class="min-w-24 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-6 py-4 text-sm font-medium text-[var(--session-muted)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          >
            Skip
          </button>
        </div>
      <% else %>
        <span class="text-sm font-medium text-[var(--session-muted)]">
          How do you feel?
        </span>
        <div class="flex gap-2">
          <%= for {icon, label, value} <- [{"hero-face-frown", "Tired", -1}, {"hero-minus-circle", "OK", 0}, {"hero-bolt", "Hyped", 1}] do %>
            <button
              type="button"
              phx-click="session_started"
              phx-value-mood={value}
              class="min-w-20 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-4 py-4 text-sm font-medium text-[var(--session-ink)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70"
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
      <div class="text-center">
        <p class="text-lg font-semibold text-[var(--session-ink)]">
          Session complete
        </p>
        <p class="mt-2 text-sm tabular-nums text-[var(--session-muted)]">
          {@summary.burpee_count_total} reps · {Fmt.duration_sec(round(@summary.duration_sec_total))} planned
        </p>
      </div>

      <%!-- Mood --%>
      <div class="mt-8 flex overflow-hidden rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/45">
        <%= for {icon, label, value} <- @mood_options do %>
          <button
            type="button"
            phx-click="set_mood"
            phx-value-mood={value}
            class={[
              "flex flex-1 flex-col items-center py-4 text-sm font-medium transition",
              if(@mood == value,
                do:
                  "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)] ring-1 ring-inset ring-[var(--session-toggle-border)]",
                else:
                  "text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
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
        <div class="grid grid-cols-2 overflow-hidden rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/45">
          <div class="space-y-1 border-r border-[var(--session-border)] p-5">
            <p class="text-sm font-medium text-[var(--session-muted)]">
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
            <p class="text-sm font-medium text-[var(--session-muted)]">Min</p>
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
        <div class="flex flex-wrap gap-2">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              class={[
                "rounded-md border px-3 py-2 text-xs transition",
                tag in @completion_tags &&
                  "border-[var(--session-tag-border)] bg-[var(--session-tag-bg)] font-medium text-[var(--session-tag-ink)]",
                tag not in @completion_tags &&
                  "border-[var(--session-border)] text-[var(--session-muted)] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <%!-- Note --%>
        <div class="rounded-xl border border-[var(--session-border)] bg-[var(--session-surface)]/45 p-4">
          <p class="mb-2 text-sm font-medium text-[var(--session-muted)]">
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
          class="flex w-full items-center justify-center rounded-md border border-[var(--session-ink)] bg-[var(--session-ink)] py-3 text-sm font-semibold text-[var(--session-bg)] transition active:scale-[0.99] hover:opacity-90"
        >
          Save session
        </button>
        <div class="text-center">
          <button
            type="button"
            phx-click="discard"
            data-confirm="Discard this session without saving?"
            class="text-sm font-medium text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
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
      class="session-surface fixed inset-0 z-50 flex flex-col items-center justify-center bg-[var(--session-bg)] px-6 text-[var(--session-ink)]"
    >
      <div class="flex w-full max-w-[420px] flex-col items-center gap-6">
        <p class="text-sm font-medium text-[var(--session-muted)]">
          {if length(@events) > 1, do: "New achievements", else: "New achievement"}
        </p>

        <div class="flex w-full flex-col gap-3">
          <%= for {event, idx} <- Enum.with_index(@events) do %>
            <.qs_surface class={[
              "bg-[var(--session-surface)]/60 p-5 text-center",
              idx == 0 && "border-[var(--session-accent)]"
            ]}>
              <p class="text-sm font-medium text-[var(--session-muted)]">
                {celebration_title(event)}
              </p>
              <p class="mt-2 text-3xl font-semibold tabular-nums text-[var(--session-ink)]">
                {celebration_headline(event)}
              </p>
              <p class="mt-1 text-sm text-[var(--session-muted)]">
                {celebration_detail(event)}
              </p>
            </.qs_surface>
          <% end %>
        </div>

        <button
          type="button"
          phx-click="dismiss_celebration"
          class="w-full max-w-[420px] rounded-md bg-[var(--session-ink)] py-3 text-sm font-semibold text-[var(--session-bg)] transition hover:opacity-90"
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
    do: "#{:erlang.float_to_binary(v * 1.0, decimals: 1)}s"

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
