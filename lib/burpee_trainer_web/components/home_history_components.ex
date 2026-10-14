defmodule BurpeeTrainerWeb.HomeHistoryComponents do
  @moduledoc "Read-only Home analytics and saved-session inspection. Coach has a separate view."

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainer.History
  alias BurpeeTrainerWeb.Fmt
  alias Phoenix.LiveView.JS

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
            phx-mounted={
              JS.focus(
                to:
                  if(Map.get(@state, :history_focus_return?, false),
                    do: "#history-coach-summary",
                    else: "#home-history-heading"
                  )
              )
            }
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
          <.trend_chart
            points={@state.history_points}
            empty?={@state.history_empty?}
            period={@state.history_period}
            period_start={List.first(@state.history_weeks).start}
            now={@state.history_snapshot_now}
            show_sessions?={@state.history_show_sessions?}
          />
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
              <button type="button" class="home-history-period" aria-pressed="true">Sessions</button>
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

  defp goal_percent(%{best: best, goal: %{burpee_count_target: target}}),
    do: min(100, div(best * 100, target))

  attr(:state, :map, required: true)

  # Level, this week and goals at a glance, then the coach summary (or, with nothing to
  # summarize yet, an invitation): the only way into Coach.
  defp history_header(assigns) do
    ~H"""
    <header id="history-header" class="history-header">
      <.headline
        headline={@state.history_headline.headline}
        dismissed?={Map.get(@state, :history_next_dismissed?, false)}
      />
      <%!-- The coach's line says what to do next; tapping it opens the coach's own screen. --%>
      <.link id="history-coach-summary" patch={~p"/coach"} class="history-coach-summary">
        <BurpeeTrainerWeb.HomeCoachComponents.summary_body
          :if={summary_line?(@state)}
          summary={@state.progress_summary}
          loading?={@state.progress_summary_loading?}
        />
        <span :if={not summary_line?(@state)} class="coach-summary-invitation">
          {if(@state.history_headline.headline.kind == :goal,
            do: "Ask the coach about this week",
            else: "Set a goal with the coach"
          )}
        </span>
        <.icon name="hero-chevron-right" class="history-coach-summary-arrow size-4" />
      </.link>
      <%!-- Other goals follow the headline as quiet rows: what, by when, your best. --%>
      <ul :if={@state.history_headline.others != []} id="progress-goals" class="progress-goals">
        <li :for={row <- @state.history_headline.others} id={"progress-goal-#{row.goal.id}"}>
          <span>{Fmt.goal_title(row.goal)} {Fmt.goal_by(row.goal)}</span>
          <span class="progress-goal-best">{row.best}</span>
        </li>
      </ul>
    </header>
    """
  end

  attr(:headline, :map, required: true)
  attr(:dismissed?, :boolean, default: false)

  # One number leads Progress: the goal you're closest to, a goal just reached, your best,
  # or your first result. See docs/specs/2026-10-13-progress-headline-design.md.
  defp headline(%{headline: %{kind: :none}} = assigns), do: ~H""

  defp headline(assigns) do
    ~H"""
    <section id="progress-headline" class="progress-headline" data-kind={@headline.kind}>
      <p class="progress-headline-number">
        {headline_number(@headline)}<span
          :if={@headline.kind == :goal}
          class="progress-headline-of"
        > / {@headline.goal.burpee_count_target}</span>
      </p>
      <p class={["progress-headline-label", @headline.kind == :reached && "progress-headline-done"]}>
        {headline_label(@headline)}
      </p>
      <%!-- With an honest course, a small chart says when the target comes; else a bar. --%>
      <figure
        :if={@headline.kind == :goal and @headline.course}
        id="progress-course"
        class="progress-course"
      >
        <svg viewBox="0 0 100 40" preserveAspectRatio="none" aria-hidden="true">
          <line x1="0" y1="2" x2="100" y2="2" class="progress-course-target" />
          <polyline points={course_line(@headline)} class="progress-course-done" />
          <polyline points={course_projection(@headline)} class="progress-course-ahead" />
        </svg>
        <figcaption class="progress-course-caption">
          <span>{Calendar.strftime(hd(@headline.course.weeks).start, "%-d %b")}</span>
          <span class={@headline.course.on_course? && "progress-course-on"}>
            {if(@headline.course.on_course?, do: "On course for ", else: "At this pace, ")}{Calendar.strftime(
              @headline.course.projected_on,
              "%-d %b"
            )}
          </span>
        </figcaption>
      </figure>
      <div
        :if={@headline.kind == :reached or (@headline.kind == :goal and is_nil(@headline.course))}
        class={["progress-headline-meter", @headline.kind == :reached && "progress-headline-met"]}
        role="meter"
        aria-label={"Best toward #{Fmt.goal_title(@headline.goal)}"}
        aria-valuemin="0"
        aria-valuemax={@headline.goal.burpee_count_target}
        aria-valuenow={min(@headline.best, @headline.goal.burpee_count_target)}
      >
        <span style={"width: #{goal_percent(@headline)}%"}></span>
      </div>
      <p :if={@headline.kind == :first} class="progress-headline-note">
        That's your starting point. Two more sessions and the coach suggests a goal that fits.
      </p>
      <div
        :if={@headline.kind in [:reached, :best] and not @dismissed?}
        id="progress-next-goal"
        class="progress-next-goal"
      >
        <p>Next: {Fmt.goal_title(@headline.next)} {Fmt.goal_by(@headline.next)}.</p>
        <div class="home-review-actions">
          <button
            id="progress-set-goal"
            type="button"
            class="home-primary-action"
            phx-click="progress_set_goal"
          >
            Set this goal
          </button>
          <button
            :if={@headline.kind == :reached}
            id="progress-not-now"
            type="button"
            class="home-text-action"
            phx-click="progress_not_now"
          >
            Not now
          </button>
          <.link
            :if={@headline.kind == :best}
            id="progress-choose-goal"
            patch={~p"/coach"}
            class="home-text-action"
          >
            Choose my own
          </.link>
        </div>
      </div>
    </section>
    """
  end

  # The course chart: x runs from the first counted week to the projected week, y from a
  # little under the lowest weekly best up to the target (drawn at the top, y = 2).
  defp course_line(%{course: course} = headline),
    do: course.weeks |> Enum.map(&course_xy(headline, &1.start, &1.best)) |> Enum.join(" ")

  defp course_projection(%{course: course, goal: goal} = headline) do
    last = List.last(course.weeks)

    [
      course_xy(headline, last.start, last.best),
      course_xy(headline, course.projected_on, goal.burpee_count_target)
    ]
    |> Enum.join(" ")
  end

  defp course_xy(%{course: course, goal: goal}, date, value) do
    from = hd(course.weeks).start
    span = max(Date.diff(course.projected_on, from), 1)
    low = (course.weeks |> Enum.map(& &1.best) |> Enum.min()) * 0.9
    x = Date.diff(date, from) / span * 100
    y = 2 + (goal.burpee_count_target - value) / max(goal.burpee_count_target - low, 1) * 36
    "#{Float.round(x * 1.0, 2)},#{Float.round(y * 1.0, 2)}"
  end

  defp headline_number(%{kind: :first, reps: reps}), do: reps
  defp headline_number(%{best: best}), do: best

  defp headline_label(%{kind: :goal, goal: goal}),
    do:
      "#{type_sentence(goal.burpee_type)} in #{div(goal.duration_sec_target, 60)} min, #{Fmt.goal_by(goal)}"

  defp headline_label(%{kind: :reached, goal: goal, reached_on: on}),
    do:
      "#{type_sentence(goal.burpee_type)} in #{div(goal.duration_sec_target, 60)} min. Goal reached #{Calendar.strftime(on, "%-d %b")}#{early(goal.date_target, on)}."

  defp headline_label(%{kind: :best, burpee_type: type}),
    do: "Your best #{String.downcase(type_sentence(type))} in 20 min"

  defp headline_label(%{kind: :first, burpee_type: type}),
    do: "#{type_sentence(type)} in your first workout"

  defp type_sentence(:six_count), do: "Six-count"
  defp type_sentence(:navy_seal), do: "Navy SEAL"

  defp early(target, on) do
    case Date.diff(target, on) do
      days when days <= 0 -> ""
      1 -> ", a day early"
      days when days < 7 -> ", #{days} days early"
      days when days < 14 -> ", a week early"
      days -> ", #{div(days, 7)} weeks early"
    end
  end

  defp summary_line?(state),
    do:
      Map.get(state, :progress_summary_loading?, false) or
        not is_nil(Map.get(state, :progress_summary))

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

    densities = series |> Enum.flat_map(& &1.points) |> Enum.map(& &1.density)
    axis_min = if Enum.min(densities, fn -> 0 end) >= 100, do: 100, else: 0

    axis_max =
      max(
        if(axis_min == 100, do: 220, else: 100),
        ceil(Enum.max(densities, fn -> 0 end) / 20) * 20
      )

    assigns =
      assigns
      |> assign(
        :series,
        plot_series(series, axis_min, axis_max, assigns.period_start, assigns.now)
      )
      |> assign(:axis_min, axis_min)
      |> assign(:axis_max, axis_max)

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
          <div id="home-history-trend-axis" class="home-history-trend-axis" aria-hidden="true">
            <span>{@axis_max}</span>
            <span>{div(@axis_max + @axis_min, 2)}</span>
            <span>{@axis_min}</span>
          </div>
          <div class="home-history-plot-area">
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
              <polyline
                :for={series <- @series}
                :if={series.points != []}
                class={"home-history-line-#{String.replace(Atom.to_string(series.type), "_", "-")}"}
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
                  "home-history-point-#{String.replace(Atom.to_string(series.type), "_", "-")}"
                ]}
              >
                <span aria-hidden="true"></span>
              </button>
            <% end %>
          </div>
        </div>
        <%!-- Names the lines only when there are two to tell apart. --%>
        <div
          :if={Enum.count(@series, &(&1.points != [])) > 1}
          class="home-history-legend"
          aria-label="Workout types"
        >
          <span :for={series <- @series} :if={series.points != []} id={series.dom_id}>
            {series.label}
          </span>
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

  defp plot_series(series, axis_min, axis_max, period_start, now) do
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
            y: 88 - (point.density - axis_min) / (axis_max - axis_min) * 75
          })
        end)

      Map.merge(series, %{points: plotted, line: Enum.map_join(plotted, " ", &"#{&1.x},#{&1.y}")})
    end)
  end

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
