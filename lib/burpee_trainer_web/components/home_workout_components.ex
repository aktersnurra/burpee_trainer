defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html
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
    |> JS.focus(to: "#home-summary")
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
            {if(@request.burpee_type == "six_count", do: "Six-count", else: "Navy SEAL")}
          </dd>
        </div>
        <div class="rounded-lg bg-stone-100 p-3">
          <dt class="text-stone-500">Sets</dt>
          <dd id="home-request-style" class="mt-1 font-semibold text-stone-900">
            {if(@request.pacing_style == "unbroken", do: "Unbroken within sets", else: "Even")}
          </dd>
        </div>
      </dl>
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
      <div class="home-review-actions home-review-actions-split">
        <button
          :if={@editable}
          id="home-request-abort"
          type="button"
          phx-click={JS.push("abort_new_workout") |> JS.focus(to: "#home-summary")}
          class="home-text-action home-icon-action"
          aria-label="Cancel"
          title="Cancel"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div class="home-review-actions-group">
          <button
            :if={@editable}
            id="home-request-edit"
            type="button"
            phx-click={JS.push("edit_workout_request") |> JS.focus(to: "#home-review-reps")}
            class="home-text-action home-icon-action"
            aria-label="Edit"
            title="Edit"
          >
            <.icon name="hero-pencil-square" class="size-5" />
          </button>
          <button
            :if={!@editable}
            id="home-request-back"
            type="button"
            phx-click="back_to_workout_request"
            class="home-text-action home-icon-action"
            aria-label="Edit"
            title="Edit"
          >
            <.icon name="hero-pencil-square" class="size-5" />
          </button>
          <button
            id="home-request-confirm"
            type="button"
            phx-click="confirm_workout_request"
            class="home-primary-action home-icon-action"
            aria-label="Approve"
            title="Approve"
          >
            <.icon name="hero-check" class="size-5" />
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp elapsed_clock(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  attr(:prefix, :string, default: "home-request")
  attr(:busy, :boolean, default: false)
  attr(:authoring, :boolean, default: true)
  attr(:confirm, :string, default: "confirm_workout_request")
  attr(:cancel, :string, default: "abort_new_workout")
  attr(:confirm_label, :string, default: "Use workout")

  def review_actions(assigns) do
    ~H"""
    <div class="home-review-actions home-review-actions-split">
      <button
        id={@prefix <> "-abort"}
        type="button"
        phx-click={@cancel}
        class="home-text-action home-icon-action"
        aria-label="Cancel review"
        title="Cancel"
        disabled={@busy}
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
      <div class="home-review-actions-group">
        <button
          :if={@authoring}
          id={@prefix <> "-edit"}
          type="button"
          phx-click="edit_workout_request"
          class="home-text-action home-icon-action"
          aria-label="Edit workout"
          title="Edit"
          disabled={@busy}
        >
          <.icon name="hero-pencil-square" class="size-5" />
        </button>
        <button
          :if={@authoring}
          id={@prefix <> "-save"}
          type="button"
          phx-click="save_review_to_library"
          class="home-text-action home-icon-action"
          aria-label="Save to library"
          title="Save to library"
          disabled={@busy}
        >
          <.icon name="hero-bookmark" class="size-5" />
        </button>
        <button
          id={@prefix <> "-confirm"}
          type="button"
          phx-click={@confirm}
          class="home-primary-action home-icon-action"
          aria-label={@confirm_label}
          title={@confirm_label}
          disabled={@busy}
        >
          <.icon name="hero-check" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @start_choices %{
    "camera" => {"Camera tracking", "hero-video-camera"},
    "warmup" => {"Warmup", "hero-fire"}
  }

  attr(:choice, :string, required: true, values: Map.keys(@start_choices))

  # A start toggle beside play or Resume. The device remembers it; the server renders it
  # once and leaves it.
  def start_choice(assigns) do
    {label, icon} = Map.fetch!(@start_choices, assigns.choice)
    assigns = assign(assigns, label: label, icon: icon)

    ~H"""
    <button
      id={"home-start-#{@choice}"}
      type="button"
      phx-hook="HomeStartChoice"
      phx-update="ignore"
      data-start-choice={@choice}
      aria-pressed="false"
      aria-label={@label}
      title={@label}
      class="home-text-action home-start-choice"
    >
      <.icon name={@icon} class="size-5" />
    </button>
    """
  end

  attr(:state, :map, required: true)

  # Today's workout. Swipe right to swap it; swipe up to edit it or make a new one (the
  # buttons do the same). Edit and New take Home's place as a chat: `HomeStudioComponents`.
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
            <.burpee_loader />
            <span class="sr-only">Updating workout</span>
          </div>
        <% else %>
          <div
            id="home-workout-hero"
            class={@state.authoring_returned? && "home-enter"}
            phx-mounted={@state.authoring_returned? && JS.focus(to: "#home-summary")}
          >
            <p class="home-eyebrow">Today’s workout</p>
            <div class="home-hero">
              <div class="home-hero-main">
                <h1>
                  <button
                    id="home-summary"
                    type="button"
                    phx-click="toggle_summary"
                    inert={@state.authoring_stage != :idle}
                    class={["home-summary", @state.expanded? && "home-summary-expanded"]}
                    aria-expanded={to_string(@state.expanded?)}
                    aria-controls="home-expansion-content"
                  >
                    <span class="home-workout-name">
                      <.changed
                        value={hero_name(@state)}
                        was={
                          if swap_review?(@state),
                            do: hero_name(@state),
                            else: @state.home_selection.plan.name
                        }
                      />
                    </span>
                  </button>
                </h1>
              </div>
              <span :if={swap_video?(@state)} class="home-workout-totals">
                {duration_label(@state.swap_preview.source.duration_sec)} · Video
              </span>
              <span :if={!swap_video?(@state)} class="home-workout-totals">
                <.changed
                  value={duration_label(hero_totals(@state).target_duration_sec)}
                  was={duration_label(hero_was(@state).target_duration_sec)}
                /> ·
                <.changed
                  value={"#{hero_totals(@state).target_reps}"}
                  was={"#{hero_was(@state).target_reps}"}
                /> reps
              </span>
            </div>
            <p
              :if={@state.authoring_stage == :idle and shape(@state.home_selection.plan)}
              id="home-shape"
              class="home-shape"
            >
              {shape(@state.home_selection.plan)}<span
                :if={best(@state)}
                id="home-best"
                class="home-best"
              > · best {best(@state)} in 20 min</span>
            </p>
            <p
              :if={@state.home_selection.rationale && @state.authoring_stage == :idle}
              id="home-planner-rationale"
              class="home-coach-summary-text"
            >
              {@state.home_selection.rationale}
            </p>
            <div
              :if={@state.authoring_stage == :idle}
              class="home-workout-actions"
              data-expanded="true"
            >
              <.start_choice choice="camera" />
              <.start_choice choice="warmup" />
              <button
                id="home-action"
                data-primary-action="start"
                type="button"
                phx-click="start_workout"
                phx-value-client_session_id={@state.start_client_session_id}
                aria-label="Start workout"
                title="Start workout"
                class="home-primary-action home-play-action"
                disabled={@state.authoring_stage != :idle}
              >
                <.icon name="hero-play-solid" class="size-6" />
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
                <section
                  :if={@state.authoring_stage == :choosing}
                  id="home-swap-review"
                  class="home-review"
                  aria-label="Review workout"
                  phx-mounted={JS.focus(to: "#home-swap-confirm")}
                >
                  <.inspection
                    :if={@state.swap_preview.kind == "plan"}
                    rows={@state.review_inspection_rows}
                    expanded={@state.expanded_groups}
                  />
                  <.review_actions
                    prefix="home-swap"
                    authoring={false}
                    confirm="use_alternative"
                    confirm_label={
                      if @state.swap_preview.kind == "video", do: "Start video", else: "Use workout"
                    }
                  />
                </section>
                <.request_confirmation
                  :if={@state.pending_request && @state.authoring_stage == :idle}
                  request={@state.pending_request.request}
                />
                <p id="home-adjustment-error" role="status" class="home-local-message">
                  {@state.local_error}
                </p>
              </div>
            </section>
          </div>
          <%!-- Edit and New wait until the workout is opened: a swipe up, or this handle. Swap is
               the swipe right, the left drawer. --%>
          <div
            :if={
              @state.authoring_stage == :idle and @state.expanded? and not @state.options_open? and
                not @state.chooser_open?
            }
            class="home-grab-area"
          >
            <button
              id="home-grab"
              type="button"
              class="home-grab"
              phx-click="open_options"
              aria-label="Edit, swap or new workout"
              title="Edit, swap or new workout"
            >
              <span class="home-grab-bar"></span>
            </button>
          </div>
          <.options_sheet :if={@state.options_open?} state={@state} />
          <.chooser state={@state} />
        <% end %>
      </div>
    </section>
    """
  end

  attr(:state, :map, required: true)

  # Swiped up from the workout: what to do with it, in two choices.
  defp options_sheet(assigns) do
    ~H"""
    <div id="home-options-backdrop" phx-click="close_options"></div>
    <div
      id="home-options-sheet"
      role="dialog"
      aria-modal="true"
      aria-label="Edit, swap or make a new workout"
      phx-window-keydown="close_options"
      phx-key="Escape"
      phx-mounted={JS.focus()}
      tabindex="-1"
      data-no-swipe
    >
      <span class="home-sheet-grip" aria-hidden="true"></span>
      <button
        id="home-options-edit"
        type="button"
        class="home-option"
        phx-click="edit_current_workout"
      >
        <.icon name="hero-pencil-square" class="size-6" />
        <span class="home-option-title">Edit this workout</span>
      </button>
      <button id="home-options-swap" type="button" class="home-option" phx-click="open_chooser">
        <.icon name="hero-arrows-right-left" class="size-6" />
        <span class="home-option-title">Swap workout</span>
      </button>
      <button id="home-options-new" type="button" class="home-option" phx-click="new_workout">
        <.icon name="hero-plus" class="size-6" />
        <span class="home-option-title">New workout</span>
      </button>
    </div>
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
          <button
            id="home-chooser-close"
            type="button"
            class="home-text-action home-icon-action"
            phx-click={close_chooser()}
            aria-label="Close"
            title="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
          <h2>Choose a workout</h2>
        </header>
        <p
          :if={Phoenix.Flash.get(@state.flash, :error)}
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
            class="home-text-action home-icon-action"
            type="button"
            phx-click="toggle_filters"
            aria-expanded={to_string(@state.filters_open?)}
            aria-controls="home-filters"
            aria-label="Filter"
            title="Filter"
          >
            <.icon name="hero-adjustments-horizontal" class="size-5" />
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
            <button
              id="home-filter-reset"
              type="button"
              phx-click="reset_filters"
              class="home-icon-action"
              aria-label="Reset filters"
              title="Reset filters"
            >
              <.icon name="hero-arrow-path" class="size-5" />
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
          <p id="home-current-level" class="sr-only">
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
          class="home-primary-action home-icon-action"
        >
          <.icon name="hero-arrows-right-left" class="size-5" />
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
          |> JS.push("preview_alternative")
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
        class="home-text-action home-icon-action"
        aria-label={"Delete #{@item.name}"}
        data-confirm="Delete this workout? Past sessions will be kept."
        phx-click="delete_workout"
        phx-value-id={@item.source_id}
        title="Delete workout"
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

  attr(:compare, :list,
    default: nil,
    doc: "rows of the current workout; changed cells are marked"
  )

  attr(:editable, :boolean,
    default: false,
    doc: "a tap on a set's row selects it for a hand edit (`select_proposal_row`)"
  )

  attr(:selected, :list, default: [], doc: "the set numbers selected for a hand edit")

  def inspection(assigns) do
    show_move? = show_move?(assigns.rows)

    changes =
      case assigns.compare do
        nil ->
          %{}

        compare ->
          was = Enum.map(compare, &row_signature(&1, show_move?))

          assigns.rows
          |> Enum.with_index()
          |> Map.new(fn {row, index} ->
            {row.id, changed_cells(row_signature(row, show_move?), Enum.at(was, index))}
          end)
      end

    assigns = assign(assigns, show_move?: show_move?, changes: changes)

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
            <th scope="col">Set</th>
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
            <%!-- A tap anywhere on a group row toggles it; the button keeps keyboard and screen-reader operation. --%>
            <tr
              id={"#{row.id}-event-#{hd(hd(row.units).paired).index}"}
              class={[
                row.count > 1 && "home-group-row",
                (@editable and row.kind != :recovery) && "home-editable-row",
                selected?(@rows, row, @selected) && "home-selected-row"
              ]}
              phx-click={
                cond do
                  @editable and row.kind != :recovery -> "select_proposal_row"
                  row.count > 1 -> "toggle_group"
                  true -> nil
                end
              }
              phx-value-index={(@editable and row.kind != :recovery) && first_index(row)}
              phx-value-id={(not @editable and row.count > 1) && row.id}
              aria-selected={
                (@editable and row.kind != :recovery) && to_string(selected?(@rows, row, @selected))
              }
            >
              <th scope="row" class={changed?(@changes, row.id, :label) && "home-changed"}>
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
                    {set_number(@rows, hd(row.units))}
                  <% else %>
                    {set_range(@rows, row)}
                  <% end %>
                  <.icon name="hero-chevron-down" class="home-chevron" />
                </button>
                <span :if={row.count > 1} id={"#{row.id}-prescription"} class="sr-only">
                  {Enum.map_join(visible_units, "; ", &prescription_label/1)}
                </span>
                <span :if={row.count == 1}>{row_label(@rows, row)}</span>
              </th>
              <.prescription
                units={visible_units}
                show_move?={@show_move?}
                changed={Map.get(@changes, row.id, MapSet.new())}
              />
            </tr>
          </tbody>
          <tbody
            :if={row.count > 1}
            id={"#{row.id}-details"}
            class="home-group-rows"
            hidden={!expanded?}
          >
            <tr :for={unit <- Enum.drop(row.units, 1)} id={"#{row.id}-event-#{hd(unit.paired).index}"}>
              <th scope="row">{set_number(@rows, unit)}</th>
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
  attr(:changed, :any, default: MapSet.new())

  defp prescription(assigns) do
    ~H"""
    <td class={["home-prescription-reps", MapSet.member?(@changed, :reps) && "home-changed"]}>
      <span :for={unit <- @units}>{work_value(unit, "reps")}</span>
    </td>
    <td class={["home-prescription-every", MapSet.member?(@changed, :every) && "home-changed"]}>
      <span :for={unit <- @units}>{cadence(unit)}</span>
    </td>
    <td
      :if={@show_move?}
      class={["home-prescription-move", MapSet.member?(@changed, :move) && "home-changed"]}
    >
      <span :for={unit <- @units}>{pace(unit)}</span>
    </td>
    <td class={["home-prescription-rest", MapSet.member?(@changed, :rest) && "home-changed"]}>
      <span :for={unit <- @units}>{recovery(unit)}</span>
    </td>
    """
  end

  # What a row shows when collapsed, cell by cell, so Review can mark what Edit changed.
  defp row_signature(row, show_move?) do
    units = shared_units(row)

    %{
      label: if(row.count > 1, do: "#{row.count}", else: "#{row.kind}"),
      reps: Enum.map(units, &work_value(&1, "reps")),
      every: Enum.map(units, &cadence/1),
      move: if(show_move?, do: Enum.map(units, &pace/1), else: []),
      rest: Enum.map(units, &recovery/1)
    }
  end

  defp changed_cells(_now, nil), do: MapSet.new([:label, :reps, :every, :move, :rest])

  defp changed_cells(now, was),
    do: now |> Map.keys() |> Enum.reject(&(now[&1] == was[&1])) |> MapSet.new()

  defp changed?(changes, row_id, cell),
    do: changes |> Map.get(row_id, MapSet.new()) |> MapSet.member?(cell)

  attr(:value, :string, required: true)
  attr(:was, :string, required: true)

  # A value Review changed reads marked; an unchanged one reads plain.
  defp changed(assigns) do
    ~H"""
    <mark :if={@value != @was} class="home-changed">{@value}</mark><span :if={@value == @was}>{@value}</span>
    """
  end

  defp shape(plan), do: BurpeeTrainer.Workouts.Shape.describe(plan.definition_json)

  # The athlete's best for this burpee type, per 20 minutes, to read today's reps against.
  defp best(state),
    do: state |> Map.get(:home_bests, %{}) |> Map.get(state.home_selection.plan.burpee_type)

  defp hero_name(state) do
    cond do
      swap_review?(state) -> state.swap_preview.source.name
      true -> state.home_selection.plan.name
    end
  end

  defp hero_totals(state) do
    cond do
      swap_review?(state) and state.swap_preview.kind == "plan" -> state.swap_preview.source
      true -> state.home_selection.plan
    end
  end

  # What the hero is marked against. A swap is another workout, so it reads plain.
  defp hero_was(state),
    do: if(swap_review?(state), do: hero_totals(state), else: state.home_selection.plan)

  defp swap_review?(state),
    do: state.authoring_stage == :choosing and not is_nil(state.swap_preview)

  defp swap_video?(state), do: swap_review?(state) and state.swap_preview.kind == "video"

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
    # Whole seconds: timing is planned to ±10s, so decimals here are noise.
    if total_us == 0,
      do: "—",
      else: BurpeeTrainer.Workouts.Shape.clock(round(total_us / 1_000_000))
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

  defp row_label(_rows, %{trailing?: true}), do: "Final recovery"
  defp row_label(_rows, %{kind: :recovery}), do: "Recovery"
  defp row_label(rows, row), do: set_range(rows, row)

  defp first_index(row), do: hd(hd(row.units).paired).index

  @doc "A row's sets by number, as the table labels them: `5`, or `1–4` for a group."
  def set_range(rows, row) do
    case set_numbers(rows, row) do
      [] -> ""
      [one] -> "#{one}"
      numbers -> "#{Enum.min(numbers)}–#{Enum.max(numbers)}"
    end
  end

  @doc "The numbers of a row's sets, 1 for the workout's first."
  def set_numbers(rows, row),
    do: row.units |> Enum.filter(&work/1) |> Enum.map(&set_number(rows, &1))

  defp selected?(_rows, _row, selected) when selected in [nil, []], do: false
  defp selected?(rows, row, selected), do: Enum.any?(set_numbers(rows, row), &(&1 in selected))

  @doc "The row whose first event is at `index`, if any."
  def row_at(rows, index), do: Enum.find(rows, &(first_index(&1) == index))

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
  defp level_label(level),
    do: level |> BurpeeTrainerWeb.Fmt.level() |> String.replace_prefix("Level ", "")
end
