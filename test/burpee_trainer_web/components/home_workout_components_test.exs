defmodule BurpeeTrainerWeb.HomeWorkoutComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BurpeeTrainer.Workouts.{Inspection, WorkoutPlan}
  alias BurpeeTrainerWeb.HomeWorkoutComponents

  test "weekly progress exposes actual completed seconds to assistive technology" do
    for {completed, target, expected_now} <- [
          {2, 4_800, "2"},
          {6_000, 4_800, "4800"},
          {0, 0, "0"}
        ] do
      html =
        render_component(&HomeWorkoutComponents.week_progress/1,
          slot: %{completed_sec: completed, weekly_target_sec: target, week_start: ~D[2026-09-07]}
        )
        |> LazyHTML.from_fragment()

      progress = LazyHTML.query(html, "[role=progressbar]")
      assert LazyHTML.attribute(progress, "aria-valuenow") == [expected_now]
      assert LazyHTML.attribute(progress, "aria-valuemax") == [to_string(target)]

      assert LazyHTML.attribute(progress, "aria-valuetext") == [
               "#{completed} of #{target} seconds completed"
             ]
    end
  end

  test "inspection disclosure exposes its controlled prescription to assistive technology" do
    [group] = inspection_rows()

    collapsed = inspection([group])
    button = LazyHTML.query(collapsed, "##{group.id} button")

    assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(button, "aria-controls") == ["#{group.id}-details"]
    assert LazyHTML.attribute(button, "aria-describedby") == ["#{group.id}-prescription"]
    assert LazyHTML.query(collapsed, "##{group.id}-details[hidden]") != []

    expanded = inspection([group], MapSet.new([group.id]))
    assert LazyHTML.query(expanded, "##{group.id} button[aria-expanded=true]") != []
    assert LazyHTML.query(expanded, "##{group.id}-details[hidden]") |> Enum.empty?()
  end

  test "inspection is a named keyboard region and supplies timing information" do
    html = inspection(inspection_rows())
    region = LazyHTML.query(html, "#home-inspection[role=region][tabindex='0']")

    assert region != []
    assert LazyHTML.attribute(region, "aria-label") != []

    assert LazyHTML.query(html, "caption.sr-only") |> LazyHTML.text() =~
             "Pace is prescribed active seconds"

    assert html
           |> LazyHTML.query(".home-prescription-cadence")
           |> LazyHTML.text()
           |> String.contains?("5s")
  end

  defp inspection_rows do
    Inspection.rows(%WorkoutPlan{
      id: "accessibility",
      updated_at: ~U[2026-09-10 00:00:00Z],
      definition_json: %{"events" => [work(2), work(2)]},
      program_json: %{"events" => [work(2), work(2)]}
    })
  end

  defp work(reps) do
    %{
      "kind" => "work",
      "reps" => reps,
      "sec_per_rep_us" => 5_000_000,
      "sec_per_burpee_us" => 5_000_000,
      "duration_sec" => reps * 5
    }
  end

  defp inspection(rows, expanded \\ MapSet.new()) do
    render_component(&HomeWorkoutComponents.inspection/1,
      rows: rows,
      expanded: expanded,
      pacing_style: "even"
    )
    |> LazyHTML.from_fragment()
  end
end
