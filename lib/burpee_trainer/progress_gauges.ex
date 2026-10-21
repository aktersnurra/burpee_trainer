defmodule BurpeeTrainer.ProgressGauges do
  @moduledoc """
  What Progress shows for each burpee type, side by side: six-count, then Navy SEAL. For
  each type, the first that applies:

    1. its active goal with the nearest date (`:goal`), with its course when one is honest
       to show (`GoalCourse.project/4`);
    2. a goal reached in the last week (`:reached`), with the next goal;
    3. three or more measured sessions: the best (`:best`), with the next goal;
    4. one or two measured sessions: the first as a starting point (`:first`);
    5. nothing measured (`:none`).

  A new goal set after one is reached leads at once. Best reps toward a goal are
  `Insights.Metrics.goal_best/2`, the figure the coach's summary uses.
  """

  alias BurpeeTrainer.{GoalCourse, History, NextGoal}
  alias BurpeeTrainer.Insights.Metrics

  @types [:six_count, :navy_seal]
  @reached_days 7
  @best_after 3

  @type gauge :: %{
          required(:kind) => atom(),
          required(:burpee_type) => atom(),
          optional(atom()) => term()
        }

  @spec for_types([map()], [map()], Date.t(), String.t()) :: [gauge()]
  def for_types(goals, sessions, %Date{} = today, timezone) do
    measured = sessions |> Enum.reject(&warmup?/1) |> Enum.filter(&measured?/1)

    for type <- @types do
      typed_goals = Enum.filter(goals, &(&1.burpee_type == type))
      typed = Enum.filter(measured, &(&1.burpee_type == type))

      active(typed_goals, sessions, typed, today) ||
        reached(typed_goals, sessions, today, timezone) ||
        without_goal(type, typed, sessions, today)
    end
  end

  defp active(goals, sessions, typed, today) do
    goals
    |> Enum.filter(&(&1.status == :active))
    |> Enum.min_by(& &1.date_target, Date, fn -> nil end)
    |> case do
      nil ->
        nil

      goal ->
        %{
          kind: :goal,
          burpee_type: goal.burpee_type,
          goal: goal,
          best: Metrics.goal_best(sessions, goal.burpee_type),
          course: course(goal, typed, today)
        }
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
        best = Metrics.goal_best(sessions, goal.burpee_type)

        %{
          kind: :reached,
          burpee_type: goal.burpee_type,
          goal: goal,
          best: best,
          reached_on: on,
          next: NextGoal.for_best(goal.burpee_type, best, today)
        }
    end
  end

  defp without_goal(type, [], _sessions, _today), do: %{kind: :none, burpee_type: type}

  defp without_goal(type, typed, _sessions, _today) when length(typed) < @best_after do
    first = Enum.min_by(typed, & &1.completed_at, DateTime)
    %{kind: :first, burpee_type: type, reps: first.burpee_count_actual}
  end

  defp without_goal(type, _typed, sessions, today) do
    best = Metrics.goal_best(sessions, type)
    %{kind: :best, burpee_type: type, best: best, next: NextGoal.for_best(type, best, today)}
  end

  defp course(goal, typed, today) do
    typed
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
