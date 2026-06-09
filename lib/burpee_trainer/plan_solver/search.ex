defmodule BurpeeTrainer.PlanSolver.Search do
  @moduledoc """
  MILP-backed exact prescription search.

  This module precomputes linear set/rest/pace options, then asks HiGHS to select
  the lowest-cost option that satisfies hard workout constraints.
  """

  alias BurpeeTrainer.PlanSolver.Milp

  @human_set_sizes %{six_count: [8, 10, 12, 6, 15, 5, 4], navy_seal: [5, 4, 6, 3]}
  @remainder_set_sizes [15, 12, 10, 9, 8, 6, 5, 4]
  @min_recovery_sec 8

  @type candidate :: %{
          sec_per_burpee: float(),
          set_pattern: [pos_integer()],
          rest_pattern_sec: [float()],
          duration_sec: float(),
          score: float(),
          recommendation: String.t(),
          set_pattern_strategy: atom()
        }

  @spec solve(map()) :: {:ok, candidate()} | {:error, [String.t()]}
  def solve(%{} = input) do
    target_reps = Map.fetch!(input, :target_reps)
    target_sec = Map.fetch!(input, :target_sec) * 1.0
    min_sec_per_rep = Map.fetch!(input, :min_sec_per_rep) * 1.0
    max_sec_per_rep = Map.get(input, :max_sec_per_rep, :infinity)
    burpee_type = Map.fetch!(input, :burpee_type)
    preferred = Map.get(input, :preferred_reps_per_set)

    candidates =
      burpee_type
      |> set_sizes(preferred)
      |> Enum.flat_map(fn set_size ->
        target_reps
        |> set_pattern_for(set_size, preferred)
        |> Enum.flat_map(fn set_pattern ->
          set_pattern_candidate(
            target_sec,
            min_sec_per_rep,
            max_sec_per_rep,
            set_pattern,
            set_size,
            preferred
          )
        end)
      end)

    case candidates do
      [] ->
        {:error, [infeasible_message(target_reps, target_sec, min_sec_per_rep)]}

      [_ | _] ->
        candidates
        |> Enum.with_index()
        |> Enum.map(fn {candidate, index} ->
          candidate
          |> Map.put(:id, index)
          |> Map.put(:cost, candidate.score)
          |> Map.put(:reps, Enum.sum(candidate.set_pattern))
          |> Map.put(:duration_ds, round(candidate.duration_sec * 10))
        end)
        |> Milp.select_option(
          target_reps: target_reps,
          target_duration_ds: round(target_sec * 10)
        )
        |> case do
          {:ok, selected} ->
            {:ok, Map.drop(selected, [:id, :cost, :reps, :duration_ds])}

          {:error, _reason} ->
            {:error, [infeasible_message(target_reps, target_sec, min_sec_per_rep)]}
        end
    end
  end

  defp set_sizes(type, preferred) do
    base = Map.fetch!(@human_set_sizes, type)

    if is_integer(preferred) and preferred > 0 do
      [preferred]
    else
      base
    end
    |> Enum.uniq()
  end

  defp set_pattern_for(total_reps, size, _preferred) when total_reps <= size, do: [[total_reps]]

  defp set_pattern_for(total_reps, size, preferred) do
    full_count = div(total_reps, size)
    remainder = rem(total_reps, size)
    base = List.duplicate(size, full_count)

    cond do
      remainder == 0 ->
        [base]

      fixed_set_size?(size, preferred) and remainder > 0 ->
        [base ++ [remainder]]

      remainder in @remainder_set_sizes ->
        [base ++ [remainder]]

      full_count > 0 and (size - 1) in @remainder_set_sizes and
          (remainder + 1) in @remainder_set_sizes ->
        [List.duplicate(size, full_count - 1) ++ [size - 1, remainder + 1]]

      true ->
        []
    end
  end

  defp fixed_set_size?(size, preferred), do: is_integer(preferred) and preferred == size

  defp set_pattern_candidate(
         target_sec,
         min_sec_per_rep,
         max_sec_per_rep,
         set_pattern,
         set_size,
         preferred_size
       ) do
    target_reps = Enum.sum(set_pattern)
    gap_count = max(length(set_pattern) - 1, 0)

    cond do
      target_reps * min_sec_per_rep > target_sec ->
        []

      gap_count == 0 ->
        [
          %{
            sec_per_burpee: target_sec / target_reps,
            set_pattern: [target_reps],
            rest_pattern_sec: [],
            duration_sec: target_sec,
            score: 1000.0,
            recommendation: "1 × #{target_reps} reps",
            set_pattern_strategy: :exact_search
          }
        ]

      true ->
        min_recovery = min_recovery_sec(set_size, preferred_size)

        min_recovery..max_recovery_sec(
          target_sec,
          target_reps,
          min_sec_per_rep,
          gap_count,
          min_recovery
        )
        |> Enum.flat_map(fn rest ->
          sec_per_burpee = (target_sec - gap_count * rest) / target_reps

          if sec_per_burpee >= min_sec_per_rep and
               within_max_pace?(sec_per_burpee, max_sec_per_rep) do
            {reps, count} = primary_set(set_pattern)

            [
              %{
                sec_per_burpee: sec_per_burpee,
                set_pattern: set_pattern,
                rest_pattern_sec: List.duplicate(rest * 1.0, gap_count),
                duration_sec: target_sec,
                score: score(set_pattern, set_size, preferred_size, rest),
                recommendation: "#{count} × #{reps} reps with auto recovery",
                set_pattern_strategy: :exact_search
              }
            ]
          else
            []
          end
        end)
    end
  end

  defp min_recovery_sec(set_size, preferred_size)
       when is_integer(preferred_size) and preferred_size > 0 and set_size == preferred_size,
       do: 1

  defp min_recovery_sec(_set_size, _preferred_size), do: @min_recovery_sec

  defp within_max_pace?(_sec_per_burpee, :infinity), do: true
  defp within_max_pace?(sec_per_burpee, max_sec_per_rep), do: sec_per_burpee <= max_sec_per_rep

  defp max_recovery_sec(target_sec, target_reps, min_sec_per_rep, gap_count, min_recovery) do
    target_sec
    |> Kernel.-(target_reps * min_sec_per_rep)
    |> Kernel./(gap_count)
    |> floor()
    |> max(min_recovery)
  end

  defp primary_set(set_pattern) do
    set_pattern
    |> Enum.frequencies()
    |> Enum.max_by(fn {_reps, count} -> count end)
  end

  defp score(set_pattern, set_size, preferred_size, rest) do
    target_size =
      if is_integer(preferred_size) and preferred_size > 0 do
        preferred_size
      else
        8
      end

    primary_penalty = abs(set_size - target_size) * 0.5
    recovery_penalty = abs(rest - 20) * 0.05
    complexity_penalty = length(set_pattern) * 0.01
    variance_penalty = (Enum.max(set_pattern) - Enum.min(set_pattern)) * 0.1
    primary_penalty + recovery_penalty + complexity_penalty + variance_penalty
  end

  defp infeasible_message(target_reps, target_sec, min_sec_per_rep) do
    required = target_sec / target_reps

    "#{target_reps} reps in #{format_duration(target_sec)} requires about #{Float.round(required, 1)}s/rep before useful recovery. " <>
      "Safe pace is #{Float.round(min_sec_per_rep, 1)}s/rep or slower. Try lowering reps, increasing duration, or using larger sets."
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
end
