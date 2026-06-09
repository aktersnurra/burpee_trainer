defmodule BurpeeTrainer.Planning.DraftGeneratorTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planning.{Goal, StyleProfile}

  describe "StyleProfile.from_goal/1" do
    test "even style distributes rest between reps" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 150,
          burpee_type: :six_count,
          style: :even
        })

      profile = StyleProfile.from_goal(goal)

      assert profile.style == :even
      assert profile.rest_semantics == :between_reps
      assert profile.preferred_unit_sec == 120
    end

    test "unbroken style rests after sets" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :unbroken,
          max_reps_per_set: 8
        })

      profile = StyleProfile.from_goal(goal)

      assert profile.style == :unbroken
      assert profile.rest_semantics == :after_set
      assert profile.max_reps_per_set == 8
    end
  end

  describe "DraftGenerator.generate/1 for even pacing" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "150 reps in 20 minutes becomes two-minute units, not one giant set" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 150,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert draft.status == :good
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))
      assert length(draft.timeline) == 10
      assert Enum.all?(draft.timeline, &(&1.reps == 15))
      refute Enum.any?(draft.timeline, &(&1.reps == 150))
    end

    test "300 reps in 20 minutes stays legible and allows dense units" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 300,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert length(draft.timeline) == 10
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))
      assert Enum.all?(draft.timeline, &(&1.reps == 30))
      assert Enum.all?(draft.timeline, &(&1.rep_interval_sec == 4.0))
    end

    test "low target reps shrink the unit count so every unit has at least one rep" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 5,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert length(draft.timeline) == 5
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))
      assert Enum.all?(draft.timeline, &(&1.reps == 1))
      assert Enum.all?(draft.timeline, &(&1.duration_sec == 240))
    end

    test "short duration uses the full duration as one unit" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 90,
          target_reps: 10,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert length(draft.timeline) == 1
      assert [%TimelineItem.EvenUnit{} = unit] = draft.timeline
      assert unit.duration_sec == 90
      assert unit.reps == 10
      assert unit.rep_interval_sec == 9.0
    end
  end

  describe "DraftGenerator.generate/1 for unbroken pacing" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "160 reps with max 8 reps per set produces repeated unbroken groups" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :unbroken,
          max_reps_per_set: 8
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert draft.status == :good
      assert length(draft.timeline) == 20
      assert Enum.all?(draft.timeline, &match?(%TimelineItem.UnbrokenGroup{}, &1))
      assert Enum.all?(draft.timeline, &(&1.reps == 8))
      assert Enum.all?(draft.timeline, &(&1.rest_after_sec >= 0))
      refute Enum.any?(draft.timeline, &(&1.reps == 160))
    end
  end

  describe "DraftGenerator.generate/1 with strategic rest" do
    alias BurpeeTrainer.Planning.{DraftGenerator, TimelineItem}

    test "adds a funded standalone rest around 12 minutes without hidden gaps" do
      {:ok, goal} =
        Goal.new(%{
          duration_sec: 20 * 60,
          target_reps: 160,
          burpee_type: :six_count,
          style: :even,
          preferred_unit_sec: 120,
          requested_rest: %{target_sec: 12 * 60, duration_sec: 45}
        })

      assert {:ok, draft} = DraftGenerator.generate(goal)

      assert Enum.chunk_every(draft.timeline, 2, 1, :discard)
             |> Enum.all?(fn [left, right] ->
               right.start_sec == left.start_sec + timeline_item_duration(left)
             end)

      assert [%TimelineItem.StandaloneRest{start_sec: rest_start, duration_sec: 45} | _] =
               Enum.drop_while(draft.timeline, &match?(%TimelineItem.EvenUnit{}, &1))

      assert rest_start ==
               Enum.at(draft.timeline, 5).start_sec +
                 timeline_item_duration(Enum.at(draft.timeline, 5))

      assert draft.feedback.text == "Added 45s reset · earlier units tightened to fund it"
    end
  end

  defp timeline_item_duration(%BurpeeTrainer.Planning.TimelineItem.EvenUnit{
         duration_sec: duration_sec
       }),
       do: duration_sec

  defp timeline_item_duration(%BurpeeTrainer.Planning.TimelineItem.StandaloneRest{
         duration_sec: duration_sec
       }),
       do: duration_sec

  defp timeline_item_duration(%BurpeeTrainer.Planning.TimelineItem.UnbrokenGroup{
         reps: reps,
         burpee_duration_sec: burpee_duration_sec,
         rest_after_sec: rest_after_sec
       }),
       do: round(reps * burpee_duration_sec) + rest_after_sec
end
