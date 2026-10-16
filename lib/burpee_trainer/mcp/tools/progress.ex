defmodule BurpeeTrainer.Mcp.Tools.Progress do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.{Goals, Levels, ProgressGauges, UserTime, Workouts}
  alias BurpeeTrainer.Coach.Tool

  def name, do: "get_progress"

  def description,
    do:
      "What the Progress screen shows for each burpee type, six-count then Navy SEAL: its " <>
        "active goal with the best reps toward it and, when the trend is honest, the week the " <>
        "goal will be reached (kind goal); a goal just reached and the next one (reached); the " <>
        "best reps per 20 minutes and a next goal (best); a first result (first); or nothing " <>
        "yet (none). Also the current level."

  def schema, do: Tool.object(%{}, [])

  def call(%{user: user} = scope, args, _) when is_map(args) and map_size(args) == 0 do
    sessions = Workouts.list_sessions(scope)

    case UserTime.context(user, DateTime.utc_now()) do
      {:ok, context} ->
        gauges =
          ProgressGauges.for_types(Goals.list(scope), sessions, context.date, context.timezone)

        {:ok,
         %{
           "gauges" => Enum.map(gauges, &gauge/1),
           "level" => to_string(Levels.current_level(sessions, context.date))
         }}

      {:error, _} ->
        {:error, "progress is not available: the athlete's timezone is not known"}
    end
  end

  def call(_, _, _), do: {:error, "get_progress takes no arguments"}

  defp gauge(gauge) do
    %{"kind" => to_string(gauge.kind), "burpee_type" => to_string(gauge.burpee_type)}
    |> put("goal", gauge[:goal] && goal(gauge.goal))
    |> put("best", gauge[:best])
    |> put("reps", gauge[:reps])
    |> put("reached_on", gauge[:reached_on] && Date.to_iso8601(gauge.reached_on))
    |> put("next_goal", gauge[:next] && goal(gauge.next))
    |> put(
      "course",
      gauge[:course] &&
        %{
          "projected_on" => Date.to_iso8601(gauge.course.projected_on),
          "on_course" => gauge.course.on_course?
        }
    )
  end

  defp goal(goal),
    do:
      %{
        "reps" => goal.burpee_count_target,
        "duration_sec" => goal.duration_sec_target,
        "date" => Date.to_iso8601(goal.date_target)
      }
      |> put("id", Map.get(goal, :id))

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
