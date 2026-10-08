defmodule BurpeeTrainer.Coach.Tools.SelectWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Workouts
  def name, do: "select_workout"
  def description, do: "Select an owned or built-in published workout fitting the current slot."

  def schema,
    do:
      Tool.object(
        %{
          "plan_id" => %{"type" => "integer", "minimum" => 1},
          "rationale" => %{"type" => "string", "maxLength" => 600}
        },
        ["plan_id", "rationale"]
      )

  def call(scope, %{"plan_id" => id, "rationale" => rationale} = args, run)
      when is_integer(id) and id > 0 and is_binary(rationale) and byte_size(rationale) <= 2400 and
             map_size(args) == 2 do
    with {:ok, _} <- Workouts.get_library_plan(scope, id) do
      case run do
        %{slot: slot} when is_map(slot) ->
          with {:ok, selection} <- Workouts.ensure_home_selection(scope, slot),
               {:ok, _} <- Workouts.select_planned_workout(scope, selection, id, rationale) do
            {:ok, %{"selected" => id}}
          else
            _ -> {:error, "selection changed or workout does not fit the slot"}
          end

        _ ->
          {:error, "planner slot required"}
      end
    else
      _ -> {:error, "plan not found"}
    end
  end

  def call(_, _, _), do: {:error, "invalid selection arguments"}
end
