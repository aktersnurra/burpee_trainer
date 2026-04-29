defmodule BurpeeTrainerWeb.SessionLive do
  @moduledoc """
  Session runner — client-driven execution model.

  On mount the server computes the timeline once and pushes it to the client
  via `session_ready`. The client (SessionHook) owns the clock, state machine,
  beeps, and UI updates. The server is idle during the workout.

  State machine (server-side phase):
      :idle → :running → :done

  The client drives everything in between. When the workout completes the
  client pushes `session_complete` and the server shows the save modal.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Planner, Workouts}
  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.Fmt

  @impl true
  def mount(%{"plan_id" => plan_id}, _session, socket) do
    user = socket.assigns.current_user

    case Integer.parse(plan_id) do
      {id, ""} ->
        plan = Workouts.get_plan!(user, id)
        timeline = Planner.to_timeline(plan)
        summary = Planner.summary(plan)

        socket =
          socket
          |> assign(:plan, plan)
          |> assign(:timeline, timeline)
          |> assign(:summary, summary)
          |> assign(:phase, if(timeline == [], do: :not_runnable, else: :idle))
          |> assign(:mood, nil)
          |> assign(:warmup_asked, false)
          |> assign(:completion_tags, [])
          |> assign(:completion_form, nil)
          |> assign(:warmup_burpee_count, 0)
          |> assign(:warmup_duration_sec, 0)

        {:ok, push_event(socket, "session_ready", %{timeline: serialize_timeline(timeline)})}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/plans")}
    end
  end

  @impl true
  def handle_event("warmup_requested", _, socket) do
    warmup = Planner.warmup_timeline(socket.assigns.plan)
    {:noreply, push_event(socket, "warmup_ready", %{warmup: serialize_timeline(warmup)})}
  end

  def handle_event("session_started", %{"mood" => mood_str}, socket) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> 0
      end

    {:noreply,
     socket |> assign(:phase, :running) |> assign(:mood, mood) |> assign(:warmup_asked, true)}
  end

  def handle_event("session_complete", %{"main" => main, "warmup" => warmup}, socket) do
    main_count = Map.get(main, "burpee_count_done", 0)
    main_duration = Map.get(main, "duration_sec", 0)
    warmup_count = Map.get(warmup, "burpee_count_done", 0)
    warmup_duration = Map.get(warmup, "duration_sec", 0)

    socket =
      socket
      |> assign(:phase, :done)
      |> assign(:warmup_burpee_count, warmup_count)
      |> assign(:warmup_duration_sec, warmup_duration)
      |> assign(:completion_form, build_completion_form(socket, main_count, main_duration))

    {:noreply, socket}
  end

  def handle_event("set_mood", %{"mood" => mood_str}, socket) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> socket.assigns.mood
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
      |> WorkoutSession.from_plan_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :completion_form, to_form(changeset))}
  end

  def handle_event("save_session", %{"workout_session" => params}, socket) do
    %{current_user: user, plan: plan, mood: mood, completion_tags: tags} = socket.assigns

    if socket.assigns.warmup_burpee_count > 0 do
      Workouts.create_warmup_session(user, %{
        burpee_type: plan.burpee_type,
        burpee_count_done: socket.assigns.warmup_burpee_count,
        duration_sec: socket.assigns.warmup_duration_sec
      })
    end

    params =
      params
      |> Map.put("mood", mood)
      |> Map.put("tags", tags |> Enum.sort() |> Enum.join(","))

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

  def handle_event("discard", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/plans")}
  end

  defp serialize_timeline(events) do
    Enum.map(events, fn e ->
      %{
        type: Atom.to_string(e.type),
        duration_sec: e.duration_sec,
        burpee_count: e.burpee_count,
        sec_per_burpee: e.sec_per_burpee,
        label: e.label
      }
    end)
  end

  defp blank_session(plan), do: %WorkoutSession{user_id: plan.user_id, plan_id: plan.id}

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
      <div
        id="burpee-session"
        phx-hook="SessionHook"
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

        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <.completion_panel
              plan={@plan}
              summary={@summary}
              form={@completion_form}
              mood={@mood}
              completion_tags={@completion_tags}
            />
          <% phase when phase in [:idle, :running] -> %>
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
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
      <p class="text-base-content/70">This plan has no timed events yet.</p>
      <p class="text-sm text-base-content/50">
        Add at least one block with one set before running.
      </p>
    </div>
    """
  end

  attr :phase, :atom, required: true
  attr :summary, :map, required: true
  attr :warmup_asked, :boolean, required: true

  defp session_runner(assigns) do
    ~H"""
    <div class="relative flex flex-col gap-5">
      <div class="flex items-center justify-between gap-3">
        <span
          id="phase-badge"
          class="inline-flex items-center rounded-full px-2.5 py-1 text-[13px] font-medium uppercase tracking-[0.06em] bg-base-200 text-base-content/70"
        >
          Ready
        </span>
        <span id="set-label" class="truncate text-xs text-base-content/60"></span>
      </div>

      <div
        id="ring-container"
        class="relative mx-auto w-[280px] h-[280px] cursor-pointer select-none"
        phx-update="ignore"
      >
        <svg id="ring-svg" viewBox="0 0 280 280" class="absolute inset-0 w-[280px] h-[280px]"></svg>

        <svg viewBox="0 0 280 280" class="absolute inset-0 w-[280px] h-[280px] pointer-events-none">
          <circle
            id="flash-circle"
            cx="140"
            cy="140"
            r="107"
            fill="none"
            stroke="white"
            stroke-width="18"
            opacity="0"
            transform="rotate(-90 140 140)"
          />
        </svg>

        <div class="absolute inset-0 flex flex-col items-center justify-center pointer-events-none">
          <span
            id="count"
            class="text-[72px] font-light leading-none tracking-[-0.03em] tabular-nums"
            style="color: #C8D8F0;"
          >—</span>
          <span
            id="down-word"
            class="absolute text-[28px] font-mono font-medium tracking-[0.12em] uppercase text-white pointer-events-none"
            style="display: none;"
          >Down</span>
          <svg
            id="pause-icon"
            viewBox="0 0 48 48"
            fill="currentColor"
            class="absolute h-16 w-16"
            style="display: none; color: #C8D8F0; opacity: 0.85;"
          >
            <rect x="10" y="8" width="10" height="32" rx="2" />
            <rect x="28" y="8" width="10" height="32" rx="2" />
          </svg>
        </div>
      </div>

      <div class="flex items-baseline justify-center gap-[6px]">
        <span
          id="total-done"
          class="text-[32px] font-light leading-none tabular-nums"
          style="color: #C8D8F0; transition: color 0.12s;"
        >0</span>
        <span class="text-[16px]" style="color: #2A3A50;">/</span>
        <span id="total-plan" class="text-[16px]" style="color: #2A3A50;">{@summary.burpee_count_total}</span>
      </div>

      <div class="flex flex-col gap-1">
        <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-300">
          <div
            id="progress-fill"
            class="h-full rounded-full transition-none"
            style="width: 0%; background-color: #1E2535;"
          />
        </div>
        <div class="text-center text-[13px] text-base-content/50">
          <span id="time-left">{Fmt.duration_sec(round(@summary.duration_sec_total))}</span>
        </div>
      </div>

      <button
        id="finish-early-btn"
        type="button"
        class={[
          "self-center text-xs text-base-content/50 underline hover:text-base-content",
          "disabled:opacity-40 disabled:no-underline disabled:cursor-not-allowed"
        ]}
        disabled
      >
        Finish early
      </button>

      <%= if @phase == :idle do %>
        <.tap_to_start_overlay warmup_asked={@warmup_asked} />
      <% end %>
    </div>
    """
  end

  attr :warmup_asked, :boolean, required: true

  defp tap_to_start_overlay(assigns) do
    ~H"""
    <div
      id="start-overlay"
      class={[
        "absolute inset-0 z-10 flex flex-col items-center justify-center gap-5 rounded-lg",
        "bg-base-100/90 text-center backdrop-blur-sm"
      ]}
    >
      <%= if not @warmup_asked do %>
        <span class="text-xl font-semibold tracking-tight">Do you want a warmup?</span>
        <div class="flex gap-3">
          <button
            type="button"
            id="warmup-yes-btn"
            class={[
              "flex flex-col items-center gap-1.5 rounded-xl border border-base-300",
              "px-6 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
            ]}
          >
            <span class="text-2xl">🔥</span>
            <span>Yes</span>
          </button>
          <button
            type="button"
            id="warmup-skip-btn"
            class={[
              "flex flex-col items-center gap-1.5 rounded-xl border border-base-300",
              "px-6 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
            ]}
          >
            <span class="text-2xl">⚡</span>
            <span>Skip</span>
          </button>
        </div>
      <% else %>
        <span class="text-xl font-semibold tracking-tight">How do you feel?</span>
        <div class="flex gap-3">
          <%= for {emoji, label, value} <- [{"😮‍💨", "Tired", -1}, {"😐", "OK", 0}, {"💪", "Hyped", 1}] do %>
            <button
              type="button"
              phx-click="session_started"
              phx-value-mood={value}
              class={[
                "flex flex-col items-center gap-1.5 rounded-xl border border-base-300",
                "px-5 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
              ]}
            >
              <span class="text-2xl">{emoji}</span>
              <span>{label}</span>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :plan, :any, required: true
  attr :summary, :map, required: true
  attr :form, :any, required: true
  attr :mood, :integer, default: nil
  attr :completion_tags, :list, default: []

  @mood_options [{"😮‍💨", "Tired", -1}, {"😐", "OK", 0}, {"💪", "Hyped", 1}]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  defp completion_panel(assigns) do
    assigns =
      assign(assigns,
        mood_options: @mood_options,
        tag_options: @tag_options
      )

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-6 space-y-5">
      <div>
        <h2 class="text-lg font-semibold tracking-tight">Session complete</h2>
        <p class="text-sm text-base-content/60">
          Log what you actually did. Planned: {@summary.burpee_count_total} burpees in {Fmt.duration_sec(
            round(@summary.duration_sec_total)
          )}.
        </p>
      </div>

      <div class="space-y-1.5">
        <p class="text-sm font-medium">Mood</p>
        <div class="flex gap-2">
          <%= for {emoji, label, value} <- @mood_options do %>
            <button
              type="button"
              phx-click="set_mood"
              phx-value-mood={value}
              class={[
                "flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm transition",
                if(@mood == value,
                  do: "border-primary bg-primary/10 font-medium",
                  else: "border-base-300 hover:bg-base-200"
                )
              ]}
            >
              {emoji} {label}
            </button>
          <% end %>
        </div>
      </div>

      <div class="space-y-1.5">
        <p class="text-sm font-medium">Tags</p>
        <div class="flex flex-wrap gap-2">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              class={[
                "rounded-full border px-3 py-1 text-xs transition",
                if(tag in @completion_tags,
                  do: "border-primary bg-primary/10 font-medium",
                  else: "border-base-300 hover:bg-base-200"
                )
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>
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
end
