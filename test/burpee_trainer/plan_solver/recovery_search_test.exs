defmodule BurpeeTrainer.PlanSolver.RecoverySearchTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{BlockSpec, Input, PacePolicy, RecoverySearch}

  test "derives exact pace from selected recovery and target duration" do
    {:ok, block} = BlockSpec.new(20, [7])

    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 1_200,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8
    }

    policy = PacePolicy.for(:six_count)

    assert [candidate | _] = RecoverySearch.candidates(input, policy, [block])
    assert candidate.sec_per_rep >= policy.hard_fastest_sec_per_rep
    assert candidate.sec_per_rep <= policy.hard_slowest_sec_per_rep
    assert Enum.sum(candidate.set_pattern) == 140
    assert candidate.normal_recovery_sec in [8, 10, 12, 15, 18, 20, 25]
  end

  test "does not return candidates outside hard pace bounds" do
    {:ok, block} = BlockSpec.new(20, [7])

    input = %Input{
      burpee_type: :six_count,
      target_duration_sec: 300,
      burpee_count_target: 140,
      pacing_style: :unbroken,
      max_unbroken_reps: 8
    }

    assert [] = RecoverySearch.candidates(input, PacePolicy.for(:six_count), [block])
  end
end
