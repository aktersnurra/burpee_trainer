defmodule BurpeeTrainer.PlanSolver do
  @moduledoc """
  Public entry point for session plan generation.

  Given a `%PlanSolver.Input{}` (burpee count, type, duration, pacing style,
  user level), generates a human-shaped session plan via deterministic
  candidate scoring and returns a `%PlanSolver.Solution{}` wrapping the
  `%WorkoutPlan{}`.

  `sec_per_burpee` is solver-chosen from `BurpeeTrainer.PaceModel` unless
  `sec_per_burpee_override` pins it exactly.
  """

  alias BurpeeTrainer.{Levels, PaceModel}
  alias BurpeeTrainer.PlanSolver.{Apply, Input, Solution}

  @default_reps_per_set %{six_count: 10, navy_seal: 5}
  @human_set_sizes [15, 12, 10, 9, 8, 6, 5, 4]
  @normal_work_interval_sec 60.0
  @min_useful_recovery_sec 8.0

  @doc "Type- and level-derived fastest recommended pace (sec/rep)."
  @spec sustainable_ceiling(atom, atom) :: float
  def sustainable_ceiling(burpee_type, level),
    do: PaceModel.fastest_recommended_sec_per_rep(burpee_type, level)

  @doc "Default reps-per-set for a given burpee type."
  @spec default_reps_per_set(atom) :: pos_integer
  def default_reps_per_set(type), do: Map.get(@default_reps_per_set, type, 10)

  @doc "Effective lower bound for pace. Override takes precedence."
  @spec effective_ceiling(Input.t()) :: float
  def effective_ceiling(%Input{sec_per_burpee_override: override}) when is_float(override),
    do: override

  def effective_ceiling(%Input{} = input) do
    user_ceiling = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, input.level)
    workout_level = Levels.level_for_count(input.burpee_type, input.burpee_count_target)
    workout_ceiling = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, workout_level)
    min(user_ceiling, workout_ceiling)
  end

  @doc "Generate a `%Solution{}` from a `%PlanSolver.Input{}`."
  @spec solve(Input.t()) :: {:ok, Solution.t()} | {:error, [String.t()]}
  def solve(%Input{} = input) do
    with {:ok, reps_per_set} <- resolve_reps_per_set(input),
         :ok <- validate_block_pattern(input.block_pattern),
         :ok <- preflight_check(input),
         prepared_input = apply_resolved_reps_per_set(input, reps_per_set),
         {:ok, candidate} <- solve_candidate(prepared_input, reps_per_set),
         {:ok, plan} <-
           Apply.to_workout_plan(
             %{prepared_input | block_pattern: candidate.block_pattern},
             candidate.sec_per_burpee,
             candidate.set_pattern,
             candidate.rest_pattern_sec,
             candidate.reservations
           ) do
      {:ok,
       build_solution(plan, %{prepared_input | block_pattern: candidate.block_pattern}, candidate)}
    end
  end

  defp validate_block_pattern(nil), do: :ok

  defp validate_block_pattern(pattern)
       when is_list(pattern) and pattern != [] and length(pattern) <= 12 do
    if Enum.all?(pattern, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, ["block pattern must contain positive rep counts"]}
    end
  end

  defp validate_block_pattern(_pattern),
    do: {:error, ["block pattern must contain 1 to 12 positive rep counts"]}

  defp resolve_reps_per_set(%Input{pacing_style: :even}), do: {:ok, nil}

  defp resolve_reps_per_set(%Input{pacing_style: :unbroken} = input) do
    rps = input.reps_per_set || default_reps_per_set(input.burpee_type)

    if is_integer(rps) and rps > 0,
      do: {:ok, rps},
      else: {:error, ["reps_per_set must be a positive integer"]}
  end

  defp preflight_check(%Input{} = input) do
    ceiling = effective_ceiling(input)
    min_work = input.burpee_count_target * ceiling
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(input.additional_rests || [], 0.0, &(&1.rest_sec + &2))

    cond do
      min_work > target_sec ->
        {:error,
         [
           "#{input.burpee_count_target} reps at #{Float.round(ceiling, 1)}s/rep needs " <>
             "at least #{format_duration(min_work)} of work, but the target is #{format_duration(target_sec)}."
         ]}

      min_work + add_rest > target_sec ->
        {:error,
         [
           "Work needs #{format_duration(min_work)} and additional rests add #{format_duration(add_rest)}, " <>
             "which does not fit in #{format_duration(target_sec)}."
         ]}

      true ->
        :ok
    end
  end

  defp apply_resolved_reps_per_set(%Input{pacing_style: :unbroken} = input, reps_per_set),
    do: %{input | reps_per_set: reps_per_set}

  defp apply_resolved_reps_per_set(%Input{} = input, _reps_per_set), do: input

  defp solve_candidate(%Input{pacing_style: :even} = input, _reps_per_set) do
    p = pace(input)
    pattern = default_even_pattern(input)
    prepared_input = %{input | block_pattern: pattern}

    case place_additional_rests(prepared_input, p, nil) do
      {:ok, reservations} ->
        set_pattern = expand_pattern(input.burpee_count_target, pattern)
        rest_pattern = List.duplicate(0.0, max(length(set_pattern) - 1, 0))

        {:ok,
         candidate(prepared_input,
           sec_per_burpee: p,
           set_pattern: set_pattern,
           rest_pattern_sec: rest_pattern,
           reservations: reservations,
           candidate_count: 1,
           score: score_smart_candidate(input, p, set_pattern, rest_pattern),
           set_pattern_strategy:
             if(input.block_pattern, do: :preferred_pattern, else: :smart_even)
         )}

      {:error, :invalid_rest_boundary} ->
        {:error, [infeasibility_message(input)]}
    end
  end

  defp solve_candidate(%Input{pacing_style: :unbroken} = input, reps_per_set) do
    p = pace(input)

    candidates =
      input.burpee_count_target
      |> set_pattern_candidates(input.burpee_type, reps_per_set)
      |> Enum.flat_map(fn set_pattern ->
        with {:ok, reservations} <- place_additional_rests(input, p, set_pattern),
             {:ok, rest_pattern} <- derive_rest_pattern(input, p, set_pattern, reservations) do
          [
            candidate(input,
              sec_per_burpee: p,
              set_pattern: set_pattern,
              rest_pattern_sec: rest_pattern,
              reservations: reservations,
              candidate_count: 0,
              score: score_set_pattern(set_pattern, reps_per_set),
              set_pattern_strategy: :human_shaped
            )
          ]
        else
          _ -> []
        end
      end)

    case candidates do
      [] ->
        {:error, [infeasibility_message(input)]}

      candidates ->
        winner = Enum.min_by(candidates, & &1.score)
        {:ok, %{winner | candidate_count: length(candidates)}}
    end
  end

  defp pace(%Input{sec_per_burpee_override: override}) when is_float(override), do: override
  defp pace(%Input{} = input), do: effective_ceiling(input)

  defp candidate(input, opts) do
    p = Keyword.fetch!(opts, :sec_per_burpee)
    set_pattern = Keyword.fetch!(opts, :set_pattern)
    rest_pattern = Keyword.fetch!(opts, :rest_pattern_sec)
    reservations = Keyword.fetch!(opts, :reservations)
    target_sec = input.target_duration_min * 60.0
    add_rest = Enum.reduce(reservations, 0.0, &(&1.rest_sec + &2))

    %{
      sec_per_burpee: p,
      set_pattern: set_pattern,
      rest_pattern_sec: rest_pattern,
      reservations: reservations,
      duration_sec: Enum.sum(set_pattern) * p + Enum.sum(rest_pattern) + add_rest,
      rest_sec: average_rest(rest_pattern),
      target_sec: target_sec,
      candidate_count: Keyword.fetch!(opts, :candidate_count),
      score: Keyword.fetch!(opts, :score),
      set_pattern_strategy: Keyword.fetch!(opts, :set_pattern_strategy),
      block_pattern: input.block_pattern
    }
  end

  defp set_pattern_candidates(total_reps, burpee_type, reps_per_set) do
    preferred = preferred_set_sizes(burpee_type, reps_per_set)

    preferred
    |> Enum.flat_map(&set_pattern_for(total_reps, &1))
    |> Enum.uniq()
    |> Enum.filter(&(Enum.sum(&1) == total_reps))
  end

  defp preferred_set_sizes(:navy_seal, reps_per_set),
    do: [reps_per_set, 6, 5, 4] |> Enum.uniq() |> Enum.filter(&(&1 > 0))

  defp preferred_set_sizes(_type, reps_per_set),
    do: [reps_per_set | @human_set_sizes] |> Enum.uniq() |> Enum.filter(&(&1 > 0))

  defp smart_set_sizes(:navy_seal), do: [5, 4, 6, 3]
  defp smart_set_sizes(:six_count), do: [8, 10, 12, 6, 15, 5, 4]

  defp default_even_pattern(%Input{block_pattern: pattern})
       when is_list(pattern) and pattern != [],
       do: pattern

  defp default_even_pattern(%Input{} = input) do
    p = pace(input)

    input.burpee_type
    |> smart_set_sizes()
    |> Enum.min_by(fn reps -> abs(reps * p - @normal_work_interval_sec) end)
    |> then(&[&1])
  end

  defp expand_pattern(total_reps, pattern) do
    {full_repeats, remainder_pattern} = Apply.split_pattern_for_solver(total_reps, pattern)

    pattern
    |> List.duplicate(full_repeats)
    |> List.flatten()
    |> Kernel.++(remainder_pattern)
  end

  defp score_smart_candidate(_input, p, set_pattern, rest_pattern) do
    work_penalty =
      set_pattern
      |> Enum.map(fn reps -> abs(reps * p - @normal_work_interval_sec) / 60.0 end)
      |> Enum.sum()

    recovery_penalty =
      rest_pattern
      |> Enum.map(fn rest ->
        if rest > 0 and rest < @min_useful_recovery_sec, do: 10.0, else: 0.0
      end)
      |> Enum.sum()

    work_penalty + recovery_penalty + length(set_pattern) * 0.01
  end

  defp set_pattern_for(total_reps, size) when total_reps <= size, do: [[total_reps]]

  defp set_pattern_for(total_reps, size) do
    full_count = div(total_reps, size)
    remainder = rem(total_reps, size)
    base = List.duplicate(size, full_count)

    cond do
      remainder == 0 ->
        [base]

      remainder in @human_set_sizes ->
        [base ++ [remainder]]

      full_count > 0 and (size - 1) in @human_set_sizes and (remainder + 1) in @human_set_sizes ->
        [List.duplicate(size, full_count - 1) ++ [size - 1, remainder + 1]]

      true ->
        []
    end
  end

  defp derive_rest_pattern(input, p, set_pattern, reservations) do
    reservation_total = Enum.reduce(reservations, 0.0, fn r, acc -> acc + r.rest_sec end)
    work_sec = Enum.sum(set_pattern) * p
    target_sec = input.target_duration_min * 60.0
    gap_count = max(length(set_pattern) - 1, 0)
    rest_budget = target_sec - work_sec - reservation_total

    cond do
      rest_budget < -1.0e-6 ->
        {:error, :negative_rest}

      gap_count == 0 ->
        {:ok, []}

      true ->
        rest_per_gap = rest_budget / gap_count

        if input.pacing_style == :unbroken and gap_count > 0 and
             rest_per_gap < @min_useful_recovery_sec do
          {:error, :insufficient_recovery}
        else
          {:ok, List.duplicate(rest_per_gap, gap_count)}
        end
    end
  end

  defp score_set_pattern(set_pattern, reps_per_set) do
    size_penalty =
      set_pattern
      |> Enum.map(fn reps ->
        cond do
          reps == reps_per_set -> 0
          reps in @human_set_sizes -> 1
          true -> 10
        end
      end)
      |> Enum.sum()

    variance_penalty = Enum.max(set_pattern) - Enum.min(set_pattern)
    length(set_pattern) * 0.01 + size_penalty + variance_penalty * 0.1
  end

  defp place_additional_rests(%Input{additional_rests: []}, _p, _set_pattern), do: {:ok, []}

  defp place_additional_rests(%Input{pacing_style: :even} = input, _p, _set_pattern) do
    target_sec = input.target_duration_min * 60.0

    reservation_total =
      Enum.reduce(input.additional_rests || [], 0.0, fn rest, acc -> acc + rest.rest_sec end)

    cadence = (target_sec - reservation_total) / input.burpee_count_target
    block_total = even_rest_block_total(input)

    reservations =
      input.additional_rests
      |> Enum.sort_by(& &1.target_min)
      |> Enum.map(fn rest ->
        target_sec = rest.target_min * 60.0
        slot = round(target_sec / cadence / block_total) * block_total
        boundary_sec = slot * cadence

        if slot > 0 and slot < input.burpee_count_target and abs(boundary_sec - target_sec) <= 30 do
          {:ok, %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}}
        else
          :error
        end
      end)

    if Enum.any?(reservations, &(&1 == :error)) do
      {:error, :invalid_rest_boundary}
    else
      {:ok, Enum.map(reservations, fn {:ok, reservation} -> reservation end)}
    end
  end

  defp place_additional_rests(%Input{pacing_style: :unbroken} = input, p, set_pattern) do
    with {:ok, rest_pattern} <- derive_rest_pattern(input, p, set_pattern, []) do
      boundaries = set_boundaries(set_pattern, p, rest_pattern)

      reservations =
        input.additional_rests
        |> Enum.sort_by(& &1.target_min)
        |> Enum.map(fn rest ->
          target_sec = rest.target_min * 60.0

          {slot, boundary_sec} =
            Enum.min_by(boundaries, fn {_slot, sec} -> abs(sec - target_sec) end)

          if slot < input.burpee_count_target and abs(boundary_sec - target_sec) <= 30 do
            {:ok, %{slot: slot, rest_sec: rest.rest_sec, target_min: rest.target_min}}
          else
            :error
          end
        end)

      if Enum.any?(reservations, &(&1 == :error)) do
        {:error, :invalid_rest_boundary}
      else
        {:ok, Enum.map(reservations, fn {:ok, reservation} -> reservation end)}
      end
    end
  end

  defp even_rest_block_total(%Input{block_pattern: pattern})
       when is_list(pattern) and pattern != [],
       do: Enum.sum(pattern)

  defp even_rest_block_total(_input), do: 1

  defp set_boundaries(set_pattern, p, rest_pattern) do
    set_pattern
    |> Enum.drop(-1)
    |> Enum.with_index(1)
    |> Enum.map(fn {_reps, index} ->
      reps_done = set_pattern |> Enum.take(index) |> Enum.sum()
      rest_done = rest_pattern |> Enum.take(index - 1) |> Enum.sum()
      {reps_done, reps_done * p + rest_done}
    end)
  end

  defp infeasibility_message(%Input{additional_rests: [_ | _] = rests}) do
    %{target_min: t} = Enum.max_by(rests, & &1.target_min)
    "Rest at minute #{t} does not land close enough to a set boundary."
  end

  defp infeasibility_message(%Input{} = input) do
    target_sec = input.target_duration_min * 60.0
    required_pace = target_sec / input.burpee_count_target
    fastest = PaceModel.fastest_recommended_sec_per_rep(input.burpee_type, input.level)

    "#{input.burpee_count_target} reps in #{format_duration(target_sec)} requires " <>
      "about #{Float.round(required_pace, 1)}s/rep before useful recovery. " <>
      "Your level target is #{Float.round(fastest, 1)}s/rep or slower. " <>
      "Try lowering reps, increasing duration, using larger sets, or removing extra rests."
  end

  defp format_duration(seconds) do
    seconds = round(seconds)
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)

    cond do
      minutes > 0 and remainder > 0 -> "#{minutes}m #{remainder}s"
      minutes > 0 -> "#{minutes}m"
      true -> "#{remainder}s"
    end
  end

  defp build_solution(plan, %Input{} = input, candidate) do
    {_fastest, slowest} = PaceModel.pace_range_sec_per_rep(input.burpee_type, input.level)
    effective_fastest = effective_ceiling(input)

    %Solution{
      sec_per_burpee: candidate.sec_per_burpee,
      set_size: Enum.max(candidate.set_pattern),
      set_count: length(candidate.set_pattern),
      rest_sec: candidate.rest_sec,
      duration_sec: input.target_duration_min * 60.0,
      set_pattern: candidate.set_pattern,
      rest_pattern_sec: candidate.rest_pattern_sec,
      burpee_count: Enum.sum(candidate.set_pattern),
      pacing_style: input.pacing_style,
      burpee_type: input.burpee_type,
      metadata: %{
        solver_version: "deterministic-v2",
        set_pattern_strategy: candidate.set_pattern_strategy,
        candidate_count: candidate.candidate_count,
        score: candidate.score,
        pace_fastest_sec_per_rep: effective_fastest,
        pace_slowest_sec_per_rep: slowest,
        pace_override?: is_float(input.sec_per_burpee_override),
        recovery_mode: :auto,
        recommendation: recommendation_text(input, candidate),
        work_interval_sec: average_work_interval(candidate.set_pattern, candidate.sec_per_burpee),
        recovery_sec: candidate.rest_sec,
        rest_suggestions: rest_suggestions(input, candidate)
      },
      plan: plan
    }
  end

  defp recommendation_text(%Input{pacing_style: :unbroken}, candidate) do
    {reps, count} =
      candidate.set_pattern
      |> Enum.frequencies()
      |> Enum.max_by(fn {_reps, count} -> count end)

    "#{count} × #{reps} reps with auto recovery"
  end

  defp recommendation_text(%Input{pacing_style: :even}, candidate) do
    {reps, count} =
      candidate.set_pattern
      |> Enum.frequencies()
      |> Enum.max_by(fn {_reps, count} -> count end)

    "#{count} × #{reps} reps at even cadence"
  end

  defp average_work_interval([], _p), do: 0.0

  defp average_work_interval(set_pattern, p) do
    set_pattern
    |> Enum.map(&(&1 * p))
    |> Enum.sum()
    |> Kernel./(length(set_pattern))
  end

  defp rest_suggestions(%Input{additional_rests: [_ | _]}, _candidate), do: []

  defp rest_suggestions(%Input{target_duration_min: duration}, _candidate) when duration < 15,
    do: []

  defp rest_suggestions(%Input{} = input, candidate) do
    target_min = midpoint_rest_minute(input.target_duration_min)
    rest_sec = 30
    gap_count = max(length(candidate.set_pattern) - 1, 0)

    if gap_count > 0 do
      adjusted_recovery =
        (candidate.target_sec -
           Enum.sum(candidate.set_pattern) * candidate.sec_per_burpee - rest_sec) / gap_count

      if adjusted_recovery >= @min_useful_recovery_sec do
        [
          %{
            target_min: target_min,
            rest_sec: rest_sec,
            effect: "set recovery becomes about #{round(adjusted_recovery)}s"
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  defp midpoint_rest_minute(duration_min) do
    duration_min
    |> Kernel.*(0.6)
    |> round()
    |> max(10)
    |> min(16)
  end

  defp average_rest([]), do: 0.0
  defp average_rest(rest_pattern), do: Enum.sum(rest_pattern) / length(rest_pattern)
end
