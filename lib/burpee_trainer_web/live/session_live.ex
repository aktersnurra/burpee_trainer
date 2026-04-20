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
      |> assign(:status, :running)
      |> schedule_tick()
      |> push_event_for_current_event()

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

  def handle_event("skip", _, socket) do
    {:noreply, advance_event(socket)}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div id="burpee-session" phx-hook="BurpeeHook" class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">{@plan.name}</h1>
            <p class="text-sm text-base-content/60">
              {Fmt.burpee_type(@plan.burpee_type)} · {@summary.burpee_count_total} burpees · {Fmt.duration_sec(
                round(@summary.duration_sec_total)
              )}
            </p>
          </div>
          <.link
            navigate={~p"/plans"}
            class="text-sm text-base-content/60 hover:text-base-content"
          >
            ← Back to plans
          </.link>
        </div>

        <%= case @status do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :idle -> %>
            <.idle_panel summary={@summary} />
          <% status when status in [:running, :paused] -> %>
            <.running_panel
              status={@status}
              event={Enum.at(@timeline, @event_index)}
              event_index={@event_index}
              total_events={length(@timeline)}
              remaining_sec={@remaining_sec}
              elapsed_total_sec={@elapsed_total_sec}
            />
          <% :completed -> %>
            <.completion_panel
              plan={@plan}
              summary={@summary}
              elapsed_total_sec={@elapsed_total_sec}
              form={@completion_form}
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

  attr :summary, :map, required: true

  defp idle_panel(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-8 space-y-6 text-center">
      <div>
        <p class="text-sm uppercase tracking-wide text-base-content/50">Ready</p>
        <p class="text-4xl font-bold tracking-tight mt-2">{@summary.burpee_count_total}</p>
        <p class="text-base-content/60">
          burpees in {Fmt.duration_sec(round(@summary.duration_sec_total))}
        </p>
      </div>
      <button
        type="button"
        phx-click="start"
        class="inline-flex items-center justify-center rounded-md bg-primary px-8 py-3 text-base font-semibold text-primary-content hover:bg-primary/90 transition"
      >
        Start session
      </button>
    </section>
    """
  end

  attr :status, :atom, required: true
  attr :event, :any, required: true
  attr :event_index, :integer, required: true
  attr :total_events, :integer, required: true
  attr :remaining_sec, :integer, required: true
  attr :elapsed_total_sec, :integer, required: true

  defp running_panel(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-8 space-y-6">
      <div class="text-center space-y-3">
        <div class="flex items-center justify-center gap-2">
          <span class={[
            "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
            event_badge_class(@event.type)
          ]}>
            {event_label(@event.type)}
          </span>
          <span class="text-xs text-base-content/50">
            {@event_index + 1} / {@total_events}
          </span>
        </div>

        <p class="text-base-content/70">{@event.label}</p>

        <div
          id="session-countdown"
          class="font-mono text-7xl font-bold tabular-nums tracking-tight"
        >
          {Fmt.duration_sec(@remaining_sec)}
        </div>

        <%= if @event.burpee_count do %>
          <p class="text-sm text-base-content/60">
            {@event.burpee_count} burpee{if @event.burpee_count == 1, do: "", else: "s"} to do
          </p>
        <% end %>

        <p class="text-xs text-base-content/50">
          Elapsed {Fmt.duration_sec(@elapsed_total_sec)}
        </p>
      </div>

      <div class="flex flex-wrap justify-center gap-2">
        <%= if @status == :running do %>
          <button
            type="button"
            phx-click="pause"
            class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
          >
            Pause
          </button>
        <% else %>
          <button
            type="button"
            phx-click="resume"
            class="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
          >
            Resume
          </button>
        <% end %>
        <button
          type="button"
          phx-click="skip"
          class="rounded-md border border-base-300 px-4 py-2 text-sm hover:bg-base-200 transition"
        >
          Skip
        </button>
        <button
          type="button"
          phx-click="finish_early"
          data-confirm="End the session now and log what you've done so far?"
          class="rounded-md border border-error/40 px-4 py-2 text-sm text-error hover:bg-error/10 transition"
        >
          Finish early
        </button>
      </div>
    </section>
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

  defp event_label(:work_burpee), do: "Work"
  defp event_label(:work_rest), do: "Rest"
  defp event_label(:warmup_burpee), do: "Warmup"
  defp event_label(:warmup_rest), do: "Warmup rest"
  defp event_label(:shave_rest), do: "Shave rest"

  defp event_badge_class(t) when t in [:work_burpee, :warmup_burpee],
    do: "bg-primary/10 text-primary"

  defp event_badge_class(_), do: "bg-base-200 text-base-content/70"
end
