defmodule BurpeeTrainer.PlanCompiler.ProgramValidator do
  @moduledoc "Validates canonical execution program invariants."

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent}

  @epsilon 1.0e-6

  @spec validate(Program.t()) :: :ok | {:error, CompileError.t()}
  def validate(%Program{} = program) do
    with :ok <- validate_events(program.events),
         :ok <- validate_reps(program),
         :ok <- validate_duration(program) do
      :ok
    end
  end

  defp validate_events([]),
    do: {:error, CompileError.new(:empty_program, "Program must contain at least one event")}

  defp validate_events(events) do
    Enum.reduce_while(events, :ok, fn
      %ProgramEvent.Work{reps: reps, sec_per_rep: pace}, :ok
      when reps > 0 and pace > 0 ->
        {:cont, :ok}

      %ProgramEvent.Rest{duration_sec: duration}, :ok
      when duration > 0 ->
        {:cont, :ok}

      event, :ok ->
        {:halt,
         {:error,
          CompileError.new(:invalid_event, "Program contains an invalid event", %{event: event})}}
    end)
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
