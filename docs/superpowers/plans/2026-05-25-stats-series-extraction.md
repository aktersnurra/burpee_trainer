# Stats Series Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract chart data shaping from `StatsLive` into a pure `BurpeeTrainer.Stats.Series` module.

**Architecture:** Keep LiveView rendering and events in `StatsLive`; move only chart series/bounds calculations into a pure module with unit tests. This avoids a large HEEx rewrite while making chart logic testable.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit.

---

## Task 1: Introduce Stats.Series for Weekly Minutes

**Files:**

- Create: `lib/burpee_trainer/stats/series.ex`
- Create: `test/burpee_trainer/stats/series_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/burpee_trainer/stats/series_test.exs`:

```elixir
defmodule BurpeeTrainer.Stats.SeriesTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Stats.Series

  test "weekly_minutes returns empty model for no rows" do
    assert %{points: [], max_minutes: 0} = Series.weekly_minutes([])
  end

  test "weekly_minutes sorts rows and computes max" do
    rows = [
      %{week_start: ~D[2026-05-18], minutes: 25.0},
      %{week_start: ~D[2026-05-11], minutes: 40.0}
    ]

    model = Series.weekly_minutes(rows)

    assert Enum.map(model.points, & &1.week_start) == [~D[2026-05-11], ~D[2026-05-18]]
    assert model.max_minutes == 40.0
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
mix test test/burpee_trainer/stats/series_test.exs
```

Expected: FAIL because `BurpeeTrainer.Stats.Series` does not exist.

- [ ] **Step 3: Implement module**

Create `lib/burpee_trainer/stats/series.ex`:

```elixir
defmodule BurpeeTrainer.Stats.Series do
  @moduledoc """
  Pure chart data shaping for stats screens.
  """

  @type weekly_row :: %{week_start: Date.t(), minutes: number()}
  @type weekly_point :: %{week_start: Date.t(), minutes: number()}
  @type weekly_model :: %{points: [weekly_point()], max_minutes: number()}

  @spec weekly_minutes([weekly_row()]) :: weekly_model()
  def weekly_minutes(rows) do
    points = Enum.sort_by(rows, & &1.week_start, Date)
    max_minutes = points |> Enum.map(& &1.minutes) |> Enum.max(fn -> 0 end)

    %{points: points, max_minutes: max_minutes}
  end
end
```

- [ ] **Step 4: Run tests**

Run:

```bash
mix test test/burpee_trainer/stats/series_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(stats): extract weekly chart series"
jj new
```

## Task 2: Add Progress Series Model

**Files:**

- Modify: `lib/burpee_trainer/stats/series.ex`
- Modify: `test/burpee_trainer/stats/series_test.exs`

- [ ] **Step 1: Write failing progress tests**

Append tests:

```elixir
test "progress returns empty model for no sessions" do
  assert %{points: [], max_count: 0, min_pace: nil, max_pace: nil} = Series.progress([])
end

test "progress keeps chronological count and pace points" do
  sessions = [
    %{inserted_at: ~U[2026-05-20 10:00:00Z], burpee_count_actual: 30, duration_sec_actual: 90},
    %{inserted_at: ~U[2026-05-18 10:00:00Z], burpee_count_actual: 20, duration_sec_actual: 80}
  ]

  model = Series.progress(sessions)

  assert Enum.map(model.points, & &1.burpee_count) == [20, 30]
  assert Enum.map(model.points, & &1.sec_per_burpee) == [4.0, 3.0]
  assert model.max_count == 30
  assert model.min_pace == 3.0
  assert model.max_pace == 4.0
end
```

- [ ] **Step 2: Implement progress/1**

Add to `Stats.Series`:

```elixir
@type progress_session :: %{
        inserted_at: DateTime.t(),
        burpee_count_actual: pos_integer(),
        duration_sec_actual: pos_integer()
      }

@type progress_point :: %{
        inserted_at: DateTime.t(),
        burpee_count: non_neg_integer(),
        sec_per_burpee: float()
      }

@type progress_model :: %{
        points: [progress_point()],
        max_count: non_neg_integer(),
        min_pace: float() | nil,
        max_pace: float() | nil
      }

@spec progress([progress_session()]) :: progress_model()
def progress(sessions) do
  points =
    sessions
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.map(fn session ->
      count = session.burpee_count_actual || 0
      duration = session.duration_sec_actual || 0
      pace = if count > 0, do: duration / count, else: 0.0

      %{inserted_at: session.inserted_at, burpee_count: count, sec_per_burpee: pace}
    end)

  paces = Enum.map(points, & &1.sec_per_burpee)

  %{
    points: points,
    max_count: points |> Enum.map(& &1.burpee_count) |> Enum.max(fn -> 0 end),
    min_pace: if(paces == [], do: nil, else: Enum.min(paces)),
    max_pace: if(paces == [], do: nil, else: Enum.max(paces))
  }
end
```

- [ ] **Step 3: Run tests**

Run:

```bash
mix test test/burpee_trainer/stats/series_test.exs
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor(stats): extract progress chart series"
jj new
```

## Task 3: Adapt StatsLive to Use Series Module

**Files:**

- Modify: `lib/burpee_trainer_web/live/stats_live.ex`
- Modify: `test/burpee_trainer/stats/series_test.exs` if needed

- [ ] **Step 1: Add alias**

In `StatsLive`, add:

```elixir
alias BurpeeTrainer.Stats.Series
```

- [ ] **Step 2: Use weekly model where chart data is prepared**

Find the code path that assigns weekly minutes/chart data. Replace inline sorting/max calculations with:

```elixir
weekly_model = Series.weekly_minutes(weekly_minutes)
```

Keep assign names unchanged if templates depend on them.

- [ ] **Step 3: Use progress model where progress chart data is prepared**

Find the progress chart data preparation path. Replace inline chronological pace/count shaping with:

```elixir
progress_model = Series.progress(sessions)
```

Keep rendered output unchanged.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/stats/series_test.exs test/burpee_trainer_web/live/stats_live_test.exs
```

If the LiveView test file name differs, run:

```bash
mix test test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(stats): use series models in LiveView"
jj new
```

## Task 4: Final Verification and Push

- [ ] Run:

```bash
mix precommit
jj st
```

Expected: PASS and clean working copy.

- [ ] Push master if this work should ship immediately:

```bash
jj bookmark set master -r @-
jj git push -b master
```

## Self-Review

Spec coverage:

- Weekly minutes model: Task 1.
- Progress chart model: Task 2.
- Small StatsLive adapter: Task 3.
- Final verification: Task 4.

No placeholders remain. The plan intentionally keeps rendering and modal/event behavior in `StatsLive`.
