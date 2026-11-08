defmodule BurpeeTrainer.Coach.EnduranceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Coach.Endurance

  test "forty minutes holds one and a half times a twenty-minute session's reps" do
    assert Endurance.factor(2_400) == 1.5
    assert Endurance.factor(1_200) == 1.0
    # An hour is not three twenty-minute sessions back to back.
    assert_in_delta Endurance.factor(3_600), 1.9, 0.01
  end

  test "up to twenty minutes a session counts as it is" do
    assert Endurance.factor(600) == 1.0
  end

  property "a longer session holds more reps, but fewer than in proportion" do
    check all(shorter <- integer(1_201..7_200), extra <- integer(1..3_600)) do
      longer = shorter + extra
      assert Endurance.factor(shorter) < Endurance.factor(longer)
      assert Endurance.factor(longer) < longer / 1_200
    end
  end
end
