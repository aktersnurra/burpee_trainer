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

  describe "ideal_rests/1" do
    test ":even style with fatigue_factor=0.0 distributes uniformly" do
      input = %BurpeeTrainer.PlanWizard.PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        sec_per_burpee: 4.0,
        pacing_style: :even,
        fatigue_factor: 0.0
      }

      model = BurpeeTrainer.PlanWizard.SlotModel.new(input, nil)
      ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)
      [first | rest] = ideals

      Enum.each(rest, fn r -> assert_in_delta r, first, 1.0e-6 end)

      assert_in_delta Enum.sum(ideals),
                      BurpeeTrainer.PlanWizard.SlotModel.rest_budget(model),
                      1.0e-6
    end

    test ":even style with fatigue_factor=1.0 biases later slots" do
      input = %BurpeeTrainer.PlanWizard.PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 5,
        sec_per_burpee: 4.0,
        pacing_style: :even,
        fatigue_factor: 1.0
      }

      model = BurpeeTrainer.PlanWizard.SlotModel.new(input, nil)
      ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)

      pairs = Enum.zip(ideals, tl(ideals))
      Enum.each(pairs, fn {a, b} -> assert b > a end)

      assert_in_delta Enum.sum(ideals),
                      BurpeeTrainer.PlanWizard.SlotModel.rest_budget(model),
                      1.0e-6
    end

    test ":unbroken style: zero-weight slots stay zero under fatigue" do
      input = %BurpeeTrainer.PlanWizard.PlanInput{
        name: "t",
        burpee_type: :six_count,
        target_duration_min: 10,
        burpee_count_target: 10,
        sec_per_burpee: 4.0,
        pacing_style: :unbroken,
        reps_per_set: 5,
        fatigue_factor: 1.0
      }

      model = BurpeeTrainer.PlanWizard.SlotModel.new(input, 5)
      ideals = BurpeeTrainer.PlanWizard.SlotModel.ideal_rests(model)

      Enum.with_index(ideals, 1)
      |> Enum.each(fn {v, i} ->
        if i == 5, do: assert(v > 0), else: assert_in_delta(v, 0.0, 1.0e-6)
      end)
    end
  end
end
