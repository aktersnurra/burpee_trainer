defmodule BurpeeTrainer.ExecutionPrograms do
  @moduledoc "Persistence boundary for immutable compiled workout programs."

  import Ecto.Query

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent, ProgramHash, ProgramValidator}
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.ExecutionProgram

  @spec get_or_insert(Program.t()) :: {:ok, ExecutionProgram.t()} | {:error, term()}
  def get_or_insert(%Program{} = program) do
    with :ok <- ProgramValidator.validate(program) do
      hash = ProgramHash.hash(program)

      case Repo.get_by(ExecutionProgram, content_hash: hash) do
        %ExecutionProgram{} = existing ->
          {:ok, existing}

        nil ->
          insert_program(program, hash)
      end
    end
  end

  @spec get!(integer()) :: ExecutionProgram.t()
  def get!(id), do: Repo.get!(ExecutionProgram, id)

  defp insert_program(%Program{} = program, hash) do
    attrs = %{
      content_hash: hash,
      schema_version: program.schema_version,
      solver_version: program.solver_version,
      burpee_type: program.burpee_type,
      target_reps: program.target_reps,
      target_duration_sec: program.target_duration_sec,
      event_count: length(program.events),
      program_json: ProgramHash.canonical_map(program),
      summary_json: summary_json(program)
    }

    %ExecutionProgram{}
    |> ExecutionProgram.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, changeset} -> handle_insert_error(hash, changeset)
    end
  end

  defp handle_insert_error(hash, changeset) do
    case Repo.one(from p in ExecutionProgram, where: p.content_hash == ^hash) do
      %ExecutionProgram{} = existing -> {:ok, existing}
      nil -> {:error, changeset}
    end
  end

  defp summary_json(%Program{} = program) do
    %{
      "target_reps" => program.target_reps,
      "target_duration_sec" => program.target_duration_sec,
      "work_event_count" => Enum.count(program.events, &match?(%ProgramEvent.Work{}, &1)),
      "rest_event_count" => Enum.count(program.events, &match?(%ProgramEvent.Rest{}, &1))
    }
  end
end
