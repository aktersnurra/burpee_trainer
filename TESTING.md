## TESTING — PROPERTY-BASED TESTING (Antithesis-style)

Add property-based tests for the two pure modules using **StreamData** (ships with ExUnit,
no extra dep needed beyond `stream_data` in mix.exs).

The philosophy: don't test examples, test invariants. Generate thousands of random inputs
and assert properties that must hold for ALL valid inputs. This is the Antithesis approach
applied at the module level.

---

### Generators (define in test/support/generators.ex)

Build composable generators bottom-up:

```elixir
def set_generator do
  gen all burpee_count    <- integer(1..20),
          sec_per_burpee  <- float(min: 2.0, max: 10.0),
          rest_sec_after_set <- integer(0..120) do
    %Set{
      position:          0,   # will be assigned by parent
      burpee_count:      burpee_count,
      sec_per_burpee:    sec_per_burpee,
      rest_sec_after_set: rest_sec_after_set
    }
  end
end

def block_generator do
  gen all sets         <- list_of(set_generator(), min_length: 1, max_length: 5),
          repeat_count <- integer(1..5) do
    sets_with_positions = Enum.with_index(sets, 1)
      |> Enum.map(fn {s, i} -> %{s | position: i} end)
    %Block{repeat_count: repeat_count, sets: sets_with_positions}
  end
end

def plan_generator do
  gen all blocks          <- list_of(block_generator(), min_length: 1, max_length: 6),
          burpee_type     <- member_of([:six_count, :navy_seal]),
          warmup_enabled  <- boolean(),
          warmup_reps     <- integer(1..15),
          warmup_rounds   <- integer(1..3),
          shave_off_sec   <- one_of([constant(nil), integer(1..15)]),
          shave_off_block_count <- one_of([constant(nil), integer(1..3)]) do
    blocks_with_positions = Enum.with_index(blocks, 1)
      |> Enum.map(fn {b, i} -> %{b | position: i} end)
    %WorkoutPlan{
      burpee_type:               burpee_type,
      warmup_enabled:            warmup_enabled,
      warmup_reps:               warmup_reps,
      warmup_rounds:             warmup_rounds,
      rest_sec_warmup_between:   120,
      rest_sec_warmup_before_main: 180,
      shave_off_sec:             shave_off_sec,
      shave_off_block_count:     shave_off_block_count,
      blocks:                    blocks_with_positions
    }
  end
end

def session_generator(burpee_type) do
  gen all burpee_count_actual  <- integer(1..300),
          duration_sec_actual  <- integer(60..3600),
          days_ago             <- integer(0..180) do
    %WorkoutSession{
      burpee_type:          burpee_type,
      burpee_count_actual:  burpee_count_actual,
      duration_sec_actual:  duration_sec_actual,
      inserted_at:          DateTime.utc_now() |> DateTime.add(-days_ago * 86400)
    }
  end
end

def goal_generator do
  gen all burpee_type           <- member_of([:six_count, :navy_seal]),
          burpee_count_baseline <- integer(50..150),
          burpee_count_target   <- integer(151..300),
          duration_sec_target   <- integer(600..3600),
          weeks_ahead           <- integer(4..24) do
    %Goal{
      burpee_type:           burpee_type,
      burpee_count_baseline: burpee_count_baseline,
      burpee_count_target:   burpee_count_target,
      duration_sec_target:   duration_sec_target,
      duration_sec_baseline: duration_sec_target,  # same window
      date_baseline:         Date.utc_today(),
      date_target:           Date.utc_today() |> Date.add(weeks_ahead * 7),
      status:                :active
    }
  end
end
```

---

### Planner properties (test/burpee_trainer/planner_property_test.exs)

```elixir
property "timeline duration_sec_total equals sum of all event durations" do
  check all plan <- plan_generator() do
    timeline = Planner.to_timeline(plan)
    summary  = Planner.summary(plan)

    duration_sec_sum = Enum.reduce(timeline, 0.0, & &1.duration_sec + &2)
    assert_in_delta duration_sec_sum, summary.duration_sec_total, 0.001
  end
end

property "timeline burpee_count_total matches summary" do
  check all plan <- plan_generator() do
    timeline = Planner.to_timeline(plan)
    summary  = Planner.summary(plan)

    burpee_count_sum =
      timeline
      |> Enum.filter(& &1.type in [:work_burpee, :warmup_burpee])
      |> Enum.map(& &1.burpee_count)
      |> Enum.sum()

    assert burpee_count_sum == summary.burpee_count_total
  end
end

property "timeline is never empty for a valid plan" do
  check all plan <- plan_generator() do
    assert Planner.to_timeline(plan) != []
  end
end

property "all event durations are strictly positive" do
  check all plan <- plan_generator() do
    for event <- Planner.to_timeline(plan) do
      assert event.duration_sec > 0,
        "Got non-positive duration #{event.duration_sec} for event #{inspect(event)}"
    end
  end
end

property "shave_rest total equals shave_off_sec * repetitions" do
  check all plan <- plan_generator(),
            plan.shave_off_sec != nil,
            plan.shave_off_block_count != nil do
    timeline = Planner.to_timeline(plan)

    shave_events = Enum.filter(timeline, & &1.type == :shave_rest)

    # There is exactly one shave_rest event
    assert length(shave_events) == 1

    [shave_event] = shave_events

    expected_repetitions =
      plan.blocks
      |> Enum.take(plan.shave_off_block_count)
      |> Enum.sum(& &1.repeat_count)

    expected_duration_sec = plan.shave_off_sec * expected_repetitions

    assert_in_delta shave_event.duration_sec, expected_duration_sec, 0.001
  end
end

property "warmup events appear before all work events" do
  check all plan <- plan_generator(), plan.warmup_enabled do
    timeline = Planner.to_timeline(plan)

    warmup_indices = timeline
      |> Enum.with_index()
      |> Enum.filter(fn {e, _} -> e.type in [:warmup_burpee, :warmup_rest] end)
      |> Enum.map(fn {_, i} -> i end)

    work_indices = timeline
      |> Enum.with_index()
      |> Enum.filter(fn {e, _} -> e.type in [:work_burpee, :work_rest, :shave_rest] end)
      |> Enum.map(fn {_, i} -> i end)

    assert Enum.max(warmup_indices) < Enum.min(work_indices)
  end
end

property "timeline event labels are all non-empty strings" do
  check all plan <- plan_generator() do
    for event <- Planner.to_timeline(plan) do
      assert is_binary(event.label) and byte_size(event.label) > 0
    end
  end
end
```

---

### Progression properties (test/burpee_trainer/progression_property_test.exs)

```elixir
property "suggested reps are always positive" do
  check all goal     <- goal_generator(),
            sessions <- list_of(session_generator(goal.burpee_type), max_length: 20) do
    rec = Progression.recommend(goal, sessions)
    assert rec.burpee_count_suggested > 0
  end
end

property "suggested reps never exceed target by more than build_3 multiplier" do
  check all goal     <- goal_generator(),
            sessions <- list_of(session_generator(goal.burpee_type), max_length: 20) do
    rec = Progression.recommend(goal, sessions)
    # 1.05 is the maximum multiplier (build_3), add small epsilon for float rounding
    assert rec.burpee_count_suggested <= ceil(goal.burpee_count_target * 1.06)
  end
end

property "deload week suggested reps are less than build_2 week" do
  check all goal <- goal_generator() do
    # Force deload week (weeks_elapsed divisible by 4)
    deload_goal = %{goal | date_baseline: Date.add(goal.date_baseline, -28)}
    build_goal  = %{goal | date_baseline: Date.add(goal.date_baseline, -21)}

    rec_deload = Progression.recommend(deload_goal, [])
    rec_build  = Progression.recommend(build_goal,  [])

    assert rec_deload.burpee_count_suggested < rec_build.burpee_count_suggested
  end
end

property "sec_per_burpee_suggested is consistent with duration and count" do
  check all goal     <- goal_generator(),
            sessions <- list_of(session_generator(goal.burpee_type), max_length: 20) do
    rec = Progression.recommend(goal, sessions)

    derived_pace = rec.duration_sec_suggested / rec.burpee_count_suggested
    assert_in_delta rec.sec_per_burpee_suggested, derived_pace, 0.01
  end
end

property "project_trend returns dates in ascending order" do
  check all sessions <- list_of(session_generator(:six_count),
                                min_length: 2, max_length: 20) do
    projections = Progression.project_trend(sessions)
    dates = Enum.map(projections, fn {date, _} -> date end)
    assert dates == Enum.sort(dates, Date)
  end
end

property "trend_status is always a valid atom" do
  check all goal     <- goal_generator(),
            sessions <- list_of(session_generator(goal.burpee_type), max_length: 20) do
    rec = Progression.recommend(goal, sessions)
    assert rec.trend_status in [:ahead, :on_track, :behind, :low_consistency]
  end
end
```

---

### Session state machine (test/burpee_trainer_web/live/session_property_test.exs)

Generate random sequences of user actions and verify the state machine never enters
an invalid state. Use ConnCase + LiveViewTest:

```elixir
property "state machine reaches :done for any valid plan under any pause/resume sequence" do
  check all plan    <- plan_generator(),
            actions <- list_of(member_of([:tick, :pause, :resume]), max_length: 50) do

    # Insert plan, mount LiveView, drive it through generated actions
    # Assert: phase is always a valid state atom, never crashes
    # Assert: once :done is reached, no further ticks change state

    # Implementation: drive via send(view.pid, action) and assert_receive
  end
end
```

---

### Configuration

In mix.exs:
```elixir
{:stream_data, "~> 1.0", only: [:test, :dev]}
```

In test/test_helper.exs — increase default test case count for thoroughness:
```elixir
ExUnitProperties.max_runs(1000)
```

Or per-property:
```elixir
check all plan <- plan_generator(), max_runs: 2000 do
```

---

### Philosophy note for implementation

The goal of these tests is NOT to verify specific outputs for specific inputs.
The goal is to verify INVARIANTS that must hold for ALL inputs:
- Duration accounting is always exact (no lost seconds)
- Burpee counts always add up
- State machine never panics or gets stuck
- Derived values are always consistent with their sources

If a property fails, StreamData will shrink the failing case to the minimal
reproducing example automatically. Treat shrunk failures as the most valuable
output — they tell you exactly where your logic breaks.
