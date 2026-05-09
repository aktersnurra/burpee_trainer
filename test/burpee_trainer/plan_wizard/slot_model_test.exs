defmodule BurpeeTrainer.PlanWizard.SlotModelTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{PlanInput, SlotModel}

  defp input(overrides \\ %{}) do
    base = %PlanInput{
      name: "Test plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      reps_per_set: nil
    }

    struct!(base, overrides)
  end

  describe "new/2 — :even" do
    test "weight vector has total_reps - 1 entries, all 1.0" do
      m = SlotModel.new(input(burpee_count_target: 4, pacing_style: :even), nil)
      assert m.weights == [1.0, 1.0, 1.0]
    end

    test "target_duration_sec is minutes × 60" do
      m = SlotModel.new(input(target_duration_min: 20), nil)
      assert m.target_duration_sec == 1200
    end

    test "additional_rests_input round-trips verbatim" do
      rests = [%{rest_sec: 30, target_min: 5}, %{rest_sec: 45, target_min: 10}]
      m = SlotModel.new(input(additional_rests: rests), nil)
      assert m.additional_rests_input == rests
    end

    test "missing additional_rests defaults to empty list" do
      m = SlotModel.new(input(), nil)
      assert m.additional_rests_input == []
    end
  end

  describe "new/2 — :unbroken" do
    test "weights concentrate at every reps_per_set" do
      m = SlotModel.new(input(burpee_count_target: 10, pacing_style: :unbroken), 5)
      # boundaries after rep 5 (slot index 4 in 0-based → slot 5 in 1-based)
      assert m.weights == [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0]
      assert m.reps_per_set == 5
    end
  end

  describe "work_sec/1" do
    test "is total_reps × sec_per_burpee" do
      m = SlotModel.new(input(burpee_count_target: 100, sec_per_burpee: 5.0), nil)
      assert SlotModel.work_sec(m) == 500.0
    end
  end

  describe "additional_rest_total/1" do
    test "sums rest_sec across all reservations" do
      rests = [%{rest_sec: 30, target_min: 5}, %{rest_sec: 45, target_min: 10}]
      m = SlotModel.new(input(additional_rests: rests), nil)
      assert SlotModel.additional_rest_total(m) == 75.0
    end

    test "is 0.0 when no rests" do
      m = SlotModel.new(input(), nil)
      assert SlotModel.additional_rest_total(m) == 0.0
    end
  end

  describe "rest_budget/1" do
    test "is target − work − additional_rests" do
      # 20 min × 60 = 1200s; 100 × 5 = 500s work; 75s additional → 625s budget
      rests = [%{rest_sec: 30, target_min: 5}, %{rest_sec: 45, target_min: 10}]
      m = SlotModel.new(input(additional_rests: rests), nil)
      assert SlotModel.rest_budget(m) == 625.0
    end

    test "without additional rests, budget = target − work" do
      m = SlotModel.new(input(), nil)
      assert SlotModel.rest_budget(m) == 700.0
    end

    test "can be negative when work alone exceeds target" do
      m = SlotModel.new(input(target_duration_min: 5, burpee_count_target: 100), nil)
      # 300s target − 500s work = −200s
      assert SlotModel.rest_budget(m) == -200.0
    end
  end
end
