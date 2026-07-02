# Canonical Workout Program Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace mutable workout-plan-derived execution with a source → compiler → immutable `ExecutionProgram` → runner architecture while preserving completed workout sessions.

**Architecture:** `WorkoutPlan` becomes editable source, `PlanCompiler` compiles source into immutable canonical programs, `ExecutionPrograms` persists/dedupes compiled programs by content hash, and `SessionLive`/JS interpret only canonical program events. Old plan template data may be reset; completed sessions stay and gain optional `execution_program_id` provenance.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto migrations/schemas, SQLite in dev/test, ExUnit, Phoenix LiveView tests, Vitest/node tests for JS hooks, jj for VCS.

## Global Constraints

- Preserve `workout_sessions` rows and stats/history.
- Old `workout_plans`, `blocks`, `sets`, and `plan_steps` template rows are disposable.
- Use `mix ecto.gen.migration migration_name_using_underscores` for every migration.
- Use `mix precommit` as final verification.
- Do not keep messy execution compatibility APIs just to preserve old plan templates.
- `WorkoutPlan` is editable source; `ExecutionProgram` is immutable executable truth.
- `SessionLive` and JS runner must not reconstruct runtime timing from mutable plan blocks, sets, steps, or `additional_rests`.
- Count-in, vertical set bars, rest countdown, beeps, and completion flow must be preserved by deriving UI projections from program events.
- Use jj commands only; do not use git commands directly.

---

## File Structure

### New domain/compiler files

- Create: `lib/burpee_trainer/plan_compiler/program_event.ex` — typed work/rest instruction structs.
- Create: `lib/burpee_trainer/plan_compiler/program.ex` — immutable compiled program struct and derived totals.
- Create: `lib/burpee_trainer/plan_compiler/compile_error.ex` — structured domain error.
- Create: `lib/burpee_trainer/plan_compiler/program_validator.ex` — canonical program invariant checks.
- Create: `lib/burpee_trainer/plan_compiler/program_hash.ex` — deterministic semantic encoder and SHA-256 hash.
- Create: `lib/burpee_trainer/plan_compiler/plan_source.ex` — source-code struct parsed from `WorkoutPlan.source_json` or editor attrs.
- Create: `lib/burpee_trainer/plan_compiler.ex` — public compiler facade.

### New persistence files

- Create: generated migration `priv/repo/migrations/*_create_execution_programs_and_refactor_workout_plans.exs`.
- Create: `lib/burpee_trainer/workouts/execution_program.ex` — Ecto schema for immutable compiled programs.
- Create: `lib/burpee_trainer/execution_programs.ex` — context for validate/hash/get-or-insert.

### Modified Elixir files

- Modify: `lib/burpee_trainer/workouts/workout_plan.ex` — make plan source-oriented with `source_json` and optional `current_execution_program_id`.
- Modify: `lib/burpee_trainer/workouts/workout_session.ex` — add `execution_program_id` association and cast/set support.
- Modify: `lib/burpee_trainer/workouts.ex` — create/update/duplicate/list/start-session APIs use source + compiled program; no runtime dependence on blocks/sets/steps.
- Modify: `lib/burpee_trainer/workout_feed.ex` — summarize plans from current compiled program summary.
- Modify: `lib/burpee_trainer/plan_solver.ex` and `lib/burpee_trainer/plan_solver/*` — solver internals produce program events through the compiler boundary.
- Modify: `lib/burpee_trainer_web/live/session_live.ex` — load/compile program and serialize program payload directly.
- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex` and related templates — save/edit source JSON instead of runtime block/step truth.
- Modify: `lib/burpee_trainer_web/router.ex` only if route names change; keep `/session/:plan_id` initially as “compile current plan and run program”.

### Modified JS files

- Modify: `assets/js/hooks/session_hook.js` — rename execution input from plan timeline to program events.
- Modify: `assets/js/hooks/session_plan.mjs` — reduce to program/warmup helpers or delete after call sites move.
- Modify: `assets/js/hooks/session_segment_fsm.mjs` — keep VM behavior; accept canonical program event shape.
- Modify: relevant tests under `assets/js/hooks/*_test.mjs`.

### Test files

- Create: `test/burpee_trainer/plan_compiler/program_test.exs`.
- Create: `test/burpee_trainer/plan_compiler/program_hash_test.exs`.
- Create: `test/burpee_trainer/execution_programs_test.exs`.
- Modify/Create: `test/burpee_trainer/plan_compiler_test.exs`.
- Modify: `test/burpee_trainer/plan_solver/even_solver_test.exs`.
- Modify: `test/burpee_trainer/plan_solver_test.exs`.
- Modify: `test/burpee_trainer/workouts_test.exs`.
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`.
- Modify: JS hook tests in `assets/js/hooks`.

---

### Task 1: Add canonical program domain core

**Files:**

- Create: `lib/burpee_trainer/plan_compiler/program_event.ex`
- Create: `lib/burpee_trainer/plan_compiler/program.ex`
- Create: `lib/burpee_trainer/plan_compiler/compile_error.ex`
- Create: `lib/burpee_trainer/plan_compiler/program_validator.ex`
- Test: `test/burpee_trainer/plan_compiler/program_test.exs`

**Interfaces:**

- Produces: `BurpeeTrainer.PlanCompiler.Program.new/1 :: keyword | map -> {:ok, Program.t()} | {:error, CompileError.t()}`
- Produces: `BurpeeTrainer.PlanCompiler.Program.events/1 :: Program.t() -> [ProgramEvent.t()]`
- Produces: `BurpeeTrainer.PlanCompiler.Program.total_reps/1 :: Program.t() -> non_neg_integer`
- Produces: `BurpeeTrainer.PlanCompiler.Program.duration_sec/1 :: Program.t() -> float`
- Produces: `BurpeeTrainer.PlanCompiler.ProgramValidator.validate/1 :: Program.t() -> :ok | {:error, CompileError.t()}`

- [ ] **Step 1: Write failing program invariant tests**

Create `test/burpee_trainer/plan_compiler/program_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.ProgramTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent, ProgramValidator}

  test "valid program computes reps and duration from ordered events" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 20,
               target_duration_sec: 300,
               events: [
                 ProgramEvent.work!(%{
                   id: "work-001",
                   set_index: 1,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 1"
                 }),
                 ProgramEvent.rest!(%{id: "rest-001", duration_sec: 60, label: "Rest"}),
                 ProgramEvent.work!(%{
                   id: "work-002",
                   set_index: 2,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 2"
                 })
               ],
               metadata: %{pacing_style: :even}
             })

    assert Program.total_reps(program) == 20
    assert_in_delta Program.duration_sec(program), 300.0, 1.0e-6
    assert :ok = ProgramValidator.validate(program)
  end

  test "validator rejects duplicate event ids" do
    event =
      ProgramEvent.work!(%{
        id: "work-001",
        set_index: 1,
        block_index: 1,
        reps: 10,
        duration_sec: 120.0,
        sec_per_rep: 12.0,
        label: "Set 1"
      })

    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 20,
               target_duration_sec: 240,
               events: [event, %{event | set_index: 2}],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :duplicate_event_id, context: %{id: "work-001"}}} =
             ProgramValidator.validate(program)
  end

  test "validator rejects target duration mismatch" do
    assert {:ok, program} =
             Program.new(%{
               schema_version: 1,
               solver_version: 4,
               burpee_type: :six_count,
               target_reps: 10,
               target_duration_sec: 300,
               events: [
                 ProgramEvent.work!(%{
                   id: "work-001",
                   set_index: 1,
                   block_index: 1,
                   reps: 10,
                   duration_sec: 120.0,
                   sec_per_rep: 12.0,
                   label: "Set 1"
                 })
               ],
               metadata: %{pacing_style: :even}
             })

    assert {:error, %CompileError{code: :target_duration_mismatch}} =
             ProgramValidator.validate(program)
  end
end
```

- [ ] **Step 2: Run RED test**

Run:

```bash
mix test test/burpee_trainer/plan_compiler/program_test.exs
```

Expected: compile failure because `BurpeeTrainer.PlanCompiler.Program` modules do not exist.

- [ ] **Step 3: Implement structured compile error**

Create `lib/burpee_trainer/plan_compiler/compile_error.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.CompileError do
  @moduledoc "Structured compiler/program validation error."

  @enforce_keys [:code, :message, :context]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          context: map()
        }

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, context \\ %{}) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, context: context}
  end
end
```

- [ ] **Step 4: Implement event constructors**

Create `lib/burpee_trainer/plan_compiler/program_event.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.ProgramEvent do
  @moduledoc "One executable instruction in a compiled workout program."

  defmodule Work do
    @moduledoc "A work instruction containing reps at a concrete cadence."
    @enforce_keys [:id, :kind, :set_index, :reps, :duration_sec, :sec_per_rep, :label]
    defstruct [:id, :kind, :set_index, :block_index, :display_group, :reps, :duration_sec, :sec_per_rep, :label]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :work,
            set_index: pos_integer(),
            block_index: pos_integer() | nil,
            display_group: String.t() | nil,
            reps: pos_integer(),
            duration_sec: float(),
            sec_per_rep: float(),
            label: String.t()
          }
  end

  defmodule Rest do
    @moduledoc "A rest instruction with concrete duration."
    @enforce_keys [:id, :kind, :duration_sec, :label]
    defstruct [:id, :kind, :duration_sec, :label, :source]

    @type t :: %__MODULE__{
            id: String.t(),
            kind: :rest,
            duration_sec: pos_integer() | float(),
            label: String.t(),
            source: atom() | tuple() | nil
          }
  end

  @type t :: Work.t() | Rest.t()

  @spec work!(map()) :: Work.t()
  def work!(attrs) when is_map(attrs) do
    %Work{
      id: fetch!(attrs, :id),
      kind: :work,
      set_index: fetch!(attrs, :set_index),
      block_index: Map.get(attrs, :block_index),
      display_group: Map.get(attrs, :display_group),
      reps: fetch!(attrs, :reps),
      duration_sec: fetch!(attrs, :duration_sec) * 1.0,
      sec_per_rep: fetch!(attrs, :sec_per_rep) * 1.0,
      label: fetch!(attrs, :label)
    }
  end

  @spec rest!(map()) :: Rest.t()
  def rest!(attrs) when is_map(attrs) do
    %Rest{
      id: fetch!(attrs, :id),
      kind: :rest,
      duration_sec: fetch!(attrs, :duration_sec),
      label: fetch!(attrs, :label),
      source: Map.get(attrs, :source)
    }
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  end
end
```

- [ ] **Step 5: Implement program struct**

Create `lib/burpee_trainer/plan_compiler/program.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.Program do
  @moduledoc "Immutable compiled workout program."

  alias BurpeeTrainer.PlanCompiler.{CompileError, ProgramEvent}

  @enforce_keys [
    :schema_version,
    :solver_version,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :events,
    :metadata
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          solver_version: pos_integer(),
          burpee_type: :six_count | :navy_seal,
          target_reps: pos_integer(),
          target_duration_sec: pos_integer(),
          events: [ProgramEvent.t()],
          metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, CompileError.t()}
  def new(attrs) when is_map(attrs) do
    program = %__MODULE__{
      schema_version: Map.fetch!(attrs, :schema_version),
      solver_version: Map.fetch!(attrs, :solver_version),
      burpee_type: Map.fetch!(attrs, :burpee_type),
      target_reps: Map.fetch!(attrs, :target_reps),
      target_duration_sec: Map.fetch!(attrs, :target_duration_sec),
      events: Map.fetch!(attrs, :events),
      metadata: Map.get(attrs, :metadata, %{})
    }

    {:ok, program}
  rescue
    KeyError ->
      {:error, CompileError.new(:invalid_program, "Program is missing required fields")}
  end

  @spec events(t()) :: [ProgramEvent.t()]
  def events(%__MODULE__{events: events}), do: events

  @spec total_reps(t()) :: non_neg_integer()
  def total_reps(%__MODULE__{events: events}) do
    Enum.reduce(events, 0, fn
      %ProgramEvent.Work{reps: reps}, total -> total + reps
      _event, total -> total
    end)
  end

  @spec duration_sec(t()) :: float()
  def duration_sec(%__MODULE__{events: events}) do
    Enum.reduce(events, 0.0, fn
      %{duration_sec: duration}, total -> total + duration
    end)
  end
end
```

- [ ] **Step 6: Implement validator**

Create `lib/burpee_trainer/plan_compiler/program_validator.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.ProgramValidator do
  @moduledoc "Validates canonical execution program invariants."

  alias BurpeeTrainer.PlanCompiler.{CompileError, Program, ProgramEvent}

  @epsilon 1.0e-6

  @spec validate(Program.t()) :: :ok | {:error, CompileError.t()}
  def validate(%Program{} = program) do
    with :ok <- validate_events(program.events),
         :ok <- validate_unique_ids(program.events),
         :ok <- validate_reps(program),
         :ok <- validate_duration(program) do
      :ok
    end
  end

  defp validate_events([]),
    do: {:error, CompileError.new(:empty_program, "Program must contain at least one event")}

  defp validate_events(events) do
    Enum.reduce_while(events, :ok, fn
      %ProgramEvent.Work{reps: reps, duration_sec: duration, sec_per_rep: pace, id: id}, :ok
      when is_binary(id) and reps > 0 and duration > 0 and pace > 0 ->
        {:cont, :ok}

      %ProgramEvent.Rest{duration_sec: duration, id: id}, :ok
      when is_binary(id) and duration > 0 ->
        {:cont, :ok}

      event, :ok ->
        {:halt,
         {:error,
          CompileError.new(:invalid_event, "Program contains an invalid event", %{event: event})}}
    end)
  end

  defp validate_unique_ids(events) do
    ids = Enum.map(events, & &1.id)

    case ids -- Enum.uniq(ids) do
      [duplicate | _] ->
        {:error,
         CompileError.new(:duplicate_event_id, "Program event ids must be unique", %{id: duplicate})}

      [] ->
        :ok
    end
  end

  defp validate_reps(%Program{} = program) do
    if Program.total_reps(program) == program.target_reps do
      :ok
    else
      {:error,
       CompileError.new(:target_reps_mismatch, "Program reps do not match target", %{
         target_reps: program.target_reps,
         actual_reps: Program.total_reps(program)
       })}
    end
  end

  defp validate_duration(%Program{} = program) do
    actual = Program.duration_sec(program)

    if abs(actual - program.target_duration_sec) <= @epsilon do
      :ok
    else
      {:error,
       CompileError.new(:target_duration_mismatch, "Program duration does not match target", %{
         target_duration_sec: program.target_duration_sec,
         actual_duration_sec: actual
       })}
    end
  end
end
```

- [ ] **Step 7: Run GREEN test**

Run:

```bash
mix test test/burpee_trainer/plan_compiler/program_test.exs
```

Expected: all tests pass.

- [ ] **Step 8: Run file diagnostics**

Run:

```bash
mix format lib/burpee_trainer/plan_compiler/*.ex test/burpee_trainer/plan_compiler/program_test.exs
mix test test/burpee_trainer/plan_compiler/program_test.exs
```

Expected: formatter succeeds and tests pass.

- [ ] **Step 9: Commit task**

Run:

```bash
jj describe -m "feat(program): add canonical workout program core"
jj new
```

Expected: new empty working-copy change on top of the program core commit.

---

### Task 2: Add stable canonical hashing

**Files:**

- Create: `lib/burpee_trainer/plan_compiler/program_hash.ex`
- Test: `test/burpee_trainer/plan_compiler/program_hash_test.exs`

**Interfaces:**

- Consumes: `Program.t()` from Task 1.
- Produces: `ProgramHash.canonical_map/1 :: Program.t() -> map()`
- Produces: `ProgramHash.encode!/1 :: Program.t() -> String.t()`
- Produces: `ProgramHash.hash/1 :: Program.t() -> String.t()`

- [ ] **Step 1: Write failing hash tests**

Create `test/burpee_trainer/plan_compiler/program_hash_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.ProgramHashTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent, ProgramHash}

  defp program(attrs \\ %{}) do
    {:ok, program} =
      Program.new(Map.merge(%{
        schema_version: 1,
        solver_version: 4,
        burpee_type: :six_count,
        target_reps: 10,
        target_duration_sec: 120,
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 120.0,
            sec_per_rep: 12.0,
            label: "Set 1"
          })
        ],
        metadata: %{pacing_style: :even, recovery_model: :saved_up_rest}
      }, attrs))

    program
  end

  test "hash is stable for identical semantic programs" do
    assert ProgramHash.hash(program()) == ProgramHash.hash(program())
  end

  test "hash ignores display label changes" do
    changed_label =
      program(%{
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 120.0,
            sec_per_rep: 12.0,
            label: "A prettier label"
          })
        ]
      })

    assert ProgramHash.hash(program()) == ProgramHash.hash(changed_label)
  end

  test "hash changes when executable cadence changes" do
    changed_cadence =
      program(%{
        target_duration_sec: 130,
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 130.0,
            sec_per_rep: 13.0,
            label: "Set 1"
          })
        ]
      })

    refute ProgramHash.hash(program()) == ProgramHash.hash(changed_cadence)
  end
end
```

- [ ] **Step 2: Run RED test**

Run:

```bash
mix test test/burpee_trainer/plan_compiler/program_hash_test.exs
```

Expected: compile failure because `ProgramHash` does not exist.

- [ ] **Step 3: Implement deterministic hash**

Create `lib/burpee_trainer/plan_compiler/program_hash.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.ProgramHash do
  @moduledoc "Canonical semantic encoding and content hash for execution programs."

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}

  @spec canonical_map(Program.t()) :: map()
  def canonical_map(%Program{} = program) do
    %{
      schema_version: program.schema_version,
      solver_version: program.solver_version,
      burpee_type: Atom.to_string(program.burpee_type),
      target_reps: program.target_reps,
      target_duration_ms: sec_to_ms(program.target_duration_sec),
      events: Enum.map(program.events, &canonical_event/1),
      semantics: canonical_metadata(program.metadata)
    }
  end

  @spec encode!(Program.t()) :: String.t()
  def encode!(%Program{} = program) do
    program
    |> canonical_map()
    |> Jason.encode!()
  end

  @spec hash(Program.t()) :: String.t()
  def hash(%Program{} = program) do
    :crypto.hash(:sha256, encode!(program))
    |> Base.encode16(case: :lower)
  end

  defp canonical_event(%ProgramEvent.Work{} = event) do
    %{
      id: event.id,
      kind: "work",
      set_index: event.set_index,
      block_index: event.block_index,
      reps: event.reps,
      duration_ms: sec_to_ms(event.duration_sec),
      sec_per_rep_ms: sec_to_ms(event.sec_per_rep)
    }
  end

  defp canonical_event(%ProgramEvent.Rest{} = event) do
    %{
      id: event.id,
      kind: "rest",
      duration_ms: sec_to_ms(event.duration_sec),
      source: encode_source(event.source)
    }
  end

  defp canonical_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:pacing_style, :recovery_model, :policy_version])
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), encode_source(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp sec_to_ms(value), do: round(value * 1000)

  defp encode_source(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_source({left, right}), do: [encode_source(left), encode_source(right)]
  defp encode_source(value), do: value
end
```

- [ ] **Step 4: Run GREEN test**

Run:

```bash
mix test test/burpee_trainer/plan_compiler/program_hash_test.exs test/burpee_trainer/plan_compiler/program_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit task**

Run:

```bash
jj describe -m "feat(program): add stable execution program hashing"
jj new
```

Expected: new empty working-copy change.

---

### Task 3: Persist immutable execution programs and link sessions

**Files:**

- Create: generated migration from `mix ecto.gen.migration create_execution_programs_and_refactor_workout_plans`
- Create: `lib/burpee_trainer/workouts/execution_program.ex`
- Create: `lib/burpee_trainer/execution_programs.ex`
- Modify: `lib/burpee_trainer/workouts/workout_session.ex`
- Modify: `lib/burpee_trainer/workouts/workout_plan.ex`
- Test: `test/burpee_trainer/execution_programs_test.exs`

**Interfaces:**

- Consumes: `Program.t()` and `ProgramHash.hash/1`.
- Produces: `%BurpeeTrainer.Workouts.ExecutionProgram{}` Ecto schema.
- Produces: `BurpeeTrainer.ExecutionPrograms.get_or_insert/1`.
- Produces: `WorkoutSession.belongs_to(:execution_program, ExecutionProgram)`.

- [ ] **Step 1: Generate migration**

Run:

```bash
mix ecto.gen.migration create_execution_programs_and_refactor_workout_plans
```

Expected: Mix prints a new migration path under `priv/repo/migrations/` ending in `_create_execution_programs_and_refactor_workout_plans.exs`.

- [ ] **Step 2: Edit generated migration**

Replace the generated migration body with:

```elixir
defmodule BurpeeTrainer.Repo.Migrations.CreateExecutionProgramsAndRefactorWorkoutPlans do
  use Ecto.Migration

  def up do
    create table(:execution_programs) do
      add :content_hash, :string, null: false
      add :schema_version, :integer, null: false
      add :solver_version, :integer, null: false
      add :burpee_type, :string, null: false
      add :target_reps, :integer, null: false
      add :target_duration_sec, :integer, null: false
      add :event_count, :integer, null: false
      add :program_json, :map, null: false
      add :summary_json, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:execution_programs, [:content_hash])
    create index(:execution_programs, [:burpee_type])

    alter table(:workout_sessions) do
      add :execution_program_id, references(:execution_programs, on_delete: :nilify_all)
    end

    create index(:workout_sessions, [:execution_program_id])

    alter table(:workout_plans) do
      add :source_json, :map
      add :current_execution_program_id, references(:execution_programs, on_delete: :nilify_all)
    end

    create index(:workout_plans, [:current_execution_program_id])

    execute("DELETE FROM plan_steps")
    execute("DELETE FROM sets")
    execute("DELETE FROM blocks")
    execute("DELETE FROM workout_plans")
  end

  def down do
    alter table(:workout_plans) do
      remove :current_execution_program_id
      remove :source_json
    end

    alter table(:workout_sessions) do
      remove :execution_program_id
    end

    drop table(:execution_programs)
  end
end
```

- [ ] **Step 3: Write failing persistence tests**

Create `test/burpee_trainer/execution_programs_test.exs`:

```elixir
defmodule BurpeeTrainer.ExecutionProgramsTest do
  use BurpeeTrainer.DataCase, async: true

  alias BurpeeTrainer.ExecutionPrograms
  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}

  defp program do
    {:ok, program} =
      Program.new(%{
        schema_version: 1,
        solver_version: 4,
        burpee_type: :six_count,
        target_reps: 10,
        target_duration_sec: 120,
        events: [
          ProgramEvent.work!(%{
            id: "work-001",
            set_index: 1,
            block_index: 1,
            reps: 10,
            duration_sec: 120.0,
            sec_per_rep: 12.0,
            label: "Set 1"
          })
        ],
        metadata: %{pacing_style: :even, recovery_model: :saved_up_rest}
      })

    program
  end

  test "get_or_insert deduplicates identical programs by content hash" do
    assert {:ok, first} = ExecutionPrograms.get_or_insert(program())
    assert {:ok, second} = ExecutionPrograms.get_or_insert(program())

    assert first.id == second.id
    assert first.content_hash == second.content_hash
    assert first.target_reps == 10
    assert first.target_duration_sec == 120
    assert first.event_count == 1
  end
end
```

- [ ] **Step 4: Run RED test**

Run:

```bash
mix test test/burpee_trainer/execution_programs_test.exs
```

Expected: compile or database failure because schema/context are not implemented or migration is not applied in test.

- [ ] **Step 5: Implement Ecto schema**

Create `lib/burpee_trainer/workouts/execution_program.ex`:

```elixir
defmodule BurpeeTrainer.Workouts.ExecutionProgram do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "execution_programs" do
    field :content_hash, :string
    field :schema_version, :integer
    field :solver_version, :integer
    field :burpee_type, Ecto.Enum, values: [:six_count, :navy_seal]
    field :target_reps, :integer
    field :target_duration_sec, :integer
    field :event_count, :integer
    field :program_json, :map
    field :summary_json, :map

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(program, attrs) do
    program
    |> cast(attrs, [
      :content_hash,
      :schema_version,
      :solver_version,
      :burpee_type,
      :target_reps,
      :target_duration_sec,
      :event_count,
      :program_json,
      :summary_json
    ])
    |> validate_required([
      :content_hash,
      :schema_version,
      :solver_version,
      :burpee_type,
      :target_reps,
      :target_duration_sec,
      :event_count,
      :program_json,
      :summary_json
    ])
    |> validate_number(:schema_version, greater_than: 0)
    |> validate_number(:solver_version, greater_than: 0)
    |> validate_number(:target_reps, greater_than: 0)
    |> validate_number(:target_duration_sec, greater_than: 0)
    |> validate_number(:event_count, greater_than: 0)
    |> unique_constraint(:content_hash)
  end
end
```

- [ ] **Step 6: Implement persistence context**

Create `lib/burpee_trainer/execution_programs.ex`:

```elixir
defmodule BurpeeTrainer.ExecutionPrograms do
  @moduledoc "Persistence boundary for immutable compiled workout programs."

  import Ecto.Query

  alias BurpeeTrainer.PlanCompiler.{Program, ProgramHash, ProgramValidator}
  alias BurpeeTrainer.Repo
  alias BurpeeTrainer.Workouts.ExecutionProgram

  @spec get_or_insert(Program.t()) :: {:ok, ExecutionProgram.t()} | {:error, term()}
  def get_or_insert(%Program{} = program) do
    with :ok <- ProgramValidator.validate(program) do
      hash = ProgramHash.hash(program)

      case Repo.get_by(ExecutionProgram, content_hash: hash) do
        %ExecutionProgram{} = existing ->
          {:ok, existing}

        nil ->
          insert_program(program, hash)
      end
    end
  end

  @spec get!(integer()) :: ExecutionProgram.t()
  def get!(id), do: Repo.get!(ExecutionProgram, id)

  defp insert_program(%Program{} = program, hash) do
    attrs = %{
      content_hash: hash,
      schema_version: program.schema_version,
      solver_version: program.solver_version,
      burpee_type: program.burpee_type,
      target_reps: program.target_reps,
      target_duration_sec: program.target_duration_sec,
      event_count: length(program.events),
      program_json: ProgramHash.canonical_map(program),
      summary_json: summary_json(program)
    }

    %ExecutionProgram{}
    |> ExecutionProgram.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, changeset} -> handle_insert_error(hash, changeset)
    end
  end

  defp handle_insert_error(hash, changeset) do
    case Repo.one(from p in ExecutionProgram, where: p.content_hash == ^hash) do
      %ExecutionProgram{} = existing -> {:ok, existing}
      nil -> {:error, changeset}
    end
  end

  defp summary_json(%Program{} = program) do
    %{
      "target_reps" => program.target_reps,
      "target_duration_sec" => program.target_duration_sec,
      "work_event_count" => Enum.count(program.events, &match?(%BurpeeTrainer.PlanCompiler.ProgramEvent.Work{}, &1)),
      "rest_event_count" => Enum.count(program.events, &match?(%BurpeeTrainer.PlanCompiler.ProgramEvent.Rest{}, &1))
    }
  end
end
```

- [ ] **Step 7: Link schemas**

Modify `lib/burpee_trainer/workouts/workout_session.ex`:

```elixir
alias BurpeeTrainer.Workouts.{ExecutionProgram, WorkoutPlan}
```

Add inside schema:

```elixir
belongs_to(:execution_program, ExecutionProgram)
```

Add `:execution_program_id` to `from_plan_changeset/2` cast list only if the context sets it in attrs. If the context sets associations directly, keep it out of cast and use `put_change/3` in `Workouts`.

Modify `lib/burpee_trainer/workouts/workout_plan.ex`:

```elixir
alias BurpeeTrainer.Workouts.ExecutionProgram
```

Add fields/association:

```elixir
field(:source_json, :map)
belongs_to(:current_execution_program, ExecutionProgram)
```

Add `:source_json` and `:current_execution_program_id` to the changeset cast list. Keep old associations temporarily until Task 8 removes call sites.

- [ ] **Step 8: Run migration and tests**

Run:

```bash
mix ecto.migrate
MIX_ENV=test mix ecto.reset
mix test test/burpee_trainer/execution_programs_test.exs
```

Expected: migration succeeds and test passes.

- [ ] **Step 9: Commit task**

Run:

```bash
jj describe -m "feat(program): persist immutable execution programs"
jj new
```

Expected: new empty working-copy change.

---

### Task 4: Add plan source and compiler facade

**Files:**

- Create: `lib/burpee_trainer/plan_compiler/plan_source.ex`
- Create: `lib/burpee_trainer/plan_compiler.ex`
- Modify: `lib/burpee_trainer/plan_solver/even_solver.ex`
- Modify: `lib/burpee_trainer/plan_solver/unbroken_solver.ex`
- Modify: `lib/burpee_trainer/plan_solver/execution.ex`
- Test: `test/burpee_trainer/plan_compiler_test.exs`

**Interfaces:**

- Produces: `PlanSource.new/1 :: map -> {:ok, PlanSource.t()} | {:error, CompileError.t()}`
- Produces: `PlanCompiler.compile/1 :: PlanSource.t() | map -> {:ok, Program.t()} | {:error, CompileError.t()}`
- Consumes: existing solver policy and solved event ordering.

- [ ] **Step 1: Write failing compiler tests**

Create `test/burpee_trainer/plan_compiler_test.exs`:

```elixir
defmodule BurpeeTrainer.PlanCompilerTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.PlanCompiler
  alias BurpeeTrainer.PlanCompiler.{Program, ProgramEvent}

  test "compiles saved-up even rest source into canonical program events" do
    source = %{
      name: "100 in 20",
      burpee_type: :six_count,
      target_reps: 100,
      target_duration_sec: 1_200,
      pacing_style: :even,
      block_pattern: [10],
      explicit_rests: [%{target_elapsed_sec: 600, duration_sec: 60, tolerance_sec: 90}]
    }

    assert {:ok, %Program{} = program} = PlanCompiler.compile(source)
    assert Program.total_reps(program) == 100
    assert_in_delta Program.duration_sec(program), 1_200.0, 1.0e-6

    work_events = Enum.filter(program.events, &match?(%ProgramEvent.Work{}, &1))
    rest_events = Enum.filter(program.events, &match?(%ProgramEvent.Rest{}, &1))

    assert length(work_events) == 10
    assert length(rest_events) == 1
    assert Enum.map(work_events, & &1.reps) == List.duplicate(10, 10)
    assert Enum.map(Enum.take(work_events, 5), & &1.sec_per_rep) == List.duplicate(10.8, 5)
    assert Enum.map(Enum.drop(work_events, 5), & &1.sec_per_rep) == List.duplicate(12.0, 5)
  end

  test "compile errors are structured" do
    assert {:error, error} = PlanCompiler.compile(%{burpee_type: :six_count})
    assert error.code == :invalid_source
    assert is_binary(error.message)
    assert is_map(error.context)
  end
end
```

- [ ] **Step 2: Run RED test**

Run:

```bash
mix test test/burpee_trainer/plan_compiler_test.exs
```

Expected: compile failure because `PlanCompiler` does not exist.

- [ ] **Step 3: Implement source struct**

Create `lib/burpee_trainer/plan_compiler/plan_source.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler.PlanSource do
  @moduledoc "Editable workout source normalized for compilation."

  alias BurpeeTrainer.PlanCompiler.CompileError

  @enforce_keys [:burpee_type, :target_reps, :target_duration_sec, :pacing_style]
  defstruct [
    :name,
    :burpee_type,
    :target_reps,
    :target_duration_sec,
    :pacing_style,
    :max_unbroken_reps,
    block_pattern: nil,
    explicit_rests: [],
    sec_per_rep_override: nil,
    pace_bias: :balanced,
    load_shape: :even
  ]

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, CompileError.t()}
  def new(attrs) when is_map(attrs) do
    source = %__MODULE__{
      name: get(attrs, :name),
      burpee_type: get(attrs, :burpee_type),
      target_reps: get(attrs, :target_reps) || get(attrs, :burpee_count_target),
      target_duration_sec: get(attrs, :target_duration_sec),
      pacing_style: get(attrs, :pacing_style),
      max_unbroken_reps: get(attrs, :max_unbroken_reps) || get(attrs, :reps_per_set),
      block_pattern: get(attrs, :block_pattern),
      explicit_rests: get(attrs, :explicit_rests) || [],
      sec_per_rep_override: get(attrs, :sec_per_rep_override),
      pace_bias: get(attrs, :pace_bias) || :balanced,
      load_shape: get(attrs, :load_shape) || :even
    }

    validate(source)
  end

  defp validate(%__MODULE__{} = source) do
    cond do
      source.burpee_type not in [:six_count, :navy_seal] ->
        invalid(:burpee_type, source.burpee_type)

      source.pacing_style not in [:even, :unbroken] ->
        invalid(:pacing_style, source.pacing_style)

      not (is_integer(source.target_reps) and source.target_reps > 0) ->
        invalid(:target_reps, source.target_reps)

      not (is_integer(source.target_duration_sec) and source.target_duration_sec > 0) ->
        invalid(:target_duration_sec, source.target_duration_sec)

      source.pacing_style == :unbroken and
          not (is_integer(source.max_unbroken_reps) and source.max_unbroken_reps > 0) ->
        invalid(:max_unbroken_reps, source.max_unbroken_reps)

      true ->
        {:ok, source}
    end
  end

  defp invalid(field, value) do
    {:error,
     CompileError.new(:invalid_source, "Workout source is invalid", %{field: field, value: value})}
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
```

- [ ] **Step 4: Implement compiler facade using existing solver internals as compiler internals**

Create `lib/burpee_trainer/plan_compiler.ex`:

```elixir
defmodule BurpeeTrainer.PlanCompiler do
  @moduledoc "Compiles editable workout source into immutable execution programs."

  alias BurpeeTrainer.PlanCompiler.{CompileError, PlanSource, Program, ProgramEvent, ProgramValidator}
  alias BurpeeTrainer.PlanSolver.{Execution, ExplicitRest, Input}
  alias BurpeeTrainer.PlanSolver

  @solver_version 4
  @schema_version 1

  @spec compile(PlanSource.t() | map()) :: {:ok, Program.t()} | {:error, CompileError.t()}
  def compile(%PlanSource{} = source), do: compile_source(source)

  def compile(attrs) when is_map(attrs) do
    with {:ok, source} <- PlanSource.new(attrs) do
      compile_source(source)
    end
  end

  defp compile_source(%PlanSource{} = source) do
    input = %Input{
      name: source.name,
      burpee_type: source.burpee_type,
      target_duration_sec: source.target_duration_sec,
      burpee_count_target: source.target_reps,
      pacing_style: source.pacing_style,
      max_unbroken_reps: source.max_unbroken_reps,
      block_pattern: source.block_pattern,
      explicit_rests: Enum.map(source.explicit_rests, &explicit_rest/1),
      sec_per_rep_override: source.sec_per_rep_override,
      pace_bias: source.pace_bias,
      load_shape: source.load_shape
    }

    with {:ok, solution} <- PlanSolver.solve(input),
         {:ok, program} <- program_from_execution(source, solution.execution, solution.metadata),
         :ok <- ProgramValidator.validate(program) do
      {:ok, program}
    else
      {:error, %CompileError{} = error} -> {:error, error}
      {:error, messages} when is_list(messages) ->
        {:error, CompileError.new(:solver_infeasible, Enum.join(messages, " "), %{messages: messages})}
      {:error, reason} ->
        {:error, CompileError.new(:compile_failed, "Workout source could not be compiled", %{reason: reason})}
    end
  end

  defp explicit_rest(%ExplicitRest{} = rest), do: rest
  defp explicit_rest(rest) when is_map(rest) do
    %ExplicitRest{
      target_elapsed_sec: get(rest, :target_elapsed_sec),
      duration_sec: get(rest, :duration_sec),
      tolerance_sec: get(rest, :tolerance_sec) || 60
    }
  end

  defp program_from_execution(source, execution, metadata) do
    Program.new(%{
      schema_version: @schema_version,
      solver_version: @solver_version,
      burpee_type: source.burpee_type,
      target_reps: source.target_reps,
      target_duration_sec: source.target_duration_sec,
      events: Enum.with_index(execution, 1) |> Enum.map(fn {event, index} -> program_event(event, index) end),
      metadata: Map.merge(metadata || %{}, %{source: :plan_compiler})
    })
  end

  defp program_event(%Execution.SetEvent{} = event, _index) do
    ProgramEvent.work!(%{
      id: "work-#{pad(event.index)}",
      set_index: event.index,
      block_index: nil,
      display_group: nil,
      reps: event.burpee_count,
      duration_sec: event.duration_sec,
      sec_per_rep: event.sec_per_rep,
      label: "Set #{event.index}"
    })
  end

  defp program_event(%Execution.RestEvent{} = event, index) do
    ProgramEvent.rest!(%{
      id: "rest-#{pad(index)}",
      duration_sec: event.rest_sec,
      label: "Rest",
      source: event.source
    })
  end

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
```

This step still calls the existing solver, but only as compiler internals. It does not expose old plan blocks/steps as runtime truth.

- [ ] **Step 5: Run compiler tests**

Run:

```bash
mix test test/burpee_trainer/plan_compiler_test.exs test/burpee_trainer/plan_compiler/program_test.exs test/burpee_trainer/plan_compiler/program_hash_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit task**

Run:

```bash
jj describe -m "feat(compiler): compile workout source to execution programs"
jj new
```

Expected: new empty working-copy change.

---

### Task 5: Make WorkoutPlan source-oriented and compile on create/update

**Files:**

- Modify: `lib/burpee_trainer/workouts/workout_plan.ex`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer/workout_feed.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`

**Interfaces:**

- Consumes: `PlanCompiler.compile/1` and `ExecutionPrograms.get_or_insert/1`.
- Produces: `Workouts.compile_plan/1 :: WorkoutPlan.t() -> {:ok, ExecutionProgram.t()} | {:error, term()}`
- Produces: `Workouts.plan_source_attrs/1 :: WorkoutPlan.t() -> map()` private helper.

- [ ] **Step 1: Write failing Workouts tests**

Add to `test/burpee_trainer/workouts_test.exs`:

```elixir
test "creating a plan stores source_json and current execution program", %{user: user} do
  attrs = %{
    "name" => "100 in 20",
    "source_json" => %{
      "burpee_type" => "six_count",
      "target_reps" => 100,
      "target_duration_sec" => 1_200,
      "pacing_style" => "even",
      "block_pattern" => [10],
      "explicit_rests" => [%{"target_elapsed_sec" => 600, "duration_sec" => 60, "tolerance_sec" => 90}]
    }
  }

  assert {:ok, plan} = Workouts.create_plan(user, attrs)
  assert plan.source_json["target_reps"] == 100
  assert plan.current_execution_program_id
end

test "deleting a plan preserves performed session facts", %{user: user} do
  assert {:ok, plan} =
           Workouts.create_plan(user, %{
             "name" => "10 in 2",
             "source_json" => %{
               "burpee_type" => "six_count",
               "target_reps" => 10,
               "target_duration_sec" => 120,
               "pacing_style" => "even",
               "block_pattern" => [10],
               "explicit_rests" => []
             }
           })

  program = BurpeeTrainer.ExecutionPrograms.get!(plan.current_execution_program_id)

  assert {:ok, session} =
           Workouts.create_session_from_plan(user, plan, %{
             "burpee_count_actual" => 10,
             "duration_sec_actual" => 118,
             "client_session_id" => Ecto.UUID.generate(),
             "execution_program_id" => program.id
           })

  assert {:ok, _plan} = Workouts.delete_plan(plan)
  session = Workouts.get_session!(user, session.id)

  assert session.plan_id == nil
  assert session.execution_program_id == program.id
  assert session.burpee_count_actual == 10
end
```

If the existing test setup does not provide `%{user: user}`, adapt to the fixture helper already used in that file.

- [ ] **Step 2: Run RED tests**

Run:

```bash
mix test test/burpee_trainer/workouts_test.exs
```

Expected: failures because `source_json` create/update does not compile plans yet.

- [ ] **Step 3: Update `WorkoutPlan` schema**

In `lib/burpee_trainer/workouts/workout_plan.ex`, keep old fields temporarily for compile stability, but make `source_json` the required source for new writes:

```elixir
field(:source_json, :map)
belongs_to(:current_execution_program, BurpeeTrainer.Workouts.ExecutionProgram)
```

Update changeset cast list with:

```elixir
:source_json,
:current_execution_program_id
```

Change required validation to:

```elixir
|> validate_required([:name, :source_json])
```

Keep `:burpee_type` validation only if old form paths still submit it in this task. Task 8 removes old source paths.

- [ ] **Step 4: Compile on create/update**

Modify `lib/burpee_trainer/workouts.ex`:

```elixir
alias BurpeeTrainer.{ExecutionPrograms, PlanCompiler}
alias BurpeeTrainer.Workouts.ExecutionProgram
```

Replace `create_plan/2` with a compile-first flow:

```elixir
def create_plan(%User{id: user_id}, attrs) do
  with {:ok, program} <- compile_source_attrs(attrs),
       {:ok, persisted_program} <- ExecutionPrograms.get_or_insert(program) do
    attrs =
      attrs
      |> Map.put("current_execution_program_id", persisted_program.id)
      |> put_source_summary(program)

    %WorkoutPlan{user_id: user_id}
    |> WorkoutPlan.changeset(attrs)
    |> Repo.insert()
  end
end
```

Replace `update_plan/2` similarly:

```elixir
def update_plan(%WorkoutPlan{} = plan, attrs) do
  with {:ok, program} <- compile_source_attrs(attrs),
       {:ok, persisted_program} <- ExecutionPrograms.get_or_insert(program) do
    attrs =
      attrs
      |> Map.put("current_execution_program_id", persisted_program.id)
      |> put_source_summary(program)

    plan
    |> WorkoutPlan.changeset(attrs)
    |> Repo.update()
  end
end
```

Add helpers:

```elixir
@spec compile_plan(WorkoutPlan.t()) :: {:ok, ExecutionProgram.t()} | {:error, term()}
def compile_plan(%WorkoutPlan{current_execution_program_id: id}) when is_integer(id) do
  {:ok, ExecutionPrograms.get!(id)}
end

def compile_plan(%WorkoutPlan{source_json: source}) when is_map(source) do
  with {:ok, program} <- PlanCompiler.compile(source) do
    ExecutionPrograms.get_or_insert(program)
  end
end

defp compile_source_attrs(attrs) do
  source = Map.get(attrs, "source_json") || Map.get(attrs, :source_json)
  PlanCompiler.compile(source || %{})
end

defp put_source_summary(attrs, %BurpeeTrainer.PlanCompiler.Program{} = program) do
  attrs
  |> Map.put("burpee_type", Atom.to_string(program.burpee_type))
  |> Map.put("target_duration_min", round(program.target_duration_sec / 60))
  |> Map.put("burpee_count_target", program.target_reps)
  |> Map.put("sec_per_burpee", average_work_pace(program))
  |> Map.put("pacing_style", Atom.to_string(program.metadata[:pacing_style] || :even))
end

defp average_work_pace(program) do
  work_events = Enum.filter(program.events, &match?(%BurpeeTrainer.PlanCompiler.ProgramEvent.Work{}, &1))
  total_reps = Enum.reduce(work_events, 0, &(&1.reps + &2))
  total_work = Enum.reduce(work_events, 0.0, &(&1.duration_sec + &2))

  if total_reps > 0, do: Float.round(total_work / total_reps, 1), else: 0.0
end
```

- [ ] **Step 5: Update workout feed summary**

In `lib/burpee_trainer/workout_feed.ex`, replace `Planner.summary(plan)` in `plan_to_item/2` with current program summary:

```elixir
program =
  case plan.current_execution_program_id do
    nil -> nil
    id -> BurpeeTrainer.ExecutionPrograms.get!(id)
  end

count = if program, do: program.target_reps, else: plan.burpee_count_target || 0
duration = if program, do: program.target_duration_sec, else: (plan.target_duration_min || 0) * 60
level = Levels.level_for_count(plan.burpee_type, count)
```

Remove `alias BurpeeTrainer.Planner` if unused.

- [ ] **Step 6: Run Workouts tests**

Run:

```bash
mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer/execution_programs_test.exs
```

Expected: tests pass.

- [ ] **Step 7: Commit task**

Run:

```bash
jj describe -m "feat(workouts): compile plans into immutable programs"
jj new
```

Expected: new empty working-copy change.

---

### Task 6: Refactor SessionLive server boundary to run programs

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`

**Interfaces:**

- Consumes: `Workouts.compile_plan/1` and `ExecutionProgram.program_json`.
- Produces: `serialize_program/1 :: ExecutionProgram.t() -> map()` private function.
- Produces: session save attrs with `execution_program_id`.

- [ ] **Step 1: Write failing SessionLive tests**

Add to `test/burpee_trainer_web/live/session_live_test.exs`:

```elixir
test "session ready payload contains canonical program events and no derived plan timeline", %{conn: conn, user: user} do
  {:ok, plan} =
    BurpeeTrainer.Workouts.create_plan(user, %{
      "name" => "10 in 2",
      "source_json" => %{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "even",
        "block_pattern" => [10],
        "explicit_rests" => []
      }
    })

  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  assert_push_event view, "session_ready", payload
  assert payload.program_id == plan.current_execution_program_id
  assert payload.program_hash
  assert [%{kind: "work", reps: 10, duration_sec: 120.0}] = payload.events
  refute Map.has_key?(payload, :blocks)
  refute Map.has_key?(payload, :timeline)
end
```

If the existing test helper uses string keys for pushed payloads, assert against `%{"program_id" => ...}` instead.

- [ ] **Step 2: Run RED SessionLive test**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: failure because payload currently sends `plan.timeline` and blocks.

- [ ] **Step 3: Replace plan serialization with program serialization**

In `lib/burpee_trainer_web/live/session_live.ex`, replace `serialize_plan/1` and `serialize_execution_timeline/1` usage with:

```elixir
defp serialize_program(%BurpeeTrainer.Workouts.ExecutionProgram{} = program) do
  %{
    program_id: program.id,
    program_hash: program.content_hash,
    target_reps: program.target_reps,
    target_duration_sec: program.target_duration_sec,
    events: program_events_for_runner(program.program_json),
    display: Map.get(program.summary_json || %{}, "display", %{})
  }
end

defp program_events_for_runner(%{"events" => events}) when is_list(events) do
  Enum.map(events, fn
    %{"kind" => "work"} = event ->
      %{
        id: event["id"],
        kind: "work",
        phase: "work",
        set_index: event["set_index"],
        block_index: event["block_index"],
        reps: event["reps"],
        burpee_count: event["reps"],
        duration_sec: event["duration_ms"] / 1000,
        sec_per_rep: event["sec_per_rep_ms"] / 1000,
        sec_per_burpee: event["sec_per_rep_ms"] / 1000,
        label: "Set #{event["set_index"]}"
      }

    %{"kind" => "rest"} = event ->
      %{
        id: event["id"],
        kind: "rest",
        phase: "rest",
        duration_sec: event["duration_ms"] / 1000,
        burpee_count: nil,
        reps: nil,
        sec_per_rep: nil,
        sec_per_burpee: nil,
        label: "Rest"
      }
  end)
end
```

Keep `phase` temporarily because current JS uses it. Task 7 renames JS internals to `kind` while accepting `phase` during the transition.

- [ ] **Step 4: Compile/load program during mount**

Where `SessionLive` loads a plan, add:

```elixir
{:ok, execution_program} = Workouts.compile_plan(plan)
summary = program_summary(execution_program)
```

Add private summary:

```elixir
defp program_summary(program) do
  %{
    burpee_count_total: program.target_reps,
    duration_sec_total: program.target_duration_sec,
    blocks: []
  }
end
```

Push:

```elixir
push_event(socket, "session_ready", serialize_program(execution_program))
```

Assign `:execution_program` for save.

- [ ] **Step 5: Save execution program id with session**

In session completion attrs, add:

```elixir
"execution_program_id" => socket.assigns.execution_program.id
```

Ensure planned snapshots come from program summary:

```elixir
"burpee_count_planned" => socket.assigns.execution_program.target_reps,
"duration_sec_planned" => socket.assigns.execution_program.target_duration_sec
```

- [ ] **Step 6: Run server tests**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs test/burpee_trainer/workouts_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Commit task**

Run:

```bash
jj describe -m "feat(session): run canonical execution programs"
jj new
```

Expected: new empty working-copy change.

---

### Task 7: Refactor JS runner to consume program events

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_plan.mjs`
- Modify: `assets/js/hooks/session_segment_fsm.mjs`
- Modify: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify/Create: `assets/js/hooks/session_program_test.mjs`

**Interfaces:**

- Consumes: server payload `{program_id, program_hash, target_reps, target_duration_sec, events}`.
- Produces: `workoutTimelineFromProgram(program) :: event[]`.
- Produces: `programBurpeeCount(programOrEvents) :: number`.

- [ ] **Step 1: Write failing JS program tests**

Create `assets/js/hooks/session_program_test.mjs`:

```javascript
import { describe, expect, it } from "vitest";
import {
	programBurpeeCount,
	setBarsFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";

describe("canonical session program helpers", () => {
	const program = {
		program_id: 7,
		program_hash: "abc",
		target_reps: 20,
		target_duration_sec: 300,
		events: [
			{
				id: "work-001",
				kind: "work",
				reps: 10,
				burpee_count: 10,
				duration_sec: 120,
				sec_per_rep: 12,
				label: "Set 1",
			},
			{id: "rest-001", kind: "rest", duration_sec: 60, label: "Rest"},
			{
				id: "work-002",
				kind: "work",
				reps: 10,
				burpee_count: 10,
				duration_sec: 120,
				sec_per_rep: 12,
				label: "Set 2",
			},
		],
	};

	it("returns canonical events without deriving from blocks", () => {
		expect(workoutTimelineFromProgram(program)).toEqual(program.events);
	});

	it("counts reps from work events", () => {
		expect(programBurpeeCount(program)).toBe(20);
	});

	it("derives one set bar per work event", () => {
		expect(setBarsFromProgram(program)).toEqual([
			{id: "work-001", index: 1, reps: 10, label: "Set 1"},
			{id: "work-002", index: 2, reps: 10, label: "Set 2"},
		]);
	});
});
```

- [ ] **Step 2: Run RED JS test**

Run:

```bash
cd assets && npm test -- session_program_test.mjs
```

Expected: failure because new exports do not exist.

- [ ] **Step 3: Replace plan timeline helpers**

Modify `assets/js/hooks/session_plan.mjs` to export program helpers:

```javascript
export function workoutTimelineFromProgram(program) {
	return Array.isArray(program?.events) ? program.events : [];
}

export function programBurpeeCount(programOrEvents) {
	const events = Array.isArray(programOrEvents)
		? programOrEvents
		: workoutTimelineFromProgram(programOrEvents);

	return events.reduce((total, event) => {
		if ((event.kind || event.phase) !== "work") return total;
		return total + (event.reps || event.burpee_count || 0);
	}, 0);
}

export function setBarsFromProgram(program) {
	return workoutTimelineFromProgram(program)
		.filter((event) => (event.kind || event.phase) === "work")
		.map((event, index) => ({
			id: event.id || `work-${index + 1}`,
			index: event.set_index || index + 1,
			reps: event.reps || event.burpee_count || 0,
			label: event.label || `Set ${index + 1}`,
		}));
}

export function warmupTimelineFromProgram(program) {
	const firstWork = workoutTimelineFromProgram(program).find(
		(event) => (event.kind || event.phase) === "work",
	);

	if (!firstWork) return [];

	const secPerBurpee =
		firstWork.sec_per_rep ||
		firstWork.sec_per_burpee ||
		firstWork.duration_sec / (firstWork.reps || firstWork.burpee_count || 1);
	if (!secPerBurpee || secPerBurpee <= 0) return [];

	const warmupReps = Math.min(
		firstWork.reps || firstWork.burpee_count || 0,
		Math.trunc(60 / secPerBurpee),
	);
	if (warmupReps <= 0) return [];

	const durationSec = warmupReps * secPerBurpee;

	return [
		{
			id: "warmup-work-001",
			kind: "work",
			phase: "work",
			duration_sec: durationSec,
			reps: warmupReps,
			burpee_count: warmupReps,
			sec_per_rep: secPerBurpee,
			sec_per_burpee: secPerBurpee,
			label: "Warmup Round 1",
		},
		{
			id: "warmup-rest-001",
			kind: "rest",
			phase: "rest",
			duration_sec: 120,
			burpee_count: null,
			sec_per_burpee: null,
			label: "Warmup Rest",
		},
		{
			id: "warmup-work-002",
			kind: "work",
			phase: "work",
			duration_sec: durationSec,
			reps: warmupReps,
			burpee_count: warmupReps,
			sec_per_rep: secPerBurpee,
			sec_per_burpee: secPerBurpee,
			label: "Warmup Round 2",
		},
		{
			id: "warmup-rest-002",
			kind: "rest",
			phase: "rest",
			duration_sec: 180,
			burpee_count: null,
			sec_per_burpee: null,
			label: "Warmup Rest",
		},
	];
}
```

- [ ] **Step 4: Update `session_hook.js` imports and state names**

Replace imports:

```javascript
import {
	programBurpeeCount,
	warmupTimelineFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";
```

When handling server payload, store:

```javascript
this.program = payload;
this.plan = payload;
```

Keep `this.plan = payload` only where display code still references `plan`; remove it after all references are renamed in the same task.

Replace calls:

```javascript
warmupTimelineFromPlan(this.plan)
workoutTimelineFromPlan(this.plan)
timelineBurpeeCount(warmupTimeline)
```

with:

```javascript
warmupTimelineFromProgram(this.program)
workoutTimelineFromProgram(this.program)
programBurpeeCount(warmupTimeline)
```

- [ ] **Step 5: Make FSM event checks accept `kind`**

In `assets/js/hooks/session_segment_fsm.mjs`, replace direct phase checks with helper:

```javascript
function eventKind(event) {
	return event?.kind || event?.phase;
}
```

Use `eventKind(event) === "work"` and `eventKind(event) === "rest"` anywhere the FSM currently reads `event.phase`.

- [ ] **Step 6: Run JS tests**

Run:

```bash
cd assets && npm test
```

Expected: all JS tests pass.

- [ ] **Step 7: Commit task**

Run:

```bash
jj describe -m "feat(session): interpret canonical program events in runner"
jj new
```

Expected: new empty working-copy change.

---

### Task 8: Remove legacy execution reconstruction paths

**Files:**

- Modify: `lib/burpee_trainer/plan_solver/apply.ex`
- Modify: `lib/burpee_trainer/plan_solver/execution.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `lib/burpee_trainer/prescription_graph.ex` if no remaining production call sites exist
- Modify/Delete: tests that assert old `Apply.to_workout_plan` behavior

**Interfaces:**

- Removes: public runtime dependence on `Apply.to_workout_plan`.
- Removes: `SessionLive.serialize_execution_timeline/1` fallback from blocks/steps.
- Keeps: solver internals only if still needed by `PlanCompiler`.

- [ ] **Step 1: Find legacy call sites**

Run:

```bash
rg "Apply\.to_workout_plan|serialize_execution_timeline|PrescriptionGraph\.build|additional_rests" lib test assets
```

Expected: call sites are limited to tests or code scheduled for removal in this task.

- [ ] **Step 2: Delete or privatize `Apply.to_workout_plan`**

In `lib/burpee_trainer/plan_solver/apply.ex`, remove the public `to_workout_plan/4` and `to_workout_plan/5` functions. Keep only functions that are still used by compiler tests or delete the module if no production path needs persisted block/step plans.

If deleting the whole module causes too much churn in this task, replace public legacy functions with compile-time absence by deleting their definitions rather than leaving compatibility shims.

- [ ] **Step 3: Remove SessionLive timeline reconstruction**

Delete private functions from `lib/burpee_trainer_web/live/session_live.ex` when no longer called:

```elixir
serialize_execution_timeline/1
serialize_plan_step/2
serialize_execution_node/1
block_events/1
decode_additional_rests/1
```

The only runner serialization function should be `serialize_program/1`.

- [ ] **Step 4: Remove JS block-derived fallback**

Ensure `assets/js/hooks/session_plan.mjs` has no `sortedBlocks`, `sortedSets`, or `blockTimeline` functions.

- [ ] **Step 5: Update tests to assert absence of old runtime path**

Add to `test/burpee_trainer_web/live/session_live_test.exs`:

```elixir
test "session runner payload does not expose mutable plan execution structures", %{conn: conn, user: user} do
  {:ok, plan} =
    BurpeeTrainer.Workouts.create_plan(user, %{
      "name" => "10 in 2",
      "source_json" => %{
        "burpee_type" => "six_count",
        "target_reps" => 10,
        "target_duration_sec" => 120,
        "pacing_style" => "even",
        "block_pattern" => [10],
        "explicit_rests" => []
      }
    })

  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  assert_push_event view, "session_ready", payload
  refute Map.has_key?(payload, :blocks)
  refute Map.has_key?(payload, :steps)
  refute Map.has_key?(payload, :additional_rests)
  assert is_list(payload.events)
end
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs test/burpee_trainer/plan_compiler_test.exs test/burpee_trainer/workouts_test.exs
cd assets && npm test
```

Expected: all tests pass.

- [ ] **Step 7: Commit task**

Run:

```bash
jj describe -m "refactor(session): remove mutable plan execution reconstruction"
jj new
```

Expected: new empty working-copy change.

---

### Task 9: Refactor plan editor source persistence

**Files:**

- Modify: `lib/burpee_trainer_web/live/plans_live/edit.ex`
- Modify: `lib/burpee_trainer_web/live/plans_live/edit/*.heex`
- Modify: `test/burpee_trainer_web/live/workouts_live_test.exs`
- Modify/Create: plan editor tests under `test/burpee_trainer_web/live/plans_live/`

**Interfaces:**

- Consumes: `WorkoutPlan.source_json`.
- Produces: editor save params containing only `name` and `source_json` for execution semantics.

- [ ] **Step 1: Add editor test for source JSON save**

Create or modify a LiveView test to assert that creating a workout results in a plan with source JSON and current program ID:

```elixir
test "new workout editor saves editable source and compiles current program", %{conn: conn, user: user} do
  {:ok, view, _html} = live(conn, ~p"/workouts/new")

  view
  |> form("#workout-form", %{
    "workout_plan" => %{
      "name" => "100 in 20",
      "source_json" => %{
        "burpee_type" => "six_count",
        "target_reps" => 100,
        "target_duration_sec" => 1_200,
        "pacing_style" => "even",
        "block_pattern" => [10],
        "explicit_rests" => []
      }
    }
  })
  |> render_submit()

  [plan] = BurpeeTrainer.Workouts.list_plans(user)
  assert plan.source_json["target_reps"] == 100
  assert plan.current_execution_program_id
end
```

Adapt the form selector to the actual ID in the template. If the editor is not form-posting nested JSON today, add a hidden input that submits encoded source and decode it in `PlansLive.Edit`.

- [ ] **Step 2: Run RED editor tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs
```

Expected: failure until editor saves `source_json`.

- [ ] **Step 3: Add source encoder/decoder in `PlansLive.Edit`**

In `lib/burpee_trainer_web/live/plans_live/edit.ex`, add helpers:

```elixir
defp source_from_form(params) do
  %{
    "burpee_type" => params["burpee_type"],
    "target_reps" => parse_int(params["target_reps"]),
    "target_duration_sec" => parse_int(params["target_duration_sec"]),
    "pacing_style" => params["pacing_style"],
    "block_pattern" => parse_block_pattern(params["block_pattern"]),
    "explicit_rests" => parse_explicit_rests(params["explicit_rests"] || [])
  }
end

defp parse_int(value) when is_integer(value), do: value
defp parse_int(value) when is_binary(value), do: String.to_integer(value)

defp parse_block_pattern(values) when is_list(values), do: Enum.map(values, &parse_int/1)
defp parse_block_pattern(value) when is_binary(value) do
  value
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.map(&String.to_integer/1)
end

defp parse_explicit_rests(rests) when is_list(rests), do: rests
```

When saving, pass:

```elixir
attrs = %{
  "name" => params["name"],
  "source_json" => source_from_form(params)
}
```

- [ ] **Step 4: Keep UI components but stop saving runtime blocks**

Editor screens can still display blocks/sets as source editing controls. They must submit source JSON, not persisted `blocks`, `sets`, `steps`, or `additional_rests` as runtime truth.

Remove calls in the editor that build plan blocks solely for execution persistence. Keep source-preview helpers only if they call `PlanCompiler.compile/1` for preview.

- [ ] **Step 5: Run editor and compiler tests**

Run:

```bash
mix test test/burpee_trainer_web/live/workouts_live_test.exs test/burpee_trainer/plan_compiler_test.exs test/burpee_trainer/workouts_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit task**

Run:

```bash
jj describe -m "refactor(editor): save workouts as compiler source"
jj new
```

Expected: new empty working-copy change.

---

### Task 10: Clean schema/code after source/program cutover

**Files:**

- Create: generated migration from `mix ecto.gen.migration drop_legacy_plan_execution_tables`
- Modify: `lib/burpee_trainer/workouts.ex`
- Delete or stop referencing: `lib/burpee_trainer/workouts/block.ex`
- Delete or stop referencing: `lib/burpee_trainer/workouts/set.ex`
- Delete or stop referencing: `lib/burpee_trainer/workouts/plan_step.ex`
- Modify: tests that referenced blocks/sets as runtime truth

**Interfaces:**

- Removes old persisted execution tables from the active model.
- Keeps completed sessions.

- [ ] **Step 1: Generate cleanup migration**

Run:

```bash
mix ecto.gen.migration drop_legacy_plan_execution_tables
```

Expected: Mix prints a migration path ending in `_drop_legacy_plan_execution_tables.exs`.

- [ ] **Step 2: Drop old execution tables and columns**

Edit generated migration:

```elixir
defmodule BurpeeTrainer.Repo.Migrations.DropLegacyPlanExecutionTables do
  use Ecto.Migration

  def up do
    drop_if_exists table(:plan_steps)
    drop_if_exists table(:sets)
    drop_if_exists table(:blocks)

    alter table(:workout_plans) do
      remove :additional_rests
      remove :plan_solver_metadata
    end
  end

  def down do
    alter table(:workout_plans) do
      add :additional_rests, :text
      add :plan_solver_metadata, :map
    end

    create table(:blocks) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :repeat_count, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create table(:sets) do
      add :block_id, references(:blocks, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :burpee_count, :integer, null: false
      add :sec_per_rep, :float, null: false
      add :sec_per_burpee, :float, null: false, default: 3.0
      add :end_of_set_rest, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create table(:plan_steps) do
      add :plan_id, references(:workout_plans, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :kind, :string, null: false
      add :block_position, :integer
      add :repeat_count, :integer
      add :rest_sec, :integer
      timestamps(type: :utc_datetime)
    end
  end
end
```

If `drop_if_exists table(:plan_steps)` fails because `plan_steps` was created in a later migration with constraints, use ordinary `drop table(:plan_steps)` after confirming the table exists in all environments.

- [ ] **Step 3: Remove schema aliases/preloads**

In `lib/burpee_trainer/workouts.ex`:

- remove aliases `Block`, `Set`, `PlanStep`
- remove preloads `[blocks: :sets, steps: []]`
- remove duplicate block/step helpers
- make `duplicate_plan/1` duplicate `source_json` and compile a fresh current program

Replacement duplicate attrs:

```elixir
attrs = %{
  "name" => source.name <> " (copy)",
  "source_json" => source.source_json
}
```

- [ ] **Step 4: Remove schema modules from production references**

Run:

```bash
rg "BurpeeTrainer.Workouts\.(Block|Set|PlanStep)|blocks:|steps:|\.blocks|\.steps" lib test
```

Expected: no production runtime references. Remaining docs or migration references are acceptable.

- [ ] **Step 5: Run full Elixir tests**

Run:

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit task**

Run:

```bash
jj describe -m "refactor(workouts): drop legacy plan execution tables"
jj new
```

Expected: new empty working-copy change.

---

### Task 11: Final verification and polish

**Files:**

- Modify: any files with diagnostics from prior tasks.
- Modify: docs if implementation differs from spec in a meaningful way.

**Interfaces:**

- Produces: verified end-to-end refactor.

- [ ] **Step 1: Run JS tests**

Run:

```bash
cd assets && npm test
```

Expected: all JS tests pass.

- [ ] **Step 2: Run Elixir precommit**

Run:

```bash
mix precommit
```

Expected: all ExUnit tests pass and formatter/compile checks pass.

- [ ] **Step 3: Run diagnostics**

Run via pi lens:

```text
lens_diagnostics mode=all severity=error
```

Expected: no error issues in edited files.

- [ ] **Step 4: Inspect jj state**

Run:

```bash
jj st
jj log -r 'ancestors(@, 5)'
```

Expected: current change has only intended final polish or is empty after task commits.

- [ ] **Step 5: Produce implementation summary**

Write a concise summary covering:

- new `ExecutionProgram` architecture
- source/program/session boundaries
- data reset behavior for old plans
- session preservation behavior
- runner UI preservation
- verification commands and results

- [ ] **Step 6: Commit final polish**

Run:

```bash
jj describe -m "chore(program): verify canonical workout program refactor"
```

If the current change is non-empty, run:

```bash
jj new
```

Expected: clean working-copy commit on top of the verified stack.

---

## Self-Review Checklist

- Spec coverage: Tasks 1–2 cover canonical program and hash; Task 3 covers persistence/session link; Tasks 4–5 cover compiler/source; Tasks 6–7 cover SessionLive and JS runner; Tasks 8–10 remove legacy runtime paths and reset old plan templates; Task 11 verifies all work.
- Deferred-marker scan: the plan intentionally avoids deferred implementation markers and names exact APIs, modules, commands, and assertions.
- Type consistency: `Program.t()`, `ProgramEvent.Work`, `ProgramEvent.Rest`, `ExecutionProgram`, `PlanSource.t()`, and `PlanCompiler.compile/1` are introduced before downstream tasks consume them.
- Data policy: completed `workout_sessions` are preserved; old workout plan templates are explicitly reset.
- UI policy: runner UI features are preserved through program-derived display projections.
