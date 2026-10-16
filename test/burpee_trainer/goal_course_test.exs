defmodule BurpeeTrainer.GoalCourseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.GoalCourse

  # A Tuesday; weeks start on Monday.
  @today ~D[2026-10-13]

  defp point(weeks_ago, density) do
    date = Date.add(@today, -7 * weeks_ago)
    %{completed_at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"), density: density}
  end

  test "a steady rise projects the week the line reaches the target" do
    points = [point(3, 100), point(2, 110), point(1, 120), point(0, 130)]
    course = GoalCourse.project(points, 150, ~D[2026-11-09], @today)

    assert course.on_course?
    # Ten reps a week from 130: two weeks after this one.
    assert course.projected_on == Date.add(Date.beginning_of_week(@today), 14)
    assert Enum.map(course.weeks, & &1.best) == [100, 110, 120, 130]
  end

  test "a rise too slow for the date reads at this pace, not on course" do
    points = [point(3, 100), point(2, 102), point(1, 104), point(0, 106)]
    course = GoalCourse.project(points, 150, ~D[2026-11-09], @today)

    refute course.on_course?
    assert Date.compare(course.projected_on, ~D[2026-11-09]) == :gt
  end

  test "the best in each week counts, not every session" do
    points = [point(2, 100), point(2, 90), point(1, 110), point(0, 120), point(0, 80)]
    course = GoalCourse.project(points, 150, ~D[2026-12-01], @today)
    assert Enum.map(course.weeks, & &1.best) == [100, 110, 120]
  end

  test "no course when it would not be honest: too few weeks, flat or falling, or reached" do
    assert GoalCourse.project([point(1, 100), point(0, 120)], 150, ~D[2026-11-09], @today) ==
             nil

    falling = [point(2, 130), point(1, 120), point(0, 110)]
    assert GoalCourse.project(falling, 150, ~D[2026-11-09], @today) == nil

    reached = [point(2, 130), point(1, 140), point(0, 155)]
    assert GoalCourse.project(reached, 150, ~D[2026-11-09], @today) == nil

    # Weeks older than eight back do not count toward the three.
    old = [point(12, 60), point(10, 80), point(0, 120)]
    assert GoalCourse.project(old, 150, ~D[2026-11-09], @today) == nil
  end

  property "a course, when there is one, rises to the target no earlier than this week" do
    check all(
            bests <- list_of(integer(40..200), min_length: 3, max_length: 8),
            target <- integer(50..260)
          ) do
      points = bests |> Enum.reverse() |> Enum.with_index(&point(&2, &1))

      case GoalCourse.project(points, target, ~D[2026-12-31], @today) do
        nil ->
          :ok

        course ->
          assert Date.compare(course.projected_on, Date.beginning_of_week(@today)) != :lt
          assert List.last(course.weeks).best < target
          assert course.on_course? == (Date.compare(course.projected_on, ~D[2026-12-31]) != :gt)
      end
    end
  end
end
