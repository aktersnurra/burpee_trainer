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
    assert input.manual_structure? == false
    assert input.pace_bias == :balanced
    assert input.load_shape == :even
  end

  test "default contract generation does not impose a hidden block pattern" do
    {:ok, state} = PlanEditor.new(:level_1a, %{})
    {:ok, state} = PlanEditor.regenerate(state)

    total_reps =
      state.form_plan.blocks
      |> Enum.flat_map(fn block ->
        repeat_count = block.repeat_count || 1

        Enum.map(block.sets, fn set -> set.burpee_count * repeat_count end)
      end)
      |> Enum.sum()

    assert state.form_plan.burpee_count_target == 100
    assert total_reps == 100
  end

  describe "PlanEditor.Input boundary" do
    test "default/0 returns typed defaults" do
      assert %Input{} = input = Input.default()
      assert input.name == "New workout"
      assert input.burpee_type == :six_count
      assert input.target_duration_min == 20
      assert input.burpee_count_target == 100
      assert input.pacing_style == :even
      assert input.manual_structure? == false
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

    test "change_basics/2 preserves the existing name for blank input" do
      {:ok, input} =
        Input.default()
        |> Input.change_basics(%{"name" => "   "})

      assert input.name == "New workout"
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
      assert input.manual_structure? == true
    end

    test "change_block_pattern/2 ignores Phoenix unused nested input sentinels" do
      {:ok, input} =
        Input.default()
        |> Input.change_block_pattern(%{
          "pattern" => %{"_unused_0" => "", "0" => "4", "1" => "3"}
        })

      assert input.block_pattern == [4, 3]
      assert input.manual_structure? == true
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

    test "pace bias maps to solver movement pace" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.set_pace_bias(state, "faster")
      {:ok, state} = PlanEditor.regenerate(state)

      assert state.input.pace_bias == :faster
      assert state.solver_solution.metadata.pace_bias == :faster
      assert_in_delta state.solver_solution.sec_per_burpee, 4.8, 1.0e-6
    end

    test "pace bias clears manual pace override" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.set_pace_override(state, "12.5")

      assert state.input.sec_per_burpee_override == 12.5

      {:ok, state} = PlanEditor.set_pace_bias(state, "faster")

      assert state.input.pace_bias == :faster
      assert state.input.sec_per_burpee_override == nil
    end

    test "load shape is stored on solver metadata" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})

      {:ok, state} = PlanEditor.set_load_shape(state, "front_loaded")
      {:ok, state} = PlanEditor.regenerate(state)

      assert state.input.load_shape == :front_loaded
      assert state.solver_solution.metadata.load_shape == :front_loaded
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

    test "solver errors fail closed instead of keeping stale can-save state" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      assert state.derived.can_save?

      state = %{
        state
        | input: %{state.input | additional_rests: [%{target_min: 10, rest_sec: 30}]}
      }

      {:ok, state} = PlanEditor.regenerate(state)

      assert state.solver_error =~ "Explicit rest cannot be placed"
      refute state.derived.can_save?
    end

    test "change_basics name-only edit preserves existing workout structure" do
      user = user_fixture()

      plan =
        plan_fixture(user, %{
          "name" => "Custom plan",
          "target_duration_min" => 20,
          "burpee_count_target" => 10,
          "pacing_style" => "even",
          "blocks" => [
            %{
              "position" => 1,
              "repeat_count" => 1,
              "sets" => [
                %{
                  "position" => 1,
                  "burpee_count" => 10,
                  "sec_per_rep" => 7.5,
                  "sec_per_burpee" => 7.5,
                  "end_of_set_rest" => 45
                }
              ]
            }
          ]
        })

      {:ok, state} = PlanEditor.from_plan(plan, :level_1a)
      existing_blocks = state.form_plan.blocks
      existing_steps = state.form_plan.steps
      {:ok, state} = PlanEditor.change_basics(state, %{"name" => "Renamed"})

      assert state.input.name == "Renamed"
      assert state.form_plan.name == "Renamed"
      assert state.form_plan.blocks == existing_blocks
      assert state.form_plan.steps == existing_steps
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

    test "change_basics preserves locked block contents while regenerating" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      locked_block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
      edited_block = %{locked_block | sets: [%{hd(locked_block.sets) | burpee_count: 17}]}

      state = %{
        state
        | form_plan: %{state.form_plan | blocks: [edited_block]},
          locked_block_indexes: MapSet.new([0]),
          manual_edit?: true
      }

      {:ok, changed} =
        PlanEditor.change_basics(state, %{
          "target_duration_min" => "25",
          "burpee_count_target" => "120"
        })

      [first_block | _] = Enum.sort_by(changed.form_plan.blocks, & &1.position)

      assert hd(first_block.sets).burpee_count == 17
      assert MapSet.member?(changed.locked_block_indexes, 0)
      assert changed.manual_edit?
    end

    test "change_basics preserves locked block repeat count in matching steps" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      [locked_block | _] = Enum.sort_by(state.form_plan.blocks, & &1.position)
      edited_block = %{locked_block | repeat_count: 7}

      steps =
        Enum.map(state.form_plan.steps || [], fn
          %{kind: :block_run, block_position: position} = step
          when position == locked_block.position ->
            %{step | repeat_count: 7}

          step ->
            step
        end)

      state = %{
        state
        | form_plan: %{state.form_plan | blocks: [edited_block], steps: steps},
          locked_block_indexes: MapSet.new([0]),
          manual_edit?: true
      }

      {:ok, changed} =
        PlanEditor.change_basics(state, %{
          "target_duration_min" => "25",
          "burpee_count_target" => "120"
        })

      [first_block | _] = Enum.sort_by(changed.form_plan.blocks, & &1.position)
      [first_step | _] = Enum.sort_by(changed.form_plan.steps || [], & &1.position)

      assert first_block.repeat_count == 7
      assert first_step.repeat_count == 7

      assert BurpeeTrainer.Planner.summary(changed.form_plan).burpee_count_total ==
               hd(first_block.sets).burpee_count * 7
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

    test "copy_block clears copied ids and schedules the duplicate" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)

      form_plan =
        state.form_plan
        |> Map.update!(:blocks, fn blocks ->
          blocks
          |> Enum.with_index(1)
          |> Enum.map(fn {block, id} ->
            sets =
              block.sets
              |> Enum.with_index(1)
              |> Enum.map(fn {set, set_id} -> %{set | id: set_id, block_id: id} end)

            %{block | id: id, plan_id: 123, sets: sets}
          end)
        end)

      state = %{state | form_plan: form_plan}
      block_count = length(state.form_plan.blocks)
      step_count = length(state.form_plan.steps)

      {:ok, state} = PlanEditor.copy_block(state, "0")

      assert state.manual_edit? == true
      assert length(state.form_plan.blocks) == block_count + 1
      assert length(state.form_plan.steps) == step_count + 1

      copied_block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> List.last()
      copied_step = state.form_plan.steps |> Enum.sort_by(& &1.position) |> List.last()

      assert copied_block.id == nil
      assert copied_block.plan_id == nil
      assert Enum.all?(copied_block.sets, &is_nil(&1.id))
      assert copied_step.kind == :block_run
      assert copied_step.block_position == copied_block.position
      assert copied_step.repeat_count == 1
    end

    test "change_basics preserves unscheduled manual edits such as duplicated blocks" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)
      {:ok, state} = PlanEditor.copy_block(state, "0")
      block_count = length(state.form_plan.blocks)
      step_count = length(state.form_plan.steps)

      {:ok, state} = PlanEditor.change_basics(state, %{"target_duration_min" => "25"})

      assert length(state.form_plan.blocks) == block_count
      assert length(state.form_plan.steps) == step_count
      assert state.manual_edit?
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

  describe "delete_block" do
    # Builds a manual state with at least one block; extra blocks are added with
    # copy_block so deletes can be observed in the middle of the sequence.
    defp multi_block_state(block_count) when block_count >= 1 do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      {:ok, state} = PlanEditor.regenerate(state)
      state = single_block_state(state)

      Enum.reduce(2..block_count//1, state, fn _i, acc ->
        {:ok, acc} = PlanEditor.copy_block(acc, "0")
        acc
      end)
    end

    # Collapses a freshly generated plan down to one block + one block_run step
    # so block/step counts are predictable as copies are added.
    defp single_block_state(state) do
      [block | _] = Enum.sort_by(state.form_plan.blocks, & &1.position)
      block = %{block | position: 1}

      step = %BurpeeTrainer.Workouts.PlanStep{
        position: 1,
        kind: :block_run,
        block_position: 1,
        repeat_count: 1
      }

      %{state | form_plan: %{state.form_plan | blocks: [block], steps: [step]}}
    end

    defp block_positions(state),
      do: state.form_plan.blocks |> Enum.map(& &1.position) |> Enum.sort()

    defp step_positions(state),
      do: state.form_plan.steps |> Enum.map(& &1.position) |> Enum.sort()

    defp block_run_positions(state) do
      state.form_plan.steps
      |> Enum.filter(&(&1.kind == :block_run))
      |> Enum.map(& &1.block_position)
      |> Enum.sort()
    end

    test "deleting a middle block renumbers blocks and steps contiguously" do
      state = multi_block_state(3)
      assert block_positions(state) == [1, 2, 3]

      {:ok, deleted} = PlanEditor.delete_block(state, "1")

      assert deleted.manual_edit? == true
      assert length(deleted.form_plan.blocks) == 2
      assert block_positions(deleted) == [1, 2]
      assert step_positions(deleted) == [1, 2]
      # No block_run step may reference a missing block position.
      assert block_run_positions(deleted) == [1, 2]
    end

    test "deleting the only remaining block is rejected" do
      state = multi_block_state(1)
      assert length(state.form_plan.blocks) == 1

      assert {:error, :last_block, ^state} = PlanEditor.delete_block(state, "0")
    end

    test "locked block indexes shift to follow surviving blocks" do
      state = multi_block_state(3)
      # Lock the third block (index 2); deleting index 0 should leave it at 1.
      state = %{state | locked_block_indexes: MapSet.new([2])}

      {:ok, deleted} = PlanEditor.delete_block(state, "0")

      assert MapSet.member?(deleted.locked_block_indexes, 1)
      refute MapSet.member?(deleted.locked_block_indexes, 2)
    end

    test "locking the deleted block drops that lock" do
      state = multi_block_state(3)
      state = %{state | locked_block_indexes: MapSet.new([1])}

      {:ok, deleted} = PlanEditor.delete_block(state, "1")

      refute MapSet.member?(deleted.locked_block_indexes, 1)
    end

    test "missing form_plan returns an error tuple" do
      {:ok, state} = PlanEditor.new(:level_1a, %{})
      state = %{state | form_plan: nil}

      assert {:error, :missing_form_plan, ^state} = PlanEditor.delete_block(state, "0")
    end
  end

  describe "inline set editing" do
    defp reps(state, block_index) do
      block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> Enum.at(block_index)
      block.sets |> Enum.sort_by(& &1.position) |> Enum.map(& &1.burpee_count)
    end

    defp set_positions(state, block_index) do
      block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> Enum.at(block_index)
      block.sets |> Enum.map(& &1.position) |> Enum.sort()
    end

    test "add_set appends a set copying the last set's cadence" do
      state = multi_block_state(1)
      before = reps(state, 0)

      {:ok, added} = PlanEditor.add_set(state, "0")

      assert added.manual_edit? == true
      assert length(reps(added, 0)) == length(before) + 1
      assert set_positions(added, 0) == Enum.to_list(1..(length(before) + 1))
    end

    test "delete_set removes a set and renumbers positions" do
      state = multi_block_state(1)
      {:ok, state} = PlanEditor.add_set(state, "0")
      {:ok, state} = PlanEditor.add_set(state, "0")
      count = length(reps(state, 0))

      {:ok, deleted} = PlanEditor.delete_set(state, "0", "1")

      assert deleted.manual_edit? == true
      assert length(reps(deleted, 0)) == count - 1
      assert set_positions(deleted, 0) == Enum.to_list(1..(count - 1))
    end

    test "delete_set rejects removing the block's last set" do
      state = multi_block_state(1)
      # collapse block 0 to a single set
      block = state.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
      [one | _] = Enum.sort_by(block.sets, & &1.position)
      block = %{block | sets: [%{one | position: 1}]}
      state = %{state | form_plan: %{state.form_plan | blocks: [%{block | position: 1}]}}

      assert {:error, :last_set, ^state} = PlanEditor.delete_set(state, "0", "0")
    end

    test "update_set changes only the targeted field" do
      state = multi_block_state(1)
      {:ok, state} = PlanEditor.add_set(state, "0")

      {:ok, updated} = PlanEditor.update_set(state, "0", "1", %{"reps" => "12"})

      block = updated.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
      target = block.sets |> Enum.sort_by(& &1.position) |> Enum.at(1)
      assert target.burpee_count == 12
      assert updated.manual_edit? == true
    end

    test "update_set sets rest via the rest key" do
      state = multi_block_state(1)

      {:ok, updated} = PlanEditor.update_set(state, "0", "0", %{"rest" => "60"})

      block = updated.form_plan.blocks |> Enum.sort_by(& &1.position) |> hd()
      target = block.sets |> Enum.sort_by(& &1.position) |> hd()
      assert target.end_of_set_rest == 60
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
