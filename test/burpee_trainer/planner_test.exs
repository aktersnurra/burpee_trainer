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
      warmup_enabled: false,
      warmup_reps: nil,
      warmup_rounds: nil,
      rest_sec_warmup_between: 120,
      rest_sec_warmup_before_main: 180,
      shave_off_sec: nil,
      shave_off_block_count: nil,
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
  end

  describe "to_timeline/1 — repeat_count > 1" do
    test "repeat_count=3 emits the block's sets three times labelled with the block" do
      plan = build_plan([build_block(1, 3, [build_set(1, 4, 4.0, 36)])])

      events = Planner.to_timeline(plan)

      # 3 work + 3 rest = 6 events
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

  describe "to_timeline/1 — warmup" do
    test "warmup disabled emits no warmup events" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 5, 4.0, 0)])],
          %{warmup_enabled: false, warmup_reps: 3, warmup_rounds: 2}
        )

      events = Planner.to_timeline(plan)
      refute Enum.any?(events, &(&1.type in [:warmup_burpee, :warmup_rest]))
    end

    test "warmup enabled emits rounds at first set pace with inter-round and final rests" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 5, 5.0, 0)])],
          %{
            warmup_enabled: true,
            warmup_reps: 3,
            warmup_rounds: 2,
            rest_sec_warmup_between: 90,
            rest_sec_warmup_before_main: 180
          }
        )

      assert [
               %Event{
                 type: :warmup_burpee,
                 burpee_count: 3,
                 duration_sec: 15.0,
                 label: "Warmup Round 1"
               },
               %Event{type: :warmup_rest, duration_sec: 90.0},
               %Event{
                 type: :warmup_burpee,
                 burpee_count: 3,
                 duration_sec: 15.0,
                 label: "Warmup Round 2"
               },
               %Event{type: :warmup_rest, duration_sec: 180.0},
               %Event{type: :work_burpee, label: "Block 1"}
             ] = Planner.to_timeline(plan)
    end

    test "warmup with zero reps or zero rounds emits nothing" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 5, 4.0, 0)])],
          %{warmup_enabled: true, warmup_reps: 0, warmup_rounds: 3}
        )

      events = Planner.to_timeline(plan)
      refute Enum.any?(events, &(&1.type in [:warmup_burpee, :warmup_rest]))
    end
  end

  describe "to_timeline/1 — shave-off" do
    test "injects shave_rest after the Nth block with duration = shave_off_sec × total repetitions" do
      # From SPEC example:
      #   Block(repeat_count=3): [ Set(burpee_count=4, sec_per_rep=4.0, end_of_set_rest=36) ]
      #   Block(repeat_count=1): [ Set(burpee_count=3, sec_per_rep=4.0, end_of_set_rest=0)  ]
      #   shave_off_sec=8, shave_off_block_count=1
      #   expected shave_rest duration = 8 × 3 = 24s
      plan =
        build_plan(
          [
            build_block(1, 3, [build_set(1, 4, 4.0, 36)]),
            build_block(2, 1, [build_set(1, 3, 4.0, 0)])
          ],
          %{shave_off_sec: 8, shave_off_block_count: 1}
        )

      events = Planner.to_timeline(plan)
      shave = Enum.find(events, &(&1.type == :shave_rest))

      assert %Event{duration_sec: 24.0, label: "Shave-off Rest"} = shave
    end

    test "shave_rest is positioned between block N and block N+1" do
      plan =
        build_plan(
          [
            build_block(1, 2, [build_set(1, 4, 4.0, 30)]),
            build_block(2, 1, [build_set(1, 3, 4.0, 0)])
          ],
          %{shave_off_sec: 5, shave_off_block_count: 1}
        )

      types = Planner.to_timeline(plan) |> Enum.map(& &1.type)

      # block 1 rep 1: work, rest
      # block 1 rep 2: work, rest
      # shave_rest
      # block 2: work
      assert types == [
               :work_burpee,
               :work_rest,
               :work_burpee,
               :work_rest,
               :shave_rest,
               :work_burpee
             ]
    end

    test "shave_off disabled (nil) emits no shave_rest" do
      plan =
        build_plan([
          build_block(1, 2, [build_set(1, 4, 4.0, 30)]),
          build_block(2, 1, [build_set(1, 3, 4.0, 0)])
        ])

      refute Enum.any?(Planner.to_timeline(plan), &(&1.type == :shave_rest))
    end

    test "shave_off_sec = 0 emits no shave_rest" do
      plan =
        build_plan(
          [
            build_block(1, 2, [build_set(1, 4, 4.0, 30)]),
            build_block(2, 1, [build_set(1, 3, 4.0, 0)])
          ],
          %{shave_off_sec: 0, shave_off_block_count: 1}
        )

      refute Enum.any?(Planner.to_timeline(plan), &(&1.type == :shave_rest))
    end
  end

  describe "to_timeline/1 — edge cases" do
    test "empty blocks list returns empty timeline (even with warmup enabled)" do
      plan =
        build_plan(
          [],
          %{warmup_enabled: true, warmup_reps: 3, warmup_rounds: 2}
        )

      assert Planner.to_timeline(plan) == []
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
      # two blocks with adjustable rest = 30s each (appears once per occurrence)
      # work = 2 * (5 * 4.0) = 40s. one adjustable rest contributes 30s. last set rest = 0.
      # current total = 40 + 30 = 70s. target = 100s → need +30s of rest.
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 5, 4.0, 30)]),
          build_block(2, 1, [build_set(1, 5, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 100)
      assert Planner.summary(fitted).duration_sec_total == 100.0

      # the adjustable rest should now be 60s
      [fitted_block_one | _] = fitted.blocks
      [fitted_set | _] = fitted_block_one.sets
      assert fitted_set.end_of_set_rest == 60
    end

    test "scales existing rests proportionally to hit a shorter target" do
      # current total = 40 + 60 = 100. target = 80 → new rest should scale to (60 * 40/60) ≈ 40
      # wait, let me recompute: current_adjustable_rest = 60, delta = -20.
      # scale = (60 - 20) / 60 = 2/3. new rest = 60 * 2/3 = 40.
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
      # block 1: repeat=3, 1 set, rest=30 → contributes 3 * 30 = 90s total from that rest
      # block 2: repeat=1, 1 set, rest=0 → last set
      # work = 3 * (4*4.0) + 1 * (3*4.0) = 48 + 12 = 60s
      # current total = 60 + 90 = 150. target = 180 → delta = +30 on adjustable total of 90.
      # scale = 120/90 = 4/3. new rest = 30 * 4/3 = 40.
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
      # block 1: repeat=2, 1 set → that set's rest occurs 2 times → 2 adjustable slots
      # block 2: 1 set = final set of final block → NOT adjustable
      # work = 2*(4*4.0) + 1*(4*4.0) = 48s. target = 78 → +30s total rest.
      # 2 slots, 30/2 = 15s each → rest = 15 on the block-1 set.
      plan =
        build_plan([
          build_block(1, 2, [build_set(1, 4, 4.0, 0)]),
          build_block(2, 1, [build_set(1, 4, 4.0, 0)])
        ])

      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, 78)

      [block_one, block_two] = fitted.blocks
      assert hd(block_one.sets).end_of_set_rest == 15
      # block 2's only set is the final set of the final block → rest stays 0
      assert hd(block_two.sets).end_of_set_rest == 0
      assert Planner.summary(fitted).duration_sec_total == 78.0
    end

    test "returns {:error, :no_adjustable_sets} when the plan has only the final set of the final block" do
      plan = build_plan([build_block(1, 1, [build_set(1, 5, 4.0, 0)])])
      assert {:error, :no_adjustable_sets} = Planner.fit_rest_to_duration(plan, 100)
    end

    test "returns {:error, :target_too_short} when target is below irreducible duration" do
      # work = 100s irreducible. adjustable rest = 20s. target below 100s is impossible.
      plan =
        build_plan([
          build_block(1, 1, [build_set(1, 25, 4.0, 20)]),
          build_block(2, 1, [build_set(1, 0, 4.0, 0)])
        ])

      assert {:error, :target_too_short} = Planner.fit_rest_to_duration(plan, 50)
    end

    test "does not modify warmup rests or shave-off rest" do
      plan =
        build_plan(
          [
            build_block(1, 1, [build_set(1, 4, 4.0, 20)]),
            build_block(2, 1, [build_set(1, 4, 4.0, 0)])
          ],
          %{
            warmup_enabled: true,
            warmup_reps: 3,
            warmup_rounds: 1,
            rest_sec_warmup_before_main: 60,
            shave_off_sec: 5,
            shave_off_block_count: 1
          }
        )

      current_total = Planner.summary(plan).duration_sec_total
      assert {:ok, fitted} = Planner.fit_rest_to_duration(plan, current_total + 40)

      assert fitted.rest_sec_warmup_before_main == 60
      assert fitted.shave_off_sec == 5
      assert fitted.warmup_reps == 3
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
    test "totals count main sets only; warmup is excluded from both burpees and duration" do
      plan =
        build_plan(
          [build_block(1, 1, [build_set(1, 10, 4.0, 0)])],
          %{
            warmup_enabled: true,
            warmup_reps: 5,
            warmup_rounds: 1,
            rest_sec_warmup_before_main: 60
          }
        )

      summary = Planner.summary(plan)

      # Only main work sets count: 10 * 4.0 = 40s. Warmup intentionally omitted.
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

      # Block 1 × 3: 4 reps × 1 set × 3 = 12 burpees, work = 4*4.0*3 = 48, rest = 36*3 = 108
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
