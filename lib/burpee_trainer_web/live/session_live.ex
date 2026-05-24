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

  alias BurpeeTrainer.{Mood, Planner, Workouts}
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

        block_count = length(plan.blocks)

        {:ok,
         push_event(socket, "session_ready", %{
           timeline: serialize_timeline(timeline),
           block_count: block_count
         })}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/workouts")}
    end
  end

  @impl true
  def handle_event("warmup_requested", _, socket) do
    warmup = Planner.warmup_timeline(socket.assigns.plan)
    {:noreply, push_event(socket, "warmup_ready", %{warmup: serialize_timeline(warmup)})}
  end

  def handle_event("session_started", %{"mood" => mood_str}, socket) do
    mood =
      case Mood.parse(mood_str) do
        {:ok, mood} -> mood
        {:error, _reason} -> 0
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

    if socket.assigns.warmup_burpee_count > 0 do
      Workouts.create_warmup_session(user, %{
        burpee_type: plan.burpee_type,
        burpee_count_done: socket.assigns.warmup_burpee_count,
        duration_sec: socket.assigns.warmup_duration_sec
      })
    end

    session_params =
      params
      |> coerce_duration()
      |> Map.put("mood", mood)
      |> Map.put("tags", tags |> Enum.sort() |> Enum.join(","))

    case Workouts.create_session_from_plan(user, plan, session_params) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> put_flash(:info, "Session saved.")
         |> push_navigate(to: ~p"/stats")}

      {:error, changeset} ->
        {:noreply, assign(socket, :completion_form, to_form(changeset))}
    end
  end

  def handle_event("discard", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workouts")}
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

  defp coerce_duration(params) do
    case Float.parse(Map.get(params, "duration_min", "")) do
      {min, _} when min >= 0 -> Map.put(params, "duration_sec_actual", round(min * 60))
      _ -> params
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
      <div
        id="burpee-session"
        phx-hook="SessionHook"
        class="mx-auto flex w-full max-w-[420px] flex-col gap-5"
      >
        <div class="flex items-center justify-between">
          <.link
            navigate={~p"/workouts"}
            class="flex items-center justify-center w-8 h-8 rounded transition-colors"
            style="color: #6B8FA8;"
          >
            <.icon name="hero-chevron-left" />
          </.link>
          <span id="block-info" class="text-xs" style="color: #6B8FA8; opacity: 0.6;"></span>
          <button
            id="finish-early-btn"
            type="button"
            class="flex items-center justify-center w-8 h-8 rounded transition-colors disabled:cursor-not-allowed"
            style="color: #6B8FA8; opacity: 0.4;"
            disabled
          >
            <.icon name="hero-flag" />
          </button>
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
          >
            —
          </span>
          <span
            id="down-word"
            class="absolute text-[28px] font-mono font-medium tracking-[0.12em] uppercase text-white pointer-events-none"
            style="display: none;"
          >
            Down
          </span>
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
        >
          0
        </span>
        <span class="text-[16px]" style="color: #2A3A50;">/</span>
        <span id="total-plan" class="text-[16px]" style="color: #2A3A50;">
          {@summary.burpee_count_total}
        </span>
      </div>

      <div class="flex flex-col gap-1">
        <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-300">
          <div
            id="progress-fill"
            class="h-full rounded-full transition-none"
            style="width: 0%; background-color: #222840;"
          />
        </div>
        <div class="text-center text-[13px] text-base-content/50">
          <span id="time-left">{Fmt.duration_sec(round(@summary.duration_sec_total))}</span>
        </div>
      </div>

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
        "bg-base-100/95 text-center backdrop-blur-sm"
      ]}
    >
      <%= if not @warmup_asked do %>
        <span class="text-xl font-semibold tracking-tight">Warmup?</span>
        <div class="flex gap-3">
          <button
            type="button"
            id="warmup-yes-btn"
            class={[
              "flex flex-col items-center gap-1.5 rounded-xl border border-base-border",
              "px-8 py-4 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
            ]}
          >
            <.icon name="hero-sparkles" class="size-6 text-primary" />
            <span>Yes</span>
          </button>
          <button
            type="button"
            id="warmup-skip-btn"
            class={[
              "flex flex-col items-center gap-1.5 rounded-xl border border-base-border",
              "px-8 py-4 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
            ]}
          >
            <.icon name="hero-forward" class="size-6 text-base-content/50" />
            <span>Skip</span>
          </button>
        </div>
      <% else %>
        <span class="text-xl font-semibold tracking-tight">How do you feel?</span>
        <div class="flex gap-3">
          <%= for {icon, label, value} <- [{"hero-face-frown", "Tired", -1}, {"hero-minus-circle", "OK", 0}, {"hero-bolt", "Hyped", 1}] do %>
            <button
              type="button"
              phx-click="session_started"
              phx-value-mood={value}
              class={[
                "flex flex-col items-center gap-1.5 rounded-xl border border-base-border",
                "px-6 py-4 text-sm font-medium transition active:scale-[0.97] hover:bg-base-200"
              ]}
            >
              <.icon name={icon} class="size-6" />
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
    <div class="space-y-3">
      <%!-- Header --%>
      <div class="flex items-baseline justify-between">
        <p class="text-sm font-semibold text-base-content/50 uppercase tracking-widest">
          Session complete
        </p>
        <p class="text-xs text-base-content/30 tabular-nums">
          {@summary.burpee_count_total} reps · {Fmt.duration_sec(round(@summary.duration_sec_total))} planned
        </p>
      </div>

      <%!-- Mood --%>
      <div class="rounded-[10px] bg-base-300 overflow-hidden flex">
        <%= for {icon, label, value} <- @mood_options do %>
          <button
            type="button"
            phx-click="set_mood"
            phx-value-mood={value}
            class={[
              "flex-1 flex flex-col items-center gap-1.5 py-4 text-[10px] uppercase tracking-widest transition",
              if(@mood == value,
                do: "text-primary bg-primary/10",
                else: "text-base-content/30 hover:text-base-content/60 hover:bg-base-raised"
              )
            ]}
          >
            <.icon name={icon} class="size-5" />
            {label}
          </button>
          <%= if value != 1 do %>
            <div class="w-px bg-base-border self-stretch" />
          <% end %>
        <% end %>
      </div>

      <.form
        for={@form}
        id="session-completion-form"
        phx-change="validate_session"
        phx-submit="save_session"
        class="space-y-3"
      >
        <%!-- Reps + Duration dials --%>
        <div class="rounded-[10px] bg-base-300 overflow-hidden grid grid-cols-2">
          <div class="p-5 space-y-1 border-r border-base-border">
            <p class="text-[10px] text-base-content/30 uppercase tracking-widest">Reps</p>
            <input
              type="number"
              name={@form[:burpee_count_actual].name}
              value={@form[:burpee_count_actual].value}
              min="0"
              inputmode="numeric"
              class="w-full bg-transparent text-4xl font-bold tabular-nums focus:outline-none leading-none"
            />
          </div>
          <div class="p-5 space-y-1">
            <p class="text-[10px] text-base-content/30 uppercase tracking-widest">Min</p>
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
              class="w-full bg-transparent text-4xl font-bold tabular-nums focus:outline-none leading-none"
            />
          </div>
        </div>

        <%!-- Tags --%>
        <div class="rounded-[10px] bg-base-300 px-4 py-3 flex flex-wrap gap-2">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              class={[
                "rounded-full px-3 py-1 text-xs border transition",
                tag in @completion_tags && "border-primary/40 text-primary bg-primary/10",
                tag not in @completion_tags &&
                  "border-base-border text-base-content/35 hover:text-base-content/60"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <%!-- Note --%>
        <div class="rounded-[10px] bg-base-300 p-4">
          <p class="text-[10px] text-base-content/30 uppercase tracking-widest mb-2">Note</p>
          <textarea
            name={@form[:note_post].name}
            rows="2"
            placeholder="How did it go?"
            class="w-full bg-transparent text-sm text-base-content/80 focus:outline-none resize-none placeholder:text-base-content/20"
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
          class="w-full py-4 rounded-[10px] text-sm font-semibold tracking-wide bg-primary/75 text-primary-content hover:bg-primary/85 transition flex items-center justify-center gap-2"
        >
          Save session <.icon name="hero-arrow-right" class="size-4" />
        </button>
        <div class="text-center">
          <button
            type="button"
            phx-click="discard"
            data-confirm="Discard this session without saving?"
            class="text-xs text-base-content/30 hover:text-base-content/60 transition"
          >
            Discard
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
