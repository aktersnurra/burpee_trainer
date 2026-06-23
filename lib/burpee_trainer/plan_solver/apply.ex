defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Collapses a solved pace `p` and set/rest patterns into a `%WorkoutPlan{}`.

  Additional rests are stored on the plan and rendered as timeline steps. They
  are not folded into set recovery.
  """

  alias BurpeeTrainer.PlanSolver.{Execution, Input, Prescription, StructureSearch}
  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}

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

  @spec to_workout_plan(Input.t(), float, [float], [map]) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(%Input{pacing_style: :even} = input, p, _r, reservations) do
    to_workout_plan(input, p, [input.burpee_count_target], [], reservations)
  end

  def to_workout_plan(%Input{pacing_style: :unbroken} = input, p, _r, reservations) do
    set_pattern = legacy_unbroken_set_pattern(input)
    rest_pattern = legacy_unbroken_rest_pattern(input, p, set_pattern, reservations)
    to_workout_plan(input, p, set_pattern, rest_pattern, reservations)
  end

  @spec to_workout_plan(Input.t(), float, [pos_integer], [float], [map]) :: {:ok, WorkoutPlan.t()}
  def to_workout_plan(
        %Input{pacing_style: :even} = input,
        p,
        _set_pattern,
        _rest_pattern,
        reservations
      ) do
    {:ok, wrap_plan(input, p, build_even(input, p, reservations))}
  end

  def to_workout_plan(
        %Input{pacing_style: :unbroken} = input,
        p,
        set_pattern,
        rest_pattern,
        _reservations
      ) do
    {:ok, wrap_plan(input, p, build_unbroken(p, set_pattern, rest_pattern))}
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

  defp target_duration_sec(%Input{target_duration_min: minutes}) when is_number(minutes),
    do: minutes * 60.0

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
    if auto_rest_source?(rest_event.source) do
      execution_units(rest, [{:rest, rest_event} | units], nil)
    else
      execution_units(rest, [{:rest, rest_event} | units], nil)
    end
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

  # ---------------------------------------------------------------------------
  # :even
  # ---------------------------------------------------------------------------

  defp build_even(input, p, []) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    cadence = target_sec / n
    pattern = preferred_pattern(input)
    {full_repeats, remainder_pattern} = split_pattern_for_solver(n, pattern)

    blocks = [pattern_block(1, pattern, cadence, p, full_repeats)]

    if remainder_pattern == [] do
      blocks
    else
      blocks ++ [pattern_block(2, remainder_pattern, cadence, p, 1)]
    end
  end

  defp build_even(%Input{block_pattern: pattern} = input, p, reservations)
       when is_list(pattern) and pattern != [] do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    cadence = (target_sec - reservation_total) / n
    {full_repeats, remainder_pattern} = split_pattern_for_solver(n, pattern)

    blocks = [pattern_block(1, pattern, cadence, p, full_repeats)]

    if remainder_pattern == [] do
      blocks
    else
      blocks ++ [pattern_block(2, remainder_pattern, cadence, p, 1)]
    end
  end

  defp build_even(input, p, reservations) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    cadence = (target_sec - reservation_total) / n

    sorted = Enum.sort_by(reservations, & &1.slot)
    splits = Enum.map(sorted, &{&1.slot, &1.rest_sec}) ++ [{n, 0}]

    {blocks, _} =
      Enum.reduce(splits, {[], 0}, fn {split_at, _rest_sec}, {acc, prev} ->
        reps = split_at - prev

        set = %Set{
          position: 1,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: p,
          end_of_set_rest: 0
        }

        block = %Block{position: length(acc) + 1, repeat_count: 1, sets: [set]}
        {[block | acc], split_at}
      end)

    Enum.reverse(blocks)
  end

  defp preferred_pattern(%Input{block_pattern: pattern}) when is_list(pattern) and pattern != [],
    do: pattern

  defp preferred_pattern(%Input{burpee_type: :navy_seal}), do: [5]
  defp preferred_pattern(%Input{burpee_type: :six_count}), do: [8]

  @spec split_pattern_for_solver(pos_integer(), [pos_integer()]) ::
          {non_neg_integer(), [pos_integer()]}
  def split_pattern_for_solver(total_reps, pattern) do
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

  defp pattern_block(position, pattern, cadence, p, repeat_count) do
    sets =
      pattern
      |> Enum.with_index(1)
      |> Enum.map(fn {reps, set_position} ->
        %Set{
          position: set_position,
          burpee_count: reps,
          sec_per_rep: cadence,
          sec_per_burpee: p,
          end_of_set_rest: 0
        }
      end)

    %Block{position: position, repeat_count: repeat_count, sets: sets}
  end

  # ---------------------------------------------------------------------------
  # :unbroken
  # ---------------------------------------------------------------------------

  defp build_unbroken(p, set_pattern, rest_pattern) do
    integer_rest_pattern = integer_rest_pattern(rest_pattern)

    set_pattern
    |> Enum.with_index()
    |> Enum.map(fn {reps, index} ->
      rest_after_set = Enum.at(integer_rest_pattern, index, 0)
      %{reps: reps, rest_after_set: rest_after_set}
    end)
    |> Enum.chunk_by(&{&1.reps, &1.rest_after_set})
    |> Enum.with_index(1)
    |> Enum.map(fn {group, position} ->
      first = hd(group)

      %Block{
        position: position,
        repeat_count: length(group),
        sets: [
          %Set{
            position: 1,
            burpee_count: first.reps,
            sec_per_rep: p,
            sec_per_burpee: p,
            end_of_set_rest: first.rest_after_set
          }
        ]
      }
    end)
  end

  defp integer_rest_pattern(rest_pattern) do
    target_total = rest_pattern |> Enum.sum() |> round()

    floors = Enum.map(rest_pattern, &floor/1)
    remainder = target_total - Enum.sum(floors)

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

  defp legacy_unbroken_rest_pattern(input, p, set_pattern, reservations) do
    target_sec = input.target_duration_min * 60.0
    work_sec = input.burpee_count_target * p
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    gap_count = max(length(set_pattern) - 1, 0)

    if gap_count > 0 do
      rest_per_gap = max((target_sec - work_sec - reservation_total) / gap_count, 0.0)
      List.duplicate(rest_per_gap, gap_count)
    else
      []
    end
  end

  defp legacy_unbroken_set_pattern(input) do
    set_size = min(input.reps_per_set || 1, input.burpee_count_target)
    full_sets = div(input.burpee_count_target, set_size)
    remainder = rem(input.burpee_count_target, set_size)
    base = List.duplicate(set_size, full_sets)

    if remainder > 0, do: base ++ [remainder], else: base
  end

  # ---------------------------------------------------------------------------
  # Plan wrapper
  # ---------------------------------------------------------------------------

  defp wrap_plan(input, p, blocks) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: input.target_duration_min,
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: round_pace(p),
      pacing_style: input.pacing_style,
      additional_rests: encode_rests(input.additional_rests || []),
      fatigue_factor: 0.0,
      blocks: blocks,
      steps: build_steps(input, blocks)
    }
  end

  defp wrap_plan(input, p, blocks, steps) do
    %WorkoutPlan{
      name: input.name,
      burpee_type: input.burpee_type,
      target_duration_min: duration_min(input),
      burpee_count_target: input.burpee_count_target,
      sec_per_burpee: round_pace(p),
      pacing_style: input.pacing_style,
      additional_rests: encode_rests(input.additional_rests || []),
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
      additional_rests: encode_rests(input.additional_rests || []),
      fatigue_factor: 0.0,
      blocks: blocks,
      steps: steps,
      plan_solver_metadata:
        Map.merge(prescription.metadata, %{
          solver_version: 3,
          structure_key: StructureSearch.encode(prescription.blocks),
          sec_per_rep: prescription.sec_per_rep,
          target_duration_sec: prescription.target_duration_sec,
          burpee_count: prescription.burpee_count,
          blocks: Enum.map(prescription.blocks, &%{repeat: &1.repeat, motif: &1.motif})
        })
    }
  end

  defp duration_min(%Input{target_duration_min: minutes}) when is_integer(minutes), do: minutes

  defp duration_min(%Input{target_duration_sec: seconds}) when is_integer(seconds),
    do: round(seconds / 60)

  defp duration_min(%Input{target_duration_min: minutes}) when is_number(minutes),
    do: round(minutes)

  defp build_steps(%Input{pacing_style: :unbroken, additional_rests: []}, blocks) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn block -> block_run_step(0, block.position, block.repeat_count || 1) end)
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp build_steps(%Input{pacing_style: :unbroken} = input, blocks) do
    units = unbroken_run_units(blocks)

    {steps, remaining_units, _elapsed} =
      input.additional_rests
      |> Enum.sort_by(& &1.target_min)
      |> Enum.reduce({[], units, 0.0}, fn rest, {steps, remaining_units, elapsed} ->
        target_delta = rest.target_min * 60.0 - elapsed
        {before_rest, after_rest} = split_units_near_target(remaining_units, target_delta)
        rest_step = %PlanStep{position: 0, kind: :rest, rest_sec: rest.rest_sec}
        elapsed = elapsed + units_duration(before_rest) + rest.rest_sec
        {steps ++ block_run_steps_for_units(before_rest) ++ [rest_step], after_rest, elapsed}
      end)

    (steps ++ block_run_steps_for_units(remaining_units))
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp build_steps(%Input{block_pattern: pattern, additional_rests: rests} = input, [
         block | _blocks
       ])
       when is_list(pattern) and pattern != [] and is_list(rests) and rests != [] do
    {full_repeats, remainder_pattern} =
      split_pattern_for_solver(input.burpee_count_target, pattern)

    block_sec = block_duration(block)

    {steps, remaining_repeats, _elapsed} =
      rests
      |> Enum.sort_by(& &1.target_min)
      |> Enum.reduce({[], full_repeats, 0.0}, fn rest, {steps, remaining_repeats, elapsed} ->
        repeats_before =
          rest.target_min
          |> Kernel.*(60.0)
          |> Kernel.-(elapsed)
          |> Kernel./(block_sec)
          |> round()
          |> max(0)
          |> min(remaining_repeats)

        steps =
          if repeats_before > 0 do
            steps ++ [block_run_step(0, block.position, repeats_before)]
          else
            steps
          end

        rest_step = %PlanStep{position: 0, kind: :rest, rest_sec: rest.rest_sec}
        remaining_repeats = remaining_repeats - repeats_before
        elapsed = elapsed + repeats_before * block_sec + rest.rest_sec
        {steps ++ [rest_step], remaining_repeats, elapsed}
      end)

    steps =
      if remaining_repeats > 0 do
        steps ++ [block_run_step(0, block.position, remaining_repeats)]
      else
        steps
      end

    steps =
      if remainder_pattern == [] do
        steps
      else
        steps ++ [block_run_step(0, 2, 1)]
      end

    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp build_steps(%Input{pacing_style: :even, additional_rests: []} = input, _blocks) do
    pattern = preferred_pattern(input)

    {full_repeats, remainder_pattern} =
      split_pattern_for_solver(input.burpee_count_target, pattern)

    steps =
      if full_repeats > 0 do
        [block_run_step(1, 1, full_repeats)]
      else
        []
      end

    steps =
      if remainder_pattern == [] do
        steps
      else
        steps ++ [block_run_step(length(steps) + 1, 2, 1)]
      end

    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp build_steps(%Input{pacing_style: :even, additional_rests: rests}, blocks)
       when is_list(rests) and rests != [] do
    sorted_blocks = Enum.sort_by(blocks, & &1.position)
    sorted_rests = Enum.sort_by(rests, & &1.target_min)

    sorted_blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, index} ->
      block_step = block_run_step(0, block.position, block.repeat_count || 1)

      case Enum.at(sorted_rests, index) do
        %{rest_sec: rest_sec} ->
          [block_step, %PlanStep{position: 0, kind: :rest, rest_sec: rest_sec}]

        nil ->
          [block_step]
      end
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {step, position} -> %{step | position: position} end)
  end

  defp build_steps(_input, blocks) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.with_index(1)
    |> Enum.map(fn {block, position} ->
      block_run_step(position, block.position, block.repeat_count || 1)
    end)
  end

  defp unbroken_run_units(blocks) do
    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.flat_map(fn block ->
      repeat_count = block.repeat_count || 1
      duration = block_duration(block)

      for _ <- 1..repeat_count do
        %{block_position: block.position, duration_sec: duration}
      end
    end)
  end

  defp split_units_near_target(units, target_sec) do
    {_elapsed, best_index, _best_delta} =
      units
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, 0, abs(target_sec)}, fn {unit, index},
                                                   {elapsed, best_index, best_delta} ->
        elapsed = elapsed + unit.duration_sec
        delta = abs(elapsed - target_sec)

        if delta < best_delta do
          {elapsed, index, delta}
        else
          {elapsed, best_index, best_delta}
        end
      end)

    Enum.split(units, best_index)
  end

  defp block_run_steps_for_units(units) do
    units
    |> Enum.chunk_by(& &1.block_position)
    |> Enum.map(fn group ->
      block_run_step(0, hd(group).block_position, length(group))
    end)
  end

  defp units_duration(units) do
    Enum.reduce(units, 0.0, fn unit, total -> total + unit.duration_sec end)
  end

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

  defp block_duration(%Block{} = block) do
    block.sets
    |> Enum.reduce(0.0, fn set, total ->
      total + (set.burpee_count || 0) * (set.sec_per_rep || 0.0) + (set.end_of_set_rest || 0)
    end)
  end

  defp encode_rests([]), do: "[]"

  defp encode_rests(rests) do
    items =
      Enum.map(rests, fn %{rest_sec: r, target_min: t} ->
        "{\"rest_sec\":#{r},\"target_min\":#{t}}"
      end)

    "[" <> Enum.join(items, ",") <> "]"
  end
end
