defmodule BurpeeTrainer.Planning.Goal do
  @moduledoc """
  Required planner goal.

  This is the stable problem statement for draft generation. The solver may
  rebalance structure, pace, and rest, but must not silently change these goal
  facts.
  """

  @enforce_keys [:duration_sec, :target_reps, :burpee_type, :style]
  defstruct [
    :duration_sec,
    :target_reps,
    :burpee_type,
    :style,
    :max_reps_per_set,
    :requested_rest,
    preferred_unit_sec: 120,
    rest_targets_sec: [12 * 60, 17 * 60]
  ]

  @type burpee_type :: :six_count | :navy_seal
  @type style :: :even | :unbroken

  @type error :: {atom(), atom()}

  @type t :: %__MODULE__{
          duration_sec: pos_integer(),
          target_reps: pos_integer(),
          burpee_type: burpee_type(),
          style: style(),
          max_reps_per_set: pos_integer() | nil,
          requested_rest: %{target_sec: pos_integer(), duration_sec: pos_integer()} | nil,
          preferred_unit_sec: pos_integer(),
          rest_targets_sec: [pos_integer()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, [error()]}
  def new(attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    errors =
      []
      |> require_key(attrs, :duration_sec)
      |> require_key(attrs, :target_reps)
      |> require_key(attrs, :burpee_type)
      |> require_key(attrs, :style)
      |> validate_positive(attrs, :duration_sec)
      |> validate_positive(attrs, :target_reps)
      |> validate_burpee_type(attrs)
      |> validate_style(attrs)
      |> validate_unbroken(attrs)
      |> validate_requested_rest(attrs)

    case errors do
      [] ->
        {:ok,
         %__MODULE__{
           duration_sec: attrs.duration_sec,
           target_reps: attrs.target_reps,
           burpee_type: attrs.burpee_type,
           style: attrs.style,
           max_reps_per_set: Map.get(attrs, :max_reps_per_set),
           requested_rest: Map.get(attrs, :requested_rest),
           preferred_unit_sec: Map.get(attrs, :preferred_unit_sec, 120),
           rest_targets_sec: Map.get(attrs, :rest_targets_sec, [12 * 60, 17 * 60])
         }}

      [_ | _] ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp require_key(errors, attrs, key) do
    if Map.has_key?(attrs, key), do: errors, else: [{key, :required} | errors]
  end

  defp validate_positive(errors, attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value > 0 -> errors
      nil -> errors
      _ -> [{key, :must_be_positive_integer} | errors]
    end
  end

  defp validate_burpee_type(errors, attrs) do
    case Map.get(attrs, :burpee_type) do
      type when type in [:six_count, :navy_seal] -> errors
      nil -> errors
      _ -> [{:burpee_type, :unsupported} | errors]
    end
  end

  defp validate_style(errors, attrs) do
    case Map.get(attrs, :style) do
      style when style in [:even, :unbroken] -> errors
      nil -> errors
      _ -> [{:style, :unsupported} | errors]
    end
  end

  defp validate_unbroken(errors, %{style: :unbroken} = attrs) do
    case Map.get(attrs, :max_reps_per_set) do
      value when is_integer(value) and value > 0 -> errors
      _ -> [{:max_reps_per_set, :required_for_unbroken} | errors]
    end
  end

  defp validate_unbroken(errors, _attrs), do: errors

  defp validate_requested_rest(errors, attrs) do
    case Map.get(attrs, :requested_rest) do
      nil ->
        errors

      %{target_sec: target_sec, duration_sec: duration_sec}
      when is_integer(target_sec) and is_integer(duration_sec) ->
        cond do
          target_sec <= 0 ->
            [{:requested_rest, :outside_duration} | errors]

          duration_sec <= 0 ->
            [{:requested_rest, :outside_duration} | errors]

          target_sec >= attrs.duration_sec ->
            [{:requested_rest, :outside_duration} | errors]

          duration_sec >= attrs.duration_sec ->
            [{:requested_rest, :outside_duration} | errors]

          true ->
            errors
        end

      _ ->
        [{:requested_rest, :invalid} | errors]
    end
  end
end
