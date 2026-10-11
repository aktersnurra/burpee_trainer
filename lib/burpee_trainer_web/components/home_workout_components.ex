defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html
  alias BurpeeTrainer.Coach.WorkoutRequest
  alias BurpeeTrainerWeb.CreationParameters

  defp open_chooser do
    JS.set_attribute({"inert", ""},
      to: "#home-summary, .home-workout-actions, #home-expansion-content"
    )
    |> JS.remove_attribute("hidden", to: "#home-alternatives-panel")
    |> JS.focus(to: "#home-chooser-close")
    |> JS.push("open_chooser")
  end

  defp close_chooser do
    JS.set_attribute({"hidden", ""}, to: "#home-alternatives-panel")
    |> JS.remove_attribute("inert",
      to: "#home-summary, .home-workout-actions, #home-expansion-content"
    )
    |> JS.focus(to: "#home-title-action")
    |> JS.push("close_chooser")
  end

  attr(:request, :map, required: true)
  attr(:editable, :boolean, default: false)

  def request_confirmation(assigns) do
    ~H"""
    <section
      id="home-request-confirmation"
      phx-mounted={JS.focus(to: "#home-request-confirm")}
      aria-labelledby="home-request-heading"
      class="home-review"
    >
      <h2 id="home-request-heading" class="home-review-heading">Review</h2>
      <dl class="home-review-values">
        <div class="rounded-lg bg-stone-100 p-3">
          <dt class="text-stone-500">Reps</dt>
          <dd id="home-request-reps" class="mt-1 font-semibold text-stone-900">
            {@request.target_reps}
          </dd>
        </div>
        <div class="rounded-lg bg-stone-100 p-3">
          <dt class="text-stone-500">Duration</dt>
          <dd id="home-request-duration" class="mt-1 font-semibold text-stone-900">
            {duration_label(@request.target_duration_sec)}
          </dd>
        </div>
        <div class="rounded-lg bg-stone-100 p-3">
          <dt class="text-stone-500">Movement</dt>
          <dd id="home-request-movement" class="mt-1 font-semibold text-stone-900">
            {if(@request.burpee_type == "six_count", do: "Six-count", else: "Navy Seal")}
          </dd>
        </div>
        <div class="rounded-lg bg-stone-100 p-3">
          <dt class="text-stone-500">Sets</dt>
          <dd id="home-request-style" class="mt-1 font-semibold text-stone-900">
            {if(@request.pacing_style == "unbroken", do: "Unbroken within sets", else: "Even")}
          </dd>
        </div>
      </dl>
      <p id="home-request-timing" class="mt-4 text-xs leading-relaxed text-stone-600">
        Timing ±{WorkoutRequest.timing_tolerance_sec()}s · reps and rests exact.
        <span class="sr-only">
          Total time and timed-rest starts may vary by up to {WorkoutRequest.timing_tolerance_sec()} seconds; the saved duration reflects the actual plan.
        </span>
      </p>
      <p id="home-request-recovery" class="mt-4 text-sm text-stone-700">
        <%= case @request.recovery do %>
          <% "required" -> %>
            Recovery between sets
          <% "forbidden" -> %>
            No rests
          <% "optional" -> %>
            Recovery as needed
        <% end %>
      </p>
      <p :if={@request.requested_pace_sec} id="home-request-pace" class="mt-2 text-sm text-stone-700">
        Requested movement pace: {@request.requested_pace_sec} seconds per rep
      </p>
      <div :if={@request.timed_rests != []} id="home-request-timed-rests" class="mt-4">
        <p class="text-sm font-medium text-stone-900">Timed rests</p>
        <ul class="mt-2 space-y-2 text-sm text-stone-700">
          <li
            :for={{rest, index} <- Enum.with_index(@request.timed_rests)}
            id={"home-request-rest-#{index}"}
          >
            {rest.duration_sec} seconds beginning at {elapsed_clock(rest.start_sec)}
          </li>
        </ul>
      </div>
      <div class="home-review-actions">
        <button
          :if={@editable}
          id="home-request-abort"
          type="button"
          phx-click={JS.push("abort_new_workout") |> JS.focus(to: "#home-summary")}
          class="home-icon-button"
          aria-label="Abort review"
          title="Abort"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <button
          :if={@editable}
          id="home-request-edit"
          type="button"
          phx-click={JS.push("edit_workout_request") |> JS.focus(to: "#home-review-reps")}
          class="home-icon-button"
          aria-label="Update interpretation"
          title="Update"
        >
          <.icon name="hero-pencil-square" class="size-5" />
        </button>
        <button
          id="home-request-confirm"
          type="button"
          phx-click="confirm_workout_request"
          class="home-icon-button"
          aria-label="Approve and plan"
          title="Approve"
        >
          <.icon name="hero-check" class="size-5" />
        </button>
        <button
          :if={!@editable}
          id="home-request-back"
          type="button"
          phx-click="back_to_workout_request"
          class="home-icon-button"
          aria-label="Back to request"
          title="Back"
        >
          <.icon name="hero-pencil-square" class="size-5" />
        </button>
      </div>
    </section>
    """
  end

  attr(:form, :any, required: true)
  attr(:stage, :atom, default: :new)
  attr(:candidate, :map, default: nil)
  attr(:busy, :boolean, default: false)
  attr(:review_inspection_rows, :list, default: [])
  attr(:expanded_groups, :any, default: MapSet.new())

  def authoring_form(assigns) do
    params = Ecto.Changeset.apply_changes(assigns.form.source)
    allocation = candidate_allocation(assigns.candidate)

    budget =
      case BurpeeTrainerWeb.HomeWorkoutRequest.budget(params) do
        {:ok, :unknown_pace} when not is_nil(allocation) ->
          {:ok, %{work_us: allocation.work_us, recovery_us: allocation.pool_us}}

        local ->
          local
      end

    assigns =
      assigns
      |> assign(:locked, assigns.stage == :review)
      |> assign(:budget, budget)
      |> assign(:allocation, allocation)

    ~H"""
    <.form
      for={@form}
      id="home-new-form"
      data-stage={@stage}
      phx-mounted={JS.focus(to: "#home-new-reps")}
      phx-submit="review_new_workout"
      phx-change="change_new_workout"
      class="home-authoring-form home-enter"
    >
      <.input field={@form[:burpee_type]} type="hidden" />
      <.input field={@form[:pacing_style]} type="hidden" />
      <div
        :for={
          {field, label, choices} <- [
            {:burpee_type, "Burpee type", [{"Six-count", "six_count"}, {"Navy Seal", "navy_seal"}]},
            {:pacing_style, "Set style", [{"Even", "even"}, {"Unbroken", "unbroken"}]}
          ]
        }
        class="home-pill-row"
        role="group"
        aria-label={label}
      >
        <span class="home-pill-label">{label}</span>
        <div class="home-pill-options">
          <button
            :for={{text, value} <- choices}
            id={"home-pill-#{field}-#{value}"}
            type="button"
            class="home-selection-pill"
            phx-click="choose_workout_value"
            phx-value-field={field}
            value={value}
            aria-pressed={to_string(@form[field].value == value)}
            disabled={@locked}
          >
            {text}
          </button>
        </div>
      </div>
      <.input
        field={@form[:reps]}
        id="home-new-reps"
        type="number"
        label="Total reps"
        unit="reps"
        min="1"
        max="100000"
        disabled={@locked}
        class="home-authoring-input"
      />
      <.input
        field={@form[:duration]}
        type="text"
        label="Duration"
        unit="min"
        placeholder="20:00"
        disabled={@locked}
        class="home-authoring-input"
      />
      <div
        id="home-workout-budget"
        class="home-budget"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        <%= case @budget do %>
          <% {:ok, %{work_us: work, recovery_us: recovery}} -> %>
            <span>Movement <strong>{budget_clock(work)}</strong></span>
            <span>Recovery <strong>{budget_clock(recovery)}</strong></span>
          <% {:ok, :unknown_pace} -> %>
            <span>The coach chooses the pace</span>
          <% _ -> %>
            <span>Check reps, pace and duration</span>
        <% end %>
        <p class="home-budget-detail">
          Timing ±{WorkoutRequest.timing_tolerance_sec()}s · reps and pauses exact.
        </p>
        <p :if={@allocation} id="home-workout-allocation" class="home-budget-detail">
          Allocated {budget_clock(@allocation.recovery_us)} · unallocated {budget_clock(
            @allocation.unallocated_us
          )}
          <span :if={@allocation.overrun_us > 0}>
            · +{budget_clock(@allocation.overrun_us)} schedule time
          </span>
        </p>
      </div>
      <.input
        field={@form[:pace]}
        type="number"
        step="any"
        min="0.000001"
        label="Pace"
        unit="s per rep"
        placeholder={
          if(@candidate && is_nil(@form[:pace].value), do: "Varies by set", else: "Coach chooses")
        }
        disabled={@locked}
        class="home-authoring-input"
      />
      <.input
        field={@form[:note]}
        type="textarea"
        rows="1"
        label="Anything else"
        placeholder="e.g. two sets of 25, a minute's break at 10:00"
        maxlength="300"
        disabled={@locked}
        class="home-authoring-input"
      />
      <p :if={@busy} id="home-update-loading" role="status" class="home-budget-detail">
        {if(@locked, do: "Saving…", else: "Preparing and validating…")}
      </p>
      <div class="home-review-actions">
        <button
          id="home-request-abort"
          type="button"
          phx-click="abort_new_workout"
          class="home-text-action"
          aria-label="Cancel new workout"
          disabled={@busy && @locked}
        >
          Cancel
        </button>
        <button
          :if={@locked}
          id="home-request-edit"
          type="button"
          phx-click={JS.push("edit_workout_request") |> JS.focus(to: "#home-new-reps")}
          class="home-text-action"
          aria-label="Edit workout"
          disabled={@busy}
        >
          Edit
        </button>
        <button
          :if={@locked}
          id="home-request-confirm"
          type="button"
          phx-click="confirm_workout_request"
          class="home-primary-action"
          aria-label="Approve and save workout"
          disabled={@busy || is_nil(@candidate)}
        >
          Save
        </button>
        <button
          :if={!@locked}
          id="home-new-review"
          type="submit"
          class="home-primary-action"
          aria-label="Review workout"
          disabled={@busy}
        >
          Review
        </button>
      </div>
      <section
        :if={@locked && @candidate}
        id="home-new-review-inspection"
        aria-label="Proposed workout structure"
      >
        <.inspection
          rows={@review_inspection_rows}
          expanded={@expanded_groups}
        />
        <p
          :if={@candidate.request.timed_rests != []}
          id="home-new-review-pauses"
          class="home-local-message"
        >
          {pauses_label(@candidate.request.timed_rests)}
        </p>
      </section>
    </.form>
    """
  end

  defp budget_clock(us) do
    seconds = div(us, 1_000_000)
    fraction = rem(us, 1_000_000)

    elapsed_clock(seconds) <>
      if(fraction == 0,
        do: "",
        else:
          "." <>
            (fraction
             |> Integer.to_string()
             |> String.pad_leading(6, "0")
             |> String.trim_trailing("0"))
      )
  end

  defp candidate_allocation(nil), do: nil

  defp candidate_allocation(candidate) do
    movement =
      candidate.definition["events"]
      |> Enum.filter(&(&1["kind"] == "work"))
      |> Enum.reduce(0, &(&2 + &1["reps"] * round(&1["sec_per_burpee"] * 1_000_000)))

    actual = candidate.definition["target_duration_sec"] * 1_000_000
    requested = candidate.original_request.target_duration_sec * 1_000_000

    %{
      work_us: movement,
      pool_us: requested - movement,
      recovery_us: actual - movement,
      unallocated_us: max(requested - actual, 0),
      overrun_us: max(actual - requested, 0)
    }
  end

  defp elapsed_clock(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  attr(:state, :map, required: true)

  def current_edit(assigns) do
    ~H"""
    <%= if @state.busy? do %>
      <div
        id="home-update-loading"
        role="status"
        aria-label={
          if(@state.authoring_stage == :review, do: "Saving variation", else: "Preparing variation")
        }
      >
        <img
          class="home-loading-animation"
          src="/images/burpee-loader-ink.gif"
          alt=""
          width="142"
          height="142"
        />
        <span id="home-edit-progress" class="home-local-message">
          {if(@state.authoring_stage == :review,
            do: "Saving variation…",
            else: "Preparing variation…"
          )}
        </span>
      </div>
      <div :if={@state.authoring_stage == :editing} class="home-review-actions">
        <button
          id="home-request-abort"
          type="button"
          class="home-text-action"
          aria-label="Cancel edit"
          phx-click="abort_new_workout"
        >
          Cancel
        </button>
      </div>
    <% else %>
      <%= if @state.authoring_stage == :editing do %>
        <.form
          for={@state.adjustment_form}
          id="home-edit-form"
          class="home-current-edit home-authoring-form home-enter"
          phx-submit="review_current_edit"
          phx-change="change_current_edit"
          aria-busy={to_string(@state.busy?)}
          phx-mounted={JS.focus(to: "#home-edit-instruction")}
        >
          <.input
            field={@state.adjustment_form[:instruction]}
            id="home-edit-instruction"
            type="textarea"
            label="What do you want to change?"
            placeholder="e.g. two sets of 25, a minute's rest between"
            rows="1"
            maxlength="500"
            class="home-authoring-input"
          />
          <div class="home-review-actions">
            <button
              type="button"
              id="home-request-abort"
              class="home-text-action"
              aria-label="Cancel edit"
              phx-click="abort_new_workout"
            >
              Cancel
            </button>
            <button
              type="submit"
              id="home-edit-send"
              class="home-primary-action"
              aria-label="Review variation"
            >
              Review
            </button>
          </div>
        </.form>
      <% else %>
        <section
          id="home-edit-review"
          class="home-review"
          phx-mounted={JS.focus(to: "#home-request-confirm")}
          aria-label="Proposed variation"
        >
          <h2 id="home-edit-review-name" class="home-review-name">
            {@state.pending_request.definition["name"]}
          </h2>
          <dl class="home-review-values">
            <div>
              <dt>Reps</dt>
              <dd id="home-edit-review-reps">{@state.pending_request.request.target_reps}</dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd>{duration_label(@state.pending_request.request.target_duration_sec)}</dd>
            </div>
          </dl>
          <.inspection
            rows={@state.review_inspection_rows}
            expanded={@state.expanded_groups}
          />
          <p
            :if={@state.pending_request.request.timed_rests != []}
            id="home-edit-review-pauses"
            class="home-local-message"
          >
            {pauses_label(@state.pending_request.request.timed_rests)}
          </p>
          <div class="home-review-actions">
            <button
              type="button"
              id="home-request-abort"
              class="home-text-action"
              aria-label="Cancel edit"
              phx-click="abort_new_workout"
            >
              Cancel
            </button>
            <button
              type="button"
              id="home-request-edit"
              class="home-text-action"
              aria-label="Change instruction"
              phx-click="edit_workout_request"
            >
              Edit
            </button>
            <button
              type="button"
              id="home-request-confirm"
              class="home-primary-action"
              aria-label="Approve and save variation"
              phx-click="confirm_workout_request"
            >
              Save
            </button>
          </div>
        </section>
      <% end %>
    <% end %>
    """
  end

  attr(:state, :map, required: true)

  def workspace(assigns) do
    ~H"""
    <section id="home-ready-recommendation" data-expanded={to_string(@state.expanded?)}>
      <div id="home-workout-area" aria-busy={to_string(@state.busy?)}>
        <%= if @state.busy? and @state.authoring_stage == :idle do %>
          <p class="home-eyebrow">Today’s workout</p>
          <div class="home-hero">
            <h1 class="home-workout-name">{@state.home_selection.plan.name}</h1>
            <span class="home-workout-totals">
              {duration_label(@state.home_selection.plan.target_duration_sec)} · {@state.home_selection.plan.target_reps} reps
            </span>
          </div>
          <div id="home-update-loading" role="status" aria-label="Updating workout">
            <img
              class="home-loading-animation"
              src="/images/burpee-loader-ink.gif"
              alt=""
              width="142"
              height="142"
            />
            <span class="sr-only">Updating workout</span>
          </div>
        <% else %>
          <h1 :if={authoring?(@state)} id="home-authoring-heading" class="screen-heading home-enter">
            {authoring_heading(@state.authoring_stage)}
          </h1>
          <p
            :if={authoring?(@state) and @state.editing_source}
            id="home-authoring-source"
            class="home-authoring-source home-enter"
          >
            {source_prefix(@state.authoring_stage)}{@state.editing_source.name} · {duration_label(
              @state.editing_source.target_duration_sec
            )} · {@state.editing_source.target_reps} reps
          </p>
          <%!-- Not rendered while authoring, so Cancel mounts it again and focus lands after the patch. --%>
          <div
            :if={not authoring?(@state)}
            id="home-workout-hero"
            class={@state.authoring_returned? && "home-enter"}
            phx-mounted={@state.authoring_returned? && JS.focus(to: "#home-summary")}
            phx-remove={JS.transition({"home-leave", "home-leave-from", "home-leave-to"}, time: 180)}
          >
            <p class="home-eyebrow">Today’s workout</p>
            <div class="home-hero">
              <div class="home-hero-main">
                <h1>
                  <button
                    id="home-summary"
                    type="button"
                    phx-click="toggle_summary"
                    class={["home-summary", @state.expanded? && "home-summary-expanded"]}
                    aria-expanded={to_string(@state.expanded?)}
                    aria-controls="home-expansion-content"
                  >
                    <span class="home-workout-name">{@state.home_selection.plan.name}</span>
                  </button>
                </h1>
              </div>
              <span class="home-workout-totals">
                {duration_label(@state.home_selection.plan.target_duration_sec)} · {@state.home_selection.plan.target_reps} reps
              </span>
            </div>
            <p
              :if={@state.home_selection.rationale}
              id="home-planner-rationale"
              class="home-coach-summary-text"
            >
              {@state.home_selection.rationale}
            </p>
            <div class="home-workout-actions" data-expanded={to_string(@state.expanded?)}>
              <button
                id="home-edit-workout"
                type="button"
                phx-click="edit_current_workout"
                aria-label="Edit current workout"
                title="Edit workout"
                class="home-icon-button home-expanded-action"
                inert={!@state.expanded?}
                disabled={@state.authoring_stage != :idle}
              >
                <.icon name="hero-pencil" class="size-6" />
                <span class="home-action-label">Edit</span>
              </button>
              <button
                id="home-title-action"
                type="button"
                phx-click={open_chooser()}
                aria-label="Switch workout"
                title="Switch workout"
                aria-haspopup="dialog"
                aria-expanded={to_string(@state.chooser_open?)}
                aria-controls="home-alternatives-panel"
                class="home-icon-button home-expanded-action"
                inert={!@state.expanded?}
                disabled={@state.authoring_stage != :idle}
              >
                <.icon name="hero-arrows-right-left" class="size-6" />
                <span class="home-action-label">Switch</span>
              </button>
              <button
                id="home-action"
                data-primary-action="start"
                type="button"
                phx-click="start_workout"
                phx-value-client_session_id={@state.start_client_session_id}
                aria-label="Start workout"
                title="Start workout"
                class="home-icon-button"
                disabled={@state.authoring_stage != :idle}
              >
                <.icon name="hero-play" class="size-6" />
              </button>
              <button
                id="home-new-workout"
                type="button"
                phx-click={JS.push("new_workout") |> JS.focus(to: "#home-new-reps")}
                aria-label="New workout"
                title="New workout"
                class="home-icon-button home-expanded-action"
                inert={!@state.expanded?}
                disabled={@state.authoring_stage != :idle}
              >
                <.icon name="hero-plus" class="size-6" />
                <span class="home-action-label">New</span>
              </button>
            </div>
          </div>
          <div id="home-expansion" class="home-expansion" data-open={to_string(@state.expanded?)}>
            <section
              id="home-expansion-content"
              class="home-expansion-content"
              inert={!@state.expanded?}
              aria-hidden={to_string(!@state.expanded?)}
            >
              <.inspection
                :if={@state.authoring_stage == :idle}
                rows={@state.inspection_rows}
                expanded={@state.expanded_groups}
              />
              <div id={"home-editor-#{@state.home_selection.home_revision}"}>
                <.request_confirmation
                  :if={@state.pending_request && @state.authoring_stage == :idle}
                  request={@state.pending_request.request}
                />
                <.authoring_form
                  :if={authoring_new?(@state)}
                  form={@state.workout_form}
                  stage={@state.authoring_stage}
                  candidate={@state.pending_request}
                  busy={@state.busy?}
                  review_inspection_rows={@state.review_inspection_rows}
                  expanded_groups={@state.expanded_groups}
                />
                <.current_edit
                  :if={
                    not is_nil(@state.editing_source) and
                      @state.authoring_stage in [:editing, :review]
                  }
                  state={@state}
                />
                <section
                  :if={@state.authoring_stage == :saved}
                  id="home-new-saved"
                  class="home-review"
                >
                  <h2 class="home-review-heading">{@state.created_plan.name}</h2>
                  <p class="home-local-message">Saved. Your current workout is unchanged.</p>
                  <div class="home-review-actions">
                    <button
                      id="home-new-dismiss"
                      phx-click="abort_new_workout"
                      class="home-icon-button"
                      aria-label="Return to current workout"
                    >
                      <.icon name="hero-x-mark" class="size-5" />
                    </button>
                    <button
                      id="home-new-select"
                      phx-click="select_created_workout"
                      class="home-icon-button"
                      aria-label="Select new workout"
                    >
                      <.icon name="hero-check" class="size-5" />
                    </button>
                  </div>
                </section>
                <p id="home-adjustment-error" role="status" class="home-local-message">
                  {@state.local_error}
                </p>
              </div>
            </section>
          </div>
          <.chooser state={@state} />
        <% end %>
      </div>
    </section>
    """
  end

  attr(:state, :map, required: true)

  def chooser(assigns) do
    ~H"""
    <div :if={@state.chooser_open?} id="home-chooser-backdrop" phx-click={close_chooser()}></div>
    <div
      id="home-alternatives-panel"
      hidden={!@state.chooser_open?}
      role="dialog"
      aria-modal="true"
      aria-label="Choose a workout"
      phx-window-keydown={close_chooser()}
      phx-key="Escape"
    >
      <.focus_wrap
        id="home-chooser-focus"
        phx-mounted={@state.chooser_open? && JS.focus(to: "#home-chooser-close")}
      >
        <header class="home-chooser-header">
          <h2>Choose a workout</h2>
          <button
            id="home-chooser-close"
            type="button"
            aria-label="Close chooser"
            phx-click={close_chooser()}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>
        <p
          :if={
            @state.home_state == :choose and is_nil(@state.home_selection) and
              Phoenix.Flash.get(@state.flash, :error)
          }
          id="home-chooser-error"
          role="alert"
          tabindex="-1"
          class="home-local-message focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          {Phoenix.Flash.get(@state.flash, :error)}
        </p>
        <div id="home-alternatives-toolbar">
          <div role="tablist" aria-label="Other workouts">
            <button
              :for={tab <- [:workouts, :videos]}
              id={"home-tab-#{tab}"}
              role="tab"
              type="button"
              phx-click="tab"
              phx-value-tab={tab}
              aria-selected={to_string(@state.active_tab == tab)}
            >
              {if tab == :workouts, do: "Workouts", else: "Videos"}
            </button>
          </div>
          <button
            id="home-filter-toggle"
            aria-label="Filter"
            title="Filter"
            type="button"
            phx-click="toggle_filters"
            aria-expanded={to_string(@state.filters_open?)}
            aria-controls="home-filters"
          >
            <span aria-hidden="true">
              <.icon name="hero-adjustments-horizontal" class="size-5" />
            </span>
          </button>
        </div>
        <div :if={@state.filters_open?} id="home-filters">
          <div role="group" aria-label="Workout type">
            <button
              :for={type <- [:six_count, :navy_seal]}
              id={"home-type-#{type}"}
              type="button"
              phx-click="filter"
              phx-value-kind="type"
              phx-value-filter={type}
              aria-pressed={to_string(MapSet.member?(@state.filters.types, type))}
            >
              {CreationParameters.type_label(Atom.to_string(type))}
            </button>
          </div>
          <div class="home-filter-level-heading">
            <span>Levels</span>
            <button id="home-filter-reset" type="button" phx-click="reset_filters">
              Reset
            </button>
          </div>
          <div role="group" aria-label="Catalog level" aria-describedby="home-current-level">
            <button
              :for={level <- Enum.reverse(BurpeeTrainer.Levels.all_levels())}
              id={"home-level-#{level}"}
              type="button"
              phx-click="filter"
              phx-value-kind="level"
              phx-value-filter={level}
              aria-pressed={to_string(MapSet.member?(@state.filters.levels, level))}
            >
              {level_label(level)}
            </button>
          </div>
          <p id="home-current-level">
            {BurpeeTrainerWeb.Fmt.level(@state.current_level)} is your current level.
          </p>
        </div>
        <p
          :if={@state.alternatives_empty?}
          id="home-alternatives-empty"
          class="home-local-message"
        >
          No matching {if(@state.active_tab == :videos, do: "videos", else: "workouts")}. Try changing the filters.
        </p>
        <div id="home-alternatives" phx-update="stream">
          <.alternative
            :for={{id, item} <- @state.streams.alternatives}
            id={id}
            item={item}
            current?={
              not is_nil(@state.home_selection) and item.kind == :plan and
                item.source_id == @state.home_selection.plan.id
            }
          />
        </div>
      </.focus_wrap>
    </div>
    """
  end

  attr(:state, :map, required: true)

  def choose(assigns) do
    ~H"""
    <section id="home-ready-recommendation" class="home-result" data-expanded="true">
      <h1 class="home-state-heading">Your workout is being prepared</h1>
      <p :if={@state.local_error} id="home-initialization-error" role="status">
        {@state.local_error}
      </p>
      <a
        :if={@state.local_error}
        id="home-fallback-reload"
        href={~p"/"}
        class="mt-4 inline-flex min-h-11 items-center underline focus-visible:outline-2"
      >
        Reload Home
      </a>
      <div class="home-workout-actions" data-expanded="true">
        <button
          id="home-title-action"
          type="button"
          phx-click={open_chooser()}
          data-primary-action="choose"
          aria-label="Switch workout"
          title="Switch workout"
          aria-haspopup="dialog"
          aria-expanded={to_string(@state.chooser_open?)}
          aria-controls="home-alternatives-panel"
          class="home-icon-button home-expanded-action"
        >
          <.icon name="hero-arrows-right-left" class="size-6" />
          <span class="home-action-label">Switch</span>
        </button>
      </div>
      <.chooser state={@state} />
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:item, :map, required: true)
  attr(:current?, :boolean, default: false)

  def alternative(assigns) do
    ~H"""
    <div id={@id} class="home-alternative-row">
      <button
        id={"#{@id}-select"}
        type="button"
        phx-click={
          JS.set_attribute({"hidden", ""}, to: "#home-alternatives-panel")
          |> JS.remove_attribute("inert",
            to: "#home-summary, .home-workout-actions, #home-expansion-content"
          )
          |> JS.push("select_alternative")
        }
        phx-value-id={@item.source_id}
        phx-value-kind={@item.kind}
        aria-current={@current? && "true"}
        class="home-alternative"
      >
        <span class="home-alternative-name">{@item.name}</span>
        <span class="home-alternative-metadata">
          {duration_label(@item.duration_sec)} · {if is_nil(@item.reps),
            do: "Reps unknown",
            else: "#{@item.reps} reps"}
        </span>
      </button>
      <button
        :if={Map.get(@item, :owned?, false)}
        id={"home-delete-workout-#{@item.source_id}"}
        type="button"
        class="home-icon-button"
        aria-label={"Delete workout #{@item.name}"}
        data-confirm="Delete this workout? Past sessions will be kept."
        phx-click="delete_workout"
        phx-value-id={@item.source_id}
      >
        <.icon name="hero-trash" class="size-5" />
      </button>
    </div>
    """
  end

  attr(:slot, :map, required: true)

  def week_progress(assigns) do
    ~H"""
    <div id="home-week-progress">
      <div class="home-progress-labels">
        <span id="home-week-duration">
          {div(@slot.completed_sec, 60)} / {div(@slot.weekly_target_sec, 60)} min
        </span>
        <span id="home-week-dates">{BurpeeTrainerWeb.Fmt.week(@slot.week_start)}</span>
      </div>
      <div
        id="home-week-track"
        role="progressbar"
        aria-label="Weekly training progress"
        aria-valuemin="0"
        aria-valuemax={@slot.weekly_target_sec}
        aria-valuenow={min(@slot.completed_sec, @slot.weekly_target_sec)}
        aria-valuetext={"#{@slot.completed_sec} of #{@slot.weekly_target_sec} seconds completed"}
      >
        <span id="home-week-fill" style={"width: #{progress_percent(@slot)}%"}></span>
      </div>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:expanded, :any, required: true)

  def inspection(assigns) do
    assigns = assign(assigns, :show_move?, show_move?(assigns.rows))

    ~H"""
    <div
      id="home-inspection"
      data-move={to_string(@show_move?)}
      role="region"
      tabindex="0"
      aria-label="Workout structure. Scroll horizontally if needed to read exact timings."
    >
      <table>
        <caption class="sr-only">
          Exact workout structure. Every is the seconds from the start of one rep to the next.
          Move, shown only when it differs, is the active seconds per burpee.
          Rest is the total pause after the last burpee finishes until the next set starts,
          including the final gap and any explicit recovery; a dash means no recovery.
          Repeats preserve the ordered sets, not authoring blocks.
        </caption>
        <thead>
          <tr>
            <th scope="col">Sets</th>
            <th scope="col">Reps</th>
            <th scope="col">Every</th>
            <th :if={@show_move?} scope="col">Move</th>
            <th scope="col">Rest</th>
          </tr>
        </thead>
        <%= for row <- @rows do %>
          <% expanded? = row.count > 1 and MapSet.member?(@expanded, row.id) %>
          <% visible_units = if expanded?, do: Enum.take(row.units, 1), else: shared_units(row) %>
          <tbody id={row.id} data-expanded={row.count > 1 && to_string(expanded?)}>
            <%!-- The existing utility bounds the hit target even when a reconnect retains older CSS. --%>
            <tr
              id={"#{row.id}-event-#{hd(hd(row.units).paired).index}"}
              class={row.count > 1 && "home-group-row relative"}
            >
              <th scope="row">
                <button
                  :if={row.count > 1}
                  id={"#{row.id}-toggle"}
                  type="button"
                  class="home-group-toggle"
                  phx-click="toggle_group"
                  phx-value-id={row.id}
                  aria-expanded={to_string(expanded?)}
                  aria-controls={"#{row.id}-details"}
                  aria-describedby={"#{row.id}-prescription"}
                >
                  <%= if expanded? do %>
                    Set {set_number(@rows, hd(row.units))}
                  <% else %>
                    {row.count} {if length(row.units) == row.count, do: "sets", else: "repeats"}
                  <% end %>
                  <.icon name="hero-chevron-down" class="home-chevron" />
                </button>
                <span :if={row.count > 1} id={"#{row.id}-prescription"} class="sr-only">
                  {Enum.map_join(visible_units, "; ", &prescription_label/1)}
                </span>
                <span :if={row.count == 1}>{row_label(row)}</span>
              </th>
              <.prescription units={visible_units} show_move?={@show_move?} />
            </tr>
          </tbody>
          <tbody
            :if={row.count > 1}
            id={"#{row.id}-details"}
            class="home-group-rows"
            hidden={!expanded?}
          >
            <tr :for={unit <- Enum.drop(row.units, 1)} id={"#{row.id}-event-#{hd(unit.paired).index}"}>
              <th scope="row">Set {set_number(@rows, unit)}</th>
              <.prescription units={[unit]} show_move?={@show_move?} />
            </tr>
          </tbody>
        <% end %>
      </table>
    </div>
    """
  end

  attr(:units, :list, required: true)
  attr(:show_move?, :boolean, required: true)

  defp prescription(assigns) do
    ~H"""
    <td class="home-prescription-reps">
      <span :for={unit <- @units}>{work_value(unit, "reps")}</span>
    </td>
    <td class="home-prescription-every">
      <span :for={unit <- @units}>{cadence(unit)}</span>
    </td>
    <td :if={@show_move?} class="home-prescription-move">
      <span :for={unit <- @units}>{pace(unit)}</span>
    </td>
    <td class="home-prescription-rest">
      <span :for={unit <- @units}>{recovery(unit)}</span>
    </td>
    """
  end

  defp shared_units(row), do: Enum.take(row.units, div(length(row.units), row.count))

  defp prescription_label(unit),
    do:
      "#{work_value(unit, "reps")} reps · one every #{cadence(unit)} · #{pace(unit)} move · " <>
        recovery_label(unit)

  defp recovery_label(unit),
    do: if(recovery(unit) == "—", do: "No recovery", else: "#{recovery(unit)} rest")

  defp work(unit),
    do: Enum.find_value(unit.paired, &if(&1.program["kind"] == "work", do: &1.program))

  defp work_value(unit, key), do: if(work(unit), do: work(unit)[key], else: "—")

  defp cadence(unit),
    do: if(work(unit), do: scaled(work(unit)["sec_per_rep_us"], 1_000_000) <> "s", else: "—")

  defp recovery(unit) do
    explicit_ms =
      unit.paired
      |> Enum.filter(&(&1.program["kind"] == "rest"))
      |> Enum.reduce(0, &(&1.program["duration_ms"] + &2))

    tail_us =
      if event = work(unit) do
        active_end_us = (event["reps"] - 1) * event["sec_per_rep_us"] + event["sec_per_burpee_us"]
        # Compiler work timing is microsecond-exact; its float duration can contain
        # binary arithmetic noise. Recover that precision before subtracting.
        round(event["duration_sec"] * 1_000_000) - active_end_us
      else
        0
      end

    total_us = tail_us + explicit_ms * 1_000
    if total_us == 0, do: "—", else: scaled(total_us, 1_000_000) <> "s"
  end

  defp pace(unit),
    do: if(work(unit), do: scaled(work(unit)["sec_per_burpee_us"], 1_000_000) <> "s", else: "—")

  # Move is only news when a rep's movement is shorter than the gap to the next one.
  defp show_move?(rows) do
    Enum.any?(rows, fn row ->
      Enum.any?(row.events, fn event ->
        event["kind"] == "work" and event["sec_per_rep_us"] != event["sec_per_burpee_us"]
      end)
    end)
  end

  defp row_label(%{trailing?: true}), do: "Final recovery"
  defp row_label(%{kind: :recovery}), do: "Recovery"
  defp row_label(_), do: "1 set"

  defp set_number(rows, unit) do
    rows
    |> Enum.flat_map(& &1.units)
    |> Enum.filter(&work/1)
    |> Enum.find_index(&(hd(&1.paired).index == hd(unit.paired).index))
    |> Kernel.+(1)
  end

  # Normal decimal output avoids exponent notation without rounding canonical timing.
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value),
    do: value |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp scaled(value, divisor),
    do:
      value
      |> Decimal.new()
      |> Decimal.div(divisor)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

  defp duration_label(nil), do: "Duration unknown"
  defp duration_label(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp duration_label(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} s"
  defp progress_percent(%{weekly_target_sec: 0}), do: "0"

  defp progress_percent(slot),
    do: number(min(100, max(0, slot.completed_sec * 100 / slot.weekly_target_sec)))

  # Filter chips use the short form: "1A", "Graduated".
  # New and Edit (and their review) replace today's workout on screen under one heading.
  defp authoring?(state), do: state.authoring_stage in [:new, :review, :editing]

  defp authoring_new?(state),
    do: is_nil(state.editing_source) and state.authoring_stage in [:new, :review, :editing]

  defp source_prefix(:review), do: "From "
  defp source_prefix(_stage), do: ""

  defp pauses_label([_one] = rests), do: "Pause: " <> pause_times(rests)
  defp pauses_label(rests), do: "Pauses: " <> pause_times(rests)

  defp pause_times(rests),
    do:
      Enum.map_join(rests, " · ", &"#{&1.duration_sec}s at #{elapsed_clock(round(&1.start_sec))}")

  defp authoring_heading(:review), do: "Review"
  defp authoring_heading(:editing), do: "Edit workout"
  defp authoring_heading(:new), do: "New workout"

  defp level_label(level),
    do: level |> BurpeeTrainerWeb.Fmt.level() |> String.replace_prefix("Level ", "")
end
