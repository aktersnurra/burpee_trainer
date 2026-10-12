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
        inert={not is_nil(@state.history_selected_session)}
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
        </div>
        <.history_header state={@state} />
        <p :if={@state.history_error} id="home-history-error" role="status">{@state.history_error}</p>
        <%= if is_nil(@state.history_error) and @state.history_available? do %>
          <div id="home-history-status" class="home-history-status">
            <p class="home-history-streak-line">
              <strong id="home-history-streak">{@state.history_streak}</strong>
              <span>week streak</span>
            </p>
          </div>
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
          <section id="home-history-weekly" aria-label="Weekly training">
            <div class="home-history-week-heading">
              <h2>Weekly training</h2>
              <button
                :if={@state.history_week_start == nil and @state.history_weeks != []}
                id="home-history-week-mode"
                type="button"
                aria-label="Show daily minutes"
                title="Show daily minutes"
                phx-click="history_week"
                phx-value-start={Date.to_iso8601(List.last(@state.history_weeks).start)}
              >
                <.icon name="hero-chart-bar" class="size-5" />
              </button>
              <button
                :if={@state.history_week_start}
                id="home-history-week-mode"
                type="button"
                aria-label="Back to weekly grid"
                title="Back to weekly grid"
                phx-mounted={JS.focus(to: "#home-history-week-mode")}
                phx-click={JS.push("history_week_back")}
              >
                <.icon name="hero-squares-2x2" class="size-5" />
              </button>
            </div>
            <p
              :if={is_nil(@state.history_week_start) and completed_week_summary(@state.history_weeks)}
              id="home-history-week-count"
              class="home-history-week-count"
            >
              {completed_week_summary(@state.history_weeks)}
            </p>
            <p :if={is_nil(@state.history_week_start)} class="home-history-week-current">
              {current_week_label(@state.history_weeks)}
            </p>
            <%= if @state.history_week_start do %>
              <p id="home-history-week-detail">
                {week_date_range(@state.history_week_start)} · {week_duration(
                  @state.history_weeks,
                  @state.history_week_start
                )} trained
              </p>
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
              <p id="home-history-day-note">Minutes by day</p>
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
            <p
              :if={is_nil(@state.history_week_start) and length(@state.history_weeks) > 12}
              class="home-history-week-oldest"
            >
              {oldest_week_label(@state.history_weeks)}
            </p>
            <div
              :if={is_nil(@state.history_week_start)}
              class="home-history-week-key"
              aria-label="Minutes per week: 0, 20, 40, 60, 80 or more"
            >
              <span>0</span>
              <i class="home-history-tone-0"></i>
              <i class="home-history-tone-20"></i>
              <i class="home-history-tone-40"></i>
              <i class="home-history-tone-60"></i>
              <i class="home-history-tone-80"></i>
              <span>80 min</span>
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
            <h2>Training density</h2>
            <button
              id="home-history-density-back"
              type="button"
              aria-label="Show density graph"
              title="Show density graph"
              phx-mounted={
                @state.history_show_sessions? && JS.focus(to: "#home-history-density-back")
              }
              phx-click="history_density_mode"
              phx-value-mode="chart"
            >
              <.icon name="hero-presentation-chart-line" class="size-5" />
            </button>
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
            <div class="home-history-session-columns" aria-hidden="true">
              <span>Workout</span><span>Reps</span><span>Time</span>
            </div>
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
                  expanded?={MapSet.member?(@state.history_expanded, session.id)}
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
      <.session_sheet
        :if={@state.history_selected_session}
        session={@state.history_selected_session}
        insight={@state.history_selected_insight}
        confirm?={@state.history_confirm_delete?}
        timezone={@state.current_scope.user.timezone}
        return_to={@state.history_session_return_to}
        error={@state.history_error}
      />
    </section>
    """
  end

  attr(:session, BurpeeTrainer.Workouts.WorkoutSession, required: true)
  attr(:insight, :any, default: nil)
  attr(:confirm?, :boolean, required: true)
  attr(:timezone, :string, required: true)
  attr(:return_to, :string, required: true)
  attr(:error, :string, default: nil)

  def session_sheet(assigns) do
    tags =
      (assigns.session.tags || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    assigns = assign(assigns, :tags, tags)

    ~H"""
    <div
      id="home-history-sheet-backdrop"
      class="home-history-sheet-backdrop"
      phx-click={close_session_sheet(@return_to)}
    >
    </div>
    <section
      id="home-history-sheet"
      class="home-history-sheet"
      role="dialog"
      aria-modal="true"
      aria-label="Session details"
      phx-window-keydown={
        if(@confirm?, do: "history_cancel_delete", else: close_session_sheet(@return_to))
      }
      phx-key="Escape"
      phx-remove={
        @confirm? &&
          JS.remove_attribute("inert", to: "#home-history-body")
          |> JS.remove_attribute("inert", to: "#home-history-close")
          |> JS.focus(to: "#home-history-heading")
      }
    >
      <.focus_wrap
        id="home-history-sheet-focus"
        phx-mounted={JS.focus(to: "#home-history-sheet-close")}
      >
        <div class="home-history-sheet-actions">
          <button
            :if={not @confirm?}
            id="home-history-delete"
            type="button"
            aria-label="Delete saved session"
            phx-click="history_confirm_delete"
          >
            <.icon name="hero-trash" class="size-5" />
          </button>
          <button
            id="home-history-sheet-close"
            type="button"
            aria-label="Close session details"
            phx-click={close_session_sheet(@return_to)}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <p :if={@error} id="home-history-sheet-error" role="status">{@error}</p>
        <%= if @confirm? do %>
          <h2>Delete this session?</h2>
          <p>
            This removes the session from History and updates your weekly progress. This cannot be undone.
          </p>
          <div class="home-history-sheet-actions">
            <button id="home-history-delete-cancel" type="button" phx-click="history_cancel_delete">
              Cancel
            </button>
            <button
              id="home-history-delete-confirm"
              type="button"
              phx-click="history_delete_session"
            >
              Delete session
            </button>
          </div>
        <% else %>
          <h2>{display_name(@session)}</h2>
          <p>{local_completion(@session, @timezone)}</p>
          <section :if={@insight} id="history-insight" class="mt-4">
            <h3 id="history-insight-headline">{@insight.headline}</h3>
            <ul id="history-insight-points" class="mt-2 space-y-2">
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
        <% end %>
      </.focus_wrap>
    </section>
    """
  end

  defp open_session_sheet do
    JS.set_attribute({"inert", ""}, to: "#home-history-body")
    |> JS.set_attribute({"inert", ""}, to: "#home-history-close")
    |> JS.push("history_session")
  end

  defp close_session_sheet(return_to) do
    JS.remove_attribute("inert", to: "#home-history-body")
    |> JS.remove_attribute("inert", to: "#home-history-close")
    |> JS.focus(to: return_to)
    |> JS.push("history_close_session")
  end

  defp day_duration(seconds) when seconds < 60, do: "#{seconds} sec"
  defp day_duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp day_duration(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} sec"

  defp day_bar_height(seconds) when seconds > 0, do: min(max(seconds * 100 / 4_800, 1), 100)
  defp day_bar_height(_seconds), do: 0

  defp week_duration(weeks, date) do
    seconds = weeks |> Enum.find(&(&1.start == date)) |> Map.fetch!(:seconds)

    if rem(seconds, 60) == 0,
      do: "#{div(seconds, 60)} min",
      else: "#{div(seconds, 60)} min #{rem(seconds, 60)} sec"
  end

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

  # The dates are already in the progress row above; the label only marks the open cell.
  defp current_week_label([]), do: ""
  defp current_week_label(_weeks), do: "This week"

  defp oldest_week_label([week | _]), do: "#{week_date_range(week.start)} · oldest shown"

  defp week_date_range(start) do
    last = Date.add(start, 6)
    first_label = Calendar.strftime(start, "%b %-d")
    last_label = Calendar.strftime(last, if(start.month == last.month, do: "%-d", else: "%b %-d"))
    "#{first_label}–#{last_label}"
  end

  attr(:state, :map, required: true)

  # Level, this week and goals at a glance, then the coach summary (or, with nothing to
  # summarize yet, an invitation): the only way into Coach.
  defp history_header(assigns) do
    ~H"""
    <header id="history-header" class="history-header">
      <p class="history-header-facts">
        <span id="history-level">{Fmt.level(@state.current_level)}</span>
      </p>
      <ul :if={@state.history_goals != []} id="history-goals" class="history-header-goals">
        <li :for={goal <- @state.history_goals}>{Fmt.goal(goal)}</li>
      </ul>
      <%!-- Coach opens here, under its summary, like the workout card on Home: /coach is History with Coach open.
           The summary and Coach share one paper surface, so the summary reads as something that opens. --%>
      <div id="history-coach" class="history-coach">
        <.link
          id="history-coach-summary"
          patch={if(coach_open?(@state), do: ~p"/progress", else: ~p"/coach")}
          class="history-coach-summary"
          aria-expanded={to_string(coach_open?(@state))}
          aria-controls="home-coach-panel"
          phx-click={coach_open?(@state) && fold_coach()}
        >
          <BurpeeTrainerWeb.HomeCoachComponents.summary_body
            :if={summary_line?(@state)}
            summary={@state.progress_summary}
            loading?={@state.progress_summary_loading?}
          />
          <span :if={not summary_line?(@state)} class="coach-summary-invitation">
            Tell the coach what you're training for
          </span>
          <.icon name="hero-chevron-down" class="history-coach-summary-arrow size-4" />
        </.link>
        <div :if={coach_open?(@state)} id="history-coach-expansion" class="history-coach-expansion">
          <div class="history-coach-expansion-content">
            <BurpeeTrainerWeb.HomeCoachComponents.panel state={@state} />
          </div>
        </div>
      </div>
    </header>
    """
  end

  # LiveView holds the patch's reply until a running transition ends, so Coach folds away
  # before it is removed and History below slides up instead of snapping.
  defp fold_coach do
    JS.transition("history-coach-closing", to: "#history-coach-expansion", time: 200)
  end

  defp coach_open?(state), do: Map.get(state, :coach_open?, false)

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

    start_label =
      case assigns.period do
        "all" -> "First session"
        "year" -> "1 year ago"
        _ -> "12 weeks ago"
      end

    assigns =
      assigns
      |> assign(
        :series,
        plot_series(series, axis_min, axis_max, assigns.period_start, assigns.now)
      )
      |> assign(:axis_min, axis_min)
      |> assign(:axis_max, axis_max)
      |> assign(:start_label, start_label)

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
          <span class="font-semibold">Training density</span>
          <button
            id="home-history-density-sessions"
            type="button"
            aria-label="Show sessions"
            title="Show sessions"
            phx-mounted={not @show_sessions? && JS.focus(to: "#home-history-density-sessions")}
            phx-click="history_density_mode"
            phx-value-mode="sessions"
          >
            <.icon name="hero-list-bullet" class="size-5" />
          </button>
        </span>
        <span class="home-history-trend-subtitle">Reps / 20 min</span>
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
                phx-click={open_session_sheet()}
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
        <div id="home-history-trend-caption" class="home-history-trend-caption">
          <span>{@start_label}</span>
          <span>Now</span>
        </div>
        <div class="home-history-legend" aria-label="Workout types">
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
          phx-click={open_session_sheet()}
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
      </td>
    </tr>
    """
  end

  attr(:id, :string, required: true)
  attr(:session, BurpeeTrainer.Workouts.WorkoutSession, required: true)

  def session_details(assigns) do
    assigns = assign(assigns, density: History.points([assigns.session]))

    ~H"""
    <dl id={@id} class="home-history-comparison">
      <div>
        <dt>Actual</dt>
        <dd data-actual-reps={@session.burpee_count_actual}>
          Reps · {@session.burpee_count_actual || "—"}
        </dd>
        <dd data-actual-duration-sec={@session.duration_sec_actual}>
          Duration · {Fmt.duration_sec(@session.duration_sec_actual)}
        </dd>
      </div>
      <div>
        <dt>Planned</dt>
        <dd>Reps · {@session.burpee_count_planned || "—"}</dd>
        <dd>Duration · {Fmt.duration_sec(@session.duration_sec_planned)}</dd>
      </div>
    </dl>
    <p class="home-history-density">
      {case @density do
        [point] -> "Density #{point.density} reps / 20 min"
        [] -> "Density unavailable"
      end}
    </p>
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
      {:ok, local_datetime} -> Calendar.strftime(local_datetime, "%b %-d, %Y at %-I:%M %p")
      {:error, _reason} -> "Completion date and time unavailable"
    end
  end

  defp local_completion(_session, _timezone), do: "Completion date and time unavailable"
end
