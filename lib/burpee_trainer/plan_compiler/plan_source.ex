defmodule BurpeeTrainer.PlanCompiler.PlanSource do
  @moduledoc "Editable workout source normalized for compilation."

  alias BurpeeTrainer.PlanCompiler.CompileError

  @enforce_keys [:burpee_type, :target_reps, :target_duration_sec, :pacing_style]
  defstruct [
    :name,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :pacing_style,
    :max_unbroken_reps,
    block_pattern: nil,
    explicit_rests: [],
    sec_per_rep_override: nil,
    pace_bias: :balanced,
    load_shape: :even
  ]

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, CompileError.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, target_reps} <-
           integer_field(
             attrs,
             :target_reps,
             get(attrs, :target_reps) || get(attrs, :burpee_count_target)
           ),
         {:ok, target_duration_sec} <-
           integer_field(attrs, :target_duration_sec, get(attrs, :target_duration_sec)),
         {:ok, max_unbroken_reps} <-
           integer_field(
             attrs,
             :max_unbroken_reps,
             get(attrs, :max_unbroken_reps) || get(attrs, :reps_per_set)
           ),
         {:ok, block_pattern} <- normalize_block_pattern(get(attrs, :block_pattern)),
         {:ok, explicit_rests} <- normalize_explicit_rests(get(attrs, :explicit_rests)),
         {:ok, sec_per_rep_override} <-
           float_field(attrs, :sec_per_rep_override, get(attrs, :sec_per_rep_override)) do
      source = %__MODULE__{
        name: get(attrs, :name),
        burpee_type: normalize_burpee_type(get(attrs, :burpee_type)),
        target_reps: target_reps,
        target_duration_sec: target_duration_sec,
        pacing_style: normalize_pacing_style(get(attrs, :pacing_style)),
        max_unbroken_reps: max_unbroken_reps,
        block_pattern: block_pattern,
        explicit_rests: explicit_rests,
        sec_per_rep_override: sec_per_rep_override,
        pace_bias: normalize_pace_bias(get(attrs, :pace_bias)) || :balanced,
        load_shape: normalize_load_shape(get(attrs, :load_shape)) || :even
      }

      validate(source)
    end
  end

  defp validate(%__MODULE__{} = source) do
    cond do
      source.burpee_type not in [:six_count, :navy_seal] ->
        invalid(:burpee_type, source.burpee_type)

      source.pacing_style not in [:even, :unbroken] ->
        invalid(:pacing_style, source.pacing_style)

      not (is_integer(source.target_reps) and source.target_reps > 0) ->
        invalid(:target_reps, source.target_reps)

      not (is_integer(source.target_duration_sec) and source.target_duration_sec > 0) ->
        invalid(:target_duration_sec, source.target_duration_sec)

      source.pacing_style == :unbroken and
          not (is_integer(source.max_unbroken_reps) and source.max_unbroken_reps > 0) ->
        invalid(:max_unbroken_reps, source.max_unbroken_reps)

      true ->
        {:ok, source}
    end
  end

  defp invalid(field, value) do
    {:error,
     CompileError.new(:invalid_source, "Workout source is invalid", %{field: field, value: value})}
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_burpee_type(value) when value in [:six_count, :navy_seal], do: value
  defp normalize_burpee_type("six_count"), do: :six_count
  defp normalize_burpee_type("navy_seal"), do: :navy_seal
  defp normalize_burpee_type(value), do: value

  defp normalize_pacing_style(value) when value in [:even, :unbroken], do: value
  defp normalize_pacing_style("even"), do: :even
  defp normalize_pacing_style("unbroken"), do: :unbroken
  defp normalize_pacing_style(value), do: value

  defp normalize_pace_bias(value) when value in [:slower, :balanced, :faster], do: value
  defp normalize_pace_bias("slower"), do: :slower
  defp normalize_pace_bias("balanced"), do: :balanced
  defp normalize_pace_bias("faster"), do: :faster
  defp normalize_pace_bias(_value), do: nil

  defp normalize_load_shape(value) when value in [:even, :front_loaded, :back_loaded], do: value
  defp normalize_load_shape("even"), do: :even
  defp normalize_load_shape("front_loaded"), do: :front_loaded
  defp normalize_load_shape("back_loaded"), do: :back_loaded
  defp normalize_load_shape(_value), do: nil

  defp normalize_block_pattern(nil), do: {:ok, nil}

  defp normalize_block_pattern(pattern) when is_list(pattern) do
    pattern
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case parse_integer(value) do
        {:ok, integer} -> {:cont, {:ok, acc ++ [integer]}}
        :error -> {:halt, invalid(:block_pattern, pattern)}
      end
    end)
  end

  defp normalize_block_pattern(pattern), do: invalid(:block_pattern, pattern)

  defp normalize_explicit_rests(nil), do: {:ok, []}
  defp normalize_explicit_rests(rests) when is_list(rests), do: {:ok, rests}
  defp normalize_explicit_rests(rests), do: invalid(:explicit_rests, rests)

  defp integer_field(_attrs, _field, nil), do: {:ok, nil}

  defp integer_field(_attrs, _field, value) when is_integer(value), do: {:ok, value}

  defp integer_field(_attrs, field, value) when is_binary(value) do
    case parse_integer(value) do
      {:ok, integer} -> {:ok, integer}
      :error -> invalid(field, value)
    end
  end

  defp integer_field(_attrs, field, value), do: invalid(field, value)

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp float_field(_attrs, _field, nil), do: {:ok, nil}
  defp float_field(_attrs, _field, value) when is_float(value), do: {:ok, value}
  defp float_field(_attrs, _field, value) when is_integer(value), do: {:ok, value * 1.0}

  defp float_field(_attrs, field, value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> invalid(field, value)
    end
  end

  defp float_field(_attrs, field, value), do: invalid(field, value)
end
