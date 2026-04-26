defmodule BurpeeTrainer.PlannerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Planner
  alias BurpeeTrainer.Planner.Event
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  defp build_set(position, burpee_count, sec_per_rep, end_of_set_rest) do
    %Set{
      position: position,
      burpee_count: burpee_count,
      sec_per_rep: sec_per_rep,
      sec_per_burpee: min(sec_per_rep, 3.0),
      end_of_set_rest: end_of_set_rest
    }
  end

  defp build_block(position, repeat_count, sets) do
    %Block{position: position, repeat_count: repeat_count, sets: sets}
  end

  defp build_plan(blocks, overrides \\ %{}) do
    base = %WorkoutPlan{
      name: "Test Plan",
      burpee_type: :six_count,
      target_duration_min: nil,
      burpee_count_target: nil,
      sec_per_burpee: nil,
      pacing_style: nil,
      additional_rests: "[]",
      blocks: blocks
    }

    struct!(base, overrides)
  end

  describe "to_timeline/1 — basic expansion" do
    test "single block with one set emits one work event and no rest when rest is zero" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 0)])])

      assert [
               %Event{
                 type: :work_burpee,
                 duration_sec: 20.0,
                 burpee_count: 5,
                 label: "Block 1"
               }
             ] = Planner.to_timeline(plan)
    end

    test "single block with multiple sets preserves order and emits rests between" do
      plan =
        build_plan([
          build_block(1, 1, [
            build_set(1, 4, 4.0, 30),
            build_set(2, 3, 4.0, 0)
          ])
        ])

      events = Planner.to_timeline(plan)

      assert [
               %Event{type: :work_burpee, burpee_count: 4, label: "Block 1"},
               %Event{type: :work_rest, duration_sec: 30.0},
               %Event{type: :work_burpee, burpee_count: 3, label: "Block 1"}
             ] = events
    end

    test "multiple blocks emit in order with trailing rest as inter-block gap" do
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 4, 4.0, 60)]),
          build_block(2, 1, [build_set(1, 3, 4.0, 0)])
        ])

      assert [
               %Event{type: :work_burpee, burpee_count: 4, label: "Block 1"},
               %Event{type: :work_rest, duration_sec: 60.0},
               %Event{type: :work_burpee, burpee_count: 3, label: "Block 2"}
             ] = Planner.to_timeline(plan)
    end

    test "blocks and sets are sorted by position regardless of input order" do
      plan =
        build_plan([
          build_block(2, 1, [build_set(1, 3, 4.0, 0)]),
          build_block(1, 1, [
            build_set(2, 2, 4.0, 0),
            build_set(1, 4, 4.0, 10)
          ])
        ])

      [first, _rest, third, fourth] = Planner.to_timeline(plan)
      assert first.label == "Block 1"
      assert first.burpee_count == 4
      assert third.label == "Block 1"
      assert third.burpee_count == 2
      assert fourth.label == "Block 2"
    end

    test "to_timeline/1 never emits warmup events" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 0)])])
      events = Planner.to_timeline(plan)
      refute Enum.any?(events, &(&1.type in [:warmup_burpee, :warmup_rest]))
    end
  end

  describe "to_timeline/1 — repeat_count > 1" do
    test "repeat_count=3 emits the block's sets three times labelled with the block" do
      plan = build_plan([build_block(1, 3, [build_set(1, 4, 4.0, 36)])])

      events = Planner.to_timeline(plan)

      assert length(events) == 6

      labels = for %Event{type: :work_burpee, label: l} <- events, do: l
      assert labels == ["Block 1", "Block 1", "Block 1"]
    end

    test "repeat_count=0 emits no events for that block" do
      plan =
        build_plan([
          build_block(1, 0, [build_set(1, 4, 4.0, 10)]),
          build_block(2, 1, [build_set(1, 3, 4.0, 0)])
        ])

      assert [%Event{label: "Block 2"}] = Planner.to_timeline(plan)
    end
  end

  describe "to_timeline/1 — edge cases" do
    test "empty blocks list returns empty timeline" do
      assert Planner.to_timeline(build_plan([])) == []
    end
  end

  describe "to_timeline/1 — sec_per_burpee field" do
    test "work_burpee events have sec_per_burpee set" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 0)])])
      [event] = Planner.to_timeline(plan)
      assert event.sec_per_burpee == 4.0
    end

    test "work_rest events have sec_per_burpee nil" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 30), build_set(2, 5, 4.0, 0)])])
      events = Planner.to_timeline(plan)
      rest = Enum.find(events, &(&1.type == :work_rest))
      assert rest.sec_per_burpee == nil
    end
  end

  describe "warmup_timeline/1" do
    test "returns empty list when plan has no blocks" do
      assert Planner.warmup_timeline(build_plan([])) == []
    end

    test "returns two warmup rounds with rests" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 10, 5.0, 0)])],
          %{sec_per_burpee: 5.0}
        )

      events = Planner.warmup_timeline(plan)
      types = Enum.map(events, & &1.type)
      assert types == [:warmup_burpee, :warmup_rest, :warmup_burpee, :warmup_rest]
    end

    test "warmup_burpee events have sec_per_burpee set, rest events have nil" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 10, 5.0, 0)])],
          %{sec_per_burpee: 5.0}
        )

      events = Planner.warmup_timeline(plan)
      work_events = Enum.filter(events, &(&1.type == :warmup_burpee))
      rest_events = Enum.filter(events, &(&1.type == :warmup_rest))

      assert Enum.all?(work_events, &(&1.sec_per_burpee == 5.0))
      assert Enum.all?(rest_events, &(&1.sec_per_burpee == nil))
    end

    test "inter-round rest is 120s and final rest is 180s" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 10, 5.0, 0)])],
          %{sec_per_burpee: 5.0}
        )

      [_, rest1, _, rest2] = Planner.warmup_timeline(plan)
      assert rest1.duration_sec == 120.0
      assert rest2.duration_sec == 180.0
    end

    test "warmup reps capped at first set burpee_count" do
      # 10 reps in set but pace allows 60/5=12 per min → capped at 10
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 10, 5.0, 0)])],
          %{sec_per_burpee: 5.0}
        )

      [round1 | _] = Planner.warmup_timeline(plan)
      assert round1.burpee_count == 10
    end

    test "warmup reps capped at reps achievable in 1 min" do
      # first set has 100 reps but pace is 10s/rep → 6 per min
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 100, 10.0, 0)])],
          %{sec_per_burpee: 10.0}
        )

      [round1 | _] = Planner.warmup_timeline(plan)
      assert round1.burpee_count == 6
    end
  end

  describe "fit_rest_to_duration/2" do
    test "target equal to current total returns the plan unchanged" do
      plan =
        build_plan([
          build_block(1, 1, [
            build_set(1, 5, 4.0, 30),
            build_set(2, 5, 4.0, 0)
          ])
        ])

      current_total = Planner.summary(plan).duration_sec_total
      assert {:ok, ^plan} = Planner.fit_rest_to_duration(plan, current_total)
    end

    test "scales existing rests proportionally to hit a longer target" do
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 5, 4.0, 30)]),
          build_block(2, 1, [build_set(1, 5, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 100)
      assert Planner.summary(fitted).duration_sec_total == 100.0

      [fitted_block_one | _] = fitted.blocks
      [fitted_set | _] = fitted_block_one.sets
      assert fitted_set.end_of_set_rest == 60
    end

    test "scales existing rests proportionally to hit a shorter target" do
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 5, 4.0, 60)]),
          build_block(2, 1, [build_set(1, 5, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 80)

      [block_one | _] = fitted.blocks
      [adjustable_set | _] = block_one.sets
      assert adjustable_set.end_of_set_rest == 40
      assert Planner.summary(fitted).duration_sec_total == 80.0
    end

    test "repeat_count weights the adjustable rest's contribution" do
      plan =
        build_plan([
          build_block(1, 3, [build_set(1, 4, 4.0, 30)]),
          build_block(2, 1, [build_set(1, 3, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 180)

      [block_one | _] = fitted.blocks
      [adjustable_set | _] = block_one.sets
      assert adjustable_set.end_of_set_rest == 40
      assert Planner.summary(fitted).duration_sec_total == 180.0
    end

    test "distributes evenly when all adjustable rests are zero" do
      plan =
        build_plan([
          build_block(1, 2, [build_set(1, 4, 4.0, 0)]),
          build_block(2, 1, [build_set(1, 4, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 78)

      [block_one, block_two] = fitted.blocks
      assert hd(block_one.sets).end_of_set_rest == 15
      assert hd(block_two.sets).end_of_set_rest == 0
      assert Planner.summary(fitted).duration_sec_total == 78.0
    end

    test "returns {:error, :no_adjustable_sets} when the plan has only the final set of the final block" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 0)])])
      assert {:error, :no_adjustable_sets} = Planner.fit_rest_to_duration(plan, 100)
    end

    test "returns {:error, :target_too_short} when target is below irreducible duration" do
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 25, 4.0, 20)]),
          build_block(2, 1, [build_set(1, 0, 4.0, 0)])
        ])

      assert {:error, :target_too_short} = Planner.fit_rest_to_duration(plan, 50)
    end

    test "final set of the final block retains its zero rest" do
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 4, 4.0, 30)]),
          build_block(2, 1, [
            build_set(1, 4, 4.0, 30),
            build_set(2, 4, 4.0, 0)
          ])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 200)

      last_block = List.last(fitted.blocks)
      last_set = List.last(last_block.sets)
      assert last_set.end_of_set_rest == 0
    end
  end

  describe "summary/1" do
    test "totals work burpees only from main blocks" do
      plan = build_plan([build_block(1, 1, [build_set(1, 10, 4.0, 0)])])
      summary = Planner.summary(plan)
      assert summary.burpee_count_total == 10
      assert summary.duration_sec_total == 40.0
    end

    test "per-block summary multiplies by repeat_count" do
      plan =
        build_plan([
          build_block(1, 3, [build_set(1, 4, 4.0, 36)]),
          build_block(2, 1, [build_set(1, 3, 4.0, 0)])
        ])

      summary = Planner.summary(plan)

      assert [block_one, block_two] = summary.blocks

      assert block_one.position == 1
      assert block_one.repeat_count == 3
      assert block_one.burpee_count_total == 12
      assert block_one.duration_sec_work == 48.0
      assert block_one.duration_sec_rest == 108

      assert block_two.position == 2
      assert block_two.burpee_count_total == 3
      assert block_two.duration_sec_work == 12.0
      assert block_two.duration_sec_rest == 0
    end

    test "empty plan summary has zero totals and empty block list" do
      assert Planner.summary(build_plan([])) == %{
               burpee_count_total: 0,
               duration_sec_total: 0.0,
               blocks: []
             }
    end
  end
end
