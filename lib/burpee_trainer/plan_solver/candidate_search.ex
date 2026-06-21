defmodule BurpeeTrainer.PlanSolver.CandidateSearch do
  @moduledoc """
  Bounded candidate search for fixed-pattern unbroken workouts.

  This module deliberately searches workout-shaped templates instead of exposing
  the UI to arbitrary optimizer variables. A candidate is a complete prescription
  shape: one normal recovery duration, zero to two reset recoveries, and the pace
  implied by the exact target duration.
  """

  @normal_recovery_candidates [15.0, 12.0, 10.0, 8.0]
  @reset_recovery_sec 90.0
  @pace_floor_relaxation 0.92

  @type solution :: %{
          sec_per_burpee: float,
          rest_pattern_sec: [float],
          objective: float
        }

  @spec solve_fixed_pattern([pos_integer], keyword) :: {:ok, solution} | {:error, term}
  def solve_fixed_pattern(set_pattern, opts) when is_list(set_pattern) and set_pattern != [] do
    target_sec = Keyword.fetch!(opts, :target_sec)
    pace_min = Keyword.fetch!(opts, :pace_min)
    pace_max = Keyword.fetch!(opts, :pace_max)
    explicit_rest_total = Keyword.get(opts, :explicit_rest_total, 0.0)
    min_useful_rest = Keyword.fetch!(opts, :min_useful_rest)

    total_reps = Enum.sum(set_pattern)
    gap_count = max(length(set_pattern) - 1, 0)
    pace_floor = pace_floor(pace_min)

    if gap_count == 0 do
      solve_without_recovery(total_reps, target_sec, explicit_rest_total, pace_floor, pace_max)
    else
      set_pattern
      |> candidates(target_sec, pace_floor, pace_max, explicit_rest_total, min_useful_rest)
      |> case do
        [] -> {:error, :no_human_shaped_candidate}
        candidates -> {:ok, Enum.min_by(candidates, & &1.objective)}
      end
    end
  end

  defp solve_without_recovery(total_reps, target_sec, explicit_rest_total, pace_min, pace_max) do
    pace = (target_sec - explicit_rest_total) / total_reps

    cond do
      pace < pace_min - 1.0e-6 -> {:error, :negative_rest}
      pace > pace_max + 1.0e-6 -> {:error, :pace_too_slow}
      true -> {:ok, %{sec_per_burpee: pace, rest_pattern_sec: [], objective: pace}}
    end
  end

  defp candidates(
         set_pattern,
         target_sec,
         pace_min,
         pace_max,
         explicit_rest_total,
         min_useful_rest
       ) do
    gap_count = max(length(set_pattern) - 1, 0)
    total_reps = Enum.sum(set_pattern)
    reset_indexes = reset_indexes(set_pattern, target_sec)

    for normal_recovery <- @normal_recovery_candidates,
        normal_recovery >= min_useful_rest,
        resets <- reset_subsets(reset_indexes),
        reduce: [] do
      candidates ->
        rests = rest_pattern(gap_count, normal_recovery, resets)
        rest_total = Enum.sum(rests)
        pace = (target_sec - explicit_rest_total - rest_total) / total_reps

        if feasible_pace?(pace, pace_min, pace_max) do
          [
            %{
              sec_per_burpee: pace,
              rest_pattern_sec: rests,
              objective: objective(pace, pace_min, normal_recovery, resets)
            }
            | candidates
          ]
        else
          candidates
        end
    end
  end

  defp pace_floor(pace_min) when pace_min > 5.2, do: pace_min * @pace_floor_relaxation
  defp pace_floor(pace_min), do: pace_min

  defp feasible_pace?(pace, pace_min, pace_max),
    do: pace >= pace_min - 1.0e-6 and pace <= pace_max + 1.0e-6

  defp reset_indexes(set_pattern, target_sec) do
    gap_count = max(length(set_pattern) - 1, 0)

    target_sec
    |> reset_phases()
    |> Enum.map(fn
      :mid -> max(1, round(gap_count * 0.75))
      :late -> gap_count
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reset_phases(target_sec) when target_sec >= 18 * 60, do: [:mid, :late]
  defp reset_phases(target_sec) when target_sec >= 12 * 60, do: [:mid]
  defp reset_phases(_target_sec), do: []

  defp reset_subsets([]), do: [[]]

  defp reset_subsets(indexes) do
    indexes = Enum.sort(indexes)

    [[]] ++
      for count <- 1..length(indexes),
          subset <- combinations(indexes, count),
          not adjacent?(subset) do
        subset
      end
  end

  defp combinations(_items, 0), do: [[]]
  defp combinations([], _count), do: []

  defp combinations([head | tail], count) do
    with_head = for rest <- combinations(tail, count - 1), do: [head | rest]
    without_head = combinations(tail, count)
    with_head ++ without_head
  end

  defp adjacent?(indexes) do
    indexes
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> b - a <= 1 end)
  end

  defp rest_pattern(gap_count, normal_recovery, reset_indexes) do
    reset_indexes = MapSet.new(reset_indexes)

    for gap_index <- 1..gap_count do
      if MapSet.member?(reset_indexes, gap_index), do: @reset_recovery_sec, else: normal_recovery
    end
  end

  defp objective(pace, pace_min, normal_recovery, reset_indexes) do
    pace_penalty = (pace - pace_min) * 10_000.0
    normal_penalty = abs(normal_recovery - 15.0) * 100.0
    reset_reward = length(reset_indexes) * -500.0
    pace_penalty + normal_penalty + reset_reward
  end
end
