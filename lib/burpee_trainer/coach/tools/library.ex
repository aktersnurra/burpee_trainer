defmodule BurpeeTrainer.Coach.Tools.Library do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  def name, do: "library"
  def description, do: "Owned and built-in published workouts."
  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0 do
    {:ok,
     %{
       "plans" =>
         BurpeeTrainer.Workouts.list_library(scope)
         |> Enum.take(100)
         |> Enum.map(fn p ->
           %{
             "id" => p.id,
             "name" => p.name,
             "type" => Atom.to_string(p.burpee_type),
             "reps" => p.target_reps,
             "duration_sec" => p.target_duration_sec
           }
         end)
     }}
  end

  def call(_, _, _), do: {:error, "library takes no arguments"}
end
