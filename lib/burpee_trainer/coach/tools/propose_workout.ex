defmodule BurpeeTrainer.Coach.Tools.ProposeWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{
    Rationale,
    RepCeiling,
    Tool,
    Voice,
    WorkoutRequest,
    WorkoutLayout,
    RestFitter
  }

  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.HomeSelection

  def name, do: "propose_workout"

  def description,
    do:
      "Fit a workout for the fixed slot type and duration, at most 10% above their best 20-minute rate for the type in the last eight weeks, whatever their level; with no session of the type in that time, at most one level above the current level. It becomes this run's selection and is saved only when the run finishes. Phases must equal timed_rests + 1."

  def schema do
    {:ok, request} =
      WorkoutRequest.new(%{
        "burpee_type" => "six_count",
        "target_reps" => 1,
        "target_duration_sec" => 1200,
        "pacing_style" => "even",
        "recovery" => "optional",
        "timed_rests" => [],
        "requested_pace_sec" => nil
      })

    layout =
      WorkoutLayout.json_schema(request)
      |> update_in(["properties", "phases"], &Map.delete(&1, "maxItems"))

    fields = WorkoutRequest.json_schema().properties

    Tool.object(
      %{
        "reps" => fields.target_reps,
        "pacing_style" => fields.pacing_style,
        "recovery" => fields.recovery,
        "timed_rests" => fields.timed_rests,
        "requested_pace_sec" => fields.requested_pace_sec,
        "layout" => layout
      },
      ~w[reps pacing_style recovery timed_rests requested_pace_sec layout]
    )
  end

  def call(
        scope,
        %{"reps" => reps, "layout" => layout} = args,
        %{slot: slot, expected_selection: %HomeSelection{}} = run
      )
      when is_integer(reps) and is_map(layout) and is_map(slot) and map_size(args) == 6 do
    attrs =
      args
      |> Map.drop(["reps", "layout"])
      |> Map.merge(%{
        "target_reps" => reps,
        "burpee_type" => Atom.to_string(slot.burpee_type),
        "target_duration_sec" => slot.duration_sec
      })

    with :ok <- plain_name(layout["name"]),
         {:ok, rationale} <- Rationale.validate(layout["rationale"]),
         :ok <- within_ceiling(scope, slot, reps),
         {:ok, request} <- WorkoutRequest.new(attrs),
         {:ok, canonical} <- RestFitter.fit(request, %{layout | "rationale" => rationale}),
         {:ok, definition} <- WorkoutDefinition.new(canonical),
         {:ok, _} <- PlanCompiler.compile(definition),
         :ok <- WorkoutRequest.validate_definition(request, definition) do
      {:ok, %{"duration_sec" => definition.target_duration_sec},
       %{
         pending_selection: %{
           definition: WorkoutDefinition.canonical_map(definition),
           approval_key: run.run_id <> ":" <> Integer.to_string(run.call_index),
           rationale: rationale
         }
       }}
    else
      {:error, reason} -> {:error, describe(reason)}
      {:error, _error, detail} -> {:error, detail}
    end
  end

  def call(_, _, _), do: {:error, "invalid workout arguments or missing slot"}

  defp within_ceiling(scope, slot, reps) do
    case RepCeiling.for_type(scope, slot.burpee_type) do
      {:ok, ceiling} ->
        if RepCeiling.allows?(ceiling, slot.burpee_type, reps, slot.duration_sec),
          do: :ok,
          else:
            {:error,
             "reps must not exceed 10% above the recent best (the next level without a recent session)"}

      {:error, :timezone_unavailable} ->
        {:error, "owner timezone is unavailable"}
    end
  end

  defp plain_name(name) when is_binary(name) do
    case Voice.internal_id(name) do
      nil -> :ok
      id -> {:error, "name is shown to the athlete; write #{id} in plain words"}
    end
  end

  defp plain_name(_name), do: :ok

  defp describe(%{code: code, context: context}), do: "#{code}: #{inspect(context)}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: RestFitter.describe(reason)
end
