defmodule BurpeeTrainer.PlanSolver.UnbrokenSolver do
  @moduledoc "Plan Solver v3 unbroken branch."

  alias BurpeeTrainer.PlanSolver.{
    Infeasible,
    PacePolicy,
    Prescription,
    RecoverySearch,
    StructureSearch
  }

  @spec solve(BurpeeTrainer.PlanSolver.Input.t(), PacePolicy.t()) ::
          {:ok, Prescription.t()} | {:error, Infeasible.t()}
  def solve(input, %PacePolicy{} = policy) do
    with :ok <- preflight(input, policy),
         {:ok, structures} <- StructureSearch.structures(input) do
      candidates =
        structures
        |> Enum.flat_map(&RecoverySearch.candidates(input, policy, &1))
        |> Enum.sort_by(& &1.score_key)

      case candidates do
        [] -> {:error, no_human_shaped_recovery_allocation(input)}
        [candidate | _] -> {:ok, prescription(input, policy, candidate, length(candidates))}
      end
    end
  end

  defp preflight(input, policy) do
    min_work_sec = input.burpee_count_target * policy.hard_fastest_sec_per_rep

    if min_work_sec > input.target_duration_sec do
      {:error,
       %Infeasible{
         reason: :work_alone_exceeds_duration,
         details: %{min_work_sec: min_work_sec, target_duration_sec: input.target_duration_sec},
         suggestions: [
           "Reduce total reps",
           "Increase duration",
           "Choose a slower burpee type target"
         ]
       }}
    else
      :ok
    end
  end

  defp prescription(input, policy, candidate, candidate_count) do
    %Prescription{
      pacing_style: :unbroken,
      burpee_type: input.burpee_type,
      target_duration_sec: input.target_duration_sec,
      burpee_count: input.burpee_count_target,
      sec_per_rep: candidate.sec_per_rep,
      cadence_sec: nil,
      blocks: candidate.structure,
      set_pattern: candidate.set_pattern,
      recoveries: candidate.recoveries,
      execution: nil,
      score: candidate.score_key,
      metadata: metadata(input, policy, candidate, candidate_count)
    }
  end

  defp metadata(input, policy, candidate, candidate_count) do
    %{
      solver_version: 3,
      strategy: strategy(input, candidate),
      generated_candidate_count: candidate_count,
      feasible_candidate_count: candidate_count,
      pace_status: pace_status(candidate.sec_per_rep, policy),
      pace_policy: %{
        hard_fastest_sec_per_rep: policy.hard_fastest_sec_per_rep,
        preferred_fast_sec_per_rep: policy.preferred_fast_sec_per_rep,
        preferred_slow_sec_per_rep: policy.preferred_slow_sec_per_rep,
        hard_slowest_sec_per_rep: policy.hard_slowest_sec_per_rep
      },
      score_key: candidate.score_key,
      recommendation: "#{StructureSearch.encode(candidate.structure)} with auto recovery",
      rest_suggestions: [],
      recovery_mode: :auto,
      recovery_sec: candidate.normal_recovery_sec,
      work_interval_sec: candidate.sec_per_rep * (candidate.set_pattern |> Enum.max()),
      normal_recovery_sec: candidate.normal_recovery_sec,
      auto_resets:
        Enum.map(candidate.placement.auto_resets, fn reset ->
          %{
            kind: reset.kind,
            after_set: reset.after_set,
            starts_at_sec: reset.starts_at_sec,
            duration_sec: reset.duration_sec
          }
        end),
      structure_key: StructureSearch.encode(candidate.structure)
    }
  end

  defp strategy(%{block_structure: blocks}, _candidate) when is_list(blocks) and blocks != [],
    do: :manual_structure

  defp strategy(_input, candidate) do
    if length(candidate.structure) == 1 and hd(candidate.structure).repeat > 12 do
      :balanced_fallback
    else
      :generated_grammar
    end
  end

  defp pace_status(sec_per_rep, policy) do
    cond do
      sec_per_rep < policy.preferred_fast_sec_per_rep -> :too_fast
      sec_per_rep > policy.preferred_slow_sec_per_rep -> :too_slow
      true -> :comfortable
    end
  end

  defp no_human_shaped_recovery_allocation(input) do
    %Infeasible{
      reason: :no_human_shaped_recovery_allocation,
      details: %{
        target_duration_sec: input.target_duration_sec,
        burpee_count_target: input.burpee_count_target,
        max_unbroken_reps: input.max_unbroken_reps
      },
      suggestions: [
        "Reduce total reps",
        "Increase duration",
        "Increase maximum unbroken set size",
        "Provide a different manual block structure"
      ]
    }
  end
end
