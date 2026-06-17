defmodule BurpeeTrainer.PlanEditor.Input do
  @moduledoc """
  Typed boundary value for plan-editor inputs.

  Raw LiveView params are normalized into this struct before plan-editor
  transitions and the plan solver rely on them.
  """

  alias BurpeeTrainer.PlanSolver

  @type additional_rest :: PlanSolver.Input.additional_rest()

  @type reason ::
          {:invalid_index, term()}
          | {:invalid_positive_integer, atom(), term()}
          | {:invalid_pace, term()}
          | {:invalid_pacing_style, term()}
          | BurpeeTrainer.BurpeeType.error()

  @type t :: %__MODULE__{
          name: String.t(),
          burpee_type: PlanSolver.Input.burpee_type(),
          target_duration_min: pos_integer(),
          burpee_count_target: pos_integer(),
          pacing_style: PlanSolver.Input.pacing_style(),
          reps_per_set: pos_integer() | nil,
          additional_rests: [additional_rest()],
          sec_per_burpee_override: float() | nil,
          block_pattern: [pos_integer()] | nil
        }

  @enforce_keys [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style
  ]
  defstruct [
    :name,
    :burpee_type,
    :target_duration_min,
    :burpee_count_target,
    :pacing_style,
    reps_per_set: nil,
    additional_rests: [],
    sec_per_burpee_override: nil,
    block_pattern: nil
  ]

  @spec default() :: t()
  def default do
    %__MODULE__{
      name: "New plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      pacing_style: :even,
      reps_per_set: PlanSolver.default_reps_per_set(:six_count),
      additional_rests: [],
      sec_per_burpee_override: nil,
      block_pattern: nil
    }
  end

  @spec apply_coach_params(t(), map()) :: t()
  def apply_coach_params(%__MODULE__{} = input, params) when is_map(params) do
    input
    |> maybe_put_count(params)
    |> maybe_put_pace(params)
  end

  @spec change_basics(t(), map()) :: {:ok, t()}
  def change_basics(%__MODULE__{} = input, params) when is_map(params) do
    {:ok,
     %{
       input
       | name: Map.get(params, "name", input.name),
         target_duration_min:
           positive_integer_or(
             Map.get(params, "target_duration_min", ""),
             input.target_duration_min
           ),
         burpee_count_target:
           positive_integer_or(
             Map.get(params, "burpee_count_target", ""),
             input.burpee_count_target
           ),
         reps_per_set:
           positive_integer_or(Map.get(params, "reps_per_set", ""), input.reps_per_set)
     }}
  end

  @spec change_block_pattern(t(), map()) :: {:ok, t()}
  def change_block_pattern(%__MODULE__{} = input, params) when is_map(params) do
    pattern =
      params
      |> Map.get("pattern", %{})
      |> Enum.sort_by(fn {idx, _value} -> String.to_integer(to_string(idx)) end)
      |> Enum.map(fn {_idx, value} -> parse_positive_integer(value) end)
      |> Enum.reject(&is_nil/1)

    {:ok, %{input | block_pattern: pattern}}
  end

  @spec set_pace_override(t(), term()) :: {:ok, t()}
  def set_pace_override(%__MODULE__{} = input, pace) do
    override =
      case parse_positive_float(pace) do
        {:ok, pace} -> pace
        {:error, _reason} -> nil
      end

    {:ok, %{input | sec_per_burpee_override: override}}
  end

  @spec parse_non_negative_index(term()) ::
          {:ok, non_neg_integer()} | {:error, {:invalid_index, term()}}
  def parse_non_negative_index(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def parse_non_negative_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_index, value}}
    end
  end

  def parse_non_negative_index(value), do: {:error, {:invalid_index, value}}

  @spec change_rest(t(), map()) :: {:ok, t()} | {:error, {:invalid_index, term()}}
  def change_rest(%__MODULE__{} = input, rest_params) when is_map(rest_params) do
    with {:ok, index} <- parse_non_negative_index(Map.get(rest_params, "index", "0")) do
      existing = Enum.at(input.additional_rests, index, %{rest_sec: 30, target_min: 10})

      rest_sec = positive_integer_or(Map.get(rest_params, "rest_sec", ""), existing.rest_sec)

      target_min =
        positive_integer_or(Map.get(rest_params, "target_min", ""), existing.target_min)

      rests =
        List.update_at(input.additional_rests, index, fn _rest ->
          %{rest_sec: rest_sec, target_min: target_min}
        end)

      {:ok, %{input | additional_rests: rests}}
    end
  end

  defp maybe_put_count(%__MODULE__{} = input, %{"count" => count_str}) do
    case Integer.parse(to_string(count_str || "")) do
      {count, ""} when count > 0 -> %{input | burpee_count_target: count}
      _ -> input
    end
  end

  defp maybe_put_count(%__MODULE__{} = input, _params), do: input

  defp maybe_put_pace(%__MODULE__{} = input, %{"pace" => pace_str}) do
    case Float.parse(to_string(pace_str || "")) do
      {pace, _rest} when pace > 0 -> %{input | sec_per_burpee_override: pace}
      _ -> input
    end
  end

  defp maybe_put_pace(%__MODULE__{} = input, _params), do: input

  defp parse_positive_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} when number > 0 -> {:ok, number}
      _ -> {:error, {:invalid_pace, value}}
    end
  end

  defp parse_positive_float(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp parse_positive_float(value), do: {:error, {:invalid_pace, value}}

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer_or(value, default) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end
end
