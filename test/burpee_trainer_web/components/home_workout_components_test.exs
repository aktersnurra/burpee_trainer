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

  test "pacing columns retain cadence, interval and ordered nonuniform recoveries" do
    events = [work(2, 5_000_000, 10), rest(10_000), work(3, 6_125_000, 18.375), rest(11_250)]
    rows = rows(events ++ events ++ [work(2, 5_000_000, 9)])
    [group, final] = rows
    assert group.count == 2
    html = inspection(rows, MapSet.new([group.id]))

    assert LazyHTML.query(html, "#home-inspection > table > thead th") |> text() ==
             "SetsRepsPaceCadenceRest"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-reps") |> text() ==
             "23"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-rest") |> text() ==
             "10s11.25s"

    assert LazyHTML.query(html, "##{group.id}-details li .home-constituent-prescription")
           |> text() ==
             "2 reps · 5s pace · 5s cadence · Interval 10s · 10s rest " <>
               "3 reps · 6.125s pace · 6.125s cadence · Interval 18.375s · 11.25s rest " <>
               "2 reps · 5s pace · 5s cadence · Interval 10s · 10s rest " <>
               "3 reps · 6.125s pace · 6.125s cadence · Interval 18.375s · 11.25s rest"

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
      assert text(item) =~ "2 reps · 5s pace · 9s cadence · Interval 14s · No recovery"
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
             "2 reps · 5s pace · 5s cadence · Interval 10s · No recovery"

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

  test "validated pacing layouts merge only the real pause between sets" do
    even = definition_work(20, 8, 5)
    unbroken = definition_work(20, 8, 8)

    for {style, events, duration, rests, headers} <- [
          {"even", [even, definition_rest(48), even], 365, ["51s", "—"],
           "SetsRepsPaceCadenceRest"},
          {"even", [even, even], 317, ["3s", "—"], "SetsRepsPaceCadenceRest"},
          {"even", [even, definition_rest(20), definition_rest(28), even], 365, ["51s", "—"],
           "SetsRepsPaceCadenceRest"},
          {"unbroken", [unbroken, definition_rest(48), unbroken], 368, ["48s", "—"],
           "SetsRepsPaceRest"},
          {"unbroken", [even, definition_rest(48), unbroken], 368, ["51s", "—"],
           "SetsRepsPaceCadenceRest"},
          {"unbroken", [even], 157, ["—"], "SetsRepsPaceCadenceRest"},
          {"unbroken", [unbroken], 160, ["—"], "SetsRepsPaceRest"},
          {"even", [definition_rest(2), even, even], 319, ["2s", "3s", "—"],
           "SetsRepsPaceCadenceRest"}
        ] do
      plan = compiled_plan(style, events, duration)
      rows = Inspection.rows(plan)
      html = inspection(rows, MapSet.new(), style)
      assert LazyHTML.query(html, "thead th") |> text() == headers
      assert Enum.map(LazyHTML.query(html, ".home-prescription-rest > span"), &text/1) == rests
      assert Inspection.flatten(rows) == plan.program_json["events"]
      assert LazyHTML.query(html, "caption") |> text() =~ "not measured"
      assert LazyHTML.query(html, "caption") |> text() =~ "last burpee finishes"
    end
  end

  test "real compiled microsecond pace and summed recovery stay exact without scientific notation" do
    plan =
      compiled_plan(
        "even",
        [
          definition_work(1, 1200.000001, 1199.999999),
          definition_rest(0.001),
          definition_rest(0.002),
          definition_work(1, 1, 0.996999)
        ],
        1201
      )

    html = inspection(Inspection.rows(plan))
    assert LazyHTML.query(html, ".home-prescription-pace") |> text() =~ "1199.999999s"
    assert LazyHTML.query(html, ".home-prescription-cadence") |> text() =~ "1200.000001s"
    assert LazyHTML.query(html, ".home-prescription-rest") |> text() == "0.003002s —"
    refute text(html) =~ ~r/\d[eE][+-]?\d/
  end

  test "inspection keeps definitions accessible and exact timing reachable without permanent body copy" do
    html = inspection(Inspection.rows(compiled_plan("even", [definition_work(20, 8, 5)], 157)))

    assert LazyHTML.query(html, "#home-inspection[role=region][tabindex='0'][aria-label]")
           |> Enum.count() == 1

    assert LazyHTML.query(html, "#home-pacing-key") |> Enum.empty?()

    assert LazyHTML.query(html, "caption.sr-only") |> text() =~
             "Pace is prescribed active seconds"

    assert LazyHTML.query(html, ".home-interval:not(.sr-only)") |> text() == "Interval 157s"
  end

  test "terminal floating-point representation cannot invent a sub-microsecond rest" do
    plan = compiled_plan("even", [definition_work(4, 0.282, 0.154)], 1)
    html = inspection(Inspection.rows(plan))
    assert LazyHTML.query(html, ".home-prescription-rest") |> text() == "—"
  end

  test "real compiled grouped recovery is per set and unequal recovery never groups" do
    w = definition_work(20, 8, 5)

    for {second_rest, duration, counts} <- [{48, 573, [2, 1]}, {49, 574, [1, 1, 1]}] do
      plan =
        compiled_plan(
          "even",
          [w, definition_rest(48), w, definition_rest(second_rest), w],
          duration
        )

      rows = Inspection.rows(plan)
      assert Enum.map(rows, & &1.count) == counts
      html = inspection(rows, MapSet.new(Enum.map(rows, & &1.id)))
      assert LazyHTML.query(html, ".home-prescription-rest") |> text() =~ "51s"
      assert Inspection.flatten(rows) == plan.program_json["events"]
    end
  end

  defp definition_work(reps, cadence, active),
    do: %{"kind" => "work", "reps" => reps, "sec_per_rep" => cadence, "sec_per_burpee" => active}

  defp definition_rest(seconds), do: %{"kind" => "rest", "duration_sec" => seconds}

  defp compiled_plan(style, events, duration) do
    attrs = %{
      "version" => 1,
      "name" => "Pacing regression",
      "burpee_type" => "six_count",
      "target_reps" => Enum.sum(Enum.map(events, &Map.get(&1, "reps", 0))),
      "target_duration_sec" => duration,
      "pacing_style" => style,
      "rationale" => "Validated presentation regression",
      "events" => events
    }

    assert {:ok, definition} = WorkoutDefinition.new(attrs)
    assert {:ok, program} = PlanCompiler.compile(definition)

    %WorkoutPlan{
      id: "pacing",
      updated_at: ~U[2026-09-10 00:00:00Z],
      definition_json: WorkoutDefinition.canonical_map(definition),
      program_json: ProgramHash.canonical_map(program)
    }
  end

  defp text(html), do: html |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp inspection(rows, expanded \\ MapSet.new(), style \\ "even"),
    do:
      render_component(&HomeWorkoutComponents.inspection/1,
        rows: rows,
        expanded: expanded,
        pacing_style: style
      )
      |> LazyHTML.from_fragment()

  defp work(reps, cadence, duration),
    do: %{
      "kind" => "work",
      "reps" => reps,
      "sec_per_rep_us" => cadence,
      "sec_per_burpee_us" => min(cadence, round(duration * 1_000_000) - (reps - 1) * cadence),
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
