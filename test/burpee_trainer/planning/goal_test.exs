defmodule BurpeeTrainer.Planning.GoalTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.Goal

  describe "new/1" do
    test "requires duration, reps, burpee type, and style" do
      assert {:error, errors} = Goal.new(%{})

      assert {:duration_sec, :required} in errors
      assert {:target_reps, :required} in errors
      assert {:burpee_type, :required} in errors
      assert {:style, :required} in errors
    end

    test "requires max reps per set for unbroken goals" do
      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 160,
                 burpee_type: :six_count,
                 style: :unbroken
               })

      assert {:max_reps_per_set, :required_for_unbroken} in errors
    end

    test "builds an even goal with default two minute unit preference" do
      assert {:ok, goal} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even
               })

      assert goal.duration_sec == 1200
      assert goal.target_reps == 150
      assert goal.burpee_type == :six_count
      assert goal.style == :even
      assert goal.preferred_unit_sec == 120
      assert goal.max_reps_per_set == nil
      assert goal.requested_rest == nil
    end

    test "accepts a valid requested rest" do
      assert {:ok, goal} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 12 * 60, duration_sec: 45}
               })

      assert goal.requested_rest == %{target_sec: 12 * 60, duration_sec: 45}
    end

    test "rejects requested rest outside the workout window" do
      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 0, duration_sec: 45}
               })

      assert {:requested_rest, :outside_duration} in errors

      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 12 * 60, duration_sec: 20 * 60}
               })

      assert {:requested_rest, :outside_duration} in errors

      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 20 * 60, duration_sec: 45}
               })

      assert {:requested_rest, :outside_duration} in errors
    end

    test "rejects malformed requested rest" do
      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 0, duration_sec: -5}
               })

      assert {:requested_rest, :outside_duration} in errors
    end

    test "rejects requested rest with missing keys" do
      assert {:error, errors} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even,
                 requested_rest: %{target_sec: 12 * 60}
               })

      assert {:requested_rest, :invalid} in errors
    end

    test "builds an unbroken goal with max reps per set" do
      assert {:ok, goal} =
               Goal.new(%{
                 duration_sec: 20 * 60,
                 target_reps: 160,
                 burpee_type: :six_count,
                 style: :unbroken,
                 max_reps_per_set: 8
               })

      assert goal.style == :unbroken
      assert goal.max_reps_per_set == 8
    end
  end
end
