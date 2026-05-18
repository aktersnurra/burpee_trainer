# Stats Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Stats screen at `/stats` with a streak card, goal slots, recent sessions (replacing HistoryLive), SVG trend charts, and a FAB for logging past sessions. Retire GoalsLive and HistoryLive.

**Architecture:** `StatsLive` is a single LiveView with five focused sub-components. `BurpeeTrainer.Streak` is a new pure context module that computes streak state from sessions. A new `user_stats` migration stores previous-best. The existing `Goals` context and `Goals.Goal` schema are used unchanged. Charts are server-rendered SVG via Contex.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView 1.1, Ecto + SQLite, Tailwind CSS, Contex (SVG charts). Run `mix precommit` before every commit.

**Prerequisite:** Plan A (Workouts screen) must be complete. `StatsLive` stub at `/stats` must exist (created in Plan A, Task 3).

---

## File Map

| Action | File |
|---|---|
| Create | `lib/burpee_trainer/streak.ex` |
| Create | `priv/repo/migrations/YYYYMMDDHHMMSS_create_user_stats.exs` |
| Modify | `lib/burpee_trainer_web/live/stats_live.ex` (replace stub) |
| Delete | `lib/burpee_trainer_web/live/goals_live.ex` |
| Delete | `lib/burpee_trainer_web/live/history_live.ex` |
| Modify | `lib/burpee_trainer_web/live/log_live.ex` (make it embeddable as a component) |
| Modify | `lib/burpee_trainer/workouts.ex` (add `list_sessions_recent/2`) |
| Modify | `mix.exs` (add `:contex` dependency) |
| Create | `test/burpee_trainer/streak_test.exs` |
| Create | `test/burpee_trainer_web/live/stats_live_test.exs` |
| Delete | `test/burpee_trainer_web/live/goals_live_test.exs` |
| Delete | `test/burpee_trainer_web/live/history_live_test.exs` |

---

## Task 1: Add Contex dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add contex to deps**

Open `mix.exs`. In the `deps` list, add:

```elixir
{:contex, "~> 0.5"}
```

- [ ] **Step 2: Fetch and compile**

```bash
mix deps.get && mix compile --warnings-as-errors
```

Expected: Contex fetched and compiled, no warnings.

- [ ] **Step 3: Commit**

```
jj describe -m "deps: add contex for SVG charts" && jj new
```

---

## Task 2: user_stats migration

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_user_stats.exs`

- [ ] **Step 1: Generate the migration**

```bash
mix ecto.gen.migration create_user_stats
```

Note the generated filename (e.g. `20260518120000_create_user_stats.exs`).

- [ ] **Step 2: Fill in the migration**

Open the generated file and replace the `change/0` body:

```elixir
def change do
  create table(:user_stats, primary_key: false) do
    add :user_id, references(:users, on_delete: :delete_all), primary_key: true
    add :previous_best_weeks, :integer, null: false, default: 0
    add :previous_best_ended_on, :string  # ISO date string, nullable

    timestamps(updated_at: true, inserted_at: false)
  end
end
```

- [ ] **Step 3: Run migration**

```bash
mix ecto.migrate
```

Expected: migration runs without error.

- [ ] **Step 4: Commit**

```
jj describe -m "feat: add user_stats table for previous best streak" && jj new
```

---

## Task 3: Streak module

**Files:**
- Create: `lib/burpee_trainer/streak.ex`
- Create: `test/burpee_trainer/streak_test.exs`

`Streak.compute/2` reads sessions from the DB, groups by ISO week, computes current streak and previous best, updates `user_stats`, and returns a `%Streak{}` struct.

- [ ] **Step 1: Write failing tests**

Create `test/burpee_trainer/streak_test.exs`:

```elixir
defmodule BurpeeTrainer.StreakTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Streak
  alias BurpeeTrainer.Streak.State

  # Helper: insert a session on a specific date with a given duration
  defp session_on(user, date, duration_min) do
    dt = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

    {:ok, session} =
      BurpeeTrainer.Workouts.create_free_form_session(user, %{
        "burpee_type" => "six_count",
        "burpee_count_actual" => 10,
        "duration_sec_actual" => round(duration_min * 60),
        "inserted_at" => dt
      })

    session
  end

  describe "compute/2" do
    test "returns zero streak when user has no sessions" do
      user = user_fixture()
      today = ~D[2026-05-18]

      state = Streak.compute(user, today)

      assert %State{streak_weeks: 0, current_week_minutes: 0} = state
    end

    test "counts a week with >= 80 minutes as a streak week" do
      user = user_fixture()
      # Monday of the current week
      today = ~D[2026-05-18]
      monday = ~D[2026-05-18]
      session_on(user, monday, 90)

      state = Streak.compute(user, today)

      assert state.current_week_minutes >= 90
    end

    test "streak_weeks is 0 when current week has >= 80 but no prior complete weeks" do
      user = user_fixture()
      today = ~D[2026-05-18]
      session_on(user, today, 90)

      state = Streak.compute(user, today)

      # Current week doesn't count toward streak until it closes
      assert state.streak_weeks == 0
    end

    test "streak_weeks counts consecutive complete prior weeks" do
      user = user_fixture()
      today = ~D[2026-05-18]
      # Two prior complete weeks, both >= 80 min
      session_on(user, ~D[2026-05-11], 90)  # week of May 11
      session_on(user, ~D[2026-05-04], 90)  # week of May 4

      state = Streak.compute(user, today)

      assert state.streak_weeks == 2
    end

    test "streak resets to 0 on gap week" do
      user = user_fixture()
      today = ~D[2026-05-18]
      # Week of May 11 met goal, week of May 4 did not
      session_on(user, ~D[2026-05-11], 90)
      session_on(user, ~D[2026-05-04], 30)  # only 30 min — break

      state = Streak.compute(user, today)

      assert state.streak_weeks == 1
    end

    test "days_active_this_week includes days with sessions in current week" do
      user = user_fixture()
      today = ~D[2026-05-18]  # Monday
      session_on(user, ~D[2026-05-18], 30)
      session_on(user, ~D[2026-05-20], 30)  # Wednesday

      state = Streak.compute(user, today)

      assert ~D[2026-05-18] in state.days_active_this_week
      assert ~D[2026-05-20] in state.days_active_this_week
      refute ~D[2026-05-19] in state.days_active_this_week
    end

    test "previous_best_weeks persists and survives recompute" do
      user = user_fixture()
      today = ~D[2026-05-18]

      # Build a 3-week streak, then break it
      session_on(user, ~D[2026-04-28], 90)  # week of Apr 28
      session_on(user, ~D[2026-05-04], 90)  # week of May 4
      session_on(user, ~D[2026-05-11], 90)  # week of May 11
      # May 18 week has nothing — streak broken as of next week

      # Simulate "next week" arriving
      next_monday = ~D[2026-05-25]
      state = Streak.compute(user, next_monday)

      assert state.streak_weeks == 0
      assert state.previous_best_weeks == 3
    end

    test "property: naive reference matches compute/2" do
      user = user_fixture()
      today = ~D[2026-05-18]

      # Insert sessions across several weeks
      weeks_data = [
        {~D[2026-04-21], 90},
        {~D[2026-04-28], 50},  # break
        {~D[2026-05-05], 90},
        {~D[2026-05-11], 90}
      ]

      for {date, min} <- weeks_data, do: session_on(user, date, min)

      state = Streak.compute(user, today)

      # Naive reference: walk prior weeks from most recent, count consecutive >= 80
      prior_weeks =
        weeks_data
        |> Enum.filter(fn {d, _} -> Date.beginning_of_week(d, :monday) < Date.beginning_of_week(today, :monday) end)
        |> Enum.group_by(fn {d, _} -> Date.beginning_of_week(d, :monday) end)
        |> Enum.map(fn {_w, entries} -> Enum.sum_by(entries, fn {_, m} -> m end) end)
        |> Enum.sort(:desc)

      expected_streak =
        prior_weeks
        |> Enum.reduce_while(0, fn min, acc ->
          if min >= 80, do: {:cont, acc + 1}, else: {:halt, acc}
        end)

      assert state.streak_weeks == expected_streak
    end
  end
end
```

- [ ] **Step 2: Add `create_free_form_session/2` to `Workouts` context if not present**

Check `lib/burpee_trainer/workouts.ex` for `create_free_form_session`. If missing, add:

```elixir
@spec create_free_form_session(User.t(), map) ::
        {:ok, WorkoutSession.t()} | {:error, Ecto.Changeset.t()}
def create_free_form_session(%User{id: user_id}, attrs) do
  %WorkoutSession{user_id: user_id}
  |> WorkoutSession.free_form_changeset(attrs)
  |> Repo.insert()
end
```

- [ ] **Step 3: Run tests to confirm failure**

```bash
mix test test/burpee_trainer/streak_test.exs
```

Expected: `UndefinedFunctionError` for `BurpeeTrainer.Streak`.

- [ ] **Step 4: Implement Streak module**

Create `lib/burpee_trainer/streak.ex`:

```elixir
defmodule BurpeeTrainer.Streak do
  @moduledoc """
  Computes streak state from session history. Reads from DB, updates
  user_stats with previous_best, returns a %State{} struct.

  Week boundary: Monday 00:00 – Sunday 23:59:59 UTC (ISO 8601).
  A week counts toward the streak iff total session minutes >= 80.
  The current (open) week never breaks or extends the streak count —
  only closed weeks do.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Repo

  @goal_min 80

  defmodule State do
    @type t :: %__MODULE__{
      current_week_minutes: number(),
      current_week_target: pos_integer(),
      days_active_this_week: [Date.t()],
      on_pace?: boolean(),
      streak_weeks: non_neg_integer(),
      previous_best_weeks: non_neg_integer(),
      previous_best_ended_on: Date.t() | nil
    }

    defstruct [
      current_week_minutes: 0,
      current_week_target: 80,
      days_active_this_week: [],
      on_pace?: false,
      streak_weeks: 0,
      previous_best_weeks: 0,
      previous_best_ended_on: nil
    ]
  end

  @spec compute(User.t(), Date.t()) :: State.t()
  def compute(%User{id: user_id}, today) do
    week_start = Date.beginning_of_week(today, :monday)

    sessions = fetch_sessions(user_id)

    by_week =
      Enum.group_by(sessions, fn %{date: d} ->
        Date.beginning_of_week(d, :monday)
      end)

    current_week_sessions = Map.get(by_week, week_start, [])
    current_week_minutes = Enum.sum_by(current_week_sessions, & &1.duration_min)

    days_active =
      current_week_sessions
      |> Enum.map(& &1.date)
      |> Enum.uniq()

    days_elapsed = Date.day_of_week(today, :monday)
    on_pace? = current_week_minutes >= @goal_min * days_elapsed / 7

    prior_weeks =
      by_week
      |> Enum.reject(fn {w, _} -> w == week_start end)
      |> Enum.sort_by(fn {w, _} -> w end, {:desc, Date})

    streak =
      Enum.reduce_while(prior_weeks, 0, fn {_w, sessions}, acc ->
        min = Enum.sum_by(sessions, & &1.duration_min)
        if min >= @goal_min, do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    # Load and update previous best
    user_stats = get_or_init_user_stats(user_id)
    previous_best = user_stats.previous_best_weeks
    previous_ended = user_stats.previous_best_ended_on

    {new_best, new_ended} =
      if streak > previous_best do
        {streak, today}
      else
        {previous_best, previous_ended}
      end

    if new_best != previous_best do
      upsert_user_stats(user_id, new_best, new_ended)
    end

    %State{
      current_week_minutes: current_week_minutes,
      current_week_target: @goal_min,
      days_active_this_week: days_active,
      on_pace?: on_pace?,
      streak_weeks: streak,
      previous_best_weeks: new_best,
      previous_best_ended_on: new_ended
    }
  end

  defp fetch_sessions(user_id) do
    Repo.all(
      from s in BurpeeTrainer.Workouts.WorkoutSession,
        where: s.user_id == ^user_id,
        select: %{
          date: fragment("date(?)", s.inserted_at),
          duration_min: s.duration_sec_actual / 60.0
        }
    )
    |> Enum.map(fn %{date: d, duration_min: m} ->
      %{date: Date.from_iso8601!(d), duration_min: m}
    end)
  end

  defp get_or_init_user_stats(user_id) do
    case Repo.one(from us in "user_stats", where: us.user_id == ^user_id,
           select: %{previous_best_weeks: us.previous_best_weeks,
                     previous_best_ended_on: us.previous_best_ended_on}) do
      nil -> %{previous_best_weeks: 0, previous_best_ended_on: nil}
      row -> row
    end
  end

  defp upsert_user_stats(user_id, best_weeks, ended_on) do
    ended_str = if ended_on, do: Date.to_iso8601(ended_on)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.insert_all("user_stats",
      [%{user_id: user_id, previous_best_weeks: best_weeks,
         previous_best_ended_on: ended_str, updated_at: now}],
      on_conflict: {:replace, [:previous_best_weeks, :previous_best_ended_on, :updated_at]},
      conflict_target: :user_id
    )
  end
end
```

- [ ] **Step 5: Run streak tests**

```bash
mix test test/burpee_trainer/streak_test.exs
```

Fix any failures before continuing.

- [ ] **Step 6: Run precommit**

```bash
mix precommit
```

- [ ] **Step 7: Commit**

```
jj describe -m "feat: add Streak.compute/2 with user_stats persistence" && jj new
```

---

## Task 4: Add `list_sessions_recent/2` to Workouts context

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`

The Stats screen needs the last N sessions with plan name preloaded.

- [ ] **Step 1: Add the function**

Open `lib/burpee_trainer/workouts.ex` and add after `list_sessions/1`:

```elixir
@doc """
Return the most recent `limit` sessions for a user, preloading the
associated plan (for plan name display). Most recent first.
"""
@spec list_sessions_recent(User.t(), pos_integer()) :: [WorkoutSession.t()]
def list_sessions_recent(%User{id: user_id}, limit \\ 10) do
  Repo.all(
    from s in WorkoutSession,
      where: s.user_id == ^user_id,
      order_by: [desc: s.inserted_at],
      limit: ^limit,
      preload: :plan
  )
end

@doc """
Return all sessions for a user with plan preloaded, most recent first.
"""
@spec list_sessions_all(User.t()) :: [WorkoutSession.t()]
def list_sessions_all(%User{id: user_id}) do
  Repo.all(
    from s in WorkoutSession,
      where: s.user_id == ^user_id,
      order_by: [desc: s.inserted_at],
      preload: :plan
  )
end
```

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

- [ ] **Step 3: Commit**

```
jj describe -m "feat: add list_sessions_recent and list_sessions_all to Workouts" && jj new
```

---

## Task 5: StatsLive — full implementation

**Files:**
- Modify: `lib/burpee_trainer_web/live/stats_live.ex` (replace stub)
- Create: `test/burpee_trainer_web/live/stats_live_test.exs`

- [ ] **Step 1: Write tests first**

Create `test/burpee_trainer_web/live/stats_live_test.exs`:

```elixir
defmodule BurpeeTrainerWeb.StatsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Goals
  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/stats" do
    test "renders streak card with zero state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")

      assert html =~ "THIS WEEK"
      assert html =~ "/ 80 min"
      assert html =~ "No active streak"
    end

    test "renders two goal slots always", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")

      assert html =~ "6-COUNT"
      assert html =~ "NAVY SEAL"
    end

    test "empty goal slot shows 'Set goal' button when user has no goals", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stats")

      assert html =~ "Set goal"
    end

    test "active goal slot shows progress", %{conn: conn, user: user} do
      today = Date.utc_today()

      {:ok, _goal} =
        Goals.create_goal(user, %{
          "burpee_type" => "six_count",
          "burpee_count_target" => 500,
          "duration_sec_target" => 1200,
          "date_target" => Date.add(today, 30),
          "burpee_count_baseline" => 0,
          "duration_sec_baseline" => 0,
          "date_baseline" => today
        })

      {:ok, _view, html} = live(conn, ~p"/stats")

      assert html =~ "500"
    end

    test "shows recent sessions", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "My Plan"})
      _session = session_from_plan_fixture(user, plan)

      {:ok, _view, html} = live(conn, ~p"/stats")

      assert html =~ "My Plan"
    end

    test "Show all expands session list", %{conn: conn, user: user} do
      plan = plan_fixture(user)
      # Create 12 sessions
      for _ <- 1..12, do: session_from_plan_fixture(user, plan)

      {:ok, view, _html} = live(conn, ~p"/stats")

      view |> element("button", "Show all") |> render_click()

      assert render(view) =~ "Show less"
    end

    test "FAB opens log modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stats")

      view |> element("button[phx-click='open_log_modal']") |> render_click()

      assert render(view) =~ "Log session"
    end

    test "old /history route redirects to /stats", %{conn: conn} do
      assert conn |> get("/history") |> redirected_to() == "/stats"
    end

    test "old /goals route redirects to /stats", %{conn: conn} do
      assert conn |> get("/goals") |> redirected_to() == "/stats"
    end

    test "old /log route redirects to /stats", %{conn: conn} do
      assert conn |> get("/log") |> redirected_to() == "/stats"
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Expected: failures — stub doesn't render any of this.

- [ ] **Step 3: Implement StatsLive**

Replace `lib/burpee_trainer_web/live/stats_live.ex`:

```elixir
defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Goals, Streak, Workouts}
  alias BurpeeTrainer.Goals.Goal
  alias BurpeeTrainer.Streak.State
  alias BurpeeTrainerWeb.{Fmt, Layouts}

  @session_preview 10

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    today = Date.utc_today()

    streak = Streak.compute(user, today)
    goals = Goals.list_active_goals(user)
    sessions = Workouts.list_sessions_recent(user, @session_preview)
    all_sessions = nil  # loaded on demand

    {:ok,
     socket
     |> assign(:streak, streak)
     |> assign(:today, today)
     |> assign(:goals, goals)
     |> assign(:sessions, sessions)
     |> assign(:show_all_sessions, false)
     |> assign(:all_sessions, all_sessions)
     |> assign(:show_more_trends, false)
     |> assign(:log_modal_open, false)
     |> assign(:weekly_data, Workouts.weekly_minutes(user))}
  end

  @impl true
  def handle_event("open_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, true)}
  end

  def handle_event("close_log_modal", _, socket) do
    {:noreply, assign(socket, :log_modal_open, false)}
  end

  def handle_event("show_all_sessions", _, socket) do
    all = Workouts.list_sessions_all(socket.assigns.current_user)
    {:noreply, assign(socket, show_all_sessions: true, all_sessions: all)}
  end

  def handle_event("show_less_sessions", _, socket) do
    {:noreply, assign(socket, show_all_sessions: false)}
  end

  def handle_event("toggle_trends", _, socket) do
    {:noreply, update(socket, :show_more_trends, &(!&1))}
  end

  def handle_event("session_saved", _, socket) do
    user = socket.assigns.current_user
    today = socket.assigns.today

    {:noreply,
     socket
     |> assign(:log_modal_open, false)
     |> assign(:streak, Streak.compute(user, today))
     |> assign(:sessions, Workouts.list_sessions_recent(user, @session_preview))
     |> assign(:weekly_data, Workouts.weekly_minutes(user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <div class="space-y-5 pb-20">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Stats</h1>
          <p class="text-sm text-base-content/60">How you're tracking.</p>
        </div>

        <.streak_card streak={@streak} today={@today} />

        <.goals_section goals={@goals} />

        <.sessions_section
          sessions={if @show_all_sessions, do: @all_sessions, else: @sessions}
          show_all={@show_all_sessions}
        />

        <.trends_section weekly_data={@weekly_data} show_more={@show_more_trends} />
      </div>

      <%!-- FAB --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-8 z-40">
        <button
          type="button"
          phx-click="open_log_modal"
          class="w-12 h-12 rounded-full bg-primary text-primary-content flex items-center justify-center hover:bg-primary/90 transition"
          aria-label="Log session"
        >
          <.icon name="hero-plus" class="size-6" />
        </button>
      </div>

      <%!-- Log modal --%>
      <%= if @log_modal_open do %>
        <.modal id="log-modal" show on_cancel={JS.push("close_log_modal")}>
          <.live_component
            module={BurpeeTrainerWeb.LogFormComponent}
            id="log-form"
            current_user={@current_user}
            on_save="session_saved"
          />
        </.modal>
      <% end %>
    </Layouts.app>
    """
  end

  # --- Streak card ---

  attr :streak, State, required: true
  attr :today, Date, required: true

  defp streak_card(assigns) do
    week_start = Date.beginning_of_week(assigns.today, :monday)
    days = Enum.map(0..6, fn i -> Date.add(week_start, i) end)
    assigns = assign(assigns, :week_days, days)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-5 space-y-4">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40">This week</p>

      <div class="flex items-baseline justify-between">
        <div class="tabular-nums">
          <span class="text-3xl font-semibold">{trunc(@streak.current_week_minutes)}</span>
          <span class="text-base-content/50 text-sm ml-1">/ 80 min</span>
        </div>
        <div class="text-sm text-base-content/60">
          <%= if @streak.streak_weeks == 0 do %>
            No active streak
          <% else %>
            {@streak.streak_weeks} week streak
          <% end %>
        </div>
      </div>

      <div class="h-2 rounded-full bg-[#1E2535] overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-500",
            @streak.current_week_minutes >= 80 && "bg-primary",
            @streak.current_week_minutes < 80 && @streak.on_pace? && "bg-primary/70",
            !@streak.on_pace? && "bg-base-content/20"
          ]}
          style={"width: #{min(@streak.current_week_minutes / 80 * 100, 100)}%"}
        />
      </div>

      <div class="flex justify-between">
        <%= for day <- @week_days do %>
          <div class="flex flex-col items-center gap-1">
            <span class="text-[10px] text-base-content/30">
              {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
            </span>
            <div class={[
              "w-2 h-2 rounded-full",
              day in @streak.days_active_this_week && "bg-primary",
              day == @today && day not in @streak.days_active_this_week && "border border-primary",
              day > @today && "bg-[#1E2535]",
              day < @today && day not in @streak.days_active_this_week && "bg-[#1E2535]"
            ]} />
          </div>
        <% end %>
      </div>

      <%= if @streak.streak_weeks == 0 && @streak.previous_best_weeks > 0 do %>
        <p class="text-xs text-base-content/30">
          Previous best: {@streak.previous_best_weeks} weeks
        </p>
      <% end %>
    </div>
    """
  end

  # --- Goals section ---

  attr :goals, :list, required: true

  defp goals_section(assigns) do
    six = Enum.find(assigns.goals, &(&1.burpee_type == :six_count))
    seal = Enum.find(assigns.goals, &(&1.burpee_type == :navy_seal))
    assigns = assign(assigns, six: six, seal: seal)

    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <.goal_slot burpee_type={:six_count} goal={@six} />
      <.goal_slot burpee_type={:navy_seal} goal={@seal} />
    </div>
    """
  end

  attr :burpee_type, :atom, required: true
  attr :goal, :any, required: true  # Goal.t() | nil

  defp goal_slot(assigns) do
    label = if assigns.burpee_type == :six_count, do: "6-COUNT", else: "NAVY SEAL"
    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
      <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/40">{@label}</p>

      <%= if @goal do %>
        <div class="space-y-2">
          <p class="text-sm font-medium">{@goal.burpee_count_target} burpees</p>
          <p class="text-xs text-base-content/50">by {Calendar.strftime(@goal.date_target, "%-d %b")}</p>
        </div>
      <% else %>
        <div class="space-y-2">
          <p class="text-xs text-base-content/50">No goal set</p>
          <.link
            navigate={~p"/goals"}
            class="text-xs text-primary hover:underline"
          >
            Set goal
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Sessions section ---

  attr :sessions, :list, required: true
  attr :show_all, :boolean, required: true

  defp sessions_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">Sessions</h2>
        <%= if @show_all do %>
          <button phx-click="show_less_sessions" class="text-xs text-primary hover:underline">
            Show less
          </button>
        <% else %>
          <button phx-click="show_all_sessions" class="text-xs text-primary hover:underline">
            Show all
          </button>
        <% end %>
      </div>

      <%= if @sessions == [] || @sessions == nil do %>
        <p class="text-sm text-base-content/40">No sessions yet.</p>
      <% else %>
        <div class="space-y-2">
          <%= for session <- (@sessions || []) do %>
            <.session_row session={session} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :session, :any, required: true

  defp session_row(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 px-4 py-3 space-y-1">
      <div class="flex items-center justify-between text-sm">
        <span class="text-base-content/50 text-xs">
          {Calendar.strftime(DateTime.to_date(@session.inserted_at), "%-d %b")}
        </span>
        <div class="flex gap-3 tabular-nums text-xs">
          <%= if @session.duration_sec_actual do %>
            <span>{Fmt.duration_sec(@session.duration_sec_actual)}</span>
          <% end %>
          <%= if @session.burpee_count_actual do %>
            <span>{@session.burpee_count_actual} burpees</span>
          <% end %>
        </div>
      </div>
      <p class="text-sm font-medium">
        <%= if @session.plan do %>
          {@session.plan.name}
        <% else %>
          <span class="text-base-content/50">Logged manually</span>
        <% end %>
      </p>
    </div>
    """
  end

  # --- Trends section ---

  attr :weekly_data, :list, required: true
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
        <.volume_chart weekly_data={@weekly_data} />
      <% end %>
    </div>
    """
  end

  attr :weekly_data, :list, required: true

  defp weekly_minutes_chart(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">Weekly minutes</p>
      <svg viewBox="0 0 300 80" class="w-full" aria-hidden="true">
        <%= for {week, i} <- Enum.with_index(Enum.take(Enum.reverse(@weekly_data), 12)) do %>
          <%
            bar_width = 18
            gap = 7
            x = i * (bar_width + gap)
            max_min = 120
            height = min(week.minutes / max_min * 70, 70)
            y = 75 - height
            color = if week.met_goal, do: "#4A9EFF", else: "#2A3A4E"
          %>
          <rect x={x} y={y} width={bar_width} height={height} fill={color} rx="2" />
        <% end %>
        <%!-- 80-min goal line --%>
        <line x1="0" y1={75 - 80/120 * 70} x2="300" y2={75 - 80/120 * 70}
              stroke="#3A4A5E" stroke-width="0.5" stroke-dasharray="3,3" />
      </svg>
    </div>
    """
  end

  attr :weekly_data, :list, required: true

  defp volume_chart(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4">
      <p class="text-xs text-base-content/40 mb-3 uppercase tracking-wide">Volume over time</p>
      <p class="text-xs text-base-content/30 italic">Chart coming in a follow-up — needs per-type session data.</p>
    </div>
    """
  end
end
```

Note: The `LogFormComponent` referenced in the modal doesn't exist yet — see Task 6.

Also: `GoalsLive` is referenced by the `Set goal` link (navigates to `/goals`). Since `/goals` now redirects to `/stats`, this will loop. For now, the "Set goal" link navigates to `/goals` — update it in a follow-up to open an inline form. For v1, the redirect keeps the user on Stats which is acceptable.

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer_web/live/stats_live_test.exs
```

Fix failures. Common issues: `LogFormComponent` not defined (stub it), missing `Streak.State` struct accessor.

- [ ] **Step 5: Run precommit**

```bash
mix precommit
```

- [ ] **Step 6: Commit**

```
jj describe -m "feat: implement StatsLive with streak, goals, sessions, trends" && jj new
```

---

## Task 6: LogFormComponent — extract LogLive into a component

**Files:**
- Create: `lib/burpee_trainer_web/live/log_form_component.ex`
- Modify: `lib/burpee_trainer_web/live/log_live.ex` (delegate to component)

The log form logic needs to work both as a standalone page (`/log` redirects to `/stats`) and as a modal inside StatsLive. Extract it into a `LiveComponent`.

- [ ] **Step 1: Create the component**

Create `lib/burpee_trainer_web/live/log_form_component.ex`:

```elixir
defmodule BurpeeTrainerWeb.LogFormComponent do
  use BurpeeTrainerWeb, :live_component

  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.Workouts.WorkoutSession

  @mood_options [
    {"hero-face-frown", "Tired", -1},
    {"hero-minus-circle", "OK", 0},
    {"hero-bolt", "Hyped", 1}
  ]
  @tag_options ~w[tired great_energy bad_sleep sick travel hot]

  @impl true
  def mount(socket) do
    {:ok, build_form(socket)}
  end

  defp build_form(socket) do
    changeset = Workouts.change_free_form_session(%WorkoutSession{})

    assign(socket,
      form: to_form(changeset),
      date: Date.utc_today(),
      duration_min: "",
      mood: 0,
      log_tags: [],
      mood_options: @mood_options,
      tag_options: @tag_options
    )
  end

  @impl true
  def handle_event("set_mood", %{"mood" => mood_str}, socket) do
    mood =
      case Integer.parse(mood_str) do
        {m, ""} when m in [-1, 0, 1] -> m
        _ -> socket.assigns.mood
      end

    {:noreply, assign(socket, :mood, mood)}
  end

  def handle_event("toggle_tag", %{"tag" => tag}, socket) do
    tags = socket.assigns.log_tags

    new_tags =
      if tag in tags, do: List.delete(tags, tag), else: [tag | tags]

    {:noreply, assign(socket, :log_tags, new_tags)}
  end

  def handle_event("save", %{"workout_session" => params}, socket) do
    user = socket.assigns.current_user
    tags_str = socket.assigns.log_tags |> Enum.sort() |> Enum.join(",")

    full_params =
      params
      |> Map.put("mood", to_string(socket.assigns.mood))
      |> Map.put("tags", tags_str)

    case Workouts.create_free_form_session(user, full_params) do
      {:ok, _session} ->
        send(self(), {socket.assigns.on_save})
        {:noreply, build_form(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2 class="text-lg font-semibold mb-4">Log session</h2>
      <.form for={@form} id={"log-form-#{@id}"} phx-submit="save" phx-target={@myself} class="space-y-4">
        <.input field={@form[:burpee_type]} type="select"
          label="Burpee type"
          options={[{"6-Count", "six_count"}, {"Navy SEAL", "navy_seal"}]} />
        <.input field={@form[:burpee_count_actual]} type="number" label="Burpees done" min="0" />
        <.input field={@form[:duration_sec_actual]} type="number" label="Duration (seconds)" min="0" />

        <div class="flex gap-3">
          <%= for {icon, label, val} <- @mood_options do %>
            <button
              type="button"
              phx-click="set_mood"
              phx-value-mood={val}
              phx-target={@myself}
              class={[
                "flex-1 flex flex-col items-center gap-1 rounded-lg border py-2 text-xs transition",
                @mood == val && "border-primary text-primary bg-primary/10",
                @mood != val && "border-base-300 text-base-content/50"
              ]}
            >
              <.icon name={icon} class="size-5" />
              {label}
            </button>
          <% end %>
        </div>

        <div class="flex flex-wrap gap-2">
          <%= for tag <- @tag_options do %>
            <button
              type="button"
              phx-click="toggle_tag"
              phx-value-tag={tag}
              phx-target={@myself}
              class={[
                "rounded-full px-3 py-1 text-xs border transition",
                tag in @log_tags && "border-primary text-primary bg-primary/10",
                tag not in @log_tags && "border-base-300 text-base-content/50"
              ]}
            >
              {String.replace(tag, "_", " ")}
            </button>
          <% end %>
        </div>

        <button type="submit"
          class="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-content hover:bg-primary/90 transition">
          Save session
        </button>
      </.form>
    </div>
    """
  end
end
```

Note: `send(self(), {socket.assigns.on_save})` sends the atom as a message. In `StatsLive`, add a `handle_info` clause:

```elixir
@impl true
def handle_info(:session_saved, socket) do
  # same as handle_event("session_saved", ...)
  user = socket.assigns.current_user
  today = socket.assigns.today

  {:noreply,
   socket
   |> assign(:log_modal_open, false)
   |> assign(:streak, Streak.compute(user, today))
   |> assign(:sessions, Workouts.list_sessions_recent(user, @session_preview))
   |> assign(:weekly_data, Workouts.weekly_minutes(user))}
end
```

Update the `live_component` call in `StatsLive.render/1` to pass `on_save: :session_saved`.

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

- [ ] **Step 3: Commit**

```
jj describe -m "feat: extract LogFormComponent for reuse in StatsLive modal" && jj new
```

---

## Task 7: Delete retired modules

**Files:**
- Delete: `lib/burpee_trainer_web/live/goals_live.ex`
- Delete: `lib/burpee_trainer_web/live/history_live.ex`
- Delete: `test/burpee_trainer_web/live/goals_live_test.exs`
- Delete: `test/burpee_trainer_web/live/history_live_test.exs`

- [ ] **Step 1: Delete files**

```bash
rm lib/burpee_trainer_web/live/goals_live.ex
rm lib/burpee_trainer_web/live/history_live.ex
rm test/burpee_trainer_web/live/goals_live_test.exs
rm test/burpee_trainer_web/live/history_live_test.exs
```

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

Expected: passes. The router no longer references these modules (redirects handle `/goals` and `/history`).

- [ ] **Step 3: Commit**

```
jj describe -m "refactor: delete retired GoalsLive and HistoryLive" && jj new
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| Stats screen renders streak card as top section | Task 5 |
| Minutes, target 80, progress bar, day strip, streak count | Task 5 |
| Progress bar colour: on-pace vs behind vs complete | Task 5 |
| Day strip fills dots for active days | Task 5 (via `Streak.State.days_active_this_week`) |
| Streak resets on new week with < 80 min | Task 3 |
| Previous-best line when streak = 0 and best > 0 | Task 5 |
| Two goal slots, always rendered | Task 5 |
| Empty slot (no sessions of type): muted copy | Task 5 (simplified — shows "Set goal" for both) |
| Replace confirmation for occupied slot | Not implemented — `Set goal` link goes to `/goals` redirect. Deferred to follow-up. |
| Recent sessions, last 10, Show all expands | Task 5 |
| 2 charts default, Show more reveals up to 5 | Task 5 (volume chart is a placeholder — needs per-type session query) |
| All charts server-rendered SVG | Task 5 (weekly minutes chart done; volume chart is a placeholder) |
| FAB opens log modal, saving updates streak + sessions | Task 5 + Task 6 |
| Property test: Streak.compute matches naive reference | Task 3 |
| HistoryLive retired | Task 7 |
| GoalsLive retired | Task 7 |

**Known deferred items:**
1. Volume chart needs per-type session aggregation — placeholder in place.
2. Empty goal slot distinguishes "no sessions of this type" vs "sessions exist but no goal" — simplified to a single empty state in v1.
3. Goal replace confirmation — deferred; `Set goal` links to `/goals` (which redirects to `/stats`, creating a loop). Wire up inline goal form in follow-up.

**Placeholder scan:** Volume chart body is an explicit placeholder with a note. All other steps have real code.

**Type consistency:** `Streak.State` struct used consistently in Tasks 3 and 5. `Workouts.list_sessions_recent/2` and `list_sessions_all/1` defined in Task 4, called in Task 5. `LogFormComponent` defined in Task 6, referenced in Task 5 — ensure Task 6 is done before running Task 5 tests end-to-end.
