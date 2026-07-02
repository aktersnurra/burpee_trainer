defmodule BurpeeTrainer.PlanEditor.Input do
  @moduledoc """
  Typed boundary value for plan-editor inputs.

  Raw LiveView params are normalized into this struct before plan-editor
  transitions and the plan solver rely on them.
  """

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.PlanEditor.{Block, Set}
  alias BurpeeTrainer.Workouts.WorkoutPlan

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
          block_pattern: [pos_integer()] | nil,
          manual_structure?: boolean(),
          pace_bias: :slower | :balanced | :faster,
          load_shape: :even | :front_loaded | :back_loaded
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
    block_pattern: nil,
    manual_structure?: false,
    pace_bias: :balanced,
    load_shape: :even
  ]

  @spec default() :: t()
  def default do
    %__MODULE__{
      name: "New workout",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      pacing_style: :even,
      reps_per_set: PlanSolver.default_reps_per_set(:six_count),
      additional_rests: [],
      sec_per_burpee_override: nil,
      block_pattern: nil,
      manual_structure?: false,
      pace_bias: :balanced,
      load_shape: :even
    }
  end

  @spec apply_coach_params(t(), map()) :: t()
  def apply_coach_params(%__MODULE__{} = input, params) when is_map(params) do
    input
    |> maybe_put_count(params)
    |> maybe_put_pace(params)
  end

  @spec from_plan(WorkoutPlan.t()) :: t()
  def from_plan(%WorkoutPlan{source_json: source} = plan) when is_map(source) do
    block_pattern = source_block_pattern(source) || infer_block_pattern(plan)

    %__MODULE__{
      name: plan.name,
      burpee_type: source_burpee_type(source, plan.burpee_type || :six_count),
      target_duration_min: source_target_duration_min(source, plan.target_duration_min || 20),
      burpee_count_target: source_target_reps(source, plan.burpee_count_target || 100),
      pacing_style: source_pacing_style(source, plan.pacing_style || :even),
      reps_per_set: source_max_unbroken_reps(source) || infer_reps_per_set(plan),
      additional_rests: source_additional_rests(source),
      sec_per_burpee_override: source_sec_per_rep_override(source),
      block_pattern: block_pattern,
      manual_structure?: not is_nil(block_pattern),
      pace_bias:
        source_metadata_atom(
          source,
          :pace_bias,
          metadata_atom(plan.plan_solver_metadata, :pace_bias, :balanced)
        ),
      load_shape:
        source_metadata_atom(
          source,
          :load_shape,
          metadata_atom(plan.plan_solver_metadata, :load_shape, :even)
        )
    }
  end

  def from_plan(%WorkoutPlan{} = plan) do
    %__MODULE__{
      name: plan.name,
      burpee_type: plan.burpee_type,
      target_duration_min: plan.target_duration_min || 20,
      burpee_count_target: plan.burpee_count_target || 100,
      pacing_style: plan.pacing_style || :even,
      reps_per_set: infer_reps_per_set(plan),
      additional_rests: decode_additional_rests(plan.additional_rests),
      sec_per_burpee_override: nil,
      block_pattern: infer_block_pattern(plan),
      manual_structure?: false,
      pace_bias: metadata_atom(plan.plan_solver_metadata, :pace_bias, :balanced),
      load_shape: metadata_atom(plan.plan_solver_metadata, :load_shape, :even)
    }
  end

  @spec change_basics(t(), map()) :: {:ok, t()}
  def change_basics(%__MODULE__{} = input, params) when is_map(params) do
    {:ok,
     %{
       input
       | name: non_blank_name_or(Map.get(params, "name", input.name), input.name),
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
      |> Enum.flat_map(fn {idx, value} ->
        case Integer.parse(to_string(idx)) do
          {index, ""} -> [{index, value}]
          _other -> []
        end
      end)
      |> Enum.sort_by(fn {idx, _value} -> idx end)
      |> Enum.map(fn {_idx, value} -> parse_positive_integer(value) end)
      |> Enum.reject(&is_nil/1)

    {:ok, %{input | block_pattern: pattern, manual_structure?: pattern != []}}
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

  @spec set_pace_bias(t(), term()) :: {:ok, t()}
  def set_pace_bias(%__MODULE__{} = input, bias) do
    bias =
      case to_string(bias || "") do
        "faster" -> :faster
        "slower" -> :slower
        _ -> :balanced
      end

    {:ok, %{input | pace_bias: bias, sec_per_burpee_override: nil}}
  end

  @spec set_load_shape(t(), term()) :: {:ok, t()}
  def set_load_shape(%__MODULE__{} = input, shape) do
    shape =
      case to_string(shape || "") do
        "front_loaded" -> :front_loaded
        "back_loaded" -> :back_loaded
        _ -> :even
      end

    {:ok, %{input | load_shape: shape}}
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

  defp non_blank_name_or(value, fallback) do
    case String.trim(to_string(value || "")) do
      "" -> fallback
      name -> name
    end
  end

  defp metadata_atom(metadata, key, fallback) when is_map(metadata) do
    value = Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

    cond do
      value in [:slower, :balanced, :faster, :even, :front_loaded, :back_loaded] -> value
      is_binary(value) -> safe_existing_atom(value, fallback)
      true -> fallback
    end
  end

  defp metadata_atom(_metadata, _key, fallback), do: fallback

  defp safe_existing_atom(value, fallback) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> fallback
  end

  defp decode_additional_rests(json) do
    case Jason.decode(json || "[]") do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, &editor_rest_from_map/1)

      _ ->
        []
    end
  end

  defp source_burpee_type(source, fallback) do
    case source_value(source, :burpee_type) do
      "six_count" -> :six_count
      "navy_seal" -> :navy_seal
      value when value in [:six_count, :navy_seal] -> value
      _ -> fallback
    end
  end

  defp source_pacing_style(source, fallback) do
    case source_value(source, :pacing_style) do
      "even" -> :even
      "unbroken" -> :unbroken
      value when value in [:even, :unbroken] -> value
      _ -> fallback
    end
  end

  defp source_target_reps(source, fallback),
    do: positive_integer_or(source_value(source, :target_reps), fallback)

  defp source_target_duration_min(source, fallback) do
    source
    |> source_value(:target_duration_sec)
    |> positive_integer_or(fallback * 60)
    |> div(60)
    |> max(1)
  end

  defp source_max_unbroken_reps(source),
    do: positive_integer_or(source_value(source, :max_unbroken_reps), nil)

  defp source_sec_per_rep_override(source) do
    case parse_positive_float(source_value(source, :sec_per_rep_override)) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp source_block_pattern(source) do
    case source_value(source, :block_pattern) do
      pattern when is_list(pattern) ->
        pattern
        |> Enum.map(&positive_integer_or(&1, nil))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          pattern -> pattern
        end

      _ ->
        nil
    end
  end

  defp source_additional_rests(source) do
    source
    |> source_value(:explicit_rests)
    |> case do
      rests when is_list(rests) -> Enum.flat_map(rests, &editor_rest_from_map/1)
      _ -> []
    end
  end

  defp editor_rest_from_map(%{"rest_sec" => rest_sec, "target_min" => target_min}) do
    rest_sec = positive_integer_or(rest_sec, nil)
    target_min = positive_integer_or(target_min, nil)
    if rest_sec && target_min, do: [%{rest_sec: rest_sec, target_min: target_min}], else: []
  end

  defp editor_rest_from_map(%{
         "duration_sec" => duration_sec,
         "target_elapsed_sec" => target_elapsed_sec
       }) do
    duration_sec = positive_integer_or(duration_sec, nil)
    target_elapsed_sec = positive_integer_or(target_elapsed_sec, nil)

    if duration_sec && target_elapsed_sec do
      [%{rest_sec: duration_sec, target_min: max(1, round(target_elapsed_sec / 60))}]
    else
      []
    end
  end

  defp editor_rest_from_map(%{rest_sec: rest_sec, target_min: target_min}),
    do: editor_rest_from_map(%{"rest_sec" => rest_sec, "target_min" => target_min})

  defp editor_rest_from_map(%{
         duration_sec: duration_sec,
         target_elapsed_sec: target_elapsed_sec
       }),
       do:
         editor_rest_from_map(%{
           "duration_sec" => duration_sec,
           "target_elapsed_sec" => target_elapsed_sec
         })

  defp editor_rest_from_map(_rest), do: []

  defp source_metadata_atom(source, key, fallback) do
    case source_value(source, key) do
      value when value in [:slower, :balanced, :faster, :even, :front_loaded, :back_loaded] ->
        value

      value when is_binary(value) ->
        safe_existing_atom(value, fallback)

      _ ->
        fallback
    end
  end

  defp source_value(source, key), do: Map.get(source, key) || Map.get(source, Atom.to_string(key))

  defp infer_block_pattern(%WorkoutPlan{} = plan) do
    plan.blocks
    |> Enum.sort_by(& &1.position)
    |> List.first()
    |> case do
      %Block{sets: sets} ->
        sets
        |> Enum.sort_by(& &1.position)
        |> Enum.map(& &1.burpee_count)
        |> case do
          [] -> nil
          pattern -> pattern
        end

      _ ->
        nil
    end
  end

  defp infer_reps_per_set(%WorkoutPlan{} = plan) do
    first_set =
      plan.blocks
      |> Enum.sort_by(& &1.position)
      |> List.first()
      |> case do
        nil -> nil
        %Block{sets: sets} -> sets |> Enum.sort_by(& &1.position) |> List.first()
      end

    (match?(%Set{}, first_set) && first_set.burpee_count) ||
      PlanSolver.default_reps_per_set(plan.burpee_type)
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
