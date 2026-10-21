defmodule BurpeeTrainer.Mcp.Tools.GoalJson do
  @moduledoc false
  def encode(goal),
    do: %{
      "id" => goal.id,
      "burpee_type" => to_string(goal.burpee_type),
      "status" => to_string(goal.status),
      "reps" => goal.burpee_count_target,
      "duration_sec" => goal.duration_sec_target,
      "date" => Date.to_iso8601(goal.date_target)
    }
end

defmodule BurpeeTrainer.Mcp.Tools.ListGoals do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tools.Goals

  def name, do: "list_goals"

  def description,
    do:
      "The athlete's active goals (at most one per burpee type) and goals waiting for them " <>
        "to confirm, with the starting point and progress toward each."

  def schema, do: Goals.schema()
  def call(scope, args, run), do: Goals.call(scope, args, run)
end

defmodule BurpeeTrainer.Mcp.Tools.SetGoal do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tools.ProposeGoal
  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Mcp.Tools.GoalJson

  def name, do: "set_goal"

  def description,
    do:
      "Set the athlete's goal for a burpee type, active at once; it replaces that type's " <>
        "current goal. A goal is reps in one 20-minute session (the length levels are counted " <>
        "in) by a date."

  def schema,
    do:
      Tool.object(
        %{
          "burpee_type" => %{"type" => "string", "enum" => ["six_count", "navy_seal"]},
          "reps" => %{"type" => "integer", "minimum" => 1},
          "date" => %{"type" => "string", "format" => "date", "description" => "YYYY-MM-DD"}
        },
        ["burpee_type", "reps", "date"]
      )

  def call(scope, %{"burpee_type" => type, "reps" => reps, "date" => date} = args, run)
      when map_size(args) == 3 do
    with :ok <- date(date),
         {:ok, %{"goal_id" => id}} <-
           ProposeGoal.call(
             scope,
             %{
               "burpee_type" => type,
               "burpee_count_target" => reps,
               "date_target" => date
             },
             run
           ) do
      case Goals.confirm(scope, id) do
        {:ok, goal} ->
          {:ok, %{"goal" => GoalJson.encode(goal)}}

        {:error, _} ->
          Goals.dismiss(scope, id)
          {:error, "the goal could not be made active; nothing changed"}
      end
    end
  end

  def call(_, _, _),
    do: {:error, "set_goal takes burpee_type, reps and date; a goal is a 20-minute session"}

  defp date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, _} -> :ok
      _ -> {:error, "date must be YYYY-MM-DD"}
    end
  end

  defp date(_), do: {:error, "date must be YYYY-MM-DD"}
end

defmodule BurpeeTrainer.Mcp.Tools.ConfirmGoal do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Mcp.Tools.GoalJson

  def name, do: "confirm_goal"

  def description,
    do:
      "Make a goal that is waiting for the athlete active; it replaces that type's current goal."

  def schema, do: Tool.object(%{"id" => %{"type" => "integer", "minimum" => 1}}, ["id"])

  def call(scope, %{"id" => id} = args, _) when is_integer(id) and map_size(args) == 1 do
    case Goals.confirm(scope, id) do
      {:ok, goal} -> {:ok, %{"goal" => GoalJson.encode(goal)}}
      {:error, _} -> {:error, "no goal #{id} is waiting for the athlete"}
    end
  end

  def call(_, _, _), do: {:error, "confirm_goal takes a goal id"}
end

defmodule BurpeeTrainer.Mcp.Tools.DismissGoal do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Mcp.Tools.GoalJson

  def name, do: "dismiss_goal"
  def description, do: "Dismiss a goal that is waiting for the athlete."
  def schema, do: Tool.object(%{"id" => %{"type" => "integer", "minimum" => 1}}, ["id"])

  def call(scope, %{"id" => id} = args, _) when is_integer(id) and map_size(args) == 1 do
    case Goals.dismiss(scope, id) do
      {:ok, goal} -> {:ok, %{"goal" => GoalJson.encode(goal)}}
      {:error, _} -> {:error, "no goal #{id} is waiting for the athlete"}
    end
  end

  def call(_, _, _), do: {:error, "dismiss_goal takes a goal id"}
end
