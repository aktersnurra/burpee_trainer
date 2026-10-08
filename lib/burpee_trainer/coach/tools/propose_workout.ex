defmodule BurpeeTrainer.Coach.Tools.ProposeWorkout do
  @behaviour BurpeeTrainer.Coach.Tool
  alias BurpeeTrainer.Coach.{Tool, WorkoutRequest, WorkoutLayout, RestFitter}
  alias BurpeeTrainer.{Levels, Workouts, Repo, PlanCompiler}
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  def name, do: "propose_workout"

  def description,
    do:
      "Fit and publish a workout for the fixed slot type and duration, at current or next level. Phases must equal timed_rests + 1."

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

  def call(scope, %{"reps" => reps, "layout" => layout} = args, %{slot: slot} = run)
      when is_integer(reps) and is_map(layout) and is_map(slot) and map_size(args) == 6 do
    attrs =
      args
      |> Map.drop(["reps", "layout"])
      |> Map.merge(%{
        "target_reps" => reps,
        "burpee_type" => Atom.to_string(slot.burpee_type),
        "target_duration_sec" => slot.duration_sec
      })

    current = Levels.current_level(Workouts.list_sessions(scope))
    levels = Enum.reverse(Levels.all_levels())
    next = Enum.at(levels, min(Enum.find_index(levels, &(&1 == current)) + 1, length(levels) - 1))

    with true <- Levels.level_for_count(slot.burpee_type, reps) in [current, next],
         {:ok, request} <- WorkoutRequest.new(attrs),
         {:ok, canonical} <- RestFitter.fit(request, layout),
         {:ok, definition} <- WorkoutDefinition.new(canonical),
         {:ok, _} <- PlanCompiler.compile(definition),
         :ok <- WorkoutRequest.validate_definition(request, definition) do
      Repo.immediate_transaction(fn ->
        with {:ok, plan} <-
               Workouts.commit_approved_workout(
                 scope,
                 WorkoutDefinition.canonical_map(definition),
                 "Planner",
                 approval_key: run.run_id <> ":" <> Integer.to_string(run.call_index)
               ),
             {:ok, _} <-
               BurpeeTrainer.Coach.Tools.SelectWorkout.call(
                 scope,
                 %{"plan_id" => plan.id, "rationale" => layout["rationale"] || "Planned workout"},
                 run
               ) do
          %{"plan_id" => plan.id, "duration_sec" => plan.target_duration_sec}
        else
          {:error, reason} -> Repo.rollback(describe(reason))
        end
      end)
    else
      false -> {:error, "reps must be within current or next level"}
      {:error, reason} -> {:error, describe(reason)}
      {:error, _error, detail} -> {:error, detail}
    end
  end

  def call(_, _, _), do: {:error, "invalid workout arguments or missing slot"}
  defp describe(%{code: code, context: context}), do: "#{code}: #{inspect(context)}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: RestFitter.describe(reason)
end
