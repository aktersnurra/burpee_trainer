# Goal Card Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show real progress on goal cards — best normalized reps from qualifying 20-min sessions since the goal baseline, with a progress bar and days remaining.

**Architecture:** New `Workouts.best_qualifying_session_since/3` fetches the highest-reps qualifying session (duration 1190–1210 sec) since a given date. `StatsLive` adds `@six_progress` and `@seal_progress` assigns. `goal_slot` renders current/target progress bar, days left, and an "Update goal" link replacing the "Replace" button.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, SQLite

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/burpee_trainer/workouts.ex` | Modify | Add `best_qualifying_session_since/3` |
| `lib/burpee_trainer_web/live/stats_live.ex` | Modify | Add progress assigns, update `goal_slot` rendering |
| `test/burpee_trainer/workouts_test.exs` | Modify | Tests for `best_qualifying_session_since/3` |

---

### Task 1: Add `Workouts.best_qualifying_session_since/3`

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

The qualifying session filter is: `burpee_count_actual > 0`, `duration_sec_actual` between 1190 and 1210. "Best" = highest `burpee_count_actual` (not normalized — normalization happens in the UI since durations are all ~1200 sec anyway). Returns `nil` if no qualifying sessions exist since the given date.

- [ ] **Step 1: Write failing tests**

Add at the end of `test/burpee_trainer/workouts_test.exs` (before the final `end`):

```elixir
describe "best_qualifying_session_since/3" do
  test "returns nil when no sessions exist" do
    user = user_fixture()
    assert Workouts.best_qualifying_session_since(user, :six_count, ~D[2026-01-01]) == nil
  end

  test "returns the session with the highest burpee_count_actual since the given date" do
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

    result = Workouts.best_qualifying_session_since(user, :six_count, ~D[2026-04-01])
    assert result.id == best.id
  end

  test "excludes sessions before the given date" do
    user = user_fixture()

    _old =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 300,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-03-01 10:00:00Z]
      })

    assert Workouts.best_qualifying_session_since(user, :six_count, ~D[2026-04-01]) == nil
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

    _long =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 300,
        "duration_sec_actual" => 2400,
        "inserted_at" => ~U[2026-04-10 10:00:00Z]
      })

    assert Workouts.best_qualifying_session_since(user, :six_count, ~D[2026-04-01]) == nil
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

    assert Workouts.best_qualifying_session_since(user, :six_count, ~D[2026-04-01]) == nil
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

    assert Workouts.best_qualifying_session_since(user2, :six_count, ~D[2026-04-01]) == nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/workouts_test.exs --grep "best_qualifying_session_since"
```

Expected: compile error or `UndefinedFunctionError`.

- [ ] **Step 3: Implement the function**

Add to `lib/burpee_trainer/workouts.ex` after `last_session_for_type/2`:

```elixir
@doc """
Best qualifying session (highest burpee_count_actual) for a user + burpee type
since a given date. Qualifying = duration_sec_actual in [1190, 1210] and
burpee_count_actual > 0. Returns nil if no qualifying sessions exist.
"""
@spec best_qualifying_session_since(User.t(), atom, Date.t()) :: WorkoutSession.t() | nil
def best_qualifying_session_since(%User{id: user_id}, burpee_type, since)
    when is_atom(burpee_type) do
  Repo.one(
    from s in WorkoutSession,
      where:
        s.user_id == ^user_id and
          s.burpee_type == ^burpee_type and
          s.burpee_count_actual > 0 and
          s.duration_sec_actual >= 1190 and
          s.duration_sec_actual <= 1210 and
          fragment("date(?)", s.inserted_at) >= ^since,
      order_by: [desc: s.burpee_count_actual],
      limit: 1
  )
end
```

- [ ] **Step 4: Run tests**

```
mix test test/burpee_trainer/workouts_test.exs --grep "best_qualifying_session_since"
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```
jj describe -m "feat: add Workouts.best_qualifying_session_since/3" && jj new
```

---

### Task 2: Wire progress into StatsLive and update goal_slot

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`

Read the full file before making changes — it's large.

- [ ] **Step 1: Add progress assigns to `mount/3`**

After `|> assign(:goals, Goals.list_active_goals(user))`, add:

```elixir
|> assign(:six_progress, nil)
|> assign(:seal_progress, nil)
```

Then add a private function to compute progress assigns and call it from mount. Replace the two lines above with a call to `load_goal_progress/2`:

Actually, inline the calls directly. After `|> assign(:goals, Goals.list_active_goals(user))`:

```elixir
|> then(fn socket ->
  six = Enum.find(socket.assigns.goals, &(&1.burpee_type == :six_count))
  seal = Enum.find(socket.assigns.goals, &(&1.burpee_type == :navy_seal))
  socket
  |> assign(:six_progress, six && Workouts.best_qualifying_session_since(user, :six_count, six.date_baseline))
  |> assign(:seal_progress, seal && Workouts.best_qualifying_session_since(user, :seal_count, seal.date_baseline))
end)
```

Wait — the burpee type atom for navy seal is `:navy_seal` not `:seal_count`. Use the correct atoms. The full addition after goals assign:

```elixir
|> then(fn socket ->
  goals = socket.assigns.goals
  six_goal = Enum.find(goals, &(&1.burpee_type == :six_count))
  seal_goal = Enum.find(goals, &(&1.burpee_type == :navy_seal))
  socket
  |> assign(:six_progress, six_goal && Workouts.best_qualifying_session_since(user, :six_count, six_goal.date_baseline))
  |> assign(:seal_progress, seal_goal && Workouts.best_qualifying_session_since(user, :navy_seal, seal_goal.date_baseline))
end)
```

- [ ] **Step 2: Refresh progress in `handle_info(:session_saved, ...)`**

Add the same `then/2` block at the end of `handle_info(:session_saved, socket)`:

```elixir
|> then(fn socket ->
  goals = socket.assigns.goals
  six_goal = Enum.find(goals, &(&1.burpee_type == :six_count))
  seal_goal = Enum.find(goals, &(&1.burpee_type == :navy_seal))
  socket
  |> assign(:six_progress, six_goal && Workouts.best_qualifying_session_since(user, :six_count, six_goal.date_baseline))
  |> assign(:seal_progress, seal_goal && Workouts.best_qualifying_session_since(user, :navy_seal, seal_goal.date_baseline))
end)
```

- [ ] **Step 3: Refresh progress in `handle_info(:goal_saved, ...)`**

`handle_info(:goal_saved, socket)` already refreshes `@goals`. Add the same `then/2` block there too, after the goals refresh. First fetch the user:

```elixir
def handle_info(:goal_saved, socket) do
  user = socket.assigns.current_user
  goals = Goals.list_active_goals(user)

  {:noreply,
   socket
   |> assign(:goal_modal_type, nil)
   |> assign(:goal_baseline_session, nil)
   |> assign(:goals, goals)
   |> then(fn socket ->
     six_goal = Enum.find(goals, &(&1.burpee_type == :six_count))
     seal_goal = Enum.find(goals, &(&1.burpee_type == :navy_seal))
     socket
     |> assign(:six_progress, six_goal && Workouts.best_qualifying_session_since(user, :six_count, six_goal.date_baseline))
     |> assign(:seal_progress, seal_goal && Workouts.best_qualifying_session_since(user, :navy_seal, seal_goal.date_baseline))
   end)}
end
```

- [ ] **Step 4: Pass progress to `goals_section`**

In `render/1`, update the `goals_section` call from:

```heex
<.goals_section goals={@goals} />
```

To:

```heex
<.goals_section goals={@goals} six_progress={@six_progress} seal_progress={@seal_progress} />
```

- [ ] **Step 5: Update `goals_section` component**

Replace the current `goals_section` (including its `attr` declaration):

```elixir
attr :goals, :list, required: true
attr :six_progress, :any, required: true
attr :seal_progress, :any, required: true

defp goals_section(assigns) do
  assigns =
    assigns
    |> assign(:six, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
    |> assign(:seal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

  ~H"""
  <div class="grid grid-cols-2 gap-3">
    <.goal_slot burpee_type={:six_count} label="6-COUNT" goal={@six} progress={@six_progress} />
    <.goal_slot burpee_type={:navy_seal} label="NAVY SEAL" goal={@seal} progress={@seal_progress} />
  </div>
  """
end
```

- [ ] **Step 6: Replace `goal_slot` component**

Replace the current `goal_slot` (including its `attr` declarations) with:

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

  pct =
    if assigns.goal do
      min(round(current_reps / assigns.goal.burpee_count_target * 100), 100)
    else
      0
    end

  days_left =
    if assigns.goal do
      Date.diff(assigns.goal.date_target, today)
    else
      nil
    end

  assigns =
    assign(assigns,
      current_reps: current_reps,
      pct: pct,
      days_left: days_left
    )

  ~H"""
  <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
    <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/40">{@label}</p>

    <%= if @goal do %>
      <div class="space-y-2">
        <div class="tabular-nums">
          <span class="text-lg font-semibold">{@current_reps}</span>
          <span class="text-xs text-base-content/40 ml-1">/ {@goal.burpee_count_target}</span>
        </div>

        <div class="h-1.5 rounded-full bg-[#1E2535] overflow-hidden">
          <div
            class="h-full rounded-full bg-primary transition-all duration-500"
            style={"width: #{@pct}%"}
          />
        </div>

        <div class="flex items-center justify-between">
          <p class="text-[10px] text-base-content/40">
            <%= cond do %>
              <% @days_left > 0 -> %>{@days_left}d left
              <% @days_left == 0 -> %>Today
              <% true -> %>Overdue
            <% end %>
          </p>
          <%= if @current_reps == 0 do %>
            <p class="text-[10px] text-base-content/30">No 20-min session yet</p>
          <% end %>
        </div>

        <button
          type="button"
          phx-click="open_goal_modal"
          phx-value-type={@burpee_type}
          class="text-[10px] text-base-content/30 hover:text-primary transition"
        >
          Update goal
        </button>
      </div>
    <% else %>
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

- [ ] **Step 7: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no output.

- [ ] **Step 8: Commit**

```
jj describe -m "feat: goal card progress with best qualifying session" && jj new
```

---

### Task 3: Precommit check

- [ ] **Step 1: Run full precommit**

```
mix precommit
```

Expected: compile clean, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Fix any issues, then done**
