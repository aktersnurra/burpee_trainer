defmodule BurpeeTrainer.PlanSolver.BoundaryPlacementTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanSolver.{BoundaryPlacement, ExplicitRest}

  test "places reset candidates inside elapsed-time windows" do
    set_pattern = List.duplicate(7, 20)
    sec_per_rep = 5.464285714285714

    placements = BoundaryPlacement.enumerate(set_pattern, sec_per_rep, 15, [90, 90], [])

    assert Enum.any?(placements, fn placement ->
             mid = Enum.find(placement.auto_resets, &(&1.kind == :mid))
             late = Enum.find(placement.auto_resets, &(&1.kind == :late))

             not is_nil(mid) and not is_nil(late) and
               mid.starts_at_sec >= 660 and mid.starts_at_sec <= 804 and
               late.starts_at_sec >= 1_020 and late.starts_at_sec <= 1_152
           end)
  end

  test "does not place a reset after the final set" do
    set_pattern = List.duplicate(7, 20)

    placements = BoundaryPlacement.enumerate(set_pattern, 5.46, 15, [90, 90], [])

    assert Enum.all?(placements, fn placement ->
             Enum.all?(placement.auto_resets, &(&1.after_set < 20))
           end)
  end

  test "places explicit rest at the closest canonical boundary within tolerance" do
    set_pattern = List.duplicate(7, 20)
    explicit_rest = %ExplicitRest{target_elapsed_sec: 720, duration_sec: 60, tolerance_sec: 90}

    placements = BoundaryPlacement.enumerate(set_pattern, 5.46, 15, [90], [explicit_rest])

    assert Enum.any?(placements, fn placement ->
             Enum.any?(placement.explicit_rests, fn rest ->
               rest.duration_sec == 60 and abs(rest.starts_at_sec - 720) <= 90
             end)
           end)
  end
end
