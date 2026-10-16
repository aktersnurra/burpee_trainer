defmodule BurpeeTrainer.GoalCourse do
  @moduledoc """
  When a goal will be reached at the current pace, shown only when that is honest: the
  best reps per 20 minutes in at least three of the last eight weeks, on a line that rises,
  and not yet at the target. The projected week is where a least-squares line through
  the weekly bests reaches the target, never earlier than this week.
  """

  @window_weeks 8
  @min_weeks 3

  @type week :: %{start: Date.t(), best: number()}
  @type t :: %{weeks: [week()], projected_on: Date.t(), on_course?: boolean()}

  @spec project(
          [%{completed_at: DateTime.t(), density: number()}],
          pos_integer(),
          Date.t(),
          Date.t()
        ) ::
          t() | nil
  def project(points, target, %Date{} = goal_date, %Date{} = today) do
    this_week = Date.beginning_of_week(today)
    first_week = Date.add(this_week, -7 * (@window_weeks - 1))

    weeks =
      points
      |> Enum.map(&{Date.beginning_of_week(DateTime.to_date(&1.completed_at)), &1.density})
      |> Enum.filter(fn {start, _} -> Date.compare(start, first_week) != :lt end)
      |> Enum.group_by(fn {start, _} -> start end, fn {_, density} -> density end)
      |> Enum.map(fn {start, densities} -> %{start: start, best: Enum.max(densities)} end)
      |> Enum.sort_by(& &1.start, Date)

    with true <- length(weeks) >= @min_weeks,
         true <- List.last(weeks).best < target,
         {slope, intercept} when slope > 0 <- fit(weeks, first_week) do
      week_index = max((target - intercept) / slope, Date.diff(this_week, first_week) / 7)
      projected_on = Date.add(first_week, ceil(week_index) * 7)

      %{
        weeks: weeks,
        projected_on: projected_on,
        on_course?: Date.compare(projected_on, goal_date) != :gt
      }
    else
      _ -> nil
    end
  end

  # Least squares through (weeks since the window's first, best).
  defp fit(weeks, first_week) do
    xs = Enum.map(weeks, &(Date.diff(&1.start, first_week) / 7))
    ys = Enum.map(weeks, & &1.best)
    n = length(xs)
    mean_x = Enum.sum(xs) / n
    mean_y = Enum.sum(ys) / n

    spread = xs |> Enum.map(&((&1 - mean_x) ** 2)) |> Enum.sum()

    if spread == 0 do
      {0, mean_y}
    else
      covariance =
        Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> (x - mean_x) * (y - mean_y) end) |> Enum.sum()

      slope = covariance / spread
      {slope, mean_y - slope * mean_x}
    end
  end
end
