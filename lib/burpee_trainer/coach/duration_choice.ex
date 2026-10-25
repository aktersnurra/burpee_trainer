defmodule BurpeeTrainer.Coach.DurationChoice do
  @moduledoc "Provider-free duration reviews at the selected workout's normalized rate."
  alias BurpeeTrainer.Accounts.Scope
  alias BurpeeTrainer.Coach.{Policy, RestFitter, WorkoutRequest}
  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.WorkoutDefinition
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.Error

  @spec options(map() | nil) :: [pos_integer()]
  def options(%{home_state: :workout_needed, remaining_sec: remaining}),
    do: Enum.filter([1200, 2400], &(&1 <= remaining))

  def options(_), do: []

  @spec prepare(Scope.t(), Workouts.HomeSelection.t(), integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare(scope, expected, duration) when duration in [1200, 2400] do
    with {:ok, slot} <- Policy.required_slot(scope, DateTime.utc_now(:second)),
         true <- duration in options(slot),
         {:ok, source} <- Workouts.verify_home_selection(scope, expected),
         {:ok, request, canonical} <- variant(source, duration),
         {:ok, definition} <- WorkoutDefinition.new(canonical),
         {:ok, _} <- PlanCompiler.compile(definition),
         :ok <- WorkoutRequest.validate_definition(request, definition) do
      {:ok,
       %{
         user_id: scope.user.id,
         approval_key: Ecto.UUID.generate(),
         request: request,
         original_request: request,
         definition: canonical,
         source: %{"plan_id" => source.id, "content_hash" => source.content_hash},
         text: "Choose #{div(duration, 60)} minutes from #{source.name}"
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, Error.new(:invalid_duration_choice)}
    end
  end

  def prepare(_, _, _), do: {:error, Error.new(:invalid_duration_choice)}

  defp variant(source, duration) do
    reps = max(1, round(source.target_reps * duration / max(source.target_duration_sec, 1200)))

    active =
      source.definition_json["events"]
      |> Enum.filter(&(&1["kind"] == "work"))
      |> Enum.sum_by(&(&1["reps"] * &1["sec_per_burpee"]))

    pace = Float.floor(active / source.target_reps, 3)

    attrs = %{
      "burpee_type" => Atom.to_string(source.burpee_type),
      "target_reps" => reps,
      "target_duration_sec" => duration,
      "pacing_style" => "even",
      "recovery" => "optional",
      "timed_rests" => [],
      "requested_pace_sec" => pace
    }

    with {:ok, request} <- WorkoutRequest.new(attrs),
         {:ok, canonical} <- RestFitter.fit(request, layout(request)) do
      {:ok, request, canonical}
    end
  end

  defp layout(request) do
    size = min(5, max(1, div(request.target_reps, 2)))

    sets =
      1..request.target_reps
      |> Enum.chunk_every(size)
      |> Enum.map(fn reps ->
        %{
          "reps" => length(reps),
          "sec_per_rep" => request.requested_pace_sec,
          "sec_per_burpee" => request.requested_pace_sec
        }
      end)

    type = if request.burpee_type == "six_count", do: "Six-count", else: "Navy SEAL"

    %{
      "name" => "#{div(request.target_duration_sec, 60)}-minute #{type}",
      "rationale" => "A comparable rate for the time you chose.",
      "phases" => [
        %{"sets" => sets, "rests" => List.duplicate(%{"share" => 1}, length(sets) - 1)}
      ]
    }
  end
end
