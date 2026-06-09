defmodule BurpeeTrainer.PlanSolver.SearchTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.Search

  test "solves 160 reps in 20 minutes as exact 20 x 8" do
    assert {:ok, candidate} =
             Search.solve(%{
               burpee_type: :six_count,
               pacing_style: :unbroken,
               target_reps: 160,
               target_sec: 1200,
               min_sec_per_rep: 5.513,
               preferred_reps_per_set: 8,
               block_pattern: nil,
               additional_rests: []
             })

    assert candidate.set_pattern == List.duplicate(8, 20)
    assert length(candidate.rest_pattern_sec) == 19
    assert_in_delta candidate.duration_sec, 1200.0, 0.001
    assert candidate.sec_per_burpee >= 5.513
    assert candidate.recommendation == "20 × 8 reps with auto recovery"
  end

  test "rejects impossible target instead of returning invalid duration" do
    assert {:error, [message]} =
             Search.solve(%{
               burpee_type: :six_count,
               pacing_style: :unbroken,
               target_reps: 300,
               target_sec: 1200,
               min_sec_per_rep: 7.955,
               preferred_reps_per_set: 8,
               block_pattern: nil,
               additional_rests: []
             })

    assert message =~ "requires"
  end
end
