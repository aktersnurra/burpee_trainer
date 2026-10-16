defmodule BurpeeTrainer.Mcp.Tools.CoachContext do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{AgentPrompt, Policy, Tool}

  def name, do: "get_coach_context"

  def description,
    do:
      "What the in-app coach reads before it answers: memory notes, goals, current level, " <>
        "the reps each level needs in 20 minutes, recent sessions with feedback, and the " <>
        "next session this week. Read it first."

  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0 do
    slot =
      case Policy.required_slot(scope, DateTime.utc_now(:second)) do
        {:ok, slot} -> slot
        _ -> nil
      end

    {:ok, scope |> AgentPrompt.context(slot) |> Jason.encode!() |> Jason.decode!()}
  end

  def call(_, _, _), do: {:error, "get_coach_context takes no arguments"}
end
