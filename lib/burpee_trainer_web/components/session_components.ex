defmodule BurpeeTrainerWeb.SessionComponents do
  @moduledoc """
  Stable markup for the client-owned workout session runtime.
  """

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainerWeb.Fmt

  attr(:hidden, :boolean, default: true)

  def capture_choice(assigns) do
    ~H"""
    <.panel
      id="session-capture-choice"
      heading_id="session-capture-choice-heading"
      hidden={@hidden}
    >
      <div class="mx-auto flex min-h-dvh w-full max-w-[430px] flex-col items-center justify-center px-6 text-center">
        <h1
          id="session-capture-choice-heading"
          data-session-heading
          tabindex="-1"
          class="qs-heading-tight text-4xl font-medium leading-tight"
        >
          Track burpees with the camera?
        </h1>
        <p class="mt-4 max-w-sm text-base leading-relaxed text-[var(--session-muted)]">
          The workout timer runs either way. Camera tracking adds a backup rep count.
        </p>
        <div class="mt-10 grid w-full gap-3">
          <button
            id="camera-choice-yes"
            type="button"
            class="min-h-14 rounded-2xl bg-[var(--session-ink)] px-6 py-4 text-base font-semibold text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.99]"
          >
            Yes, use camera
          </button>
          <button
            id="camera-choice-no"
            type="button"
            class="min-h-14 rounded-2xl border border-[var(--session-border)] px-6 py-4 text-base font-medium text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)] active:scale-[0.99]"
          >
            No, continue
          </button>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)

  def camera_status(assigns) do
    ~H"""
    <.panel id="session-camera-status" heading_id="camera-status-heading" hidden={@hidden}>
      <div class="mx-auto flex min-h-dvh w-full max-w-[430px] flex-col items-center justify-center px-6 text-center">
        <div id="camera-status-starting">
          <h1
            id="camera-status-heading"
            data-session-heading
            tabindex="-1"
            class="qs-heading-tight text-4xl font-medium leading-tight"
          >
            Starting camera
          </h1>
        </div>
        <div id="camera-status-error" hidden inert="inert">
          <h2 class="qs-heading-tight text-4xl font-medium leading-tight">Camera unavailable</h2>
          <p class="mt-4 text-base text-[var(--session-muted)]">Nothing has started.</p>
          <div class="mt-10 grid w-full gap-3">
            <button
              id="camera-status-retry"
              type="button"
              class="min-h-14 rounded-2xl bg-[var(--session-ink)] px-6 py-4 font-semibold text-[var(--session-bg)]"
            >
              Try again
            </button>
            <button
              id="camera-status-continue"
              type="button"
              class="min-h-14 px-6 py-4 text-[var(--session-muted)] underline underline-offset-4"
            >
              Continue without camera
            </button>
          </div>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)
  attr(:target_pace_sec, :any, default: nil)

  def camera_setup(assigns) do
    ~H"""
    <.panel id="session-camera-setup" heading_id="camera-setup-heading" hidden={@hidden}>
      <div class="session-camera-layout absolute inset-0 grid text-center">
        <div class="row-start-1 w-full max-w-[430px] place-self-center self-center px-5">
          <div id="camera-setup-arming">
            <h1
              id="camera-setup-heading"
              data-session-heading
              tabindex="-1"
              class="qs-heading-tight text-3xl font-medium leading-tight"
            >
              Step into frame
            </h1>
            <p class="mx-auto mt-2 max-w-md text-sm leading-relaxed text-[var(--session-muted)]">
              Keep shoulders, hips, and one knee visible.
            </p>
          </div>
          <div id="camera-setup-ready" hidden inert="inert">
            <h2 class="qs-heading-tight text-3xl font-medium leading-tight">Camera ready</h2>
            <p class="mx-auto mt-2 max-w-md text-sm leading-relaxed text-[var(--session-muted)]">
              Hold one hand up or stay still.
            </p>
          </div>
        </div>

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
            <canvas id="pose-tracker-canvas" class="absolute inset-0 h-full w-full"></canvas>
          </div>
        </div>

        <button
          id="camera-setup-continue"
          type="button"
          class="row-start-3 mt-20 place-self-center px-5 py-3 text-sm text-[var(--session-muted)] underline underline-offset-4"
        >
          Continue without camera
        </button>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)

  def warmup_choice(assigns) do
    ~H"""
    <.panel id="session-warmup-choice" heading_id="session-warmup-heading" hidden={@hidden}>
      <div class="mx-auto flex min-h-dvh w-full max-w-[430px] flex-col items-center justify-center px-6 text-center">
        <h1
          id="session-warmup-heading"
          data-session-heading
          tabindex="-1"
          class="qs-heading-tight text-4xl font-medium leading-tight"
        >
          Warm up first?
        </h1>
        <p id="warmup-tracked-instruction" class="mt-4 text-lg text-[var(--session-muted)]">
          Raise one hand to warm up.
        </p>
        <p id="warmup-skip-countdown" class="qs-tabular mt-3 text-base text-[var(--session-muted)]">
          Skipping in <span id="warmup-skip-seconds">4</span>
        </p>
        <div id="warmup-manual-controls" class="mt-10 grid w-full gap-3" hidden inert="inert">
          <button
            id="warmup-yes-btn"
            type="button"
            class="min-h-14 rounded-2xl bg-[var(--session-ink)] px-6 py-4 font-semibold text-[var(--session-bg)]"
          >
            Warm up
          </button>
          <button
            id="warmup-skip-btn"
            type="button"
            class="min-h-14 rounded-2xl border border-[var(--session-border)] px-6 py-4 text-[var(--session-muted)]"
          >
            Skip warmup
          </button>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)

  def workout_ready(assigns) do
    ~H"""
    <.panel id="session-workout-ready" heading_id="session-workout-ready-heading" hidden={@hidden}>
      <div class="mx-auto flex min-h-dvh w-full max-w-[430px] flex-col items-center justify-center px-6 text-center">
        <h1
          id="session-workout-ready-heading"
          data-session-heading
          tabindex="-1"
          class="qs-heading-tight text-4xl font-medium leading-tight"
        >
          Ready when you are
        </h1>
        <p id="workout-ready-instruction" class="mt-4 text-lg text-[var(--session-muted)]">
          Hold one hand up to start.
        </p>
        <button
          id="workout-ready-btn"
          type="button"
          hidden
          inert="inert"
          class="mt-10 min-h-14 w-full rounded-2xl bg-[var(--session-ink)] px-6 py-4 font-semibold text-[var(--session-bg)]"
        >
          Start workout
        </button>
        <button
          id="workout-ready-continue"
          type="button"
          class="mt-6 min-h-11 px-5 py-3 text-sm text-[var(--session-muted)] underline underline-offset-4"
        >
          Continue without camera
        </button>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)
  attr(:summary, :map, required: true)

  def runner(assigns) do
    ~H"""
    <.panel id="session-runner-client" heading_id="session-runner-heading" hidden={@hidden}>
      <h1 id="session-runner-heading" data-session-heading tabindex="-1" class="sr-only">
        Workout in progress
      </h1>
      <div class="relative min-h-dvh w-full overflow-hidden">
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
          <div id="session-top-readout" class="pointer-events-none">
            <div id="session-progress" hidden aria-hidden="true">
              <div id="session-progress-fill"></div>
            </div>
            <div id="session-status-line" class="qs-tabular flex items-start">
              <div id="total-reps" class="flex items-baseline" hidden>
                <span id="total-reps-accessible" class="sr-only">
                  0 of {@summary.burpee_count_total} total reps
                </span>
                <span id="total-done" data-total-plan={@summary.burpee_count_total} aria-hidden="true">
                  0
                </span>
                <span id="total-separator" aria-hidden="true" hidden>/</span>
                <span id="total-plan" aria-hidden="true" hidden>{@summary.burpee_count_total}</span>
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
                class="session-finish-early-action px-6 py-4 text-lg font-medium disabled:invisible"
              >
                Finish early
              </button>
              <button
                id="session-abort-btn"
                type="button"
                disabled
                data-confirm="Abort this session without saving?"
                class="px-6 py-3 text-base text-[var(--session-active-ink)]"
              >
                Abort
              </button>
            </div>
          </div>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)
  attr(:form, :any, required: true)

  @mood_options [{"Tired", -1}, {"OK", 0}, {"Hyped", 1}]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  def completion_review(assigns) do
    assigns = assign(assigns, mood_options: @mood_options, tag_options: @tag_options)

    ~H"""
    <.panel id="session-completion-review" heading_id="session-completion-heading" hidden={@hidden}>
      <div class="mx-auto h-dvh w-full max-w-[430px] overflow-y-auto px-5 pb-10 pt-[max(4rem,env(safe-area-inset-top))]">
        <section id="session-completion-summary" class="text-center">
          <h1
            id="session-completion-heading"
            data-session-heading
            tabindex="-1"
            class="qs-heading-tight text-3xl font-medium"
          >
            Workout complete
          </h1>
          <p
            id="session-actual-reps"
            class="qs-tabular mt-8 text-[clamp(5rem,24vw,9rem)] font-semibold leading-none tracking-[-0.08em]"
          >
            0
          </p>
          <p class="qs-tabular mt-4 text-sm text-[var(--session-muted)]">
            of <span id="session-planned-reps" class="font-medium text-[var(--session-ink)]">0</span>
            planned
          </p>
          <p id="session-count-source" class="mt-3 text-xs text-[var(--session-muted)]" hidden></p>
          <p id="session-actual-duration" class="qs-tabular mt-8 text-3xl font-medium">0:00</p>
        </section>

        <div
          id="session-save-errors"
          tabindex="-1"
          class="mt-8 hidden rounded-2xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
        >
        </div>

        <div
          id="session-report-pending-status"
          role="status"
          aria-live="polite"
          hidden
          inert="inert"
          class="mt-8 rounded-2xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
        >
          We could not prepare this workout for saving. Your workout details are still here.
        </div>
        <button
          id="session-report-pending-retry"
          type="button"
          hidden
          inert="inert"
          class="mt-3 min-h-14 w-full rounded-2xl bg-[var(--session-ink)] px-6 py-4 font-semibold text-[var(--session-bg)]"
        >
          Try again
        </button>

        <div id="session-completion-mood" class="mt-10 flex border-y border-[var(--session-border)]">
          <%= for {label, value} <- @mood_options do %>
            <button
              type="button"
              data-mood={value}
              aria-pressed="false"
              class="session-choice-toggle min-h-14 flex-1 text-sm font-medium text-[var(--session-muted)] transition-colors duration-150 active:scale-[0.98]"
            >
              {label}
            </button>
          <% end %>
        </div>

        <.form for={@form} id="session-completion-form" class="mt-10">
          <.input
            field={@form[:burpee_count_actual]}
            id="completion-reps-input"
            type="number"
            label="Reps"
            min="0"
            inputmode="numeric"
            aria-describedby="completion-reps-error"
            class="qs-tabular min-h-14 w-full rounded-xl border border-[var(--session-border)] bg-transparent px-4 text-2xl text-[var(--session-ink)]"
          />
          <p id="completion-reps-error" hidden></p>
          <.input
            field={@form[:duration_sec_actual]}
            id="completion-duration-input"
            type="number"
            label="Seconds"
            min="0"
            inputmode="numeric"
            aria-describedby="completion-duration-error"
            class="qs-tabular min-h-14 w-full rounded-xl border border-[var(--session-border)] bg-transparent px-4 text-2xl text-[var(--session-ink)]"
          />
          <p id="completion-duration-error" hidden></p>
          <.input
            field={@form[:note_post]}
            id="completion-note-input"
            type="textarea"
            label="Note"
            rows="3"
            placeholder="How did it go?"
            aria-describedby="completion-note-error"
            class="w-full resize-none rounded-xl border border-[var(--session-border)] bg-transparent px-4 py-3 text-sm text-[var(--session-ink)]"
          />
          <p id="completion-note-error" hidden></p>

          <div id="session-completion-tags" class="border-t border-[var(--session-border)] py-6">
            <p class="mb-3 text-sm font-medium text-[var(--session-muted)]">Tags</p>
            <div class="flex flex-wrap gap-2">
              <%= for tag <- @tag_options do %>
                <button
                  type="button"
                  data-tag={tag}
                  aria-pressed="false"
                  class="session-choice-toggle min-h-11 rounded-full border border-[var(--session-border)] px-4 py-2 text-xs text-[var(--session-muted)] transition-colors duration-150 active:scale-[0.98]"
                >
                  {String.replace(tag, "_", " ")}
                </button>
              <% end %>
            </div>
          </div>

          <div class="hidden">
            <.input field={@form[:burpee_type]} type="hidden" />
            <.input field={@form[:burpee_count_planned]} type="hidden" />
            <.input field={@form[:duration_sec_planned]} type="hidden" />
            <.input field={@form[:client_session_id]} type="hidden" />
          </div>

          <button
            id="session-save-btn"
            type="submit"
            class="mt-8 min-h-14 w-full rounded-2xl bg-[var(--session-ink)] px-6 py-4 font-semibold text-[var(--session-bg)]"
          >
            Save session
          </button>
          <button
            id="session-discard-btn"
            type="button"
            data-confirm="Discard this session?"
            class="mx-auto mt-2 block min-h-11 px-6 py-3 text-sm text-[var(--session-muted)]"
          >
            Discard
          </button>
        </.form>
      </div>
    </.panel>
    """
  end

  attr(:id, :string, required: true)
  attr(:heading_id, :string, required: true)
  attr(:hidden, :boolean, required: true)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <section
      id={@id}
      data-session-panel
      hidden={@hidden}
      inert={@hidden && "inert"}
      aria-labelledby={@heading_id}
      class="absolute inset-0 bg-[var(--session-bg)] text-[var(--session-ink)]"
    >
      {render_slot(@inner_block)}
    </section>
    """
  end
end
