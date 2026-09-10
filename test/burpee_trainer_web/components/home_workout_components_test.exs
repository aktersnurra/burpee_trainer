defmodule BurpeeTrainerWeb.HomeWorkoutComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.Workouts.{Inspection, WorkoutPlan}
  alias BurpeeTrainerWeb.HomeWorkoutComponents

  test "weekly progress uses actual seconds and ISO week, with bounded visual fill" do
    for {completed, target, fill, now} <- [
          {1935, 4800, "40.3125%", "1935"},
          {6000, 4800, "100%", "4800"},
          {0, 0, "0%", "0"}
        ] do
      html =
        render_component(&HomeWorkoutComponents.week_progress/1,
          slot: %{completed_sec: completed, weekly_target_sec: target, week_start: ~D[2026-09-07]}
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(html, "[role=progressbar]") |> LazyHTML.attribute("aria-valuenow") ==
               [now]

      assert LazyHTML.query(html, "[role=progressbar]") |> LazyHTML.attribute("aria-valuemax") ==
               [to_string(target)]

      assert LazyHTML.query(html, "#home-week-fill") |> LazyHTML.attribute("style") == [
               "width: #{fill}"
             ]

      assert LazyHTML.query(html, "#home-week-number") |> text() == "Week 37"
    end
  end

  test "four compact columns retain cadence, interval and ordered nonuniform recoveries" do
    events = [work(2, 5_000_000, 10), rest(10_000), work(3, 6_125_000, 18.375), rest(11_250)]
    rows = rows(events ++ events ++ [work(2, 5_000_000, 9)])
    [group, final] = rows
    assert group.count == 2
    html = inspection(rows, MapSet.new([group.id]))

    assert LazyHTML.query(html, "#home-inspection > table > thead th") |> text() ==
             "SetsRepsCadenceRest"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-reps") |> text() ==
             "23"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-rest") |> text() ==
             "10s11.25s"

    assert LazyHTML.query(html, "##{group.id}-details li .home-constituent-prescription")
           |> text() ==
             "2 reps · 5s cadence · Interval 10s · 10s rest " <>
               "3 reps · 6.125s cadence · Interval 18.375s · 11.25s rest " <>
               "2 reps · 5s cadence · Interval 10s · 10s rest " <>
               "3 reps · 6.125s cadence · Interval 18.375s · 11.25s rest"

    assert LazyHTML.query(html, "##{final.id} .home-prescription-rest") |> text() == "—"
    assert LazyHTML.query(html, "##{final.id} .home-interval") |> text() == "Interval 9s"
    assert LazyHTML.query(html, "caption") |> LazyHTML.text() =~ "prescribed"
  end

  test "simple adjacent sets and separate final recovery are not fabricated" do
    rows = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10), rest(1250)])
    [group, recovery] = rows
    html = inspection(rows, MapSet.new([group.id]))
    assert LazyHTML.query(html, "##{group.id} button") |> LazyHTML.text() =~ "2 sets"
    assert LazyHTML.query(html, "##{recovery.id} th") |> text() == "Final recovery"
    assert LazyHTML.query(html, "##{recovery.id} .home-prescription-rest") |> text() == "1.25s"
  end

  test "compiler-shortened terminal work exposes its exact interval without expanding a group" do
    attrs = %{
      "version" => 1,
      "name" => "Terminal active",
      "burpee_type" => "six_count",
      "target_reps" => 4,
      "target_duration_sec" => 40,
      "pacing_style" => "even",
      "rationale" => "Canonical presentation test.",
      "events" => [
        %{"kind" => "work", "reps" => 2, "sec_per_rep" => 8.0, "sec_per_burpee" => 5.0},
        %{"kind" => "rest", "duration_sec" => 10},
        %{"kind" => "work", "reps" => 2, "sec_per_rep" => 9.0, "sec_per_burpee" => 5.0}
      ]
    }

    assert {:ok, definition} = WorkoutDefinition.new(attrs)
    assert {:ok, program} = PlanCompiler.compile(definition)

    rows =
      Inspection.rows(%WorkoutPlan{
        id: "compiled",
        updated_at: ~U[2026-09-10 00:00:00Z],
        definition_json: attrs,
        program_json: ProgramHash.canonical_map(program)
      })

    [ordinary, terminal] = rows
    html = inspection(rows)

    assert LazyHTML.query(html, "##{ordinary.id} .home-interval.sr-only") |> text() ==
             "Interval 16s"

    assert LazyHTML.query(html, "##{terminal.id} .home-interval:not(.sr-only)") |> text() ==
             "Interval 14s"

    assert LazyHTML.query(html, "##{terminal.id} .home-prescription-cadence") |> text() ==
             "9s Interval 14s"
  end

  test "ordered constituent outline labels shared prescription and keeps exceptional intervals visible" do
    [group] = rows([work(2, 9_000_000, 14), work(2, 9_000_000, 14)])
    html = inspection([group], MapSet.new([group.id]))
    details = LazyHTML.query(html, "##{group.id}-details")

    assert LazyHTML.query(details, "ol[aria-label='Ordered constituent sets'] li .home-set-label")
           |> text() == "Set 1Set 2"

    assert LazyHTML.query(details, "table") |> Enum.empty?()

    assert LazyHTML.query(details, ".home-shared-prescription") |> text() ==
             "Prescription as above"

    for item <- LazyHTML.query(details, "li") do
      assert text(item) =~ "2 reps · 9s cadence · Interval 14s · No recovery"
    end

    assert LazyHTML.query(details, ".home-interval:not(.sr-only)") |> text() ==
             "Interval 14s Interval 14s"
  end

  test "group activation retains one native button with row-wide target and disclosure context" do
    [group] = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10)])
    html = inspection([group])
    button = LazyHTML.query(html, "##{group.id} > tr.home-group-summary button[type=button]")
    assert LazyHTML.attribute(button, "phx-click") == ["toggle_group"]
    assert LazyHTML.attribute(button, "aria-controls") == ["#{group.id}-details"]
    assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(button, "aria-describedby") == ["#{group.id}-prescription"]

    assert LazyHTML.query(html, "##{group.id}-prescription") |> text() ==
             "2 reps · 5s cadence · Interval 10s · No recovery"

    assert LazyHTML.query(html, "##{group.id}-details[hidden]") |> Enum.count() == 1
    expanded = inspection([group], MapSet.new([group.id]))
    assert LazyHTML.query(expanded, "button[aria-expanded=true]") |> Enum.count() == 1
    assert LazyHTML.query(expanded, "##{group.id}-details[hidden]") |> Enum.empty?()
  end

  test "alternative metadata uses exact known duration and reps without turning unknown into zero" do
    for {kind, duration, reps, expected} <- [
          {:plan, 1200, 120, "20 min · 120 reps"},
          {:video, 61, 4, "1 min 1 s · 4 reps"},
          {:video, 60, nil, "1 min · Reps unknown"},
          {:video, nil, nil, "Duration unknown · Reps unknown"}
        ] do
      html =
        render_component(&HomeWorkoutComponents.alternative/1,
          id: "home-alternative-#{kind}-1",
          item: %{
            source_id: 1,
            kind: kind,
            name: "Stored item",
            duration_sec: duration,
            reps: reps
          }
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(html, ".home-alternative-metadata") |> text() == expected

      assert LazyHTML.query(html, "button[phx-click=select_alternative]")
             |> LazyHTML.attribute("phx-value-kind") == [to_string(kind)]

      assert LazyHTML.query(html, ".home-alternative-name") |> text() == "Stored item"
    end
  end

  test "ordinary fractional and large duration values never use exponent notation or lose precision" do
    html = inspection(rows([work(100, 12_000_001, 1200.000001), rest(1), work(1, 1_000_000, 1)]))
    assert LazyHTML.query(html, ".home-prescription-cadence") |> LazyHTML.text() =~ "12.000001s"
    assert LazyHTML.query(html, ".home-interval") |> LazyHTML.text() =~ "Interval 1200.000001s"
    assert LazyHTML.query(html, ".home-prescription-rest") |> LazyHTML.text() =~ "0.001s"
    refute LazyHTML.text(html) =~ ~r/\d[eE][+-]?\d/
  end

  defp text(html), do: html |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp inspection(rows, expanded \\ MapSet.new()),
    do:
      render_component(&HomeWorkoutComponents.inspection/1, rows: rows, expanded: expanded)
      |> LazyHTML.from_fragment()

  defp work(reps, cadence, duration),
    do: %{
      "kind" => "work",
      "reps" => reps,
      "sec_per_rep_us" => cadence,
      "duration_sec" => duration
    }

  defp rest(ms), do: %{"kind" => "rest", "duration_ms" => ms}
  # Projection-only synthetic events also cover terminal recovery, forbidden by the compiler.
  defp rows(events),
    do:
      Inspection.rows(%WorkoutPlan{
        id: "test",
        updated_at: ~U[2026-09-10 00:00:00Z],
        definition_json: %{"events" => events},
        program_json: %{"events" => events}
      })
end
