defmodule BurpeeTrainerWeb.SessionComponents do
  @moduledoc """
  Stable markup for the client-owned workout session runtime.
  """

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainerWeb.Fmt

  attr(:hidden, :boolean, default: true)
  attr(:target_pace_sec, :any, default: nil)
  attr(:session, :map, required: true)

  # The one camera screen, from starting to "hand up": the feed fills the screen and its
  # heading, at the top, is the status.
  def camera_setup(assigns) do
    ~H"""
    <.panel
      id="session-camera-setup"
      heading_id="camera-setup-heading"
      hidden={@hidden}
      class="session-night"
    >
      <div
        id="pose-tracker"
        phx-hook="PoseTracker"
        phx-update="ignore"
        data-target-pace-sec={@target_pace_sec}
        class="contents"
      >
        <div id="pose-tracker-preview-frame" class="session-camera-feed">
          <video
            id="pose-tracker-preview"
            class="absolute inset-0 h-full w-full object-cover scale-x-[-1]"
            muted
            playsinline
          ></video>
          <canvas id="pose-tracker-canvas" class="absolute inset-0 h-full w-full"></canvas>
        </div>
      </div>
      <div class="session-camera-vignette" aria-hidden="true"></div>

      <.link
        id="session-camera-setup-back"
        navigate={~p"/"}
        aria-label="Back to Home"
        title="Back to Home"
        class="session-preflight-back"
      >
        <.icon name="hero-arrow-left" class="size-5" />
      </.link>

      <div class="session-title-block">
        <h1
          id="camera-setup-heading"
          data-session-heading
          tabindex="-1"
          aria-live="polite"
          class="session-title"
        >
          Starting camera
        </h1>
        <p id="camera-setup-detail" class="session-meta">
          {@session.display_name_snapshot || Fmt.burpee_type(@session.burpee_type)}
        </p>
        <p id="camera-setup-failure-detail" hidden class="session-meta break-words"></p>
      </div>

      <div class="session-foot">
        <button
          id="camera-setup-retry"
          type="button"
          hidden
          inert="inert"
          aria-label="Try the camera again"
          title="Try the camera again"
          class="session-chip"
        >
          <.icon name="hero-arrow-path" class="size-6" />
        </button>
        <button
          id="camera-setup-continue"
          type="button"
          aria-label="Continue without camera"
          title="Continue without camera"
          class="session-chip"
        >
          <.icon name="hero-video-camera-slash" class="size-6" />
        </button>
      </div>
    </.panel>
    """
  end

  attr(:hidden, :boolean, default: true)
  attr(:summary, :map, required: true)

  # Every runner screen is the same four parts: the workout line, a title block (count-in
  # and pause), the hero (the number, the sink's disc, the pause mark) and the foot slot.
  def runner(assigns) do
    ~H"""
    <.panel
      id="session-runner-client"
      heading_id="session-runner-heading"
      hidden={@hidden}
      class="session-night"
    >
      <h1 id="session-runner-heading" data-session-heading tabindex="-1" class="sr-only">
        Workout in progress
      </h1>
      <div class="session-stage">
        <div id="session-visual-layers" aria-hidden="true">
          <canvas id="session-sink"></canvas>
          <div id="session-work-fill"></div>
          <div id="session-work-line"><span></span></div>
        </div>

        <div id="session-line" aria-hidden="true">
          <div id="session-line-fill"></div>
        </div>
        <span id="total-reps-accessible" class="sr-only">
          Pace progress: 0 of {@summary.burpee_count_total} reps
        </span>
        <span id="session-time-accessible" class="sr-only">
          Session time remaining {Fmt.duration_sec(round(@summary.duration_sec_total))}
        </span>

        <div id="session-title-block" class="session-title-block" aria-hidden="true">
          <p class="session-title">{@summary.name}</p>
          <p id="session-meta" class="session-meta">
            {@summary.set_count} sets · {@summary.burpee_count_total} reps
          </p>
        </div>

        <div
          id="ring-container"
          role="button"
          tabindex="0"
          aria-label="Pause session"
        >
          <span id="count" class="session-number qs-tabular" aria-hidden="true">—</span>
          <span id="count-on-fill" class="session-number qs-tabular" aria-hidden="true">—</span>
          <span id="session-ring" aria-hidden="true"></span>
          <svg id="pause-icon" viewBox="0 0 48 100" fill="currentColor" aria-hidden="true">
            <rect x="4" y="0" width="14" height="100" rx="7" />
            <rect x="30" y="0" width="14" height="100" rx="7" />
          </svg>
        </div>

        <div class="session-foot">
          <span id="set-progress" class="qs-tabular" hidden aria-hidden="true"></span>
          <span
            id="session-camera-lost"
            class="session-chip"
            hidden
            role="img"
            aria-label="Camera stopped counting"
            title="Camera stopped counting"
          >
            <.icon name="hero-video-camera-slash" class="size-6" />
          </span>
        </div>

        <div id="session-pause-actions" aria-hidden="true" inert="inert">
          <%!-- Paused, a workout is finished early or aborted; nothing else. --%>
          <div id="session-pause-choices" aria-label="Paused session actions" role="group">
            <button
              id="finish-early-btn"
              type="button"
              disabled
              aria-label="Finish early"
              title="Finish early"
              class="session-chip"
            >
              <.icon name="hero-flag" class="size-6" />
            </button>
            <%!-- The first tap arms it, the second aborts and deletes the started session. --%>
            <button
              id="session-abort-btn"
              type="button"
              aria-pressed="false"
              aria-label="Abort workout"
              title="Abort workout"
              class="session-chip"
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
          </div>
          <p id="session-abort-error" role="alert" class="session-meta" hidden></p>
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
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <section
      id={@id}
      data-session-panel
      hidden={@hidden}
      inert={@hidden && "inert"}
      aria-labelledby={@heading_id}
      class={["absolute inset-0 bg-[var(--session-bg)] text-[var(--session-ink)]", @class]}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end
end
