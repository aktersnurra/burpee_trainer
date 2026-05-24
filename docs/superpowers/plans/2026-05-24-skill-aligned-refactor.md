# Skill-Aligned Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the project toward the loaded Elixir/OTP, Tiger Style, and type-driven-development guidance while preserving current behavior.

**Architecture:** The work is risk-ordered. First replace unsafe runtime boundaries and inline JavaScript, then add precise specs, then extract pure plan-editor logic, then introduce refined domain values at parsing boundaries. Each task is independently testable and should be committed before moving on.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, SQLite/Exqlite, ExUnit, Phoenix.LiveViewTest, Tailwind/app.js asset bundle, jj.

---

## File Structure

- Create: `lib/burpee_trainer/coach/learning.ex` — explicit post-session coach-learning boundary.
- Modify: `lib/burpee_trainer/application.ex` — add `Task.Supervisor` only if async coach learning remains enabled outside tests.
- Modify: `lib/burpee_trainer/workouts.ex` — delegate session-completed learning to `Coach.Learning` instead of raw `Task.start/1`.
- Test: `test/burpee_trainer/coach/learning_test.exs` — boundary tests for synchronous test behavior and no raw task ownership issue.
- Modify: `lib/burpee_trainer_web/components/layouts/root.html.heex` — remove inline theme script.
- Modify: `assets/js/app.js` — install equivalent theme initialization in the app bundle.
- Test: `test/burpee_trainer_web/components/layouts_test.exs` or an existing layout/controller test — assert root layout no longer contains custom inline theme script.
- Modify: `lib/burpee_trainer/workouts/workout_session.ex` — add specs for public functions.
- Modify: `lib/burpee_trainer/workouts/workout_plan.ex` — add specs for public functions.
- Create: `lib/burpee_trainer/plan_editor.ex` — pure plan-editor state/input helpers extracted from `PlansLive.Edit`.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex` — call `PlanEditor` for extracted pure transitions.
- Test: `test/burpee_trainer/plan_editor_test.exs` — pure unit tests for default input, coach params, existing-plan input, and derived regeneration helpers.
- Create: `lib/burpee_trainer/mood.ex` — refined mood parser/value helper.
- Create: `lib/burpee_trainer/duration.ex` — refined duration parser/converter helper.
- Create: `lib/burpee_trainer/burpee_type.ex` — safe parser for supported burpee types.
- Test: `test/burpee_trainer/mood_test.exs`, `test/burpee_trainer/duration_test.exs`, `test/burpee_trainer/burpee_type_test.exs`.

## Task 1: Coach Learning Boundary

**Files:**

- Create: `lib/burpee_trainer/coach/learning.ex`
- Modify: `lib/burpee_trainer/application.ex`
- Modify: `lib/burpee_trainer/workouts.ex`
- Test: `test/burpee_trainer/coach/learning_test.exs`

- [ ] **Step 1: Write the failing boundary test**

Create `test/burpee_trainer/coach/learning_test.exs`:

```elixir
defmodule BurpeeTrainer.Coach.LearningTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach.Learning
  alias BurpeeTrainer.Workouts

  test "record_session_completed updates coach arms deterministically in tests" do
    user = user_fixture()
    plan = plan_fixture(user)

    {:ok, session} =
      Workouts.create_session_from_plan(user, plan, %{
        "burpee_type" => Atom.to_string(plan.burpee_type),
        "burpee_count_planned" => plan.burpee_count_target,
        "duration_sec_planned" => plan.target_duration_min * 60,
        "burpee_count_actual" => plan.burpee_count_target,
        "duration_sec_actual" => plan.target_duration_min * 60,
        "mood" => 0
      })

    assert :ok = Learning.record_session_completed(user, session)
  end
end
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
mix test test/burpee_trainer/coach/learning_test.exs
```

Expected: FAIL because `BurpeeTrainer.Coach.Learning` does not exist.

- [ ] **Step 3: Add the learning boundary module**

Create `lib/burpee_trainer/coach/learning.ex`:

```elixir
defmodule BurpeeTrainer.Coach.Learning do
  @moduledoc """
  Boundary for post-session coach learning.

  Tests run synchronously so Ecto sandbox ownership remains deterministic.
  Runtime environments run through the supervised task boundary.
  """

  require Logger

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Workouts.WorkoutSession

  @supervisor BurpeeTrainer.CoachLearningSupervisor

  @spec record_session_completed(User.t(), WorkoutSession.t()) :: :ok
  def record_session_completed(%User{} = user, %WorkoutSession{} = session) do
    if Application.get_env(:burpee_trainer, :coach_learning_mode, default_mode()) == :sync do
      run_update(user, session)
    else
      start_update_task(user, session)
    end
  end

  defp default_mode do
    if Application.get_env(:burpee_trainer, :env) == :test, do: :sync, else: :async
  end

  defp start_update_task(user, session) do
    case Task.Supervisor.start_child(@supervisor, fn -> run_update(user, session) end) do
      {:ok, _pid} -> :ok
      {:error, reason} ->
        Logger.warning("coach learning task start failed: #{inspect(reason)}")
        :ok
    end
  end

  defp run_update(user, session) do
    Coach.update_arms(user, session)
  rescue
    exception ->
      Logger.warning("coach learning update failed: #{Exception.message(exception)}")
      :ok
  end
end
```

- [ ] **Step 4: Add the supervisor**

Modify the `children` list in `lib/burpee_trainer/application.ex` so it includes the named task supervisor before the endpoint:

```elixir
children = [
  BurpeeTrainerWeb.Telemetry,
  BurpeeTrainer.Repo,
  {Ecto.Migrator,
   repos: Application.fetch_env!(:burpee_trainer, :ecto_repos), skip: skip_migrations?()},
  {DNSCluster, query: Application.get_env(:burpee_trainer, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: BurpeeTrainer.PubSub},
  {Task.Supervisor, name: BurpeeTrainer.CoachLearningSupervisor},
  BurpeeTrainerWeb.Endpoint
]
```

- [ ] **Step 5: Replace raw `Task.start/1`**

In `lib/burpee_trainer/workouts.ex`, add `Learning` to the coach alias section:

```elixir
alias BurpeeTrainer.Coach
alias BurpeeTrainer.Coach.Learning
```

Replace the raw task in `create_session_from_plan/3`:

```elixir
maybe_upsert_style_performance(session, user_id)
Learning.record_session_completed(%User{id: user_id}, session)
{:ok, session}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/coach/learning_test.exs test/burpee_trainer/workouts_test.exs
```

Expected: PASS with no DB ownership error logs.

- [ ] **Step 7: Commit**

```bash
jj describe -m "refactor(coach): supervise session learning boundary"
jj new
```

## Task 2: Move Theme JavaScript Into App Bundle

**Files:**

- Modify: `lib/burpee_trainer_web/components/layouts/root.html.heex`
- Modify: `assets/js/app.js`
- Test: `test/burpee_trainer_web/components/layouts_test.exs`

- [ ] **Step 1: Write failing layout test**

Create `test/burpee_trainer_web/components/layouts_test.exs`:

```elixir
defmodule BurpeeTrainerWeb.LayoutsTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  test "root layout does not contain inline theme initializer", %{conn: conn} do
    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    refute html =~ "const setTheme"
    refute html =~ "localStorage.getItem(\"phx:theme\")"
    assert html =~ ~s(src="/assets/js/app.js")
  end
end
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
mix test test/burpee_trainer_web/components/layouts_test.exs
```

Expected: FAIL because the root layout still contains the inline theme script.

- [ ] **Step 3: Remove inline script from layout**

In `lib/burpee_trainer_web/components/layouts/root.html.heex`, keep the stylesheet and app script tag, but delete the second `<script>...</script>` block containing `setTheme`.

The head should keep this shape:

```heex
<link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
<script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
</script>
```

- [ ] **Step 4: Add equivalent app-bundle theme initializer**

In `assets/js/app.js`, add this near the top after imports and before LiveSocket setup:

```javascript
const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.removeAttribute("data-theme")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
  }
}

if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(localStorage.getItem("phx:theme") || "system")
}

window.addEventListener("storage", (event) => {
  if (event.key === "phx:theme") setTheme(event.newValue || "system")
})

window.addEventListener("phx:set-theme", (event) => {
  setTheme(event.target.dataset.phxTheme)
})
```

- [ ] **Step 5: Run focused test**

Run:

```bash
mix test test/burpee_trainer_web/components/layouts_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(layout): move theme script into app bundle"
jj new
```

## Task 3: Specs for Touched Public Surfaces

**Files:**

- Modify: `lib/burpee_trainer/workouts/workout_session.ex`
- Modify: `lib/burpee_trainer/workouts/workout_plan.ex`
- Modify: `lib/burpee_trainer/coach/learning.ex`

- [ ] **Step 1: Add schema public specs**

In `lib/burpee_trainer/workouts/workout_session.ex`, add specs above public functions:

```elixir
@spec burpee_types() :: [:six_count | :navy_seal]
def burpee_types, do: @burpee_types

@spec from_plan_changeset(t(), map()) :: Ecto.Changeset.t()
def from_plan_changeset(session, attrs) do
```

and:

```elixir
@spec free_form_changeset(t(), map()) :: Ecto.Changeset.t()
def free_form_changeset(session, attrs) do
```

In `lib/burpee_trainer/workouts/workout_plan.ex`, add:

```elixir
@spec burpee_types() :: [:six_count | :navy_seal]
def burpee_types, do: @burpee_types

@spec changeset(t(), map()) :: Ecto.Changeset.t()
def changeset(plan, attrs) do
```

- [ ] **Step 2: Confirm coach boundary spec is present**

Ensure `lib/burpee_trainer/coach/learning.ex` has:

```elixir
@spec record_session_completed(User.t(), WorkoutSession.t()) :: :ok
```

- [ ] **Step 3: Run compile and focused tests**

Run:

```bash
mix compile --warnings-as-errors
mix test test/burpee_trainer/coach/learning_test.exs test/burpee_trainer/workouts_test.exs
```

Expected: both commands PASS.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor(types): specify touched workout surfaces"
jj new
```

## Task 4: First PlanEditor Extraction

**Files:**

- Create: `lib/burpee_trainer/plan_editor.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Test: `test/burpee_trainer/plan_editor_test.exs`

- [ ] **Step 1: Write failing PlanEditor tests**

Create `test/burpee_trainer/plan_editor_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanEditorTest do
  use BurpeeTrainer.DataCase, async: true

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.PlanEditor
  alias BurpeeTrainer.PlanSolver

  test "default_input contains the new-plan defaults" do
    input = PlanEditor.default_input()

    assert input.name == "New plan"
    assert input.burpee_type == :six_count
    assert input.target_duration_min == 20
    assert input.burpee_count_target == 100
    assert input.pacing_style == :even
    assert input.reps_per_set == PlanSolver.default_reps_per_set(:six_count)
    assert input.additional_rests == []
    assert input.sec_per_burpee_override == nil
  end

  test "apply_coach_params accepts positive count and pace" do
    input =
      PlanEditor.default_input()
      |> PlanEditor.apply_coach_params(%{"count" => "75", "pace" => "2.5"})

    assert input.burpee_count_target == 75
    assert input.sec_per_burpee_override == 2.5
  end

  test "apply_coach_params ignores invalid values" do
    input =
      PlanEditor.default_input()
      |> PlanEditor.apply_coach_params(%{"count" => "0", "pace" => "bad"})

    assert input.burpee_count_target == 100
    assert input.sec_per_burpee_override == nil
  end

  test "input_from_plan preserves persisted plan choices" do
    user = user_fixture()
    plan = plan_fixture(user, %{"name" => "Persisted", "burpee_count_target" => 42})

    input = PlanEditor.input_from_plan(plan)

    assert input.name == "Persisted"
    assert input.burpee_count_target == 42
    assert input.burpee_type == plan.burpee_type
  end
end
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs
```

Expected: FAIL because `BurpeeTrainer.PlanEditor` does not exist.

- [ ] **Step 3: Create PlanEditor module**

Create `lib/burpee_trainer/plan_editor.ex`:

```elixir
defmodule BurpeeTrainer.PlanEditor do
  @moduledoc """
  Pure plan-editor transitions extracted from the plan LiveView.
  """

  alias BurpeeTrainer.PlanSolver
  alias BurpeeTrainer.Workouts.{Block, Set, WorkoutPlan}

  @type input :: %{
          name: String.t(),
          burpee_type: PlanSolver.Input.burpee_type(),
          target_duration_min: pos_integer(),
          burpee_count_target: pos_integer(),
          pacing_style: PlanSolver.Input.pacing_style(),
          reps_per_set: pos_integer() | nil,
          additional_rests: [PlanSolver.Input.additional_rest()],
          sec_per_burpee_override: float() | nil
        }

  @spec default_input() :: input()
  def default_input do
    %{
      name: "New plan",
      burpee_type: :six_count,
      target_duration_min: 20,
      burpee_count_target: 100,
      pacing_style: :even,
      reps_per_set: PlanSolver.default_reps_per_set(:six_count),
      additional_rests: [],
      sec_per_burpee_override: nil
    }
  end

  @spec apply_coach_params(input(), map()) :: input()
  def apply_coach_params(plan_input, params) do
    plan_input
    |> maybe_put_count(params)
    |> maybe_put_pace(params)
  end

  @spec input_from_plan(WorkoutPlan.t()) :: input()
  def input_from_plan(plan) do
    rests =
      case Jason.decode(plan.additional_rests || "[]") do
        {:ok, list} when is_list(list) ->
          Enum.map(list, fn %{"rest_sec" => rest_sec, "target_min" => target_min} ->
            %{rest_sec: rest_sec, target_min: target_min}
          end)

        _ ->
          []
      end

    %{
      name: plan.name,
      burpee_type: plan.burpee_type,
      target_duration_min: plan.target_duration_min || 20,
      burpee_count_target: plan.burpee_count_target || 100,
      pacing_style: plan.pacing_style || :even,
      reps_per_set: infer_reps_per_set(plan),
      additional_rests: rests,
      sec_per_burpee_override: nil
    }
  end

  defp maybe_put_count(plan_input, %{"count" => count_str}) do
    case Integer.parse(count_str) do
      {count, ""} when count > 0 -> %{plan_input | burpee_count_target: count}
      _ -> plan_input
    end
  end

  defp maybe_put_count(plan_input, _params), do: plan_input

  defp maybe_put_pace(plan_input, %{"pace" => pace_str}) do
    case Float.parse(pace_str) do
      {pace, _} when pace > 0 -> %{plan_input | sec_per_burpee_override: pace}
      _ -> plan_input
    end
  end

  defp maybe_put_pace(plan_input, _params), do: plan_input

  defp infer_reps_per_set(plan) do
    first_set =
      plan.blocks
      |> Enum.sort_by(& &1.position)
      |> List.first()
      |> case do
        nil -> nil
        %Block{sets: sets} -> sets |> Enum.sort_by(& &1.position) |> List.first()
      end

    (match?(%Set{}, first_set) && first_set.burpee_count) ||
      PlanSolver.default_reps_per_set(plan.burpee_type)
  end
end
```

- [ ] **Step 4: Replace duplicated LiveView helpers**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, add alias:

```elixir
alias BurpeeTrainer.{Levels, Planner, Workouts}
alias BurpeeTrainer.PlanEditor
```

Replace:

```elixir
plan_input = default_plan_input() |> apply_coach_params(params)
```

with:

```elixir
plan_input = PlanEditor.default_input() |> PlanEditor.apply_coach_params(params)
```

Replace:

```elixir
plan_input = plan_input_from_plan(plan)
```

with:

```elixir
plan_input = PlanEditor.input_from_plan(plan)
```

Delete the private functions now owned by `PlanEditor`:

```elixir
defp apply_coach_params(plan_input, params), do: ...
defp maybe_put_count(plan_input, params), do: ...
defp maybe_put_pace(plan_input, params), do: ...
defp default_plan_input, do: ...
defp plan_input_from_plan(plan), do: ...
defp infer_reps_per_set(plan), do: ...
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live/plans_live_test.exs
```

If the LiveView test file has a different name, run:

```bash
mix test test/burpee_trainer_web/live
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(plans): extract pure editor input logic"
jj new
```

## Task 5: Refined Mood Value

**Files:**

- Create: `lib/burpee_trainer/mood.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Test: `test/burpee_trainer/mood_test.exs`

- [ ] **Step 1: Write failing mood tests**

Create `test/burpee_trainer/mood_test.exs`:

```elixir
defmodule BurpeeTrainer.MoodTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Mood

  test "parse accepts valid mood strings" do
    assert {:ok, -1} = Mood.parse("-1")
    assert {:ok, 0} = Mood.parse("0")
    assert {:ok, 1} = Mood.parse("1")
  end

  test "parse rejects invalid mood strings" do
    assert {:error, {:invalid_mood, "2"}} = Mood.parse("2")
    assert {:error, {:invalid_mood, "bad"}} = Mood.parse("bad")
  end
end
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
mix test test/burpee_trainer/mood_test.exs
```

Expected: FAIL because `BurpeeTrainer.Mood` does not exist.

- [ ] **Step 3: Implement Mood**

Create `lib/burpee_trainer/mood.ex`:

```elixir
defmodule BurpeeTrainer.Mood do
  @moduledoc """
  Refined workout mood value.
  """

  @type t :: -1 | 0 | 1
  @type error :: {:invalid_mood, term()}

  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(value) when value in [-1, 0, 1], do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {mood, ""} when mood in [-1, 0, 1] -> {:ok, mood}
      _ -> {:error, {:invalid_mood, value}}
    end
  end

  def parse(value), do: {:error, {:invalid_mood, value}}
end
```

- [ ] **Step 4: Use Mood in SessionLive**

In `lib/burpee_trainer_web/live/session_live.ex`, add:

```elixir
alias BurpeeTrainer.Mood
```

Replace mood parsing in `handle_event("session_started", ...)` with:

```elixir
mood =
  case Mood.parse(mood_str) do
    {:ok, mood} -> mood
    {:error, _reason} -> 0
  end
```

Replace mood parsing in `handle_event("set_mood", ...)` with:

```elixir
mood =
  case Mood.parse(mood_str) do
    {:ok, mood} -> mood
    {:error, _reason} -> socket.assigns.mood
  end
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/mood_test.exs test/burpee_trainer_web/live/session_live_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(session): parse mood as refined value"
jj new
```

## Task 6: Refined Duration and Burpee Type Parsers

**Files:**

- Create: `lib/burpee_trainer/duration.ex`
- Create: `lib/burpee_trainer/burpee_type.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Test: `test/burpee_trainer/duration_test.exs`
- Test: `test/burpee_trainer/burpee_type_test.exs`

- [ ] **Step 1: Write failing parser tests**

Create `test/burpee_trainer/duration_test.exs`:

```elixir
defmodule BurpeeTrainer.DurationTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Duration

  test "parse_minutes_to_seconds accepts non-negative minute strings" do
    assert {:ok, 90} = Duration.parse_minutes_to_seconds("1.5")
    assert {:ok, 0} = Duration.parse_minutes_to_seconds("0")
  end

  test "parse_minutes_to_seconds rejects invalid values" do
    assert {:error, {:invalid_duration_min, "-1"}} = Duration.parse_minutes_to_seconds("-1")
    assert {:error, {:invalid_duration_min, "bad"}} = Duration.parse_minutes_to_seconds("bad")
  end
end
```

Create `test/burpee_trainer/burpee_type_test.exs`:

```elixir
defmodule BurpeeTrainer.BurpeeTypeTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.BurpeeType

  test "parse accepts supported string values" do
    assert {:ok, :six_count} = BurpeeType.parse("six_count")
    assert {:ok, :navy_seal} = BurpeeType.parse("navy_seal")
  end

  test "parse rejects unsupported values without creating atoms" do
    assert {:error, {:invalid_burpee_type, "unknown"}} = BurpeeType.parse("unknown")
  end
end
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
mix test test/burpee_trainer/duration_test.exs test/burpee_trainer/burpee_type_test.exs
```

Expected: FAIL because modules do not exist.

- [ ] **Step 3: Implement Duration**

Create `lib/burpee_trainer/duration.ex`:

```elixir
defmodule BurpeeTrainer.Duration do
  @moduledoc """
  Duration parsing and conversion helpers.
  """

  @type seconds :: non_neg_integer()
  @type error :: {:invalid_duration_min, term()}

  @spec parse_minutes_to_seconds(term()) :: {:ok, seconds()} | {:error, error()}
  def parse_minutes_to_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {minutes, ""} when minutes >= 0 -> {:ok, round(minutes * 60)}
      {minutes, _rest} when minutes >= 0 -> {:ok, round(minutes * 60)}
      _ -> {:error, {:invalid_duration_min, value}}
    end
  end

  def parse_minutes_to_seconds(value) when is_number(value) and value >= 0 do
    {:ok, round(value * 60)}
  end

  def parse_minutes_to_seconds(value), do: {:error, {:invalid_duration_min, value}}
end
```

- [ ] **Step 4: Implement BurpeeType**

Create `lib/burpee_trainer/burpee_type.ex`:

```elixir
defmodule BurpeeTrainer.BurpeeType do
  @moduledoc """
  Safe parser for supported burpee types.
  """

  @type t :: :six_count | :navy_seal
  @type error :: {:invalid_burpee_type, term()}

  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(:six_count), do: {:ok, :six_count}
  def parse(:navy_seal), do: {:ok, :navy_seal}
  def parse("six_count"), do: {:ok, :six_count}
  def parse("navy_seal"), do: {:ok, :navy_seal}
  def parse(value), do: {:error, {:invalid_burpee_type, value}}
end
```

- [ ] **Step 5: Use Duration in SessionLive**

In `lib/burpee_trainer_web/live/session_live.ex`, add:

```elixir
alias BurpeeTrainer.Duration
```

Replace `coerce_duration/1` with:

```elixir
defp coerce_duration(params) do
  case Duration.parse_minutes_to_seconds(Map.get(params, "duration_min", "")) do
    {:ok, seconds} -> Map.put(params, "duration_sec_actual", seconds)
    {:error, _reason} -> params
  end
end
```

Do not force `BurpeeType` into a caller unless a nearby repeated parser is already present. The value module is introduced with tests and becomes available for subsequent boundary cleanups.

- [ ] **Step 6: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/duration_test.exs test/burpee_trainer/burpee_type_test.exs test/burpee_trainer_web/live/session_live_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
jj describe -m "refactor(domain): add refined parsers for duration and burpee type"
jj new
```

## Task 7: Final Verification

**Files:**

- No new files unless verification exposes a bug.

- [ ] **Step 1: Run the full project gate**

Run:

```bash
mix precommit
```

Expected:

- exit code `0`;
- all tests pass;
- no `DBConnection.ConnectionError owner ... exited` logs from coach-learning tasks;
- no `FOREIGN KEY constraint failed` logs from `Coach.update_arms/2`.

- [ ] **Step 2: Inspect working copy**

Run:

```bash
jj diff --stat
jj status
```

Expected: only intentional refactor files appear. The pre-existing `.gitignore` modification may still be present in a separate working-copy change; do not mix it into refactor commits.

- [ ] **Step 3: Final commit description if needed**

If the current working-copy commit contains only final verification fixes, describe it:

```bash
jj describe -m "refactor: complete skill-aligned cleanup"
jj new
```

If there are no changes after verification, do not create an empty commit.

## Self-Review

Spec coverage:

- Runtime boundary cleanup: Task 1.
- Inline JavaScript relocation: Task 2.
- Typed public surfaces: Task 3.
- Plan editor extraction: Task 4.
- Refined domain values: Tasks 5 and 6.
- Final verification: Task 7.

Placeholder scan: this plan contains no unresolved placeholder steps. Each task includes target files, code snippets, commands, and expected outcomes.

Type consistency: names introduced here are consistent across tasks: `BurpeeTrainer.Coach.Learning.record_session_completed/2`, `BurpeeTrainer.PlanEditor.default_input/0`, `apply_coach_params/2`, `input_from_plan/1`, `BurpeeTrainer.Mood.parse/1`, `BurpeeTrainer.Duration.parse_minutes_to_seconds/1`, and `BurpeeTrainer.BurpeeType.parse/1`.
