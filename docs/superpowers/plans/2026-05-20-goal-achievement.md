# Goal Achievement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-mark goals achieved when progress hits target, show an achieved state on goal cards, flash a notification, tag the achieving session in the sessions list, and redesign goal cards with pace + unit clarity.

**Architecture:** Four changes: (1) replace `best_qualifying_session_since` with `best_qualifying_session` (no date cutoff), (2) add goal achievement detection + `Goals.mark_achieved` call in `handle_info(:session_saved)`, (3) switch `@goals` to include achieved goals via a new `Goals.list_current_goals` query, (4) redesign `goal_slot` UI and add session "Goal reached" tag. The `goals.updated_at` field serves as achievement date; session tagging is purely derived at render time.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, SQLite, Tailwind CSS, Heroicons

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/burpee_trainer/workouts.ex` | Modify | Replace `best_qualifying_session_since/3` with `best_qualifying_session/2` (no date cutoff) |
| `lib/burpee_trainer/goals.ex` | Modify | Add `list_current_goals/1` (active + recently achieved) |
| `lib/burpee_trainer_web/live/stats_live.ex` | Modify | Achievement detection, UI redesign, session tag |
| `test/burpee_trainer/workouts_test.exs` | Modify | Update tests for renamed function |
| `test/burpee_trainer/goals_test.exs` | Modify | Tests for `list_current_goals/1` |
| `test/burpee_trainer_web/live/stats_live_test.exs` | Modify | Update tests for new UI |

---

### Task 1: Replace `best_qualifying_session_since/3` with `best_qualifying_session/2`

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

The new function drops the `since` date filter entirely — returns the all-time best qualifying 20-min (±10 sec) session for a user + type.

- [ ] **Step 1: Update `best_qualifying_session_since/3` tests**

In `test/burpee_trainer/workouts_test.exs`, find the `describe "best_qualifying_session_since/3"` block and replace it entirely with:

```elixir
describe "best_qualifying_session/2" do
  test "returns nil when no sessions exist" do
    user = user_fixture()
    assert Workouts.best_qualifying_session(user, :six_count) == nil
  end

  test "returns the session with the highest burpee_count_actual" do
    user = user_fixture()

    _lower =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 200,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-10 10:00:00Z]
      })

    best =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 280,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-17 10:00:00Z]
      })

    result = Workouts.best_qualifying_session(user, :six_count)
    assert result.id == best.id
  end

  test "excludes sessions outside the 20-min ±10 sec window" do
    user = user_fixture()

    _short =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 300,
        "duration_sec_actual" => 600,
        "inserted_at" => ~U[2026-04-10 10:00:00Z]
      })

    assert Workouts.best_qualifying_session(user, :six_count) == nil
  end

  test "only returns sessions for the given burpee_type" do
    user = user_fixture()

    _seal =
      free_form_session_fixture(user, %{
        "burpee_type" => "navy_seal",
        "burpee_count_actual" => 150,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-10 10:00:00Z]
      })

    assert Workouts.best_qualifying_session(user, :six_count) == nil
  end

  test "does not return sessions from another user" do
    user1 = user_fixture()
    user2 = user_fixture()

    free_form_session_fixture(user1, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 250,
      "duration_sec_actual" => 1200,
      "inserted_at" => ~U[2026-04-10 10:00:00Z]
    })

    assert Workouts.best_qualifying_session(user2, :six_count) == nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/workouts_test.exs --grep "best_qualifying_session"
```

Expected: compile error (old function name referenced, new one not defined yet).

- [ ] **Step 3: Replace function in `lib/burpee_trainer/workouts.ex`**

Find `def best_qualifying_session_since` and replace the entire function (including `@doc` and `@spec`) with:

```elixir
@doc """
All-time best qualifying session (highest burpee_count_actual) for a user + burpee type.
Qualifying = duration_sec_actual in [1190, 1210] and burpee_count_actual > 0.
Returns nil if no qualifying sessions exist.
"""
@spec best_qualifying_session(User.t(), atom) :: WorkoutSession.t() | nil
def best_qualifying_session(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
  Repo.one(
    from s in WorkoutSession,
      where:
        s.user_id == ^user_id and
          s.burpee_type == ^burpee_type and
          s.burpee_count_actual > 0 and
          s.duration_sec_actual >= 1190 and
          s.duration_sec_actual <= 1210,
      order_by: [desc: s.burpee_count_actual],
      limit: 1
  )
end
```

- [ ] **Step 4: Update `compute_goal_progress/3` in `stats_live.ex`**

In `lib/burpee_trainer_web/live/stats_live.ex`, find `compute_goal_progress/3` and update the two `Workouts.best_qualifying_session_since` calls to `Workouts.best_qualifying_session`:

```elixir
defp compute_goal_progress(socket, user, goals) do
  six_goal = Enum.find(goals, &(&1.burpee_type == :six_count))
  seal_goal = Enum.find(goals, &(&1.burpee_type == :navy_seal))

  socket
  |> assign(:six_progress, six_goal && Workouts.best_qualifying_session(user, :six_count))
  |> assign(:seal_progress, seal_goal && Workouts.best_qualifying_session(user, :navy_seal))
end
```

Note: `best_qualifying_session` now takes only `(user, burpee_type)` — no date argument.

- [ ] **Step 5: Run tests**

```
mix test test/burpee_trainer/workouts_test.exs --grep "best_qualifying_session"
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -10
```

Expected: no output.

- [ ] **Step 7: Commit**

```
jj describe -m "refactor: replace best_qualifying_session_since with best_qualifying_session (all-time)" && jj new
```

---

### Task 2: Add `Goals.list_current_goals/1`

**Files:**
- Modify: `lib/burpee_trainer/goals.ex`
- Modify: `test/burpee_trainer/goals_test.exs`

We need active goals AND recently achieved goals (so the card can show the "Goal reached" state). "Current" = active OR achieved. Abandoned goals are excluded.

- [ ] **Step 1: Write failing tests**

Add to `test/burpee_trainer/goals_test.exs`:

```elixir
describe "list_current_goals/1" do
  test "returns active goals" do
    user = user_fixture()
    goal = goal_fixture(user)
    results = Goals.list_current_goals(user)
    assert Enum.any?(results, &(&1.id == goal.id))
  end

  test "returns achieved goals" do
    user = user_fixture()
    {:ok, goal} = Goals.mark_achieved(goal_fixture(user))
    results = Goals.list_current_goals(user)
    assert Enum.any?(results, &(&1.id == goal.id))
  end

  test "does not return abandoned goals" do
    user = user_fixture()
    {:ok, goal} = Goals.abandon_goal(goal_fixture(user))
    results = Goals.list_current_goals(user)
    refute Enum.any?(results, &(&1.id == goal.id))
  end

  test "does not return goals from another user" do
    user1 = user_fixture()
    user2 = user_fixture()
    _goal = goal_fixture(user1)
    assert Goals.list_current_goals(user2) == []
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/goals_test.exs --grep "list_current_goals"
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement `list_current_goals/1`**

Add to `lib/burpee_trainer/goals.ex` after `list_active_goals/1`:

```elixir
@doc """
Active and achieved goals for a user (excludes abandoned).
Used to display both in-progress and completed goal cards.
"""
@spec list_current_goals(User.t()) :: [Goal.t()]
def list_current_goals(%User{id: user_id}) do
  Repo.all(
    from goal in Goal,
      where: goal.user_id == ^user_id and goal.status in [:active, :achieved],
      order_by: [desc: goal.updated_at]
  )
end
```

- [ ] **Step 4: Run tests**

```
mix test test/burpee_trainer/goals_test.exs --grep "list_current_goals"
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```
jj describe -m "feat: add Goals.list_current_goals/1" && jj new
```

---

### Task 3: Achievement detection + UI redesign

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`
- Modify: `test/burpee_trainer_web/live/stats_live_test.exs`

This is the largest task. Read the full `stats_live.ex` before making changes.

- [ ] **Step 1: Switch `@goals` to use `list_current_goals`**

In `mount/3`, replace:
```elixir
|> assign(:goals, Goals.list_active_goals(user))
```
With:
```elixir
|> assign(:goals, Goals.list_current_goals(user))
```

In `handle_info(:goal_saved, socket)`, replace:
```elixir
goals = Goals.list_active_goals(user)
```
With:
```elixir
goals = Goals.list_current_goals(user)
```

- [ ] **Step 2: Add achievement detection to `handle_info(:session_saved, ...)`**

Replace the current `handle_info(:session_saved, socket)` with:

```elixir
def handle_info(:session_saved, socket) do
  user = socket.assigns.current_user
  today = socket.assigns.today
  {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

  # Check for newly achieved goals before refreshing goal list
  newly_achieved =
    socket.assigns.goals
    |> Enum.filter(&(&1.status == :active))
    |> Enum.filter(fn goal ->
      best = Workouts.best_qualifying_session(user, goal.burpee_type)
      best &&
        round(best.burpee_count_actual / best.duration_sec_actual * 1200.0) >=
          goal.burpee_count_target
    end)

  Enum.each(newly_achieved, &Goals.mark_achieved/1)

  goals = Goals.list_current_goals(user)

  socket =
    socket
    |> assign(:log_modal_open, false)
    |> assign(:streak, Streak.compute(user, today))
    |> assign(:sessions, sessions)
    |> assign(:sessions_has_more, has_more)
    |> assign(:weekly_data, Workouts.weekly_minutes(user))
    |> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
    |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))
    |> assign(:goals, goals)
    |> compute_goal_progress(user, goals)

  socket =
    Enum.reduce(newly_achieved, socket, fn goal, acc ->
      type_label = if goal.burpee_type == :six_count, do: "6-Count", else: "Navy SEAL"
      put_flash(acc, :info, "#{type_label} goal reached!")
    end)

  {:noreply, socket}
end
```

- [ ] **Step 3: Redesign `goal_slot/1`**

Replace the entire `goal_slot` function (including `attr` declarations) with:

```elixir
attr :burpee_type, :atom, required: true
attr :label, :string, required: true
attr :goal, :any, required: true
attr :progress, :any, required: true

defp goal_slot(assigns) do
  today = Date.utc_today()

  current_reps =
    if assigns.progress do
      round(assigns.progress.burpee_count_actual / assigns.progress.duration_sec_actual * 1200.0)
    else
      0
    end

  {pct, days_left, weekly_pace} =
    if assigns.goal && assigns.goal.status == :active do
      target = assigns.goal.burpee_count_target
      pct = min(round(current_reps / target * 100), 100)
      days = Date.diff(assigns.goal.date_target, today)
      weeks_remaining = max(ceil(days / 7), 1)
      reps_needed = max(target - current_reps, 0)
      pace = ceil(reps_needed / weeks_remaining)
      {pct, days, pace}
    else
      {100, nil, nil}
    end

  assigns =
    assign(assigns,
      current_reps: current_reps,
      pct: pct,
      days_left: days_left,
      weekly_pace: weekly_pace
    )

  ~H"""
  <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
    <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/60">{@label}</p>

    <%= cond do %>
      <% @goal && @goal.status == :achieved -> %>
        <div class="space-y-2">
          <div class="flex items-center gap-2 text-primary">
            <.icon name="hero-check-circle" class="size-4 shrink-0" />
            <span class="text-sm font-semibold">Goal reached</span>
          </div>
          <p class="text-xs text-base-content/40">
            {Calendar.strftime(DateTime.to_date(@goal.updated_at), "%-d %b %Y")}
          </p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="text-xs text-primary hover:underline"
          >
            Set new goal
          </button>
        </div>

      <% @goal && @goal.status == :active -> %>
        <div class="space-y-2">
          <div class="flex items-baseline justify-between">
            <div class="tabular-nums">
              <span class="text-lg font-semibold">{@current_reps}</span>
              <span class="text-xs text-base-content/40 ml-1">/ {@goal.burpee_count_target} burpees</span>
            </div>
            <%= if @weekly_pace && @days_left > 0 do %>
              <span class="text-[10px] text-base-content/40 tabular-nums">~{@weekly_pace}/wk</span>
            <% end %>
          </div>

          <div class="h-1.5 rounded-full bg-[#1E2535] overflow-hidden">
            <div
              class="h-full rounded-full bg-primary transition-all duration-500"
              style={"width: #{@pct}%"}
            />
          </div>

          <%= if @current_reps == 0 do %>
            <p class="text-[10px] text-base-content/30">Log a 20-min session to track progress</p>
          <% end %>

          <p class="text-[10px] text-base-content/40">
            by {Calendar.strftime(@goal.date_target, "%-d %b")}
            <%= cond do %>
              <% @days_left > 0 -> %> · {@days_left}d left
              <% @days_left == 0 -> %> · Today
              <% true -> %> · Overdue
            <% end %>
          </p>

          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="text-[10px] text-base-content/30 hover:text-primary transition"
          >
            Update goal
          </button>
        </div>

      <% true -> %>
        <div class="space-y-2">
          <p class="text-xs text-base-content/50">No goal set</p>
          <button
            type="button"
            phx-click="open_goal_modal"
            phx-value-type={@burpee_type}
            class="text-xs text-primary hover:underline"
          >
            Set goal
          </button>
        </div>
    <% end %>
  </div>
  """
end
```

- [ ] **Step 4: Add "Goal reached" tag to session rows**

Add `achieved_goals` attr to `sessions_section` and pass it. First update `goals_section` call in `render/1` — actually, pass `@goals` directly to `sessions_section`:

In `render/1`, update the `sessions_section` call from:
```heex
<.sessions_section sessions={@sessions} has_more={@sessions_has_more} />
```
To:
```heex
<.sessions_section sessions={@sessions} has_more={@sessions_has_more} goals={@goals} />
```

Replace `sessions_section` component (including `attr` declarations):

```elixir
attr :sessions, :list, required: true
attr :has_more, :boolean, required: true
attr :goals, :list, required: true

defp sessions_section(assigns) do
  # Build a map of {burpee_type => achievement_date} for achieved goals
  achieved_map =
    assigns.goals
    |> Enum.filter(&(&1.status == :achieved))
    |> Map.new(fn g -> {g.burpee_type, DateTime.to_date(g.updated_at)} end)

  assigns = assign(assigns, :achieved_map, achieved_map)

  ~H"""
  <div>
    <h2 class="text-base font-semibold text-base-content mb-2">Sessions</h2>

    <%= if @sessions == [] do %>
      <p class="text-sm text-base-content/40">No sessions yet.</p>
    <% else %>
      <div class="rounded-[10px] border border-[#1E2535] bg-base-200 divide-y divide-[#1E2535] px-4">
        <%= for session <- @sessions do %>
          <.session_row session={session} achieved_map={@achieved_map} />
        <% end %>
      </div>

      <%= if @has_more do %>
        <button
          phx-click="load_more_sessions"
          class="w-full pt-3 text-xs text-base-content/40 hover:text-base-content/70 transition text-center"
        >
          Load more
        </button>
      <% end %>
    <% end %>
  </div>
  """
end
```

Replace `session_row` component:

```elixir
attr :session, :any, required: true
attr :achieved_map, :map, required: true

defp session_row(assigns) do
  today = Date.utc_today()
  date = DateTime.to_date(assigns.session.inserted_at)
  date_str = if date.year == today.year,
    do: Calendar.strftime(date, "%-d %b"),
    else: Calendar.strftime(date, "%-d %b %Y")

  goal_reached = Map.get(assigns.achieved_map, assigns.session.burpee_type) == date

  assigns = assign(assigns, date_str: date_str, goal_reached: goal_reached)

  ~H"""
  <div class="flex items-center justify-between gap-4 py-2.5">
    <div class="flex items-center gap-3 min-w-0">
      <span class="text-sm font-semibold tabular-nums w-10 shrink-0">
        <%= if @session.burpee_count_actual, do: @session.burpee_count_actual, else: "—" %>
      </span>
      <span class="text-sm text-base-content/70 shrink-0">{Fmt.burpee_type(@session.burpee_type)}</span>
      <span class="text-sm text-base-content/40 tabular-nums shrink-0">{Fmt.duration_sec(@session.duration_sec_actual)}</span>
      <%= if @goal_reached do %>
        <span class="flex items-center gap-1 text-[10px] text-primary shrink-0">
          <.icon name="hero-trophy" class="size-3" />
          Goal reached
        </span>
      <% end %>
      <%= if @session.plan do %>
        <span class="text-xs text-base-content/25 truncate">{@session.plan.name}</span>
      <% end %>
    </div>
    <span class="text-xs text-base-content/30 shrink-0">{@date_str}</span>
  </div>
  """
end
```

- [ ] **Step 5: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no output.

- [ ] **Step 6: Run tests**

```
mix test 2>&1 | tail -4
```

Fix any failing tests — likely the `stats_live_test.exs` test that checks "60 burpees" in the goal slot (now the format changed). Update assertions to match new UI (e.g. `"/ 60 burpees"` or `"Set new goal"`).

- [ ] **Step 7: Commit**

```
jj describe -m "feat: goal achievement detection, card redesign, session tag" && jj new
```

---

### Task 4: Precommit check

- [ ] **Step 1: Run full precommit**

```
mix precommit
```

Expected: compile clean, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Fix any issues, then done**
