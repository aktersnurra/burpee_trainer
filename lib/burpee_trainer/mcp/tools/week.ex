defmodule BurpeeTrainer.Mcp.Tools.Week do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.{History, Levels, WeekWindow, Workouts}
  alias BurpeeTrainer.Coach.{Policy, Tool}
  alias BurpeeTrainer.Mcp.Sessions

  def name, do: "get_week"

  def description,
    do:
      "This week against its minutes target: minutes done and left, today's state " <>
        "(workout_needed, done_today, week_complete), the next session's type and length, " <>
        "the week's sessions done and the 20-minute sessions left, the streak of weeks at " <>
        "target, and the current level."

  def schema, do: Tool.object(%{}, [])

  def call(%{user: user} = scope, args, _) when is_map(args) and map_size(args) == 0 do
    now = DateTime.utc_now(:second)
    sessions = Workouts.list_sessions(scope)

    with {:ok, slot} <- Policy.required_slot(scope, now),
         {:ok, weeks} <- History.weeks(sessions, user, now, "all") do
      {:ok,
       %{
         "week_start" => Date.to_iso8601(slot.week_start),
         "minutes_target" => div(slot.weekly_target_sec, 60),
         "minutes_done" => div(slot.completed_sec, 60),
         "minutes_left" => div(slot.remaining_sec, 60),
         "today" => to_string(slot.home_state),
         "next_session" => %{
           "burpee_type" => to_string(slot.burpee_type),
           "minutes" => div(slot.duration_sec, 60),
           "catch_up" => slot.strategy == :catch_up
         },
         "window" =>
           Enum.map(WeekWindow.this_week(scope, slot.weekly_target_sec), &item(&1, user.timezone)),
         "streak_weeks" => History.streak(weeks),
         "level" => to_string(Levels.current_level(sessions))
       }}
    else
      {:error, _} -> {:error, "the week is not available: the athlete's timezone is not known"}
    end
  end

  def call(_, _, _), do: {:error, "get_week takes no arguments"}

  defp item(%{status: :done} = item, timezone),
    do: %{
      "status" => "done",
      "burpee_type" => to_string(item.burpee_type),
      "minutes" => div(item.duration_sec, 60),
      "date" => Sessions.local_date(item.completed_at, timezone)
    }

  defp item(%{status: :left} = item, _timezone),
    do: %{
      "status" => "left",
      "burpee_type" => to_string(item.burpee_type),
      "minutes" => div(item.duration_sec, 60)
    }
end
