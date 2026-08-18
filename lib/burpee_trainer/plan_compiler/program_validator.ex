defmodule BurpeeTrainer.PlanCompiler.ProgramValidator do
  @moduledoc "Validates canonical execution program invariants."

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent}

  @epsilon 1.0e-6

  @spec validate(Program.t()) :: :ok | {:error, CompileError.t()}
  def validate(%Program{} = program) do
    with :ok <- validate_canonical_contract(program),
         :ok <- validate_events(program.events),
         :ok <- validate_terminal_work(program.events),
         :ok <- validate_schema_three_work_durations(program),
         :ok <- validate_reps(program),
         :ok <- validate_duration(program) do
      :ok
    end
  end

  defp validate_canonical_contract(%Program{schema_version: 3} = program) do
    definition_hash =
      Map.get(program.metadata, :definition_hash, Map.get(program.metadata, "definition_hash"))

    pacing_style =
      Map.get(program.metadata, :pacing_style, Map.get(program.metadata, "pacing_style"))

    if program.solver_version == 1 and is_binary(definition_hash) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, definition_hash) and
         pacing_style in [:even, :unbroken, "even", "unbroken"] do
      :ok
    else
      {:error,
       CompileError.new(:invalid_program, "Program violates the canonical contract", %{
         schema_version: program.schema_version,
         solver_version: program.solver_version,
         metadata: program.metadata
       })}
    end
  end

  defp validate_canonical_contract(%Program{}), do: :ok

  defp validate_events([]),
    do: {:error, CompileError.new(:empty_program, "Program must contain at least one event")}

  defp validate_events(events) do
    Enum.reduce_while(events, :ok, fn
      %ProgramEvent.Work{
        reps: reps,
        sec_per_rep: cadence,
        sec_per_burpee: active_duration,
        duration_sec: duration_sec
      },
      :ok
      when reps > 0 and cadence > 0 and active_duration > 0 and active_duration <= cadence and
             (is_nil(duration_sec) or (is_number(duration_sec) and duration_sec > 0)) ->
        {:cont, :ok}

      %ProgramEvent.Rest{duration_sec: duration}, :ok when duration > 0 ->
        {:cont, :ok}

      event, :ok ->
        {:halt,
         {:error,
          CompileError.new(:invalid_event, "Program contains an invalid event", %{event: event})}}
    end)
  end

  defp validate_terminal_work(events) do
    case List.last(events) do
      %ProgramEvent.Work{} ->
        :ok

      %ProgramEvent.Rest{} ->
        {:error, CompileError.new(:terminal_rest, "Program must end with a work event")}
    end
  end

  defp validate_schema_three_work_durations(%Program{schema_version: schema_version})
       when schema_version < 3,
       do: :ok

  defp validate_schema_three_work_durations(%Program{} = program) do
    terminal_index = length(program.events) - 1

    program.events
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%ProgramEvent.Work{} = work, ^terminal_index}, :ok ->
        validate_work_duration(work, (work.reps - 1) * work.sec_per_rep + work.sec_per_burpee)

      {%ProgramEvent.Work{} = work, _index}, :ok ->
        validate_work_duration(work, work.reps * work.sec_per_rep)

      {_event, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_work_duration(%ProgramEvent.Work{duration_sec: duration_sec}, expected)
       when is_number(duration_sec) do
    if abs(duration_sec - expected) <= @epsilon do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        CompileError.new(
          :invalid_work_duration,
          "Work duration does not match canonical timing",
          %{
            expected_duration_sec: expected,
            actual_duration_sec: duration_sec
          }
        )}}
    end
  end

  defp validate_work_duration(_work, _expected) do
    {:halt,
     {:error,
      CompileError.new(:invalid_work_duration, "Schema-3 work events require duration", %{})}}
  end

  defp validate_reps(%Program{} = program) do
    if Program.total_reps(program) == program.target_reps do
      :ok
    else
      {:error,
       CompileError.new(:target_reps_mismatch, "Program reps do not match target", %{
         target_reps: program.target_reps,
         actual_reps: Program.total_reps(program)
       })}
    end
  end

  defp validate_duration(%Program{} = program) do
    actual = Program.duration_sec(program)

    if abs(actual - program.target_duration_sec) <= @epsilon do
      :ok
    else
      {:error,
       CompileError.new(:target_duration_mismatch, "Program duration does not match target", %{
         target_duration_sec: program.target_duration_sec,
         actual_duration_sec: actual
       })}
    end
  end
end
