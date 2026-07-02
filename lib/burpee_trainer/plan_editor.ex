defmodule BurpeeTrainer.PlanEditor do
  @moduledoc """
  Pure plan-editor transitions extracted from the plan LiveView.
  """

  alias BurpeeTrainer.BurpeeType
  alias BurpeeTrainer.PlanEditor.{Derived, Input, State}
  alias BurpeeTrainer.{Planner, PlanSolver}
  alias BurpeeTrainer.PlanSolver.{ExplicitRest, PacePolicy}
  alias BurpeeTrainer.PlanSolver.Input, as: SolverInput
  alias BurpeeTrainer.PlanEditor.{Block, PlanStep, Set}
  alias BurpeeTrainer.Workouts.WorkoutPlan

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
      derived: %Derived{}
    }

    with {:ok, state} <- regenerate(state) do
      {:ok, %{state | plan: plan}}
    end
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

  @spec set_pace_bias(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def set_pace_bias(%State{} = state, bias) when bias in ["slower", "balanced", "faster"] do
    {:ok, input} = Input.set_pace_bias(state.input, bias)
    {:ok, %{state | input: input}}
  end

  def set_pace_bias(%State{} = state, bias) when bias in [:slower, :balanced, :faster] do
    {:ok, input} = Input.set_pace_bias(state.input, bias)
    {:ok, %{state | input: input}}
  end

  def set_pace_bias(%State{} = state, bias), do: {:error, {:invalid_pace_bias, bias}, state}

  @spec set_load_shape(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def set_load_shape(%State{} = state, shape)
      when shape in ["even", "front_loaded", "back_loaded"] do
    {:ok, %{state | input: %{state.input | load_shape: String.to_existing_atom(shape)}}}
  end

  def set_load_shape(%State{} = state, shape)
      when shape in [:even, :front_loaded, :back_loaded] do
    {:ok, %{state | input: %{state.input | load_shape: shape}}}
  end

  def set_load_shape(%State{} = state, shape), do: {:error, {:invalid_load_shape, shape}, state}

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
      target_duration_sec: state.input.target_duration_min * 60,
      burpee_count_target: state.input.burpee_count_target,
      pacing_style: state.input.pacing_style,
      level: state.level,
      max_unbroken_reps: if(state.input.pacing_style == :unbroken, do: state.input.reps_per_set),
      explicit_rests: explicit_rests_from_editor(state.input.additional_rests),
      sec_per_rep_override:
        state.input.sec_per_burpee_override || pace_bias_override(state.input),
      block_pattern: if(state.input.manual_structure?, do: state.input.block_pattern, else: nil),
      pace_bias: state.input.pace_bias,
      load_shape: state.input.load_shape
    }

    locked_blocks = locked_blocks_by_index(state.form_plan, state.locked_block_indexes)
    preserve_manual_plan? = preserve_manual_plan?(state)

    case PlanSolver.generate_plan(solver_input) do
      {:ok, solution} ->
        form_plan =
          if preserve_manual_plan? do
            merge_manual_plan(solution.plan, state.form_plan)
          else
            restore_locked_blocks(solution.plan, locked_blocks)
          end

        manual_edit? =
          state.manual_edit? and (preserve_manual_plan? or map_size(locked_blocks) > 0)

        {:ok,
         %{
           state
           | solver_error: nil,
             solver_solution: solution,
             form_plan: form_plan,
             manual_edit?: manual_edit?,
             derived: derived(form_plan, state.input)
         }}

      {:error, reasons} ->
        {:ok,
         %{
           state
           | solver_error: Enum.join(reasons, "; "),
             solver_solution: nil,
             derived: %Derived{}
         }}
    end
  end

  @spec change_basics(State.t(), map()) :: {:ok, State.t()}
  def change_basics(%State{} = state, params) do
    {:ok, input} = Input.change_basics(state.input, params)
    state = put_input(state, input)

    if solver_basic_params?(params) do
      regenerate(state)
    else
      form_plan = rename_form_plan(state.form_plan, input.name)
      {:ok, %{state | form_plan: form_plan, derived: derived_or_empty(form_plan, input)}}
    end
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
      copied_block = copy_block_as_new(source_block, length(blocks) + 1)
      steps = schedule_copied_block(state.form_plan.steps, copied_block.position)
      form_plan = %{state.form_plan | blocks: blocks ++ [copied_block], steps: steps}

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

  @spec delete_block(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def delete_block(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, index) do
    sorted = Enum.sort_by(blocks || [], & &1.position)

    with {:ok, index} <- Input.parse_non_negative_index(index),
         %Block{} = target <- Enum.at(sorted, index),
         true <- length(sorted) > 1 do
      remaining = List.delete_at(sorted, index) |> renumber_blocks()
      steps = drop_block_run_step(state.form_plan.steps, target.position)
      form_plan = %{state.form_plan | blocks: remaining, steps: steps}

      {:ok,
       %{
         state
         | form_plan: form_plan,
           locked_block_indexes: shift_locked_indexes(state.locked_block_indexes, index),
           manual_edit?: true,
           derived: derived(form_plan, state.input)
       }}
    else
      false -> {:error, :last_block, state}
      nil -> {:error, {:missing_block, index}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def delete_block(%State{} = state, _index), do: {:error, :missing_form_plan, state}

  defp renumber_blocks(blocks) do
    blocks
    |> Enum.with_index(1)
    |> Enum.map(fn {block, position} -> %{block | position: position} end)
  end

  # Drops the block_run step for the deleted block, decrements block_position for
  # steps referencing later blocks, and renumbers all step positions contiguously.
  defp drop_block_run_step(steps, deleted_position) when is_list(steps) do
    steps
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.reject(fn step ->
      step.kind == :block_run and step.block_position == deleted_position
    end)
    |> Enum.map(fn step ->
      if step.kind == :block_run and step.block_position > deleted_position do
        %{step | block_position: step.block_position - 1}
      else
        step
      end
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp drop_block_run_step(steps, _deleted_position), do: steps

  defp shift_locked_indexes(locked, deleted_index) do
    locked
    |> Enum.reject(&(&1 == deleted_index))
    |> Enum.map(fn i -> if i > deleted_index, do: i - 1, else: i end)
    |> MapSet.new()
  end

  @spec copy_set(State.t(), term(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def copy_set(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, block_index, set_index) do
    with {:ok, block_index} <- Input.parse_non_negative_index(block_index),
         {:ok, set_index} <- Input.parse_non_negative_index(set_index),
         blocks <- Enum.sort_by(blocks || [], & &1.position),
         %Block{} = block <- Enum.at(blocks, block_index),
         sets <- Enum.sort_by(block.sets || [], & &1.position),
         %Set{} = source_set <- Enum.at(sets, set_index) do
      copied_set = %{source_set | id: nil, block_id: nil, position: length(sets) + 1}
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

  @spec add_set(State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def add_set(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, block_index) do
    with {:ok, block_index} <- Input.parse_non_negative_index(block_index),
         blocks <- Enum.sort_by(blocks || [], & &1.position),
         %Block{} = block <- Enum.at(blocks, block_index) do
      sets = Enum.sort_by(block.sets || [], & &1.position)
      template = List.last(sets)

      new_set = %Set{
        position: length(sets) + 1,
        burpee_count: (template && template.burpee_count) || 8,
        sec_per_rep: template && template.sec_per_rep,
        sec_per_burpee: template && template.sec_per_burpee,
        end_of_set_rest: (template && template.end_of_set_rest) || 0
      }

      updated_block = %{block | sets: sets ++ [new_set]}
      form_plan = %{state.form_plan | blocks: List.replace_at(blocks, block_index, updated_block)}

      {:ok,
       %{
         state
         | form_plan: form_plan,
           manual_edit?: true,
           derived: derived(form_plan, state.input)
       }}
    else
      nil -> {:error, {:missing_block, block_index}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def add_set(%State{} = state, _block_index), do: {:error, :missing_form_plan, state}

  @spec delete_set(State.t(), term(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def delete_set(%State{form_plan: %WorkoutPlan{blocks: blocks}} = state, block_index, set_index) do
    with {:ok, block_index} <- Input.parse_non_negative_index(block_index),
         {:ok, set_index} <- Input.parse_non_negative_index(set_index),
         blocks <- Enum.sort_by(blocks || [], & &1.position),
         %Block{} = block <- Enum.at(blocks, block_index),
         sets <- Enum.sort_by(block.sets || [], & &1.position),
         %Set{} <- Enum.at(sets, set_index),
         true <- length(sets) > 1 do
      remaining =
        sets
        |> List.delete_at(set_index)
        |> Enum.with_index(1)
        |> Enum.map(fn {set, position} -> %{set | position: position} end)

      updated_block = %{block | sets: remaining}
      form_plan = %{state.form_plan | blocks: List.replace_at(blocks, block_index, updated_block)}

      {:ok,
       %{
         state
         | form_plan: form_plan,
           manual_edit?: true,
           derived: derived(form_plan, state.input)
       }}
    else
      false -> {:error, :last_set, state}
      nil -> {:error, :missing_item, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def delete_set(%State{} = state, _block_index, _set_index),
    do: {:error, :missing_form_plan, state}

  defp copy_block_as_new(%Block{} = block, position) do
    sets =
      block.sets
      |> Enum.sort_by(&(&1.position || 0))
      |> Enum.with_index(1)
      |> Enum.map(fn {set, set_position} ->
        %{
          set
          | id: nil,
            block_id: nil,
            position: set_position,
            inserted_at: nil,
            updated_at: nil
        }
      end)

    %{
      block
      | id: nil,
        plan_id: nil,
        position: position,
        repeat_count: 1,
        sets: sets,
        inserted_at: nil,
        updated_at: nil
    }
  end

  defp schedule_copied_block(steps, copied_block_position) when is_list(steps) and steps != [] do
    steps = Enum.sort_by(steps, &(&1.position || 0))

    steps ++
      [
        %PlanStep{
          position: length(steps) + 1,
          kind: :block_run,
          block_position: copied_block_position,
          repeat_count: 1
        }
      ]
  end

  defp schedule_copied_block(steps, _copied_block_position), do: steps

  defp solver_basic_params?(params) when is_map(params) do
    Enum.any?(
      ["target_duration_min", "burpee_count_target", "reps_per_set"],
      &Map.has_key?(params, &1)
    )
  end

  defp rename_form_plan(%WorkoutPlan{} = plan, name), do: %{plan | name: name}
  defp rename_form_plan(plan, _name), do: plan

  defp derived_or_empty(%WorkoutPlan{} = plan, input), do: derived(plan, input)
  defp derived_or_empty(_plan, _input), do: %Derived{}

  defp preserve_manual_plan?(%State{
         manual_edit?: true,
         locked_block_indexes: locked_indexes,
         form_plan: %WorkoutPlan{blocks: blocks}
       })
       when is_list(blocks) do
    MapSet.size(locked_indexes) == 0
  end

  defp preserve_manual_plan?(_state), do: false

  defp merge_manual_plan(%WorkoutPlan{} = generated_plan, %WorkoutPlan{} = manual_plan) do
    %{generated_plan | blocks: manual_plan.blocks, steps: manual_plan.steps}
  end

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

    steps = restore_locked_step_repeats(plan.steps, locked_blocks)

    %{plan | blocks: blocks, steps: steps}
  end

  defp restore_locked_blocks(plan, _locked_blocks), do: plan

  defp restore_locked_step_repeats(steps, locked_blocks) when is_list(steps) do
    repeats_by_position =
      locked_blocks
      |> Map.values()
      |> Map.new(fn block -> {block.position, block.repeat_count || 1} end)

    Enum.map(steps, fn
      %{kind: :block_run, block_position: position} = step ->
        case Map.fetch(repeats_by_position, position) do
          {:ok, repeat_count} -> %{step | repeat_count: repeat_count}
          :error -> step
        end

      step ->
        step
    end)
  end

  defp restore_locked_step_repeats(steps, _locked_blocks), do: steps

  @spec input_from_plan(WorkoutPlan.t()) :: input()
  def input_from_plan(%WorkoutPlan{} = plan) do
    Input.from_plan(plan)
  end

  defp explicit_rests_from_editor(rests) when is_list(rests) do
    Enum.map(rests, fn rest ->
      %ExplicitRest{
        target_elapsed_sec: round(rest.target_min * 60),
        duration_sec: round(rest.rest_sec),
        tolerance_sec: 60
      }
    end)
  end

  defp explicit_rests_from_editor(_rests), do: []

  defp pace_bias_override(%Input{pace_bias: :balanced}), do: nil

  defp pace_bias_override(%Input{pace_bias: :faster, burpee_type: burpee_type}) do
    PacePolicy.for(burpee_type).preferred_fast_sec_per_rep
  end

  defp pace_bias_override(%Input{pace_bias: :slower, burpee_type: burpee_type}) do
    PacePolicy.for(burpee_type).preferred_slow_sec_per_rep
  end

  defp pace_bias_override(_input), do: nil

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
