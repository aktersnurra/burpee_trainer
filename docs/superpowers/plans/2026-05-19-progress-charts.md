# Progress Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stacked-bar volume chart with two per-type progress line charts (6-Count and Navy SEAL) showing normalized reps-per-20-min across all sessions, always visible in the Trends section.

**Architecture:** A new `Workouts.list_sessions_for_chart/2` query fetches all chartable sessions for a type (positive counts and duration). `StatsLive` replaces `@volume_data`/`show_more_trends` with `@six_count_sessions`/`@navy_seal_sessions`. A `progress_chart/1` component renders the line chart with a target line from the active goal. The "Show more" toggle and `volume_chart/1` are removed entirely.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, SQLite, plain SVG

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/burpee_trainer/workouts.ex` | Modify | Add `list_sessions_for_chart/2` |
| `lib/burpee_trainer_web/live/stats_live.ex` | Modify | Replace volume assigns/events, add progress chart component, remove volume_chart/toggle |
| `test/burpee_trainer/workouts_test.exs` | Modify | Tests for `list_sessions_for_chart/2` |

---

### Task 1: Add `Workouts.list_sessions_for_chart/2`

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new `describe "list_sessions_for_chart/2"` block at the end of `test/burpee_trainer/workouts_test.exs` (before the final `end`):

```elixir
describe "list_sessions_for_chart/2" do
  test "returns empty list when user has no sessions" do
    user = user_fixture()
    assert Workouts.list_sessions_for_chart(user, :six_count) == []
  end

  test "returns sessions with positive burpee_count_actual and duration_sec_actual, oldest first" do
    user = user_fixture()

    s1 =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 200,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-01 10:00:00Z]
      })

    s2 =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 250,
        "duration_sec_actual" => 1200,
        "inserted_at" => ~U[2026-04-08 10:00:00Z]
      })

    result = Workouts.list_sessions_for_chart(user, :six_count)
    assert length(result) == 2
    assert Enum.at(result, 0).id == s1.id
    assert Enum.at(result, 1).id == s2.id
  end

  test "excludes sessions with nil or zero burpee_count_actual" do
    user = user_fixture()

    _zero =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 0,
        "duration_sec_actual" => 1200
      })

    plan = plan_fixture(user)
    _nil_count = session_from_plan_fixture(user, plan)

    assert Workouts.list_sessions_for_chart(user, :six_count) == []
  end

  test "excludes sessions with nil or zero duration_sec_actual" do
    user = user_fixture()

    _zero_dur =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 200,
        "duration_sec_actual" => 0
      })

    assert Workouts.list_sessions_for_chart(user, :six_count) == []
  end

  test "only returns sessions for the given burpee_type" do
    user = user_fixture()

    _six =
      free_form_session_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 200,
        "duration_sec_actual" => 1200
      })

    _seal =
      free_form_session_fixture(user, %{
        "burpee_type" => "navy_seal",
        "burpee_count_actual" => 100,
        "duration_sec_actual" => 1200
      })

    six_results = Workouts.list_sessions_for_chart(user, :six_count)
    assert length(six_results) == 1
    assert hd(six_results).burpee_type == :six_count
  end

  test "does not return sessions from another user" do
    user1 = user_fixture()
    user2 = user_fixture()

    free_form_session_fixture(user1, %{
      "burpee_type" => "six_count",
      "burpee_count_actual" => 200,
      "duration_sec_actual" => 1200
    })

    assert Workouts.list_sessions_for_chart(user2, :six_count) == []
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/workouts_test.exs --grep "list_sessions_for_chart"
```

Expected: compile error or `UndefinedFunctionError`.

- [ ] **Step 3: Implement `list_sessions_for_chart/2`**

Add to `lib/burpee_trainer/workouts.ex` after `last_session_for_type/2`:

```elixir
@doc """
All sessions for a user + burpee type suitable for progress charting:
burpee_count_actual > 0 and duration_sec_actual > 0, ordered oldest first.
"""
@spec list_sessions_for_chart(User.t(), atom) :: [WorkoutSession.t()]
def list_sessions_for_chart(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
  Repo.all(
    from s in WorkoutSession,
      where:
        s.user_id == ^user_id and
          s.burpee_type == ^burpee_type and
          s.burpee_count_actual > 0 and
          s.duration_sec_actual > 0,
      order_by: [asc: s.inserted_at]
  )
end
```

- [ ] **Step 4: Run tests**

```
mix test test/burpee_trainer/workouts_test.exs --grep "list_sessions_for_chart"
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```
jj describe -m "feat: add Workouts.list_sessions_for_chart/2" && jj new
```

---

### Task 2: Update StatsLive — replace volume assigns, remove toggle, add progress charts

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`

This task makes all changes to `stats_live.ex` in one go. Read the full file first to understand current structure before editing.

- [ ] **Step 1: Replace `@volume_data` and `@show_more_trends` assigns in `mount/3`**

Remove these two lines from `mount/3`:
```elixir
|> assign(:show_more_trends, false)
...
|> assign(:volume_data, Workouts.weekly_volume(user))
```

Add these two lines instead (after `|> assign(:weekly_data, Workouts.weekly_minutes(user))`):
```elixir
|> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
|> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))
```

- [ ] **Step 2: Remove `toggle_trends` event handler**

Delete this entire function:
```elixir
def handle_event("toggle_trends", _, socket) do
  {:noreply, update(socket, :show_more_trends, &(!&1))}
end
```

- [ ] **Step 3: Update `handle_info(:session_saved, ...)` to refresh progress sessions**

Replace `|> assign(:volume_data, Workouts.weekly_volume(user))` with:
```elixir
|> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
|> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))
```

The full updated `handle_info(:session_saved, socket)`:
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
   |> assign(:six_count_sessions, Workouts.list_sessions_for_chart(user, :six_count))
   |> assign(:navy_seal_sessions, Workouts.list_sessions_for_chart(user, :navy_seal))}
end
```

- [ ] **Step 4: Update `render/1` — pass new assigns to `trends_section`**

Replace:
```heex
<.trends_section
  weekly_data={@weekly_data}
  volume_data={@volume_data}
  show_more={@show_more_trends}
/>
```

With:
```heex
<.trends_section
  weekly_data={@weekly_data}
  six_count_sessions={@six_count_sessions}
  navy_seal_sessions={@navy_seal_sessions}
  goals={@goals}
/>
```

- [ ] **Step 5: Replace `trends_section` component**

Replace the existing `trends_section` (including its `attr` declarations) with:

```elixir
attr :weekly_data, :list, required: true
attr :six_count_sessions, :list, required: true
attr :navy_seal_sessions, :list, required: true
attr :goals, :list, required: true

defp trends_section(assigns) do
  assigns =
    assigns
    |> assign(:six_goal, Enum.find(assigns.goals, &(&1.burpee_type == :six_count)))
    |> assign(:seal_goal, Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal)))

  ~H"""
  <div class="space-y-3">
    <h2 class="text-base font-semibold text-base-content">Trends</h2>
    <.weekly_minutes_chart weekly_data={@weekly_data} />
    <.progress_chart
      sessions={@six_count_sessions}
      label="6-Count progress"
      color="#4A9EFF"
      goal={@six_goal}
    />
    <.progress_chart
      sessions={@navy_seal_sessions}
      label="Navy SEAL progress"
      color="#F97316"
      goal={@seal_goal}
    />
  </div>
  """
end
```

- [ ] **Step 6: Remove `volume_chart/1` function and its `attr` declaration**

Delete the entire `volume_chart` function including its `attr :volume_data` declaration (the full block from `attr :volume_data, :list, required: true` through the closing `end`).

- [ ] **Step 7: Add `progress_chart/1` component**

Add this after `weekly_minutes_chart/1`:

```elixir
attr :sessions, :list, required: true
attr :label, :string, required: true
attr :color, :string, required: true
attr :goal, :any, required: true

defp progress_chart(assigns) do
  # Normalize each session to reps-per-20-min pace
  points =
    Enum.map(assigns.sessions, fn s ->
      normalized = round(s.burpee_count_actual / s.duration_sec_actual * 1200)
      date = DateTime.to_date(s.inserted_at)
      %{date: date, reps: normalized}
    end)

  target = if assigns.goal, do: assigns.goal.burpee_count_target, else: nil

  all_vals = Enum.map(points, & &1.reps) ++ (if target, do: [target], else: [])
  max_val = if all_vals == [], do: 1, else: Enum.max(all_vals)

  n = length(points)

  # Layout
  y_axis_w = 24
  chart_w = 300
  top_pad = 8
  plot_h = 60
  bot_pad = 16
  total_h = top_pad + plot_h + bot_pad

  step = if n > 1, do: (chart_w - y_axis_w) / (n - 1), else: chart_w - y_axis_w

  to_x = fn i -> y_axis_w + i * step end
  to_y = fn v -> top_pad + plot_h - v / max_val * plot_h end

  indexed = Enum.with_index(points)

  polyline =
    Enum.map_join(indexed, " ", fn {p, i} ->
      "#{Float.round(to_x.(i * 1.0), 1)},#{Float.round(to_y.(p.reps * 1.0), 1)}"
    end)

  # X-axis labels — first, last, every 3rd
  x_labels =
    Enum.filter(indexed, fn {_p, i} ->
      i == 0 or i == n - 1 or (n > 4 and rem(i, 3) == 0)
    end)

  target_y = if target, do: to_y.(target * 1.0), else: nil

  assigns =
    assign(assigns,
      points: points,
      indexed: indexed,
      polyline: polyline,
      x_labels: x_labels,
      target_y: target_y,
      target: target,
      max_val: max_val,
      to_x: to_x,
      to_y: to_y,
      top_pad: top_pad,
      plot_h: plot_h,
      total_h: total_h,
      chart_w: chart_w,
      y_axis_w: y_axis_w
    )

  ~H"""
  <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
    <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">{@label}</p>

    <%= if @points == [] do %>
      <p class="text-xs text-base-content/30">No sessions yet.</p>
    <% else %>
      <svg viewBox={"0 0 #{@chart_w} #{@total_h}"} class="w-full overflow-visible" aria-hidden="true">
        <%!-- y-axis labels --%>
        <text x={@y_axis_w - 3} y={@top_pad + 4} text-anchor="end" font-size="7" fill="#3A4A5E">{@max_val}</text>
        <text x={@y_axis_w - 3} y={@top_pad + @plot_h} text-anchor="end" font-size="7" fill="#3A4A5E">0</text>

        <%!-- zero baseline --%>
        <line
          x1={@y_axis_w}
          y1={@top_pad + @plot_h}
          x2={@chart_w}
          y2={@top_pad + @plot_h}
          stroke="#1E2535"
          stroke-width="0.5"
        />

        <%!-- target line --%>
        <%= if @target_y do %>
          <line
            x1={@y_axis_w}
            y1={@target_y}
            x2={@chart_w}
            y2={@target_y}
            stroke={@color}
            stroke-width="0.5"
            stroke-dasharray="3,3"
            opacity="0.5"
          />
          <text x={@chart_w} y={@target_y - 2} text-anchor="end" font-size="6" fill={@color} opacity="0.7">{@target}</text>
        <% end %>

        <%!-- line --%>
        <%= if length(@indexed) > 1 do %>
          <polyline
            points={@polyline}
            fill="none"
            stroke={@color}
            stroke-width="1.5"
            stroke-linejoin="round"
          />
        <% end %>

        <%!-- dots --%>
        <%= for {_p, i} <- @indexed do %>
          <% pt = Enum.at(@points, i) %>
          <circle
            cx={@to_x.(i * 1.0)}
            cy={@to_y.(pt.reps * 1.0)}
            r="2.5"
            fill={@color}
          />
        <% end %>

        <%!-- x-axis date labels --%>
        <%= for {p, i} <- @x_labels do %>
          <text
            x={@to_x.(i * 1.0)}
            y={@top_pad + @plot_h + 12}
            text-anchor="middle"
            font-size="6"
            fill="#3A4A5E"
          >{Calendar.strftime(p.date, "%-d %b")}</text>
        <% end %>
      </svg>
    <% end %>
  </div>
  """
end
```

- [ ] **Step 8: Remove `weekly_volume` from the `Workouts` alias if it's now unused**

Check the alias at the top of the file. The existing alias is:
```elixir
alias BurpeeTrainer.{Goals, Streak, Workouts}
```
This imports the whole `Workouts` module — no change needed.

- [ ] **Step 9: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no output.

- [ ] **Step 10: Commit**

```
jj describe -m "feat: progress line charts replacing volume chart" && jj new
```

---

### Task 3: Precommit check

- [ ] **Step 1: Run full precommit**

```
mix precommit
```

Expected: compile clean, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Fix any issues, then done**
