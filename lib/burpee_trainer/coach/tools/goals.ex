defmodule BurpeeTrainer.Coach.Tools.Goals do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.Tool
  def name, do: "goals"
  def description, do: "Active and proposed owner goals with baseline and target progress."
  def schema, do: Tool.object(%{}, [])

  def call(scope, args, _) when is_map(args) and map_size(args) == 0 do
    {:ok,
     %{
       "goals" =>
         Enum.map(BurpeeTrainer.Goals.list(scope), fn goal ->
           %{
             "id" => goal.id,
             "type" => Atom.to_string(goal.burpee_type),
             "status" => Atom.to_string(goal.status),
             "reps" => goal.burpee_count_target,
             "duration_sec" => goal.duration_sec_target,
             "date" => Date.to_iso8601(goal.date_target),
             "baseline_reps" => goal.burpee_count_baseline,
             "baseline_duration_sec" => goal.duration_sec_baseline,
             "progress" => BurpeeTrainer.Goals.progress(scope, goal)
           }
         end)
     }}
  end

  def call(_, _, _), do: {:error, "goals takes no arguments"}
end
