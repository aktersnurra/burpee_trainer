defmodule BurpeeTrainer.Workouts.PaceConsistencyTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Workouts.PaceConsistency

  test "constant intervals produce 1" do
    assert PaceConsistency.score([1000, 2000, 3000, 4000]) == 1.0
  end

  test "fewer than three reps returns nil" do
    assert PaceConsistency.score([]) == nil
    assert PaceConsistency.score([1000]) == nil
    assert PaceConsistency.score([1000, 2000]) == nil
  end

  test "score stays in range" do
    score = PaceConsistency.score([1000, 3000, 8000, 16000, 30000])
    assert score >= 0.0
    assert score <= 1.0
  end

  test "uniform scaling does not change score" do
    assert PaceConsistency.score([1000, 2000, 4000, 7000]) ==
             PaceConsistency.score([2000, 4000, 8000, 14000])
  end

  test "irregular intervals score lower than flat intervals" do
    assert PaceConsistency.score([1000, 2000, 3000, 4000, 5000]) >
             PaceConsistency.score([1000, 2000, 3500, 6000, 10000])
  end
end
