defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  The live session runner. Drives a workout plan's timeline one event at
  a time with a 1-second server-side tick, pushes audio cues to the
  BurpeeHook, and finishes with a completion form that records a
  `WorkoutSession`.

  State machine:

      :idle → :preroll → :running ⇄ :paused → :completed

  `:preroll` is a 5-second "Get ready" countdown that fires before the
  first real event. `:completed` is also reached via "Finish early"
  from `:paused` or `:running`. From `:completed`, the only transitions
  are `save_session` (navigates to history) or `discard` (navigates to
  plans).
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Planner, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.Fmt

  @tick_ms 1000
  @preroll_sec 5

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        timeline = Planner.to_timeline(plan)
        summary = Planner.summary(plan)

        {:ok,
         socket
         |> assign(:plan, plan)
         |> assign(:timeline, timeline)
         |> assign(:summary, summary)
         |> assign(:status, initial_status(timeline))
         |> assign(:event_index, 0)
         |> assign(:remaining_sec, event_duration_sec(timeline, 0))
         |> assign(:elapsed_total_sec, 0)
         |> assign(:preroll_total_sec, @preroll_sec)
         |> assign(:tick_ref, nil)
         |> assign(:completion_form, nil)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/plans")}
    end
  end

  defp initial_status([]), do: :not_runnable
  defp initial_status(_), do: :idle

  defp event_duration_sec([], _), do: 0

  defp event_duration_sec(timeline, index) do
    case Enum.at(timeline, index) do
      nil -> 0
      event -> round(event.duration_sec)
    end
  end

  @impl true
  def handle_event("start", _, socket) do
    socket =
      socket
      |> assign(:status, :preroll)
      |> assign(:remaining_sec, @preroll_sec)
      |> schedule_tick()
      |> push_preroll_event()

    {:noreply, socket}
  end

  def handle_event("pause", _, socket) do
    {:noreply,
     socket
     |> cancel_tick()
     |> assign(:status, :paused)
     |> push_event("burpee:audio_stop", %{})}
  end

  def handle_event("resume", _, socket) do
    {:noreply,
     socket
     |> assign(:status, :running)
     |> schedule_tick()
     |> push_event_for_current_event()}
  end

  def handle_event("finish_early", _, socket) do
    {:noreply, complete_session(socket)}
  end

  def handle_event("discard", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/plans")}
  end

  def handle_event("validate_session", %{"workout_session" => params}, socket) do
    changeset =
      socket.assigns.plan
      |> blank_session()
      |> WorkoutSession.from_plan_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :completion_form, to_form(changeset))}
  end

  def handle_event("save_session", %{"workout_session" => params}, socket) do
    %{current_user: user, plan: plan} = socket.assigns

    case Workouts.create_session_from_plan(user, plan, params) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> put_flash(:info, "Session saved.")
         |> push_navigate(to: ~p"/history")}

      {:error, changeset} ->
        {:noreply, assign(socket, :completion_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    case socket.assigns.status do
      :running -> {:noreply, tick(socket)}
      :preroll -> {:noreply, preroll_tick(socket)}
      _ -> {:noreply, socket}
    end
  end

  defp tick(socket) do
    remaining = socket.assigns.remaining_sec - 1
    elapsed = socket.assigns.elapsed_total_sec + 1

    socket = assign(socket, elapsed_total_sec: elapsed)

    if remaining <= 0 do
      advance_event(socket)
    else
      socket
      |> assign(:remaining_sec, remaining)
      |> schedule_tick()
    end
  end

  defp preroll_tick(socket) do
    remaining = socket.assigns.remaining_sec - 1

    if remaining <= 0 do
      socket
      |> cancel_tick()
      |> assign(:status, :running)
      |> assign(:remaining_sec, event_duration_sec(socket.assigns.timeline, 0))
      |> schedule_tick()
      |> push_event_for_current_event()
    else
      socket
      |> assign(:remaining_sec, remaining)
      |> schedule_tick()
    end
  end

  defp advance_event(socket) do
    next_index = socket.assigns.event_index + 1

    if next_index >= length(socket.assigns.timeline) do
      complete_session(socket)
    else
      socket
      |> cancel_tick()
      |> assign(:event_index, next_index)
      |> assign(:remaining_sec, event_duration_sec(socket.assigns.timeline, next_index))
      |> schedule_tick()
      |> push_event_for_current_event()
    end
  end

  defp complete_session(socket) do
    socket
    |> cancel_tick()
    |> assign(:status, :completed)
    |> assign(:completion_form, build_completion_form(socket))
    |> push_event("burpee:audio_stop", %{})
    |> push_event("burpee:completed", %{})
  end

  defp schedule_tick(socket) do
    socket = cancel_tick(socket)
    ref = Process.send_after(self(), :tick, @tick_ms)
    assign(socket, :tick_ref, ref)
  end

  defp cancel_tick(socket) do
    case socket.assigns.tick_ref do
      nil ->
        socket

      ref ->
        Process.cancel_timer(ref)
        assign(socket, :tick_ref, nil)
    end
  end

  defp burpees_remaining(%{type: type, burpee_count: count, duration_sec: dur}, remaining_sec)
       when type in [:work_burpee, :warmup_burpee] and is_integer(count) and count > 0 and
              is_number(dur) and dur > 0 do
    sec_per_rep = dur / count

    remaining_sec
    |> Kernel./(sec_per_rep)
    |> Float.ceil()
    |> trunc()
    |> min(count)
    |> max(0)
  end

  defp burpees_remaining(_, _), do: nil

  defp cumulative_burpees_done(timeline, event_index, remaining_sec) do
    completed =
      timeline
      |> Enum.take(event_index)
      |> Enum.filter(&(&1.type == :work_burpee))
      |> Enum.reduce(0, fn e, acc -> acc + (e.burpee_count || 0) end)

    partial =
      case Enum.at(timeline, event_index) do
        %{type: :work_burpee, burpee_count: n, duration_sec: d}
        when is_integer(n) and n > 0 and is_number(d) and d > 0 ->
          sec_per_rep = d / n
          elapsed = max(d - remaining_sec, 0)

          elapsed
          |> Kernel./(sec_per_rep)
          |> Float.floor()
          |> trunc()
          |> max(0)
          |> min(n)

        _ ->
          0
      end

    completed + partial
  end

  defp push_preroll_event(socket) do
    push_event(socket, "burpee:event_changed", %{
      type: "countdown",
      remaining_sec: socket.assigns.remaining_sec,
      sec_per_rep: nil,
      burpee_count: nil
    })
  end

  defp push_event_for_current_event(socket) do
    %{timeline: timeline, event_index: index, remaining_sec: remaining} = socket.assigns

    case Enum.at(timeline, index) do
      nil ->
        socket

      event ->
        push_event(socket, "burpee:event_changed", %{
          type: Atom.to_string(event.type),
          remaining_sec: remaining,
          sec_per_rep: sec_per_rep(event),
          burpee_count: event.burpee_count
        })
    end
  end

  defp sec_per_rep(%{type: type, duration_sec: d, burpee_count: c})
       when type in [:work_burpee, :warmup_burpee] and is_integer(c) and c > 0 do
    d / c
  end

  defp sec_per_rep(_), do: nil

  defp blank_session(plan), do: %WorkoutSession{user_id: plan.user_id, plan_id: plan.id}

  defp build_completion_form(socket) do
    %{plan: plan, summary: summary, elapsed_total_sec: elapsed} = socket.assigns

    attrs = %{
      "burpee_type" => Atom.to_string(plan.burpee_type),
      "burpee_count_planned" => summary.burpee_count_total,
      "duration_sec_planned" => round(summary.duration_sec_total),
      "burpee_count_actual" => summary.burpee_count_total,
      "duration_sec_actual" => elapsed
    }

    plan
    |> blank_session()
    |> WorkoutSession.from_plan_changeset(attrs)
    |> to_form()
  end

  # Ring geometry — r=107 in a 240×240 viewBox leaves 13px padding around
  # the 14px stroke so the rounded cap isn't clipped.
  defp ring_radius, do: 107
  defp ring_circumference, do: 2.0 * :math.pi() * ring_radius()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div
        id="burpee-session"
        phx-hook="BurpeeHook"
        class="mx-auto flex w-full max-w-[420px] flex-col gap-5"
      >
        <div class="flex items-baseline justify-between gap-3">
          <div class="min-w-0">
            <h1 class="truncate text-xl font-semibold tracking-tight">{@plan.name}</h1>
            <p class="truncate text-xs text-base-content/60">
              {Fmt.burpee_type(@plan.burpee_type)} · {@summary.burpee_count_total} burpees · {Fmt.duration_sec(
                round(@summary.duration_sec_total)
              )}
            </p>
          </div>
          <.link
            navigate={~p"/plans"}
            class="shrink-0 text-xs text-base-content/60 hover:text-base-content"
          >
            ← Plans
          </.link>
        </div>

        <%= case @status do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :completed -> %>
            <.completion_panel
              plan={@plan}
              summary={@summary}
              elapsed_total_sec={@elapsed_total_sec}
              form={@completion_form}
            />
          <% status when status in [:idle, :preroll, :running, :paused] -> %>
            <.session_runner
              status={status}
              timeline={@timeline}
              event_index={@event_index}
              remaining_sec={@remaining_sec}
              elapsed_total_sec={@elapsed_total_sec}
              summary={@summary}
              preroll_total_sec={@preroll_total_sec}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ---------------- components ----------------

  defp not_runnable_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
      <p class="text-base-content/70">This plan has no timed events yet.</p>
      <p class="text-sm text-base-content/50">
        Add at least one block with one set before running.
      </p>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :timeline, :list, required: true
  attr :event_index, :integer, required: true
  attr :remaining_sec, :integer, required: true
  attr :elapsed_total_sec, :integer, required: true
  attr :summary, :map, required: true
  attr :preroll_total_sec, :integer, required: true

  defp session_runner(assigns) do
    view = runner_view_state(assigns)
    assigns = assign(assigns, view)

    ~H"""
    <div class="relative flex flex-col gap-5">
      <.phase_bar phase_type={@phase_type} set_label={@set_label} />

      <.clock
        phase_type={@phase_type}
        progress={@ring_progress}
        center_top={@center_top}
        center_primary={@center_primary}
        center_bottom={@center_bottom}
        pulse={@pulse_ring}
      />

      <.burpee_counter done={@done} total={@summary.burpee_count_total} />

      <.workout_progress
        phase_type={@phase_type}
        elapsed={@elapsed_total_sec}
        total_sec={round(@summary.duration_sec_total)}
      />

      <.pause_button status={@status} />

      <button
        type="button"
        phx-click="finish_early"
        data-confirm="End the session now and log what you've done so far?"
        class={[
          "self-center text-xs text-base-content/50 underline hover:text-base-content",
          "disabled:opacity-40 disabled:no-underline disabled:cursor-not-allowed"
        ]}
        disabled={@status == :idle}
      >
        Finish early
      </button>

      <%= if @status == :idle do %>
        <.tap_to_start_overlay />
      <% end %>
    </div>
    """
  end

  defp runner_view_state(assigns) do
    case assigns.status do
      :idle -> runner_view_idle(assigns)
      :preroll -> runner_view_preroll(assigns)
      s when s in [:running, :paused] -> runner_view_event(assigns)
    end
  end

  defp runner_view_idle(%{timeline: timeline}) do
    event = List.first(timeline)
    is_work_like = event && event.type in [:work_burpee, :warmup_burpee]

    %{
      phase_type: (event && event.type) || :preroll,
      set_label: (event && event.label) || "",
      ring_progress: 0.0,
      center_top: if(is_work_like, do: "reps left", else: "ready"),
      center_primary: if(is_work_like, do: event.burpee_count, else: "—"),
      center_bottom: if(is_work_like, do: "of #{event.burpee_count}", else: ""),
      pulse_ring: false,
      done: 0
    }
  end

  defp runner_view_preroll(%{remaining_sec: remaining, preroll_total_sec: total}) do
    %{
      phase_type: :preroll,
      set_label: "First set starts soon",
      ring_progress: ring_progress(total - remaining, total),
      center_top: "starts in",
      center_primary: max(remaining, 0),
      center_bottom: "",
      pulse_ring: remaining > 0 and remaining <= 3,
      done: 0
    }
  end

  defp runner_view_event(%{
         status: status,
         timeline: timeline,
         event_index: idx,
         remaining_sec: remaining
       }) do
    event = Enum.at(timeline, idx)
    is_work = event && event.type in [:work_burpee, :warmup_burpee]
    is_rest = event && event.type in [:work_rest, :warmup_rest, :shave_rest]
    duration = round((event && event.duration_sec) || 0)

    %{
      phase_type: (event && event.type) || :preroll,
      set_label: (event && event.label) || "",
      ring_progress: ring_progress(duration - remaining, duration),
      center_top:
        cond do
          is_work -> "reps left"
          is_rest -> "rest"
          true -> ""
        end,
      center_primary:
        cond do
          is_work -> burpees_remaining(event, remaining)
          is_rest -> remaining
          true -> ""
        end,
      center_bottom:
        cond do
          is_work -> "of #{event.burpee_count}"
          true -> ""
        end,
      pulse_ring: status == :running and is_rest and remaining > 0 and remaining <= 5,
      done: cumulative_burpees_done(timeline, idx, remaining)
    }
  end

  defp ring_progress(_, duration) when duration <= 0, do: 0.0

  defp ring_progress(elapsed, duration) do
    elapsed
    |> Kernel./(duration)
    |> min(1.0)
    |> max(0.0)
  end

  attr :phase_type, :atom, required: true
  attr :set_label, :string, required: true

  defp phase_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <span class={[
        "inline-flex items-center rounded-full px-2.5 py-1 text-[13px] font-medium uppercase tracking-[0.06em]",
        phase_badge_class(@phase_type)
      ]}>
        {phase_label_text(@phase_type)}
      </span>
      <span class="truncate text-xs text-base-content/60">{@set_label}</span>
    </div>
    """
  end

  attr :phase_type, :atom, required: true
  attr :progress, :float, required: true
  attr :center_top, :string, required: true
  attr :center_primary, :any, required: true
  attr :center_bottom, :string, required: true
  attr :pulse, :boolean, required: true

  defp clock(assigns) do
    circ = ring_circumference()
    offset = circ * (1.0 - assigns.progress)

    assigns =
      assigns
      |> assign(:circumference, :erlang.float_to_binary(circ, decimals: 4))
      |> assign(:dashoffset, :erlang.float_to_binary(offset, decimals: 4))

    ~H"""
    <div class={[
      "relative mx-auto flex aspect-square w-full max-w-[220px] items-center justify-center",
      @pulse && "burpee-ring-pulse"
    ]}>
      <svg viewBox="0 0 240 240" class="h-full w-full -rotate-90">
        <circle cx="120" cy="120" r="107" fill="none" stroke-width="14" class="stroke-base-300" />
        <circle
          cx="120"
          cy="120"
          r="107"
          fill="none"
          stroke-width="14"
          stroke-linecap="round"
          class={phase_stroke_class(@phase_type)}
          style={"stroke-dasharray: #{@circumference}; stroke-dashoffset: #{@dashoffset}; transition: stroke 0.4s, stroke-dashoffset 1s linear;"}
        />
      </svg>
      <div class="pointer-events-none absolute inset-0 flex flex-col items-center justify-center text-center">
        <span class="text-[13px] text-base-content/60">{@center_top}</span>
        <span class="text-[46px] font-medium leading-none tabular-nums tracking-tight">
          {@center_primary}
        </span>
        <span class="text-[13px] text-base-content/60">{@center_bottom}</span>
      </div>
    </div>
    """
  end

  attr :done, :integer, required: true
  attr :total, :integer, required: true

  defp burpee_counter(assigns) do
    ~H"""
    <div class="flex items-baseline justify-center gap-2">
      <span class="text-[36px] font-medium leading-none tabular-nums">{@done}</span>
      <span class="text-xl text-base-content/60 tabular-nums">/ {@total}</span>
      <span class="text-[13px] text-base-content/50">burpees</span>
    </div>
    """
  end

  attr :phase_type, :atom, required: true
  attr :elapsed, :integer, required: true
  attr :total_sec, :integer, required: true

  defp workout_progress(assigns) do
    total = max(assigns.total_sec, 1)
    pct = min(100.0, assigns.elapsed / total * 100.0)
    time_left = max(total - assigns.elapsed, 0)

    assigns =
      assigns
      |> assign(:pct, :erlang.float_to_binary(pct, decimals: 2))
      |> assign(:time_left, time_left)
      |> assign(:total_sec_display, total)

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-300">
        <div
          class={["h-full rounded-full", phase_bg_class(@phase_type)]}
          style={"width: #{@pct}%; transition: width 1s linear, background-color 0.4s;"}
        />
      </div>
      <div class="flex items-center justify-between text-[13px]">
        <span>
          Time left: <span class="font-medium">{Fmt.duration_sec(@time_left)}</span>
        </span>
        <span class="text-base-content/60">Workout {Fmt.duration_sec(@total_sec_display)}</span>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp pause_button(assigns) do
    paused = assigns.status == :paused
    disabled = assigns.status == :idle
    assigns = assign(assigns, paused: paused, disabled: disabled)

    ~H"""
    <button
      type="button"
      phx-click={if @paused, do: "resume", else: "pause"}
      disabled={@disabled}
      class={[
        "flex h-12 w-full items-center justify-center gap-3 rounded-md border border-base-300 text-sm font-medium transition",
        "active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40"
      ]}
    >
      <%= if @paused do %>
        <svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4">
          <path d="M6 4l10 6-10 6V4z" />
        </svg>
        <span>Resume</span>
      <% else %>
        <svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4">
          <rect x="5" y="4" width="3" height="12" rx="0.5" />
          <rect x="12" y="4" width="3" height="12" rx="0.5" />
        </svg>
        <span>Pause</span>
      <% end %>
    </button>
    """
  end

  defp tap_to_start_overlay(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="start"
      class={[
        "absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 rounded-lg",
        "bg-base-100/85 text-center transition active:scale-[0.995] backdrop-blur-sm"
      ]}
    >
      <span class="text-4xl font-semibold tracking-tight">Ready</span>
      <span class="text-sm text-base-content/60">Tap anywhere to begin</span>
    </button>
    """
  end

  attr :plan, :any, required: true
  attr :summary, :map, required: true
  attr :elapsed_total_sec, :integer, required: true
  attr :form, :any, required: true

  defp completion_panel(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-5">
      <div>
        <h2 class="text-lg font-semibold tracking-tight">Session complete</h2>
        <p class="text-sm text-base-content/60">
          Log what you actually did. Planned: {@summary.burpee_count_total} burpees in {Fmt.duration_sec(
            round(@summary.duration_sec_total)
          )}. Elapsed: {Fmt.duration_sec(@elapsed_total_sec)}.
        </p>
      </div>

      <.form
        for={@form}
        id="session-completion-form"
        phx-change="validate_session"
        phx-submit="save_session"
        class="space-y-4"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:burpee_count_actual]}
            type="number"
            label="Burpees done"
            min="0"
          />
          <.input
            field={@form[:duration_sec_actual]}
            type="number"
            label="Duration (sec)"
            min="0"
          />
        </div>

        <.input field={@form[:note_pre]} type="textarea" label="Pre-session note" rows="2" />
        <.input field={@form[:note_post]} type="textarea" label="How did it go?" rows="3" />

        <div class="hidden">
          <.input field={@form[:burpee_type]} type="text" />
          <.input field={@form[:burpee_count_planned]} type="number" />
          <.input field={@form[:duration_sec_planned]} type="number" />
        </div>

        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="discard"
            data-confirm="Discard this session without saving?"
            class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
          >
            Discard
          </button>
          <button
            type="submit"
            class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
          >
            Save session
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # ---------------- phase palette ----------------

  defp phase_badge_class(:work_burpee), do: "bg-primary text-primary-content"
  defp phase_badge_class(:warmup_burpee), do: "bg-warning text-warning-content"
  defp phase_badge_class(:work_rest), do: "bg-secondary text-secondary-content"
  defp phase_badge_class(:warmup_rest), do: "bg-base-200 text-base-content/70"
  defp phase_badge_class(:shave_rest), do: "bg-secondary text-secondary-content"
  defp phase_badge_class(:preroll), do: "bg-base-200 text-base-content/70"
  defp phase_badge_class(_), do: "bg-base-200 text-base-content/70"

  defp phase_stroke_class(:work_burpee), do: "stroke-primary"
  defp phase_stroke_class(:warmup_burpee), do: "stroke-warning"
  defp phase_stroke_class(:work_rest), do: "stroke-secondary"
  defp phase_stroke_class(:warmup_rest), do: "stroke-base-300"
  defp phase_stroke_class(:shave_rest), do: "stroke-secondary"
  defp phase_stroke_class(:preroll), do: "stroke-base-300"
  defp phase_stroke_class(_), do: "stroke-base-300"

  defp phase_bg_class(:work_burpee), do: "bg-primary"
  defp phase_bg_class(:warmup_burpee), do: "bg-warning"
  defp phase_bg_class(:work_rest), do: "bg-secondary"
  defp phase_bg_class(:warmup_rest), do: "bg-base-300"
  defp phase_bg_class(:shave_rest), do: "bg-secondary"
  defp phase_bg_class(:preroll), do: "bg-base-300"
  defp phase_bg_class(_), do: "bg-base-300"

  defp phase_label_text(:work_burpee), do: "Work"
  defp phase_label_text(:warmup_burpee), do: "Warmup"
  defp phase_label_text(:work_rest), do: "Rest"
  defp phase_label_text(:warmup_rest), do: "Warmup rest"
  defp phase_label_text(:shave_rest), do: "Shave rest"
  defp phase_label_text(:preroll), do: "Get ready"
  defp phase_label_text(_), do: "Ready"
end
