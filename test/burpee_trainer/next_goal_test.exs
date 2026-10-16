defmodule BurpeeTrainer.NextGoalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.NextGoal

  @today ~D[2026-10-13]

  property "the next goal is always above the best, in 20 minutes, six weeks out" do
    check all(
            type <- member_of([:six_count, :navy_seal]),
            best <- integer(0..600)
          ) do
      goal = NextGoal.for_best(type, best, @today)
      assert goal.burpee_type == type
      assert goal.burpee_count_target > best
      assert goal.duration_sec_target == 1200
      assert goal.date_target == Date.add(@today, 42)
    end
  end

  test "it is the next level landmark above the best for that type" do
    assert NextGoal.for_best(:six_count, 130, @today).burpee_count_target == 150
    assert NextGoal.for_best(:six_count, 150, @today).burpee_count_target == 200
    assert NextGoal.for_best(:navy_seal, 20, @today).burpee_count_target == 40
    assert NextGoal.for_best(:six_count, 0, @today).burpee_count_target == 50
  end

  test "above the last landmark it is ten percent more, rounded up to five" do
    assert NextGoal.for_best(:six_count, 330, @today).burpee_count_target == 365
    assert NextGoal.for_best(:navy_seal, 150, @today).burpee_count_target == 165
  end
end
