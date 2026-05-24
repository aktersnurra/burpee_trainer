defmodule BurpeeTrainer.PlanEditor do
  @moduledoc """
  Pure plan-editor transitions extracted from the plan LiveView.
  """

  alias BurpeeTrainer.BurpeeType
  alias BurpeeTrainer.PlanEditor.State
  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @type input :: %{
          name: String.t(),
          burpee_type: PlanSolver.Input.burpee_type(),
          target_duration_min: pos_integer(),
          burpee_count_target: pos_integer(),
          pacing_style: PlanSolver.Input.pacing_style(),
          reps_per_set: pos_integer() | nil,
          additional_rests: [PlanSolver.Input.additional_rest()],
          sec_per_burpee_override: float() | nil
        }

  @spec new(atom(), map()) :: {:ok, State.t()}
  def new(level, params) do
    state = %State{
      plan: nil,
      input: default_input() |> apply_coach_params(params),
      level: level
    }

    {:ok, state}
  end

  @spec from_plan(WorkoutPlan.t(), atom()) :: {:ok, State.t()}
  def from_plan(%WorkoutPlan{} = plan, level) do
    state = %State{
      plan: plan,
      input: input_from_plan(plan),
      level: level
    }

    {:ok, state}
  end

  @spec default_input() :: input()
  def default_input do
    %{
      name: "New plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      pacing_style: :even,
      reps_per_set: PlanSolver.default_reps_per_set(:six_count),
      additional_rests: [],
      sec_per_burpee_override: nil
    }
  end

  @spec apply_coach_params(input(), map()) :: input()
  def apply_coach_params(plan_input, params) do
    plan_input
    |> maybe_put_count(params)
    |> maybe_put_pace(params)
  end

  @spec pick_type(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def pick_type(%State{} = state, type) do
    case BurpeeType.parse(type) do
      {:ok, burpee_type} ->
        input = %{
          state.input
          | burpee_type: burpee_type,
            reps_per_set: PlanSolver.default_reps_per_set(burpee_type)
        }

        {:ok, %{state | input: input}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec pick_pacing(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def pick_pacing(%State{} = state, style) when style in ["even", "unbroken", :even, :unbroken] do
    pacing_style = if is_binary(style), do: String.to_existing_atom(style), else: style
    {:ok, %{state | input: %{state.input | pacing_style: pacing_style}}}
  end

  def pick_pacing(%State{} = state, style), do: {:error, {:invalid_pacing_style, style}, state}

  @spec set_pace_override(State.t(), term()) :: {:ok, State.t()}
  def set_pace_override(%State{} = state, pace) do
    override =
      case parse_positive_float(pace) do
        {:ok, pace} -> pace
        {:error, _reason} -> nil
      end

    {:ok, %{state | input: %{state.input | sec_per_burpee_override: override}}}
  end

  @spec add_rest(State.t()) :: {:ok, State.t()}
  def add_rest(%State{} = state) do
    current = state.input
    count = length(current.additional_rests) + 1
    target_min = max(1, div(current.target_duration_min * count, count + 1))
    rest = %{rest_sec: 30, target_min: target_min}

    {:ok, %{state | input: %{current | additional_rests: current.additional_rests ++ [rest]}}}
  end

  @spec remove_rest(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def remove_rest(%State{} = state, index) do
    case parse_non_negative_integer(index) do
      {:ok, index} ->
        rests = List.delete_at(state.input.additional_rests, index)
        {:ok, %{state | input: %{state.input | additional_rests: rests}}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec change_rest(State.t(), map()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def change_rest(%State{} = state, rest_params) do
    with {:ok, index} <- parse_non_negative_integer(Map.get(rest_params, "index", "0")) do
      existing = Enum.at(state.input.additional_rests, index, %{rest_sec: 30, target_min: 10})

      rest_sec =
        parse_positive_integer_or(Map.get(rest_params, "rest_sec", ""), existing.rest_sec)

      target_min =
        parse_positive_integer_or(Map.get(rest_params, "target_min", ""), existing.target_min)

      rests =
        List.update_at(state.input.additional_rests, index, fn _ ->
          %{rest_sec: rest_sec, target_min: target_min}
        end)

      {:ok, %{state | input: %{state.input | additional_rests: rests}}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec input_from_plan(WorkoutPlan.t()) :: input()
  def input_from_plan(plan) do
    rests =
      case Jason.decode(plan.additional_rests || "[]") do
        {:ok, list} when is_list(list) ->
          Enum.map(list, fn %{"rest_sec" => rest_sec, "target_min" => target_min} ->
            %{rest_sec: rest_sec, target_min: target_min}
          end)

        _ ->
          []
      end

    %{
      name: plan.name,
      burpee_type: plan.burpee_type,
      target_duration_min: plan.target_duration_min || 20,
      burpee_count_target: plan.burpee_count_target || 100,
      pacing_style: plan.pacing_style || :even,
      reps_per_set: infer_reps_per_set(plan),
      additional_rests: rests,
      sec_per_burpee_override: nil
    }
  end

  defp maybe_put_count(plan_input, %{"count" => count_str}) do
    case Integer.parse(count_str) do
      {count, ""} when count > 0 -> %{plan_input | burpee_count_target: count}
      _ -> plan_input
    end
  end

  defp maybe_put_count(plan_input, _params), do: plan_input

  defp maybe_put_pace(plan_input, %{"pace" => pace_str}) do
    case Float.parse(pace_str) do
      {pace, _} when pace > 0 -> %{plan_input | sec_per_burpee_override: pace}
      _ -> plan_input
    end
  end

  defp maybe_put_pace(plan_input, _params), do: plan_input

  defp parse_positive_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} when number > 0 -> {:ok, number}
      _ -> {:error, {:invalid_pace, value}}
    end
  end

  defp parse_positive_float(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp parse_positive_float(value), do: {:error, {:invalid_pace, value}}

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_index, value}}
    end
  end

  defp parse_non_negative_integer(value), do: {:error, {:invalid_index, value}}

  defp parse_positive_integer_or(value, default) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp infer_reps_per_set(plan) do
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
end
