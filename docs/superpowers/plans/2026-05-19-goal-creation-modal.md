# Goal Creation Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a goal creation modal to the Stats screen that lets the user set a burpee count target and date, auto-deriving baselines from their most recent session.

**Architecture:** A `GoalFormComponent` live_component opens from the "Set goal" link in each goal slot. `StatsLive` manages modal open/close state and refreshes goals on save. A new `Workouts.last_session_for_type/2` function provides the baseline session.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, SQLite, Tailwind CSS

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/burpee_trainer/workouts.ex` | Modify | Add `last_session_for_type/2` |
| `lib/burpee_trainer_web/live/goal_form_component.ex` | Create | Modal form live_component |
| `lib/burpee_trainer_web/live/stats_live.ex` | Modify | Wire modal open/close, refresh on save |
| `test/burpee_trainer/workouts_test.exs` | Modify | Tests for `last_session_for_type/2` |
| `test/burpee_trainer_web/live/stats_live_test.exs` | Modify | Integration tests for modal flow |

---

### Task 1: Add `Workouts.last_session_for_type/2`

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/burpee_trainer/workouts_test.exs` inside a new `describe "last_session_for_type/2"` block:

```elixir
describe "last_session_for_type/2" do
  test "returns most recent session with non-nil counts for the given type" do
    user = user_fixture()
    _old = free_form_session_fixture(user, %{"burpee_type" => "six_count", "burpee_count_actual" => 10, "duration_sec_actual" => 60})
    recent = free_form_session_fixture(user, %{"burpee_type" => "six_count", "burpee_count_actual" => 25, "duration_sec_actual" => 100})

    result = Workouts.last_session_for_type(user, :six_count)
    assert result.id == recent.id
  end

  test "returns nil when no sessions exist for the type" do
    user = user_fixture()
    _other = free_form_session_fixture(user, %{"burpee_type" => "navy_seal", "burpee_count_actual" => 20, "duration_sec_actual" => 80})

    assert Workouts.last_session_for_type(user, :six_count) == nil
  end

  test "does not return sessions with nil burpee_count_actual" do
    user = user_fixture()
    plan = plan_fixture(user)
    _plan_session = session_from_plan_fixture(user, plan)

    # plan sessions may have nil burpee_count_actual — verify we only get usable sessions
    result = Workouts.last_session_for_type(user, :six_count)
    if result, do: assert(result.burpee_count_actual != nil and result.duration_sec_actual != nil)
  end

  test "does not return sessions from another user" do
    user1 = user_fixture()
    user2 = user_fixture()
    _s = free_form_session_fixture(user1, %{"burpee_type" => "six_count"})

    assert Workouts.last_session_for_type(user2, :six_count) == nil
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```
mix test test/burpee_trainer/workouts_test.exs --grep "last_session_for_type"
```

Expected: compile error or `UndefinedFunctionError` for `last_session_for_type/2`.

- [ ] **Step 3: Implement `last_session_for_type/2`**

Add to `lib/burpee_trainer/workouts.ex` after `list_sessions_page/3`:

```elixir
@doc """
Most recent session for a user + burpee type that has usable baseline data
(both burpee_count_actual and duration_sec_actual are non-nil).
"""
@spec last_session_for_type(User.t(), atom) :: WorkoutSession.t() | nil
def last_session_for_type(%User{id: user_id}, burpee_type) when is_atom(burpee_type) do
  Repo.one(
    from s in WorkoutSession,
      where:
        s.user_id == ^user_id and
          s.burpee_type == ^burpee_type and
          not is_nil(s.burpee_count_actual) and
          not is_nil(s.duration_sec_actual),
      order_by: [desc: s.inserted_at],
      limit: 1
  )
end
```

- [ ] **Step 4: Run tests**

```
mix test test/burpee_trainer/workouts_test.exs --grep "last_session_for_type"
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```
jj describe -m "feat: add Workouts.last_session_for_type/2" && jj new
```

---

### Task 2: Create `GoalFormComponent`

**Files:**
- Create: `lib/burpee_trainer_web/live/goal_form_component.ex`

- [ ] **Step 1: Create the component file**

Create `lib/burpee_trainer_web/live/goal_form_component.ex`:

```elixir
defmodule BurpeeTrainerWeb.GoalFormComponent do
  use BurpeeTrainerWeb, :live_component

  alias BurpeeTrainer.Goals

  @impl true
  def mount(socket) do
    {:ok, assign(socket, form: nil)}
  end

  @impl true
  def update(%{baseline_session: nil, burpee_type: burpee_type} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, nil)
     |> assign(:type_label, type_label(burpee_type))}
  end

  def update(%{baseline_session: session, burpee_type: burpee_type} = assigns, socket) do
    changeset = Goals.change_goal(%Goals.Goal{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:type_label, type_label(burpee_type))}
  end

  @impl true
  def handle_event("save", %{"goal" => params}, socket) do
    user = socket.assigns.current_user
    session = socket.assigns.baseline_session
    burpee_type = socket.assigns.burpee_type
    today = Date.utc_today()

    burpee_count_target = String.to_integer(params["burpee_count_target"] || "0")

    duration_sec_target =
      round(burpee_count_target * session.duration_sec_actual / session.burpee_count_actual)

    full_attrs = %{
      "burpee_type" => to_string(burpee_type),
      "burpee_count_target" => burpee_count_target,
      "duration_sec_target" => duration_sec_target,
      "date_target" => params["date_target"],
      "burpee_count_baseline" => session.burpee_count_actual,
      "duration_sec_baseline" => session.duration_sec_actual,
      "date_baseline" => Date.to_iso8601(today)
    }

    case Goals.create_goal(user, full_attrs) do
      {:ok, _goal} ->
        send(self(), socket.assigns.on_save)
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp type_label(:six_count), do: "6-Count"
  defp type_label(:navy_seal), do: "Navy SEAL"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold mb-5">Set {@type_label} goal</h2>

      <%= if @baseline_session == nil do %>
        <p class="text-sm text-base-content/50">
          Log at least one {@type_label} session before setting a goal.
        </p>
      <% else %>
        <.form
          for={@form}
          id={"goal-form-#{@id}"}
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <.input
            field={@form[:burpee_count_target]}
            type="number"
            label="Target burpees"
            min={@baseline_session.burpee_count_actual + 1}
          />
          <.input
            field={@form[:date_target]}
            type="date"
            label="Target date"
            min={Date.to_iso8601(Date.add(Date.utc_today(), 1))}
          />
          <p class="text-xs text-base-content/40">
            Baseline: {@baseline_session.burpee_count_actual} burpees from your last session.
          </p>
          <button
            type="submit"
            class="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-content hover:bg-primary/90 transition"
          >
            Save goal
          </button>
        </.form>
      <% end %>
    </div>
    """
  end
end
```

- [ ] **Step 2: Verify compile**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no errors or warnings for the new file.

- [ ] **Step 3: Commit**

```
jj describe -m "feat: add GoalFormComponent" && jj new
```

---

### Task 3: Wire modal into `StatsLive`

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex`

- [ ] **Step 1: Add assigns to `mount/3`**

In `mount/3`, add two new assigns after the existing ones:

```elixir
|> assign(:goal_modal_type, nil)
|> assign(:goal_baseline_session, nil)
```

The full `mount/3` return becomes:

```elixir
{:ok,
 socket
 |> assign(:streak, Streak.compute(user, today))
 |> assign(:today, today)
 |> assign(:goals, Goals.list_active_goals(user))
 |> assign(:sessions, sessions)
 |> assign(:sessions_has_more, has_more)
 |> assign(:show_more_trends, false)
 |> assign(:log_modal_open, false)
 |> assign(:goal_modal_type, nil)
 |> assign(:goal_baseline_session, nil)
 |> assign(:weekly_data, Workouts.weekly_minutes(user))}
```

- [ ] **Step 2: Add event handlers**

Add after `handle_event("toggle_trends", ...)`:

```elixir
def handle_event("open_goal_modal", %{"type" => type_str}, socket) do
  user = socket.assigns.current_user
  burpee_type = String.to_existing_atom(type_str)
  baseline = Workouts.last_session_for_type(user, burpee_type)

  {:noreply,
   socket
   |> assign(:goal_modal_type, burpee_type)
   |> assign(:goal_baseline_session, baseline)}
end

def handle_event("close_goal_modal", _, socket) do
  {:noreply,
   socket
   |> assign(:goal_modal_type, nil)
   |> assign(:goal_baseline_session, nil)}
end
```

- [ ] **Step 3: Add `handle_info` for `:goal_saved`**

Add after `handle_info(:session_saved, ...)`:

```elixir
def handle_info(:goal_saved, socket) do
  user = socket.assigns.current_user

  {:noreply,
   socket
   |> assign(:goal_modal_type, nil)
   |> assign(:goal_baseline_session, nil)
   |> assign(:goals, Goals.list_active_goals(user))}
end
```

- [ ] **Step 4: Add goal modal to `render/1`**

Add the goal modal block immediately after the log modal block (before `</Layouts.app>`):

```heex
<%!-- Goal modal --%>
<%= if @goal_modal_type do %>
  <div
    id="goal-modal"
    class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/60"
    phx-click="close_goal_modal"
  >
    <div
      class="w-full sm:max-w-md bg-[#0D1017] border border-[#1E2535] rounded-t-2xl sm:rounded-2xl p-6"
      phx-click-away="close_goal_modal"
      phx-click.stop
    >
      <.live_component
        module={BurpeeTrainerWeb.GoalFormComponent}
        id="goal-form"
        current_user={@current_user}
        burpee_type={@goal_modal_type}
        baseline_session={@goal_baseline_session}
        on_save={:goal_saved}
      />
    </div>
  </div>
<% end %>
```

- [ ] **Step 5: Update `goal_slot` to trigger modal**

In the `goal_slot` component, replace the no-op link:

```heex
<.link navigate={~p"/stats"} class="text-xs text-primary hover:underline">Set goal</.link>
```

with:

```heex
<button
  type="button"
  phx-click="open_goal_modal"
  phx-value-type={@burpee_type}
  class="text-xs text-primary hover:underline"
>
  Set goal
</button>
```

- [ ] **Step 6: Compile check**

```
mix compile --warnings-as-errors 2>&1 | grep -E "error|warning" | head -20
```

Expected: no errors.

- [ ] **Step 7: Commit**

```
jj describe -m "feat: wire goal modal into StatsLive" && jj new
```

---

### Task 4: Integration tests

**Files:**
- Modify: `test/burpee_trainer_web/live/stats_live_test.exs`

- [ ] **Step 1: Add tests**

Add a new `describe` block to `test/burpee_trainer_web/live/stats_live_test.exs`:

```elixir
describe "goal creation modal" do
  test "Set goal button opens modal", %{conn: conn, user: user} do
    _session = free_form_session_fixture(user, %{"burpee_type" => "six_count"})
    {:ok, view, _html} = live(conn, ~p"/stats")
    view |> element("button[phx-value-type='six_count']") |> render_click()
    assert render(view) =~ "Set 6-Count goal"
  end

  test "modal shows no-session state when user has no sessions for type", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stats")
    view |> element("button[phx-value-type='six_count']") |> render_click()
    assert render(view) =~ "Log at least one 6-Count session"
  end

  test "modal shows form when baseline session exists", %{conn: conn, user: user} do
    _session = free_form_session_fixture(user, %{"burpee_type" => "six_count", "burpee_count_actual" => 30, "duration_sec_actual" => 120})
    {:ok, view, _html} = live(conn, ~p"/stats")
    view |> element("button[phx-value-type='six_count']") |> render_click()
    assert render(view) =~ "Target burpees"
    assert render(view) =~ "Baseline: 30 burpees"
  end

  test "saving goal closes modal and updates goal slot", %{conn: conn, user: user} do
    _session = free_form_session_fixture(user, %{"burpee_type" => "six_count", "burpee_count_actual" => 30, "duration_sec_actual" => 120})
    today = Date.utc_today()

    {:ok, view, _html} = live(conn, ~p"/stats")
    view |> element("button[phx-value-type='six_count']") |> render_click()

    view
    |> form("#goal-form-goal-form", %{
      "goal" => %{
        "burpee_count_target" => "60",
        "date_target" => Date.to_iso8601(Date.add(today, 30))
      }
    })
    |> render_submit()

    html = render(view)
    refute html =~ "Set 6-Count goal"
    assert html =~ "60 burpees"
  end

  test "navy seal goal slot opens modal for navy_seal type", %{conn: conn, user: user} do
    _session = free_form_session_fixture(user, %{"burpee_type" => "navy_seal", "burpee_count_actual" => 20, "duration_sec_actual" => 100})
    {:ok, view, _html} = live(conn, ~p"/stats")
    view |> element("button[phx-value-type='navy_seal']") |> render_click()
    assert render(view) =~ "Set Navy SEAL goal"
  end
end
```

- [ ] **Step 2: Run new tests**

```
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Expected: all tests pass including existing ones.

- [ ] **Step 3: Commit**

```
jj describe -m "test: goal creation modal integration tests" && jj new
```

---

### Task 5: Precommit check

- [ ] **Step 1: Run full precommit**

```
mix precommit
```

Expected: compile clean, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Fix any issues, then done**
