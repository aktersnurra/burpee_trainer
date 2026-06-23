defmodule BurpeeTrainer.PlanSolver.CandidateScoreTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{CandidateScore, PacePolicy}

  test "preferred band beats outside-band pace" do
    policy = PacePolicy.for(:six_count)

    comfortable = %{
      sec_per_rep: 5.4,
      explicit_rest_target_error_ms: 0,
      reset_count_miss: 0,
      reset_window_error_ms: 0,
      structure_shape_penalty: 0,
      structure_complexity_penalty: 1,
      normal_recovery_preference_error: 0,
      canonical_tiebreaker: "b"
    }

    too_fast = %{comfortable | sec_per_rep: 4.2, canonical_tiebreaker: "a"}

    assert CandidateScore.key(comfortable, policy) < CandidateScore.key(too_fast, policy)
  end

  test "canonical tiebreaker is stable when all earlier score fields match" do
    policy = PacePolicy.for(:six_count)

    left = %{
      sec_per_rep: 5.4,
      explicit_rest_target_error_ms: 0,
      reset_count_miss: 0,
      reset_window_error_ms: 0,
      structure_shape_penalty: 0,
      structure_complexity_penalty: 1,
      normal_recovery_preference_error: 0,
      canonical_tiebreaker: "20x[7]|15|2|13,19"
    }

    right = %{left | canonical_tiebreaker: "5x[8]|15|2|13,19"}

    assert CandidateScore.key(left, policy) < CandidateScore.key(right, policy)
  end
end
