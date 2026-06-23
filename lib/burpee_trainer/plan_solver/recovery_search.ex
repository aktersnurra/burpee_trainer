defmodule BurpeeTrainer.PlanSolver.RecoverySearch do
  @moduledoc """
  Enumerates human-readable recovery candidates for unbroken structures.
  """

  alias BurpeeTrainer.PlanSolver.{
    BoundaryPlacement,
    CandidateScore,
    PacePolicy,
    Recovery,
    StructureSearch
  }

  @normal_recovery_candidates_sec [8, 10, 12, 15, 18, 20, 25]
  @reset_recovery_candidates_sec [45, 60, 75, 90, 105, 120, 150, 180]

  @spec candidates(BurpeeTrainer.PlanSolver.Input.t(), PacePolicy.t(), [
          BurpeeTrainer.PlanSolver.BlockSpec.t()
        ]) :: [map]
  def candidates(input, %PacePolicy{} = policy, structure) do
    structure
    |> candidates_for_structure(input, policy)
    |> Enum.uniq_by(& &1.canonical_tiebreaker)
    |> Enum.map(&%{&1 | score_key: CandidateScore.key(&1, policy)})
    |> Enum.sort_by(& &1.score_key)
  end

  defp candidates_for_structure(structure, input, policy) do
    set_pattern = StructureSearch.expand(structure)
    explicit_rests = input.explicit_rests || []

    for normal_sec <- @normal_recovery_candidates_sec,
        reset_durations <- reset_duration_sets(input.target_duration_sec),
        placement <-
          BoundaryPlacement.enumerate(
            set_pattern,
            representative_pace(input, policy),
            normal_sec,
            reset_durations,
            explicit_rests
          ),
        candidate = build_candidate(input, policy, structure, normal_sec, placement),
        hard_feasible?(candidate, policy) do
      candidate
    end
  end

  defp build_candidate(input, _policy, structure, normal_sec, placement) do
    set_pattern = StructureSearch.expand(structure)
    reset_indexes = MapSet.new(Enum.map(placement.auto_resets, & &1.after_set))
    gap_count = max(length(set_pattern) - 1, 0)
    normal_gap_count = gap_count - MapSet.size(reset_indexes)
    auto_reset_total = Enum.reduce(placement.auto_resets, 0, &(&1.duration_sec + &2))
    explicit_total = Enum.reduce(placement.explicit_rests, 0, &(&1.duration_sec + &2))
    recovery_total = normal_gap_count * normal_sec + auto_reset_total + explicit_total
    sec_per_rep = (input.target_duration_sec - recovery_total) / input.burpee_count_target

    %{
      structure: structure,
      set_pattern: set_pattern,
      sec_per_rep: sec_per_rep,
      normal_recovery_sec: normal_sec,
      recoveries: recoveries(set_pattern, normal_sec, placement),
      placement: placement,
      explicit_rest_target_error_ms: explicit_rest_target_error_ms(placement),
      reset_count_miss: reset_count_miss(input.target_duration_sec, placement),
      reset_window_error_ms: reset_window_error_ms(input.target_duration_sec, placement),
      structure_shape_penalty: structure_shape_penalty(structure, input),
      structure_complexity_penalty: structure_complexity_penalty(structure),
      normal_recovery_preference_error: abs(normal_sec - 15),
      canonical_tiebreaker: canonical_tiebreaker(structure, normal_sec, placement, sec_per_rep),
      score_key: nil
    }
  end

  defp hard_feasible?(candidate, policy) do
    candidate.sec_per_rep >= policy.hard_fastest_sec_per_rep and
      candidate.sec_per_rep <= policy.hard_slowest_sec_per_rep
  end

  defp representative_pace(input, policy) do
    cond do
      is_float(input.sec_per_rep_override) -> input.sec_per_rep_override
      true -> (policy.preferred_fast_sec_per_rep + policy.preferred_slow_sec_per_rep) / 2
    end
  end

  defp reset_duration_sets(target_duration_sec) do
    cond do
      target_duration_sec < 12 * 60 ->
        [[]]

      target_duration_sec < 18 * 60 ->
        [[]] ++ Enum.map(@reset_recovery_candidates_sec, &[&1])

      true ->
        [[]] ++
          Enum.map(@reset_recovery_candidates_sec, &[&1]) ++
          for mid <- @reset_recovery_candidates_sec,
              late <- @reset_recovery_candidates_sec do
            [mid, late]
          end
    end
  end

  defp recoveries(set_pattern, normal_sec, placement) do
    reset_by_set = Map.new(placement.auto_resets, &{&1.after_set, &1})
    explicit_by_set = Enum.group_by(placement.explicit_rests, & &1.after_set)

    automatic =
      for after_set <- 1..(length(set_pattern) - 1) do
        case Map.get(reset_by_set, after_set) do
          nil ->
            %Recovery{
              after_set: after_set,
              total_sec: normal_sec,
              kind: :normal,
              source: :auto_normal
            }

          reset ->
            %Recovery{
              after_set: after_set,
              total_sec: reset.duration_sec,
              kind: :reset,
              source: {:auto_reset, reset.kind}
            }
        end
      end

    explicit =
      explicit_by_set
      |> Enum.flat_map(fn {after_set, rests} ->
        Enum.map(rests, fn rest ->
          %Recovery{
            after_set: after_set,
            total_sec: rest.duration_sec,
            kind: :explicit,
            source: {:explicit, rest.source.target_elapsed_sec}
          }
        end)
      end)

    Enum.sort_by(automatic ++ explicit, &{&1.after_set, recovery_order(&1.kind)})
  end

  defp recovery_order(:normal), do: 0
  defp recovery_order(:reset), do: 0
  defp recovery_order(:explicit), do: 1

  defp explicit_rest_target_error_ms(%{explicit_rests: explicit_rests}) do
    explicit_rests
    |> Enum.reduce(0, fn rest, total ->
      total + round(abs(rest.starts_at_sec - rest.source.target_elapsed_sec) * 1_000)
    end)
  end

  defp reset_count_miss(target_duration_sec, %{auto_resets: auto_resets}) do
    abs(preferred_reset_count(target_duration_sec) - length(auto_resets))
  end

  defp preferred_reset_count(target_duration_sec) when target_duration_sec < 12 * 60, do: 0
  defp preferred_reset_count(target_duration_sec) when target_duration_sec < 18 * 60, do: 1
  defp preferred_reset_count(_target_duration_sec), do: 2

  defp reset_window_error_ms(target_duration_sec, %{auto_resets: auto_resets}) do
    centers = reset_centers(target_duration_sec)

    auto_resets
    |> Enum.reduce(0, fn reset, total ->
      center = Map.fetch!(centers, reset.kind)
      total + round(abs(reset.starts_at_sec - center) * 1_000)
    end)
  end

  defp reset_centers(target_duration_sec) do
    %{mid: 0.60 * target_duration_sec, late: 0.90 * target_duration_sec}
  end

  defp structure_shape_penalty(structure, input) do
    set_pattern = StructureSearch.expand(structure)
    first_average = structure |> hd() |> BurpeeTrainer.PlanSolver.BlockSpec.average_reps()
    final_average = structure |> List.last() |> BurpeeTrainer.PlanSolver.BlockSpec.average_reps()

    max_penalty = if Enum.max(hd(structure).motif) == input.max_unbroken_reps, do: 0, else: 1
    taper_penalty = if final_average <= first_average, do: 0, else: 5
    tiny_penalty = if Enum.min(set_pattern) < max(input.max_unbroken_reps - 3, 1), do: 10, else: 0
    distinct_penalty = max(length(Enum.uniq(set_pattern)) - 3, 0)

    max_penalty + taper_penalty + tiny_penalty + distinct_penalty
  end

  defp structure_complexity_penalty(structure) do
    set_pattern = StructureSearch.expand(structure)
    length(structure) * 10 + length(Enum.uniq(set_pattern)) + length(set_pattern)
  end

  defp canonical_tiebreaker(structure, normal_sec, placement, sec_per_rep) do
    reset_key =
      placement.auto_resets
      |> Enum.map(&"#{&1.kind}:#{&1.after_set}:#{&1.duration_sec}")
      |> Enum.join(",")

    explicit_key =
      placement.explicit_rests
      |> Enum.map(&"#{&1.after_set}:#{&1.duration_sec}")
      |> Enum.join(",")

    [
      StructureSearch.encode(structure),
      normal_sec,
      length(placement.auto_resets),
      reset_key,
      explicit_key,
      Float.to_string(sec_per_rep)
    ]
    |> Enum.join("|")
  end
end
