defmodule BurpeeTrainer.PlanCompiler.Program do
  @moduledoc "Immutable compiled workout program."

  alias BurpeeTrainer.PlanCompiler.{CompileError, ProgramEvent}

  @fields [
    :schema_version,
    :solver_version,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :events,
    :metadata
  ]
  @canonical_semantic_keys MapSet.new(["definition_hash", "pacing_style"])

  @enforce_keys [
    :schema_version,
    :solver_version,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :events,
    :metadata
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          solver_version: pos_integer(),
          burpee_type: :six_count | :navy_seal,
          target_reps: pos_integer(),
          target_duration_sec: pos_integer(),
          events: [ProgramEvent.t()],
          metadata: map()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, CompileError.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- reject_unknown_fields(attrs),
         :ok <- validate_canonical_semantics(attrs) do
      build(attrs)
    end
  end

  defp build(attrs) do
    program = %__MODULE__{
      schema_version: Map.fetch!(attrs, :schema_version),
      solver_version: Map.fetch!(attrs, :solver_version),
      burpee_type: Map.fetch!(attrs, :burpee_type),
      target_reps: Map.fetch!(attrs, :target_reps),
      target_duration_sec: Map.fetch!(attrs, :target_duration_sec),
      events: Map.fetch!(attrs, :events),
      metadata: Map.get(attrs, :metadata, %{})
    }

    {:ok, program}
  rescue
    KeyError ->
      {:error, CompileError.new(:invalid_program, "Program is missing required fields")}
  end

  defp reject_unknown_fields(attrs) do
    unknown = Map.keys(attrs) -- @fields

    if unknown == [] do
      :ok
    else
      {:error,
       CompileError.new(:invalid_program, "Program contains unknown fields", %{fields: unknown})}
    end
  end

  defp validate_canonical_semantics(%{schema_version: 3, metadata: metadata})
       when is_map(metadata) do
    with {:ok, normalized} <- normalize_semantic_keys(metadata),
         true <- MapSet.equal?(Map.keys(normalized) |> MapSet.new(), @canonical_semantic_keys) do
      :ok
    else
      _reason ->
        {:error,
         CompileError.new(:invalid_program, "Program contains invalid semantics", %{
           value: metadata
         })}
    end
  end

  defp validate_canonical_semantics(%{schema_version: 3} = attrs) do
    {:error,
     CompileError.new(:invalid_program, "Program contains invalid semantics", %{
       value: Map.get(attrs, :metadata)
     })}
  end

  defp validate_canonical_semantics(_attrs), do: :ok

  defp normalize_semantic_keys(metadata) do
    Enum.reduce_while(metadata, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(normalized, key) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(normalized, key, value)}}
        end

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  @spec events(t()) :: [ProgramEvent.t()]
  def events(%__MODULE__{events: events}), do: events

  @spec total_reps(t()) :: non_neg_integer()
  def total_reps(%__MODULE__{events: events}) do
    Enum.reduce(events, 0, fn
      %ProgramEvent.Work{reps: reps}, total -> total + reps
      _event, total -> total
    end)
  end

  @spec duration_sec(t()) :: float()
  def duration_sec(%__MODULE__{events: events}) do
    Enum.reduce(events, 0.0, fn
      %ProgramEvent.Work{duration_sec: duration_sec}, total when is_number(duration_sec) ->
        total + duration_sec

      %ProgramEvent.Work{reps: reps, sec_per_rep: sec_per_rep}, total ->
        total + reps * sec_per_rep

      %ProgramEvent.Rest{duration_sec: duration}, total ->
        total + duration
    end)
  end
end
