defmodule BurpeeTrainer.PlanSolver.Input do
  @moduledoc """
  Input to `BurpeeTrainer.PlanSolver.solve/1`.

  Plan Solver v3 normalizes legacy editor fields into canonical solver fields
  at the boundary. Existing callers may still provide `target_duration_min`,
  `reps_per_set`, `additional_rests`, and `sec_per_burpee_override`; the solver
  core consumes `target_duration_sec`, `max_unbroken_reps`, `explicit_rests`,
  and `sec_per_rep_override`.
  """

  alias BurpeeTrainer.PlanSolver.{BlockSpec, ExplicitRest, Infeasible}

  @enforce_keys [:burpee_type, :burpee_count_target, :pacing_style]
  defstruct [
    :name,
    :burpee_type,
    :target_duration_sec,
    :burpee_count_target,
    :pacing_style,
    :max_unbroken_reps,
    :block_structure,
    :explicit_rests,
    :sec_per_rep_override,
    :target_duration_min,
    :level,
    reps_per_set: nil,
    additional_rests: [],
    sec_per_burpee_override: nil,
    block_pattern: nil,
    pace_bias: :balanced,
    load_shape: :even
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type pacing_style :: :even | :unbroken
  @type additional_rest :: %{rest_sec: number, target_min: number}
  @type level ::
          :level_1a
          | :level_1b
          | :level_1c
          | :level_1d
          | :level_2
          | :level_3
          | :level_4
          | :graduated

  @type t :: %__MODULE__{
          name: String.t() | nil,
          burpee_type: burpee_type,
          target_duration_sec: pos_integer | nil,
          burpee_count_target: pos_integer,
          pacing_style: pacing_style,
          max_unbroken_reps: pos_integer | nil,
          block_structure: [BlockSpec.t()] | nil,
          explicit_rests: [ExplicitRest.t()] | nil,
          sec_per_rep_override: float | nil,
          target_duration_min: number | nil,
          level: level | nil,
          reps_per_set: pos_integer | nil,
          additional_rests: [additional_rest],
          sec_per_burpee_override: float | nil,
          block_pattern: [pos_integer] | nil,
          pace_bias: :slower | :balanced | :faster,
          load_shape: :even | :front_loaded | :back_loaded
        }

  @spec normalize_and_validate(t()) :: {:ok, t()} | {:error, Infeasible.t()}
  def normalize_and_validate(%__MODULE__{} = input) do
    input =
      input
      |> normalize_duration()
      |> normalize_pace_override()
      |> normalize_explicit_rests()
      |> normalize_unbroken_max()
      |> normalize_legacy_block_pattern()

    validate_canonical(input)
  end

  defp normalize_duration(%__MODULE__{target_duration_sec: seconds} = input)
       when is_integer(seconds),
       do: input

  defp normalize_duration(%__MODULE__{target_duration_min: minutes} = input)
       when is_number(minutes) do
    %{input | target_duration_sec: round(minutes * 60)}
  end

  defp normalize_duration(input), do: input

  defp normalize_pace_override(%__MODULE__{sec_per_rep_override: value} = input)
       when is_float(value),
       do: input

  defp normalize_pace_override(%__MODULE__{sec_per_burpee_override: value} = input)
       when is_float(value) do
    %{input | sec_per_rep_override: value}
  end

  defp normalize_pace_override(input), do: input

  defp normalize_explicit_rests(%__MODULE__{explicit_rests: rests} = input)
       when is_list(rests) and rests != [],
       do: input

  defp normalize_explicit_rests(%__MODULE__{additional_rests: rests} = input)
       when is_list(rests) do
    explicit_rests =
      Enum.map(rests, fn rest ->
        %ExplicitRest{
          target_elapsed_sec: round(fetch_rest_value(rest, :target_min) * 60),
          duration_sec: round(fetch_rest_value(rest, :rest_sec)),
          tolerance_sec: 60
        }
      end)

    %{input | explicit_rests: explicit_rests}
  end

  defp normalize_explicit_rests(input), do: %{input | explicit_rests: []}

  defp normalize_unbroken_max(%__MODULE__{pacing_style: :even} = input),
    do: %{input | max_unbroken_reps: nil}

  defp normalize_unbroken_max(
         %__MODULE__{pacing_style: :unbroken, max_unbroken_reps: max} = input
       )
       when is_integer(max) and max > 0,
       do: input

  defp normalize_unbroken_max(%__MODULE__{pacing_style: :unbroken, reps_per_set: reps} = input)
       when is_integer(reps) and reps > 0,
       do: %{input | max_unbroken_reps: reps}

  defp normalize_unbroken_max(input), do: input

  defp normalize_legacy_block_pattern(
         %__MODULE__{
           pacing_style: :unbroken,
           block_structure: nil,
           block_pattern: pattern,
           burpee_count_target: total_reps
         } = input
       )
       when is_list(pattern) and pattern != [] do
    set_pattern = expand_legacy_pattern(total_reps, pattern)

    case block_specs_from_set_pattern(set_pattern) do
      {:ok, blocks} -> %{input | block_structure: blocks}
      {:error, _reason} -> input
    end
  end

  defp normalize_legacy_block_pattern(input), do: input

  defp expand_legacy_pattern(total_reps, pattern) do
    {full_repeats, remainder_pattern} = split_pattern(total_reps, pattern)

    pattern
    |> List.duplicate(full_repeats)
    |> List.flatten()
    |> Kernel.++(remainder_pattern)
  end

  defp block_specs_from_set_pattern(set_pattern) do
    set_pattern
    |> Enum.chunk_every(2)
    |> Enum.chunk_by(& &1)
    |> Enum.reduce_while({:ok, []}, fn same_motif_chunks, {:ok, acc} ->
      motif = hd(same_motif_chunks)

      case BlockSpec.new(length(same_motif_chunks), motif) do
        {:ok, block} -> {:cont, {:ok, acc ++ [block]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp split_pattern(total_reps, pattern) do
    block_total = Enum.sum(pattern)
    full_repeats = div(total_reps, block_total)
    remainder = rem(total_reps, block_total)

    remainder_pattern =
      if remainder > 0 do
        pattern
        |> Enum.reduce_while({[], remainder}, fn reps, {acc, remaining} ->
          cond do
            remaining == 0 -> {:halt, {acc, 0}}
            reps <= remaining -> {:cont, {acc ++ [reps], remaining - reps}}
            true -> {:halt, {acc ++ [remaining], 0}}
          end
        end)
        |> elem(0)
      else
        []
      end

    {full_repeats, remainder_pattern}
  end

  defp validate_canonical(%__MODULE__{} = input) do
    cond do
      input.burpee_type not in [:six_count, :navy_seal] ->
        invalid_input(:burpee_type, input.burpee_type)

      input.pacing_style not in [:even, :unbroken] ->
        invalid_input(:pacing_style, input.pacing_style)

      not (is_integer(input.target_duration_sec) and input.target_duration_sec > 0) ->
        invalid_input(:target_duration_sec, input.target_duration_sec)

      not (is_integer(input.burpee_count_target) and input.burpee_count_target > 0) ->
        invalid_input(:burpee_count_target, input.burpee_count_target)

      input.pacing_style == :unbroken and
          not (is_integer(input.max_unbroken_reps) and input.max_unbroken_reps > 0) ->
        invalid_input(:max_unbroken_reps, input.max_unbroken_reps)

      true ->
        {:ok, input}
    end
  end

  defp invalid_input(field, value) do
    {:error,
     %Infeasible{
       reason: :invalid_input,
       details: %{field: field, value: value},
       suggestions: []
     }}
  end

  defp fetch_rest_value(rest, key) when is_map(rest) do
    Map.get(rest, key) || Map.get(rest, Atom.to_string(key))
  end
end
