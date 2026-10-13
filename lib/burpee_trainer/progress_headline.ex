defmodule BurpeeTrainer.ProgressHeadline do
  @moduledoc """
  What leads the Progress page, as one headline. The first that applies:

    1. a goal reached in the last week (`:reached`), with the next goal;
    2. the active goal with the nearest date (`:goal`);
    3. three or more measured sessions and no goal: the best (`:best`), with the next goal;
    4. one or two measured sessions: the first as a starting point (`:first`);
    5. nothing measured (`:none`).

  An active goal carries its course (`GoalCourse.project/4`) when one is honest to show.
  Other active goals follow the headline as quiet rows (`others`). Best reps toward a
  goal are `Insights.Metrics.goal_best/2`, the figure the coach's summary uses.
  """

  alias BurpeeTrainer.{GoalCourse, History, NextGoal}
  alias BurpeeTrainer.Insights.Metrics

  @reached_days 7
  @best_after 3
  @duration_sec 1200

  @spec pick([map()], [map()], Date.t(), String.t()) :: %{headline: map(), others: [map()]}
  def pick(goals, sessions, %Date{} = today, timezone) do
    measured = sessions |> Enum.reject(&warmup?/1) |> Enum.filter(&measured?/1)

    active =
      goals
      |> Enum.filter(&(&1.status == :active))
      |> Enum.sort_by(& &1.date_target, Date)
      |> Enum.map(&%{goal: &1, best: Metrics.goal_best(sessions, &1)})

    case {reached(goals, sessions, today, timezone), active} do
      {%{} = reached, _active} ->
        %{headline: reached, others: active}

      {nil, [lead | others]} ->
        %{
          headline: Map.merge(lead, %{kind: :goal, course: course(lead.goal, measured, today)}),
          others: others
        }

      {nil, []} ->
        %{headline: without_goal(measured, sessions, today), others: []}
    end
  end

  defp reached(goals, sessions, today, timezone) do
    goals
    |> Enum.filter(&(&1.status == :achieved))
    |> Enum.map(&{&1, local_date(&1.updated_at, timezone)})
    |> Enum.filter(fn {_goal, on} -> on && Date.diff(today, on) in 0..(@reached_days - 1) end)
    |> Enum.max_by(fn {_goal, on} -> on end, Date, fn -> nil end)
    |> case do
      nil ->
        nil

      {goal, on} ->
        best = Metrics.goal_best(sessions, goal)

        %{
          kind: :reached,
          goal: goal,
          best: best,
          reached_on: on,
          next: NextGoal.for_best(goal.burpee_type, best, today)
        }
    end
  end

  defp without_goal([], _sessions, _today), do: %{kind: :none}

  defp without_goal(measured, _sessions, _today) when length(measured) < @best_after do
    first = Enum.min_by(measured, & &1.completed_at, DateTime)
    %{kind: :first, burpee_type: first.burpee_type, reps: first.burpee_count_actual}
  end

  defp without_goal(measured, sessions, today) do
    type =
      if Enum.all?(measured, &(&1.burpee_type == :navy_seal)), do: :navy_seal, else: :six_count

    best =
      Metrics.goal_best(sessions, %{burpee_type: type, duration_sec_target: @duration_sec})

    %{kind: :best, burpee_type: type, best: best, next: NextGoal.for_best(type, best, today)}
  end

  defp course(goal, measured, today) do
    measured
    |> Enum.filter(&(&1.burpee_type == goal.burpee_type))
    |> History.points()
    |> GoalCourse.project(goal.burpee_count_target, goal.date_target, today)
  end

  defp measured?(session),
    do:
      is_integer(session.burpee_count_actual) and session.burpee_count_actual > 0 and
        is_integer(session.duration_sec_actual) and session.duration_sec_actual > 0

  defp warmup?(session), do: Map.get(session, :tags) == "warmup"

  defp local_date(%DateTime{} = at, timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _} -> nil
    end
  end

  defp local_date(_at, _timezone), do: nil
end
