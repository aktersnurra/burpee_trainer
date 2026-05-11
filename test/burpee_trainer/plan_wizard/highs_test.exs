defmodule BurpeeTrainer.PlanWizard.HighsTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanWizard.{Highs, Lp, PlanInput, SlotModel}

  @moduletag :highs

  test "solves a no-reservation :even plan and returns slot rest values" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 5,
      sec_per_burpee: 4.0,
      pacing_style: :even
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    assert {:ok, %{r: r, objective: _obj}} = Highs.solve(problem)
    assert length(r) == 4
    Enum.each(r, fn v -> assert v >= -1.0e-6 end)
    assert_in_delta Enum.sum(r), 600.0 - 5 * 4.0, 1.0e-3
  end

  test "solves a :unbroken plan with one reservation" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 20,
      sec_per_burpee: 12.0,
      pacing_style: :unbroken,
      reps_per_set: 5,
      additional_rests: [%{rest_sec: 60, target_min: 10}]
    }

    model = SlotModel.new(input, 5)
    problem = Lp.build(model)

    assert {:ok, %{r: r}} = Highs.solve(problem)
    # target_duration_sec(1200) - work(20*12=240) = 960
    assert_in_delta Enum.sum(r), 960.0, 1.0e-2
  end

  test "returns :infeasible for an unsatisfiable problem" do
    input = %PlanInput{
      name: "t",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 10,
      sec_per_burpee: 12.0,
      pacing_style: :even,
      additional_rests: [%{rest_sec: 60, target_min: 0.001}]
    }

    model = SlotModel.new(input, nil)
    problem = Lp.build(model)

    assert {:error, :infeasible} = Highs.solve(problem)
  end
end
