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
    assert candidate.recommendation == "20×[8]"
  end

  test "tapers indivisible targets instead of leaving an orphan set" do
    assert {:ok, candidate} =
             Search.solve(%{
               burpee_type: :six_count,
               target_reps: 140,
               target_sec: 1200,
               min_sec_per_rep: 5.0,
               preferred_reps_per_set: 8
             })

    assert candidate.set_pattern == List.duplicate(8, 14) ++ List.duplicate(7, 4)
    assert candidate.recommendation == "14×[8] 4×[7]"
    assert Enum.sum(candidate.set_pattern) == 140
    assert_in_delta candidate.duration_sec, 1200.0, 0.001
  end

  test "never exceeds the preferred set size" do
    for {reps, preferred} <- [{107, 10}, {53, 8}, {91, 5}, {140, 8}] do
      assert {:ok, candidate} =
               Search.solve(%{
                 burpee_type: :six_count,
                 target_reps: reps,
                 target_sec: 3600,
                 min_sec_per_rep: 5.0,
                 preferred_reps_per_set: preferred
               })

      assert Enum.sum(candidate.set_pattern) == reps
      assert Enum.max(candidate.set_pattern) <= preferred
      # Monotone taper: sets never grow as fatigue accumulates.
      assert candidate.set_pattern == Enum.sort(candidate.set_pattern, :desc)
    end
  end

  test "uses a single set when the target fits in one" do
    assert {:ok, candidate} =
             Search.solve(%{
               burpee_type: :six_count,
               target_reps: 6,
               target_sec: 120,
               min_sec_per_rep: 5.0,
               preferred_reps_per_set: 8
             })

    assert candidate.set_pattern == [6]
    assert candidate.rest_pattern_sec == []
    # Pace slows to fill the whole target.
    assert_in_delta candidate.sec_per_burpee, 20.0, 0.001
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
