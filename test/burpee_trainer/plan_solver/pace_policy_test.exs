defmodule BurpeeTrainer.PlanSolver.PacePolicyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.PacePolicy

  test "six-count policy has ordered hard and preferred bounds" do
    policy = PacePolicy.for(:six_count)

    assert policy.hard_fastest_sec_per_rep == 3.7
    assert policy.preferred_fast_sec_per_rep == 4.8
    assert policy.preferred_slow_sec_per_rep == 5.8
    assert policy.hard_slowest_sec_per_rep == 7.0

    assert policy.hard_fastest_sec_per_rep <= policy.preferred_fast_sec_per_rep
    assert policy.preferred_fast_sec_per_rep <= policy.preferred_slow_sec_per_rep
    assert policy.preferred_slow_sec_per_rep <= policy.hard_slowest_sec_per_rep
  end

  test "navy-seal policy has ordered hard and preferred bounds" do
    policy = PacePolicy.for(:navy_seal)

    assert policy.hard_fastest_sec_per_rep == 8.0
    assert policy.preferred_fast_sec_per_rep == 9.0
    assert policy.preferred_slow_sec_per_rep == 11.0
    assert policy.hard_slowest_sec_per_rep == 13.0
  end
end
