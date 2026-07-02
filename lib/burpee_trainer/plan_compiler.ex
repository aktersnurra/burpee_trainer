defmodule BurpeeTrainer.PlanCompiler do
  @moduledoc "Compiles editable workout source into immutable execution programs."

  alias BurpeeTrainer.PlanCompiler.{
    CompileError,
    PlanSource,
    Program,
    ProgramEvent,
    ProgramValidator
  }

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanSolver.{Execution, ExplicitRest, Input}

  @solver_version 4
  @schema_version 1

  @spec compile(PlanSource.t() | map()) :: {:ok, Program.t()} | {:error, CompileError.t()}
  def compile(%PlanSource{} = source), do: compile_source(source)

  def compile(attrs) when is_map(attrs) do
    with {:ok, source} <- PlanSource.new(attrs) do
      compile_source(source)
    end
  end

  defp compile_source(%PlanSource{} = source) do
    with {:ok, explicit_rests} <- explicit_rests(source.explicit_rests),
         input = input_from_source(source, explicit_rests),
         {:ok, solution} <- PlanSolver.solve(input),
         {:ok, program} <- program_from_execution(source, solution.execution, solution.metadata),
         :ok <- ProgramValidator.validate(program) do
      {:ok, program}
    else
      {:error, %CompileError{} = error} ->
        {:error, error}

      {:error, messages} when is_list(messages) ->
        {:error,
         CompileError.new(:solver_infeasible, Enum.join(messages, " "), %{messages: messages})}

      {:error, reason} ->
        {:error,
         CompileError.new(:compile_failed, "Workout source could not be compiled", %{
           reason: reason
         })}
    end
  end

  defp input_from_source(%PlanSource{} = source, explicit_rests) do
    %Input{
      name: source.name,
      burpee_type: source.burpee_type,
      target_duration_sec: source.target_duration_sec,
      burpee_count_target: source.target_reps,
      pacing_style: source.pacing_style,
      max_unbroken_reps: source.max_unbroken_reps,
      block_pattern: source.block_pattern,
      explicit_rests: explicit_rests,
      sec_per_rep_override: source.sec_per_rep_override,
      pace_bias: source.pace_bias,
      load_shape: source.load_shape
    }
  end

  defp explicit_rests(rests) when is_list(rests) do
    rests
    |> Enum.reduce_while({:ok, []}, fn rest, {:ok, acc} ->
      case explicit_rest(rest) do
        {:ok, explicit_rest} -> {:cont, {:ok, acc ++ [explicit_rest]}}
        {:error, %CompileError{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp explicit_rests(rests), do: invalid_source(:explicit_rests, rests)

  defp explicit_rest(%ExplicitRest{} = rest) do
    cond do
      not valid_integer?(rest.target_elapsed_sec) -> invalid_source(:explicit_rests, rest)
      not valid_positive_integer?(rest.duration_sec) -> invalid_source(:explicit_rests, rest)
      not valid_integer?(rest.tolerance_sec) -> invalid_source(:explicit_rests, rest)
      true -> {:ok, rest}
    end
  end

  defp explicit_rest(rest) when is_map(rest) do
    with {:ok, target_elapsed_sec} <- integer_value(get(rest, :target_elapsed_sec)),
         {:ok, duration_sec} <- integer_value(get(rest, :duration_sec)),
         {:ok, tolerance_sec} <- integer_value(get(rest, :tolerance_sec) || 60) do
      rest = %ExplicitRest{
        target_elapsed_sec: target_elapsed_sec,
        duration_sec: duration_sec,
        tolerance_sec: tolerance_sec
      }

      explicit_rest(rest)
    else
      :error -> invalid_source(:explicit_rests, rest)
    end
  end

  defp explicit_rest(rest), do: invalid_source(:explicit_rests, rest)

  defp program_from_execution(source, execution, metadata) do
    Program.new(%{
      schema_version: @schema_version,
      solver_version: @solver_version,
      burpee_type: source.burpee_type,
      target_reps: source.target_reps,
      target_duration_sec: source.target_duration_sec,
      events:
        execution
        |> Enum.with_index(1)
        |> Enum.map(fn {event, index} -> program_event(event, index) end),
      metadata: Map.merge(metadata || %{}, %{source: :plan_compiler})
    })
  end

  defp program_event(%Execution.SetEvent{} = event, _index) do
    ProgramEvent.work!(%{
      id: "work-#{pad(event.index)}",
      set_index: event.index,
      block_index: nil,
      display_group: nil,
      reps: event.burpee_count,
      sec_per_rep: event.sec_per_rep,
      label: "Set #{event.index}"
    })
  end

  defp program_event(%Execution.RestEvent{} = event, index) do
    ProgramEvent.rest!(%{
      id: "rest-#{pad(index)}",
      duration_sec: event.rest_sec,
      label: "Rest",
      source: event.source
    })
  end

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp integer_value(value) when is_integer(value), do: {:ok, value}

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp integer_value(_value), do: :error

  defp valid_integer?(value), do: is_integer(value) and value >= 0
  defp valid_positive_integer?(value), do: is_integer(value) and value > 0

  defp invalid_source(field, value) do
    {:error,
     CompileError.new(:invalid_source, "Workout source is invalid", %{field: field, value: value})}
  end
end
