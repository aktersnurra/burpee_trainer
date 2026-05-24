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

  describe "low-risk input transitions" do
    test "pick_type updates type and resets reps per set" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.pick_type(state, "navy_seal")

      assert state.input.burpee_type == :navy_seal
      assert state.input.reps_per_set == PlanSolver.default_reps_per_set(:navy_seal)
    end

    test "pick_type rejects invalid type without changing state" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      assert {:error, {:invalid_burpee_type, "bad"}, ^state} = PlanEditor.pick_type(state, "bad")
    end

    test "pick_pacing updates pacing style" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.pick_pacing(state, "unbroken")

      assert state.input.pacing_style == :unbroken
    end

    test "pick_pacing accepts atom pacing style" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.pick_pacing(state, :unbroken)

      assert state.input.pacing_style == :unbroken
    end

    test "pick_pacing rejects invalid style without changing state" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      assert {:error, {:invalid_pacing_style, "bad"}, ^state} =
               PlanEditor.pick_pacing(state, "bad")
    end

    test "set_pace_override accepts positive pace" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.set_pace_override(state, "2.5")
      assert state.input.sec_per_burpee_override == 2.5
    end

    test "set_pace_override clears pace for empty input" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.set_pace_override(state, "2.5")

      {:ok, state} = PlanEditor.set_pace_override(state, "")

      assert state.input.sec_per_burpee_override == nil
    end

    test "set_pace_override clears pace for invalid input" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.set_pace_override(state, "2.5")

      {:ok, state} = PlanEditor.set_pace_override(state, "bad")

      assert state.input.sec_per_burpee_override == nil
    end

    test "set_pace_override accepts positive number values" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.set_pace_override(state, 3)
      assert state.input.sec_per_burpee_override == 3.0

      {:ok, state} = PlanEditor.set_pace_override(state, 2.75)
      assert state.input.sec_per_burpee_override == 2.75
    end
  end

  describe "rest transitions" do
    test "add_rest appends a rest at the next evenly spaced target" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.add_rest(state)

      assert [%{target_min: 10, rest_sec: 30}] = state.input.additional_rests
    end

    test "remove_rest drops rest by index" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.add_rest(state)

      {:ok, state} = PlanEditor.remove_rest(state, "0")

      assert state.input.additional_rests == []
    end

    test "change_rest updates a rest by index" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.add_rest(state)

      {:ok, state} =
        PlanEditor.change_rest(state, %{
          "index" => "0",
          "target_min" => "12",
          "rest_sec" => "90"
        })

      assert [%{target_min: 12, rest_sec: 90}] = state.input.additional_rests
    end

    test "change_rest preserves existing values for invalid input" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.add_rest(state)

      {:ok, state} =
        PlanEditor.change_rest(state, %{
          "index" => "0",
          "target_min" => "bad",
          "rest_sec" => ""
        })

      assert [%{target_min: 10, rest_sec: 30}] = state.input.additional_rests
    end
  end

  describe "state initialization" do
    test "new/2 builds default editor state" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      assert %PlanEditor.State{} = state
      assert state.plan == nil
      assert state.level == :level_1a
      assert state.input.name == "New plan"
      assert state.input.burpee_type == :six_count
      assert state.manual_edit? == false
      assert state.expanded_blocks == MapSet.new()
      assert state.open_block_menu == nil
    end

    test "new/2 applies coach params" do
      {:ok, state} = PlanEditor.new(:level_1a, %{"count" => "75", "pace" => "2.5"})

      assert state.input.burpee_count_target == 75
      assert state.input.sec_per_burpee_override == 2.5
    end

    test "from_plan/2 builds edit state from persisted plan" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "Persisted", "burpee_count_target" => 42})

      {:ok, state} = PlanEditor.from_plan(plan, :level_2)

      assert state.plan.id == plan.id
      assert state.level == :level_2
      assert state.input.name == "Persisted"
      assert state.input.burpee_count_target == 42
    end
  end
end
