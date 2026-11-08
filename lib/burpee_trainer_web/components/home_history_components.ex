defmodule BurpeeTrainerWeb.HomeHistoryComponents do
  @moduledoc "Progress: level and streak, each type's best and goal, the coach's look back, the days trained, the reps chart and saved-session inspection."

  use BurpeeTrainerWeb, :html

  alias BurpeeTrainerWeb.Fmt
  alias Phoenix.LiveView.JS

  # Where the chart's top (each type's goal) and bottom lines sit, in percent of its height.
  @plot_top 4
  @plot_bottom 96

  # The day grid's weeks: as many as fit a phone, and as many as fit the 640px column.
  @phone_weeks 18
  @wide_weeks 34

  @doc "How many recent weeks the day grid holds: those of the widest screen."
  def grid_weeks, do: @wide_weeks

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
            aria-label={"Progress, #{Fmt.level(@state.current_level)}"}
          >
            <%!-- Progress is titled by where you stand: your level. --%>

            <span id="history-level">{Fmt.level(@state.current_level)}</span>
          </h1>
          <%!-- Weeks in a row at 80 minutes; nothing while there is no run. --%>
          <span
            :if={Map.get(@state, :history_streak, 0) > 0}
            id="history-streak"
            class="history-streak"
            title={"#{@state.history_streak} #{if(@state.history_streak == 1, do: "week", else: "weeks")} in a row at the weekly target"}
            aria-label={"#{@state.history_streak} #{if(@state.history_streak == 1, do: "week", else: "weeks")} in a row at the weekly target"}
          >
            <.icon name="hero-fire" class="size-5" />
            <span aria-hidden="true">
              {@state.history_streak} {if(@state.history_streak == 1, do: "week", else: "weeks")}
            </span>
          </span>
        </div>
        <.history_header state={@state} />
        <p :if={@state.history_error} id="home-history-error" role="status">{@state.history_error}</p>
        <%= if is_nil(@state.history_error) and @state.history_available? do %>
          <.week_grid weeks={@state.history_grid_weeks} />
          <section
            id="home-history-reps"
            class="home-history-reps"
            aria-labelledby="home-history-reps-heading"
          >
            <h2 id="home-history-reps-heading" class="home-history-trend-heading">
              Reps per 20 minutes
            </h2>
            <.trend_chart
              points={@state.history_points}
              empty?={@state.history_empty?}
              period_start={List.first(@state.history_weeks).start}
              now={@state.history_snapshot_now}
              gauges={@state.history_gauges}
            />
            <%!-- The session a point opened: when, its reps and time, and the bin. --%>
            <table
              :if={@state.history_selected_session}
              id="home-history-opened"
              class="home-history-table"
            >
              <caption class="sr-only">The session you opened</caption>
              <tbody>
                <.session_row
                  id={"home-history-session-#{@state.history_selected_session.id}"}
                  session={@state.history_selected_session}
                  timezone={@state.current_scope.user.timezone}
                  expanded?={true}
                  confirm?={@state.history_confirm_delete?}
                />
              </tbody>
            </table>
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
      </div>
    </section>
    """
  end

  defp open_session, do: JS.push("history_session")

  attr(:weeks, :list, required: true)

  # The days you trained, as GitHub draws contributions: a column a week from Monday, Monday on
  # top, each day in its type's colour (split diagonally for both). A phone holds the latest
  # 18 weeks and the 640px column 34; the cells stay square, so a wider screen shows more weeks.
  defp week_grid(assigns) do
    older = max(length(assigns.weeks) - @phone_weeks, 0)

    assigns =
      assign(assigns,
        weeks: Enum.with_index(assigns.weeks, &{&1, &2 < older}),
        phone_minutes: assigns.weeks |> Enum.drop(older) |> grid_minutes(),
        wide_minutes: grid_minutes(assigns.weeks),
        phone_weeks: length(assigns.weeks) - older,
        wide_weeks: length(assigns.weeks)
      )

    ~H"""
    <section :if={@weeks != []} id="home-history-weekly" aria-labelledby="home-history-weekly-heading">
      <h2 id="home-history-weekly-heading">Days you trained</h2>
      <div id="home-history-week-grid" class="home-history-days">
        <span
          :for={label <- ["", "Mon", "", "Wed", "", "Fri", "", ""]}
          class="home-history-dayname"
          aria-hidden="true"
        >{label}</span>
        <%= for {week, older?} <- @weeks do %>
          <span
            class={["home-history-month", older? && "home-history-days-older"]}
            aria-hidden="true"
          >{month_label(week)}</span>
          <span
            :for={day <- week.days}
            id={"home-history-day-#{Date.to_iso8601(day.date)}"}
            class={[
              "home-history-day",
              day_kind(day),
              older? && "home-history-days-older"
            ]}
            data-minutes={day.minutes}
            role={!day.future? && "img"}
            aria-label={!day.future? && day_title(day)}
            aria-hidden={day.future? && "true"}
            title={!day.future? && day_title(day)}
          ></span>
        <% end %>
      </div>
      <div class="home-history-days-key">
        <span class="home-history-days-phone">{@phone_minutes} min in {@phone_weeks} weeks</span>
        <span class="home-history-days-wide">{@wide_minutes} min in {@wide_weeks} weeks</span>
        <span class="home-history-days-scale" aria-hidden="true">
          <i class="home-history-day-six"></i>Six-count <i class="home-history-day-seal"></i>Navy SEAL <i class="home-history-day-both"></i>Both
        </span>
      </div>
    </section>
    """
  end

  defp grid_minutes(weeks), do: weeks |> Enum.sum_by(& &1.seconds) |> div(60)

  # A month's name over the week whose Monday is its first.
  defp month_label(week), do: if(week.start.day <= 7, do: Calendar.strftime(week.start, "%b"))

  defp day_kind(%{future?: true}), do: "home-history-day-future"
  defp day_kind(%{types: [:six_count, :navy_seal]}), do: "home-history-day-both"
  defp day_kind(%{types: [:six_count]}), do: "home-history-day-six"
  defp day_kind(%{types: [:navy_seal]}), do: "home-history-day-seal"
  defp day_kind(_day), do: nil

  defp day_title(day) do
    trained =
      case day.types do
        [] -> ""
        types -> Enum.map_join(types, " and ", &type_sentence/1) <> ", "
      end

    "#{Calendar.strftime(day.date, "%a %-d %b")}: #{trained}#{day_duration(day.seconds)}"
  end

  defp day_duration(0), do: "rest"
  defp day_duration(seconds) when seconds < 60, do: "#{seconds} sec"
  defp day_duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp day_duration(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} sec"

  attr(:state, :map, required: true)

  # Each burpee type's best in 20 minutes side by side, then the coach's look back under the
  # page's only rule.
  defp history_header(assigns) do
    ~H"""
    <header id="history-header" class="history-header">
      <p class="history-best-label">Best in 20 minutes</p>
      <div id="progress-gauges" class="progress-gauges">
        <.gauge
          :for={gauge <- @state.history_gauges}
          gauge={gauge}
          next={BurpeeTrainer.Levels.next(@state.current_level)}
        />
      </div>
      <%!-- The look back is the way into the coach, which opens on it; without the app's
           coach it is Claude's and only reads here. --%>
      <.link
        :if={summary_line?(@state) and BurpeeTrainer.Coach.enabled?(@state.current_scope)}
        id="history-look-back"
        patch={~p"/coach?from=progress"}
        data-vt="forward"
        class="history-look-back"
      >
        <.look_back state={@state} chevron?={true} />
      </.link>
      <div
        :if={summary_line?(@state) and not BurpeeTrainer.Coach.enabled?(@state.current_scope)}
        class="history-look-back"
      >
        <.look_back state={@state} chevron?={false} />
      </div>
    </header>
    """
  end

  attr(:state, :map, required: true)
  attr(:chevron?, :boolean, required: true)

  defp look_back(assigns) do
    ~H"""
    <p class="history-look-back-label">
      Coach<.icon :if={@chevron?} name="hero-chevron-right-mini" class="size-4" />
    </p>
    <p id="history-coach-summary" class="history-coach-summary">
      <BurpeeTrainerWeb.HomeCoachComponents.summary_body
        summary={@state.progress_summary}
        loading?={@state.progress_summary_loading?}
        field={:review}
      />
    </p>
    """
  end

  attr(:gauge, :map, required: true)
  attr(:next, :atom, default: nil)

  # One burpee type: its mark and name, its best, what the next level needs (ticked once the
  # best is past it), then its goal, or the next goal to set. The next level is said here
  # once, where it is measured. See docs/specs/2026-11-06-light-screens-design.md.
  defp gauge(assigns) do
    assigns = assign(assigns, :needs, needs(assigns.gauge, assigns.next))

    ~H"""
    <section
      id={"progress-gauge-#{@gauge.burpee_type}"}
      class="progress-gauge"
      data-kind={@gauge.kind}
      aria-label={type_sentence(@gauge.burpee_type)}
    >
      <%!-- The key: the type's mark, as its line on the chart below. --%>
      <p class={["progress-gauge-type", "progress-key-#{series_class(@gauge.burpee_type)}"]}>
        {type_sentence(@gauge.burpee_type)}
      </p>
      <p class={["progress-gauge-number", @gauge.kind == :reached && "progress-gauge-met"]}>
        {gauge_number(@gauge)}
      </p>
      <p :if={@needs} class="progress-gauge-needs" data-met={to_string(elem(@needs, 0))}>
        <.icon :if={elem(@needs, 0)} name="hero-check" class="size-4" />
        <span :if={elem(@needs, 0)} class="sr-only">Past it:</span>
        {elem(@needs, 1)}
      </p>
      <p :if={gauge_label(@gauge)} class="progress-gauge-label">{gauge_label(@gauge)}</p>
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
    </section>
    """
  end

  defp gauge_number(%{kind: :none}), do: "–"
  defp gauge_number(%{kind: :first, reps: reps}), do: reps
  defp gauge_number(%{best: best}), do: best

  defp gauge_label(%{kind: :goal, goal: goal}),
    do: "Goal #{goal.burpee_count_target} #{Fmt.goal_by(goal)}"

  defp gauge_label(%{kind: :reached, reached_on: on}),
    do: "Reached #{Calendar.strftime(on, "%-d %b")}"

  defp gauge_label(%{kind: :first}), do: "First session"
  defp gauge_label(%{kind: :none}), do: "No sessions yet"
  defp gauge_label(%{kind: :best}), do: nil

  # What the next level needs of this type, and whether the best in 20 minutes is past it.
  # A first session of another length says nothing about reps in 20 minutes.
  defp needs(_gauge, nil), do: nil

  defp needs(gauge, next) do
    need = BurpeeTrainer.Levels.threshold(next, gauge.burpee_type)
    best = Map.get(gauge, :best)
    {is_integer(best) and best >= need, "#{level_label(next)} needs #{need}"}
  end

  defp level_label(level), do: level |> Fmt.level() |> String.replace_prefix("Level ", "")

  defp type_sentence(:six_count), do: "Six-count"
  defp type_sentence(:navy_seal), do: "Navy SEAL"

  # The look back shows once the coach has written one; the note itself is for Home.
  defp summary_line?(state),
    do:
      Map.get(state, :progress_summary_loading?, false) or
        match?(%{review: review} when is_binary(review), Map.get(state, :progress_summary))

  attr(:points, :map, required: true)
  attr(:empty?, :boolean, required: true)
  attr(:period_start, :any, default: nil)
  attr(:now, :any, default: nil)
  attr(:gauges, :list, default: [])

  # One chart for both types on one time axis, each on its own scale: six-count reads off the
  # left axis as a solid navy line, Navy SEAL off the right as a dashed sky one, each axis in
  # its line's colour. Each scale tops out at the type's goal when it has one.
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
    bounds = time_bounds(series, assigns.period_start, assigns.now)

    plots =
      series
      |> plot_series(scales, bounds)
      |> Enum.filter(&(&1.points != []))
      |> Enum.map(fn series ->
        {lo, hi} = scales[series.type]
        Map.merge(series, %{lo: lo, hi: hi})
      end)

    assigns =
      assign(assigns,
        plots: plots,
        months: month_ticks(bounds),
        plot_top: @plot_top,
        plot_bottom: @plot_bottom
      )

    ~H"""
    <figure
      id="home-history-trend"
      phx-remove={removed_target_focus("home-history-trend")}
      class="home-history-trend"
      aria-labelledby="home-history-reps-heading"
    >
      <%= if @empty? or @plots == [] do %>
        <p class="home-history-trend-empty">No measured sessions in this period.</p>
      <% else %>
        <figcaption class="home-history-legend">
          <span
            :for={plot <- @plots}
            class={["home-history-legend-item", "progress-key-#{series_class(plot.type)}"]}
          >
            {plot.label}{if length(@plots) == 2,
              do: if(plot.type == :six_count, do: ", left", else: ", right")}
          </span>
        </figcaption>
        <div class="home-history-chart">
          <div
            :for={plot <- @plots}
            id={"home-history-trend-axis-#{series_class(plot.type)}"}
            class={[
              "home-history-trend-axis",
              "progress-key-#{series_class(plot.type)}",
              plot.type == :six_count && "home-history-axis-left",
              plot.type == :navy_seal && "home-history-axis-right"
            ]}
            aria-hidden="true"
          >
            <span style={"top: #{@plot_top}%"}>{plot.hi}</span>
            <span style="top: 50%">{div(plot.hi + plot.lo, 2)}</span>
            <span style={"top: #{@plot_bottom}%"}>{plot.lo}</span>
          </div>
          <div class="home-history-plot-area">
            <svg
              viewBox="0 0 100 100"
              preserveAspectRatio="none"
              aria-hidden="true"
              class="home-history-svg"
            >
              <line
                :for={y <- [@plot_top, 50, @plot_bottom]}
                x1="0"
                x2="100"
                y1={y}
                y2={y}
                class="home-history-grid"
              />
              <polyline
                :for={plot <- @plots}
                class={"home-history-line-#{series_class(plot.type)}"}
                stroke-dasharray={plot.type == :navy_seal && "5 4"}
                points={plot.line}
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                vector-effect="non-scaling-stroke"
              />
            </svg>
            <%= for plot <- @plots do %>
              <button
                :for={point <- plot.points}
                id={"home-history-point-#{point.id}"}
                phx-remove={removed_target_focus("home-history-point-#{point.id}")}
                type="button"
                phx-click={open_session()}
                phx-value-id={point.id}
                phx-value-source="point"
                aria-label={"#{plot.label}, #{DateTime.to_iso8601(point.completed_at)}, #{point.actual_reps} actual reps, #{point.actual_duration_sec} seconds actual duration, density #{point.density} reps per 20 min"}
                style={"left: #{point.x}%; top: #{point.y}%;"}
                class={["home-history-point", "home-history-point-#{series_class(plot.type)}"]}
              >
                <span aria-hidden="true"></span>
              </button>
            <% end %>
          </div>
          <div class="home-history-months" aria-hidden="true">
            <span :for={{x, label} <- @months} style={"left: #{x}%"}>{label}</span>
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
  attr(:confirm?, :boolean, default: false)

  # One row per session: its type in the chart's colour, when, its tags, reps and time.
  # Tapping a row selects it and shows its trash icon; the first tap on the icon arms it,
  # the second deletes.
  def session_row(assigns) do
    assigns =
      assign(assigns,
        display_name: display_name(assigns.session),
        completion: local_completion(assigns.session, assigns.timezone),
        tags: tags(assigns.session)
      )

    ~H"""
    <tr
      id={@id}
      phx-remove={removed_target_focus(@id)}
      class={["home-history-session-card", @expanded? && "home-history-session-selected"]}
    >
      <td colspan="3">
        <div class="home-history-session-line">
          <button
            id={"home-history-inspect-#{@session.id}"}
            type="button"
            class="home-history-session-toggle"
            phx-click={open_session()}
            phx-value-id={@session.id}
            phx-value-source="row"
            aria-pressed={to_string(@expanded?)}
          >
            <span class="home-history-session-summary">
              <span class={[
                "home-history-session-name",
                "progress-key-#{series_class(@session.burpee_type)}"
              ]}>
                {@display_name}
              </span>
              <small>
                {@completion}<span :for={tag <- @tags} class="home-history-session-tag">{tag}</span>
              </small>
            </span>
            <span class="home-history-session-reps">{@session.burpee_count_actual || "—"}</span>
            <span class="home-history-session-time">
              {Fmt.duration_sec(@session.duration_sec_actual)}
            </span>
          </button>
          <button
            :if={@expanded?}
            id={"home-history-delete-#{@session.id}"}
            type="button"
            class={[
              "home-icon-action home-history-session-delete",
              @confirm? && "home-history-session-delete-armed"
            ]}
            phx-click={if(@confirm?, do: "history_delete_session", else: "history_confirm_delete")}
            aria-label={if(@confirm?, do: "Confirm delete session", else: "Delete session")}
            title={if(@confirm?, do: "Tap again to delete", else: "Delete")}
          >
            <.icon name="hero-trash" class="size-5" />
          </button>
        </div>
      </td>
    </tr>
    """
  end

  defp tags(%{tags: tags}) when is_binary(tags),
    do:
      tags
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&(&1 |> String.replace("_", " ") |> String.capitalize()))

  defp tags(_session), do: []

  # The time axis: from the period's start (or the first point) to now (or the last point).
  defp time_bounds(series, period_start, now) do
    timestamps =
      series
      |> Enum.flat_map(& &1.points)
      |> Enum.map(&DateTime.to_unix(&1.completed_at, :microsecond))

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

    {first, last}
  end

  # A month's name under the time axis where the month starts. Over a year, only each
  # January shows, as its year.
  defp month_ticks({first, last}) when last <= first, do: []

  defp month_ticks({first, last}) do
    from = first |> DateTime.from_unix!(:microsecond) |> DateTime.to_date()
    to = last |> DateTime.from_unix!(:microsecond) |> DateTime.to_date()
    long? = Date.diff(to, from) > 366

    from
    |> Date.beginning_of_month()
    |> Stream.iterate(&(&1 |> Date.end_of_month() |> Date.add(1)))
    |> Stream.drop_while(&(Date.compare(&1, from) == :lt))
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.filter(&(not long? or &1.month == 1))
    |> Enum.map(fn month ->
      at = DateTime.new!(month, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:microsecond)
      label = if long?, do: Integer.to_string(month.year), else: Calendar.strftime(month, "%b")
      {Float.round((at - first) / (last - first) * 100, 2), label}
    end)
  end

  defp plot_series(series, scales, {first, last}) do
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

  defp series_class(type), do: type |> Atom.to_string() |> String.replace("_", "-")

  defp removed_target_focus(id),
    do:
      JS.focus(
        to:
          "#home-history:not([hidden]):not([inert]):has(##{id}:focus-within) #home-history-heading"
      )

  defp display_name(%{display_name_snapshot: name}) when is_binary(name) and name != "", do: name

  defp display_name(%{burpee_type: type}) when type in [:six_count, :navy_seal],
    do: type_sentence(type)

  defp display_name(%{source_kind: :video}), do: "Video workout"
  defp display_name(_), do: "Workout"

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
