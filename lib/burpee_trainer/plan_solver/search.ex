defmodule BurpeeTrainer.PlanSolver.Search do
  @moduledoc """
  Deterministic exact prescription search.

  Proves feasibility first — total reps and total duration are exact by
  construction — then ranks human-friendly candidates.

  Candidates split the rep target into `k` sets sized `base`/`base + 1`
  (a monotone taper, e.g. 140 reps at 8/set → `14×[8] 4×[7]`), staying
  at or below the preferred set size. When no such split leaves useful
  recovery, larger sets up to a per-type maximum are tried as a
  fallback before giving up. Recovery is the remaining budget spread
  evenly across the gaps between sets.
  """

  alias BurpeeTrainer.PlanNotation

  @min_recovery_sec 8.0
  @sweet_spot_recovery_sec 20.0
  # Sets below this size feel like filler unless explicitly requested.
  @min_set_size 3
  # How far below the preferred set size the taper may reach.
  @taper_window 12
  # Largest set the oversize fallback may use, by type.
  @max_fallback_set_size %{six_count: 15, navy_seal: 8}

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
    case candidates(input) do
      [candidate | _] -> {:ok, candidate}
      [] -> {:error, [infeasible_message(input)]}
    end
  end

  @doc "All feasible candidates, best first."
  @spec candidates(map()) :: [candidate()]
  def candidates(%{} = input) do
    target_reps = Map.fetch!(input, :target_reps)
    target_sec = Map.fetch!(input, :target_sec) * 1.0
    min_sec_per_rep = Map.fetch!(input, :min_sec_per_rep) * 1.0
    burpee_type = Map.fetch!(input, :burpee_type)
    preferred = preferred_set_size(input, target_reps)

    target_reps
    |> set_patterns(preferred, burpee_type)
    |> Enum.flat_map(&balance_candidate(&1, target_reps, target_sec, min_sec_per_rep, preferred))
    |> Enum.sort_by(& &1.score)
  end

  defp preferred_set_size(input, target_reps) do
    case Map.get(input, :preferred_reps_per_set) do
      size when is_integer(size) and size > 0 -> min(size, target_reps)
      _ -> min(default_set_size(Map.fetch!(input, :burpee_type)), target_reps)
    end
  end

  defp default_set_size(:navy_seal), do: 5
  defp default_set_size(_type), do: 8

  # Split target_reps into k sets of base/base+1 for a window of k values.
  # k >= ceil(reps / preferred) guarantees no set exceeds the preferred
  # size; smaller k (larger sets) are offered only as scored-down
  # fallbacks for when the preferred window leaves no useful recovery.
  defp set_patterns(target_reps, preferred, burpee_type) do
    min_size = max(min(@min_set_size, preferred), 1)
    k_min = ceil(target_reps / preferred)
    k_max = target_reps |> div(min_size) |> min(k_min + @taper_window) |> max(k_min)

    fallback_size = max(Map.fetch!(@max_fallback_set_size, burpee_type), preferred)
    k_floor = target_reps |> Kernel./(fallback_size) |> ceil() |> max(1)
    fallback_ks = if k_floor < k_min, do: Enum.to_list(k_floor..(k_min - 1)), else: []

    for k <- Enum.to_list(k_min..k_max) ++ fallback_ks, uniq: true do
      base = div(target_reps, k)
      extra = rem(target_reps, k)
      List.duplicate(base + 1, extra) ++ List.duplicate(base, k - extra)
    end
  end

  defp balance_candidate(set_pattern, target_reps, target_sec, min_sec_per_rep, preferred) do
    gap_count = length(set_pattern) - 1
    fastest_work_sec = target_reps * min_sec_per_rep
    rest_budget = target_sec - fastest_work_sec

    cond do
      rest_budget < 0 ->
        []

      gap_count == 0 ->
        score = score(set_pattern, 0.0, preferred)
        [candidate(set_pattern, target_sec / target_reps, [], target_sec, score, preferred)]

      rest_budget / gap_count < @min_recovery_sec ->
        []

      true ->
        rest = rest_budget / gap_count
        rest_pattern = List.duplicate(rest, gap_count)
        score = score(set_pattern, rest, preferred)
        [candidate(set_pattern, min_sec_per_rep, rest_pattern, target_sec, score, preferred)]
    end
  end

  defp candidate(set_pattern, sec_per_burpee, rest_pattern, duration_sec, score, _preferred) do
    %{
      sec_per_burpee: sec_per_burpee,
      set_pattern: set_pattern,
      rest_pattern_sec: rest_pattern,
      duration_sec: duration_sec,
      score: score,
      recommendation: PlanNotation.from_pattern(set_pattern),
      set_pattern_strategy: :exact_search
    }
  end

  # Oversize patterns are a last resort: any candidate that respects the
  # preferred set size beats every candidate that exceeds it.
  defp score(set_pattern, rest, preferred) do
    size_penalty = set_pattern |> Enum.map(&abs(&1 - preferred)) |> Enum.sum()
    oversize_penalty = if Enum.any?(set_pattern, &(&1 > preferred)), do: 10_000.0, else: 0.0
    recovery_penalty = abs(rest - @sweet_spot_recovery_sec) * 0.05
    complexity_penalty = length(set_pattern) * 0.01
    size_penalty + oversize_penalty + recovery_penalty + complexity_penalty
  end

  defp infeasible_message(input) do
    target_reps = Map.fetch!(input, :target_reps)
    target_sec = Map.fetch!(input, :target_sec) * 1.0
    min_sec_per_rep = Map.fetch!(input, :min_sec_per_rep) * 1.0
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
