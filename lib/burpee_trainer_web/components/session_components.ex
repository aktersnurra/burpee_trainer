defmodule BurpeeTrainerWeb.SessionComponents do
  @moduledoc """
  Stable markup for the client-owned workout session runtime.
  """

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainerWeb.Fmt

  attr(:hidden, :boolean, default: true)
  attr(:target_pace_sec, :any, default: nil)
  attr(:session, :map, required: true)

  # The one camera screen, from starting to "hand up". Its heading is the status line.
  def camera_setup(assigns) do
    ~H"""
    <.panel id="session-camera-setup" heading_id="camera-setup-heading" hidden={@hidden}>
      <.preflight_chrome id="session-camera-setup" session={@session} />
      <div class="session-camera-layout absolute inset-0 mx-auto grid w-full max-w-[640px] text-center">
        <div class="row-start-1 w-full max-w-[640px] place-self-center self-center px-5">
          <h1
            id="camera-setup-heading"
            data-session-heading
            tabindex="-1"
            aria-live="polite"
            class="qs-heading-tight text-3xl font-medium leading-tight"
          >
            Starting camera
          </h1>
          <p
            id="camera-setup-failure-detail"
            hidden
            class="mx-auto mt-2 max-w-md break-words text-sm text-[var(--session-muted)]"
          >
          </p>
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

        <div class="row-start-3 flex flex-col items-center gap-1 place-self-center">
          <button
            id="camera-setup-retry"
            type="button"
            hidden
            inert="inert"
            aria-label="Try the camera again"
            title="Try the camera again"
            class="inline-flex size-14 items-center justify-center rounded-full bg-[var(--session-ink)] text-[var(--session-bg)]"
          >
            <.icon name="hero-arrow-path" class="size-6" />
          </button>
          <button
            id="camera-setup-continue"
            type="button"
            class="px-5 py-3 text-sm text-[var(--session-muted)] underline underline-offset-4"
          >
            Continue without camera
          </button>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:id, :string, required: true)
  attr(:session, :map, required: true)

  defp preflight_chrome(assigns) do
    ~H"""
    <div class="session-preflight-chrome">
      <.link
        id={"#{@id}-back"}
        navigate={~p"/"}
        aria-label="Back to Home"
        title="Back to Home"
        class="session-preflight-back"
      >
        <.icon name="hero-arrow-left" class="size-5" />
      </.link>
      <p class="session-preflight-workout-name">
        {@session.display_name_snapshot || Fmt.burpee_type(@session.burpee_type)}
      </p>
    </div>
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
          <div id="session-work-fill" class="absolute inset-0"></div>
          <div id="session-rest-breathe-light" class="absolute inset-0" inert></div>
          <div id="session-rest-breathe-dark" class="absolute inset-0" inert></div>
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
                  Pace progress: 0 of {@summary.burpee_count_total} reps
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
              <%!-- Leaves the session started, as the start screens' back arrow did. --%>
              <.link
                id="session-pause-leave"
                navigate={~p"/"}
                aria-label="Back to Home"
                title="Back to Home"
                class="session-pause-leave inline-flex size-14 items-center justify-center rounded-full"
              >
                <.icon name="hero-arrow-left" class="size-6" />
              </.link>
            </div>
          </div>
        </div>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)
  attr(:form, :any, required: true)

  @mood_options [{"Rough", -1}, {"OK", 0}, {"Good", 1}]
  @tag_options [
    {"Tired", "tired"},
    {"Great energy", "great_energy"},
    {"Bad sleep", "bad_sleep"},
    {"Sick", "sick"},
    {"Travel", "travel"},
    {"Hot", "hot"}
  ]

  def completion_review(assigns) do
    assigns = assign(assigns, mood_options: @mood_options, tag_options: @tag_options)

    ~H"""
    <.panel id="session-completion-review" heading_id="session-completion-heading" hidden={@hidden}>
      <%!-- Centred like the camera screen; the auto margins still let a tall form scroll. --%>
      <div class="mx-auto flex h-dvh w-full max-w-[480px] flex-col overflow-y-auto px-6 pb-10 pt-[max(3rem,env(safe-area-inset-top))]">
        <section id="session-completion-summary" class="mt-auto text-center">
          <h1
            id="session-completion-heading"
            data-session-heading
            tabindex="-1"
            class="qs-heading-tight text-3xl font-medium"
          >
            Workout complete
          </h1>
          <%!-- The count and the time are the result; tapping one opens it for correction. --%>
          <button
            id="completion-reps-edit"
            type="button"
            aria-label="Correct reps"
            title="Correct reps"
            aria-controls="completion-reps-field"
            class="mt-7 rounded-2xl px-3"
          >
            <span
              id="session-actual-reps"
              class="qs-tabular block text-[clamp(5rem,18vw,6.5rem)] font-medium leading-none tracking-[-0.07em]"
            >
              0
            </span>
          </button>
          <%!-- What was planned and how long it took, in one line under the count. --%>
          <p class="qs-tabular mt-4 text-lg text-[var(--session-muted)]">
            of <span id="session-planned-reps">0</span>
            ·
            <button
              id="completion-duration-edit"
              type="button"
              aria-label="Correct time"
              title="Correct time"
              aria-controls="completion-duration-field"
              class="underline-offset-4 hover:underline"
            >
              <span id="session-actual-duration">0:00</span>
            </button>
          </p>
          <p id="session-count-source" class="mt-2 text-sm text-[var(--session-muted)]" hidden></p>
        </section>

        <div
          id="session-save-errors"
          tabindex="-1"
          class="mt-8 hidden rounded-2xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
        >
        </div>

        <.form for={@form} id="session-completion-form" class="mt-7 mb-auto">
          <div class="grid grid-cols-2 gap-5">
            <div id="completion-reps-field" hidden>
              <.input
                field={@form[:burpee_count_actual]}
                id="completion-reps-input"
                type="number"
                label="Reps"
                min="0"
                inputmode="numeric"
                aria-describedby="completion-reps-error"
                class="qs-tabular min-h-12 w-full border-0 border-b border-[var(--session-border)] bg-transparent px-0 text-xl text-[var(--session-ink)]"
              />
              <p id="completion-reps-error" hidden></p>
            </div>
            <div id="completion-duration-field" hidden>
              <.input
                field={@form[:duration_sec_actual]}
                id="completion-duration-input"
                type="number"
                label="Seconds"
                min="0"
                inputmode="numeric"
                aria-describedby="completion-duration-error"
                class="qs-tabular min-h-12 w-full border-0 border-b border-[var(--session-border)] bg-transparent px-0 text-xl text-[var(--session-ink)]"
              />
              <p id="completion-duration-error" hidden></p>
            </div>
          </div>
          <div id="session-completion-mood" class="mt-8 flex border-y border-[var(--session-border)]">
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
          <%!-- Optional, like mood: tap to toggle. Pills as on Home. --%>
          <div id="session-completion-tags" role="group" aria-label="Tags" class="session-tags">
            <%= for {label, value} <- @tag_options do %>
              <button type="button" data-tag={value} aria-pressed="false" class="session-tag-pill">
                {label}
              </button>
            <% end %>
          </div>
          <%!-- One line that grows, underlined like Home's fields. --%>
          <div class="session-note-field">
            <label for="completion-note-input" class="sr-only">Note</label>
            <textarea
              id="completion-note-input"
              name={@form[:note_post].name}
              rows="1"
              placeholder="How did it go?"
              aria-describedby="completion-note-error"
              class="session-note-input"
            >{@form[:note_post].value}</textarea>
            <p id="completion-note-error" hidden></p>
          </div>

          <div class="hidden">
            <.input field={@form[:burpee_type]} type="hidden" />
            <.input field={@form[:burpee_count_planned]} type="hidden" />
            <.input field={@form[:duration_sec_planned]} type="hidden" />
            <.input field={@form[:client_session_id]} type="hidden" />
          </div>

          <%!-- Discarding deletes the started session; it asks here, not in a dialog. --%>
          <div
            id="session-discard-confirm"
            hidden
            role="group"
            aria-labelledby="session-discard-question"
            class="mt-6 border-t border-[var(--session-border)] pt-5 text-center"
          >
            <p id="session-discard-question" class="text-base">
              Discard this workout? Nothing will be saved.
            </p>
            <div class="mt-4 flex items-center justify-center gap-3">
              <button
                id="session-discard-keep"
                type="button"
                class="min-h-11 px-5 text-sm text-[var(--session-muted)] underline underline-offset-4"
              >
                Keep it
              </button>
              <button
                id="session-discard-yes"
                type="button"
                class="min-h-11 rounded-full border border-red-700/60 px-5 text-sm font-medium text-red-700"
              >
                Discard
              </button>
            </div>
          </div>

          <%!-- A finished workout is saved or discarded; nothing else. --%>
          <div class="mt-6 flex items-center justify-between gap-3">
            <button
              id="session-discard-btn"
              type="button"
              aria-label="Discard session"
              title="Discard session"
              aria-controls="session-discard-confirm"
              class="inline-flex size-14 items-center justify-center rounded-full border border-[var(--session-border)] text-[var(--session-ink)] transition-colors hover:bg-[var(--session-border)]/35"
            >
              <.icon name="hero-trash" class="size-6" />
            </button>
            <button
              id="session-save-btn"
              type="submit"
              aria-label="Save session"
              title="Save session"
              class="inline-flex size-14 items-center justify-center rounded-full bg-[var(--session-ink)] text-[var(--session-bg)] transition-opacity hover:opacity-90"
            >
              <span id="session-save-icon-ready" aria-hidden="true">
                <.icon name="hero-check" class="size-6" />
              </span>
              <span id="session-save-icon-pending" aria-hidden="true" hidden>
                <.icon name="hero-arrow-path" class="size-6" />
              </span>
            </button>
          </div>
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
