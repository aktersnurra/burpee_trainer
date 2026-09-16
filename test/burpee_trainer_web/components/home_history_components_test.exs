defmodule BurpeeTrainerWeb.HomeHistoryComponentsTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BurpeeTrainer.Workouts.WorkoutSession
  alias BurpeeTrainerWeb.HomeHistoryComponents

  test "History renders a weekly grid, streak and one combined density trend" do
    doc = panel() |> LazyHTML.from_fragment()

    assert count(doc, "#home-history-weekly .home-history-week-cell") == 12
    assert text(doc, "#home-history-streak") == "0"
    assert text(doc, "#home-history-status") =~ "1A"
    assert count(doc, "#home-history-status ~ .home-history-periods") == 1
    assert text(doc, "#home-history-week-count") == "0 of 11 completed weeks"
    assert count(doc, ".home-history-week-oldest") == 0

    assert count(
             doc,
             "#home-history-week-mode[aria-label='Show daily minutes'][phx-click='history_week']"
           ) == 1

    assert count(doc, "figure#home-history-trend") == 1
    assert text(doc, "#home-history-trend-label") =~ "Training density"

    assert count(
             doc,
             "#home-history-density-sessions[aria-label='Show sessions'][phx-click='history_density_mode']"
           ) == 1

    assert count(doc, "#home-history-trend:not([hidden])") == 1
    assert count(doc, "#home-history-sessions-panel[hidden]") == 1
    assert count(doc, "#home-history-trend-open-sessions[aria-label='Show saved sessions']") == 1
    assert count(doc, "#home-history-trend-plot ~ .home-history-legend") == 1
    assert count(doc, "#home-history-trend-axis") == 1
    assert text(doc, "#home-history-trend-caption") =~ "12 weeks ago"
    assert text(doc, "#home-history-trend-caption") =~ "Now"
    assert count(doc, "#home-history-six-count") == 1
    assert count(doc, "#home-history-navy-seal") == 1
    assert count(doc, "#home-history-table thead.sr-only") == 1
    assert count(doc, "#home-history-close") == 0
    assert count(doc, "#home-history-sessions > tr.home-history-session-card") == 0
    assert count(doc, "#history-coach-guidance-form, #history-coach-memory") == 0
  end

  test "Sessions replace rather than follow the density chart when selected" do
    doc = panel(nil, [], true) |> LazyHTML.from_fragment()

    assert count(doc, "#home-history-trend[hidden]") == 1
    assert count(doc, "#home-history-sessions-panel:not([hidden])") == 1

    assert count(
             doc,
             "#home-history-density-back[aria-label='Show density graph'][phx-click='history_density_mode'] .hero-presentation-chart-line"
           ) == 1

    assert count(doc, "#home-history-sessions-panel #home-history-sessions[phx-update=stream]") ==
             1
  end

  test "daily drilldown replaces the grid metadata and uses the heading icon to return" do
    doc =
      panel(~D[2026-09-07], [%{date: ~D[2026-09-11], seconds: 120, minutes: 2}])
      |> LazyHTML.from_fragment()

    assert count(doc, "#home-history-week-mode[aria-label='Back to weekly grid']") == 1

    [commands] =
      doc |> LazyHTML.query("#home-history-week-mode") |> LazyHTML.attribute("phx-click")

    assert ["push", %{"event" => "history_week_back"}] = List.last(Jason.decode!(commands))

    assert count(
             doc,
             "#home-history-week-count, .home-history-week-current, .home-history-week-key"
           ) == 0

    assert count(doc, "#home-history-week-back") == 0
    assert text(doc, "#home-history-week-detail") =~ "Sep 7–13"
    assert count(doc, "#home-history-daily") == 1
    assert count(doc, "#home-history-week-grid") == 0

    assert doc
           |> LazyHTML.query("#home-history-day-axis span")
           |> Enum.map(&LazyHTML.text/1) == ["80", "40", "0"]

    assert count(doc, "#home-history-day-plot .home-history-day") == 1
    assert text(doc, "#home-history-day-2026-09-11 .home-history-day-value") == "2 min"
    assert text(doc, "#home-history-day-2026-09-11 .home-history-day-label") == "F"
    assert text(doc, "#home-history-day-note") == "Minutes by day"
  end

  test "a single 100-density point uses the approved 100–220 chart scale" do
    doc =
      render_component(&HomeHistoryComponents.trend_chart/1,
        points: %{six_count: [point(8, ~U[2026-09-09 12:00:00Z], 100)], navy_seal: []},
        empty?: false
      )
      |> LazyHTML.from_fragment()

    assert doc
           |> LazyHTML.query("#home-history-trend-axis span")
           |> Enum.map(&LazyHTML.text/1) == ["220", "160", "100"]

    assert attr(doc, "#home-history-point-8", "style") =~ "left: 50.0%; top: 88.0%"
  end

  test "density positions a lone recent point near Now for the selected period" do
    doc =
      render_component(&HomeHistoryComponents.trend_chart/1,
        points: %{six_count: [point(8, ~U[2026-09-09 12:00:00Z], 100)], navy_seal: []},
        empty?: false,
        period_start: ~D[2026-06-15],
        now: ~U[2026-09-10 12:00:00Z]
      )
      |> LazyHTML.from_fragment()

    [_, left] = Regex.run(~r/left: ([\d.]+)%/, attr(doc, "#home-history-point-8", "style"))
    assert {position, ""} = Float.parse(left)
    assert position > 95 and position <= 96
  end

  test "the trend retains point identities and an honest compact empty state" do
    points = %{six_count: [point(8, ~U[2026-09-09 12:00:00Z], 20)], navy_seal: []}

    doc =
      render_component(&HomeHistoryComponents.trend_chart/1, points: points, empty?: false)
      |> LazyHTML.from_fragment()

    assert count(doc, "#home-history-point-8[phx-value-id='8']") == 1
    assert attr(doc, "#home-history-point-8", "aria-label") =~ "Six-count, 2026-09-09T12:00:00Z"
    assert attr(doc, "#home-history-point-8", "style") =~ "left: 50.0%; top: 73.0%"
    assert count(doc, "#home-history-navy-seal") == 0

    empty =
      render_component(&HomeHistoryComponents.trend_chart/1,
        points: %{six_count: [], navy_seal: []},
        empty?: true
      )
      |> LazyHTML.from_fragment()

    assert count(empty, "#home-history-trend-plot svg, #home-history-trend-plot button") == 0
    assert text(empty, "#home-history-trend") =~ "No measured sessions in this period."
  end

  test "both density series have distinct related blue strokes and markers" do
    doc =
      render_component(&HomeHistoryComponents.trend_chart/1,
        points: %{
          six_count: [point(8, ~U[2026-09-09 12:00:00Z], 20)],
          navy_seal: [point(9, ~U[2026-09-10 12:00:00Z], 30)]
        },
        empty?: false
      )
      |> LazyHTML.from_fragment()

    assert count(doc, "polyline.home-history-line-six-count:not([stroke-dasharray])") == 1
    assert count(doc, "polyline.home-history-line-navy-seal[stroke-dasharray]") == 1
    assert count(doc, "#home-history-point-8.home-history-point-six-count") == 1
    assert count(doc, "#home-history-point-9.home-history-point-navy-seal") == 1
  end

  test "session cards preserve stream row and inspection identities with planned and actual comparison" do
    doc = row(session(), true)
    assert count(doc, "tbody > tr#saved-1.home-history-session-card") == 1
    assert count(doc, "tr > td[colspan='3']") == 1

    assert count(
             doc,
             "#home-history-inspect-1[aria-expanded=true][aria-controls=home-history-details-1]"
           ) == 1

    assert count(doc, "#home-history-details-1") == 0

    sheet =
      render_component(&HomeHistoryComponents.session_sheet/1,
        session: session(),
        confirm?: false,
        return_to: "#home-history-inspect-1",
        timezone: "Etc/UTC"
      )
      |> LazyHTML.from_fragment()

    assert count(sheet, "#home-history-sheet[role=dialog][aria-modal=true]") == 1
    assert count(sheet, "#home-history-sheet-details-1 [data-actual-reps='20']") == 1
    assert count(sheet, "#home-history-sheet-details-1 [data-actual-duration-sec='1200']") == 1
    assert text(sheet, ".home-history-density") =~ "20 reps / 20 min"

    assert Jason.decode!(attr(doc, "#saved-1", "phx-remove")) == [
             [
               "focus",
               %{
                 "to" =>
                   "#home-history:not([hidden]):not([inert]):has(#saved-1:focus-within) #home-history-heading"
               }
             ]
           ]
  end

  test "session details show only feedback actually saved with the session" do
    tagged =
      render_component(&HomeHistoryComponents.session_sheet/1,
        session: session(tags: "heat, low_energy", note_post: "Kept going"),
        confirm?: false,
        return_to: "#home-history-inspect-1",
        timezone: "Etc/UTC"
      )
      |> LazyHTML.from_fragment()

    assert tagged
           |> LazyHTML.query("#home-history-sheet-tags span")
           |> Enum.map(&LazyHTML.text/1) == ["Heat", "Low energy"]

    assert text(tagged, "#home-history-sheet-note") == "Kept going"

    plain =
      render_component(&HomeHistoryComponents.session_sheet/1,
        session: session(),
        confirm?: false,
        return_to: "#home-history-inspect-1",
        timezone: "Etc/UTC"
      )
      |> LazyHTML.from_fragment()

    assert count(plain, "#home-history-sheet-tags, #home-history-sheet-note") == 0
  end

  test "collapsed cards retain local completion date and time with measured density" do
    doc = row(session(), false)
    assert count(doc, "button[aria-expanded=false]") == 1
    assert count(doc, ".home-history-comparison") == 0
    assert text(doc, "button") =~ "Sep 8, 2026 at 9:00 PM"
    assert text(doc, "button") =~ "20"
    assert text(doc, "button") =~ "20:00"
    refute text(doc, "button") =~ "Density"
    assert count(doc, ".home-history-session-type, .home-history-session-chevron") == 0
  end

  test "collapsed cards honestly report unavailable density and local completion time" do
    unavailable = session(burpee_count_actual: nil, duration_sec_actual: nil, completed_at: nil)
    doc = row(unavailable, false)

    assert text(doc, "button") =~ "Completion date and time unavailable"
    refute text(doc, "button") =~ "Density unavailable"
  end

  defp panel(week_start \\ nil, week_days \\ [], show_sessions? \\ false) do
    render_component(&HomeHistoryComponents.panel/1,
      state: %{
        history_available?: true,
        history_return_to: "#home-history-toggle",
        history_period: "twelve_weeks",
        history_show_sessions?: show_sessions?,
        current_level: :level_1a,
        history_weeks: sample_weeks(),
        history_week_start: week_start,
        history_week_days: week_days,
        history_session_return_to: "#home-history-heading",
        history_streak: 0,
        history_selected_session: nil,
        history_confirm_delete?: false,
        history_error: nil,
        history_points: %{
          six_count: [point(1, ~U[2026-09-09 12:00:00Z], 20)],
          navy_seal: [point(2, ~U[2026-09-10 12:00:00Z], 30)]
        },
        history_summary: %{
          sessions: 5,
          total_reps: 100,
          active_time_sec: 1200,
          latest_density: 30
        },
        history_empty?: false,
        history_loaded_count: 0,
        history_expanded: MapSet.new(),
        history_has_more?: false,
        current_user: %{timezone: "Etc/UTC"},
        coach_guidance_form: Phoenix.Component.to_form(%{"text" => ""}, as: :coach_guidance),
        coach_guidance_status: nil,
        streams: %{history_sessions: [], coach_guidance_entries: []}
      }
    )
  end

  test "pagination exposes busy and terminal states without changing stream markup" do
    loading = panel_with_pagination(true) |> LazyHTML.from_fragment()
    terminal = panel_with_pagination(false) |> LazyHTML.from_fragment()

    assert count(
             loading,
             "#home-history-more[phx-click=history_more][phx-disable-with='Loading sessions…']"
           ) == 1

    assert count(terminal, "#home-history-pagination-terminal") == 0
    assert count(terminal, "#home-history-sessions[phx-update=stream]") == 1
  end

  defp panel_with_pagination(has_more?) do
    render_component(&HomeHistoryComponents.panel/1,
      state: %{
        history_available?: true,
        history_return_to: "#home-history-toggle",
        history_period: "twelve_weeks",
        history_show_sessions?: false,
        current_level: :level_1a,
        history_weeks: sample_weeks(),
        history_week_start: nil,
        history_week_days: [],
        history_session_return_to: "#home-history-heading",
        history_streak: 0,
        history_selected_session: nil,
        history_confirm_delete?: false,
        history_error: nil,
        history_points: %{six_count: [], navy_seal: []},
        history_summary: %{sessions: 1, total_reps: 20, active_time_sec: 1200, latest_density: 20},
        history_empty?: false,
        history_loaded_count: 1,
        history_expanded: MapSet.new(),
        history_has_more?: has_more?,
        current_user: %{timezone: "Etc/UTC"},
        coach_guidance_form: Phoenix.Component.to_form(%{"text" => ""}, as: :coach_guidance),
        coach_guidance_status: nil,
        streams: %{history_sessions: [], coach_guidance_entries: []}
      }
    )
  end

  defp sample_weeks do
    for offset <- 11..0//-1,
        do: %{
          start: Date.add(~D[2026-09-07], -7 * offset),
          minutes: 0,
          seconds: 0,
          open?: offset == 0,
          target?: false
        }
  end

  defp row(session, expanded?) do
    render_component(&HomeHistoryComponents.session_row/1,
      id: "saved-1",
      session: session,
      expanded?: expanded?,
      timezone: "America/New_York"
    )
    |> then(&LazyHTML.from_fragment("<table><tbody>#{&1}</tbody></table>"))
  end

  defp session(attrs \\ []) do
    struct!(
      %WorkoutSession{
        id: 1,
        state: :completed,
        source_kind: :manual,
        display_name_snapshot: "Saved snapshot",
        workout_type_snapshot: :navy_seal,
        burpee_type: :six_count,
        completed_at: ~U[2026-09-09 01:00:00Z],
        burpee_count_actual: 20,
        duration_sec_actual: 1200,
        burpee_count_planned: 100,
        duration_sec_planned: 1800
      },
      attrs
    )
  end

  defp point(id, at, density),
    do: %{id: id, completed_at: at, density: density, actual_reps: 20, actual_duration_sec: 1200}

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attr(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> hd()
end
