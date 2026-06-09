defmodule BurpeeTrainer.PlanningTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning
  alias BurpeeTrainer.Planning.{Goal}

  describe "solve/1" do
    test "accepts attrs and returns a verified draft" do
      assert {:ok, draft} =
               Planning.solve(%{
                 duration_sec: 20 * 60,
                 target_reps: 150,
                 burpee_type: :six_count,
                 style: :even
               })

      assert draft.status in [:good, :adjusted]
      assert draft.goal.style == :even
      assert draft.timeline != []
      assert :ok = BurpeeTrainer.Planning.DraftVerifier.verify(draft)
    end

    test "accepts a goal struct" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :unbroken,
          max_reps_per_set: 8
        })

      assert {:ok, draft} = Planning.solve(goal)
      assert draft.goal == goal
      assert draft.status == :good
    end
  end

  describe "build_plan/2" do
    test "solves and compiles a verified draft to a workout plan" do
      assert {:ok, plan} =
               Planning.build_plan(
                 %{
                   duration_sec: 20 * 60,
                   target_reps: 150,
                   burpee_type: :six_count,
                   style: :even
                 },
                 name: "Facade plan"
               )

      assert plan.name == "Facade plan"
      assert plan.burpee_type == :six_count
      assert plan.pacing_style == :even
      assert plan.blocks != []
      assert plan.steps != []
    end
  end
end
