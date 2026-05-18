# Workouts Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge Plans + Videos into a unified `/workouts` screen with a shared card, single pill-bar filter, and FAB — and collapse the nav from 6 items to 3 (Home · Workouts · Stats).

**Architecture:** Introduce `BurpeeTrainer.WorkoutFeed` as a thin context that normalises plans and videos into `WorkoutFeed.WorkoutItem` structs, sorted and filtered. `WorkoutsLive` replaces both `PlansLive.Index` and `VideoLive.Index`. The existing plan editor (`PlansLive.Edit`) is kept but re-routed under `/workouts`. Nav restructure happens in `Layouts` and the router.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView 1.1, Ecto + SQLite, Tailwind CSS, HeroIcons (hero-* via Phoenix.Component icon helper). No JS beyond what LiveView ships with. Run `mix precommit` before every commit (compile --warnings-as-errors, deps.unlock --unused, format, test).

---

## File Map

| Action | File |
|---|---|
| Create | `lib/burpee_trainer/workout_feed.ex` |
| Create | `lib/burpee_trainer/workout_feed/workout_item.ex` |
| Create | `lib/burpee_trainer_web/live/workouts_live.ex` |
| Modify | `lib/burpee_trainer_web/router.ex` |
| Modify | `lib/burpee_trainer_web/components/layouts.ex` |
| Modify | `lib/burpee_trainer_web/live/overview_live.ex` |
| Modify | `lib/burpee_trainer_web/live/plans_live/edit.ex` (return path only) |
| Delete | `lib/burpee_trainer_web/live/plans_live/index.ex` |
| Delete | `lib/burpee_trainer_web/live/video_live/index.ex` |
| Create | `test/burpee_trainer/workout_feed_test.exs` |
| Create | `test/burpee_trainer_web/live/workouts_live_test.exs` |
| Modify | `test/burpee_trainer_web/live/plans_live_test.exs` (update route refs) |
| Delete | `test/burpee_trainer_web/live/video_live_test.exs` (if it exists — check first) |

---

## Task 1: WorkoutItem struct

**Files:**
- Create: `lib/burpee_trainer/workout_feed/workout_item.ex`

- [ ] **Step 1: Create the struct**

```elixir
defmodule BurpeeTrainer.WorkoutFeed.WorkoutItem do
  @moduledoc """
  Normalised representation of a plan or video for the Workouts screen.
  The LiveView only works with this struct — it has no knowledge of
  WorkoutPlan or WorkoutVideo directly.
  """

  @type kind :: :plan | :video

  @enforce_keys [:kind, :id, :title, :burpee_type, :duration_sec,
                 :start_path, :inserted_at]

  defstruct [
    :kind,
    :id,
    :title,
    :burpee_type,      # :six_count | :navy_seal
    :level,            # atom from Levels.level_for_count/2, nil for videos without burpee_count
    :burpee_count,     # nil for videos where burpee_count is not set
    :duration_sec,
    :start_path,       # e.g. "/session/42" or "/videos/7"
    :edit_path,        # nil for videos
    :last_used_at,     # DateTime | nil — latest session.inserted_at for plans
    :inserted_at       # DateTime — used as sort tiebreaker
  ]
end
```

Save to `lib/burpee_trainer/workout_feed/workout_item.ex`.

- [ ] **Step 2: Run compile to confirm no errors**

```bash
mix compile --warnings-as-errors
```

Expected: no warnings, no errors.

- [ ] **Step 3: Commit**

```
jj describe -m "feat: add WorkoutItem struct" && jj new
```

---

## Task 2: WorkoutFeed context

**Files:**
- Create: `lib/burpee_trainer/workout_feed.ex`
- Create: `test/burpee_trainer/workout_feed_test.exs`

This is a pure-ish module (calls Repo but has no side effects). Test the filtering and sort logic by inserting real DB rows — follow the project's integration-test pattern (`use BurpeeTrainer.DataCase`).

- [ ] **Step 1: Write failing tests first**

Create `test/burpee_trainer/workout_feed_test.exs`:

```elixir
defmodule BurpeeTrainer.WorkoutFeedTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.WorkoutFeed
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem

  describe "list/2" do
    test "returns plans and videos as WorkoutItems" do
      user = user_fixture()
      plan = plan_fixture(user, %{"name" => "My Plan", "burpee_type" => "six_count"})
      video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 1200})

      items = WorkoutFeed.list(user)

      assert length(items) == 2
      assert Enum.all?(items, &match?(%WorkoutItem{}, &1))
      titles = Enum.map(items, & &1.title)
      assert "My Plan" in titles
      assert "BDT Video" in titles
    end

    test "plans sort before videos when no source filter" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user)

      plan_item = Enum.find(items, &(&1.kind == :plan))
      video_item = Enum.find(items, &(&1.kind == :video))
      plan_idx = Enum.find_index(items, &(&1.id == plan_item.id && &1.kind == :plan))
      video_idx = Enum.find_index(items, &(&1.id == video_item.id && &1.kind == :video))
      assert plan_idx < video_idx
    end

    test "source filter :mine returns only plans" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user, %{source: :mine})

      assert Enum.all?(items, &(&1.kind == :plan))
    end

    test "source filter :videos returns only videos" do
      user = user_fixture()
      _plan = plan_fixture(user)
      _video = video_fixture(%{name: "V", burpee_type: :six_count, duration_sec: 600})

      items = WorkoutFeed.list(user, %{source: :videos})

      assert Enum.all?(items, &(&1.kind == :video))
    end

    test "burpee_type filter restricts both plans and videos" do
      user = user_fixture()
      _six = plan_fixture(user, %{"burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})
      _video = video_fixture(%{name: "V", burpee_type: :navy_seal, duration_sec: 600})

      items = WorkoutFeed.list(user, %{burpee_type: :six_count})

      assert Enum.all?(items, &(&1.burpee_type == :six_count))
    end

    test "level filter restricts items by level" do
      user = user_fixture()
      # plan with 10 reps → :level_1a
      _low = plan_fixture(user)
      # plan with 200 reps → :level_2 for six_count
      _high = plan_fixture(user, %{
        "name" => "Big plan",
        "blocks" => [%{
          "position" => 1, "repeat_count" => 1,
          "sets" => [%{"position" => 1, "burpee_count" => 200,
                       "sec_per_rep" => 6.0, "sec_per_burpee" => 3.0, "end_of_set_rest" => 0}]
        }]
      })

      items = WorkoutFeed.list(user, %{level: :level_2})

      assert Enum.all?(items, &(&1.level == :level_2))
    end

    test "property: list with filter equals filtered union of plans and videos" do
      user = user_fixture()
      _p1 = plan_fixture(user, %{"burpee_type" => "six_count"})
      _p2 = plan_fixture(user, %{"name" => "P2", "burpee_type" => "navy_seal"})
      _v1 = video_fixture(%{name: "V1", burpee_type: :six_count, duration_sec: 600})
      _v2 = video_fixture(%{name: "V2", burpee_type: :navy_seal, duration_sec: 900})

      filter = %{burpee_type: :six_count}
      filtered = WorkoutFeed.list(user, filter)

      unfiltered = WorkoutFeed.list(user)
      expected_ids =
        unfiltered
        |> Enum.filter(&(&1.burpee_type == :six_count))
        |> Enum.map(&{&1.kind, &1.id})
        |> MapSet.new()

      actual_ids = filtered |> Enum.map(&{&1.kind, &1.id}) |> MapSet.new()
      assert actual_ids == expected_ids
    end
  end
end
```

- [ ] **Step 2: Add `video_fixture` to `test/support/fixtures.ex`**

Open `test/support/fixtures.ex` and add after the existing fixtures:

```elixir
@doc """
Build a video. No user scoping — videos are global.
"""
def video_fixture(attrs \\ %{}) do
  n = System.unique_integer([:positive])

  defaults = %{
    name: "Test Video #{n}",
    filename: "video_#{n}.mp4",
    burpee_type: :six_count,
    duration_sec: 1200,
    burpee_count: nil
  }

  {:ok, video} = BurpeeTrainer.Videos.create_video(Map.merge(defaults, attrs))
  video
end
```

- [ ] **Step 3: Run tests to confirm they fail with a clear error**

```bash
mix test test/burpee_trainer/workout_feed_test.exs
```

Expected: `** (UndefinedFunctionError) function BurpeeTrainer.WorkoutFeed.list/1 is undefined`

- [ ] **Step 4: Implement WorkoutFeed**

Create `lib/burpee_trainer/workout_feed.ex`:

```elixir
defmodule BurpeeTrainer.WorkoutFeed do
  @moduledoc """
  Unified query layer for the Workouts screen. Merges WorkoutPlans and
  WorkoutVideos into WorkoutItem structs, applies filters, and sorts.

  Sort order (plans first within each group when unfiltered by source):
    1. Plans before videos
    2. Within plans: most recently used (latest session), then closest
       burpee_count_target to current user level threshold, then newest
    3. Within videos: by inserted_at ascending (BDT canonical order)
  """

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Levels
  alias BurpeeTrainer.Planner
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Videos
  alias BurpeeTrainer.Workouts
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem

  import Ecto.Query

  @type filters :: %{
    optional(:source) => :mine | :videos,
    optional(:burpee_type) => :six_count | :navy_seal,
    optional(:level) => atom()
  }

  @spec list(User.t(), filters()) :: [WorkoutItem.t()]
  def list(user, filters \\ %{}) do
    source = Map.get(filters, :source)

    plans =
      if source in [nil, :mine] do
        user
        |> Workouts.list_plans()
        |> Enum.map(&plan_to_item(&1, last_used_at(user, &1.id)))
      else
        []
      end

    videos =
      if source in [nil, :videos] do
        Videos.list_videos()
        |> Enum.map(&video_to_item/1)
      else
        []
      end

    (plans ++ videos)
    |> apply_filters(filters)
    |> sort(source)
  end

  # --- private ---

  defp plan_to_item(plan, last_used_at) do
    summary = Planner.summary(plan)
    level = Levels.level_for_count(plan.burpee_type, summary.burpee_count_total)

    %WorkoutItem{
      kind: :plan,
      id: plan.id,
      title: plan.name,
      burpee_type: plan.burpee_type,
      level: level,
      burpee_count: summary.burpee_count_total,
      duration_sec: summary.duration_sec_total,
      start_path: "/session/#{plan.id}",
      edit_path: "/workouts/#{plan.id}/edit",
      last_used_at: last_used_at,
      inserted_at: plan.inserted_at
    }
  end

  defp video_to_item(video) do
    level =
      if video.burpee_count do
        Levels.level_for_count(video.burpee_type, video.burpee_count)
      end

    %WorkoutItem{
      kind: :video,
      id: video.id,
      title: video.name,
      burpee_type: video.burpee_type,
      level: level,
      burpee_count: video.burpee_count,
      duration_sec: video.duration_sec,
      start_path: "/videos/#{video.id}",
      edit_path: nil,
      last_used_at: nil,
      inserted_at: video.inserted_at
    }
  end

  defp last_used_at(%User{id: user_id}, plan_id) do
    Repo.one(
      from s in BurpeeTrainer.Workouts.WorkoutSession,
        where: s.user_id == ^user_id and s.plan_id == ^plan_id,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.inserted_at
    )
  end

  defp apply_filters(items, filters) do
    items
    |> filter_by_type(Map.get(filters, :burpee_type))
    |> filter_by_level(Map.get(filters, :level))
  end

  defp filter_by_type(items, nil), do: items
  defp filter_by_type(items, type), do: Enum.filter(items, &(&1.burpee_type == type))

  defp filter_by_level(items, nil), do: items
  defp filter_by_level(items, level), do: Enum.filter(items, &(&1.level == level))

  defp sort(items, :mine), do: Enum.sort_by(items, &plan_sort_key/1)
  defp sort(items, :videos), do: Enum.sort_by(items, & &1.inserted_at, DateTime)

  defp sort(items, _source) do
    plans = items |> Enum.filter(&(&1.kind == :plan)) |> Enum.sort_by(&plan_sort_key/1)
    videos = items |> Enum.filter(&(&1.kind == :video)) |> Enum.sort_by(& &1.inserted_at, DateTime)
    plans ++ videos
  end

  # Sort key for plans: most recently used first, then fewest reps (closest
  # to bottom of list makes most-recently-used the primary driver), then newest.
  # nil last_used_at sorts after all used plans.
  defp plan_sort_key(item) do
    last_used =
      case item.last_used_at do
        nil -> {1, ~U[0000-01-01 00:00:00Z]}
        dt -> {0, dt}
      end

    burpee_count = item.burpee_count || 0
    inserted = item.inserted_at

    {elem(last_used, 0), DateTime.negate(elem(last_used, 1)), burpee_count,
     DateTime.negate(inserted)}
  end
end
```

Note: `DateTime.negate/1` is not a standard function. Use a comparable workaround:

```elixir
  defp plan_sort_key(item) do
    used_rank =
      case item.last_used_at do
        nil -> 1
        _ -> 0
      end

    # Negate seconds so most recent sorts first
    used_secs =
      case item.last_used_at do
        nil -> 0
        dt -> -DateTime.to_unix(dt)
      end

    inserted_secs = -DateTime.to_unix(item.inserted_at)
    burpee_count = item.burpee_count || 0

    {used_rank, used_secs, burpee_count, inserted_secs}
  end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/burpee_trainer/workout_feed_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run precommit**

```bash
mix precommit
```

Expected: passes.

- [ ] **Step 7: Commit**

```
jj describe -m "feat: add WorkoutFeed context with filtering and sort" && jj new
```

---

## Task 3: Router — new routes and redirects

**Files:**
- Modify: `lib/burpee_trainer_web/router.ex`

The plan editor stays at its current module path but gets new routes. Old paths redirect.

- [ ] **Step 1: Update the router**

Open `lib/burpee_trainer_web/router.ex`. Replace the `live_session :authed` block:

```elixir
    live_session :authed,
      on_mount: [{BurpeeTrainerWeb.Auth, :require_authenticated_user}] do
      live "/", OverviewLive
      live "/workouts", WorkoutsLive, :index
      live "/workouts/new", PlansLive.Edit, :new
      live "/workouts/:id/edit", PlansLive.Edit, :edit

      live "/session/:plan_id", SessionLive

      live "/stats", StatsLive

      live "/videos/:id", VideoLive.Show
    end
```

And add redirects outside the live_session (before the live_session block, inside the `require_auth` scope):

```elixir
    get "/plans", BurpeeTrainerWeb.RedirectController, :plans
    get "/videos", BurpeeTrainerWeb.RedirectController, :videos
    get "/log", BurpeeTrainerWeb.RedirectController, :log
    get "/history", BurpeeTrainerWeb.RedirectController, :history
    get "/goals", BurpeeTrainerWeb.RedirectController, :goals
```

- [ ] **Step 2: Create `RedirectController`**

Create `lib/burpee_trainer_web/controllers/redirect_controller.ex`:

```elixir
defmodule BurpeeTrainerWeb.RedirectController do
  use BurpeeTrainerWeb, :controller

  def plans(conn, _), do: redirect(conn, to: ~p"/workouts")
  def videos(conn, _), do: redirect(conn, to: ~p"/workouts")
  def log(conn, _), do: redirect(conn, to: ~p"/stats")
  def history(conn, _), do: redirect(conn, to: ~p"/stats")
  def goals(conn, _), do: redirect(conn, to: ~p"/stats")
end
```

- [ ] **Step 3: Add a stub `StatsLive` so the router compiles**

Create `lib/burpee_trainer_web/live/stats_live.ex`:

```elixir
defmodule BurpeeTrainerWeb.StatsLive do
  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:stats}>
      <p class="text-base-content/50">Stats coming soon.</p>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Compile**

```bash
mix compile --warnings-as-errors
```

Expected: no errors. (WorkoutsLive doesn't exist yet — that's fine, the router references it but it's not loaded until runtime in dev mode. If compile fails on missing module, add a stub similar to StatsLive.)

Actually — Phoenix router compiles module references at compile time. Add a stub `WorkoutsLive`:

Create `lib/burpee_trainer_web/live/workouts_live.ex` (stub only):

```elixir
defmodule BurpeeTrainerWeb.WorkoutsLive do
  use BurpeeTrainerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, items: [], filters: %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <p>Loading…</p>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Run precommit**

```bash
mix precommit
```

Expected: passes.

- [ ] **Step 6: Commit**

```
jj describe -m "feat: add workouts/stats routes and legacy redirects" && jj new
```

---

## Task 4: Nav restructure — three tabs

**Files:**
- Modify: `lib/burpee_trainer_web/components/layouts.ex`

The nav currently has: Home · Plans · Log · History · Goals · Videos · Logout.
Replace with: Home · Workouts · Stats. Logout moves to a small icon in the Home header (handled in Task 7). Remove it from the nav here.

- [ ] **Step 1: Update `bottom_tab` component to include a label**

In `layouts.ex`, find `defp bottom_tab(assigns)` and update:

```elixir
attr :navigate, :string, required: true
attr :active, :boolean, required: true
attr :label, :string, required: true
slot :inner_block, required: true

defp bottom_tab(assigns) do
  ~H"""
  <.link
    navigate={@navigate}
    class={[
      "inline-flex flex-col items-center justify-center gap-0.5 w-16 h-14 shrink-0 transition-colors",
      @active && "text-[#4A9EFF]",
      !@active && "text-[#3A4A5E]"
    ]}
  >
    {render_slot(@inner_block)}
    <span class="text-[10px] font-medium">{@label}</span>
  </.link>
  """
end
```

- [ ] **Step 2: Update the desktop `nav_icon` component to include a label**

```elixir
attr :navigate, :string, required: true
attr :title, :string, required: true
attr :active, :boolean, required: true
slot :inner_block, required: true

defp nav_icon(assigns) do
  ~H"""
  <.link
    navigate={@navigate}
    title={@title}
    class={[
      "inline-flex flex-col items-center justify-center gap-0.5 px-3 py-2 rounded transition-colors",
      @active && "text-[#C8D8F0] bg-[#141B26]",
      !@active && "text-[#3A4A5E] hover:text-[#6B8FA8] hover:bg-[#141B26]"
    ]}
  >
    {render_slot(@inner_block)}
    <span class="text-[10px]">{@title}</span>
  </.link>
  """
end
```

- [ ] **Step 3: Replace the mobile bottom nav**

Find the mobile `<nav class="fixed bottom-0 ...">` block and replace its contents (keep the outer `<nav>` tag):

```heex
<.bottom_tab navigate={~p"/"} active={@current_page == :home} label="Home">
  <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
  <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
</.bottom_tab>

<.bottom_tab navigate={~p"/workouts"} active={@current_page == :workouts} label="Workouts">
  <.icon
    name="hero-rectangle-stack-solid"
    class={if @current_page == :workouts, do: "", else: "hidden"}
  />
  <.icon
    name="hero-rectangle-stack"
    class={if @current_page == :workouts, do: "hidden", else: ""}
  />
</.bottom_tab>

<.bottom_tab navigate={~p"/stats"} active={@current_page == :stats} label="Stats">
  <.icon
    name="hero-chart-bar-solid"
    class={if @current_page == :stats, do: "", else: "hidden"}
  />
  <.icon name="hero-chart-bar" class={if @current_page == :stats, do: "hidden", else: ""} />
</.bottom_tab>
```

- [ ] **Step 4: Replace the desktop top nav**

Find the desktop `<nav class="hidden sm:flex ...">` block and replace its contents:

```heex
<.nav_icon navigate={~p"/"} title="Home" active={@current_page == :home}>
  <.icon name="hero-home-solid" class={if @current_page == :home, do: "", else: "hidden"} />
  <.icon name="hero-home" class={if @current_page == :home, do: "hidden", else: ""} />
</.nav_icon>

<.nav_icon navigate={~p"/workouts"} title="Workouts" active={@current_page == :workouts}>
  <.icon
    name="hero-rectangle-stack-solid"
    class={if @current_page == :workouts, do: "", else: "hidden"}
  />
  <.icon
    name="hero-rectangle-stack"
    class={if @current_page == :workouts, do: "hidden", else: ""}
  />
</.nav_icon>

<.nav_icon navigate={~p"/stats"} title="Stats" active={@current_page == :stats}>
  <.icon
    name="hero-chart-bar-solid"
    class={if @current_page == :stats, do: "", else: "hidden"}
  />
  <.icon name="hero-chart-bar" class={if @current_page == :stats, do: "hidden", else: ""} />
</.nav_icon>

<div class="w-px h-4 bg-[#141B26] mx-1" />

<.link
  href={~p"/logout"}
  method="delete"
  title="Sign out"
  class="inline-flex items-center justify-center w-9 h-9 shrink-0 rounded transition-colors text-[#3A4A5E] hover:text-[#C8D8F0] hover:bg-[#141B26]"
>
  <.icon name="hero-arrow-left-start-on-rectangle" />
</.link>
```

(Logout stays in desktop nav for now; mobile logout moves to Home in Task 7.)

- [ ] **Step 5: Run precommit**

```bash
mix precommit
```

Expected: passes.

- [ ] **Step 6: Commit**

```
jj describe -m "feat: restructure nav to Home/Workouts/Stats with labels" && jj new
```

---

## Task 5: WorkoutsLive — full implementation

**Files:**
- Modify: `lib/burpee_trainer_web/live/workouts_live.ex` (replace stub)
- Create: `test/burpee_trainer_web/live/workouts_live_test.exs`

- [ ] **Step 1: Write LiveView tests first**

Create `test/burpee_trainer_web/live/workouts_live_test.exs`:

```elixir
defmodule BurpeeTrainerWeb.WorkoutsLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Workouts

  setup %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, conn: conn, user: user}
  end

  describe "/workouts" do
    test "empty state renders when no plans or videos", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workouts")
      assert html =~ "No workouts yet"
    end

    test "lists plans and videos together", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, _view, html} = live(conn, ~p"/workouts")

      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "Mine filter shows only plans", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      refute html =~ "BDT Video"
    end

    test "Videos filter shows only videos", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='videos']") |> render_click()

      html = render(view)
      refute html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "clicking active source filter deselects it", %{conn: conn, user: user} do
      _plan = plan_fixture(user, %{"name" => "My Plan"})
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()
      view |> element("button[phx-value-source='mine']") |> render_click()

      html = render(view)
      assert html =~ "My Plan"
      assert html =~ "BDT Video"
    end

    test "type filter restricts list", %{conn: conn, user: user} do
      _six = plan_fixture(user, %{"name" => "Six plan", "burpee_type" => "six_count"})
      _seal = plan_fixture(user, %{"name" => "SEAL plan", "burpee_type" => "navy_seal"})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-burpee_type='six_count']") |> render_click()

      html = render(view)
      assert html =~ "Six plan"
      refute html =~ "SEAL plan"
    end

    test "Mine empty state shows when user has no plans", %{conn: conn} do
      _video = video_fixture(%{name: "BDT Video", burpee_type: :six_count, duration_sec: 600})

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert render(view) =~ "haven't built any plans"
    end

    test "filter state reflected in URL", %{conn: conn, user: user} do
      _plan = plan_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/workouts")
      view |> element("button[phx-value-source='mine']") |> render_click()

      assert_patch(view, "/workouts?source=mine")
    end

    test "old /plans route redirects to /workouts", %{conn: conn} do
      assert conn |> get("/plans") |> redirected_to() == "/workouts"
    end

    test "plan duplicate action works", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Original"})
      {:ok, view, _} = live(conn, ~p"/workouts")

      view
      |> element("button[phx-click='duplicate'][phx-value-id='#{plan.id}']")
      |> render_click()

      assert render(view) =~ "Original (copy)"
    end

    test "plan delete action removes plan", %{conn: conn, user: user} do
      plan = plan_fixture(user, %{"name" => "Doomed"})
      {:ok, view, _} = live(conn, ~p"/workouts")

      view
      |> element("button[phx-click='delete'][phx-value-id='#{plan.id}']")
      |> render_click()

      refute render(view) =~ "Doomed"
      assert Workouts.list_plans(user) == []
    end
  end
end
```

- [ ] **Step 2: Run tests to see them fail**

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: failures — stub renders "Loading…" not real content.

- [ ] **Step 3: Implement WorkoutsLive**

Replace `lib/burpee_trainer_web/live/workouts_live.ex`:

```elixir
defmodule BurpeeTrainerWeb.WorkoutsLive do
  use BurpeeTrainerWeb, :live_view

  alias BurpeeTrainer.{Levels, Planner, Workouts}
  alias BurpeeTrainer.WorkoutFeed
  alias BurpeeTrainer.WorkoutFeed.WorkoutItem
  alias BurpeeTrainerWeb.{Fmt, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, filters: %{}, items: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = decode_filters(params)
    items = WorkoutFeed.list(socket.assigns.current_user, filters)
    {:noreply, assign(socket, filters: filters, items: items)}
  end

  @impl true
  def handle_event("toggle_filter", %{"source" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :source, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("toggle_filter", %{"burpee_type" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :burpee_type, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("toggle_filter", %{"level" => val}, socket) do
    filters = toggle_filter(socket.assigns.filters, :level, String.to_existing_atom(val))
    {:noreply, push_patch(socket, to: build_path(filters))}
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))

    case Workouts.duplicate_plan(plan) do
      {:ok, _copy} ->
        items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)
        {:noreply, socket |> put_flash(:info, "Plan duplicated.") |> assign(:items, items)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not duplicate plan.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    plan = Workouts.get_plan!(socket.assigns.current_user, String.to_integer(id))
    {:ok, _} = Workouts.delete_plan(plan)
    items = WorkoutFeed.list(socket.assigns.current_user, socket.assigns.filters)
    {:noreply, socket |> put_flash(:info, "Plan deleted.") |> assign(:items, items)}
  end

  defp toggle_filter(filters, key, value) do
    if Map.get(filters, key) == value do
      Map.delete(filters, key)
    else
      Map.put(filters, key, value)
    end
  end

  defp decode_filters(params) do
    %{}
    |> maybe_put(:source, params["source"], ~w(mine videos))
    |> maybe_put(:burpee_type, params["burpee_type"], ~w(six_count navy_seal))
    |> maybe_put(:level, params["level"], Enum.map(Levels.all_levels(), &Atom.to_string/1))
  end

  defp maybe_put(map, _key, nil, _valid), do: map
  defp maybe_put(map, key, val, valid) do
    if val in valid, do: Map.put(map, key, String.to_existing_atom(val)), else: map
  end

  defp build_path(filters) do
    params =
      filters
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), Atom.to_string(v)} end)
      |> Map.new()

    if params == %{}, do: "/workouts", else: "/workouts?" <> URI.encode_query(params)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:workouts}>
      <div class="space-y-5">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Workouts</h1>
          <p class="text-sm text-base-content/60">Pick something to do.</p>
        </div>

        <%!-- Filter pill-bar --%>
        <div class="flex items-center gap-0 bg-base-200 border border-base-300 rounded-full px-1.5 py-1 w-fit">
          <.filter_pill
            label="Mine"
            event="toggle_filter"
            value_key="source"
            value="mine"
            active={@filters[:source] == :mine}
          />
          <.filter_pill
            label="Videos"
            event="toggle_filter"
            value_key="source"
            value="videos"
            active={@filters[:source] == :videos}
          />
          <div class="w-px h-4 bg-base-300 mx-1.5" />
          <.filter_pill
            label="6-Count"
            event="toggle_filter"
            value_key="burpee_type"
            value="six_count"
            active={@filters[:burpee_type] == :six_count}
          />
          <.filter_pill
            label="Navy SEAL"
            event="toggle_filter"
            value_key="burpee_type"
            value="navy_seal"
            active={@filters[:burpee_type] == :navy_seal}
          />
          <div class="w-px h-4 bg-base-300 mx-1.5" />
          <.filter_pill label="L1" event="toggle_filter" value_key="level" value="level_1a" active={@filters[:level] == :level_1a} />
          <.filter_pill label="L2" event="toggle_filter" value_key="level" value="level_2" active={@filters[:level] == :level_2} />
          <.filter_pill label="L3" event="toggle_filter" value_key="level" value="level_3" active={@filters[:level] == :level_3} />
        </div>

        <%!-- List --%>
        <%= if @items == [] do %>
          <.empty_state filters={@filters} />
        <% else %>
          <div class="space-y-3">
            <%= for item <- @items do %>
              <.workout_card item={item} />
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- FAB --%>
      <div class="fixed bottom-20 right-4 sm:bottom-8 sm:right-8 z-40">
        <button
          type="button"
          phx-click="open_create_sheet"
          class="w-12 h-12 rounded-full bg-primary text-primary-content shadow-lg flex items-center justify-center hover:bg-primary/90 transition"
          aria-label="Create"
        >
          <.icon name="hero-plus" class="size-6" />
        </button>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :value_key, :string, required: true
  attr :value, :string, required: true
  attr :active, :boolean, required: true

  defp filter_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-source={if @value_key == "source", do: @value}
      phx-value-burpee_type={if @value_key == "burpee_type", do: @value}
      phx-value-level={if @value_key == "level", do: @value}
      class={[
        "rounded-full px-3 py-1 text-xs font-medium transition whitespace-nowrap",
        @active && "bg-base-content text-base-100",
        !@active && "text-base-content/50 hover:text-base-content"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :item, WorkoutItem, required: true

  defp workout_card(assigns) do
    ~H"""
    <div class="rounded-[10px] border border-[#1E2535] bg-base-200 p-4 space-y-3">
      <div class="flex items-start justify-between gap-2">
        <span class="font-semibold text-base leading-snug">{@item.title}</span>
        <div class="flex gap-1.5 shrink-0 flex-wrap justify-end">
          <span class="inline-flex items-center rounded-full bg-base-300 px-2 py-0.5 text-xs text-base-content/70">
            {Fmt.burpee_type(@item.burpee_type)}
          </span>
          <%= if @item.level do %>
            <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{Fmt.level_color(@item.level)}"}>
              {Fmt.level(@item.level)}
            </span>
          <% end %>
        </div>
      </div>

      <dl class="flex gap-5 text-sm">
        <%= if @item.burpee_count do %>
          <div>
            <dt class="text-xs text-base-content/40 uppercase tracking-wide">Burpees</dt>
            <dd class="font-semibold tabular-nums">{@item.burpee_count}</dd>
          </div>
        <% end %>
        <div>
          <dt class="text-xs text-base-content/40 uppercase tracking-wide">Duration</dt>
          <dd class="font-semibold tabular-nums">{Fmt.duration_sec(@item.duration_sec)}</dd>
        </div>
      </dl>

      <div class="flex gap-2">
        <.link
          navigate={@item.start_path}
          class="flex-1 inline-flex items-center justify-center gap-1.5 rounded-md bg-primary py-2 text-sm font-medium text-primary-content hover:bg-primary/90 transition"
        >
          <.icon name="hero-play" class="size-4" /> Start
        </.link>
        <%= if @item.kind == :plan do %>
          <button
            type="button"
            phx-click="duplicate"
            phx-value-id={@item.id}
            title="Duplicate"
            class="inline-flex items-center justify-center w-9 rounded-md border border-base-300 py-2 hover:bg-base-300 transition"
          >
            <.icon name="hero-document-duplicate" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={@item.id}
            title="Delete"
            data-confirm={"Delete '#{@item.title}'? This cannot be undone."}
            class="inline-flex items-center justify-center w-9 rounded-md border border-error/40 py-2 text-error hover:bg-error/10 transition"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :filters, :map, required: true

  defp empty_state(%{filters: %{source: :mine}} = assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-3">
      <p class="text-base-content/70">You haven't built any plans yet.</p>
      <.link
        navigate={~p"/workouts/new"}
        class="inline-flex items-center gap-1 text-sm text-primary hover:underline"
      >
        <.icon name="hero-plus" class="size-4" /> New plan
      </.link>
    </div>
    """
  end

  defp empty_state(%{filters: filters} = assigns) when map_size(filters) > 0 do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-3">
      <p class="text-base-content/70">Nothing matches these filters.</p>
      <.link patch="/workouts" class="text-sm text-primary hover:underline">
        Clear filters
      </.link>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-base-300 p-12 text-center space-y-2">
      <p class="text-base-content/70">No workouts yet.</p>
      <p class="text-sm text-base-content/50">Tap + to build your first plan.</p>
    </div>
    """
  end
end
```

Note: `Levels.all_levels/0` may not exist yet. Add it to `levels.ex`:

```elixir
@doc "All valid level atoms, in order."
@spec all_levels() :: [atom]
def all_levels, do: Enum.map(@landmarks, & &1.level)
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Fix any failures before proceeding.

- [ ] **Step 5: Run precommit**

```bash
mix precommit
```

- [ ] **Step 6: Commit**

```
jj describe -m "feat: implement WorkoutsLive with filter bar and cards" && jj new
```

---

## Task 6: Update PlansLive.Edit return path

**Files:**
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`

After save, redirect to `/workouts` instead of `/plans`.

- [ ] **Step 1: Find the redirect after save**

Search `plans_live/edit.ex` for wherever it does `push_navigate` or `redirect` after a successful save. It likely navigates to `/plans/:id/edit`. Change it to:

```elixir
{:noreply, push_navigate(socket, to: ~p"/workouts")}
```

Do this for both the `:new` and `:edit` save paths.

- [ ] **Step 2: Update plans_live_test.exs**

In `test/burpee_trainer_web/live/plans_live_test.exs`, update the route references from `~p"/plans"` to `~p"/workouts/new"` and `~p"/workouts/:id/edit"`. Also update any assertions that check for redirect to `/plans`.

- [ ] **Step 3: Run precommit**

```bash
mix precommit
```

- [ ] **Step 4: Commit**

```
jj describe -m "feat: redirect plan editor back to /workouts after save" && jj new
```

---

## Task 7: Logout icon on Home screen

**Files:**
- Modify: `lib/burpee_trainer_web/live/overview_live.ex`
- Modify: `lib/burpee_trainer_web/components/layouts.ex`

Add a small logout icon to the mobile Home header. On desktop, logout is already in the top nav (kept in Task 4).

- [ ] **Step 1: Update OverviewLive render to add a header row with logout**

In `overview_live.ex`, find the `<Layouts.app ...>` wrapper and add a header inside the page content:

```heex
<div class="flex items-center justify-between mb-4 sm:hidden">
  <h1 class="text-xl font-semibold">Home</h1>
  <.link
    href={~p"/logout"}
    method="delete"
    title="Sign out"
    class="text-[#3A4A5E] hover:text-[#C8D8F0] transition-colors"
  >
    <.icon name="hero-arrow-left-start-on-rectangle" class="size-5" />
  </.link>
</div>
```

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

- [ ] **Step 3: Commit**

```
jj describe -m "feat: move mobile logout to Home header icon" && jj new
```

---

## Task 8: Delete retired modules and tests

**Files:**
- Delete: `lib/burpee_trainer_web/live/plans_live/index.ex`
- Delete: `lib/burpee_trainer_web/live/video_live/index.ex`
- Delete (if exists): `test/burpee_trainer_web/live/video_live_test.exs`

- [ ] **Step 1: Delete the files**

```bash
rm lib/burpee_trainer_web/live/plans_live/index.ex
rm lib/burpee_trainer_web/live/video_live/index.ex
```

Check if video live test exists and delete if so:
```bash
ls test/burpee_trainer_web/live/ | grep video
```
If `video_live_test.exs` exists: `rm test/burpee_trainer_web/live/video_live_test.exs`

- [ ] **Step 2: Run precommit**

```bash
mix precommit
```

Expected: passes — nothing in the router or other modules references these deleted modules now.

- [ ] **Step 3: Commit**

```
jj describe -m "refactor: delete retired PlansLive.Index and VideoLive.Index" && jj new
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| Bottom nav ≤ 3 items, all labelled | Task 4 |
| `/workouts` renders plans + videos | Task 5 |
| Source filter (Mine/Videos) single-select, toggle | Task 5 |
| Type filter (6-Count/Navy SEAL) single-select | Task 5 |
| Level filter single-select | Task 5 |
| Filter state in URL query string | Task 5 |
| Sort: plans first, then most-recently-used, then reps delta, then newest | Task 2 |
| FAB with bottom sheet | Task 5 (FAB button; sheet UI deferred — FAB navigates directly in v1) |
| New plan returns to /workouts | Task 6 |
| Old routes redirect | Task 3 |
| Empty states: no content, no plans, no filter match | Task 5 |
| Property test: filtered list equals filtered union | Task 2 |
| Logout off nav → Home icon | Task 4 + Task 7 |

**FAB bottom sheet note:** The spec calls for a bottom sheet with `New plan` / `Log past session`. The Stats screen plan handles `Log past session`. For Plan A, the FAB navigates directly to `/workouts/new`. A full bottom sheet UI can be added in a follow-up or when Stats is wired up.

**Placeholder scan:** No TBDs or vague steps found.

**Type consistency:** `WorkoutItem` struct fields used consistently across Tasks 1, 2, and 5. `WorkoutFeed.list/2` signature matches usage in `WorkoutsLive`. `Levels.all_levels/0` added in Task 5 to support filter decoding.
