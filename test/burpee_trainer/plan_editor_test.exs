defmodule BurpeeTrainer.PlanEditorTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanEditor.Input
  alias BurpeeTrainer.PlanSolver

  test "default_input returns typed new-workout defaults" do
    input = PlanEditor.default_input()

    assert %Input{} = input
    assert input.name == "New workout"
    assert input.burpee_type == :six_count
    assert input.target_duration_min == 20
    assert input.burpee_count_target == 100
    assert input.pacing_style == :even
    assert input.reps_per_set == PlanSolver.default_reps_per_set(:six_count)
    assert input.additional_rests == []
    assert input.sec_per_burpee_override == nil
    assert input.block_pattern == nil
  end

  describe "PlanEditor.Input boundary" do
    test "default/0 returns typed defaults" do
      assert %Input{} = input = Input.default()
      assert input.name == "New workout"
      assert input.burpee_type == :six_count
      assert input.target_duration_min == 20
      assert input.burpee_count_target == 100
      assert input.pacing_style == :even
    end

    test "apply_coach_params/2 accepts positive count and pace" do
      input =
        Input.default()
        |> Input.apply_coach_params(%{"count" => "75", "pace" => "2.5"})

      assert input.burpee_count_target == 75
      assert input.sec_per_burpee_override == 2.5
    end

    test "apply_coach_params/2 ignores invalid values" do
      input =
        Input.default()
        |> Input.apply_coach_params(%{"count" => "0", "pace" => "bad"})

      assert input.burpee_count_target == 100
      assert input.sec_per_burpee_override == nil
    end

    test "change_basics/2 updates positive numeric fields and name" do
      {:ok, input} =
        Input.default()
        |> Input.change_basics(%{
          "name" => "Changed",
          "target_duration_min" => "25",
          "burpee_count_target" => "120",
          "reps_per_set" => "10"
        })

      assert input.name == "Changed"
      assert input.target_duration_min == 25
      assert input.burpee_count_target == 120
      assert input.reps_per_set == 10
    end

    test "change_basics/2 preserves existing numbers for invalid partial input" do
      {:ok, input} =
        Input.default()
        |> Input.change_basics(%{
          "name" => "Changed",
          "target_duration_min" => "bad",
          "burpee_count_target" => "0",
          "reps_per_set" => ""
        })

      assert input.name == "Changed"
      assert input.target_duration_min == 20
      assert input.burpee_count_target == 100
      assert input.reps_per_set == PlanSolver.default_reps_per_set(:six_count)
    end

    test "change_block_pattern/2 normalizes sorted positive pattern values" do
      {:ok, input} =
        Input.default()
        |> Input.change_block_pattern(%{"pattern" => %{"1" => "7", "0" => "5", "2" => "bad"}})

      assert input.block_pattern == [5, 7]
    end

    test "set_pace_override/2 stores positive numeric pace" do
      {:ok, input} = Input.set_pace_override(Input.default(), "2.5")
      assert input.sec_per_burpee_override == 2.5

      {:ok, input} = Input.set_pace_override(input, 3)
      assert input.sec_per_burpee_override == 3.0
    end

    test "set_pace_override/2 clears invalid or empty pace" do
      {:ok, input} = Input.set_pace_override(Input.default(), "2.5")
      {:ok, input} = Input.set_pace_override(input, "")
      assert input.sec_per_burpee_override == nil

      {:ok, input} = Input.set_pace_override(%{input | sec_per_burpee_override: 2.5}, "bad")
      assert input.sec_per_burpee_override == nil
    end

    test "parse_non_negative_index/1 returns tagged errors" do
      assert {:ok, 0} = Input.parse_non_negative_index("0")
      assert {:ok, 3} = Input.parse_non_negative_index(3)
      assert {:error, {:invalid_index, "bad"}} = Input.parse_non_negative_index("bad")
      assert {:error, {:invalid_index, -1}} = Input.parse_non_negative_index(-1)
    end

    test "change_rest/2 updates rest by parsed index" do
      input = %{Input.default() | additional_rests: [%{rest_sec: 30, target_min: 10}]}

      {:ok, input} =
        Input.change_rest(input, %{
          "index" => "0",
          "target_min" => "12",
          "rest_sec" => "90"
        })

      assert input.additional_rests == [%{target_min: 12, rest_sec: 90}]
    end

    test "change_rest/2 preserves existing rest values for invalid partial input" do
      input = %{Input.default() | additional_rests: [%{rest_sec: 30, target_min: 10}]}

      {:ok, input} =
        Input.change_rest(input, %{
          "index" => "0",
          "target_min" => "bad",
          "rest_sec" => ""
        })

      assert input.additional_rests == [%{target_min: 10, rest_sec: 30}]
    end

    test "from_plan/1 converts a persisted workout plan into typed input" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "Persisted", "burpee_count_target" => 42})

      input = Input.from_plan(plan)

      assert %Input{} = input
      assert input.name == "Persisted"
      assert input.burpee_count_target == 42
      assert input.burpee_type == plan.burpee_type
      assert input.target_duration_min == (plan.target_duration_min || 20)
    end
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

    assert %Input{} = input
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

  describe "regeneration and derived state" do
    test "regenerate creates a solver solution and derived summary" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.regenerate(state)

      assert state.solver_error == nil
      assert state.solver_solution != nil
      assert state.derived.summary != nil
      assert state.derived.can_save? in [true, false]
    end

    test "change_basics updates input then regenerates" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} =
        PlanEditor.change_basics(state, %{
          "name" => "Changed",
          "target_duration_min" => "25",
          "burpee_count_target" => "120",
          "reps_per_set" => "10"
        })

      assert state.input.name == "Changed"
      assert state.input.target_duration_min == 25
      assert state.input.burpee_count_target == 120
      assert state.input.reps_per_set == 10
      assert state.solver_solution != nil
    end
  end

  describe "block locks" do
    test "lock_block/2 marks a block index as locked" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      {:ok, state} = PlanEditor.lock_block(state, "0")

      assert MapSet.member?(state.locked_block_indexes, 0)
      assert state.manual_edit?
    end

    test "rebalance_unlocked_blocks/1 preserves locked block positions" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      locked_block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
      edited_block = %{locked_block | sets: [%{hd(locked_block.sets) | burpee_count: 17}]}
      form_plan = %{state.form_plan | blocks: [edited_block]}

      state = %{
        state
        | form_plan: form_plan,
          locked_block_indexes: MapSet.new([0]),
          manual_edit?: true
      }

      {:ok, rebalanced} = PlanEditor.rebalance_unlocked_blocks(state)
      [first_block | _] = Enum.sort_by(rebalanced.form_plan.blocks, & &1.position)

      assert hd(first_block.sets).burpee_count == 17
      assert MapSet.member?(rebalanced.locked_block_indexes, 0)
    end
  end

  describe "manual edit transitions" do
    test "enable_manual_edit marks state manual" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.enable_manual_edit(state)

      assert state.manual_edit? == true
    end

    test "copy_block returns manual state with another block" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)
      block_count = length(state.form_plan.blocks)

      {:ok, state} = PlanEditor.copy_block(state, "0")

      assert state.manual_edit? == true
      assert length(state.form_plan.blocks) == block_count + 1
    end

    test "copy_set returns manual state with another set" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)
      [first_block | _] = Enum.sort_by(state.form_plan.blocks, & &1.position)
      set_count = length(first_block.sets)

      {:ok, state} = PlanEditor.copy_set(state, "0", "0")
      [first_block | _] = Enum.sort_by(state.form_plan.blocks, & &1.position)

      assert state.manual_edit? == true
      assert length(first_block.sets) == set_count + 1
    end
  end

  describe "state initialization" do
    test "new/2 builds default editor state" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      assert %PlanEditor.State{} = state
      assert state.plan == nil
      assert state.level == :level_1a
      assert state.input.name == "New workout"
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
