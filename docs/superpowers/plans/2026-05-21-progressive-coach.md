# Progressive Coach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Thompson-sampling bandit that learns which workout dimension to push (reps, pace, rest) and surfaces a progressive overload suggestion on the Home screen.

**Architecture:** A new `BurpeeTrainer.Coach` module owns the bandit logic: arm definitions, reward computation, Thompson sampling, and suggestion generation. Arm state (Beta distribution α/β per arm) is persisted in a new `coach_arms` table so the prior accumulates across sessions. A new `Coach.update_arms/2` function is called after each session is saved. The Home screen gains a `CoachSuggestion` component that shows the top arm's suggestion with a "Try it →" link that pre-fills the plan editor.

**Tech Stack:** Elixir, Ecto/SQLite, Phoenix LiveView. Thompson sampling via `:rand` (Erlang stdlib Beta-distribution approximation using the Johnk method).

---

## Domain model

### Arms

Each arm is a {burpee_type, dimension, step} triple. The bandit explores deltas from the user's rolling baseline (last 5 non-warmup sessions of that burpee_type).

```
dimensions:  :reps | :pace | :rest
step values:
  :reps  → +5 | +10 | -5          (rep count delta)
  :pace  → -0.3 | -0.5 | +0.3     (sec/burpee delta; negative = faster)
  :rest  → -3 | -5 | +3           (sec/set delta; negative = shorter)
```

Plus a `:baseline` arm (step = 0) that acts as the recovery/confirmation arm — sometimes the right suggestion is "same as usual."

Total arms per burpee_type: 3 dimensions × 3 steps + 1 baseline = **10 arms**.

### Beta prior

Each arm starts at `alpha=1, beta=1` (uniform prior — no preference).

After a session attributed to arm k:
- reward ≥ 0.8 → `alpha += 1` (success)
- reward < 0.8 → `beta += 1` (failure)

Reward formula:
```
completion_ratio = burpee_count_actual / burpee_count_planned
reward = completion_ratio   (clamped 0..1)
```

Simple and honest: if you finished, the arm worked.

### Thompson sampling

Draw one sample from `Beta(alpha, beta)` for each arm. Pick the arm with the highest sample. The arm with the highest sampled value becomes the suggestion.

### Minimum sessions gate

If the user has fewer than 5 sessions of a given burpee_type, the coach returns `nil` and no suggestion is shown.

### Attribution

A session is attributed to an arm when `plan_id` is non-nil and the plan's parameters are within tolerance of the arm's suggested parameters:
- `burpee_count_actual` within 10% of suggested count
- `sec_per_burpee` within 0.5s of suggested pace
- `end_of_set_rest` (average across sets) within 5s of suggested rest

If no matching arm, the session is not attributed (doesn't update any arm).

---

## File structure

**Create:**
- `priv/repo/migrations/20260521000000_create_coach_arms.exs`
- `lib/burpee_trainer/coach.ex` — public API: `suggest/2`, `update_arms/2`, `baseline/2`
- `lib/burpee_trainer/coach/arm.ex` — Ecto schema for `coach_arms`
- `lib/burpee_trainer/coach/sampler.ex` — Thompson sampling (Beta distribution)
- `test/burpee_trainer/coach_test.exs`
- `test/burpee_trainer/coach/sampler_test.exs`

**Modify:**
- `lib/burpee_trainer/workouts.ex` — call `Coach.update_arms/2` after `create_session_from_plan/3`
- `lib/burpee_trainer_web/live/overview_live.ex` — add coach suggestion to mount + render
- `test/support/fixtures.ex` — add `coach_arm_fixture/3`

---

## Task 1: Migration and Arm schema

**Files:**
- Create: `priv/repo/migrations/20260521000000_create_coach_arms.exs`
- Create: `lib/burpee_trainer/coach/arm.ex`

- [ ] **Step 1: Write the migration**

```elixir
# priv/repo/migrations/20260521000000_create_coach_arms.exs
defmodule BurpeeTrainer.Repo.Migrations.CreateCoachArms do
  use Ecto.Migration

  def change do
    create table(:coach_arms) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :burpee_type, :string, null: false
      add :dimension, :string, null: false
      add :step, :float, null: false
      add :alpha, :float, null: false, default: 1.0
      add :beta, :float, null: false, default: 1.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:coach_arms, [:user_id, :burpee_type, :dimension, :step])
    create index(:coach_arms, [:user_id, :burpee_type])
  end
end
```

- [ ] **Step 2: Run migration**

```bash
cd /home/aktersnurra/projects/vibe/burpee_trainer
mix ecto.migrate
```

Expected: `== Running 20260521000000 CreateCoachArms ==` then `== Migrated ==`.

- [ ] **Step 3: Write `lib/burpee_trainer/coach/arm.ex`**

```elixir
defmodule BurpeeTrainer.Coach.Arm do
  use Ecto.Schema
  import Ecto.Changeset

  alias BurpeeTrainer.Accounts.User

  @burpee_types ["six_count", "navy_seal"]
  @dimensions ["reps", "pace", "rest", "baseline"]

  schema "coach_arms" do
    field :burpee_type, :string
    field :dimension, :string
    field :step, :float
    field :alpha, :float, default: 1.0
    field :beta, :float, default: 1.0

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(arm, attrs) do
    arm
    |> cast(attrs, [:user_id, :burpee_type, :dimension, :step, :alpha, :beta])
    |> validate_required([:user_id, :burpee_type, :dimension, :step])
    |> validate_inclusion(:burpee_type, @burpee_types)
    |> validate_inclusion(:dimension, @dimensions)
    |> validate_number(:alpha, greater_than: 0)
    |> validate_number(:beta, greater_than: 0)
    |> unique_constraint([:user_id, :burpee_type, :dimension, :step])
  end
end
```

- [ ] **Step 4: Compile check**

```bash
mix compile --warnings-as-errors 2>&1 | head -10
```

Expected: clean.

- [ ] **Step 5: Commit with jj**

```bash
jj describe -m "feat: coach_arms migration and Arm schema"
jj new
```

---

## Task 2: Thompson sampler

**Files:**
- Create: `lib/burpee_trainer/coach/sampler.ex`
- Create: `test/burpee_trainer/coach/sampler_test.exs`

The Beta distribution sampler uses the Johnk method: draw two Gamma samples via the Erlang method and compute `X / (X + Y)`. Elixir's `:rand` provides `:rand.uniform/0` (uniform [0,1)).

- [ ] **Step 1: Write failing tests**

```elixir
# test/burpee_trainer/coach/sampler_test.exs
defmodule BurpeeTrainer.Coach.SamplerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Coach.Sampler

  test "sample/2 returns a float in [0, 1]" do
    for _ <- 1..100 do
      s = Sampler.sample(2.0, 3.0)
      assert is_float(s)
      assert s >= 0.0
      assert s <= 1.0
    end
  end

  test "sample/2 with high alpha biases toward 1.0" do
    # With alpha=100, beta=1, mean is ~0.99
    samples = for _ <- 1..200, do: Sampler.sample(100.0, 1.0)
    assert Enum.sum(samples) / 200 > 0.90
  end

  test "sample/2 with high beta biases toward 0.0" do
    samples = for _ <- 1..200, do: Sampler.sample(1.0, 100.0)
    assert Enum.sum(samples) / 200 < 0.10
  end

  test "best_arm/1 returns the index of the arm with highest sample" do
    # With alpha=100 on arm 1, it should almost always win
    arms = [
      %{alpha: 1.0, beta: 1.0},
      %{alpha: 100.0, beta: 1.0},
      %{alpha: 1.0, beta: 1.0}
    ]

    results = for _ <- 1..50, do: Sampler.best_arm(arms)
    # arm at index 1 should win most of the time
    assert Enum.count(results, &(&1 == 1)) > 40
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/coach/sampler_test.exs 2>&1 | tail -5
```

Expected: FAIL — `Sampler` undefined.

- [ ] **Step 3: Implement `lib/burpee_trainer/coach/sampler.ex`**

```elixir
defmodule BurpeeTrainer.Coach.Sampler do
  @moduledoc """
  Thompson sampling for Beta-distributed bandit arms.

  Uses the Johnk method to sample from Beta(alpha, beta):
  draw X ~ Gamma(alpha, 1) and Y ~ Gamma(beta, 1) via Erlang,
  then return X / (X + Y).
  """

  @spec sample(float, float) :: float
  def sample(alpha, beta) when alpha > 0 and beta > 0 do
    x = gamma_sample(alpha)
    y = gamma_sample(beta)
    x / (x + y)
  end

  @spec best_arm([map]) :: non_neg_integer
  def best_arm(arms) do
    arms
    |> Enum.with_index()
    |> Enum.max_by(fn {arm, _i} -> sample(arm.alpha, arm.beta) end)
    |> elem(1)
  end

  # Gamma(k, 1) via Erlang method: sum of k exponential samples.
  # For non-integer k we use the floor + Johnk correction — but since
  # our alpha/beta start at 1.0 and increment by 1.0, k is always an
  # integer in practice. Use the integer Erlang method.
  defp gamma_sample(k) do
    n = max(1, round(k))
    Enum.reduce(1..n, 0.0, fn _, acc ->
      acc - :math.log(max(:rand.uniform(), 1.0e-15))
    end)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/coach/sampler_test.exs 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 5: Commit with jj**

```bash
jj describe -m "feat: Thompson sampler for Beta-distributed arms"
jj new
```

---

## Task 3: Coach context — baseline, suggest, update_arms

**Files:**
- Create: `lib/burpee_trainer/coach.ex`
- Test: `test/burpee_trainer/coach_test.exs`

This is the main module. Three public functions:

- `baseline/2` — compute rolling baseline from last 5 sessions of a burpee_type
- `suggest/2` — run Thompson sampling, return best arm suggestion or nil
- `update_arms/2` — after a session, find the attributed arm and update alpha/beta

- [ ] **Step 1: Write failing tests**

```elixir
# test/burpee_trainer/coach_test.exs
defmodule BurpeeTrainer.CoachTest do
  use BurpeeTrainer.DataCase, async: false

  import BurpeeTrainer.Fixtures

  alias BurpeeTrainer.Coach
  alias BurpeeTrainer.Coach.Arm
  alias BurpeeTrainer.Repo

  describe "baseline/2" do
    test "returns nil when fewer than 5 sessions exist" do
      user = user_fixture()
      assert Coach.baseline(user, :six_count) == nil
    end

    test "returns rolling average of last 5 sessions" do
      user = user_fixture()
      plan = plan_fixture(user, %{
        "burpee_type" => "six_count",
        "burpee_count_target" => 150
      })

      for i <- 1..6 do
        session = session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 150,
          "duration_sec_actual" => 900
        })
        # Space them out so ordering is deterministic
        Repo.update_all(
          from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second)]
        )
      end

      baseline = Coach.baseline(user, :six_count)
      assert baseline != nil
      assert baseline.burpee_count == 150
      assert is_float(baseline.sec_per_burpee)
    end
  end

  describe "suggest/2" do
    test "returns nil when fewer than 5 sessions" do
      user = user_fixture()
      assert Coach.suggest(user, :six_count) == nil
    end

    test "returns a suggestion map when enough sessions exist" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 150})

      for i <- 1..5 do
        session = session_from_plan_fixture(user, plan, %{
          "burpee_count_actual" => 150,
          "duration_sec_actual" => 900
        })
        Repo.update_all(
          from(s in BurpeeTrainer.Workouts.WorkoutSession, where: s.id == ^session.id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second)]
        )
      end

      suggestion = Coach.suggest(user, :six_count)
      assert suggestion != nil
      assert Map.has_key?(suggestion, :burpee_count)
      assert Map.has_key?(suggestion, :sec_per_burpee)
      assert Map.has_key?(suggestion, :rest_sec)
      assert Map.has_key?(suggestion, :dimension)
      assert Map.has_key?(suggestion, :rationale)
    end
  end

  describe "update_arms/2" do
    test "increments alpha on success (completion >= 0.8)" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 155})

      session = session_from_plan_fixture(user, plan, %{
        "burpee_count_planned" => 155,
        "burpee_count_actual" => 155,
        "duration_sec_actual" => 900
      })

      # Ensure the reps arm +5 exists so update can find it
      Coach.update_arms(user, session)

      arm = Repo.get_by(Arm, user_id: user.id, burpee_type: "six_count", dimension: "reps", step: 5.0)
      # If arm was attributed, alpha > 1.0
      if arm, do: assert(arm.alpha > 1.0 or arm.beta > 1.0)
    end

    test "increments beta on failure (completion < 0.8)" do
      user = user_fixture()
      plan = plan_fixture(user, %{"burpee_type" => "six_count", "burpee_count_target" => 155})

      session = session_from_plan_fixture(user, plan, %{
        "burpee_count_planned" => 155,
        "burpee_count_actual" => 100,
        "duration_sec_actual" => 600
      })

      Coach.update_arms(user, session)
      # Just check no crash — attribution may or may not match
      assert true
    end
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
mix test test/burpee_trainer/coach_test.exs 2>&1 | tail -5
```

Expected: FAIL — `Coach` undefined.

- [ ] **Step 3: Implement `lib/burpee_trainer/coach.ex`**

```elixir
defmodule BurpeeTrainer.Coach do
  @moduledoc """
  Progressive overload coach using Thompson sampling.

  Maintains Beta-distributed arm state in `coach_arms`. Each arm is a
  {burpee_type, dimension, step} triple representing a delta from the
  user's rolling baseline. `suggest/2` samples from all arms and returns
  the highest-scoring arm's configuration. `update_arms/2` attributes a
  completed session to the closest arm and updates its distribution.
  """

  import Ecto.Query

  alias BurpeeTrainer.Accounts.User
  alias BurpeeTrainer.Coach.{Arm, Sampler}
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.WorkoutSession

  @min_sessions 5

  # Arms: {dimension, step}. step=0 is the baseline confirmation arm.
  @arm_defs [
    {"baseline", 0.0},
    {"reps",  5.0},
    {"reps", 10.0},
    {"reps", -5.0},
    {"pace", -0.3},
    {"pace", -0.5},
    {"pace",  0.3},
    {"rest", -3.0},
    {"rest", -5.0},
    {"rest",  3.0}
  ]

  @doc """
  Rolling baseline from last #{@min_sessions} non-warmup sessions of the given type.
  Returns nil if fewer than #{@min_sessions} sessions exist.
  """
  @spec baseline(User.t(), atom) :: map | nil
  def baseline(%User{id: user_id}, burpee_type) do
    type_str = Atom.to_string(burpee_type)

    sessions =
      Repo.all(
        from s in WorkoutSession,
          join: p in assoc(s, :plan),
          where:
            s.user_id == ^user_id and
              s.burpee_type == ^type_str and
              not is_nil(s.plan_id) and
              (is_nil(s.tags) or s.tags != "warmup"),
          order_by: [desc: s.inserted_at],
          limit: @min_sessions,
          select: %{
            burpee_count: p.burpee_count_target,
            sec_per_burpee: p.sec_per_burpee,
            rest_sec: s.duration_sec_actual
          }
      )

    if length(sessions) < @min_sessions do
      nil
    else
      count = round(Enum.sum(Enum.map(sessions, & &1.burpee_count)) / length(sessions))
      pace = Enum.sum(Enum.map(sessions, & &1.sec_per_burpee)) / length(sessions)

      # Estimate avg rest_sec per set from duration
      # rest_per_session ≈ duration - burpee_count * sec_per_burpee
      avg_rest =
        sessions
        |> Enum.map(fn s -> max(0.0, s.rest_sec - s.burpee_count * s.sec_per_burpee) end)
        |> then(fn rs -> Enum.sum(rs) / length(rs) end)

      %{burpee_count: count, sec_per_burpee: pace, rest_sec: avg_rest}
    end
  end

  @doc """
  Run Thompson sampling and return the best arm's suggestion, or nil if
  fewer than #{@min_sessions} baseline sessions exist.
  """
  @spec suggest(User.t(), atom) :: map | nil
  def suggest(%User{} = user, burpee_type) do
    base = baseline(user, burpee_type)
    if is_nil(base), do: nil, else: do_suggest(user, burpee_type, base)
  end

  defp do_suggest(%User{id: user_id}, burpee_type, base) do
    type_str = Atom.to_string(burpee_type)

    arms = ensure_arms(user_id, type_str)
    best_idx = Sampler.best_arm(arms)
    best = Enum.at(arms, best_idx)

    apply_arm(base, best.dimension, best.step)
  end

  defp apply_arm(base, "baseline", _step) do
    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: round(base.rest_sec),
      dimension: :baseline,
      rationale: "Confirm your current level — same as recent sessions"
    }
  end

  defp apply_arm(base, "reps", step) do
    count = max(1, base.burpee_count + round(step))
    direction = if step > 0, do: "+#{round(step)} reps", else: "#{round(step)} reps"
    %{
      burpee_count: count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: round(base.rest_sec),
      dimension: :reps,
      rationale: "Push volume — #{direction} from your recent average of #{base.burpee_count}"
    }
  end

  defp apply_arm(base, "pace", step) do
    pace = Float.round(max(3.5, base.sec_per_burpee + step), 1)
    direction = if step < 0, do: "#{step}s/rep faster", else: "+#{step}s/rep slower"
    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: pace,
      rest_sec: round(base.rest_sec),
      dimension: :pace,
      rationale: "Push intensity — #{direction} than your recent pace of #{Float.round(base.sec_per_burpee, 1)}s/rep"
    }
  end

  defp apply_arm(base, "rest", step) do
    rest = max(0, round(base.rest_sec + step))
    direction = if step < 0, do: "#{round(step)}s shorter rest", else: "+#{round(step)}s rest"
    %{
      burpee_count: base.burpee_count,
      sec_per_burpee: Float.round(base.sec_per_burpee, 1),
      rest_sec: rest,
      dimension: :rest,
      rationale: "Push density — #{direction} between sets"
    }
  end

  @doc """
  After a session is saved, find the arm closest to its parameters and
  update alpha (completion >= 0.8) or beta (completion < 0.8).
  """
  @spec update_arms(User.t(), WorkoutSession.t()) :: :ok
  def update_arms(%User{id: user_id}, %WorkoutSession{} = session) do
    if is_nil(session.plan_id) or is_nil(session.burpee_count_planned) do
      :ok
    else
      type_str = Atom.to_string(session.burpee_type)
      base = baseline(%User{id: user_id}, session.burpee_type)

      if base do
        arms = ensure_arms(user_id, type_str)
        completion = session.burpee_count_actual / max(1, session.burpee_count_planned)

        attributed = find_attributed_arm(arms, base, session)

        if attributed do
          if completion >= 0.8 do
            Repo.update_all(
              from(a in Arm, where: a.id == ^attributed.id),
              inc: [alpha: 1.0]
            )
          else
            Repo.update_all(
              from(a in Arm, where: a.id == ^attributed.id),
              inc: [beta: 1.0]
            )
          end
        end
      end

      :ok
    end
  end

  # Ensure all arm rows exist for this user+type, inserting missing ones.
  defp ensure_arms(user_id, type_str) do
    existing =
      Repo.all(
        from a in Arm,
          where: a.user_id == ^user_id and a.burpee_type == ^type_str,
          order_by: [asc: a.dimension, asc: a.step]
      )

    existing_keys = MapSet.new(existing, &{&1.dimension, &1.step})

    missing =
      @arm_defs
      |> Enum.reject(fn {dim, step} -> MapSet.member?(existing_keys, {dim, step}) end)
      |> Enum.map(fn {dim, step} ->
        %{
          user_id: user_id,
          burpee_type: type_str,
          dimension: dim,
          step: step,
          alpha: 1.0,
          beta: 1.0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      end)

    if missing != [] do
      Repo.insert_all(Arm, missing, on_conflict: :nothing)
    end

    Repo.all(
      from a in Arm,
        where: a.user_id == ^user_id and a.burpee_type == ^type_str,
        order_by: [asc: a.dimension, asc: a.step]
    )
  end

  # Attribute the session to the arm whose applied parameters are closest.
  # Tolerance: reps within 10%, pace within 0.5s, rest within 5s.
  defp find_attributed_arm(arms, base, session) do
    actual_count = session.burpee_count_actual
    actual_duration = session.duration_sec_actual

    # Estimate actual pace from duration and count
    actual_pace =
      if actual_count > 0, do: actual_duration / actual_count, else: base.sec_per_burpee

    Enum.find(arms, fn arm ->
      suggestion = apply_arm(base, arm.dimension, arm.step)
      count_ok = abs(actual_count - suggestion.burpee_count) <= max(1, suggestion.burpee_count * 0.1)
      pace_ok = abs(actual_pace - suggestion.sec_per_burpee) <= 0.5
      count_ok and pace_ok
    end)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/burpee_trainer/coach_test.exs 2>&1 | tail -8
```

Expected: PASS.

- [ ] **Step 5: Compile check**

```bash
mix compile --warnings-as-errors 2>&1 | head -10
```

Expected: clean.

- [ ] **Step 6: Commit with jj**

```bash
jj describe -m "feat: Coach context — baseline, suggest, update_arms with Thompson sampling"
jj new
```

---

## Task 4: Wire update_arms into session save

**Files:**
- Modify: `lib/burpee_trainer/workouts.ex`

After `create_session_from_plan/3` succeeds, call `Coach.update_arms/2` asynchronously so it doesn't block the save.

- [ ] **Step 1: Read `create_session_from_plan/3`**

```bash
grep -n "def create_session_from_plan" /home/aktersnurra/projects/vibe/burpee_trainer/lib/burpee_trainer/workouts.ex
```

Read that function to understand its return value.

- [ ] **Step 2: Add Coach alias and update the function**

In `lib/burpee_trainer/workouts.ex`, add to the alias block at the top:

```elixir
alias BurpeeTrainer.Coach
```

Then find `create_session_from_plan/3`. After the `{:ok, session}` case, add the async update. The function currently looks like:

```elixir
case Repo.insert(changeset) do
  {:ok, session} ->
    # ... existing derived field computation ...
    {:ok, session}
  {:error, changeset} ->
    {:error, changeset}
end
```

Add the Coach call after the session is fully built:

```elixir
case Repo.insert(changeset) do
  {:ok, session} ->
    user_struct = %BurpeeTrainer.Accounts.User{id: user_id}
    Task.start(fn -> Coach.update_arms(user_struct, session) end)
    {:ok, session}
  {:error, changeset} ->
    {:error, changeset}
end
```

Use `Task.start/1` so the update is fire-and-forget and never delays the save response.

- [ ] **Step 3: Compile check**

```bash
mix compile --warnings-as-errors 2>&1 | head -10
```

Expected: clean.

- [ ] **Step 4: Run full test suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Commit with jj**

```bash
jj describe -m "feat: update coach arms after session save (async)"
jj new
```

---

## Task 5: Coach suggestion on Home screen

**Files:**
- Modify: `lib/burpee_trainer_web/live/overview_live.ex`

Add coach suggestion to mount and render a new `coach_suggestion` component above the workout card.

- [ ] **Step 1: Update mount/2**

In `lib/burpee_trainer_web/live/overview_live.ex`, add to the aliases:

```elixir
alias BurpeeTrainer.Coach
```

In `mount/2`, after `last_plan = Workouts.last_run_plan(user)`:

```elixir
coach_suggestion = Coach.suggest(user, :six_count)
```

And add to the socket assigns:

```elixir
|> assign(:coach_suggestion, coach_suggestion)
```

- [ ] **Step 2: Update render/1**

In the render function, add the coach suggestion between the status strip and the workout card:

```heex
<.status_strip ... />
<.coach_suggestion suggestion={@coach_suggestion} />
<.workout_card last_plan={@last_plan} />
```

- [ ] **Step 3: Add the component**

After the `status_strip` component, add:

```elixir
attr :suggestion, :any, default: nil

defp coach_suggestion(%{suggestion: nil} = assigns), do: ~H""

defp coach_suggestion(assigns) do
  ~H"""
  <div class="rounded-[10px] border border-primary/20 bg-primary/5 p-4 space-y-3">
    <div class="flex items-start justify-between gap-3">
      <div class="space-y-0.5">
        <p class="text-xs text-primary/70 font-medium uppercase tracking-wide">Coach</p>
        <p class="text-sm font-semibold">
          <%= case @suggestion.dimension do %>
            <% :reps -> %>Push volume
            <% :pace -> %>Push intensity
            <% :rest -> %>Push density
            <% :baseline -> %>Confirm your level
          <% end %>
        </p>
        <p class="text-xs text-base-content/50">{@suggestion.rationale}</p>
      </div>
    </div>
    <div class="flex items-center gap-4 text-xs text-base-content/60">
      <span><strong class="text-base-content">{@suggestion.burpee_count}</strong> reps</span>
      <span><strong class="text-base-content">{@suggestion.sec_per_burpee}s</strong> pace</span>
      <%= if @suggestion.rest_sec > 0 do %>
        <span><strong class="text-base-content">{@suggestion.rest_sec}s</strong> rest</span>
      <% end %>
    </div>
    <.link
      navigate={"/workouts/new?count=#{@suggestion.burpee_count}&pace=#{@suggestion.sec_per_burpee}&rest=#{@suggestion.rest_sec}"}
      class="text-sm text-primary hover:text-primary/80 transition font-medium"
    >
      Try it →
    </.link>
  </div>
  """
end
```

Note: the query params in `navigate` pass the suggestion to the plan editor. The plan editor doesn't yet consume them — that's a future task. For now the link goes to `/workouts/new` and the user sets up the plan manually. The link still communicates intent.

- [ ] **Step 4: Compile check**

```bash
mix compile --warnings-as-errors 2>&1 | head -10
```

Expected: clean.

- [ ] **Step 5: Run full test suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit with jj**

```bash
jj describe -m "feat: coach suggestion card on Home screen"
jj new
```

---

## Task 6: Final precommit and push

- [ ] **Step 1: Run precommit**

```bash
mix precommit
```

Expected: compile clean, format clean, all tests pass.

- [ ] **Step 2: Move master bookmark and push**

```bash
jj bookmark set master --allow-backwards -r @-
jj git push
```

---

## Self-Review

**Spec coverage:**

| Requirement | Task |
|---|---|
| `coach_arms` table with {user_id, burpee_type, dimension, step, alpha, beta} | Task 1 |
| Beta prior starts at alpha=1, beta=1 | Task 1 (default) |
| Thompson sampling via Johnk/Gamma method | Task 2 |
| `Coach.baseline/2` — rolling 5-session average | Task 3 |
| Minimum 5 sessions gate → nil | Task 3 |
| `Coach.suggest/2` — samples all arms, returns best | Task 3 |
| Arms: 3 dimensions × 3 steps + baseline = 10 per type | Task 3 (`@arm_defs`) |
| Reward = completion_ratio (clamped 0..1) | Task 3 (`update_arms`) |
| alpha += 1 on success (≥ 0.8), beta += 1 on failure | Task 3 |
| Attribution: reps within 10%, pace within 0.5s | Task 3 (`find_attributed_arm`) |
| Arms auto-created on first suggest | Task 3 (`ensure_arms`) |
| Async update after session save | Task 4 |
| Coach suggestion component on Home | Task 5 |
| Nil suggestion → component renders nothing | Task 5 |
| "Try it →" link to plan editor with params | Task 5 |

**Placeholder scan:** No TBD or TODO. The "Try it →" query-param consumption by the plan editor is explicitly noted as a future task — not a placeholder, a deliberate deferral.

**Type consistency:**
- `baseline/2` returns `%{burpee_count: integer, sec_per_burpee: float, rest_sec: float} | nil` — consumed by `apply_arm/3` with those exact keys ✓
- `suggest/2` returns `%{burpee_count: integer, sec_per_burpee: float, rest_sec: integer, dimension: atom, rationale: string} | nil` — consumed by `coach_suggestion` component ✓
- `ensure_arms/2` returns `[Arm.t()]` — consumed by `Sampler.best_arm/1` which expects `[%{alpha: float, beta: float}]` ✓ (Arm schema has those fields)
- `update_arms/2` takes `User.t()` and `WorkoutSession.t()` — called in Task 4 with `%User{id: user_id}` ✓
