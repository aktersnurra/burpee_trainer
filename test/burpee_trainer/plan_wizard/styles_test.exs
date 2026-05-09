defmodule BurpeeTrainer.PlanWizard.StylesTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.Styles

  describe "weight_vector/3 — :even" do
    test "produces total_reps - 1 slots, all weight 1.0" do
      assert Styles.weight_vector(:even, 5, nil) == [1.0, 1.0, 1.0, 1.0]
    end

    test "single rep yields no slots" do
      assert Styles.weight_vector(:even, 1, nil) == []
    end

    test "ignores reps_per_set" do
      assert Styles.weight_vector(:even, 4, 2) == Styles.weight_vector(:even, 4, nil)
    end
  end

  describe "weight_vector/3 — :unbroken" do
    test "places weight at each set boundary" do
      # 10 reps, 3 per set → boundaries after rep 3, 6, 9 (slots 3, 6, 9)
      vector = Styles.weight_vector(:unbroken, 10, 3)
      assert length(vector) == 9
      assert Enum.at(vector, 0) == 0.0
      assert Enum.at(vector, 1) == 0.0
      assert Enum.at(vector, 2) == 1.0
      assert Enum.at(vector, 3) == 0.0
      assert Enum.at(vector, 4) == 0.0
      assert Enum.at(vector, 5) == 1.0
      assert Enum.at(vector, 6) == 0.0
      assert Enum.at(vector, 7) == 0.0
      assert Enum.at(vector, 8) == 1.0
    end

    test "evenly divisible: weight at every reps_per_set, none at final rep" do
      # 9 reps, 3 per set → boundaries after rep 3, 6 (slot 8 is after rep 9 — does not exist)
      vector = Styles.weight_vector(:unbroken, 9, 3)
      assert length(vector) == 8
      assert Enum.at(vector, 2) == 1.0
      assert Enum.at(vector, 5) == 1.0
      # No slot exists after the final rep, so the trailing set has no rest
      assert Enum.sum(vector) == 2.0
    end

    test "remainder: partial final set has no boundary after it" do
      # 11 reps, 5 per set → boundaries after rep 5 and rep 10 (last set has 1 rep)
      vector = Styles.weight_vector(:unbroken, 11, 5)
      assert length(vector) == 10
      assert Enum.at(vector, 4) == 1.0
      assert Enum.at(vector, 9) == 1.0
      assert Enum.sum(vector) == 2.0
    end

    test "reps_per_set larger than total_reps: zero boundaries" do
      vector = Styles.weight_vector(:unbroken, 5, 10)
      assert length(vector) == 4
      assert Enum.sum(vector) == 0.0
    end

    test "single rep yields no slots" do
      assert Styles.weight_vector(:unbroken, 1, 5) == []
    end
  end
end
