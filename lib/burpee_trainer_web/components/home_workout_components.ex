defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html

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

  # Today's workout. Swipe right to swap it (the drawer's button does the same); Edit and New are
  # a button each, and take Home's place as a chat: `HomeStudioComponents`.
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
                    <span class="home-workout-name">{@state.home_selection.plan.name}</span>
                  </button>
                </h1>
              </div>
              <span class="home-workout-totals">
                {duration_label(@state.home_selection.plan.target_duration_sec)} · {@state.home_selection.plan.target_reps} reps
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
              <.corner :if={@state.authoring_stage == :idle and not @state.chooser_open?} />
              <div id={"home-editor-#{@state.home_selection.home_revision}"}>
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

  # The drawer, Edit and New, one tap each, under the workout's sets once it is opened: the
  # collapsed Home is the workout and Play alone.
  defp corner(assigns) do
    ~H"""
    <nav class="home-corner" aria-label="Workout">
      <button
        id="home-corner-swap"
        type="button"
        class="home-corner-action"
        phx-click={open_chooser()}
        aria-label="Choose a workout"
        title="Choose a workout"
        aria-haspopup="dialog"
        aria-controls="home-alternatives-panel"
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
      <button
        id="home-corner-edit"
        type="button"
        data-vt="rise"
        class="home-corner-action"
        phx-click="edit_current_workout"
        aria-label="Edit this workout"
        title="Edit this workout"
      >
        <.icon name="hero-pencil-square" class="size-5" />
      </button>
      <button
        id="home-corner-new"
        type="button"
        data-vt="rise"
        class="home-corner-action"
        phx-click="new_workout"
        aria-label="New workout"
        title="New workout"
      >
        <.icon name="hero-plus" class="size-5" />
      </button>
    </nav>
    """
  end

  attr(:state, :map, required: true)

  def chooser(assigns) do
    ~H"""
    <div
      id="home-alternatives-panel"
      hidden={!@state.chooser_open?}
      phx-hook="SheetDrag"
      data-close="#home-chooser-close"
      role="dialog"
      aria-modal="true"
      aria-label="Choose a workout"
      phx-window-keydown={@state.chooser_open? && close_chooser()}
      phx-key={@state.chooser_open? && "Escape"}
    >
      <.focus_wrap id="home-chooser-focus">
        <%!-- On a phone the list is a sheet: its grip says it drags down to close. --%>
        <div class="home-sheet-grip" aria-hidden="true"></div>
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
        </div>
        <p
          :if={@state.alternatives_empty?}
          id="home-alternatives-empty"
          class="home-local-message"
        >
          No {if(@state.active_tab == :videos, do: "videos", else: "workouts")} yet.
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
    <%!-- The backdrop mounts with each opening, however it was opened (a button or a swipe), and
         takes focus into the drawer. It follows the drawer, so its coming and going never moves
         the drawer in the page, which would cut the drawer's slide short. Escape listens only
         while the drawer is open. --%>
    <div
      :if={@state.chooser_open?}
      id="home-chooser-backdrop"
      phx-click={close_chooser()}
      phx-mounted={JS.focus(to: "#home-chooser-close")}
    >
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
          |> JS.push("select_alternative")
        }
        data-vt={@item.kind == "plan" && "attach"}
        data-vt-from={@item.kind == "plan" && ".home-alternative-name"}
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
              class={row.count > 1 && "home-group-row"}
              phx-click={row.count > 1 && "toggle_group"}
              phx-value-id={row.count > 1 && row.id}
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

  defp shape(plan), do: BurpeeTrainer.Workouts.Shape.describe(plan.definition_json)

  # The athlete's best for this burpee type, per 20 minutes, to read today's reps against.
  defp best(state),
    do: state |> Map.get(:home_bests, %{}) |> Map.get(state.home_selection.plan.burpee_type)

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

  @doc "A planned length as Home says it: `20 min`, or `2 min 30 s`."
  def duration_label(nil), do: "Duration unknown"
  def duration_label(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  def duration_label(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} s"
  defp progress_percent(%{weekly_target_sec: 0}), do: "0"

  defp progress_percent(slot),
    do: number(min(100, max(0, slot.completed_sec * 100 / slot.weekly_target_sec)))
end
