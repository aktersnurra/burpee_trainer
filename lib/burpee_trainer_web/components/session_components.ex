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
            ></video>
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
            ></span>
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
            <%!-- Paused, a workout is finished early or aborted; nothing else. --%>
            <div
              id="session-pause-choices"
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
                aria-controls="session-abort-confirm"
                class="session-pause-abort min-h-14 px-6 text-base font-medium"
              >
                Abort
              </button>
              <p id="session-abort-error" role="alert" class="text-sm" hidden></p>
            </div>
            <%!-- Aborting deletes the started session. The question takes the choices' place. --%>
            <div
              id="session-abort-confirm"
              hidden
              role="group"
              aria-labelledby="session-abort-question"
              aria-describedby="session-abort-consequence"
              class="session-pause-abort mx-auto w-full max-w-[360px] text-center"
            >
              <p id="session-abort-question" class="text-lg font-medium">Abort this workout?</p>
              <p id="session-abort-consequence" class="mt-1 text-sm opacity-80">
                Nothing will be saved.
              </p>
              <div class="mt-5 grid grid-cols-2 gap-3">
                <button
                  id="session-abort-keep"
                  type="button"
                  class="min-h-14 rounded-full border border-current text-base font-medium"
                >
                  Keep
                </button>
                <button
                  id="session-abort-yes"
                  type="button"
                  class="min-h-14 rounded-full bg-[var(--session-error-ink)] text-base font-medium text-white"
                >
                  Abort
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.panel>
    """
  end

  @mood_options [{"Rough", -1}, {"OK", 0}, {"Good", 1}]
  @tag_options [
    {"Tired", "tired"},
    {"Great energy", "great_energy"},
    {"Bad sleep", "bad_sleep"},
    {"Sick", "sick"},
    {"Travel", "travel"},
    {"Hot", "hot"}
  ]

  @doc "The finish screen's moods, as `{label, value}`; a video logs with the same ones."
  def mood_options, do: @mood_options

  @doc "The finish screen's tags, as `{label, value}`; a video logs with the same ones."
  def tag_options, do: @tag_options

  attr(:hidden, :boolean, default: true)
  attr(:form, :any, required: true)

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
          <%!-- The count is the result; − and + correct it. Holding one keeps counting. --%>
          <div class="session-reps-stepper mt-10">
            <button
              id="completion-reps-less"
              type="button"
              aria-label="One rep fewer"
              title="One rep fewer"
              aria-controls="session-actual-reps"
              class="session-reps-step"
            >
              <.icon name="hero-minus" class="size-6" />
            </button>
            <span
              id="session-actual-reps"
              aria-describedby="completion-reps-error"
              class="qs-tabular text-[clamp(5rem,18vw,6.5rem)] font-medium leading-none tracking-[-0.07em]"
            >
              0
            </span>
            <button
              id="completion-reps-more"
              type="button"
              aria-label="One rep more"
              title="One rep more"
              aria-controls="session-actual-reps"
              class="session-reps-step"
            >
              <.icon name="hero-plus" class="size-6" />
            </button>
          </div>
          <%!-- What was planned and how long it took, in one line under the count. --%>
          <p class="qs-tabular mt-5 text-lg text-[var(--session-muted)]">
            of <span id="session-planned-reps">0</span>
            · <span id="session-actual-duration">0:00</span>
          </p>
          <%!-- Where the count came from; after a correction, the original and a way back. --%>
          <p id="session-count-source" class="mt-2 text-sm text-[var(--session-muted)]" hidden>
            <span id="session-count-source-text"></span>
            <button
              id="completion-reps-undo"
              type="button"
              hidden
              class="min-h-11 px-2 text-[var(--session-ink)] underline underline-offset-4"
            >
              Undo
            </button>
          </p>
          <p id="completion-reps-error" class="mt-2 text-sm text-[var(--session-error-ink)]" hidden>
          </p>
        </section>

        <p id="session-save-status" hidden class="mt-8 text-sm text-[var(--session-muted)]"></p>
        <div
          id="session-save-errors"
          tabindex="-1"
          class="mt-8 hidden rounded-2xl border border-red-300/50 px-4 py-3 text-sm text-red-700"
        >
        </div>

        <.form for={@form} id="session-completion-form" class="mt-12 mb-auto">
          <div id="session-completion-mood" class="flex border-y border-[var(--session-border)]">
            <%= for {label, value} <- @mood_options do %>
              <button
                type="button"
                data-mood={value}
                aria-pressed="false"
                class="session-choice-toggle min-h-16 flex-1 text-sm font-medium text-[var(--session-muted)] transition-colors duration-150 active:scale-[0.98]"
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
          <%!-- A composer like Home's; it grows with its text. --%>
          <div class="session-note-field composer">
            <label for="completion-note-input" class="sr-only">Note</label>
            <textarea
              id="completion-note-input"
              name={@form[:note_post].name}
              rows="2"
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

          <%!-- A finished workout is saved or discarded; nothing else. --%>
          <div id="session-completion-actions" class="mt-12 flex items-center justify-between gap-3">
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

          <%!-- Discarding deletes the started session. The question takes the buttons' place. --%>
          <div
            id="session-discard-confirm"
            hidden
            role="group"
            aria-labelledby="session-discard-question"
            aria-describedby="session-discard-consequence"
            class="mt-12 text-center"
          >
            <p id="session-discard-question" class="text-lg font-medium">Discard this workout?</p>
            <p id="session-discard-consequence" class="mt-1 text-sm text-[var(--session-muted)]">
              Nothing will be saved.
            </p>
            <div class="mt-5 grid grid-cols-2 gap-3">
              <button
                id="session-discard-keep"
                type="button"
                class="min-h-14 rounded-full border border-[var(--session-border)] text-base font-medium text-[var(--session-ink)] transition-colors hover:bg-[var(--session-border)]/35"
              >
                Keep
              </button>
              <button
                id="session-discard-yes"
                type="button"
                class="min-h-14 rounded-full bg-[var(--session-error-ink)] text-base font-medium text-white transition-opacity hover:opacity-90"
              >
                Discard
              </button>
            </div>
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
