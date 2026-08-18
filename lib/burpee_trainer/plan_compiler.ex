defmodule BurpeeTrainer.PlanCompiler do
  @moduledoc "Compiles canonical workout definitions into immutable execution programs."

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent, ProgramValidator, WorkoutDefinition}

  @schema_version 3
  @solver_version 1

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec compile(WorkoutDefinition.t()) ::
          {:ok, Program.t()} | {:error, BurpeeTrainer.Workouts.Error.t()}
  def compile(%WorkoutDefinition{} = definition) do
    with {:ok, program} <-
           Program.new(%{
             schema_version: @schema_version,
             solver_version: @solver_version,
             burpee_type: definition.burpee_type,
             target_reps: definition.target_reps,
             target_duration_sec: definition.target_duration_sec,
             events: definition_events(definition.events),
             metadata: %{
               definition_hash: WorkoutDefinition.hash(definition),
               pacing_style: definition.pacing_style
             }
           }),
         :ok <- ProgramValidator.validate(program) do
      {:ok, program}
    else
      {:error, error} ->
        {:error, BurpeeTrainer.Workouts.Error.new(:invalid_workout_definition, %{reason: error})}
    end
  end

  defp definition_events(events) do
    terminal_index = length(events) - 1

    events
    |> Enum.with_index()
    |> Enum.map(&definition_event(&1, terminal_index))
  end

  defp definition_event({%{kind: :work} = event, index}, terminal_index) do
    cadence = round(event.sec_per_rep * 1_000_000) / 1_000_000
    active = round(event.sec_per_burpee * 1_000_000) / 1_000_000

    duration_sec =
      if index == terminal_index do
        (event.reps - 1) * cadence + active
      else
        event.reps * cadence
      end

    ProgramEvent.work!(%{
      reps: event.reps,
      sec_per_rep: cadence,
      sec_per_burpee: active,
      duration_sec: duration_sec
    })
  end

  defp definition_event({%{kind: :rest} = event, _index}, _terminal_index) do
    duration_sec = round(event.duration_sec * 1_000) / 1_000
    ProgramEvent.rest!(%{duration_sec: duration_sec})
  end
end
