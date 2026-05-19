# Volume Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the volume chart placeholder with a stacked SVG bar chart showing weekly burpee reps by type, with per-type dashed trend lines.

**Architecture:** A new `Workouts.weekly_volume/1` query aggregates reps per type per week (last 12 weeks, Elixir-side zero-filling). `StatsLive` mounts `@volume_data` and passes it to a `volume_chart/1` component that renders stacked SVG bars with linear regression trend lines.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, SQLite, plain SVG (no chart library)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/burpee_trainer/workouts.ex` | Modify | Add `weekly_volume/1` |
| `lib/burpee_trainer_web/live/stats_live.ex` | Modify | Mount `@volume_data`, pass to chart, replace placeholder |
| `test/burpee_trainer/workouts_test.exs` | Modify | Tests for `weekly_volume/1` |

---

### Task 1: Add `Workouts.weekly_volume/1`

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new `describe "weekly_volume/1"` block at the end of `test/burpee_trainer/workouts_test.exs`, before the final `end`:

```elixir
describe "weekly_volume/1" do
  test "returns empty list when user has no sessions" do
    user = user_fixture()
    assert Workouts.weekly_volume(user) == []
  end

  test "aggregates reps by type within the same week" do
    user = user_fixture()

    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 30,
      "inserted_at" => ~U[2026-04-21 10:00:00Z]
    })

    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 20,
      "inserted_at" => ~U[2026-04-23 10:00:00Z]
    })

    free_form_session_fixture(user, %{
      "burpee_type" => "navy_seal",
      "burpee_count_actual" => 15,
      "inserted_at" => ~U[2026-04-22 10:00:00Z]
    })

    [week] = Workouts.weekly_volume(user)
    assert week.week_start == ~D[2026-04-20]
    assert week.six_count_reps == 50
    assert week.navy_seal_reps == 15
  end

  test "separates sessions into different weeks" do
    user = user_fixture()

    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 40,
      "inserted_at" => ~U[2026-04-21 10:00:00Z]
    })

    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 50,
      "inserted_at" => ~U[2026-04-28 10:00:00Z]
    })

    [w1, w2] = Workouts.weekly_volume(user)
    assert w1.week_start == ~D[2026-04-27]
    assert w1.six_count_reps == 50
    assert w2.week_start == ~D[2026-04-20]
    assert w2.six_count_reps == 40
  end

  test "treats nil burpee_count_actual as 0" do
    user = user_fixture()
    plan = plan_fixture(user)
    session_from_plan_fixture(user, plan)

    [week] = Workouts.weekly_volume(user)
    assert week.six_count_reps == 0
    assert week.navy_seal_reps == 0
  end

  test "excludes warmup-tagged sessions" do
    user = user_fixture()

    free_form_session_fixture(user, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 40
    })

    {:ok, _} =
      Workouts.create_warmup_session(user, %{
        burpee_type: :six_count,
        burpee_count_done: 5,
        duration_sec: 600
      })

    [week] = Workouts.weekly_volume(user)
    assert week.six_count_reps == 40
  end

  test "scopes to user — other users' sessions not included" do
    alice = user_fixture()
    bob = user_fixture()

    free_form_session_fixture(alice, %{"burpee_type" => "six_count", "burpee_count_actual" => 30})
    free_form_session_fixture(bob, %{"burpee_type" => "navy_seal", "burpee_count_actual" => 20})

    [alice_week] = Workouts.weekly_volume(alice)
    assert alice_week.six_count_reps == 30
    assert alice_week.navy_seal_reps == 0

    [bob_week] = Workouts.weekly_volume(bob)
    assert bob_week.navy_seal_reps == 20
    assert bob_week.six_count_reps == 0
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/workouts_test.exs --grep "weekly_volume"
```

Expected: compile error or `UndefinedFunctionError`.

- [ ] **Step 3: Implement `weekly_volume/1`**

Add to `lib/burpee_trainer/workouts.ex` after `weekly_minutes/1`:

```elixir
@doc """
Weekly burpee rep totals by type for a user. Last 12 weeks, most recent first.
Each entry has :week_start (Date), :six_count_reps (integer), :navy_seal_reps (integer).
Weeks with no sessions still appear with zeros. Warmup sessions are excluded.
"""
@spec weekly_volume(User.t()) :: [%{week_start: Date.t(), six_count_reps: integer, navy_seal_reps: integer}]
def weekly_volume(%User{id: user_id}) do
  sessions =
    Repo.all(
      from s in WorkoutSession,
        where:
          s.user_id == ^user_id and
            (is_nil(s.tags) or s.tags != "warmup"),
        select: %{
          inserted_at: s.inserted_at,
          burpee_type: s.burpee_type,
          burpee_count_actual: s.burpee_count_actual
        }
    )

  sessions
  |> Enum.group_by(fn %{inserted_at: dt} ->
    dt |> DateTime.to_date() |> Date.beginning_of_week(:monday)
  end)
  |> Enum.map(fn {week_start, rows} ->
    six_count_reps =
      rows
      |> Enum.filter(&(&1.burpee_type == :six_count))
      |> Enum.sum_by(&(&1.burpee_count_actual || 0))

    navy_seal_reps =
      rows
      |> Enum.filter(&(&1.burpee_type == :navy_seal))
      |> Enum.sum_by(&(&1.burpee_count_actual || 0))

    %{week_start: week_start, six_count_reps: six_count_reps, navy_seal_reps: navy_seal_reps}
  end)
  |> Enum.sort_by(& &1.week_start, {:desc, Date})
end
```

- [ ] **Step 4: Run tests**

```
mix test test/burpee_trainer/workouts_test.exs --grep "weekly_volume"
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```
jj describe -m "feat: add Workouts.weekly_volume/1" && jj new
```

---

### Task 2: Wire `weekly_volume` into `StatsLive` and render chart

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`

- [ ] **Step 1: Add `@volume_data` assign to `mount/3`**

In `mount/3`, add after `|> assign(:weekly_data, Workouts.weekly_minutes(user))`:

```elixir
|> assign(:volume_data, Workouts.weekly_volume(user))
```

- [ ] **Step 2: Refresh `@volume_data` in `handle_info(:session_saved, ...)`**

In `handle_info(:session_saved, socket)`, add:

```elixir
|> assign(:volume_data, Workouts.weekly_volume(user))
```

The full updated clause:

```elixir
def handle_info(:session_saved, socket) do
  user = socket.assigns.current_user
  today = socket.assigns.today
  {sessions, has_more} = Workouts.list_sessions_page(user, @page_size)

  {:noreply,
   socket
   |> assign(:log_modal_open, false)
   |> assign(:streak, Streak.compute(user, today))
   |> assign(:sessions, sessions)
   |> assign(:sessions_has_more, has_more)
   |> assign(:weekly_data, Workouts.weekly_minutes(user))
   |> assign(:volume_data, Workouts.weekly_volume(user))}
end
```

- [ ] **Step 3: Update `trends_section` to pass `volume_data`**

Find the `trends_section` call in `render/1`:

```heex
<.trends_section weekly_data={@weekly_data} show_more={@show_more_trends} />
```

Change to:

```heex
<.trends_section weekly_data={@weekly_data} volume_data={@volume_data} show_more={@show_more_trends} />
```

- [ ] **Step 4: Update `trends_section` component signature and body**

Find `defp trends_section(assigns)` and update:

```elixir
attr :weekly_data, :list, required: true
attr :volume_data, :list, required: true
attr :show_more, :boolean, required: true

defp trends_section(assigns) do
  ~H"""
  <div class="space-y-3">
    <div class="flex items-center justify-between">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">Trends</h2>
      <button phx-click="toggle_trends" class="text-xs text-primary hover:underline">
        {if @show_more, do: "Show less", else: "Show more"}
      </button>
    </div>

    <.weekly_minutes_chart weekly_data={@weekly_data} />

    <%= if @show_more do %>
      <.volume_chart volume_data={@volume_data} />
    <% end %>
  </div>
  """
end
```

- [ ] **Step 5: Replace `volume_chart` placeholder with full implementation**

Replace the current `volume_chart` function (the placeholder) with:

```elixir
attr :volume_data, :list, required: true

defp volume_chart(assigns) do
  chart_weeks = assigns.volume_data |> Enum.take(12) |> Enum.reverse()
  all_empty = Enum.all?(chart_weeks, &(&1.six_count_reps == 0 and &1.navy_seal_reps == 0))
  assigns = assign(assigns, chart_weeks: chart_weeks, all_empty: all_empty)

  ~H"""
  <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
    <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">Weekly volume (reps)</p>

    <%= if @all_empty do %>
      <p class="text-xs text-base-content/30">No sessions yet.</p>
    <% else %>
      <% bar_w = 18
         gap = 7
         max_total = @chart_weeks |> Enum.map(&(&1.six_count_reps + &1.navy_seal_reps)) |> Enum.max(fn -> 1 end)
         scale = fn reps -> max(reps / max_total * 70, 0) end %>
      <svg viewBox="0 0 300 80" class="w-full" aria-hidden="true">
        <%= for {week, i} <- Enum.with_index(@chart_weeks) do %>
          <% x = i * (bar_w + gap)
             h_seal = scale.(week.navy_seal_reps)
             h_six = scale.(week.six_count_reps)
             y_seal = 75 - h_seal
             y_six = y_seal - h_six %>
          <%= if h_seal > 0 do %>
            <rect x={x} y={y_seal} width={bar_w} height={h_seal} fill="#F97316" rx="2" />
          <% end %>
          <%= if h_six > 0 do %>
            <rect x={x} y={y_six} width={bar_w} height={h_six} fill="#4A9EFF" rx="2" />
          <% end %>
        <% end %>

        <%= for {color, key} <- [{"#4A9EFF", :six_count_reps}, {"#F97316", :navy_seal_reps}] do %>
          <% points = @chart_weeks |> Enum.with_index() |> Enum.map(fn {w, i} -> {i * 1.0, Map.get(w, key) * 1.0} end)
             has_data = Enum.any?(points, fn {_, y} -> y > 0 end) %>
          <%= if has_data do %>
            <% {slope, intercept} = linear_trend(points)
               x0 = 0.0
               x1 = (length(@chart_weeks) - 1) * 1.0
               y0_raw = slope * x0 + intercept
               y1_raw = slope * x1 + intercept
               to_svg_y = fn reps -> 75 - max(reps / max_total * 70, 0) end
               sy0 = to_svg_y.(y0_raw)
               sy1 = to_svg_y.(y1_raw)
               tx1 = x1 * (bar_w + gap) + bar_w / 2 %>
            <line
              x1={bar_w / 2}
              y1={sy0}
              x2={tx1}
              y2={sy1}
              stroke={color}
              stroke-width="1"
              stroke-dasharray="3,3"
              opacity="0.6"
            />
          <% end %>
        <% end %>
      </svg>

      <div class="flex gap-4 mt-2">
        <span class="text-xs text-base-content/40 flex items-center gap-1">
          <span style="color:#4A9EFF">●</span> 6-Count
        </span>
        <span class="text-xs text-base-content/40 flex items-center gap-1">
          <span style="color:#F97316">●</span> Navy SEAL
        </span>
      </div>
    <% end %>
  </div>
  """
end
```

- [ ] **Step 6: Add `linear_trend/2` private function**

Add after `volume_chart/1`:

```elixir
defp linear_trend(points) do
  n = length(points)
  sum_x = Enum.sum_by(points, fn {x, _} -> x end)
  sum_y = Enum.sum_by(points, fn {_, y} -> y end)
  sum_xy = Enum.sum_by(points, fn {x, y} -> x * y end)
  sum_xx = Enum.sum_by(points, fn {x, _} -> x * x end)
  denom = n * sum_xx - sum_x * sum_x

  if denom == 0.0 do
    {0.0, if(n > 0, do: sum_y / n, else: 0.0)}
  else
    slope = (n * sum_xy - sum_x * sum_y) / denom
    intercept = (sum_y - slope * sum_x) / n
    {slope, intercept}
  end
end
```

- [ ] **Step 7: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no output.

- [ ] **Step 8: Commit**

```
jj describe -m "feat: volume chart with stacked bars and trend lines" && jj new
```

---

### Task 3: Precommit check

- [ ] **Step 1: Run full precommit**

```
mix precommit
```

Expected: compile clean, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Fix any issues, then done**
