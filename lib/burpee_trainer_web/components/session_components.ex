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

        <%!-- Paused, Finish early and Abort ask before they act; the question shows while armed. --%>
        <div id="session-finish-question" class="session-pause-question" aria-hidden="true">
          <p class="session-title">Finish early?</p>
          <p class="session-meta">What you've done is kept.</p>
        </div>
        <div id="session-abort-question" class="session-pause-question" aria-hidden="true">
          <p class="session-title">Abort workout?</p>
          <p class="session-meta">It won't be saved.</p>
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
              aria-pressed="false"
              aria-label="Finish early"
              title="Finish early"
              class="session-chip"
            >
              <.icon name="hero-flag" class="size-6" />
            </button>
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
  attr(:name, :string, required: true)

  # Finish: the count and how it went, then trash on the left and ✓ on the right. Trash asks in
  # place, as Abort does in the runner: armed, the page steps back and its question shows.
  def completion_review(assigns) do
    ~H"""
    <.panel id="session-completion-review" heading_id="session-completion-heading" hidden={@hidden}>
      <div class="session-finish">
        <section id="session-completion-summary" class="session-finish-summary">
          <h1
            id="session-completion-heading"
            data-session-heading
            data-name={@name}
            tabindex="-1"
            class="session-finish-title"
          >
            {@name}
          </h1>
          <%!-- The count is the result; − and + correct it. Holding one keeps counting. --%>
          <div class="session-reps-stepper">
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
              class="session-finish-count qs-tabular"
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
          <%!-- What was planned and how long it took, then how far through the plan's sets. --%>
          <p class="session-finish-meta qs-tabular">
            of <span id="session-planned-reps">0</span>
            reps · <span id="session-actual-duration">0:00</span>
            of <span id="session-planned-duration">0:00</span>
          </p>
          <p id="session-sets-done" class="session-finish-sets qs-tabular" hidden></p>
          <%!-- Who counted; after a correction, the original and a way back. --%>
          <p id="session-count-source" class="session-finish-source" hidden>
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

        <.form for={@form} id="session-completion-form" class="session-finish-form">
          <div id="session-completion-fields">
            <.mood_pills id="session-completion-mood" />
            <.tag_pills id="session-completion-tags" />
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
          </div>

          <%!-- A finished workout is saved or deleted; nothing else. --%>
          <div id="session-completion-actions" class="session-finish-actions">
            <button
              id="session-discard-btn"
              type="button"
              aria-pressed="false"
              aria-label="Delete session"
              title="Delete session"
              class="session-finish-trash"
            >
              <.icon name="hero-trash" class="size-6" />
            </button>
            <button
              id="session-save-btn"
              type="submit"
              aria-label="Save"
              title="Save"
              class="session-finish-save"
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
      <%!-- Armed, trash's question takes the page's place; the live status says it aloud. --%>
      <div id="session-delete-question" class="session-pause-question" aria-hidden="true">
        <p class="session-finish-question">Delete this session?</p>
        <p class="session-finish-consequence">It won't be saved. Tap again to delete.</p>
      </div>
    </.panel>
    """
  end

  attr(:id, :string, required: true)
  attr(:mood, :integer, default: nil)
  attr(:click, :string, default: nil, doc: "the LiveView event a tap sends, if any")

  @doc "How it felt, as three pills; the chosen one takes its colour (Rough, OK, Good)."
  def mood_pills(assigns) do
    assigns = assign(assigns, :mood_options, @mood_options)

    ~H"""
    <div id={@id} role="group" aria-label="How it felt" class="session-moods">
      <button
        :for={{label, value} <- @mood_options}
        type="button"
        data-mood={value}
        phx-click={@click}
        phx-value-mood={@click && value}
        aria-pressed={to_string(@mood == value)}
        class="session-mood"
      >
        {label}
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:tags, :list, default: [])
  attr(:click, :string, default: nil, doc: "the LiveView event a tap sends, if any")

  @doc "Optional tags that toggle; chosen ones are amber."
  def tag_pills(assigns) do
    assigns = assign(assigns, :tag_options, @tag_options)

    ~H"""
    <div id={@id} role="group" aria-label="Tags" class="session-tags">
      <button
        :for={{label, value} <- @tag_options}
        type="button"
        data-tag={value}
        phx-click={@click}
        phx-value-tag={@click && value}
        aria-pressed={to_string(value in @tags)}
        class="session-tag-pill"
      >
        {label}
      </button>
    </div>
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
