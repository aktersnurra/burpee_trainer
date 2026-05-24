defmodule BurpeeTrainer.PlanEditorTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanSolver

  test "default_input contains the new-plan defaults" do
    input = PlanEditor.default_input()

    assert input.name == "New plan"
    assert input.burpee_type == :six_count
    assert input.target_duration_min == 20
    assert input.burpee_count_target == 100
    assert input.pacing_style == :even
    assert input.reps_per_set == PlanSolver.default_reps_per_set(:six_count)
    assert input.additional_rests == []
    assert input.sec_per_burpee_override == nil
  end

  test "apply_coach_params accepts positive count and pace" do
    input =
      PlanEditor.default_input()
      |> PlanEditor.apply_coach_params(%{"count" => "75", "pace" => "2.5"})

    assert input.burpee_count_target == 75
    assert input.sec_per_burpee_override == 2.5
  end

  test "apply_coach_params ignores invalid values" do
    input =
      PlanEditor.default_input()
      |> PlanEditor.apply_coach_params(%{"count" => "0", "pace" => "bad"})

    assert input.burpee_count_target == 100
    assert input.sec_per_burpee_override == nil
  end

  test "input_from_plan preserves persisted plan choices" do
    user = user_fixture()
    plan = plan_fixture(user, %{"name" => "Persisted", "burpee_count_target" => 42})

    input = PlanEditor.input_from_plan(plan)

    assert input.name == "Persisted"
    assert input.burpee_count_target == 42
    assert input.burpee_type == plan.burpee_type
  end
end
