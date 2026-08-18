# Zero-Setup HSMM Camera Counting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace calibration and confidence-loss degradation with a local, zero-setup HSMM that counts one observed body-to-floor-to-standing macro-cycle.

**Architecture:** A new bounded pose-feature HSMM owns only outer-cycle inference: `upright → lowering_to_floor → floor_work → returning_from_floor → upright`. It treats unusable frames as absent observations and emits one rep only on a completed macro-cycle. `PoseTracker` publishes that count; the session FSM persists it as camera-counted unless the user explicitly changes it.

**Tech Stack:** Vanilla ES modules, BlazePose landmarks, Phoenix LiveView, ExUnit, Node test runner.

## Global Constraints

- Keep all pose inference client-side; add no model download, server inference, training corpus, or TCN.
- Do not show, persist, or trace ordinary absent/low-confidence frames as tracking loss, degradation, or out-of-frame state.
- Do not infer a burpee completed wholly without usable pose observations.
- Do not alter durable lifecycle UUID/state transitions or deferred trace upload digest/retry behavior.
- Use `jj --config signing.behavior=drop` for every Jujutsu mutation.

---

### Task 1: Build the general burpee macro-cycle HSMM

**Files:**
- Create: `assets/js/hooks/pose_burpee_hsmm.mjs`
- Create: `assets/js/hooks/pose_burpee_hsmm_test.mjs`
- Modify: `assets/js/hooks/pose_features.mjs`

**Interfaces:**
- Consumes: `featureFrameFromPose/4` output, including normalized landmark geometry and timestamp.
- Produces: `initialBurpeeHsmmState/0` and `stepBurpeeHsmm/2`.
- `stepBurpeeHsmm(state, frame)` returns `{state, rep: boolean, repAtMs: number | null}`.

- [ ] **Step 1: Write failing macro-cycle tests**

```js
import { initialBurpeeHsmmState, stepBurpeeHsmm } from './pose_burpee_hsmm.mjs';

test('counts one observed outer cycle regardless of internal pushup count', () => {
  let state = initialBurpeeHsmmState();
  const reps = onePushupCycle().concat(threePushupCycle()).flatMap((frame) => {
    const result = stepBurpeeHsmm(state, frame);
    state = result.state;
    return result.rep ? [result.repAtMs] : [];
  });
  assert.deepEqual(reps, [onePushupCycle().at(-1).tMs, threePushupCycle().at(-1).tMs]);
});

test('does not count a squat-only or interrupted floor sequence', () => {
  let state = initialBurpeeHsmmState();
  for (const frame of squatOnlyFrames().concat(interruptedFloorFrames())) {
    const result = stepBurpeeHsmm(state, frame);
    state = result.state;
    assert.equal(result.rep, false);
  }
});
```

Include fixtures for `upright`, `lowering_to_floor`, `floor_work`, and `returning_from_floor`; make `floor_work` include one and three pushup oscillations.

- [ ] **Step 2: Run the test to verify failure**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_test.mjs`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Add body-relative macro features and HSMM**

Add only the feature fields needed to distinguish hand/torso lowering, supported floor work, return-to-squat, and upright posture. Preserve the existing normalized landmark fields for debug tools.

```js
const PHASES = ['upright', 'lowering_to_floor', 'floor_work', 'returning_from_floor'];
const NEXT = {
  upright: ['upright', 'lowering_to_floor'],
  lowering_to_floor: ['lowering_to_floor', 'floor_work'],
  floor_work: ['floor_work', 'returning_from_floor'],
  returning_from_floor: ['returning_from_floor', 'upright'],
};

export function initialBurpeeHsmmState() {
  return { phase: 'upright', phaseStartedAtMs: null, lastRepAtMs: null, cadenceMs: [] };
}

export function stepBurpeeHsmm(state, frame) {
  if (!usable(frame)) return { state, rep: false, repAtMs: null };
  const phase = nextPhase(state, scoreMacroEmissions(frame));
  const next = transition(state, phase, frame.tMs);
  const rep = state.phase === 'returning_from_floor' && phase === 'upright' && outsideRefractory(state, frame.tMs);
  return { state: rep ? recordRep(next, frame.tMs) : next, rep, repAtMs: rep ? frame.tMs : null };
}
```

`usable/1` must reject only the current frame. It must not reset state, record a gap, or create a new phase. Duration bounds must expire an ambiguous partial path back to `upright` without emitting a rep. `floor_work` must remain active through any number of pushup motions.

- [ ] **Step 4: Run focused tests**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_test.mjs js/hooks/pose_features_test.mjs`

Expected: PASS; normal one-pushup and three-pushup cycles each count once, missing/interrupted/squat-only paths count zero.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'feat(tracking): add general burpee HSMM'
jj --config signing.behavior=drop new
```

### Task 2: Publish HSMM counts without confidence-loss degradation

**Files:**
- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Modify: `assets/js/hooks/pose_tracker_impl_test.mjs`
- Modify: `assets/js/hooks/pose_tracking_observer.mjs`
- Modify: `assets/js/hooks/pose_tracking_observer_test.mjs`

**Interfaces:**
- Consumes: `stepBurpeeHsmm/2` from Task 1.
- Produces: existing `pose-tracker:rep` events and monotonic `trackingFinishPayload` cadence.
- Ordinary absent observations produce no tracker status event.

- [ ] **Step 1: Write failing tracker regressions**

```js
test('keeps the same HSMM state through absent frames and counts the next full cycle', async () => {
  const tracker = mountedTrackerWithSamples([
    ...completeCycle(0), absentFrames(2600), ...completeCycle(4000),
  ]);
  await tracker.run();
  assert.deepEqual(tracker.repIndexes(), [1, 2]);
  assert.deepEqual(tracker.statusEvents(), ['live']);
});

test('does not emit a lost status for a low-confidence frame', async () => {
  const tracker = mountedTrackerWithSamples([upright(0), absent(100), upright(200)]);
  await tracker.run();
  assert.equal(tracker.statusEvents().includes('lost'), false);
});
```

- [ ] **Step 2: Run the test to verify failure**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/pose_tracking_observer_test.mjs`

Expected: FAIL because `pose_tracker_impl.mjs` calls `markLost('confidence_lost')` for an ordinary low-confidence sample.

- [ ] **Step 3: Wire the HSMM into the tracker**

Replace `initialCounterState/countRep` with `initialBurpeeHsmmState/stepBurpeeHsmm`. Feed `sample.features` to the HSMM and emit the existing `pose-tracker:rep` event only when `result.rep` is true. Remove the sample-confidence `markLost` branch. Keep readiness only for camera setup gestures; do not use workout-time readiness changes to alter reporting trust. Keep `markLost` for camera startup or detector exceptions only.

Simplify `pose_tracking_observer.mjs` so its finish result is `{cadenceMs, trusted: true}` for an active camera runtime with a valid monotonic duration. It must not degrade because a normal pose observation was absent.

- [ ] **Step 4: Run focused tracker tests**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/pose_tracking_observer_test.mjs js/hooks/pose_burpee_hsmm_test.mjs`

Expected: PASS; absent samples neither reset nor poison the runtime, and detector failures remain distinct setup/runtime errors.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'feat(tracking): tolerate absent pose observations'
jj --config signing.behavior=drop new
```

### Task 3: Remove degradation semantics from the session runner and reporting contract

**Files:**
- Modify: `assets/js/hooks/session_flow_fsm.mjs`
- Modify: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`
- Modify: `test/burpee_trainer/workouts_test.exs`

**Interfaces:**
- Consumes: a camera completion result `{detectedReps, detectedDurationSec, cadenceMs}`.
- Produces: tracking payload `{enabled: true, trust: 'finished', detected_reps, detected_duration_sec, cadence_ms}` for unchanged camera results.
- An explicit edited report is the sole route to `:camera_reviewed`; normal missing observations cannot select it.

- [ ] **Step 1: Write failing flow and context tests**

```js
test('camera completion pre-fills detected count after absent frames', () => {
  const result = step(cameraRunningState(), {
    type: 'SEGMENT_FINISHED',
    result: { burpeeCountDone: 99, detectedReps: 4, detectedDurationSec: 42, cadenceMs: [8_000, 18_000, 29_000, 42_000] },
  });
  assert.equal(result.state.completion.burpeeCountActual, 4);
  assert.equal(result.state.completion.trackingTrust, 'finished');
});

test 'a finished camera report is tracked and only an explicit edit is reviewed', %{user: user, plan: plan} do
  {:ok, session} = Workouts.begin_plan_session(user, plan, Ecto.UUID.generate())
  assert {:ok, tracked, :reported} = Workouts.report_session(user, session.client_session_id, camera_attrs(4, 42), finished_tracking(4, 42))
  assert tracked.capture_mode == :tracked
end
```

- [ ] **Step 2: Run the test to verify failure**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs && cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs`

Expected: FAIL because `completionFor/2` substitutes timer reps and the FSM/observer still contain `degraded` branches.

- [ ] **Step 3: Simplify flow, hook, and server provenance**

Remove `trackingReason`, `TRACKING_DEGRADED`, and all absence-derived `degraded` branches from the session FSM and hook. For a finished camera result, `completionFor/2` must use `detectedReps` as `burpeeCountActual`, preserve cadence, and mark trust `finished`.

In `workoutCompletionResult/1`, do not dispatch degradation because the tracker saw missing observations. Dispatch `TRACKING_FINISHED` when the active camera tracker supplies a valid finish payload. Preserve an explicit user edit as the existing server-side manual-correction comparison.

In `report_tracking_mode/2`, accept only a finished enabled payload with valid detected count/duration and matching submitted values as trusted. Keep mismatched explicit submitted values as `:manual_correction`. Delete acceptance paths that classify a confidence-loss reason as timed or reviewed.

- [ ] **Step 4: Run focused flow/context tests**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs && cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs`

Expected: PASS; a normal temporary absence never blanks Save, changes capture mode, or selects timer-derived actuals.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'fix(session): remove camera degradation fallback'
jj --config signing.behavior=drop new
```

### Task 4: Remove session calibration UI and prove the product contract

**Files:**
- Modify: `assets/js/app.js`
- Modify: `assets/js/hooks/pose_debug.js`
- Delete: `assets/js/hooks/pose_calibration_button.js`
- Delete: `assets/js/hooks/pose_template_calibration.mjs`
- Delete: `assets/js/hooks/pose_template_matcher.mjs`
- Modify: `lib/burpee_trainer_web/live/tracking_test_live.ex`
- Create: `assets/js/hooks/pose_burpee_hsmm_fixture_test.mjs`
- Modify: `docs/testing/workout-session-e2e.md`

**Interfaces:**
- Consumes: camera selection and existing pose-tracker start events.
- Produces: the existing camera-setup gesture path without a reference-rep/template workflow, no calibration/template dependency in the shipped JS bundle, and a controlled browser fixture for an absent-observation scenario.

- [ ] **Step 1: Write failing bundle-boundary and fixture tests**

```js
test('the app bundle has no calibration or template matcher dependency', async () => {
  const app = await readFile(new URL('../app.js', import.meta.url), 'utf8');
  assert.doesNotMatch(app, /pose_(?:calibration_button|template_calibration|template_matcher)/);
});

test('fixture absence between macro-cycles emits no warning and keeps Save enabled', async () => {
  const page = await runControlledPoseFixture([...completeCycle(0), ...absentFrames(2000), ...completeCycle(3500)]);
  assert.equal(page.count(), 2);
  assert.equal(page.hasText(/tracking degraded|out of frame/i), false);
  assert.equal(page.saveDisabled(), false);
});
```

Also add a focused LiveView render assertion that `tracking_test_live` has no `PoseCalibrationButton` or calibration/template control ID.

- [ ] **Step 2: Run the test to verify failure**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_fixture_test.mjs && cd .. && mix test test/burpee_trainer_web/live`

Expected: FAIL because `assets/js/app.js` imports calibration and template debug support, `tracking_test_live` renders its calibration control, and no controlled HSMM fixture exists.

- [ ] **Step 3: Remove all calibration/template dependencies and add the fixture**

Delete `pose_calibration_button.js`, `pose_template_calibration.mjs`, and `pose_template_matcher.mjs`. Remove their app registration and all corresponding state, imports, controls, copy, events, and DTW rendering from `PoseDebug` and `tracking_test_live`; retain unrelated pose overlay, decoder diagnostics, and trace tools. Add a deterministic fixture seam to the tracker so E2E can feed a fixed sequence of feature frames without a physical camera. Update the runbook to verify count continuity and the absence of warning/report changes, not a camera-health status.

- [ ] **Step 4: Run product-focused tests and browser verification**

Run:

```bash
cd assets && node --test js/hooks/pose_burpee_hsmm_test.mjs js/hooks/pose_tracker_impl_test.mjs js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_renderer_test.mjs
cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs
mix precommit
```

Then follow `docs/testing/workout-session-e2e.md` with the controlled pose fixture: complete one macro-cycle, supply absent frames between cycles, complete a second cycle, Save, and verify exactly one reported row for the captured UUID.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'test(tracking): verify zero-setup HSMM counting'
jj --config signing.behavior=drop new
```

## Plan Self-Review

- **Spec coverage:** Task 1 implements zero setup, general macro-cycle inference, bounded duration behavior, and no invented unseen reps. Task 2 makes ordinary absent observations silent runtime inputs. Task 3 removes degradation/manual fallback and preserves explicit correction provenance. Task 4 removes all calibration/template dependencies and adds deterministic fixture/browser coverage.
- **Placeholder scan:** No task delegates unspecified error handling or test design. Fatal camera startup/detector errors remain existing camera-availability errors; they are distinct from ordinary absent observations.
- **Type consistency:** The HSMM exposes `stepBurpeeHsmm/2`; the tracker publishes existing `pose-tracker:rep`; session payload remains `trust: 'finished'` with `detected_reps`, `detected_duration_sec`, and `cadence_ms`.
