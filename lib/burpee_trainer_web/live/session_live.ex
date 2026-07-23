defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  Session runner — client-driven execution model.

  On mount the server loads the editable workout plan, compiles/loads its
  immutable execution program, and pushes canonical program events via
  `session_ready`. The client owns the clock, state machine, beeps, and
  high-frequency DOM updates. The server stays idle during the workout and only
  validates/saves completion.

  State machine (server-side phase):
      :idle → :running → :done

  The client drives everything in between. When the workout completes the
  client pushes `session_complete` and the server shows the save modal.
  """
  use BurpeeTrainerWeb, :live_view

  require Logger

  alias BurpeeTrainer.{Duration, Mood, Workouts}
  alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutSession}
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        {:ok, execution_program} = Workouts.compile_plan(plan)
        summary = program_summary(execution_program)

        socket =
          socket
          |> assign(:plan, plan)
          |> assign(:execution_program, execution_program)
          |> assign(:target_pace_sec, program_target_pace_sec(execution_program))
          |> assign(:summary, summary)
          |> assign(:phase, :idle)
          |> assign(:mood, nil)
          |> assign(:warmup_asked, false)
          |> assign(:completion_tags, [])
          |> assign(:completion_form, nil)
          |> assign(:client_session_id, Ecto.UUID.generate())
          |> assign(:celebration, nil)
          |> assign(:capture_mode, :timed)
          |> assign(:capture_setup_state, :idle)
          |> assign(:pose_capture_run, nil)
          |> assign(:tracking_state, :idle)
          |> assign(:tracked_finish, nil)
          |> assign(:tracking_error, nil)

        {:ok, push_event(socket, "session_ready", serialize_program(execution_program))}

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

  def handle_event("tracker_initialized", _, socket) do
    {:noreply, assign(socket, :tracking_state, :initializing)}
  end

  def handle_event(
        "tracker_readiness",
        %{"state" => state},
        %{assigns: %{capture_setup_state: setup_state}} = socket
      )
      when state in ["ready", "optimal"] and setup_state in [:arming, :ready] do
    {:noreply,
     socket
     |> assign(:capture_setup_state, :ready)
     |> assign(:tracking_state, :ready)}
  end

  def handle_event(
        "tracker_readiness",
        %{"state" => "not_ready"},
        %{assigns: %{capture_setup_state: setup_state}} = socket
      )
      when setup_state in [:arming, :ready] do
    {:noreply,
     socket
     |> assign(:capture_setup_state, :arming)
     |> assign(:tracking_state, :arming)}
  end

  def handle_event("tracker_readiness", _params, socket), do: {:noreply, socket}

  def handle_event("camera_preview_diagnostics", params, socket) do
    Logger.info(
      "Camera preview diagnostics user_id=#{socket.assigns.current_user.id} #{inspect(params)}"
    )

    {:noreply, socket}
  end

  def handle_event(
        "camera_setup_started",
        _,
        %{assigns: %{capture_setup_state: :ready}} = socket
      ) do
    {:noreply, assign(socket, :capture_setup_state, :started)}
  end

  def handle_event("camera_setup_started", _, socket), do: {:noreply, socket}

  def handle_event("fallback_to_timed", _, socket) do
    {:noreply,
     socket
     |> abort_active_pose_capture("camera_setup_fallback")
     |> assign(:capture_mode, :timed)
     |> assign(:capture_setup_state, :idle)
     |> assign(:tracking_state, :disabled)}
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

  def handle_event("rep", _params, socket) do
    {:noreply, socket}
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
        tracking_state =
          case payload do
            %{"tracking" => %{"status" => "degraded"}} -> :degraded
            _payload -> socket.assigns.tracking_state
          end

        socket =
          socket
          |> assign(:phase, :done)
          |> assign(:tracking_state, tracking_state)
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
      |> WorkoutSession.from_plan_changeset(
        params
        |> put_client_session_id(socket)
        |> coerce_duration()
        |> put_program_session_attrs(socket)
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :completion_form, to_form(changeset))}
  end

  def handle_event("save_session", %{"workout_session" => params}, socket) do
    %{current_user: user, plan: plan, mood: mood, completion_tags: tags} = socket.assigns

    session_params =
      params
      |> put_client_session_id(socket)
      |> coerce_duration()
      |> put_program_session_attrs(socket)
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
            "target_pace_sec" => socket.assigns.target_pace_sec
          })
        )
      else
        Workouts.create_session_from_plan(user, plan, session_params)
      end

    case create_session do
      {:ok, session} ->
        maybe_complete_pose_capture_run(socket, session)
        _events = Workouts.session_milestones(user, session)

        {:noreply,
         socket
         |> put_flash(:info, "Session saved.")
         |> push_navigate(to: ~p"/stats")}

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

  defp program_summary(%ExecutionProgram{} = program) do
    %{
      burpee_count_total: program.target_reps,
      duration_sec_total: program.target_duration_sec,
      blocks: []
    }
  end

  defp serialize_program(%ExecutionProgram{} = program) do
    %{
      program_id: program.id,
      program_hash: program.content_hash,
      target_reps: program.target_reps,
      target_duration_sec: program.target_duration_sec,
      events: program_events_for_runner(program.program_json),
      display: Map.get(program.summary_json || %{}, "display", %{})
    }
  end

  defp program_events_for_runner(program_json) do
    program_json
    |> map_get(:events, [])
    |> Enum.map(&program_event_for_runner/1)
  end

  defp program_target_pace_sec(%ExecutionProgram{} = program) do
    work_totals =
      program.program_json
      |> map_get(:events, [])
      |> Enum.reduce({0, 0.0}, fn event, {reps_total, sec_total} ->
        case map_get(event, :kind) do
          "work" ->
            reps = map_get(event, :reps)
            sec_per_rep = map_get(event, :sec_per_rep_us) / 1_000_000
            {reps_total + reps, sec_total + reps * sec_per_rep}

          _other ->
            {reps_total, sec_total}
        end
      end)

    case work_totals do
      {0, _sec_total} -> nil
      {reps_total, sec_total} -> Float.round(sec_total / reps_total, 3)
    end
  end

  defp program_event_for_runner(event) do
    case map_get(event, :kind) do
      "work" ->
        sec_per_rep_us = map_get(event, :sec_per_rep_us)
        sec_per_burpee_us = map_get(event, :sec_per_burpee_us, sec_per_rep_us)

        %{
          kind: "work",
          reps: map_get(event, :reps),
          sec_per_rep: sec_per_rep_us / 1_000_000,
          sec_per_burpee: sec_per_burpee_us / 1_000_000
        }

      "rest" ->
        %{
          kind: "rest",
          duration_sec: map_get(event, :duration_ms) / 1000
        }
    end
  end

  defp map_get(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp blank_session(plan), do: %WorkoutSession{user_id: plan.user_id, plan_id: plan.id}

  defp coerce_duration(params) do
    case Duration.parse_minutes_to_seconds(Map.get(params, "duration_min", "")) do
      {:ok, seconds} -> Map.put(params, "duration_sec_actual", seconds)
      {:error, _reason} -> params
    end
  end

  defp put_client_session_id(params, socket) do
    case Map.get(params, "client_session_id") do
      value when is_binary(value) and value != "" -> params
      _ -> Map.put(params, "client_session_id", socket.assigns.client_session_id)
    end
  end

  defp put_program_session_attrs(params, socket) do
    program = socket.assigns.execution_program

    params
    |> Map.put("burpee_type", Atom.to_string(program.burpee_type))
    |> Map.put("burpee_count_planned", program.target_reps)
    |> Map.put("duration_sec_planned", program.target_duration_sec)
    |> Map.put("execution_program_id", program.id)
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
    %{plan: plan} = socket.assigns

    attrs =
      %{
        "burpee_count_actual" => burpee_count_done,
        "duration_sec_actual" => duration_sec_actual,
        "client_session_id" => socket.assigns.client_session_id
      }
      |> put_program_session_attrs(socket)

    plan
    |> blank_session()
    |> WorkoutSession.from_plan_changeset(attrs)
    |> to_form()
  end

  defp completion_integer(form, field) do
    case Integer.parse(to_string(form[field].value || "")) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp completion_duration_label(form) do
    form
    |> completion_integer(:duration_sec_actual)
    |> Fmt.duration_sec()
  end

  defp completion_count_source(:review, %{reps: camera_reps}, form) do
    if completion_integer(form, :burpee_count_actual) == camera_reps do
      "Counted by camera"
    else
      "Edited · camera counted #{camera_reps}"
    end
  end

  defp completion_count_source(:degraded, _tracked_finish, _form) do
    "Camera view was interrupted · Check the total"
  end

  defp completion_count_source(_tracking_state, _tracked_finish, _form), do: nil

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
        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <.completion_panel
              form={@completion_form}
              mood={@mood}
              completion_tags={@completion_tags}
              tracking_state={@tracking_state}
              tracked_finish={@tracked_finish}
            />
          <% phase when phase in [:idle, :running] -> %>
            <%= if @capture_mode == :tracked do %>
              <div
                id="pose-tracker-visibility"
                aria-hidden={if(@capture_setup_state == :started, do: "true", else: "false")}
                class={[
                  "session-camera-layout pointer-events-none absolute inset-0 grid bg-[var(--session-bg)] transition-opacity duration-200",
                  @capture_setup_state in [:arming, :ready] && "z-10 opacity-100",
                  @capture_setup_state == :started && "invisible -z-10 opacity-0"
                ]}
              >
                <div
                  id="pose-tracker"
                  phx-hook="PoseTracker"
                  phx-update="ignore"
                  data-target-pace-sec={@target_pace_sec}
                  class="contents"
                >
                  <div
                    id="pose-tracker-preview-frame"
                    class="relative row-start-2 aspect-[3/4] h-full max-h-[36rem] w-auto max-w-full place-self-center overflow-hidden rounded-2xl border border-[var(--session-border)] bg-black"
                  >
                    <video
                      id="pose-tracker-preview"
                      class="absolute inset-0 h-full w-full object-cover scale-x-[-1]"
                      muted
                      playsinline
                    >
                    </video>
                    <canvas
                      id="pose-tracker-canvas"
                      class="absolute inset-0 h-full w-full"
                    >
                    </canvas>
                  </div>
                </div>
              </div>
              <.camera_setup_panel
                :if={@capture_setup_state in [:arming, :ready]}
                setup_state={@capture_setup_state}
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

  attr(:setup_state, :atom, required: true)

  defp camera_setup_panel(assigns) do
    ~H"""
    <div
      id="camera-setup-panel"
      data-setup-state={@setup_state}
      class="session-camera-layout pointer-events-auto absolute inset-0 z-20 grid text-center text-[var(--session-ink)]"
    >
      <div class="row-start-1 w-full max-w-[430px] place-self-center self-center">
        <h1 class="qs-heading-tight text-3xl font-medium leading-tight">
          <%= if @setup_state == :ready do %>
            Camera ready
          <% else %>
            Adjust your camera
          <% end %>
        </h1>
        <p class="mx-auto mt-2 max-w-md text-sm leading-relaxed text-[var(--session-muted)]">
          <%= if @setup_state == :ready do %>
            Shoulders and hips are visible. A wider frame can improve tracking accuracy.
          <% else %>
            Keep your shoulders and hips visible while tracking gets ready.
          <% end %>
        </p>
      </div>

      <button
        id="camera-setup-start-btn"
        type="button"
        disabled={@setup_state != :ready}
        class="pointer-events-auto row-start-3 min-h-14 w-full max-w-[430px] place-self-center rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition enabled:hover:opacity-90 enabled:active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-35"
      >
        Start tracked session
      </button>
      <button
        id="camera-setup-timed-btn"
        type="button"
        class="pointer-events-auto row-start-3 mt-20 place-self-center px-5 py-3 text-sm text-[var(--session-muted)] underline decoration-[var(--session-track)] underline-offset-4"
      >
        Use timer instead
      </button>
    </div>
    """
  end

  defp not_runnable_panel(assigns) do
    ~H"""
    <div
      id="session-not-runnable"
      class="flex min-h-dvh items-center justify-center bg-[var(--session-bg)] px-8 text-center"
    >
      <div class="max-w-sm">
        <h1 class="qs-heading-tight text-4xl font-medium text-[var(--session-ink)]">
          No timed events
        </h1>
        <p class="mt-4 text-base leading-relaxed text-[var(--session-muted)]">
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
      class="relative min-h-dvh w-full overflow-hidden bg-[var(--session-bg)] text-[var(--session-ink)]"
      phx-update="ignore"
    >
      <div
        id="session-visual-layers"
        class="pointer-events-none absolute inset-0 overflow-hidden"
        aria-hidden="true"
      >
        <div id="session-work-fill" class="absolute inset-0 origin-bottom"></div>
      </div>

      <div
        id="session-runner-layout"
        class="relative z-10 mx-auto grid min-h-[calc(100dvh-4rem)] w-full max-w-[430px] px-5 py-8"
      >
        <span
          id="session-accessible-status"
          class="sr-only"
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          Workout starting
        </span>

        <div id="session-top-readout" class="pointer-events-none">
          <div id="session-progress" hidden aria-hidden="true">
            <div id="session-progress-fill"></div>
          </div>

          <div id="session-status-line" class="qs-tabular flex items-start">
            <div id="total-reps" class="flex items-baseline" hidden>
              <span id="total-reps-accessible" class="sr-only">
                0 of {@summary.burpee_count_total} total reps
              </span>
              <span
                id="total-done"
                data-total-plan={@summary.burpee_count_total}
                aria-hidden="true"
              >
                0
              </span>
              <span id="total-separator" aria-hidden="true" hidden>/</span><span
                id="total-plan"
                aria-hidden="true"
                hidden
              >{@summary.burpee_count_total}</span>
            </div>

            <span id="session-time-accessible" class="sr-only">
              Session time remaining {Fmt.duration_sec(round(@summary.duration_sec_total))}
            </span>
          </div>
        </div>

        <div
          id="ring-container"
          class="relative flex min-h-0 flex-1 cursor-pointer select-none touch-manipulation items-center justify-center"
          role="button"
          tabindex="0"
          aria-label="Pause session"
        >
          <span
            id="count"
            class="qs-tabular text-[clamp(7rem,34vw,13rem)] font-semibold leading-none tracking-[-0.085em]"
            aria-hidden="true"
          >
            —
          </span>
          <span
            id="set-progress"
            class="qs-tabular pointer-events-none text-[var(--session-active-ink)]"
            hidden
            aria-hidden="true"
          >
          </span>
          <svg
            id="pause-icon"
            viewBox="0 0 48 48"
            fill="currentColor"
            class="absolute size-24"
            style="display: none;"
            aria-hidden="true"
          >
            <rect x="10" y="8" width="10" height="32" rx="2" />
            <rect x="28" y="8" width="10" height="32" rx="2" />
          </svg>
        </div>

        <div
          id="session-pause-actions"
          class="pointer-events-none relative z-20 opacity-0 transition-opacity duration-150"
          aria-hidden="true"
          inert="inert"
        >
          <div
            class="mx-auto flex w-full max-w-[360px] flex-col items-center gap-1.5"
            aria-label="Paused session actions"
          >
            <button
              id="finish-early-btn"
              type="button"
              disabled
              class="session-finish-early-action px-6 py-4 text-lg font-medium transition enabled:hover:opacity-90 active:scale-[0.99] disabled:invisible"
            >
              Finish early
            </button>
            <button
              id="session-abort-btn"
              type="button"
              phx-click="discard"
              disabled
              data-confirm="Abort this session without saving?"
              class="px-6 py-3 text-base text-[var(--session-active-ink)] transition hover:text-[var(--session-active-ink)]"
              aria-label="Abort session without saving"
            >
              Abort
            </button>
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

  attr(:form, :any, required: true)
  attr(:mood, :integer, default: nil)
  attr(:completion_tags, :list, default: [])
  attr(:tracking_state, :atom, required: true)
  attr(:tracked_finish, :any, default: nil)

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
    <div class="mx-auto min-h-dvh w-full max-w-[430px] overflow-y-auto bg-[var(--session-bg)] px-5 pb-10 pt-[max(4rem,env(safe-area-inset-top))] text-[var(--session-ink)]">
      <section id="session-completion-summary" class="text-center">
        <p
          id="session-actual-reps"
          class="qs-tabular text-[clamp(5rem,24vw,9rem)] font-semibold leading-none tracking-[-0.08em]"
        >
          {completion_integer(@form, :burpee_count_actual)}
        </p>
        <p class="qs-tabular mt-4 text-sm text-[var(--session-muted)]">
          of
          <span id="session-planned-reps" class="font-medium text-[var(--session-ink)]">
            {completion_integer(@form, :burpee_count_planned)}
          </span>
          planned
        </p>
        <p
          :if={source = completion_count_source(@tracking_state, @tracked_finish, @form)}
          id="session-count-source"
          class="mt-3 text-xs text-[var(--session-muted)]"
        >
          {source}
        </p>
        <p class="qs-tabular mt-8 text-3xl font-medium">
          {completion_duration_label(@form)}
        </p>
      </section>

      <div
        id="session-completion-mood"
        class="mt-10 flex border-y border-[var(--session-border)]"
      >
        <%= for {_icon, label, value} <- @mood_options do %>
          <button
            type="button"
            phx-click="set_mood"
            phx-value-mood={value}
            class={[
              "flex min-h-14 flex-1 items-center justify-center text-sm font-medium transition",
              if(@mood == value,
                do: "bg-[var(--session-toggle-bg)] text-[var(--session-toggle-ink)]",
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
        class="mt-10"
      >
        <div class="border-t border-[var(--session-border)] py-6">
          <label
            for="completion-reps-input"
            class="text-sm font-medium text-[var(--session-muted)]"
          >
            Reps
          </label>
          <input
            id="completion-reps-input"
            type="number"
            name={@form[:burpee_count_actual].name}
            value={@form[:burpee_count_actual].value}
            min="0"
            inputmode="numeric"
            class="qs-tabular mt-2 min-h-11 w-full bg-transparent text-4xl font-semibold leading-none tracking-[-0.04em] text-[var(--session-ink)] focus:outline-none"
          />
        </div>

        <div class="border-t border-[var(--session-border)] py-6">
          <label
            for="completion-duration-min-input"
            class="text-sm font-medium text-[var(--session-muted)]"
          >
            Minutes
          </label>
          <input
            id="completion-duration-min-input"
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
            class="qs-tabular mt-2 min-h-11 w-full bg-transparent text-4xl font-semibold leading-none tracking-[-0.04em] text-[var(--session-ink)] focus:outline-none"
          />
        </div>

        <div id="session-completion-tags" class="border-t border-[var(--session-border)] py-6">
          <p class="mb-3 text-sm font-medium text-[var(--session-muted)]">Tags</p>
          <div class="flex flex-wrap gap-2">
            <%= for tag <- @tag_options do %>
              <button
                type="button"
                phx-click="toggle_tag"
                phx-value-tag={tag}
                class={[
                  "min-h-11 rounded-full border px-4 py-2 text-xs transition",
                  tag in @completion_tags &&
                    "border-[var(--session-tag-border)] bg-[var(--session-tag-bg)] font-medium text-[var(--session-tag-ink)]",
                  tag not in @completion_tags &&
                    "border-[var(--session-border)] text-[var(--session-muted)] hover:text-[var(--session-ink)]"
                ]}
              >
                {String.replace(tag, "_", " ")}
              </button>
            <% end %>
          </div>
        </div>

        <div class="border-y border-[var(--session-border)] py-6">
          <label
            for="completion-note-input"
            class="mb-2 block text-sm font-medium text-[var(--session-muted)]"
          >
            Note
          </label>
          <textarea
            id="completion-note-input"
            name={@form[:note_post].name}
            rows="3"
            placeholder="How did it go?"
            class="w-full resize-none bg-transparent text-sm text-[var(--session-ink)] placeholder:text-[var(--session-muted)] focus:outline-none"
          >{@form[:note_post].value}</textarea>
        </div>

        <div class="hidden">
          <.input field={@form[:burpee_type]} type="text" />
          <.input field={@form[:burpee_count_planned]} type="number" />
          <.input field={@form[:duration_sec_planned]} type="number" />
          <input
            type="hidden"
            name={@form[:client_session_id].name}
            value={@form[:client_session_id].value}
          />
        </div>

        <button
          id="session-save-btn"
          type="submit"
          phx-disable-with="Saving…"
          class="mt-8 min-h-11 w-full rounded-2xl bg-[var(--session-ink)] px-6 py-5 text-base font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99]"
        >
          Save session
        </button>
        <button
          id="session-discard-btn"
          type="button"
          phx-click="discard"
          data-confirm="Discard this session?"
          class="mx-auto mt-2 block min-h-11 px-6 py-3 text-sm text-[var(--session-muted)] transition hover:text-[var(--session-ink)]"
        >
          Discard
        </button>
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

        <div class="flex w-full flex-col">
          <%= for event <- @events do %>
            <div class="w-full border-t border-[var(--session-border)] py-6 text-center last:border-b">
              <p class="text-sm text-[var(--session-muted)]">
                {celebration_title(event)}
              </p>
              <p class="qs-tabular mt-2 text-5xl font-semibold tracking-[-0.06em]">
                {celebration_headline(event)}
              </p>
              <p class="mt-2 text-sm text-[var(--session-muted)]">
                {celebration_detail(event)}
              </p>
            </div>
          <% end %>
        </div>

        <button
          type="button"
          phx-click="dismiss_celebration"
          class="w-full max-w-[420px] rounded-2xl bg-[var(--session-ink)] px-6 py-5 text-base font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99]"
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
