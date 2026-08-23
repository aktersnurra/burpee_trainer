# Even-Pacing Phase-Counting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make even-paced runner progress advance when each active rep interval ends, hold through rest, finish at the final active interval, and never mistake schedule progress for a camera-confirmed actual rep.

**Architecture:** Keep the runner's existing timeline count as scheduled pace progress and expose it explicitly in terminal results. The flow FSM then stores scheduled progress separately from observed camera results. The completion UI identifies camera-confirmed counts versus an unresolved count that the user must enter. The compiler rejects any program ending in rest, enforcing the no-final-rest rule at the trusted program boundary.

**Tech Stack:** Phoenix/LiveView HEEx, Elixir/ExUnit, browser-native ES modules, Node `node:test`, Jujutsu.

## Global Constraints

- Missing, cropped, or low-confidence camera observations are silent no-ops; timer progress must never fabricate an actual rep.
- Scheduled pace progress advances only at active work-interval boundaries and is unchanged during rest.
- An execution program must end in work; no final rest is valid for even pacing.
- Duration remains schedule-derived; do not introduce wall-clock duration inference.
- Preserve UUID-scoped lifecycle recovery, bounded trace uploads, and all HSMM landmark/fixture boundaries.
- Do not modify the unrelated, pre-existing working-copy change in `assets/js/hooks/session_hook.js` outside changes required by this plan.

---

### Task 1: Reject terminal rest in canonical execution programs

**Files:**

- Modify: `test/burpee_trainer/plan_compiler/program_test.exs`
- Modify: `lib/burpee_trainer/plan_compiler/program_validator.ex`

**Interfaces:**

- Consumes: `Program.events/1`, `ProgramEvent.Work`, `ProgramEvent.Rest`, and `ProgramValidator.validate/1`.
- Produces: `{:error, %CompileError{code: :terminal_rest}}` for a program whose last event is rest.

- [ ] **Step 1: Write the failing validator test**

Add this test to `test/burpee_trainer/plan_compiler/program_test.exs`:

```elixir
test "validator rejects a program ending in rest" do
  assert {:ok, program} =
           Program.new(%{
             schema_version: 2,
             solver_version: 4,
             burpee_type: :six_count,
             target_reps: 1,
             target_duration_sec: 15,
             events: [
               ProgramEvent.work!(%{reps: 1, sec_per_rep: 10.0, sec_per_burpee: 5.0}),
               ProgramEvent.rest!(%{duration_sec: 5})
             ],
             metadata: %{pacing_style: :even}
           })

  assert {:error, %CompileError{code: :terminal_rest}} = ProgramValidator.validate(program)
end
```

- [ ] **Step 2: Run the focused test to verify RED**

Run: `mix test test/burpee_trainer/plan_compiler/program_test.exs`

Expected: FAIL because `ProgramValidator.validate/1` currently accepts a final rest.

- [ ] **Step 3: Add the terminal-work invariant**

In `lib/burpee_trainer/plan_compiler/program_validator.ex`, insert `validate_terminal_work(program.events)` between `validate_events/1` and `validate_reps/1` in `validate/1`, then add:

```elixir
defp validate_terminal_work(events) do
  case List.last(events) do
    %ProgramEvent.Work{} ->
      :ok

    %ProgramEvent.Rest{} ->
      {:error,
       CompileError.new(:terminal_rest, "Program must end with a work event")}
  end
end
```

Keep `validate_events([])` as the sole empty-list handler; `validate_terminal_work/1` is called only after it succeeds.

- [ ] **Step 4: Run focused compiler and solver tests to verify GREEN**

Run: `mix test test/burpee_trainer/plan_compiler/program_test.exs test/burpee_trainer/plan_compiler_test.exs test/burpee_trainer/plan_solver/even_solver_test.exs`

Expected: all pass; the generated even program with its explicit mid-workout rest remains valid because its last event is work.

- [ ] **Step 5: Commit the invariant**

```bash
jj describe -m "fix(pacing): reject terminal rest events"
jj new
```

### Task 2: Expose active-interval pace progress in the segment result

**Files:**

- Modify: `assets/js/hooks/session_segment_fsm_test.mjs`
- Modify: `assets/js/hooks/session_segment_fsm.mjs`

**Interfaces:**

- Consumes: timeline frames shaped as `{kind: "work", reps, sec_per_rep}` and `{kind: "rest", duration_sec}` plus `segmentTransition/2` events.
- Produces: terminal `segmentDone.result` with both legacy `burpeeCountDone` and explicit `scheduledRepsDone`, each equal to the completed active intervals.

- [ ] **Step 1: Write the failing active/rest timing regression**

Add this test to `assets/js/hooks/session_segment_fsm_test.mjs`:

```javascript
test("active completion advances pace progress before rest and final active ends the segment", () => {
  const timeline = [
    { kind: "work", reps: 1, sec_per_rep: 10 },
    { kind: "rest", duration_sec: 5 },
    { kind: "work", reps: 1, sec_per_rep: 10 },
  ];
  let state = segmentTransition(initialSegmentState(), {
    type: "SEGMENT_READY",
    timeline,
    burpeeCountTarget: 2,
  }).state;
  state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

  state = segmentTransition(state, { type: "TICK", elapsedSec: 10 }).state;
  assert.equal(state.reps.burpeeCountDone, 1);

  state = segmentTransition(state, { type: "TICK", elapsedSec: 14.9 }).state;
  assert.equal(state.reps.burpeeCountDone, 1);

  const complete = segmentTransition(state, { type: "TICK", elapsedSec: 25 });
  const done = complete.commands.find((command) => command.type === "segmentDone");
  assert.deepEqual(done.result, {
    burpeeCountDone: 2,
    scheduledRepsDone: 2,
    durationSec: 25,
  });
});
```

- [ ] **Step 2: Run the focused test to verify RED**

Run: `cd assets && node --test --test-name-pattern='active completion advances pace progress' js/hooks/session_segment_fsm_test.mjs`

Expected: FAIL because `scheduledRepsDone` is not yet emitted by `segmentDone`.

- [ ] **Step 3: Add one terminal-result helper and use it in both finish paths**

In `assets/js/hooks/session_segment_fsm.mjs`, add this helper immediately before `finalizeSegment/2`:

```javascript
function segmentResult(reps, elapsedSec) {
  return {
    burpeeCountDone: reps.burpeeCountDone,
    scheduledRepsDone: reps.burpeeCountDone,
    durationSec: Math.round(elapsedSec),
  };
}
```

Replace the inline `segmentDone.result` objects in both `finalizeSegment/2` and the terminal branch of `tickSegment/2` with `segmentResult(...)`. Do not change `accountReps/3`: it already increments at the active-work boundary and leaves the value unchanged in rest.

- [ ] **Step 4: Run the segment suite to verify GREEN**

Run: `cd assets && node --test js/hooks/session_segment_fsm_test.mjs`

Expected: all tests pass, including delayed-tick clamping and the new active→rest→final-active regression.

- [ ] **Step 5: Commit the explicit schedule result**

```bash
jj describe -m "feat(pacing): expose scheduled interval progress"
jj new
```

### Task 3: Keep scheduled pace progress separate from observed actuals

**Files:**

- Modify: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `lib/burpee_trainer_web/components/session_components.ex`

**Interfaces:**

- Consumes: `segmentDone.result.scheduledRepsDone`, optional `detectedReps`, and `trackingTrust`.
- Produces: `completion.scheduledRepsDone`; `completion.burpeeCountActual` is an integer only after finished camera tracking, otherwise `null`; no-camera completion asks for a user-entered actual count.

- [ ] **Step 1: Write failing flow and renderer tests**

In `assets/js/hooks/session_flow_fsm_test.mjs`, change the existing no-camera `SESSION_DONE` test to pass `scheduledRepsDone: 12` and assert:

```javascript
assert.equal(result.state.completion.scheduledRepsDone, 12);
assert.equal(result.state.completion.burpeeCountActual, null);
assert.equal(result.state.completion.durationSecActual, 75);
```

In the existing camera completion test, pass `scheduledRepsDone: 5` and assert both facts:

```javascript
assert.equal(result.state.completion.scheduledRepsDone, 5);
assert.equal(result.state.completion.burpeeCountActual, 4);
```

In `assets/js/hooks/session_hook_flow_test.mjs`, add a completion-rendering case with:

```javascript
{
  scheduledRepsDone: 2,
  burpeeCountActual: null,
  burpeeCountPlanned: 3,
  durationSecActual: 25,
  mood: 0,
  tags: [],
  notePost: "",
}
```

Assert `#session-actual-reps` contains `—`, `#completion-reps-input` is empty, and `#session-count-source` is visible with `Pace progress: 2 of 3. Enter actual reps below.`.

- [ ] **Step 2: Run the focused tests to verify RED**

Run:

```bash
cd assets && node --test \
  js/hooks/session_flow_fsm_test.mjs \
  js/hooks/session_hook_flow_test.mjs
```

Expected: FAIL because no-camera completion still copies `burpeeCountDone` to `burpeeCountActual`, and the renderer serializes `null` as text instead of presenting an unresolved input.

- [ ] **Step 3: Map schedule and observed facts separately**

In `assets/js/hooks/session_flow_fsm.mjs`, derive schedule progress before returning completion:

```javascript
const scheduledRepsDone =
  result.scheduledRepsDone ?? result.burpeeCountDone ?? 0;
```

Return `scheduledRepsDone` on every completion. Set `burpeeCountActual` to `result.detectedReps ?? 0` only when `trackingFinished`; otherwise set it to `null`. Keep `durationSecActual` schedule-derived for no-camera completion and camera-detected for completed tracking.

In `assets/js/hooks/session_hook.js`, preserve `scheduled_reps_done` in `completionDraft/0`; restore it with a zero fallback in `restoreCompletionDraft/2`. Do not add it to `completionPayload/0`, because the server report schema remains authoritative for actual persisted fields.

- [ ] **Step 4: Render the distinction plainly and accessibly**

In `lib/burpee_trainer_web/components/session_components.ex`, change the initial screen-reader text under `#total-reps-accessible` to describe pace progress rather than actual reps.

In `assets/js/hooks/session_renderer.mjs` `renderCompletion/1`:

```javascript
const hasActualReps = Number.isInteger(completion.burpeeCountActual);
const scheduledRepsDone = completion.scheduledRepsDone ?? 0;
const countSource = this.root.querySelector("#session-count-source");

if (actualReps) {
  actualReps.textContent = hasActualReps
    ? String(completion.burpeeCountActual)
    : "—";
}
if (repsInput) repsInput.value = hasActualReps ? String(completion.burpeeCountActual) : "";
if (countSource) {
  countSource.textContent = hasActualReps
    ? "Camera-confirmed reps"
    : `Pace progress: ${scheduledRepsDone} of ${completion.burpeeCountPlanned}. Enter actual reps below.`;
  countSource.hidden = false;
}
```

Keep a manual entry authoritative: existing `COMPLETION_EDITED` continues to replace the `null` count with the user-entered integer before save.

- [ ] **Step 5: Run focused tests to verify GREEN**

Run:

```bash
cd assets && node --test \
  js/hooks/session_flow_fsm_test.mjs \
  js/hooks/session_hook_flow_test.mjs
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all pass; a no-camera completion shows pace progress and an empty actual-reps input, while a finished camera run still pre-fills only HSMM-confirmed reps.

- [ ] **Step 6: Run the browser smoke scenario**

Follow `docs/testing/workout-session-e2e.md` using a three-rep even timeline with `work(10s) → rest(5s) → work(10s)`.

Verify, with fresh browser observations:

1. Runner total displays `0/2` before the first active interval ends.
2. At 10 seconds it displays `1/2`.
3. During rest it remains `1/2`.
4. At 25 seconds it reaches `2/2` and enters completion with no final rest screen.
5. With camera disabled, completion says `Pace progress: 2 of 2. Enter actual reps below.` and leaves the actual-reps input empty.
6. With controlled camera fixture evidence absent, actual reps remain zero only for a completed camera run; no inferred camera rep is written.

- [ ] **Step 7: Commit the fact separation and UI copy**

```bash
jj describe -m "fix(pacing): separate schedule from observed reps"
jj new
```

## Final Verification

- [ ] Run `cd assets && npm test`; expect all JavaScript tests passing.
- [ ] Run `mix precommit`; expect all ExUnit, formatting, and project checks passing.
- [ ] Run `mix assets.deploy`, then confirm the deploy app bundle excludes `__burpeePoseFixture`, `pose_tracker_fixture`, and `app_fixture`, while preserving the allowed `controlledPoseFixture` seam.
- [ ] Run `lsp_diagnostics` on every touched Elixir and JavaScript file, then `lens_diagnostics` with `mode: all`.
- [ ] Perform a whole-branch review before moving or publishing the signed `workout-session-redesign` bookmark.
