defmodule BurpeeTrainer.Mcp.Tools.PlanNextWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{PlanNextWorkoutJob, Rationale, Tool}
  alias BurpeeTrainer.Mcp.Workouts, as: McpWorkouts
  alias BurpeeTrainer.Workouts

  def name, do: "plan_next_workout"

  def description,
    do:
      "Choose the athlete's next session; it shows on Home with your one-sentence reason, " <>
        "and the app's own planner leaves it alone. The next session is today's, or " <>
        "tomorrow's once today is done; its burpee type and length are fixed by the week " <>
        "(get_week's next_session) and the workout must match them. Give a workout_id from " <>
        "the library, or a new workout in create_workout's form."

  def schema,
    do:
      Tool.object(
        %{
          "workout_id" => %{"type" => "integer", "minimum" => 1},
          "workout" => %{
            "type" => "object",
            "description" => "A new workout, as create_workout takes it.",
            "properties" => McpWorkouts.schema(),
            "required" => McpWorkouts.required()
          },
          "rationale" => %{
            "type" => "string",
            "maxLength" => Rationale.max_length(),
            "description" => Rationale.description()
          }
        },
        ["rationale"]
      )

  def call(scope, %{"rationale" => rationale} = args, _) when map_size(args) == 2 do
    with {:ok, rationale} <- Rationale.validate(rationale),
         {:ok, slot} <- next_slot(scope),
         {:ok, target, workout} <- target(scope, args),
         :ok <- fits(workout, slot),
         {:ok, expected} <- Workouts.ensure_home_selection(scope, slot),
         {:ok, selection} <-
           Workouts.select_planned_workout(scope, expected, target, rationale, :claude) do
      {:ok,
       %{
         "date" => Date.to_iso8601(slot.slot_date),
         "workout" => McpWorkouts.entry(selection.plan),
         "rationale" => selection.rationale
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, %{code: :home_selection_changed}} ->
        {:error, "Home changed while planning; try again"}

      {:error, _} ->
        {:error, "the next session could not be planned; nothing changed"}
    end
  end

  def call(_, _, _),
    do: {:error, "plan_next_workout takes a rationale and either workout_id or workout"}

  defp next_slot(scope) do
    case PlanNextWorkoutJob.target_slot(scope, DateTime.utc_now(:second)) do
      {:ok, %{home_state: :workout_needed} = slot, _at} ->
        {:ok, slot}

      {:ok, _slot, _at} ->
        {:error, "the week's minutes are done; there is no next session to plan"}

      {:error, _} ->
        {:error, "the athlete's timezone is not known"}
    end
  end

  defp target(scope, %{"workout_id" => id}) when is_integer(id) do
    case Workouts.get_library_plan(scope, id) do
      {:ok, plan} ->
        {:ok, {:plan, plan.id},
         %{burpee_type: to_string(plan.burpee_type), duration_sec: plan.target_duration_sec}}

      {:error, _} ->
        {:error, "no workout #{id} in the athlete's library"}
    end
  end

  defp target(_scope, %{"workout" => workout}) when is_map(workout) do
    with {:ok, definition} <- McpWorkouts.definition(workout) do
      {:ok, {:proposal, definition, Ecto.UUID.generate()},
       %{burpee_type: definition["burpee_type"], duration_sec: definition["target_duration_sec"]}}
    end
  end

  defp target(_scope, _args), do: {:error, "give workout_id or workout"}

  defp fits(%{burpee_type: type, duration_sec: sec}, slot) do
    if type == to_string(slot.burpee_type) and sec == slot.duration_sec,
      do: :ok,
      else:
        {:error,
         "the next session is #{slot.burpee_type} for #{div(slot.duration_sec, 60)} minutes; " <>
           "this workout is #{type} for #{Float.round(sec / 60, 1)} minutes"}
  end
end
