defmodule BurpeeTrainer.Mcp.Tools.ListWorkouts do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Workouts, as: McpWorkouts
  alias BurpeeTrainer.Workouts

  def name, do: "list_workouts"

  def description,
    do:
      "The athlete's workouts and the app's built-in ones: name, type, reps, length, " <>
        "pacing style, movement seconds per rep, and a one-line summary."

  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0,
    do: {:ok, %{"workouts" => Enum.map(Workouts.list_library(scope), &McpWorkouts.entry/1)}}

  def call(_, _, _), do: {:error, "list_workouts takes no arguments"}
end

defmodule BurpeeTrainer.Mcp.Tools.GetWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Workouts, as: McpWorkouts
  alias BurpeeTrainer.Workouts

  def name, do: "get_workout"

  def description,
    do:
      "One workout in full: its exact sets and rests (definition), a one-line summary, and " <>
        "editable, the same workout in the form edit_workout takes. Change what you need in " <>
        "editable and send it back. The format is in burpee://workout-format."

  def schema, do: Tool.object(%{"id" => %{"type" => "integer", "minimum" => 1}}, ["id"])

  def call(scope, %{"id" => id} = args, _) when is_integer(id) and map_size(args) == 1 do
    case Workouts.get_library_plan(scope, id) do
      {:ok, plan} -> {:ok, %{"workout" => McpWorkouts.encode(plan)}}
      {:error, _} -> {:error, "no workout #{id} in the athlete's library"}
    end
  end

  def call(_, _, _), do: {:error, "get_workout takes a workout id"}
end

defmodule BurpeeTrainer.Mcp.Tools.CreateWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Workouts, as: McpWorkouts
  alias BurpeeTrainer.Workouts

  def name, do: "create_workout"

  def description,
    do:
      "Add a workout to the athlete's library. Give what it asks for and its phases of " <>
        "sets with a rest per gap, exact seconds or a share of the time left (see " <>
        "burpee://workout-format); the app fits the shares and refuses, with what to change, " <>
        "a workout it could not run. It does not " <>
        "change today's workout on Home."

  def schema, do: Tool.object(McpWorkouts.schema(), McpWorkouts.required())

  def call(scope, args, _) when is_map(args) do
    with {:ok, definition} <- McpWorkouts.definition(args),
         {:ok, plan} <-
           Workouts.commit_approved_workout(scope, definition, "Made over MCP",
             approval_key: Ecto.UUID.generate()
           ) do
      {:ok, %{"workout" => McpWorkouts.entry(plan)}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "the workout could not be saved; nothing changed"}
    end
  end
end

defmodule BurpeeTrainer.Mcp.Tools.EditWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Mcp.Workouts, as: McpWorkouts
  alias BurpeeTrainer.Workouts

  def name, do: "edit_workout"

  def description,
    do:
      "Change one of the athlete's own workouts: send get_workout's editable with your " <>
        "changes and the workout's id. The app saves it as a new workout, moves Home's pick " <>
        "to it, and archives the old one; past sessions keep what they did. Built-in " <>
        "workouts cannot be changed; create_workout makes the athlete's own version."

  def schema,
    do:
      Tool.object(
        Map.put(McpWorkouts.schema(), "id", %{"type" => "integer", "minimum" => 1}),
        ["id" | McpWorkouts.required()]
      )

  def call(scope, %{"id" => id} = args, _) when is_integer(id) do
    with {:ok, definition} <- McpWorkouts.definition(Map.delete(args, "id")),
         {:ok, plan} <- Workouts.replace_plan(scope, id, definition, "Edited over MCP") do
      {:ok, %{"workout" => McpWorkouts.entry(plan), "replaced" => id}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "workout #{id} is not one of the athlete's own; nothing changed"}
    end
  end

  def call(_, _, _), do: {:error, "edit_workout needs the workout's id"}
end

defmodule BurpeeTrainer.Mcp.Tools.ArchiveWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Workouts

  def name, do: "archive_workout"

  def description,
    do:
      "Remove one of the athlete's own workouts from their library. Past sessions keep it; " <>
        "Home moves to a built-in workout if it was today's."

  def schema, do: Tool.object(%{"id" => %{"type" => "integer", "minimum" => 1}}, ["id"])

  def call(scope, %{"id" => id} = args, _) when is_integer(id) and map_size(args) == 1 do
    case Workouts.archive_plan(scope, id) do
      {:ok, plan} ->
        {:ok,
         %{"workout" => %{"id" => plan.id, "name" => plan.name, "state" => to_string(plan.state)}}}

      {:error, _} ->
        {:error, "workout #{id} is not one of the athlete's own published workouts"}
    end
  end

  def call(_, _, _), do: {:error, "archive_workout takes a workout id"}
end
