defmodule BurpeeTrainerWeb.HomeHistoryComponents do
  @moduledoc "Progress: the coach's look back, each burpee type's goal, and saved-session inspection."

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.History
  alias BurpeeTrainerWeb.Fmt
  alias Phoenix.LiveView.JS

  # Where the chart's top (each type's goal) and bottom lines sit, in percent of its height.
  @plot_top 12
  @plot_bottom 88

  attr(:state, :map, required: true)

  def panel(assigns) do
    ~H"""
    <section id="home-history" aria-labelledby="home-history-heading" class="home-history">
      <div
        id="home-history-body"
        class="home-history-body"
      >
        <div class="home-history-header">
          <h1
            id="home-history-heading"
            tabindex="-1"
            phx-mounted={JS.focus(to: "#home-history-heading")}
            class="screen-heading"
          >
            Progress
          </h1>
          <span :if={Map.get(@state, :history_available?, false)} id="history-level">
            {Fmt.level(@state.current_level)}
          </span>
        </div>
        <.history_header state={@state} />
        <p :if={@state.history_error} id="home-history-error" role="status">{@state.history_error}</p>
        <%= if is_nil(@state.history_error) and @state.history_available? do %>
          <div role="group" aria-label="Period" class="home-history-periods">
            <button
              :for={
                {label, value} <- [
                  {"12 weeks", "twelve_weeks"},
                  {"Year", "year"},
                  {"All time", "all"}
                ]
              }
              id={"home-history-period-#{value}"}
              type="button"
              class="home-history-period"
              phx-click="history_period"
              phx-value-period={value}
              aria-pressed={to_string(@state.history_period == value)}
            >
              {label}
            </button>
          </div>
          <.trend_chart
            points={@state.history_points}
            empty?={@state.history_empty?}
            period={@state.history_period}
            period_start={List.first(@state.history_weeks).start}
            now={@state.history_snapshot_now}
            show_sessions?={@state.history_show_sessions?}
            gauges={@state.history_gauges}
          />
          <section
            id="home-history-sessions-panel"
            hidden={not @state.history_show_sessions?}
            inert={not @state.history_show_sessions?}
            aria-label="Saved sessions"
            class="home-history-sessions-panel"
          >
            <div class="home-history-trend-heading">
              <h2>Reps per 20 minutes</h2>
              <div class="home-history-view-switch" role="group" aria-label="Reps view">
                <button
                  id="home-history-density-back"
                  type="button"
                  class="home-history-period"
                  aria-pressed="false"
                  phx-mounted={
                    @state.history_show_sessions? && JS.focus(to: "#home-history-density-back")
                  }
                  phx-click="history_density_mode"
                  phx-value-mode="chart"
                >
                  Chart
                </button>
                <button type="button" class="home-history-period" aria-pressed="true">
                  Sessions
                </button>
              </div>
            </div>
            <h3
              :if={is_nil(@state.history_error) and @state.history_available?}
              id="home-history-sessions-heading"
              tabindex="-1"
              class="home-history-sessions-heading sr-only"
            >
              Sessions
            </h3>
            <div
              :if={not @state.history_empty? and is_nil(@state.history_error)}
              id="home-history-table-region"
              phx-remove={removed_target_focus("home-history-table-region")}
              role="region"
              aria-label="Saved workout sessions"
              tabindex="0"
              class="home-history-table-region"
            >
              <table id="home-history-table" class="home-history-table">
                <caption class="sr-only">Saved sessions; actual reps and duration</caption>
                <thead class="sr-only">
                  <tr>
                    <th scope="col">Workout</th>
                    <th scope="col">Reps</th>
                    <th scope="col">Duration</th>
                  </tr>
                </thead>
                <tbody id="home-history-sessions" phx-update="stream">
                  <.session_row
                    :for={{id, session} <- @state.streams.history_sessions}
                    id={id}
                    session={session}
                    timezone={@state.current_scope.user.timezone}
                    expanded?={@state.history_selected_id == session.id}
                    insight={@state.history_selected_insight}
                    confirm?={@state.history_confirm_delete?}
                  />
                </tbody>
              </table>
            </div>
            <button
              :if={@state.history_has_more?}
              id="home-history-more"
              phx-remove={removed_target_focus("home-history-more")}
              type="button"
              class="home-history-more"
              phx-click="history_more"
              phx-disable-with="Loading sessions…"
            >
              Load more sessions
            </button>
          </section>
          <section id="home-history-weekly" aria-label="Minutes each week">
            <div class="home-history-week-heading">
              <h2>Minutes each week</h2>
              <%!-- A view switch reads like the period tabs: both views, the current one underlined. --%>
              <div
                :if={@state.history_weeks != []}
                class="home-history-view-switch"
                role="group"
                aria-label="Minutes view"
              >
                <button
                  :if={is_nil(@state.history_week_start)}
                  type="button"
                  class="home-history-period"
                  aria-pressed="true"
                >
                  Weeks
                </button>
                <button
                  :if={@state.history_week_start}
                  id="home-history-week-mode"
                  type="button"
                  class="home-history-period"
                  aria-pressed="false"
                  phx-mounted={JS.focus(to: "#home-history-week-mode")}
                  phx-click={JS.push("history_week_back")}
                >
                  Weeks
                </button>
                <button
                  :if={is_nil(@state.history_week_start)}
                  id="home-history-week-mode"
                  type="button"
                  class="home-history-period"
                  aria-pressed="false"
                  phx-click="history_week"
                  phx-value-start={Date.to_iso8601(List.last(@state.history_weeks).start)}
                >
                  Days
                </button>
                <button
                  :if={@state.history_week_start}
                  type="button"
                  class="home-history-period"
                  aria-pressed="true"
                >
                  Days
                </button>
              </div>
            </div>
            <p
              :if={is_nil(@state.history_week_start) and completed_week_summary(@state.history_weeks)}
              id="home-history-week-count"
              class="home-history-week-count"
            >
              {completed_week_summary(@state.history_weeks)}
            </p>
            <%= if @state.history_week_start do %>
              <div
                id="home-history-week-detail"
                class="home-history-status home-history-trend-readout"
              >
                <p class="home-history-streak-line">
                  <strong>{week_minutes(@state.history_weeks, @state.history_week_start)}</strong>
                  <span>min, {Fmt.week(@state.history_week_start)}</span>
                </p>
              </div>
              <div
                id="home-history-daily"
                role="group"
                aria-label="Daily training minutes"
                class="home-history-daily"
              >
                <div id="home-history-day-axis" class="home-history-day-axis" aria-hidden="true">
                  <span>80</span><span>40</span><span>0</span>
                </div>
                <div id="home-history-day-plot" class="home-history-day-plot">
                  <div
                    :for={day <- @state.history_week_days}
                    id={"home-history-day-#{Date.to_iso8601(day.date)}"}
                    data-minutes={day.minutes}
                    data-seconds={day.seconds}
                    class="home-history-day"
                    role="img"
                    aria-label={"#{Calendar.strftime(day.date, "%A")}: #{day_duration(day.seconds)}"}
                  >
                    <span
                      class="home-history-day-bar"
                      style={"height: #{day_bar_height(day.seconds)}%"}
                    >
                      <span :if={day.seconds > 0} class="home-history-day-value">
                        {day_duration(day.seconds)}
                      </span>
                    </span>
                    <span class="home-history-day-label">
                      {day.date |> Calendar.strftime("%a") |> String.first()}
                    </span>
                  </div>
                </div>
              </div>
            <% end %>
            <div
              :if={is_nil(@state.history_week_start)}
              id="home-history-week-grid"
              class="home-history-week-grid"
            >
              <div :for={row <- weekly_rows(@state.history_weeks)} class="home-history-week-row">
                <button
                  :for={week <- row}
                  id={"home-history-week-#{Date.to_iso8601(week.start)}"}
                  type="button"
                  phx-click={JS.focus(to: "#home-history-week-mode") |> JS.push("history_week")}
                  phx-value-start={Date.to_iso8601(week.start)}
                  class={[
                    "home-history-week-cell",
                    week_tone(week.minutes),
                    week.open? && "home-history-week-open"
                  ]}
                  title={week_title(week)}
                  aria-label={week_title(week)}
                >
                </button>
                <span
                  :for={_ <- 1..(12 - length(row))//1}
                  :if={length(row) < 12}
                  class="home-history-week-placeholder"
                  aria-hidden="true"
                >
                </span>
              </div>
            </div>
          </section>
        <% end %>
        <p
          :if={@state.history_empty? and is_nil(@state.history_error)}
          id="home-history-empty"
          class="home-history-empty"
        >
          <%= if @state.history_available? do %>
            No sessions in this period.
          <% else %>
            No workouts yet. Complete a workout to begin tracking your training.
          <% end %>
        </p>
        <p
          :if={not @state.history_empty? and is_nil(@state.history_error)}
          id="home-history-count"
          class="sr-only"
        >
          {@state.history_loaded_count} sessions shown
        </p>
      </div>
    </section>
    """
  end

  attr(:session, BurpeeTrainer.Workouts.WorkoutSession, required: true)
  attr(:insight, :any, default: nil)
  attr(:confirm?, :boolean, required: true)
  # A session opens in place under its row: what the coach saw, the numbers, then Delete.
  def session_detail(assigns) do
    tags =
      (assigns.session.tags || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assigns = assign(assigns, :tags, tags)

    ~H"""
    <div
      id="home-history-sheet"
      class="home-history-detail home-enter"
      role="region"
      aria-label="Session details"
    >
      <section :if={@insight} id="history-insight">
        <h3 id="history-insight-headline">{@insight.headline}</h3>
        <ul id="history-insight-points">
          <li :for={point <- @insight.points["items"]}>{point["text"]}</li>
        </ul>
      </section>
      <div id={"home-history-details-#{@session.id}"}>
        <.session_details id={"home-history-sheet-details-#{@session.id}"} session={@session} />
      </div>
      <div
        :if={@tags != []}
        id="home-history-sheet-tags"
        class="home-history-sheet-tags"
        aria-label="Session tags"
      >
        <span :for={tag <- @tags}>{tag |> String.replace("_", " ") |> String.capitalize()}</span>
      </div>
      <p :if={String.trim(@session.note_post || "") != ""} id="home-history-sheet-note">
        {String.trim(@session.note_post)}
      </p>
      <div :if={not @confirm?} class="home-review-actions">
        <button
          id="home-history-delete"
          type="button"
          class="home-text-action"
          phx-click="history_confirm_delete"
        >
          Delete
        </button>
      </div>
      <div :if={@confirm?} class="home-history-delete-ask">
        <p>Delete this session? It comes off your week and your charts.</p>
        <div class="home-review-actions">
          <button
            id="home-history-delete-cancel"
            type="button"
            class="home-text-action"
            phx-click="history_cancel_delete"
          >
            Cancel
          </button>
          <button
            id="home-history-delete-confirm"
            type="button"
            class="home-primary-action home-danger-action"
            phx-click="history_delete_session"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp open_session, do: JS.push("history_session")

  defp day_duration(seconds) when seconds < 60, do: "#{seconds} sec"
  defp day_duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp day_duration(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} sec"

  defp day_bar_height(seconds) when seconds > 0, do: min(max(seconds * 100 / 4_800, 1), 100)
  defp day_bar_height(_seconds), do: 0

  defp week_minutes(weeks, date),
    do: weeks |> Enum.find(&(&1.start == date)) |> Map.fetch!(:seconds) |> div(60)

  defp weekly_rows(weeks),
    do: weeks |> Enum.reverse() |> Enum.chunk_every(12) |> Enum.map(&Enum.reverse/1)

  defp week_tone(0), do: "home-history-tone-0"
  defp week_tone(minutes) when minutes < 20, do: "home-history-tone-1"
  defp week_tone(minutes) when minutes < 40, do: "home-history-tone-20"
  defp week_tone(minutes) when minutes < 60, do: "home-history-tone-40"
  defp week_tone(minutes) when minutes < 80, do: "home-history-tone-60"
  defp week_tone(_), do: "home-history-tone-80"

  defp week_title(week),
    do:
      "Week of #{Date.to_iso8601(week.start)}: #{week.minutes} of #{week.target_minutes} minutes#{if week.open?, do: ", in progress", else: ""}"

  # Counts the weeks that reached 80 minutes; with none yet it says nothing rather than "0 of 11".
  defp completed_week_summary(weeks) do
    completed = Enum.drop(weeks, -1)

    case Enum.count(completed, & &1.target?) do
      0 -> nil
      hit -> "#{hit} of the last #{length(completed)} weeks at 80 min"
    end
  end

  attr(:state, :map, required: true)

  # The coach's look back over recent weeks, then each burpee type's goal side by side.
  defp history_header(assigns) do
    ~H"""
    <header id="history-header" class="history-header">
      <p :if={summary_line?(@state)} id="history-coach-summary" class="history-coach-summary">
        <BurpeeTrainerWeb.HomeCoachComponents.summary_body
          summary={@state.progress_summary}
          loading?={@state.progress_summary_loading?}
          field={:review}
        />
      </p>
      <div id="progress-gauges" class="progress-gauges">
        <.gauge :for={gauge <- @state.history_gauges} gauge={gauge} />
      </div>
    </header>
    """
  end

  attr(:gauge, :map, required: true)

  # One burpee type: its best against its goal, how the goal is going, and the next goal
  # when there is none. Its history is a line on the shared chart below. Both types have the same shape, so they read as a pair.
  # See docs/specs/2026-10-14-coach-on-home-design.md.
  defp gauge(assigns) do
    ~H"""
    <section
      id={"progress-gauge-#{@gauge.burpee_type}"}
      class="progress-gauge"
      data-kind={@gauge.kind}
      aria-label={type_sentence(@gauge.burpee_type)}
    >
      <%!-- The key: the type in its line's colour on the chart below. --%>
      <p class={["progress-gauge-type", "progress-key-#{series_class(@gauge.burpee_type)}"]}>
        {type_sentence(@gauge.burpee_type)}
      </p>
      <p class={["progress-gauge-number", @gauge.kind == :reached && "progress-gauge-met"]}>
        {gauge_number(@gauge)}
      </p>
      <p class="progress-gauge-label">{gauge_label(@gauge)}</p>
      <%!-- When an honest course exists, when the target comes at this pace. --%>
      <p
        :if={@gauge.kind == :goal and @gauge.course}
        class={["progress-course-caption", @gauge.course.on_course? && "progress-course-on"]}
      >
        {if(@gauge.course.on_course?, do: "On course for ", else: "At this pace, ")}{Calendar.strftime(
          @gauge.course.projected_on,
          "%-d %b"
        )}
      </p>
      <button
        :if={@gauge.kind in [:reached, :best]}
        id={"progress-set-goal-#{@gauge.burpee_type}"}
        type="button"
        class="home-text-action progress-gauge-set"
        phx-click="progress_set_goal"
        phx-value-type={@gauge.burpee_type}
        aria-label={"Set goal: #{Fmt.goal_title(@gauge.next)} #{Fmt.goal_by(@gauge.next)}"}
      >
        Set {@gauge.next.burpee_count_target} {Fmt.goal_by(@gauge.next)}
      </button>
    </section>
    """
  end

  defp gauge_number(%{kind: :none}), do: "–"
  defp gauge_number(%{kind: :first, reps: reps}), do: reps
  defp gauge_number(%{best: best}), do: best

  defp gauge_label(%{kind: :goal, goal: goal}),
    do: "of #{goal.burpee_count_target}#{goal_minutes(goal)} #{Fmt.goal_by(goal)}"

  defp gauge_label(%{kind: :reached, reached_on: on}),
    do: "Reached #{Calendar.strftime(on, "%-d %b")}"

  defp gauge_label(%{kind: :best}), do: "Best in 20 min"
  defp gauge_label(%{kind: :first}), do: "First session"
  defp gauge_label(%{kind: :none}), do: "No sessions yet"

  # Goals are in 20 minutes unless they say otherwise.
  defp goal_minutes(%{duration_sec_target: 1200}), do: ""
  defp goal_minutes(%{duration_sec_target: sec}), do: " in #{div(sec, 60)} min"

  defp type_sentence(:six_count), do: "Six-count"
  defp type_sentence(:navy_seal), do: "Navy SEAL"

  # The look back shows once the coach has written one; the note itself is for Home.
  defp summary_line?(state),
    do:
      Map.get(state, :progress_summary_loading?, false) or
        match?(%{review: review} when is_binary(review), Map.get(state, :progress_summary))

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  def kpi(assigns) do
    ~H"""
    <article id={"home-history-kpi-#{@id}"} class="home-history-kpi" data-history-kpi>
      <p>{@label}</p>
      <strong>{@value}</strong>
    </article>
    """
  end

  attr(:points, :map, required: true)
  attr(:empty?, :boolean, required: true)
  attr(:period, :string, default: "twelve_weeks")
  attr(:period_start, :any, default: nil)
  attr(:now, :any, default: nil)
  attr(:show_sessions?, :boolean, default: false)
  attr(:gauges, :list, default: [])

  # Both types on one chart, each in its colour and on its own axis: six-count on the
  # left, Navy SEAL on the right. Each axis tops out at that type's goal, so both goals
  # sit on the one dashed line and a line's height reads as closeness to its goal.
  def trend_chart(assigns) do
    series = [
      %{
        type: :six_count,
        dom_id: "home-history-six-count",
        label: "Six-count",
        points: assigns.points.six_count
      },
      %{
        type: :navy_seal,
        dom_id: "home-history-navy-seal",
        label: "Navy SEAL",
        points: assigns.points.navy_seal
      }
    ]

    scales = scales(series, assigns.gauges)

    assigns =
      assigns
      |> assign(:series, plot_series(series, scales, assigns.period_start, assigns.now))
      |> assign(:axes, axes(series, scales))
      |> assign(:goal?, Enum.any?(assigns.gauges, &(&1.kind == :goal)))
      |> assign(plot_top: @plot_top, plot_bottom: @plot_bottom)

    ~H"""
    <figure
      id="home-history-trend"
      phx-remove={removed_target_focus("home-history-trend")}
      class="home-history-trend"
      hidden={@show_sessions?}
      inert={@show_sessions?}
      aria-labelledby="home-history-trend-label"
    >
      <figcaption id="home-history-trend-label">
        <span class="home-history-trend-heading">
          <span class="font-semibold">Reps per 20 minutes</span>
          <span class="home-history-view-switch" role="group" aria-label="Reps view">
            <button type="button" class="home-history-period" aria-pressed="true">Chart</button>
            <button
              id="home-history-density-sessions"
              type="button"
              class="home-history-period"
              aria-pressed="false"
              phx-mounted={not @show_sessions? && JS.focus(to: "#home-history-density-sessions")}
              phx-click="history_density_mode"
              phx-value-mode="sessions"
            >
              Sessions
            </button>
          </span>
        </span>
      </figcaption>
      <%= if @empty? or Enum.all?(@series, &(&1.points == [])) do %>
        <p class="home-history-trend-empty">No measured sessions in this period.</p>
      <% else %>
        <div
          id="home-history-trend-plot"
          class="home-history-plot"
          phx-remove={removed_target_focus("home-history-trend-plot")}
        >
          <div
            :for={axis <- @axes}
            id={"home-history-trend-axis-#{axis.side}"}
            class={[
              "home-history-trend-axis",
              "home-history-trend-axis-#{axis.side}",
              "progress-key-#{series_class(axis.type)}"
            ]}
            aria-hidden="true"
          >
            <span style={"top: #{@plot_top}%"}>{axis.hi}</span>
            <span style="top: 50%">{div(axis.hi + axis.lo, 2)}</span>
            <span style={"top: #{@plot_bottom}%"}>{axis.lo}</span>
          </div>
          <div class={["home-history-plot-area", length(@axes) == 2 && "home-history-plot-dual"]}>
            <button
              id="home-history-trend-open-sessions"
              type="button"
              aria-label="Show saved sessions"
              phx-click="history_density_mode"
              phx-value-mode="sessions"
              class="home-history-trend-open-sessions"
            >
            </button>
            <svg
              viewBox="0 0 100 100"
              preserveAspectRatio="none"
              aria-hidden="true"
              class="home-history-svg"
            >
              <line
                x1="0"
                x2="100"
                y1={@plot_top}
                y2={@plot_top}
                class={["home-history-grid", @goal? && "home-history-goal-line"]}
              />
              <line x1="0" x2="100" y1="50" y2="50" class="home-history-grid" />
              <line x1="0" x2="100" y1={@plot_bottom} y2={@plot_bottom} class="home-history-grid" />
              <polyline
                :for={series <- @series}
                :if={series.points != []}
                class={"home-history-line-#{series_class(series.type)}"}
                stroke-dasharray={series.type == :navy_seal && "5 4"}
                points={series.line}
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                vector-effect="non-scaling-stroke"
              />
            </svg>
            <%= for series <- @series, point <- series.points do %>
              <button
                id={"home-history-point-#{point.id}"}
                phx-remove={removed_target_focus("home-history-point-#{point.id}")}
                type="button"
                phx-click={open_session()}
                phx-value-id={point.id}
                phx-value-source="point"
                aria-label={"#{series.label}, #{DateTime.to_iso8601(point.completed_at)}, #{point.actual_reps} actual reps, #{point.actual_duration_sec} seconds actual duration, density #{point.density} reps per 20 min"}
                style={"left: #{point.x}%; top: #{point.y}%;"}
                class={[
                  "home-history-point",
                  "home-history-point-#{series_class(series.type)}"
                ]}
              >
                <span aria-hidden="true"></span>
              </button>
            <% end %>
          </div>
        </div>
      <% end %>
    </figure>
    """
  end

  attr(:id, :string, required: true)
  attr(:session, BurpeeTrainer.Workouts.WorkoutSession, required: true)
  attr(:expanded?, :boolean, required: true)
  attr(:timezone, :string, required: true)
  attr(:insight, :any, default: nil)
  attr(:confirm?, :boolean, default: false)

  def session_row(assigns) do
    assigns =
      assign(assigns,
        display_name: display_name(assigns.session),
        completion: local_completion(assigns.session, assigns.timezone)
      )

    ~H"""
    <tr id={@id} phx-remove={removed_target_focus(@id)} class="home-history-session-card">
      <td colspan="3">
        <button
          id={"home-history-inspect-#{@session.id}"}
          type="button"
          class="home-history-session-toggle"
          phx-click={open_session()}
          phx-value-id={@session.id}
          phx-value-source="row"
          aria-controls={"home-history-details-#{@session.id}"}
          aria-expanded={to_string(@expanded?)}
        >
          <span class="home-history-session-summary">
            <span class="home-history-session-name">{@display_name}</span>
            <small>{@completion}</small>
          </span>
          <span class="home-history-session-reps">{@session.burpee_count_actual || "—"}</span>
          <span class="home-history-session-time">
            {Fmt.duration_sec(@session.duration_sec_actual)}
          </span>
        </button>
        <.session_detail
          :if={@expanded?}
          session={@session}
          insight={@insight}
          confirm?={@confirm?}
        />
      </td>
    </tr>
    """
  end

  attr(:id, :string, required: true)
  attr(:session, BurpeeTrainer.Workouts.WorkoutSession, required: true)

  def session_details(assigns) do
    assigns = assign(assigns, density: History.points([assigns.session]))

    ~H"""
    <%!-- The row already shows reps and time; details add only the plan they're measured
         against, when there was one, and the reps per 20 minutes. --%>
    <div id={@id} class="home-history-status home-history-comparison">
      <p
        :if={@session.burpee_count_planned}
        class="home-history-streak-line"
        data-actual-reps={@session.burpee_count_actual}
      >
        <strong>{@session.burpee_count_actual || "—"}</strong>
        <span>
          reps of {@session.burpee_count_planned}
        </span>
      </p>
      <p
        :if={@session.duration_sec_planned}
        class="home-history-streak-line"
        data-actual-duration-sec={@session.duration_sec_actual}
      >
        <strong>{Fmt.duration_sec(@session.duration_sec_actual)}</strong>
        <span>of {Fmt.duration_sec(@session.duration_sec_planned)}</span>
      </p>
      <p :for={point <- @density} class="home-history-streak-line">
        <strong>{point.density}</strong>
        <span>per 20 min</span>
      </p>
    </div>
    """
  end

  defp plot_series(series, scales, period_start, now) do
    all =
      series
      |> Enum.flat_map(& &1.points)
      |> Enum.sort_by(&{DateTime.to_unix(&1.completed_at, :microsecond), &1.id})

    timestamps = Enum.map(all, &DateTime.to_unix(&1.completed_at, :microsecond))

    first =
      case period_start do
        %Date{} = date ->
          DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:microsecond)

        nil ->
          Enum.min(timestamps, fn -> 0 end)
      end

    last =
      case now do
        %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
        nil -> Enum.max(timestamps, fn -> 0 end)
      end

    Enum.map(series, fn series ->
      {lo, hi} = Map.get(scales, series.type, {0, 1})

      points =
        Enum.sort_by(series.points, &{DateTime.to_unix(&1.completed_at, :microsecond), &1.id})

      plotted =
        Enum.map(points, fn point ->
          timestamp = DateTime.to_unix(point.completed_at, :microsecond)

          x =
            if first == last,
              do: 50.0,
              else: max(4.0, min(96.0, (timestamp - first) / (last - first) * 100))

          Map.merge(point, %{
            x: x,
            y:
              max(
                2.0,
                @plot_bottom - (point.density - lo) / (hi - lo) * (@plot_bottom - @plot_top)
              )
          })
        end)

      Map.merge(series, %{points: plotted, line: Enum.map_join(plotted, " ", &"#{&1.x},#{&1.y}")})
    end)
  end

  # Each type's range: up to its goal when it has one, else its best rounded up; down to a
  # little under its lowest point.
  defp scales(series, gauges) do
    for %{points: [_ | _] = points, type: type} <- series, into: %{} do
      densities = Enum.map(points, & &1.density)

      hi =
        case Enum.find(gauges, &(&1.burpee_type == type)) do
          %{kind: :goal, goal: goal} -> goal.burpee_count_target
          _ -> max(ceil(Enum.max(densities) / 20) * 20, 20)
        end

      lo = (Enum.min(densities) * 0.8 / 10) |> floor() |> Kernel.*(10) |> max(0) |> min(hi - 10)
      {type, {lo, hi}}
    end
  end

  # Six-count reads on the left; Navy SEAL on the right, or the left when it is alone.
  defp axes(series, scales) do
    shown = for %{type: type} <- series, Map.has_key?(scales, type), do: type

    shown
    |> Enum.zip([:left, :right])
    |> Enum.map(fn {type, side} ->
      {lo, hi} = scales[type]
      %{type: type, side: side, lo: lo, hi: hi}
    end)
  end

  defp series_class(type), do: type |> Atom.to_string() |> String.replace("_", "-")

  defp removed_target_focus(id),
    do:
      JS.focus(
        to:
          "#home-history:not([hidden]):not([inert]):has(##{id}:focus-within) #home-history-heading"
      )

  defp display_name(%{display_name_snapshot: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{source_kind: :video}), do: "Video workout"
  defp display_name(%{source_kind: :plan}), do: "Workout"
  defp display_name(_), do: "Manual workout"

  defp local_completion(%{completed_at: %DateTime{} = completed_at}, timezone) do
    case DateTime.shift_zone(completed_at, timezone) do
      {:ok, local_datetime} -> local_completion_label(local_datetime)
      {:error, _reason} -> "Completion date and time unavailable"
    end
  end

  defp local_completion(_session, _timezone), do: "Completion date and time unavailable"

  # "Sun 11 Oct, 10:00", with the year only when it is not this one.
  defp local_completion_label(%DateTime{} = local) do
    year = if local.year == Date.utc_today().year, do: "", else: " %Y"
    Calendar.strftime(local, "%a %-d %b#{year}, %H:%M")
  end
end
