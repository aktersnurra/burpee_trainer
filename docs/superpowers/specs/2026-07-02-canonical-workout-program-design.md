# Burpee Trainer — Canonical Workout Program Redesign

> **Status:** design specification  
> **Scope:** replace mutable-plan-derived execution with a clean source → compiler → immutable program → runner model.  
> **Source of truth:** this document supersedes legacy block/step/additional-rest execution semantics.

## 1. Core abstraction

Model workouts like computer programs:

```text
WorkoutPlan          editable source code
PlanCompiler/Solver  compiler
ExecutionProgram     immutable compiled executable / IR
SessionRunner        VM / interpreter
WorkoutSession       run trace / result
Stats                profiler / analytics
```

This is not only a metaphor. It defines the boundaries:

- The editable plan is not executable truth.
- The compiler owns all timing, cadence, set, and rest semantics.
- The runner interprets a compiled program; it does not reconstruct timing from editor data.
- A completed session records actual facts and links to the exact immutable program that was attempted.

The product goal is execution accuracy first. Readable blocks/sets and rich UI displays are projections from the canonical program, not sources of execution truth.

---

## 2. Problem statement

The current model lets several layers reconstruct workout execution:

- `WorkoutPlan.blocks`
- `Block.sets`
- `PlanStep`
- `additional_rests` JSON
- `PrescriptionGraph`
- `SessionLive.serialize_execution_timeline/1`
- `assets/js/hooks/session_plan.mjs`

This creates competing truths. It makes a saved workout session ambiguous when the underlying plan is edited later, and it forces the runner UI to infer executable behavior from mutable editor/persistence structures.

The old assumption no longer holds:

> A workout plan is stable enough to explain a historical session.

Plans are editable. Sessions need immutable planned provenance.

---

## 3. Goals

1. Make `ExecutionProgram` the canonical executable workout artifact.
2. Keep `WorkoutPlan` editable and disposable.
3. Preserve completed sessions and stats.
4. Delete or reset old workout plans rather than preserving messy compatibility.
5. Refactor the session runner to consume only canonical program data.
6. Preserve the nice runner UI: count-in, set bars, current set display, rest countdown, beeps, and progress.
7. Make exact historical intent recoverable for a performed session.
8. Deduplicate immutable programs by canonical content hash.
9. Keep APIs clean even if that requires data reset for old plan templates.

---

## 4. Non-goals

This redesign does not need to:

- preserve old workout plans, blocks, sets, or steps
- make old mutable plans executable after the migration
- preserve legacy `Apply.to_workout_plan` call sites
- keep `additional_rests` as runtime truth
- add full workout-plan revision history
- rebuild old completed session timelines from deleted plans
- change actual session stats semantics

Completed workout sessions must remain. Old plan templates may be deleted/reset.

---

## 5. Data ownership

### 5.1 WorkoutPlan — editable source

`WorkoutPlan` is the user's editable workout source. It should eventually contain intent-level fields, not runtime execution structure.

Examples of source-level data:

- name
- burpee type
- target reps
- target duration
- pacing style
- preferred block pattern / source structure
- explicit rest requests
- UI/editor settings

A plan may be changed or deleted without altering historical sessions.

### 5.2 ExecutionProgram — immutable executable

`ExecutionProgram` is the compiled canonical workout.

It is immutable and content-addressed. If the same canonical program is compiled twice, reuse the existing row.

Minimum schema:

```text
execution_programs
- id
- content_hash          unique
- schema_version
- solver_version
- burpee_type
- target_reps
- target_duration_sec
- event_count
- program_json          canonical executable payload
- summary_json          derived display/stat summary
- inserted_at
- updated_at
```

`updated_at` exists for Ecto conventions only; semantic updates are not allowed. Changing the program creates a new row with a new hash.

### 5.3 WorkoutSession — actual run trace/result

`WorkoutSession` records what happened.

Keep scalar planned snapshots for fast stats and resilience:

```text
burpee_count_planned
duration_sec_planned
```

Add immutable provenance:

```text
execution_program_id references execution_programs(id), on_delete: nilify_all
```

Keep `plan_id` as optional provenance only:

```text
plan_id references workout_plans(id), on_delete: nilify_all
```

A session can remain meaningful if both plan and program are missing, because it still carries actual facts. But normal new sessions should link to an `ExecutionProgram`.

---

## 6. Canonical program payload

Use a versioned JSON payload with deterministic ordering and key shape.

Example:

```json
{
  "schema_version": 1,
  "solver_version": 4,
  "burpee_type": "six_count",
  "target_reps": 100,
  "target_duration_sec": 1200,
  "events": [
    {
      "id": "work-001",
      "kind": "work",
      "set_index": 1,
      "block_index": 1,
      "reps": 10,
      "duration_sec": 108.0,
      "sec_per_rep": 10.8,
      "label": "Set 1"
    },
    {
      "id": "rest-001",
      "kind": "rest",
      "duration_sec": 60,
      "label": "Rest"
    }
  ],
  "metadata": {
    "pacing_style": "even",
    "recovery_model": "saved_up_rest",
    "source": "plan_solver"
  }
}
```

Program events are the runner's instruction stream. They must not depend on mutable plan blocks or step rows.

### 6.1 Event invariants

Every program must satisfy:

1. Event IDs are unique and stable within the program.
2. Events are ordered.
3. Work events have positive `reps`, positive `duration_sec`, and positive `sec_per_rep`.
4. Rest events have positive `duration_sec`.
5. Total work reps equal `target_reps`.
6. Total event duration equals `target_duration_sec` within canonical precision.
7. No implicit trailing rest exists unless it is an explicit event.
8. Program JSON is deterministic before hashing.

### 6.2 Precision

Use integer milliseconds internally where possible. JSON may expose seconds as numbers for UI convenience, but hashing should use canonical normalized values.

Do not round solver values before building the program. Round only in display projections.

---

## 7. Hashing and deduplication

Hash the semantic executable payload, not the mutable plan.

Included in hash:

- schema version
- solver version or compiler semantic version
- burpee type
- target reps
- target duration
- ordered events
- event reps/durations/cadences
- pacing/recovery metadata that changes execution semantics

Excluded from hash:

- database IDs
- timestamps
- plan name
- owner/user ID
- display-only labels if labels do not affect execution

Implementation API:

```elixir
ExecutionPrograms.get_or_insert!(program)
```

or result-style:

```elixir
ExecutionPrograms.get_or_insert(program) ::
  {:ok, %ExecutionProgram{}} | {:error, reason}
```

The content hash is a dedupe and integrity mechanism. The core abstraction is immutability.

---

## 8. Compiler architecture

Recommended modules:

```text
BurpeeTrainer.Workouts.PlanSource
BurpeeTrainer.PlanCompiler
BurpeeTrainer.PlanCompiler.Program
BurpeeTrainer.PlanCompiler.ProgramEvent
BurpeeTrainer.PlanCompiler.ProgramHash
BurpeeTrainer.PlanCompiler.ProgramValidator
BurpeeTrainer.ExecutionPrograms
```

Alternative naming under existing `PlanSolver` is acceptable if the boundary stays clean:

```text
BurpeeTrainer.PlanSolver.ExecutionProgram
BurpeeTrainer.PlanSolver.ProgramEvent
BurpeeTrainer.PlanSolver.ProgramHash
BurpeeTrainer.PlanSolver.ProgramValidator
```

The high-level flow:

```text
WorkoutPlan source
  -> PlanSource.from_plan/1
  -> PlanCompiler.compile/1
  -> ProgramValidator.validate/1
  -> ProgramHash.hash/1
  -> ExecutionPrograms.get_or_insert/1
  -> SessionLive starts runner with program
```

The compiler may internally use even/unbroken solvers, prescriptions, and structure search. Those are compiler internals.

---

## 9. Solver relationship

The solver should emit an `ExecutionProgram` directly or emit a strict intermediate that is immediately compiled into one.

Preferred final shape:

```elixir
PlanCompiler.compile(source) ::
  {:ok, %Program{}} | {:error, %CompileError{}}
```

`Prescription` may remain temporarily as internal metadata, but it must not be the runtime source of truth.

`Execution.build/1` should either become program construction or disappear behind the compiler.

`Apply` should stop creating execution semantics. It may persist editor/source data, but not runtime truth.

---

## 10. Persistence redesign

Because we are allowed to remove old workout plans, prefer a clean migration path:

1. Add `execution_programs` table.
2. Add `workout_sessions.execution_program_id` nullable FK.
3. Clear old plan template data in dev/local environments:
   - `plan_steps`
   - `sets`
   - `blocks`
   - `workout_plans`
4. Keep `workout_sessions`.
5. New plans use the new source shape and compile to programs before running.

If the existing plan schema is too tied to blocks/sets, create a new source schema rather than bending old tables:

```text
workout_plans
- id
- user_id
- name
- source_json
- current_execution_program_id nullable
- inserted_at
- updated_at
```

This is cleaner than preserving relational blocks/sets if those tables only exist to support old execution reconstruction.

---

## 11. Session runner redesign

The session runner should consume only program data.

### 11.1 Server boundary

`SessionLive` should load or create an `ExecutionProgram` before the runner starts.

Server payload:

```elixir
%{
  program_id: program.id,
  program_hash: program.content_hash,
  target_reps: program.target_reps,
  target_duration_sec: program.target_duration_sec,
  events: program.program_json["events"],
  display: program.summary_json["display"]
}
```

Remove server fallback timeline reconstruction from:

- `plan.steps`
- `plan.blocks`
- `additional_rests`
- `PrescriptionGraph`

### 11.2 Client boundary

JS receives a `program`, not a `plan`.

Delete fallback derivation from `assets/js/hooks/session_plan.mjs` once the server always sends canonical events.

Runner responsibilities:

- count-in / startup sequence
- warmup if product wants warmup outside the program
- clock
- current frame
- rep accounting
- beeps
- display rendering
- completion payload

Runner non-responsibilities:

- deriving workout timeline from blocks
- placing rests
- calculating set cadence
- correcting planned duration
- interpreting mutable editor structures

### 11.3 Count-in and warmup

Count-in is runner behavior, not part of the compiled workout program.

Warmup can be one of two designs:

1. Runner-managed prelude derived from first work event.
2. Separate compiled `warmup_program` generated by the compiler.

Use option 1 initially unless warmup needs exact historical provenance.

---

## 12. Preserving rich runner UI

The runner UI components are preserved by deriving display projections from the program.

### 12.1 Vertical set bars

Source:

```text
program.events where kind == "work"
```

Each work event becomes one bar.

Display state:

- pending
- current
- completed
- partially completed

Current bar is selected by current event ID/index.

### 12.2 Set labels and block grouping

If block grouping matters visually, include non-execution grouping metadata on work events:

```json
{
  "kind": "work",
  "set_index": 5,
  "block_index": 1,
  "block_label": "Block 1",
  "display_group": "block-1"
}
```

This metadata is derived by the compiler and stable inside the program. The UI does not infer it from old block tables.

### 12.3 Rest countdown

Rest events are explicit program events. The existing rest countdown maps directly to current rest event duration and remaining time.

### 12.4 Rep beeps and down cues

Work events include `sec_per_rep`, `reps`, and `duration_sec`. Existing beep logic can become simpler because every work frame has canonical cadence.

---

## 13. Session save semantics

When saving a session:

- use `execution_program_id` from the active runner
- keep `plan_id` if the session started from a plan
- copy planned scalar snapshots from the program
- store actual result from the runner payload

Required attributes:

```text
burpee_type
burpee_count_planned
duration_sec_planned
burpee_count_actual
duration_sec_actual
execution_program_id
client_session_id
```

`plan_id` remains optional.

---

## 14. Error model

Use structured compile errors instead of strings at the core:

```elixir
%CompileError{
  code: :cannot_place_explicit_rest,
  message: "Explicit rest cannot be placed on a valid boundary",
  context: %{target_elapsed_sec: 600, duration_sec: 60}
}
```

UI-facing strings can be produced at the LiveView boundary.

---

## 15. Testing strategy

### 15.1 Program unit tests

- valid program computes expected reps and duration
- malformed event is rejected
- duplicate event IDs are rejected
- hash is stable for semantically identical payloads
- hash changes when executable semantics change

### 15.2 Compiler tests

- even saved-up-rest example compiles to exact expected program
- unbroken structure compiles to exact reps and duration
- explicit rest placement is encoded as a rest event
- no implicit trailing rests
- compiler errors are structured

### 15.3 Persistence tests

- `get_or_insert` dedupes identical programs
- sessions can link to programs
- deleting a plan does not delete sessions
- deleting or missing a plan leaves session stats intact

### 15.4 Runner tests

- JS runner consumes canonical program events
- no block/plan fallback required
- set bars derive from work events
- current frame, rep accounting, and beeps still work
- completion payload carries program/session identifiers

### 15.5 End-to-end tests

- create/edit plan source
- compile/start session
- complete session
- verify session stores actuals, planned snapshots, and program ID
- edit/delete plan
- verify completed session remains accurate

---

## 16. Migration/data reset policy

This redesign intentionally does not preserve old workout plan templates.

Approved reset:

```text
old workout plans/templates: disposable
completed workout sessions: preserve
```

Because `workout_sessions.plan_id` already uses `on_delete: :nilify_all`, deleting plans preserves performed workouts.

Before destructive migrations, use explicit migration names and ensure test/dev seeds are updated.

---

## 17. Implementation phases

### Phase 1 — Program domain core

- Add program/event structs.
- Add validator.
- Add stable canonical encoder/hash.
- Add unit tests.

### Phase 2 — Program persistence

- Add `execution_programs` migration.
- Add `workout_sessions.execution_program_id`.
- Add context API for get-or-insert.
- Add persistence tests.

### Phase 3 — Compiler emits programs

- Refactor even/unbroken solver output to program events.
- Keep readable source/display metadata in program payload.
- Remove runtime dependence on `Apply.to_workout_plan` for new flow.

### Phase 4 — Session runner consumes programs

- Refactor `SessionLive` payload from plan to program.
- Refactor JS from `plan` to `program` where execution is concerned.
- Preserve count-in, set bars, beeps, rest display, completion flow.

### Phase 5 — Delete legacy execution paths

- Remove plan-step/block timeline reconstruction.
- Remove `additional_rests` runtime semantics.
- Delete or quarantine old tests that assert legacy persistence structure.
- Reset old workout templates.

---

## 18. Open decisions

None blocking implementation.

Deliberate defaults:

- No full `WorkoutPlanRevision` table yet.
- Deduplicate immutable programs by hash.
- Preserve sessions, delete old plan templates.
- Keep count-in runner-managed.
- Use program display metadata for set bars/block labels.

---

## 19. Success criteria

The redesign is successful when:

1. A session runner never reconstructs execution from mutable plan blocks/steps.
2. Every new session can identify the immutable program it attempted.
3. Editing/deleting a workout plan cannot change historical planned intent.
4. Saved-up rest behavior remains exact in the compiled program.
5. Existing rich runner UI still works from program projections.
6. Old plan compatibility code is removed rather than patched around.
7. `mix precommit` passes.
