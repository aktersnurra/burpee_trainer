# Home Screen Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Home screen (streak card + 12-week grid + generic "Run a plan" button) with an action-first layout: a compact status strip, a specific suggested-workout card with a one-tap Start button, and a small "Log a session" link.

**Architecture:** Three changes to `OverviewLive`: (1) add two new data queries to `mount/2` — this-week trained days and the most-recently-run plan; (2) replace the render with the new layout: borderless status strip, dominant workout card, secondary log link; (3) move `calendar_card` component to Stats (it's the right home for historical data). No new routes needed — `/session/:plan_id` already exists.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto/SQLite, Tailwind CSS.

**Reference spec:** `PATCH_HOME_SCREEN.md`

---

## Data model notes

- `WorkoutSession` has `plan_id` (nullable), `inserted_at`, `tags` (warmup sessions have `tags = "warmup"`).
- `WorkoutPlan` has `name`, `burpee_type`, `burpee_count_target`, `target_duration_min`.
- `current_level` is already assigned by the auth on_mount hook — available as `@current_level` in every LiveView.
- `Workouts.weekly_minutes/1` already returns per-week data. Day-level data needs a new query.

---

## File structure

**Modify:**
- `lib/burpee_trainer/workouts.ex` — add `this_week_trained_days/1` and `last_run_plan/1`
- `lib/burpee_trainer_web/live/overview_live.ex` — full rewrite of mount + render; keep `compute_streak`, remove `build_calendar`

**No new files needed.**

---

## Task 1: Add `Workouts.this_week_trained_days/1`

Returns a `MapSet` of `Date.t()` for days this week (Mon–Sun) where the user completed at least one non-warmup session.

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Test: `test/burpee_trainer/workouts_test.exs`

- [ ] **Step 1: Write the failing test**

Open `test/burpee_trainer/workouts_test.exs`. Add inside the existing `describe` block or at the top level:

```elixir
describe "this_week_trained_days/1" do
  test "returns dates of non-warmup sessions in current week", %{user: user} do
    today = Date.utc_today()
    week_start = Date.beginning_of_week(today, :monday)

    # Session on Monday of this week
    monday = week_start
    insert_session(user, inserted_at: monday |> DateTime.new!(~T[10:00:00], "Etc/UTC"))

    # Warmup session — should NOT count
    insert_session(user,
      inserted_at: monday |> DateTime.new!(~T[09:00:00], "Etc/UTC"),
      tags: "warmup"
    )

    # Session from last week — should NOT count
    last_week = Date.add(week_start, -3)
    insert_session(user, inserted_at: last_week |> DateTime.new!(~T[10:00:00], "Etc/UTC"))

    days = Workouts.this_week_trained_days(user)

    assert MapSet.member?(days, monday)
    assert MapSet.size(days) == 1
  end

  test "returns empty MapSet when no sessions this week", %{user: user} do
    days = Workouts.this_week_trained_days(user)
    assert days == MapSet.new()
  end
end
```

Note: `insert_session/2` is a test helper — check what helpers already exist in the test file. If it doesn't exist, use `Workouts.create_session_from_plan/3` or direct `Repo.insert!` with a `WorkoutSession` struct. Look at existing test patterns in that file first.

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/workouts_test.exs --only describe:"this_week_trained_days/1" 2>&1 | tail -10
```

Expected: FAIL — `this_week_trained_days/1` undefined.

- [ ] **Step 3: Implement `this_week_trained_days/1`**

In `lib/burpee_trainer/workouts.ex`, add after `weekly_minutes/1`:

```elixir
@doc """
Returns a MapSet of dates (Mon–Sun of the current ISO week) on which the
user completed at least one non-warmup session.
"""
@spec this_week_trained_days(User.t()) :: MapSet.t()
def this_week_trained_days(%User{id: user_id}) do
  today = Date.utc_today()
  week_start = Date.beginning_of_week(today, :monday)
  week_end = Date.add(week_start, 6)

  week_start_dt = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")
  week_end_dt = DateTime.new!(week_end, ~T[23:59:59], "Etc/UTC")

  Repo.all(
    from s in WorkoutSession,
      where:
        s.user_id == ^user_id and
          (is_nil(s.tags) or s.tags != "warmup") and
          s.inserted_at >= ^week_start_dt and
          s.inserted_at <= ^week_end_dt,
      select: s.inserted_at
  )
  |> Enum.map(&DateTime.to_date/1)
  |> MapSet.new()
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/workouts_test.exs --only describe:"this_week_trained_days/1"
```

Expected: PASS.

- [ ] **Step 5: Commit with jj**

```bash
jj describe -m "feat: add Workouts.this_week_trained_days/1"
jj new
```

---

## Task 2: Add `Workouts.last_run_plan/1`

Returns the most recently run `%WorkoutPlan{}` (with blocks preloaded) for the suggested workout card. Returns `nil` if no sessions with a plan exist.

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Test: `test/burpee_trainer/workouts_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
describe "last_run_plan/1" do
  test "returns the plan from the most recent non-warmup session with a plan_id", %{user: user} do
    plan1 = insert_plan(user, name: "Plan A")
    plan2 = insert_plan(user, name: "Plan B")

    # Older session with plan1
    insert_session(user,
      plan_id: plan1.id,
      inserted_at: ~U[2026-01-01 10:00:00Z]
    )
    # Newer session with plan2
    insert_session(user,
      plan_id: plan2.id,
      inserted_at: ~U[2026-01-02 10:00:00Z]
    )

    result = Workouts.last_run_plan(user)
    assert result.id == plan2.id
    assert result.name == "Plan B"
  end

  test "returns nil when no sessions with a plan exist", %{user: user} do
    assert Workouts.last_run_plan(user) == nil
  end

  test "ignores warmup sessions", %{user: user} do
    plan = insert_plan(user, name: "Plan A")
    insert_session(user, plan_id: plan.id, tags: "warmup", inserted_at: ~U[2026-01-02 10:00:00Z])
    assert Workouts.last_run_plan(user) == nil
  end
end
```

Note: `insert_plan/2` is a test helper you may need to add or find in existing test support files. Check `test/support/` for factory helpers.

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/workouts_test.exs --only describe:"last_run_plan/1" 2>&1 | tail -10
```

Expected: FAIL — `last_run_plan/1` undefined.

- [ ] **Step 3: Implement `last_run_plan/1`**

In `lib/burpee_trainer/workouts.ex`, add:

```elixir
@doc """
Returns the `%WorkoutPlan{}` (blocks preloaded) most recently used in a
non-warmup session, or `nil` if no such session exists.
"""
@spec last_run_plan(User.t()) :: WorkoutPlan.t() | nil
def last_run_plan(%User{id: user_id}) do
  result =
    Repo.one(
      from s in WorkoutSession,
        join: p in WorkoutPlan,
        on: p.id == s.plan_id,
        where:
          s.user_id == ^user_id and
            not is_nil(s.plan_id) and
            (is_nil(s.tags) or s.tags != "warmup"),
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: p
    )

  case result do
    nil -> nil
    plan -> Repo.preload(plan, :blocks)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/workouts_test.exs --only describe:"last_run_plan/1"
```

Expected: PASS.

- [ ] **Step 5: Commit with jj**

```bash
jj describe -m "feat: add Workouts.last_run_plan/1"
jj new
```

---

## Task 3: Rewrite `OverviewLive` — mount and data

Replace the mount logic to load the three data points needed: this-week summary (minutes + streak), trained days, and last-run plan.

**Files:**
- Modify: `lib/burpee_trainer_web/live/overview_live.ex`

- [ ] **Step 1: Replace `mount/2` and module-level setup**

Read the file first. Then replace the entire module content with:

```elixir
defmodule BurpeeTrainerWeb.OverviewLive do
  @moduledoc """
  Home screen. Action-first: status strip + suggested workout card + log link.
  """
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Workouts}
  alias BurpeeTrainerWeb.{Fmt, Layouts}

  @goal_min 80.0

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    weeks = Workouts.weekly_minutes(user)

    today = Date.utc_today()
    current_week_start = Date.beginning_of_week(today, :monday)

    this_week =
      Enum.find(weeks, %{minutes: 0.0, met_goal: false}, &(&1.week_start == current_week_start))

    completed_weeks = Enum.reject(weeks, &(&1.week_start == current_week_start))
    streak = compute_streak(completed_weeks)

    trained_days = Workouts.this_week_trained_days(user)
    last_plan = Workouts.last_run_plan(user)

    {:ok,
     socket
     |> assign(:this_week, this_week)
     |> assign(:streak, streak)
     |> assign(:trained_days, trained_days)
     |> assign(:last_plan, last_plan)
     |> assign(:goal_min, @goal_min)
     |> assign(:today, today)
     |> assign(:week_start, current_week_start)}
  end

  defp compute_streak(completed_weeks) do
    completed_weeks
    |> Enum.sort_by(& &1.week_start, {:desc, Date})
    |> Enum.reduce_while(0, fn week, count ->
      if week.met_goal, do: {:cont, count + 1}, else: {:halt, count}
    end)
  end
```

- [ ] **Step 2: Compile check**

```bash
mix compile --warnings-as-errors 2>&1 | head -20
```

Expected: no warnings (render still references old assigns — fix in next task).

- [ ] **Step 3: Commit with jj**

```bash
jj describe -m "feat: home screen mount — trained days, last plan, streak"
jj new
```

---

## Task 4: Rewrite `OverviewLive` — render and components

Replace the render function and all component functions with the new layout.

**Files:**
- Modify: `lib/burpee_trainer_web/live/overview_live.ex`

The layout from the spec:
1. Compact status strip (no card border): `0 / 80 min · day strip`, second line `N week streak · LEVEL 1D`
2. Suggested workout card (dominant element): plan name, burpee count, duration, big Start button
3. Small "Log a session" link below

- [ ] **Step 1: Replace the render and all components**

Replace everything from `@impl true def render(assigns)` to the end of the module with:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_level={@current_level}
      current_page={:home}
    >
      <div class="space-y-8 max-w-lg mx-auto">
        <%!-- Status strip — no card border --%>
        <.status_strip
          this_week={@this_week}
          streak={@streak}
          trained_days={@trained_days}
          today={@today}
          week_start={@week_start}
          goal_min={@goal_min}
          current_level={@current_level}
        />

        <%!-- Suggested workout card --%>
        <.workout_card last_plan={@last_plan} />

        <%!-- Log session link --%>
        <div class="text-center">
          <.link
            navigate={~p"/stats"}
            class="text-sm text-base-content/30 hover:text-base-content/60 transition"
          >
            + Log a past session
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :this_week, :map, required: true
  attr :streak, :integer, required: true
  attr :trained_days, :any, required: true
  attr :today, :any, required: true
  attr :week_start, :any, required: true
  attr :goal_min, :float, required: true
  attr :current_level, :atom, default: nil

  defp status_strip(assigns) do
    min_done = Float.round(assigns.this_week.minutes, 0) |> trunc()
    goal = trunc(assigns.goal_min)
    days = [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

    day_dots =
      days
      |> Enum.with_index()
      |> Enum.map(fn {day, offset} ->
        date = Date.add(assigns.week_start, offset)
        trained = MapSet.member?(assigns.trained_days, date)
        is_today = date == assigns.today
        %{date: date, trained: trained, is_today: is_today, label: day_label(day)}
      end)

    assigns = assign(assigns, min_done: min_done, goal: goal, day_dots: day_dots)

    ~H"""
    <div class="space-y-2 px-1">
      <%!-- Row 1: minutes + day strip --%>
      <div class="flex items-center justify-between">
        <span class="text-sm text-base-content/60">
          <span class={if @this_week.met_goal, do: "text-primary font-medium", else: "text-base-content font-medium"}>
            {@min_done}
          </span>
          <span class="text-base-content/30"> / {@goal} min</span>
        </span>

        <div class="flex items-center gap-2">
          <%= for dot <- @day_dots do %>
            <div class="flex flex-col items-center gap-0.5">
              <div class={[
                "w-1.5 h-1.5 rounded-full",
                dot.trained && "bg-primary",
                !dot.trained && dot.is_today && "border border-primary/60 bg-transparent",
                !dot.trained && !dot.is_today && "bg-[#1E2535]"
              ]} />
              <span class={[
                "text-[9px] uppercase",
                dot.is_today && "text-primary/70",
                !dot.is_today && "text-base-content/20"
              ]}>
                {dot.label}
              </span>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Row 2: streak + level --%>
      <div class="flex items-center justify-between">
        <span class="text-xs text-base-content/40">
          <%= if @streak > 0 do %>
            {@streak} {if @streak == 1, do: "week", else: "weeks"} streak
          <% else %>
            No streak yet
          <% end %>
        </span>
        <%= if @current_level do %>
          <span class="text-xs font-semibold tracking-widest text-primary uppercase">
            {level_label(@current_level)}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  attr :last_plan, :any, default: nil

  defp workout_card(%{last_plan: nil} = assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-6 space-y-4">
      <p class="text-sm text-base-content/50">No plans yet.</p>
      <.link
        navigate={~p"/workouts/new"}
        class="flex items-center justify-center gap-2 w-full h-12 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
      >
        <.icon name="hero-plus" class="size-4" /> Create a plan
      </.link>
    </div>
    """
  end

  defp workout_card(assigns) do
    plan = assigns.last_plan
    type_label = if plan.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
    assigns = assign(assigns, type_label: type_label)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-6 space-y-5">
      <div class="space-y-1">
        <p class="text-xs text-base-content/40 uppercase tracking-wide font-medium">
          Pick up where you left off
        </p>
        <p class="text-lg font-semibold leading-snug">{@last_plan.name}</p>
        <p class="text-sm text-base-content/50">
          {@last_plan.burpee_count_target} {@type_label}
          <span class="text-base-content/30"> · </span>
          {@last_plan.target_duration_min} min
        </p>
      </div>

      <.link
        navigate={~p"/session/#{@last_plan.id}"}
        class="flex items-center justify-center gap-2 w-full h-14 rounded-lg bg-primary text-primary-content text-base font-semibold hover:bg-primary/90 transition-colors"
      >
        <.icon name="hero-play" class="size-5" /> Start
      </.link>

      <div class="text-center">
        <.link
          navigate={~p"/workouts"}
          class="text-xs text-base-content/30 hover:text-base-content/60 transition"
        >
          Pick another workout →
        </.link>
      </div>
    </div>
    """
  end

  defp level_label(:graduated), do: "Grad"

  defp level_label(l),
    do: l |> Atom.to_string() |> String.replace("level_", "") |> String.upcase()

  defp day_label(:monday), do: "M"
  defp day_label(:tuesday), do: "T"
  defp day_label(:wednesday), do: "W"
  defp day_label(:thursday), do: "T"
  defp day_label(:friday), do: "F"
  defp day_label(:saturday), do: "S"
  defp day_label(:sunday), do: "S"
end
```

- [ ] **Step 2: Run compile**

```bash
mix compile --warnings-as-errors 2>&1 | head -20
```

Expected: clean.

- [ ] **Step 3: Run full test suite**

```bash
mix test 2>&1 | tail -8
```

Expected: all tests pass.

- [ ] **Step 4: Commit with jj**

```bash
jj describe -m "feat: home screen redesign — status strip, suggested workout card, one-tap start"
jj new
```

---

## Task 5: Clean up Stats — move calendar if applicable

The 12-week calendar grid was removed from Home. Check if it's already on Stats; if not, add it there.

**Files:**
- Read: `lib/burpee_trainer_web/live/stats_live.ex`

- [ ] **Step 1: Check Stats for existing weekly grid**

```bash
grep -n "calendar\|weekly_minutes\|week_cell\|grid" /home/aktersnurra/projects/vibe/burpee_trainer/lib/burpee_trainer_web/live/stats_live.ex | head -20
```

- [ ] **Step 2: If weekly grid is absent from Stats, add it**

If the calendar is not on Stats, add `Workouts.weekly_minutes/1` to Stats' mount and render the grid there using the `calendar_card` and `week_cell` components copied from the old `OverviewLive`. If it's already there, skip this step.

- [ ] **Step 3: Run precommit**

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 4: Commit with jj if Stats changed**

```bash
jj describe -m "feat: move 12-week calendar to Stats"
jj new
```

---

## Task 6: Push

- [ ] **Step 1: Final precommit**

```bash
mix precommit
```

Expected: PASS.

- [ ] **Step 2: Move master bookmark and push**

```bash
jj bookmark set master --allow-backwards -r @-
jj git push
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Replace "Run a plan" generic button with suggested-workout card | Task 4 |
| One-tap Start button → `/session/:plan_id` | Task 4 |
| "Pick another workout →" escape hatch | Task 4 |
| Status strip: minutes/target + day strip | Task 4 |
| Status strip: streak + level on second line | Task 4 |
| No card border on status strip | Task 4 |
| Move 12-week grid to Stats | Task 5 |
| "Log a past session" small link | Task 4 |
| Fallback when no plans exist | Task 4 |
| Day dots: filled=trained, outlined=today, empty=untrained | Task 4 |
| `this_week_trained_days/1` query | Task 1 |
| `last_run_plan/1` query | Task 2 |

**Placeholder scan:** No TBD or TODO found.

**Type consistency:**
- `trained_days` is `MapSet.t()` from `this_week_trained_days/1` — used with `MapSet.member?/2` in `status_strip` ✓
- `last_plan` is `WorkoutPlan.t() | nil` from `last_run_plan/1` — pattern matched in `workout_card` ✓
- `week_start` is `Date.t()` — used with `Date.add/2` ✓
