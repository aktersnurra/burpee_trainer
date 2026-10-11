defmodule BurpeeTrainer.Coach.Tools.SelectWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Rationale, Tool}
  alias BurpeeTrainer.Workouts
  def name, do: "select_workout"
  def description, do: "Select an owned or built-in published workout fitting the current slot."

  def schema,
    do:
      Tool.object(
        %{
          "plan_id" => %{"type" => "integer", "minimum" => 1},
          "rationale" => %{"type" => "string", "maxLength" => Rationale.max_length()}
        },
        ["plan_id", "rationale"]
      )

  def call(scope, %{"plan_id" => id, "rationale" => rationale} = args, run)
      when is_integer(id) and id > 0 and map_size(args) == 2 do
    with {:ok, rationale} <- Rationale.validate(rationale),
         {:ok, _} <- plan(scope, id) do
      case run do
        %{slot: slot, expected_selection: %BurpeeTrainer.Workouts.HomeSelection{}}
        when is_map(slot) ->
          {:ok, %{"selected" => id}, %{pending_selection: %{plan_id: id, rationale: rationale}}}

        _ ->
          {:error, "planner slot required"}
      end
    end
  end

  def call(_, _, _), do: {:error, "invalid selection arguments"}

  defp plan(scope, id) do
    case Workouts.get_library_plan(scope, id) do
      {:ok, plan} -> {:ok, plan}
      _ -> {:error, "plan not found"}
    end
  end
end
