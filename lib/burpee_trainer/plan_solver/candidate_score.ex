defmodule BurpeeTrainer.PlanSolver.CandidateScore do
  @moduledoc "Lexicographic score keys for Plan Solver v3 candidates."

  alias BurpeeTrainer.PlanSolver.PacePolicy

  @spec key(map, PacePolicy.t()) :: tuple
  def key(candidate, %PacePolicy{} = policy) do
    {
      pace_band_violation_ms(candidate.sec_per_rep, policy),
      candidate.explicit_rest_target_error_ms,
      candidate.reset_count_miss,
      candidate.structure_shape_penalty,
      candidate.structure_complexity_penalty,
      candidate.reset_window_error_ms,
      pace_midpoint_error_ms(candidate.sec_per_rep, policy),
      candidate.normal_recovery_preference_error,
      candidate.canonical_tiebreaker
    }
  end

  defp pace_band_violation_ms(sec_per_rep, policy) do
    cond do
      sec_per_rep < policy.preferred_fast_sec_per_rep ->
        round((policy.preferred_fast_sec_per_rep - sec_per_rep) * 1_000)

      sec_per_rep > policy.preferred_slow_sec_per_rep ->
        round((sec_per_rep - policy.preferred_slow_sec_per_rep) * 1_000)

      true ->
        0
    end
  end

  defp pace_midpoint_error_ms(sec_per_rep, policy) do
    midpoint = (policy.preferred_fast_sec_per_rep + policy.preferred_slow_sec_per_rep) / 2
    round(abs(sec_per_rep - midpoint) * 1_000)
  end
end
