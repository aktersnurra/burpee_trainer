defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Derives the editor/storage `%WorkoutPlan{}` projection from canonical solver execution.

  The public entrypoint is intentionally limited to canonical execution events.
  Older direct builders from set/rest patterns were removed so runtime callers
  cannot reconstruct execution from mutable plan blocks, steps, or additional
  rest JSON.
  """

  alias BurpeeTrainer.PlanSolver.{Execution, Input, Prescription, StructureSearch}
  alias BurpeeTrainer.PlanEditor.{Block, PlanStep, Set}
  alias BurpeeTrainer.Workouts.WorkoutPlan

  @spec from_execution(Input.t(), Execution.t(), Prescription.t() | float) ::
          {:ok, WorkoutPlan.t()}
  def from_execution(%Input{} = input, execution, %Prescription{} = prescription)
      when is_list(execution) do
    execution = normalize_auto_rests(input, execution)
    {blocks, steps} = blocks_and_steps_from_execution(input, execution)
    {:ok, wrap_plan(input, prescription.sec_per_rep, blocks, steps, prescription)}
  end

  def from_execution(%Input{} = input, execution, p) when is_list(execution) do
    execution = normalize_auto_rests(input, execution)
    {blocks, steps} = blocks_and_steps_from_execution(input, execution)
    {:ok, wrap_plan(input, p, blocks, steps)}
  end

  defp normalize_auto_rests(%Input{} = input, execution) do
    work_sec =
      execution
      |> Enum.reduce(0.0, fn
        %Execution.SetEvent{} = event, total -> total + event.duration_sec
        _event, total -> total
      end)

    explicit_rest_sec =
      execution
      |> Enum.reduce(0.0, fn
        %Execution.RestEvent{} = event, total ->
          if auto_rest_source?(event.source), do: total, else: total + event.rest_sec

        _event, total ->
          total
      end)

    auto_rests =
      Enum.filter(execution, fn
        %Execution.RestEvent{} = event -> auto_rest_source?(event.source)
        _event -> false
      end)

    target_auto_rest_sec = round(target_duration_sec(input) - work_sec - explicit_rest_sec)

    integer_rests =
      integer_rest_pattern_with_total(Enum.map(auto_rests, & &1.rest_sec), target_auto_rest_sec)

    {normalized, _index} =
      Enum.map_reduce(execution, 0, fn
        %Execution.RestEvent{} = event, index ->
          if auto_rest_source?(event.source) do
            {Map.put(event, :rest_sec, Enum.at(integer_rests, index, 0)), index + 1}
          else
            {event, index}
          end

        event, index ->
          {event, index}
      end)

    normalized
  end

  defp auto_rest_source?(:auto), do: true
  defp auto_rest_source?(:auto_normal), do: true
  defp auto_rest_source?({:auto_reset, _kind}), do: true
  defp auto_rest_source?(_source), do: false

  defp target_duration_sec(%Input{target_duration_sec: seconds}) when is_integer(seconds),
    do: seconds

  defp integer_rest_pattern_with_total([], _target_total), do: []

  defp integer_rest_pattern_with_total(rest_pattern, target_total) do
    floors = Enum.map(rest_pattern, &floor/1)
    remainder = max(target_total - Enum.sum(floors), 0)

    rest_pattern
    |> Enum.map(&(&1 - floor(&1)))
    |> Enum.with_index()
    |> Enum.sort_by(fn {fraction, index} -> {-fraction, index} end)
    |> Enum.take(remainder)
    |> Enum.map(fn {_fraction, index} -> index end)
    |> MapSet.new()
    |> then(fn round_up_indexes ->
      floors
      |> Enum.with_index()
      |> Enum.map(fn {rest, index} ->
        if MapSet.member?(round_up_indexes, index), do: rest + 1, else: rest
      end)
    end)
  end

  defp blocks_and_steps_from_execution(input, execution) do
    {execution_units, _pending_rest} = execution_units(execution)
    units = coalesce_pattern_units(input, execution_units)

    units
    |> Enum.chunk_by(&unit_key/1)
    |> Enum.reduce({[], [], 1}, fn group, {blocks, steps, next_block_position} ->
      case hd(group) do
        {:set, first} ->
          block = block_from_sets(next_block_position, [first], length(group))
          step = block_run_step(0, next_block_position, length(group))
          {[block | blocks], [step | steps], next_block_position + 1}

        {:set_group, first} ->
          block = block_from_sets(next_block_position, first.sets, length(group))
          step = block_run_step(0, next_block_position, length(group))
          {[block | blocks], [step | steps], next_block_position + 1}

        {:rest, rest} ->
          step = %PlanStep{position: 0, kind: :rest, rest_sec: rest.rest_sec}
          {blocks, [step | steps], next_block_position}
      end
    end)
    |> then(fn {blocks, steps, _next_block_position} ->
      blocks = Enum.reverse(blocks)

      steps =
        steps
        |> Enum.reverse()
        |> Enum.with_index(1)
        |> Enum.map(fn {step, position} -> %{step | position: position} end)

      {blocks, steps}
    end)
  end

  defp coalesce_pattern_units(%Input{pacing_style: :even, block_pattern: pattern}, units)
       when is_list(pattern) and pattern != [] do
    do_coalesce_pattern_units(units, pattern, [])
  end

  defp coalesce_pattern_units(_input, units), do: units

  defp do_coalesce_pattern_units([], _pattern, acc), do: Enum.reverse(acc)

  defp do_coalesce_pattern_units(units, pattern, acc) do
    {candidate, rest} = Enum.split(units, length(pattern))

    if pattern_match?(candidate, pattern) do
      sets = Enum.map(candidate, fn {:set, set} -> set end)
      do_coalesce_pattern_units(rest, pattern, [{:set_group, %{sets: sets}} | acc])
    else
      [unit | rest] = units
      do_coalesce_pattern_units(rest, pattern, [unit | acc])
    end
  end

  defp pattern_match?(candidate, pattern) when length(candidate) == length(pattern) do
    candidate
    |> Enum.zip(pattern)
    |> Enum.all?(fn
      {{:set, set}, reps} -> set.burpee_count == reps and set.end_of_set_rest == 0
      _ -> false
    end)
  end

  defp pattern_match?(_candidate, _pattern), do: false

  defp unit_key({:set, set}),
    do: {:set, set.burpee_count, set.sec_per_rep, set.sec_per_burpee, set.end_of_set_rest}

  defp unit_key({:set_group, group}) do
    {:set_group,
     Enum.map(
       group.sets,
       &{&1.burpee_count, &1.sec_per_rep, &1.sec_per_burpee, &1.end_of_set_rest}
     )}
  end

  defp unit_key({:rest, rest}), do: {:rest, rest.rest_sec}

  defp block_from_sets(position, sets, repeat_count) do
    sets =
      sets
      |> Enum.with_index(1)
      |> Enum.map(fn {set, set_position} ->
        %Set{
          position: set_position,
          burpee_count: set.burpee_count,
          sec_per_rep: set.sec_per_rep,
          sec_per_burpee: set.sec_per_burpee,
          end_of_set_rest: set.end_of_set_rest
        }
      end)

    %Block{position: position, repeat_count: repeat_count, sets: sets}
  end

  defp execution_units(events), do: execution_units(events, [], nil)

  defp execution_units([], units, nil), do: {Enum.reverse(units), nil}

  defp execution_units([], units, pending_set),
    do: {Enum.reverse([{:set, %{pending_set | end_of_set_rest: 0}} | units]), nil}

  defp execution_units([%Execution.SetEvent{} = set | rest], units, nil) do
    pending_set = %{
      burpee_count: set.burpee_count,
      sec_per_rep: set.sec_per_rep,
      sec_per_burpee: set.sec_per_burpee,
      end_of_set_rest: 0
    }

    execution_units(rest, units, pending_set)
  end

  defp execution_units([%Execution.SetEvent{} = set | rest], units, pending_set) do
    units = [{:set, %{pending_set | end_of_set_rest: 0}} | units]

    pending_set = %{
      burpee_count: set.burpee_count,
      sec_per_rep: set.sec_per_rep,
      sec_per_burpee: set.sec_per_burpee,
      end_of_set_rest: 0
    }

    execution_units(rest, units, pending_set)
  end

  defp execution_units([%Execution.RestEvent{} = rest_event | rest], units, nil) do
    execution_units(rest, [{:rest, rest_event} | units], nil)
  end

  defp execution_units([%Execution.RestEvent{} = rest_event | rest], units, pending_set) do
    if auto_rest_source?(rest_event.source) do
      execution_units(
        rest,
        [{:set, %{pending_set | end_of_set_rest: round(rest_event.rest_sec)}} | units],
        nil
      )
    else
      units = [{:rest, rest_event}, {:set, pending_set} | units]
      execution_units(rest, units, nil)
    end
  end

  defp wrap_plan(input, p, blocks, steps) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: duration_min(input),
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: round_pace(p),
      pacing_style: input.pacing_style,
      additional_rests: encode_explicit_rests(input.explicit_rests || []),
      fatigue_factor: 0.0,
      blocks: blocks,
      steps: steps
    }
  end

  defp wrap_plan(input, p, blocks, steps, %Prescription{} = prescription) do
    %WorkoutPlan{
      name: input.name || "Generated workout",
      burpee_type: input.burpee_type,
      target_duration_min: duration_min(input),
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: round_pace(p),
      pacing_style: input.pacing_style,
      additional_rests: encode_explicit_rests(input.explicit_rests || []),
      fatigue_factor: 0.0,
      blocks: blocks,
      steps: steps,
      plan_solver_metadata:
        prescription.metadata
        # score_key is the solver's internal scoring tuple; it has no persisted
        # reader and Ecto's :map dump cannot JSON-encode a tuple.
        |> Map.delete(:score_key)
        |> Map.merge(%{
          solver_version: 3,
          structure_key: StructureSearch.encode(prescription.blocks),
          sec_per_rep: prescription.sec_per_rep,
          target_duration_sec: prescription.target_duration_sec,
          burpee_count: prescription.burpee_count,
          blocks: Enum.map(prescription.blocks, &%{repeat: &1.repeat, motif: &1.motif})
        })
    }
  end

  defp duration_min(%Input{target_duration_sec: seconds}) when is_integer(seconds),
    do: round(seconds / 60)

  defp round_pace(value) when is_float(value), do: Float.round(value, 1)
  defp round_pace(value), do: value

  defp block_run_step(position, block_position, repeat_count) do
    %PlanStep{
      position: position,
      kind: :block_run,
      block_position: block_position,
      repeat_count: repeat_count
    }
  end

  defp encode_explicit_rests([]), do: "[]"

  defp encode_explicit_rests(rests) do
    items =
      Enum.map(rests, fn rest ->
        target_min = rest.target_elapsed_sec / 60
        "{\"rest_sec\":#{rest.duration_sec},\"target_min\":#{target_min}}"
      end)

    "[" <> Enum.join(items, ",") <> "]"
  end
end
