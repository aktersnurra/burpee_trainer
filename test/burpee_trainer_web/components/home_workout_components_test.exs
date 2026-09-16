defmodule BurpeeTrainerWeb.HomeWorkoutComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BurpeeTrainer.Coach.WorkoutRequest
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{ProgramHash, WorkoutDefinition}
  alias BurpeeTrainer.Workouts.{Inspection, WorkoutPlan}
  alias BurpeeTrainerWeb.HomeWorkoutComponents

  test "a reviewed candidate with varying active pace shows its exact verified budget" do
    params = %BurpeeTrainerWeb.HomeWorkoutRequest{reps: 10, duration: "2:00", sets: "2x5"}
    {:ok, request} = BurpeeTrainerWeb.HomeWorkoutRequest.request(params)

    definition = %{
      "version" => 1,
      "name" => "Varying pace",
      "burpee_type" => "six_count",
      "target_reps" => 10,
      "target_duration_sec" => 120,
      "pacing_style" => "unbroken",
      "rationale" => "Two continuous sets.",
      "events" => [
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 5, "sec_per_burpee" => 5},
        %{"kind" => "rest", "duration_sec" => 75},
        %{"kind" => "work", "reps" => 5, "sec_per_rep" => 4, "sec_per_burpee" => 4}
      ]
    }

    {:ok, validated} = WorkoutDefinition.new(definition)
    assert {:ok, _} = PlanCompiler.compile(validated)

    form =
      Phoenix.Component.to_form(BurpeeTrainerWeb.HomeWorkoutRequest.changeset(params, %{}),
        as: :home_workout
      )

    html =
      render_component(&HomeWorkoutComponents.authoring_form/1,
        form: form,
        stage: :review,
        candidate: %{
          definition: definition,
          request: request,
          original_request: request,
          alternative?: false
        }
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#home-workout-budget") |> text() =~ "0:45"
    assert LazyHTML.query(html, "#home-workout-budget") |> text() =~ "1:15"

    assert LazyHTML.query(html, "#home_workout_pace[placeholder='Varies by set']") |> Enum.count() ==
             1
  end

  test "confirmation shows exact interpreted targets and both elapsed-time rests" do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 140,
        "target_duration_sec" => 1_200,
        "pacing_style" => "unbroken",
        "recovery" => "required",
        "timed_rests" => [
          %{"start_sec" => 660, "duration_sec" => 60},
          %{"start_sec" => 1_080, "duration_sec" => 30}
        ],
        "requested_pace_sec" => nil
      })

    html =
      render_component(&HomeWorkoutComponents.request_confirmation/1, request: request)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#home-request-confirmation") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-request-reps") |> text() =~ "140"
    assert LazyHTML.query(html, "#home-request-duration") |> text() =~ "20 min"
    assert LazyHTML.query(html, "#home-request-rest-0") |> text() =~ "11:00"
    assert LazyHTML.query(html, "#home-request-rest-1") |> text() =~ "18:00"
    assert LazyHTML.query(html, "#home-request-timing") |> text() =~ "10 seconds"
    assert LazyHTML.query(html, "#home-request-timing") |> text() =~ "saved duration"
    assert LazyHTML.query(html, "#home-request-confirm") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-request-back") |> Enum.count() == 1
  end

  test "bootstrap confirmation replaces the request form until approved or sent back" do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    state = %{
      busy?: false,
      pending_request: %{request: request},
      bootstrap_form: Phoenix.Component.to_form(%{"prompt" => "test"}, as: :home_bootstrap),
      local_error: nil,
      alternatives_empty?: true,
      active_tab: :workouts,
      streams: %{alternatives: []}
    }

    html =
      render_component(&HomeWorkoutComponents.bootstrap/1, state: state)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#home-request-confirmation") |> Enum.count() == 1
    assert LazyHTML.query(html, "#home-bootstrap-form") |> Enum.count() == 0
  end

  test "weekly progress uses actual seconds and ISO week, with bounded visual fill" do
    for {completed, target, fill, now, label} <- [
          {2, 4800, "0.041666666666666664%", "2", "0 / 80 min"},
          {1935, 4800, "40.3125%", "1935", "32 / 80 min"},
          {6000, 4800, "100%", "4800", "100 / 80 min"},
          {0, 0, "0%", "0", "0 / 0 min"}
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

      assert LazyHTML.query(html, "#home-week-duration") |> text() == label

      assert LazyHTML.query(html, "[role=progressbar]") |> LazyHTML.attribute("aria-valuetext") ==
               ["#{completed} of #{target} seconds completed"]

      assert LazyHTML.query(html, "#home-week-number") |> text() == "Week 37"
    end
  end

  test "shared History command isolates the workspace for either return target" do
    for return_to <- ["#home-history-toggle", "#home-result-history"] do
      assert HomeWorkoutComponents.open_history(return_to).ops == [
               ["set_attr", %{attr: ["hidden", ""], to: "#home-state-content"}],
               ["set_attr", %{attr: ["inert", ""], to: "#home-state-content"}],
               ["push", %{event: "open_history", value: %{return_to: return_to}}]
             ]
    end
  end

  test "busy workspace leaves shared progress and page spacing to Home" do
    html =
      render_component(&HomeWorkoutComponents.workspace/1,
        state: %{
          expanded?: true,
          busy?: true,
          authoring_stage: :idle,
          home_selection: %{
            plan: %{name: "Six-count", target_duration_sec: 1200, target_reps: 120}
          }
        }
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "#home-workout-area[aria-busy=true] #home-update-loading")
           |> Enum.count() == 1

    assert LazyHTML.query(html, ".home-hero .home-workout-name") |> text() == "Six-count"
    assert LazyHTML.query(html, "#home-week-progress, .adaptive-home") |> Enum.empty?()
  end

  test "expanded pattern rows retain complete prescriptions and ordered nonuniform recoveries" do
    events = [work(2, 5_000_000, 10), rest(10_000), work(3, 6_125_000, 18.375), rest(11_250)]
    rows = rows(events ++ events ++ [work(2, 5_000_000, 9)])
    [group, final] = rows
    assert group.count == 2
    html = inspection(rows, MapSet.new([group.id]))

    assert LazyHTML.query(html, "#home-inspection > table > thead th") |> text() ==
             "SetsRepsPaceCadenceRest"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-reps") |> text() ==
             "2"

    assert LazyHTML.query(html, "##{group.id} > tr:first-child .home-prescription-rest") |> text() ==
             "10s"

    assert prescription_rows(html, group.id) == [
             ["Set 1", "2", "5s", "5s", "10s"],
             ["Set 2", "3", "6.125s", "6.125s", "11.25s"],
             ["Set 3", "2", "5s", "5s", "10s"],
             ["Set 4", "3", "6.125s", "6.125s", "11.25s"]
           ]

    assert LazyHTML.query(html, "##{final.id} .home-prescription-rest") |> text() == "—"
    refute text(html) =~ "Interval"
    assert LazyHTML.query(html, "caption") |> LazyHTML.text() =~ "prescribed"
  end

  test "simple adjacent sets and separate final recovery are not fabricated" do
    rows = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10), rest(1250)])
    [group, recovery] = rows
    html = inspection(rows, MapSet.new([group.id]))
    assert LazyHTML.query(html, "##{group.id} button") |> text() == "Set 1"
    assert LazyHTML.query(html, "##{recovery.id} th") |> text() == "Final recovery"
    assert LazyHTML.query(html, "##{recovery.id} .home-prescription-rest") |> text() == "1.25s"
  end

  test "compiler-shortened terminal work keeps exact timing without a cadence annotation" do
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

    assert LazyHTML.query(html, "##{ordinary.id} .home-prescription-rest") |> text() == "13s"
    assert LazyHTML.query(html, "##{terminal.id} .home-prescription-cadence") |> text() == "9s"
    assert LazyHTML.query(html, "##{terminal.id} .home-prescription-rest") |> text() == "—"
    assert List.last(Inspection.flatten(rows))["duration_sec"] == 14
    refute text(html) =~ "Interval"
  end

  test "expanded even and unbroken sets use complete rows under the single shared header" do
    for {style, active, duration, values} <- [
          {"even", 5, 573, ["20", "5s", "8s", "51s"]},
          {"unbroken", 8, 576, ["20", "8s", "48s"]}
        ] do
      w = definition_work(20, 8, active)
      plan = compiled_plan(style, [w, definition_rest(48), w, definition_rest(48), w], duration)
      [group, _final] = rows = Inspection.rows(plan)
      html = inspection(rows, MapSet.new([group.id]), style)

      assert prescription_rows(html, group.id) == [["Set 1" | values], ["Set 2" | values]]
      assert LazyHTML.query(html, "table") |> Enum.count() == 1
      assert LazyHTML.query(html, "thead") |> Enum.count() == 1

      assert LazyHTML.query(html, "##{group.id}-details > tr > th[scope=row]") |> Enum.count() ==
               1

      assert Inspection.flatten(rows) == plan.program_json["events"]
      refute text(html) =~ "Prescription as above"
      refute text(html) =~ "Interval"
    end
  end

  test "group activation retains one native button with row-wide target and disclosure context" do
    [group] = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10)])
    html = inspection([group])
    button = LazyHTML.query(html, "##{group.id} > tr.home-group-row button[type=button]")
    assert LazyHTML.attribute(button, "phx-click") == ["toggle_group"]
    assert LazyHTML.attribute(button, "aria-controls") == ["#{group.id}-details"]
    assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(button, "aria-describedby") == ["#{group.id}-prescription"]

    assert LazyHTML.query(html, "##{group.id}-prescription") |> text() ==
             "2 reps · 5s pace · 5s cadence · No recovery"

    assert LazyHTML.query(html, "##{group.id}-details[hidden]") |> Enum.count() == 1
    expanded = inspection([group], MapSet.new([group.id]))
    assert LazyHTML.query(expanded, "button[aria-expanded=true]") |> Enum.count() == 1
    assert LazyHTML.query(expanded, "##{group.id}-details[hidden]") |> Enum.empty?()
  end

  test "row-wide hit target stays anchored when a reconnect retains the prior stylesheet" do
    [group] = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10)])

    for expanded <- [MapSet.new(), MapSet.new([group.id])] do
      html = inspection([group], expanded)

      assert LazyHTML.query(html, "##{group.id} > tr.relative > th > .home-group-toggle")
             |> Enum.count() == 1
    end
  end

  test "expansion replaces the summary with its first set and keeps the same toggle identity" do
    [group] = rows([work(2, 5_000_000, 10), work(2, 5_000_000, 10)])
    collapsed = inspection([group])
    expanded = inspection([group], MapSet.new([group.id]))

    for html <- [collapsed, expanded] do
      assert LazyHTML.query(html, "##{group.id}-toggle") |> Enum.count() == 1
      assert LazyHTML.query(html, ".home-group-detail") |> Enum.empty?()
    end

    assert LazyHTML.query(collapsed, "##{group.id}-toggle") |> text() == "2 sets"
    assert LazyHTML.query(expanded, "##{group.id}-toggle") |> text() == "Set 1"
    assert LazyHTML.query(expanded, "tbody:not([hidden]) > tr") |> Enum.count() == 2

    assert prescription_rows(expanded, group.id) == [
             ["Set 1", "2", "5s", "5s", "—"],
             ["Set 2", "2", "5s", "5s", "—"]
           ]

    assert LazyHTML.query(expanded, "##{group.id}-details > tr") |> Enum.count() == 1
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

      assert LazyHTML.query(html, "button.home-alternative")
             |> LazyHTML.attribute("phx-value-kind") == [to_string(kind)]

      assert LazyHTML.query(html, ".home-alternative-name") |> text() == "Stored item"
    end
  end

  test "ordinary fractional and large duration values never use exponent notation or lose precision" do
    html = inspection(rows([work(100, 12_000_001, 1200.000001), rest(1), work(1, 1_000_000, 1)]))
    assert LazyHTML.query(html, ".home-prescription-cadence") |> LazyHTML.text() =~ "12.000001s"
    assert LazyHTML.query(html, ".home-interval") |> Enum.empty?()
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

    assert LazyHTML.query(html, ".home-prescription-cadence") |> text() == "8s"
    refute text(html) =~ "Interval"
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

  defp prescription_rows(html, group_id) do
    for row <- LazyHTML.query(html, "##{group_id} > tr, ##{group_id}-details > tr") do
      row = LazyHTML.query(row, "th, td")

      Enum.map(row, fn cell ->
        case LazyHTML.query(cell, "button") |> Enum.to_list() do
          [button] -> text(button)
          [] -> text(cell)
        end
      end)
    end
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
