defmodule BurpeeTrainerWeb.HomeWorkoutComponents do
  use BurpeeTrainerWeb, :html
  alias BurpeeTrainerWeb.CreationParameters
  attr(:state, :map, required: true)

  def workspace(assigns) do
    ~H"""
    <section id="home-ready-recommendation" class="adaptive-home">
      <div id="home-week-progress">
        <span>Week of {@state.slot.week_start}</span>
        <span>
          {div(@state.slot.completed_sec, 60)} / {div(@state.slot.weekly_target_sec, 60)} min
        </span>
      </div>
      <div id="home-workout-area" aria-busy={@state.busy?}>
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
                {CreationParameters.duration_label(@state.home_selection.plan.target_duration_sec)} · {@state.home_selection.plan.target_reps} reps
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
                >
                  Other workouts
                </button>
                <button
                  id="home-filter-toggle"
                  type="button"
                  phx-click="toggle_filters"
                  aria-expanded={to_string(@state.filters_open?)}
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
                    phx-value-value={type}
                    aria-pressed={to_string(MapSet.member?(@state.filters.types, type))}
                  >
                    {CreationParameters.type_label(Atom.to_string(type))}
                  </button>
                </div>
                <div role="group" aria-label="Catalog level">
                  <button
                    :for={level <- Enum.reverse(BurpeeTrainer.Levels.all_levels())}
                    id={"home-level-#{level}"}
                    type="button"
                    phx-click="filter"
                    phx-value-kind="level"
                    phx-value-value={level}
                    aria-pressed={to_string(MapSet.member?(@state.filters.levels, level))}
                  >
                    {level_label(level)}
                  </button>
                </div>
                <button id="home-filter-reset" type="button" phx-click="reset_filters">Reset</button>
              </div>
              <div id="home-alternatives-panel" hidden={!@state.alternatives_open?}>
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
                <p
                  :if={@state.alternatives_empty?}
                  id="home-alternatives-empty"
                  class="home-local-message"
                >
                  No matching workouts. Try changing the filters.
                </p>
                <div id="home-alternatives" phx-update="stream">
                  <button
                    :for={{id, item} <- @state.streams.alternatives}
                    id={id}
                    type="button"
                    phx-click="select_alternative"
                    phx-value-id={item.source_id}
                    phx-value-kind={item.kind}
                    class="home-alternative"
                  >
                    {item.name}
                  </button>
                </div>
              </div>
            </section>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr(:rows, :list, required: true)
  attr(:expanded, :any, required: true)

  def inspection(assigns) do
    ~H"""
    <div id="home-inspection">
      <table>
        <caption class="sr-only">Exact workout structure</caption>
        <thead>
          <tr>
            <th scope="col">Sets / repeats</th>
            <th scope="col">Prescription and recovery</th>
          </tr>
        </thead>
        <tbody :for={row <- @rows} id={row.id}>
          <tr>
            <th scope="row">
              <button
                :if={row.count > 1}
                type="button"
                phx-click="toggle_group"
                phx-value-id={row.id}
                aria-expanded={to_string(MapSet.member?(@expanded, row.id))}
                aria-controls={"#{row.id}-details"}
              >
                {row.count} ×
              </button>
              <span :if={row.count == 1}>
                {if row.trailing?, do: "Final recovery", else: "Interval"}
              </span>
            </th>
            <td>{summary(row)}</td>
          </tr>
          <tr :if={row.count > 1} id={"#{row.id}-details"} hidden={!MapSet.member?(@expanded, row.id)}>
            <td colspan="2">
              <ol>
                <li :for={unit <- row.units} id={"#{row.id}-event-#{hd(unit.paired).index}"}>
                  {unit_text(unit)}
                </li>
              </ol>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp summary(row),
    do:
      row.units
      |> Enum.take(div(length(row.units), row.count))
      |> Enum.map_join(" / ", &unit_text/1)

  defp unit_text(unit),
    do:
      Enum.map_join(unit.paired, "; ", fn %{program: e} ->
        case e["kind"] do
          "work" ->
            "#{e["reps"]} reps · prescribed cadence #{e["sec_per_rep_us"] / 1_000_000} s/rep · interval #{e["duration_sec"]} s"

          "rest" ->
            "Recovery #{e["duration_ms"] / 1_000} s"
        end
      end)

  defp level_label(:graduated), do: "Graduated"

  defp level_label(level),
    do: level |> Atom.to_string() |> String.replace_prefix("level_", "") |> String.upcase()
end
