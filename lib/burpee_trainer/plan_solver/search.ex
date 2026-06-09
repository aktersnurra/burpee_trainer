defmodule BurpeeTrainer.PlanSolver.Search do
  @moduledoc """
  Deterministic exact prescription search.

  This module proves feasibility first, then ranks human-friendly candidates.
  """

  @human_set_sizes %{six_count: [8, 10, 12, 6, 15, 5, 4], navy_seal: [5, 4, 6, 3]}
  @min_recovery_sec 8.0
  @max_recovery_sec 90.0

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
    burpee_type = Map.fetch!(input, :burpee_type)
    preferred = Map.get(input, :preferred_reps_per_set)

    candidates =
      burpee_type
      |> set_sizes(preferred)
      |> Enum.flat_map(fn set_size ->
        repeated_set_candidate(target_reps, target_sec, min_sec_per_rep, set_size)
      end)
      |> Enum.sort_by(& &1.score)

    case candidates do
      [candidate | _] -> {:ok, candidate}
      [] -> {:error, [infeasible_message(target_reps, target_sec, min_sec_per_rep)]}
    end
  end

  defp set_sizes(type, preferred) do
    base = Map.fetch!(@human_set_sizes, type)

    if is_integer(preferred) and preferred > 0 do
      [preferred | base]
    else
      base
    end
    |> Enum.uniq()
  end

  defp repeated_set_candidate(target_reps, target_sec, min_sec_per_rep, set_size) do
    if rem(target_reps, set_size) == 0 do
      set_count = div(target_reps, set_size)
      gap_count = max(set_count - 1, 0)

      fastest_work_sec = target_reps * min_sec_per_rep
      rest_budget = target_sec - fastest_work_sec

      cond do
        rest_budget < 0 ->
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

        rest_budget / gap_count < @min_recovery_sec ->
          []

        rest_budget / gap_count > @max_recovery_sec ->
          []

        true ->
          rest = rest_budget / gap_count
          set_pattern = List.duplicate(set_size, set_count)

          [
            %{
              sec_per_burpee: min_sec_per_rep,
              set_pattern: set_pattern,
              rest_pattern_sec: List.duplicate(rest, gap_count),
              duration_sec: target_sec,
              score: score(set_size, set_count, rest),
              recommendation: "#{set_count} × #{set_size} reps with auto recovery",
              set_pattern_strategy: :exact_search
            }
          ]
      end
    else
      []
    end
  end

  defp score(set_size, set_count, rest) do
    work_interval_penalty = abs(set_size - 8) * 0.5
    recovery_penalty = abs(rest - 20) * 0.05
    complexity_penalty = set_count * 0.01
    work_interval_penalty + recovery_penalty + complexity_penalty
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
