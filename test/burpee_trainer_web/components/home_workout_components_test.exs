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
          slot: %{
            completed_sec: completed,
            weekly_target_sec: target,
            remaining_sec: max(0, target - completed),
            week_start: ~D[2026-09-07]
          }
        )
        |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query("#home-week-dates") |> LazyHTML.text() =~ "7–13 Sep"
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
             "Every is the seconds from the start of one rep to the next"
  end

  test "one column says how often a rep starts; Move appears only when it differs" do
    same = inspection(inspection_rows())
    assert headers(same) == ["Set", "Reps", "Every", "Rest"]
    assert same |> LazyHTML.query(".home-prescription-every") |> LazyHTML.text() =~ "5s"

    padded = inspection(inspection_rows(6_000_000))
    assert headers(padded) == ["Set", "Reps", "Every", "Move", "Rest"]
    assert padded |> LazyHTML.query(".home-prescription-every") |> LazyHTML.text() =~ "6s"
    assert padded |> LazyHTML.query(".home-prescription-move") |> LazyHTML.text() =~ "5s"
  end

  defp headers(html),
    do: html |> LazyHTML.query("thead th") |> Enum.map(&LazyHTML.text/1)

  defp inspection_rows(sec_per_rep_us \\ 5_000_000) do
    events = [work(2, sec_per_rep_us), work(2, sec_per_rep_us)]

    Inspection.rows(%WorkoutPlan{
      id: "accessibility",
      updated_at: ~U[2026-09-10 00:00:00Z],
      definition_json: %{"events" => events},
      program_json: %{"events" => events}
    })
  end

  defp work(reps, sec_per_rep_us) do
    %{
      "kind" => "work",
      "reps" => reps,
      "sec_per_rep_us" => sec_per_rep_us,
      "sec_per_burpee_us" => 5_000_000,
      "duration_sec" => reps * sec_per_rep_us / 1_000_000
    }
  end

  defp inspection(rows, expanded \\ MapSet.new()) do
    render_component(&HomeWorkoutComponents.inspection/1,
      rows: rows,
      expanded: expanded
    )
    |> LazyHTML.from_fragment()
  end
end
