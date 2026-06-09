defmodule BurpeeTrainer.PlanSolver.Apply do
  @moduledoc """
  Collapses a solved pace `p` and set/rest patterns into a `%WorkoutPlan{}`.

  Additional rests are stored on the plan and rendered as timeline steps. They
  are not folded into set recovery.
  """

  alias BurpeeTrainer.PlanSolver.Input
  alias BurpeeTrainer.Workouts.{Block, PlanStep, Set, WorkoutPlan}

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

  # ---------------------------------------------------------------------------
  # :even
  # ---------------------------------------------------------------------------

  defp build_even(input, p, []) do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    cadence = target_sec / n
    pattern = preferred_pattern(input)
    {_full_repeats, remainder_pattern} = split_pattern_for_solver(n, pattern)

    blocks = [pattern_block(1, pattern, cadence, p)]

    if remainder_pattern == [] do
      blocks
    else
      blocks ++ [pattern_block(2, remainder_pattern, cadence, p)]
    end
  end

  defp build_even(%Input{block_pattern: pattern} = input, p, reservations)
       when is_list(pattern) and pattern != [] do
    target_sec = input.target_duration_min * 60.0
    n = input.burpee_count_target
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    cadence = (target_sec - reservation_total) / n
    {_full_repeats, remainder_pattern} = split_pattern_for_solver(n, pattern)

    blocks = [pattern_block(1, pattern, cadence, p)]

    if remainder_pattern == [] do
      blocks
    else
      blocks ++ [pattern_block(2, remainder_pattern, cadence, p)]
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

  @spec split_pattern_for_solver(pos_integer(), [pos_integer()]) :: {non_neg_integer(), [pos_integer()]}
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

  defp pattern_block(position, pattern, cadence, p) do
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

    %Block{position: position, repeat_count: 1, sets: sets}
  end

  # ---------------------------------------------------------------------------
  # :unbroken
  # ---------------------------------------------------------------------------

  defp build_unbroken(p, set_pattern, rest_pattern) do
    p = round_pace(p)
    grouped = Enum.chunk_by(set_pattern, & &1)

    last_position = length(grouped)

    grouped
    |> Enum.with_index(1)
    |> Enum.map(fn {group, position} ->
      reps = hd(group)
      base_rest = if last_position > 1 and position == last_position, do: 0, else: Enum.at(rest_pattern, 0, 0)

      %Block{
        position: position,
        repeat_count: length(group),
        sets: [
          %Set{
            position: 1,
            burpee_count: reps,
            sec_per_rep: p,
            sec_per_burpee: p,
            end_of_set_rest: round(base_rest)
          }
        ]
      }
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
    {full_repeats, remainder_pattern} = split_pattern_for_solver(input.burpee_count_target, pattern)
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
    {full_repeats, remainder_pattern} = split_pattern_for_solver(input.burpee_count_target, pattern)

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
      |> Enum.reduce({0.0, 0, abs(target_sec)}, fn {unit, index}, {elapsed, best_index, best_delta} ->
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
