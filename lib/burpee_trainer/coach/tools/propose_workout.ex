defmodule BurpeeTrainer.Coach.Tools.ProposeWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Tool, WorkoutRequest, WorkoutLayout, RestFitter}
  alias BurpeeTrainer.{Levels, Workouts, PlanCompiler, UserTime}
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts.HomeSelection

  # Level landmarks are counts for a 20-minute session.
  @landmark_duration_sec 1_200

  def name, do: "propose_workout"

  def description,
    do:
      "Fit a workout for the fixed slot type and duration, at most one level above the current level. It becomes this run's selection and is saved only when the run finishes. Phases must equal timed_rests + 1."

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

    with :ok <- within_level_band(scope, slot, reps),
         {:ok, request} <- WorkoutRequest.new(attrs),
         {:ok, canonical} <- RestFitter.fit(request, layout),
         {:ok, definition} <- WorkoutDefinition.new(canonical),
         {:ok, _} <- PlanCompiler.compile(definition),
         :ok <- WorkoutRequest.validate_definition(request, definition) do
      {:ok, %{"duration_sec" => definition.target_duration_sec},
       %{
         pending_selection: %{
           definition: WorkoutDefinition.canonical_map(definition),
           approval_key: run.run_id <> ":" <> Integer.to_string(run.call_index),
           rationale: layout["rationale"] || "Planned workout"
         }
       }}
    else
      {:error, reason} -> {:error, describe(reason)}
      {:error, _error, detail} -> {:error, detail}
    end
  end

  def call(_, _, _), do: {:error, "invalid workout arguments or missing slot"}

  # Easier sessions below the current level are allowed; only the next level caps the plan.
  # A longer slot (weekend catch-up) is compared at its 20-minute-equivalent rate.
  defp within_level_band(scope, slot, reps) do
    case UserTime.context(scope.user, DateTime.utc_now()) do
      {:ok, %{date: today}} ->
        ascending = Enum.reverse(Levels.all_levels())
        rank = fn level -> Enum.find_index(ascending, &(&1 == level)) end
        current = Levels.current_level(Workouts.list_sessions(scope), today)
        rate = div(reps * @landmark_duration_sec, max(slot.duration_sec, @landmark_duration_sec))

        if rank.(Levels.level_for_count(slot.burpee_type, rate)) <= rank.(current) + 1,
          do: :ok,
          else: {:error, "reps must not exceed the next level"}

      {:error, _} ->
        {:error, "owner timezone is unavailable"}
    end
  end

  defp describe(%{code: code, context: context}), do: "#{code}: #{inspect(context)}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: RestFitter.describe(reason)
end
