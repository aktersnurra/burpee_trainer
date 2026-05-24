defmodule BurpeeTrainer.PlanEditor do
  @moduledoc """
  Pure plan-editor transitions extracted from the plan LiveView.
  """

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defmodule Derived do
    @moduledoc """
    Derived editor values computed from the current form and solver state.
    """

    defstruct [:summary, :duration_ok?, :reps_ok?, :can_save?]

    @type t :: %__MODULE__{}
  end

  defmodule State do
    @moduledoc """
    Plan editor state shared by the LiveView and pure editor transitions.
    """

    defstruct [
      :plan,
      :input,
      :level,
      :solver_error,
      :solver_solution,
      :derived,
      manual_edit?: false,
      expanded_blocks: MapSet.new(),
      open_block_menu: nil
    ]

    @type t :: %__MODULE__{}
  end

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
