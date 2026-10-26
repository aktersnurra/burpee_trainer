defmodule BurpeeTrainer.Coach.Tools.SelectWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Progression, Rationale, RepCeiling, Tool, WorkoutPreference}
  alias BurpeeTrainer.Workouts
  def name, do: "select_workout"
  def description, do: "Select an owned or built-in published workout fitting the current slot."

  def schema,
    do:
      Tool.object(
        %{
          "plan_id" => %{"type" => "integer", "minimum" => 1},
          "rationale" => %{
            "type" => "string",
            "maxLength" => Rationale.max_length(),
            "description" => Rationale.description()
          }
        },
        ["plan_id", "rationale"]
      )

  def call(scope, %{"plan_id" => id, "rationale" => rationale} = args, run)
      when is_integer(id) and id > 0 and map_size(args) == 2 do
    with {:ok, rationale} <- Rationale.validate(rationale),
         {:ok, plan} <- plan(scope, id),
         :ok <- eligible_plan(scope, run, plan) do
      {:ok, %{"selected" => id}, %{pending_selection: %{plan_id: id, rationale: rationale}}}
    end
  end

  def call(_, _, _), do: {:error, "invalid selection arguments"}

  defp eligible_plan(
         scope,
         %{
           slot: %{burpee_type: type, duration_sec: duration},
           expected_selection: %Workouts.HomeSelection{}
         },
         plan
       ) do
    decision = Progression.for_type(scope, type)

    case RepCeiling.for_type(scope, type) do
      {:ok, ceiling} ->
        cond do
          plan.burpee_type != type or plan.target_duration_sec != duration ->
            {:error, "saved workout must match the slot's burpee type and duration"}

          not RepCeiling.allows?(ceiling, type, plan.target_reps, duration) ->
            {:error, "saved workout exceeds the athlete's rep ceiling"}

          not Progression.allows?(decision, plan.target_reps, duration) ->
            {:error, Progression.explanation(decision)}

          Map.get(WorkoutPreference.for_scope(scope), plan.id) == :avoid ->
            {:error, "the athlete asked to avoid this workout; choose another"}

          true ->
            :ok
        end

      {:error, :timezone_unavailable} ->
        {:error, "owner timezone is unavailable"}
    end
  end

  defp eligible_plan(_scope, _run, _plan), do: {:error, "planner slot required"}

  defp plan(scope, id) do
    case Workouts.get_library_plan(scope, id) do
      {:ok, plan} -> {:ok, plan}
      _ -> {:error, "plan not found"}
    end
  end
end
