defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html
  alias BurpeeTrainerWeb.CreationParameters
  attr(:state, :map, required: true)

  def workspace(assigns) do
    ~H"""
    <section id="home-ready-recommendation" class="adaptive-home">
      <.week_progress slot={@state.slot} />
      <div id="home-workout-area" aria-busy={to_string(@state.busy?)}>
        <%= if @state.busy? do %>
          <div id="home-update-loading" role="status" aria-label="Updating workout">
            <span class="home-loading-animation" aria-hidden="true"></span>
            <span class="sr-only">Updating workout</span>
          </div>
        <% else %>
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
              <span class="home-workout-totals">
                {duration_label(@state.home_selection.plan.target_duration_sec)} · {@state.home_selection.plan.target_reps} reps
              </span>
            </button>
          </h1>
          <div id="home-expansion" class="home-expansion" data-open={to_string(@state.expanded?)}>
            <section
              id="home-expansion-content"
              class="home-expansion-content"
              inert={!@state.expanded?}
              aria-hidden={to_string(!@state.expanded?)}
            >
              <.inspection rows={@state.inspection_rows} expanded={@state.expanded_groups} />
              <div id={"home-editor-#{@state.home_selection.home_revision}"}>
                <.form
                  for={@state.adjustment_form}
                  id="home-adjustment-form"
                  phx-change="change_adjustment"
                  phx-submit="submit_home_action"
                >
                  <input
                    type="hidden"
                    name="client_session_id"
                    value={@state.start_client_session_id}
                  />
                  <.input
                    field={@state.adjustment_form[:instruction]}
                    id="home-adjustment"
                    type="textarea"
                    rows="1"
                    aria-label="Adjust this workout"
                    placeholder="Adjust…"
                    aria-describedby="home-adjustment-error"
                    class="home-adjustment"
                    phx-hook="HomeAdjustment"
                    phx-update="ignore"
                  />
                  <p id="home-adjustment-error" role="status" class="home-local-message">
                    {@state.local_error}
                  </p>
                  <button id="home-action" type="submit" class="home-action">
                    {if String.trim(@state.instruction) == "", do: "Start", else: "Update"}
                    <.icon name="hero-arrow-right" class="size-4" />
                  </button>
                </.form>
              </div>
              <div class="home-other-heading">
                <button
                  id="home-other-workouts"
                  type="button"
                  phx-click="toggle_other"
                  aria-expanded={to_string(@state.alternatives_open?)}
                  aria-controls="home-alternatives-panel"
                >
                  Other workouts <.icon name="hero-chevron-down" class="home-chevron" />
                </button>
              </div>
              <div id="home-alternatives-panel" hidden={!@state.alternatives_open?}>
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
                    type="button"
                    phx-click="toggle_filters"
                    aria-expanded={to_string(@state.filters_open?)}
                    aria-controls="home-filters"
                  >
                    Filter
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
                    {level_label(@state.current_level)} is your current level.
                  </p>
                </div>
                <p
                  :if={@state.alternatives_empty?}
                  id="home-alternatives-empty"
                  class="home-local-message"
                >
                  No matching workouts. Try changing the filters.
                </p>
                <div id="home-alternatives" phx-update="stream">
                  <.alternative :for={{id, item} <- @state.streams.alternatives} id={id} item={item} />
                </div>
              </div>
            </section>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:item, :map, required: true)

  def alternative(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="select_alternative"
      phx-value-id={@item.source_id}
      phx-value-kind={@item.kind}
      class="home-alternative"
    >
      <span class="home-alternative-name">{@item.name}</span>
      <span class="home-alternative-metadata">
        {duration_label(@item.duration_sec)} · {if is_nil(@item.reps),
          do: "Reps unknown",
          else: "#{@item.reps} reps"}
      </span>
    </button>
    """
  end

  attr(:slot, :map, required: true)

  def week_progress(assigns) do
    ~H"""
    <div id="home-week-progress">
      <div class="home-progress-labels">
        <span>{duration_label(@slot.completed_sec)} / {duration_label(@slot.weekly_target_sec)}</span>
        <span id="home-week-number">Week {iso_week(@slot.week_start)}</span>
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
    ~H"""
    <div id="home-inspection">
      <table>
        <caption class="sr-only">
          Exact workout structure. Cadence is prescribed time per rep, not measured active pace.
          Rest follows each set, including repeat boundaries; a dash means no recovery.
          Repeats preserve the ordered sets, not authoring blocks. Exact work interval durations are included with cadence.
        </caption>
        <thead>
          <tr>
            <th scope="col">Sets</th>
            <th scope="col">Reps</th>
            <th scope="col">Cadence</th>
            <th scope="col">Rest</th>
          </tr>
        </thead>
        <tbody :for={row <- @rows} id={row.id}>
          <tr class={row.count > 1 && "home-group-summary"}>
            <th scope="row">
              <button
                :if={row.count > 1}
                type="button"
                class="home-group-toggle"
                phx-click="toggle_group"
                phx-value-id={row.id}
                aria-expanded={to_string(MapSet.member?(@expanded, row.id))}
                aria-controls={"#{row.id}-details"}
                aria-describedby={"#{row.id}-prescription"}
              >
                {row.count} {if length(row.units) == row.count, do: "sets", else: "repeats"}
                <.icon name="hero-chevron-down" class="home-chevron" />
              </button>
              <span :if={row.count > 1} id={"#{row.id}-prescription"} class="sr-only">
                {Enum.map_join(shared_units(row), "; ", &prescription_label/1)}
              </span>
              <span :if={row.count == 1}>{row_label(row)}</span>
            </th>
            <.prescription units={shared_units(row)} />
          </tr>
          <tr
            :if={row.count > 1}
            id={"#{row.id}-details"}
            class="home-group-detail"
            hidden={!MapSet.member?(@expanded, row.id)}
          >
            <td colspan="4">
              <div class="home-constituents">
                <p :if={length(row.units) == row.count} class="home-shared-prescription">
                  Prescription as above
                </p>
                <ol aria-label="Ordered constituent sets">
                  <li :for={unit <- row.units} id={"#{row.id}-event-#{hd(unit.paired).index}"}>
                    <span class="home-set-label">Set {set_number(@rows, unit)}</span>
                    <span :if={length(row.units) == row.count} class="sr-only">
                      {prescription_label(unit)}
                    </span>
                    <span :if={length(row.units) != row.count} class="home-constituent-prescription">
                      {work_value(unit, "reps")} reps · {cadence(unit)} cadence ·
                      <span class={["home-interval", !exceptional_interval?(unit) && "sr-only"]}>
                        Interval {number(work(unit)["duration_sec"])}s ·
                      </span>
                      {recovery_label(unit)}
                    </span>
                    <span
                      :if={length(row.units) == row.count && exceptional_interval?(unit)}
                      class="home-interval"
                      aria-hidden="true"
                    >
                      Interval {number(work(unit)["duration_sec"])}s
                    </span>
                  </li>
                </ol>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:units, :list, required: true)

  defp prescription(assigns) do
    ~H"""
    <td class="home-prescription-reps">
      <span :for={unit <- @units}>{work_value(unit, "reps")}</span>
    </td>
    <td class="home-prescription-cadence">
      <span :for={unit <- @units}>
        {cadence(unit)}
        <span
          :if={work(unit)}
          class={["home-interval", if(exceptional_interval?(unit), do: "block", else: "sr-only")]}
        >
          Interval {number(work(unit)["duration_sec"])}s
        </span>
      </span>
    </td>
    <td class="home-prescription-rest">
      <span :for={unit <- @units}>{recovery(unit)}</span>
    </td>
    """
  end

  defp shared_units(row), do: Enum.take(row.units, div(length(row.units), row.count))

  defp prescription_label(unit),
    do:
      "#{work_value(unit, "reps")} reps · #{cadence(unit)} cadence · " <>
        "Interval #{number(work(unit)["duration_sec"])}s · #{recovery_label(unit)}"

  defp recovery_label(unit),
    do: if(recovery(unit) == "—", do: "No recovery", else: "#{recovery(unit)} rest")

  defp work(unit),
    do: Enum.find_value(unit.paired, &if(&1.program["kind"] == "work", do: &1.program))

  defp work_value(unit, key), do: if(work(unit), do: work(unit)[key], else: "—")

  defp cadence(unit),
    do: if(work(unit), do: scaled(work(unit)["sec_per_rep_us"], 1_000_000) <> "s", else: "—")

  # Terminal work can end before the last rep's prescribed cadence elapses.
  # Compare decimal canonical values, without float arithmetic or display rounding.
  defp exceptional_interval?(unit) do
    event = work(unit)
    interval = event["duration_sec"] |> number() |> Decimal.new()
    prescribed = Decimal.div(Decimal.new(event["reps"] * event["sec_per_rep_us"]), 1_000_000)
    not Decimal.equal?(interval, prescribed)
  end

  defp recovery(unit) do
    case Enum.filter(unit.paired, &(&1.program["kind"] == "rest")) do
      [] -> "—"
      rests -> Enum.map_join(rests, " + ", &(scaled(&1.program["duration_ms"], 1_000) <> "s"))
    end
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
  defp iso_week(date), do: date |> Date.to_erl() |> :calendar.iso_week_number() |> elem(1)
  defp progress_percent(%{weekly_target_sec: 0}), do: "0"

  defp progress_percent(slot),
    do: number(min(100, max(0, slot.completed_sec * 100 / slot.weekly_target_sec)))

  defp level_label(:graduated), do: "Graduated"

  defp level_label(level),
    do: level |> Atom.to_string() |> String.replace_prefix("level_", "") |> String.upcase()
end
