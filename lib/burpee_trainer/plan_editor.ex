defmodule BurpeeTrainer.PlanEditor do
  @moduledoc """
  Pure plan-editor transitions extracted from the plan LiveView.
  """

  alias BurpeeTrainer.BurpeeType
  alias BurpeeTrainer.PlanEditor.{Derived, Input, State}
  alias BurpeeTrainer.{Planner, PlanSolver}
  alias BurpeeTrainer.PlanSolver.Input, as: SolverInput
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @type input :: Input.t()

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
    input = input_from_plan(plan)

    state = %State{
      plan: plan,
      form_plan: plan,
      input: input,
      level: level,
      solver_solution: nil,
      derived: derived(plan, input)
    }

    {:ok, state}
  end

  @spec default_input() :: input()
  def default_input do
    Input.default()
  end

  @spec apply_coach_params(input(), map()) :: input()
  def apply_coach_params(%Input{} = plan_input, params) do
    Input.apply_coach_params(plan_input, params)
  end

  @spec pick_type(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
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

  @spec pick_pacing(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def pick_pacing(%State{} = state, style) when style in ["even", "unbroken", :even, :unbroken] do
    pacing_style = if is_binary(style), do: String.to_existing_atom(style), else: style
    {:ok, %{state | input: %{state.input | pacing_style: pacing_style}}}
  end

  def pick_pacing(%State{} = state, style), do: {:error, {:invalid_pacing_style, style}, state}

  @spec change_block_pattern(State.t(), map()) :: {:ok, State.t()}
  def change_block_pattern(%State{} = state, params) do
    {:ok, input} = Input.change_block_pattern(state.input, params)

    state
    |> put_input(input)
    |> regenerate()
  end

  @spec set_pace_override(State.t(), term()) :: {:ok, State.t()}
  def set_pace_override(%State{} = state, pace) do
    {:ok, input} = Input.set_pace_override(state.input, pace)
    {:ok, %{state | input: input}}
  end

  @spec add_rest(State.t()) :: {:ok, State.t()}
  def add_rest(%State{} = state) do
    current = state.input
    count = length(current.additional_rests) + 1
    target_min = max(1, div(current.target_duration_min * count, count + 1))
    rest = %{rest_sec: 30, target_min: target_min}

    {:ok, %{state | input: %{current | additional_rests: current.additional_rests ++ [rest]}}}
  end

  @spec remove_rest(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def remove_rest(%State{} = state, index) do
    case Input.parse_non_negative_index(index) do
      {:ok, index} ->
        rests = List.delete_at(state.input.additional_rests, index)
        {:ok, %{state | input: %{state.input | additional_rests: rests}}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec change_rest(State.t(), map()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def change_rest(%State{} = state, rest_params) do
    case Input.change_rest(state.input, rest_params) do
      {:ok, input} -> {:ok, %{state | input: input}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec regenerate(State.t()) :: {:ok, State.t()}
  def regenerate(%State{} = state) do
    solver_input = %SolverInput{
      name: state.input.name,
      burpee_type: state.input.burpee_type,
      target_duration_min: state.input.target_duration_min,
      burpee_count_target: state.input.burpee_count_target,
      pacing_style: state.input.pacing_style,
      level: state.level,
      reps_per_set: state.input.reps_per_set,
      additional_rests: state.input.additional_rests,
      sec_per_burpee_override: state.input.sec_per_burpee_override,
      block_pattern: state.input.block_pattern
    }

    case PlanSolver.solve(solver_input) do
      {:ok, solution} ->
        {:ok,
         %{
           state
           | solver_error: nil,
             solver_solution: solution,
             form_plan: solution.plan,
             manual_edit?: false,
             derived: derived(solution.plan, state.input)
         }}

      {:error, reasons} ->
        {:ok, %{state | solver_error: Enum.join(reasons, "; "), solver_solution: nil}}
    end
  end

  @spec change_basics(State.t(), map()) :: {:ok, State.t()}
  def change_basics(%State{} = state, params) do
    {:ok, input} = Input.change_basics(state.input, params)

    state
    |> put_input(input)
    |> regenerate()
  end

  @spec derived(WorkoutPlan.t(), input()) :: Derived.t()
  def derived(%WorkoutPlan{} = plan, plan_input) do
    if can_summarize?(plan) do
      summary = Planner.summary(plan)
      target_sec = plan_input.target_duration_min * 60
      target_count = plan_input.burpee_count_target

      duration_ok = abs(summary.duration_sec_total - target_sec) <= 5
      count_ok = summary.burpee_count_total == target_count

      summary = %{
        duration_sec: summary.duration_sec_total,
        burpee_count: summary.burpee_count_total,
        target_sec: target_sec,
        target_count: target_count,
        duration_ok: duration_ok,
        count_ok: count_ok,
        both_ok: duration_ok and count_ok
      }

      %Derived{
        summary: summary,
        duration_ok?: duration_ok,
        reps_ok?: count_ok,
        can_save?: duration_ok and count_ok
      }
    else
      %Derived{}
    end
  end

  @spec derived(State.t()) :: Derived.t()
  def derived(%State{} = state) do
    case state.solver_solution do
      %{plan: %WorkoutPlan{} = plan} -> derived(plan, state.input)
      _ -> %Derived{}
    end
  end

  @spec enable_manual_edit(State.t()) :: {:ok, State.t()}
  def enable_manual_edit(%State{} = state), do: {:ok, %{state | manual_edit?: true}}

  @spec select_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def select_block(%State{} = state, index) do
    case Input.parse_non_negative_index(index) do
      {:ok, index} -> {:ok, %{state | selected_block_index: index}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec close_block(State.t()) :: {:ok, State.t()}
  def close_block(%State{} = state), do: {:ok, %{state | selected_block_index: nil}}

  @spec lock_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def lock_block(%State{} = state, index) do
    case Input.parse_non_negative_index(index) do
      {:ok, index} ->
        {:ok,
         %{
           state
           | locked_block_indexes: MapSet.put(state.locked_block_indexes, index),
             manual_edit?: true
         }}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec unlock_block(State.t(), term()) :: {:ok, State.t()} | {:error, Input.reason(), State.t()}
  def unlock_block(%State{} = state, index) do
    case Input.parse_non_negative_index(index) do
      {:ok, index} ->
        {:ok, %{state | locked_block_indexes: MapSet.delete(state.locked_block_indexes, index)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec rebalance_unlocked_blocks(State.t()) :: {:ok, State.t()}
  def rebalance_unlocked_blocks(%State{} = state) do
    locked_blocks = locked_blocks_by_index(state.form_plan, state.locked_block_indexes)

    {:ok, regenerated} = regenerate(state)

    form_plan = restore_locked_blocks(regenerated.form_plan, locked_blocks)

    {:ok,
     %{
       regenerated
       | form_plan: form_plan,
         locked_block_indexes: state.locked_block_indexes,
         manual_edit?: true,
         derived: derived(form_plan, state.input)
     }}
  end

  @spec copy_block(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def copy_block(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, index) do
    with {:ok, index} <- Input.parse_non_negative_index(index),
         blocks <- Enum.sort_by(blocks || [], & &1.position),
         %Block{} = source_block <- Enum.at(blocks, index) do
      copied_block = %{source_block | position: length(blocks) + 1}
      form_plan = %{state.form_plan | blocks: blocks ++ [copied_block]}

      {:ok,
       %{
         state
         | form_plan: form_plan,
           manual_edit?: true,
           derived: derived(form_plan, state.input)
       }}
    else
      nil -> {:error, {:missing_block, index}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def copy_block(%State{} = state, _index), do: {:error, :missing_form_plan, state}

  @spec copy_set(State.t(), term(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def copy_set(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, block_index, set_index) do
    with {:ok, block_index} <- Input.parse_non_negative_index(block_index),
         {:ok, set_index} <- Input.parse_non_negative_index(set_index),
         blocks <- Enum.sort_by(blocks || [], & &1.position),
         %Block{} = block <- Enum.at(blocks, block_index),
         sets <- Enum.sort_by(block.sets || [], & &1.position),
         %Set{} = source_set <- Enum.at(sets, set_index) do
      copied_set = %{source_set | position: length(sets) + 1}
      updated_block = %{block | sets: sets ++ [copied_set]}
      updated_blocks = List.replace_at(blocks, block_index, updated_block)
      form_plan = %{state.form_plan | blocks: updated_blocks}

      {:ok,
       %{
         state
         | form_plan: form_plan,
           manual_edit?: true,
           derived: derived(form_plan, state.input)
       }}
    else
      nil -> {:error, :missing_item, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def copy_set(%State{} = state, _block_index, _set_index),
    do: {:error, :missing_form_plan, state}

  defp locked_blocks_by_index(%WorkoutPlan{blocks: blocks}, locked_indexes)
       when is_list(blocks) do
    blocks
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {block, index}, acc ->
      if MapSet.member?(locked_indexes, index), do: Map.put(acc, index, block), else: acc
    end)
  end

  defp locked_blocks_by_index(_plan, _locked_indexes), do: %{}

  defp restore_locked_blocks(%WorkoutPlan{blocks: blocks} = plan, locked_blocks)
       when is_list(blocks) do
    blocks =
      blocks
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.with_index()
      |> Enum.map(fn {block, index} -> Map.get(locked_blocks, index, block) end)

    %{plan | blocks: blocks}
  end

  defp restore_locked_blocks(plan, _locked_blocks), do: plan

  @spec input_from_plan(WorkoutPlan.t()) :: input()
  def input_from_plan(%WorkoutPlan{} = plan) do
    Input.from_plan(plan)
  end

  defp put_input(%State{} = state, input), do: %{state | input: input}

  defp can_summarize?(%WorkoutPlan{blocks: blocks}) when is_list(blocks) and blocks != [] do
    Enum.all?(blocks, fn block ->
      is_integer(block.repeat_count) and block.repeat_count > 0 and
        is_list(block.sets) and block.sets != [] and
        Enum.all?(block.sets, fn set ->
          is_integer(set.burpee_count) and set.burpee_count >= 0 and
            is_number(set.sec_per_rep) and set.sec_per_rep > 0 and
            is_number(set.sec_per_burpee) and set.sec_per_burpee > 0 and
            is_number(set.end_of_set_rest)
        end)
    end)
  end

  defp can_summarize?(_), do: false
end
