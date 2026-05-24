# Skill-Aligned Refactor Design

## Purpose

Refactor the project so its highest-risk implementation details better match the loaded Elixir/OTP, Tiger Style, and type-driven-development guidance while preserving current product behavior.

The refactor is risk-ordered: fix known runtime boundary issues first, then improve typed public surfaces, then extract large LiveView state logic, then introduce refined domain values where they remove repeated parsing or validation.

## Goals

- Remove the raw unsupervised coach-learning task started after session saves.
- Remove inline custom JavaScript from the root layout.
- Add precise specs to public functions touched by the refactor and high-churn schema/context surfaces.
- Extract plan-editor state transitions from `BurpeeTrainerWeb.PlansLive.Edit` into pure, testable domain code.
- Introduce refined domain value modules only where they replace existing repeated primitive parsing or validation.
- Keep existing user-visible behavior unchanged unless a current behavior is clearly a bug exposed by tests.

## Non-goals

- Redesign the visual UI.
- Rewrite all LiveViews.
- Replace Ecto changesets for form validation.
- Add broad abstractions that are used only once.
- Change database schema unless a phase proves it is necessary.

## Phase 1: Runtime Boundary Cleanup

### Coach learning boundary

Current session saves call `Task.start(fn -> Coach.update_arms(...) end)` from `BurpeeTrainer.Workouts.create_session_from_plan/3`. This creates an unsupervised process that uses the Repo after the session save returns. During `mix precommit`, tests pass but log DB sandbox ownership and foreign-key errors from that task.

Replace this with an explicit boundary module, tentatively `BurpeeTrainer.Coach.Learning`, responsible for running post-session coach updates.

Expected shape:

- `Workouts.create_session_from_plan/3` inserts the session and delegates to the boundary.
- The boundary exposes a small API, such as `record_session_completed(user, session)`.
- Runtime execution uses a named supervised task boundary under the application supervisor.
- Test execution is deterministic and sandbox-safe. Prefer synchronous execution in tests unless a supervised-task test setup is clearly simpler.
- Expected failures are returned or logged as atoms/tagged tuples. Unexpected failures crash inside the supervised boundary rather than inside LiveView/request code.

Application supervision should add `Task.Supervisor` only if async execution remains the chosen behavior. If synchronous execution is chosen for all environments, do not add a supervisor just for ceremony.

### Theme script relocation

Move the inline theme initializer from `lib/burpee_trainer_web/components/layouts/root.html.heex` into `assets/js/app.js` or a small module imported by `app.js`.

The root layout keeps only the normal Phoenix asset script tag. Theme behavior must remain equivalent:

- apply saved `phx:theme` from `localStorage`;
- clear `data-theme` for `system`;
- respond to `storage` events;
- respond to Phoenix `phx:set-theme` events.

## Phase 2: Typed Public Surfaces

Add `@spec`s to public functions touched by phase 1 and nearby high-churn schema/context modules. Prioritize functions whose contracts matter across module boundaries:

- session changeset constructors in `BurpeeTrainer.Workouts.WorkoutSession`;
- plan changeset helpers in `BurpeeTrainer.Workouts.WorkoutPlan`;
- coach learning boundary functions;
- public auth/context helpers touched during the refactor.

Specs should describe actual behavior, not desired behavior. If a function currently returns an Ecto changeset, keep that contract. Do not introduce new result tuples unless behavior is intentionally changed and covered by tests.

## Phase 3: Plan Editor Extraction

`BurpeeTrainerWeb.PlansLive.Edit` is large and currently owns UI rendering, params parsing, solver input construction, form state, and derived plan calculations. Extract pure editor state logic into a domain module, tentatively `BurpeeTrainer.PlanEditor`.

The LiveView remains responsible for:

- mount/event plumbing;
- reading current user and params;
- assigning forms and flash messages;
- rendering HEEx;
- navigation.

The extracted module should own pure transitions such as:

- building default editor input;
- applying coach params;
- converting an existing plan to editor input;
- regenerating solver-backed blocks;
- computing derived summary/constraint state;
- applying user edits to editor state.

The extracted state should be a struct with typed fields where practical. Avoid a generic `state` map. Public functions should return either updated state or named expected errors.

This phase should be incremental. The first extraction should move cohesive pure logic without changing templates. Further extraction can follow once tests prove behavior is preserved.

## Phase 4: Refined Domain Values

Introduce small value modules only when they replace repeated raw primitive handling. Candidate modules:

- `BurpeeTrainer.Mood` for `-1 | 0 | 1`;
- `BurpeeTrainer.BurpeeType` for `:six_count | :navy_seal` and string parsing;
- `BurpeeTrainer.PacingStyle` for supported pacing styles;
- `BurpeeTrainer.Duration` for seconds/minutes conversion and non-negative duration parsing.

Each value module must provide parse/smart-constructor functions that return refined values:

```elixir
{:ok, value} | {:error, reason}
```

Use atoms or tagged tuples for expected error reasons. Do not return booleans from parsers. Do not convert arbitrary user input to atoms.

Ecto schemas may still store primitive fields because that is the database boundary. The refined values should reduce ambiguity in domain and LiveView code, not fight Ecto.

## Error Handling

- Expected failures return `{:error, atom | tagged_tuple}`.
- Ecto changesets remain the form-validation error carrier.
- Background coach-learning failures are handled at the coach-learning boundary.
- Assertions are reserved for impossible internal states, not user input.

## Testing Strategy

Phase 1:

- Verify session creation still succeeds.
- Verify coach learning no longer logs sandbox ownership errors during `mix precommit`.
- Verify theme initialization behavior remains available through the app bundle.

Phase 2:

- Run compiler/tests after adding specs.
- Keep behavior unchanged unless a spec exposes an existing bug.

Phase 3:

- Add unit tests for extracted `PlanEditor` transitions.
- Keep existing LiveView tests passing.
- Prefer assertions on outcomes and stable DOM IDs over raw HTML strings when editing tests.

Phase 4:

- Add parser/smart-constructor tests for each refined domain module.
- Update callers incrementally so each refined type has an immediate use.

Final verification for the whole refactor:

- `mix precommit` exits successfully.
- No unexpected background-task errors are logged.
- Existing tests still pass.
- New tests cover the extracted/refined behavior.

## Implementation Order

1. Runtime boundary cleanup and theme script relocation.
2. Specs on touched public functions.
3. First `PlanEditor` extraction with pure unit tests.
4. Refined domain values introduced one at a time.

Each phase should be small enough to review independently and should not mix unrelated formatting or UI redesign changes.
