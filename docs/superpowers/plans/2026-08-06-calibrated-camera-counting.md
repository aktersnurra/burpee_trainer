# Calibrated Camera Counting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count camera-tracked burpees with a per-workout calibrated deterministic matcher, save the true source of every count, and make deferred pose-trace uploads safe below HTTP request limits.

**Architecture:** The browser remains the client-authoritative workout runner. A pure calibration/candidate module turns two guided reference reps into a temporal template and then accepts only quality-gated, duration-bounded, template-matched candidate reps. The LiveView is the persistence boundary: it records trusted camera results separately from camera-reviewed manual corrections and validates their provenance. Pose traces remain best-effort IndexedDB work and are byte-bounded before upload.

**Tech Stack:** Phoenix 1.8 / LiveView, Elixir / Ecto / SQLite, JavaScript ES modules, MediaPipe BlazePose, IndexedDB, Node test runner, ExUnit.

## Global Constraints

- Preserve client-authoritative execution: no server calls from pre-workout through completion review; the only LiveView event remains the idempotent final `save_session`.
- Keep camera optional. A failed calibration must offer retry or the existing no-camera flow; it must never block a workout.
- Do not introduce an HSMM, external training data, raw-video upload, or model-training pipeline.
- A trusted result requires an unchanged camera-detected count and duration. A degraded or corrected camera result must never silently persist a timer target as the actual count.
- Leave Plug's request-size limit as a server security boundary. Keep optional trace chunks and requests below existing server limits; retain unsent chunks after every non-2xx response.
- Use only `Req` for any future Elixir HTTP work; this plan adds no HTTP dependency.
- Create migrations only with `mix ecto.gen.migration <snake_case_name>`.
- Keep `.pi-subagents/**`, `.e2e-artifacts/**`, local databases, and generated bundles out of feature commits.

---

## File Map

| Path | Responsibility |
| --- | --- |
| `assets/js/hooks/pose_calibrated_counter.mjs` | New pure two-reference calibration and candidate-validation state machine. |
| `assets/js/hooks/pose_calibrated_counter_test.mjs` | Deterministic calibration, hysteresis, duration, and DTW acceptance/rejection tests. |
| `assets/js/hooks/pose_template_matcher.mjs` | Reused normalized template and DTW primitives; expose only the small helpers the calibrated counter needs. |
| `assets/js/hooks/pose_tracker_impl.mjs` | Run guided calibration, use calibrated candidates for emitted reps, and degrade only on sustained readiness loss. |
| `assets/js/hooks/pose_tracker_impl_test.mjs` | Tracker-level event tests for calibration, transient confidence loss, sustained loss, and accepted reps. |
| `assets/js/hooks/session_flow_fsm.mjs` | Add calibration flow state and truthful completion-source/confirmation invariants. |
| `assets/js/hooks/session_hook.js` | Bridge tracker calibration events, save/draft provenance, and completion-input confirmation. |
| `assets/js/hooks/session_renderer.mjs` | Render calibration, count source, tracking failure, blank manual input, and Save disabled state. |
| `assets/js/hooks/{session_flow_fsm,session_hook_flow,session_renderer,session_store}_test.mjs` | Lock the UI/runtime/draft behavior. |
| `lib/burpee_trainer_web/components/session_components.ex` | Stable calibration panel and completion source/error DOM. |
| `test/burpee_trainer_web/live/session_live_test.exs` | Server-rendered DOM and accessible calibration/completion controls. |
| `priv/repo/migrations/*_add_camera_tracking_provenance_to_workout_sessions.exs` | Add durable tracking reason and detected-result provenance columns. |
| `lib/burpee_trainer/workouts/workout_session.ex` | Schema fields and `camera_reviewed` capture mode. |
| `lib/burpee_trainer/workouts.ex` | Persist trusted versus camera-reviewed results without losing idempotency. |
| `lib/burpee_trainer_web/live/session_live.ex` | Validate tracking provenance and choose the persistence mode. |
| `test/burpee_trainer/{workouts_test.exs}` and `test/burpee_trainer_web/live/app_flow_test.exs` | Persistence and LiveView save-boundary tests. |
| `assets/js/hooks/pose_capture_recorder.mjs` | Flush optional trace chunks before their serialized payload is too large. |
| `assets/js/hooks/pose_capture_recorder_test.mjs` | New recorder byte-budget and oversize-sample tests. |
| `assets/js/hooks/pose_trace_uploader.mjs` | Build byte-bounded upload batches and retain failed work. |
| `assets/js/hooks/pose_trace_uploader_test.mjs` | Prove request byte limits, acknowledgements, and retry retention. |
| `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs` | Verify accepted bounded payloads and rejected oversized individual chunks. |

## Task 1: Build the Pure Calibrated Counter

**Files:**

- Create: `assets/js/hooks/pose_calibrated_counter.mjs`
- Create: `assets/js/hooks/pose_calibrated_counter_test.mjs`
- Modify: `assets/js/hooks/pose_template_matcher.mjs`

**Interfaces:**

- Consumes: feature samples shaped as `{tMs, confidence, signal, closeness}` and the existing `finishTemplateRecording/1` and `matchTemplateWindow/2` primitives.
- Produces:

```js
export function initialCalibratedCounter();
export function startCalibration(state, nowMs);
export function stepCalibration(state, sample);
export function stepCalibratedCounter(state, sample);
```

`stepCalibration/2` returns `{state, status, calibration?}`. `stepCalibratedCounter/2` returns `{state, rep, reason?}`. A calibration contains two normalized reference templates plus `minDurationMs`, `maxDurationMs`, and calibrated motion ranges.

- [ ] **Step 1: Write failing calibration and candidate tests**

```js
test("two compatible reference cycles produce a calibration", () => {
  let state = startCalibration(initialCalibratedCounter(), 0);
  for (const sample of twoSlowReferenceRepSamples()) {
    ({state} = stepCalibration(state, sample));
  }

  assert.equal(state.phase, "ready");
  assert.equal(state.calibration.templates.length, 2);
});

test("a candidate counts only when quality, timing, and template match", () => {
  const calibration = readyCalibration();
  let state = { ...initialCalibratedCounter(), phase: "counting", calibration };
  const results = matchingCandidateSamples().map((sample) => {
    const next = stepCalibratedCounter(state, sample);
    state = next.state;
    return next.rep;
  });

  assert.deepEqual(results.filter(Boolean), [true]);
});

test("mismatched shape, too-short duration, or poor quality never count", () => {
  for (const samples of [wrongShapeSamples(), tooFastSamples(), poorQualitySamples()]) {
    assert.equal(countCandidates(readyCalibration(), samples), 0);
  }
});
```

- [ ] **Step 2: Run the new test file and verify it fails**

Run: `cd assets && node --test js/hooks/pose_calibrated_counter_test.mjs`

Expected: FAIL because `pose_calibrated_counter.mjs` does not exist.

- [ ] **Step 3: Implement the smallest pure state machine**

```js
const REQUIRED_REFERENCE_REPS = 2;

export function initialCalibratedCounter() {
  return {
    phase: "idle",
    referenceWindows: [],
    activeWindow: [],
    calibration: null,
    candidate: initialCounterState(),
    lastAcceptedAtMs: null,
  };
}

export function stepCalibratedCounter(state, sample) {
  const proposed = countRep(state.candidate, sample, calibratedCounterOptions(state.calibration));
  const activeWindow = appendWindow(state.activeWindow, sample);
  if (!proposed.rep) return { state: { ...state, candidate: proposed.state, activeWindow }, rep: false };

  const match = matchTemplateWindow(nearestTemplate(state.calibration, activeWindow), activeWindow);
  const durationMs = candidateDuration(activeWindow);
  const accepted = match.ok && durationInRange(durationMs, state.calibration);

  return {
    state: {
      ...state,
      candidate: proposed.state,
      activeWindow: [],
      lastAcceptedAtMs: accepted ? sample.tMs : state.lastAcceptedAtMs,
    },
    rep: accepted,
    reason: accepted ? null : match.reason || "duration",
  };
}
```

Implement reference-window segmentation around the existing down/up candidate, require two compatible reference windows, derive median duration bounds and ranges, and reuse the existing DTW matcher over normalized two-signal feature windows. Keep all calculation deterministic and unit-testable.

- [ ] **Step 4: Run the pure counter tests**

Run: `cd assets && node --test js/hooks/pose_calibrated_counter_test.mjs`

Expected: PASS for compatible calibration, one accepted matching rep, and every rejection case.

- [ ] **Step 5: Commit the pure counter**

```bash
jj describe -m "feat(tracking): add calibrated rep counter"
jj new
```

## Task 2: Integrate Calibration and Sustained-Loss Handling into PoseTracker

**Files:**

- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Create: `assets/js/hooks/pose_tracker_impl_test.mjs`
- Modify: `assets/js/hooks/pose_tracking_observer.mjs`
- Modify: `assets/js/hooks/pose_tracking_observer_test.mjs`

**Interfaces:**

- Consumes: `pose-tracker:calibration-start`, `pose-tracker:calibration-retry`, and the pure counter from Task 1.
- Produces: bubbling local events `pose-tracker:calibration-status`, `pose-tracker:calibrated`, `pose-tracker:calibration-failed`, `pose-tracker:rep`, and the existing status/readiness events.

- [ ] **Step 1: Write failing tracker behavior tests**

```js
test("one low-confidence frame does not emit tracking lost", async () => {
  const tracker = mountedTrackerWithSamples([ready(), lowConfidence(), ready()]);
  await tracker.drainFrames();
  assert.deepEqual(tracker.events("pose-tracker:status"), [{ state: "live" }]);
});

test("sustained readiness loss degrades exactly once", async () => {
  const tracker = mountedTrackerWithSamples([ready(), invalid(), invalid(), invalid()]);
  await tracker.drainFrames();
  assert.deepEqual(tracker.events("pose-tracker:status").at(-1), {
    state: "lost", reason: "confidence_lost"
  });
});

test("two valid references emit calibrated and only template-matched cycles emit reps", async () => {
  const tracker = mountedTrackerWithSamples(calibrationThenWorkoutFrames());
  tracker.startCalibration();
  await tracker.drainFrames();
  assert.equal(tracker.events("pose-tracker:calibrated").length, 1);
  assert.equal(tracker.events("pose-tracker:rep").length, 3);
});
```

- [ ] **Step 2: Run the tracker tests and verify they fail**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/pose_tracking_observer_test.mjs`

Expected: FAIL because calibration commands/events and sustained-loss behavior are absent.

- [ ] **Step 3: Make PoseTracker the integration boundary**

In `createPoseTracker/2`:

```js
let calibratedCounter = initialCalibratedCounter();
let calibrationActive = false;

function maybeMarkLost(nextReadiness) {
  if (nextReadiness.status === "not_ready" && trackingState !== "lost") {
    markLost("confidence_lost");
  }
}

function emitCalibratedRep(sample) {
  const next = stepCalibratedCounter(calibratedCounter, sample);
  calibratedCounter = next.state;
  if (next.rep) {
    candidateIndex += 1;
    dispatchLocal("pose-tracker:rep", { index: candidateIndex, confidence: sample.confidence });
  }
}
```

Handle calibration commands in `mountedHook/0`, run `stepCalibration/2` before workout counting, and emit a failure with its diagnostic reason when two compatible references cannot be produced. Remove the direct one-frame `sample.confidence < 0.5` call to `markLost`; derive loss from the existing `LOST_STREAK` readiness transition instead. Reset calibration/counter state when the tracker stops or retries.

- [ ] **Step 4: Run tracker and existing flow tests**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/pose_tracking_observer_test.mjs js/hooks/session_hook_flow_test.mjs`

Expected: PASS, including existing no-camera and degraded-camera behavior.

- [ ] **Step 5: Commit the tracker integration**

```bash
jj describe -m "feat(tracking): calibrate camera rep detection"
jj new
```

## Task 3: Add the Calibration UI and Client Flow

**Files:**

- Modify: `lib/burpee_trainer_web/components/session_components.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Modify: `assets/js/hooks/session_renderer_test.mjs`

**Interfaces:**

- Consumes: `pose-tracker:calibration-status`, `pose-tracker:calibrated`, and `pose-tracker:calibration-failed` from Task 2.
- Produces: `pose-tracker:calibration-start`/`pose-tracker:calibration-retry` commands; a new flow mode `camera_calibrating`; stable DOM ids `session-camera-calibration`, `camera-calibration-start`, `camera-calibration-retry`, and `camera-calibration-continue`.

- [ ] **Step 1: Write failing DOM and FSM tests**

```elixir
test "renders one accessible camera calibration panel", %{conn: conn, user: user} do
  plan = plan_fixture(user)
  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  assert has_element?(view, "#session-camera-calibration[data-session-panel]")
  assert has_element?(view, "#camera-calibration-start")
  assert has_element?(view, "#camera-calibration-retry")
  assert has_element?(view, "#camera-calibration-continue")
end
```

```js
test("camera setup enters calibration before warmup", () => {
  const state = readyCameraSetupState();
  const next = flowTransition(state, { type: "GESTURE_CONFIRM", step: "camera_setup" });
  assert.equal(next.state.mode, "camera_calibrating");
  assert.deepEqual(next.commands.map(({type}) => type), ["disarmGesture", "startCalibration", "renderFlow"]);
});

test("failed calibration can continue without camera", () => {
  const state = calibrationFailedState();
  const next = flowTransition(state, { type: "CONTINUE_WITHOUT_CAMERA" });
  assert.equal(next.state.captureMode, "no_camera");
  assert.equal(next.state.mode, "warmup_choice");
});
```

- [ ] **Step 2: Run focused UI/flow tests and verify they fail**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_renderer_test.mjs js/hooks/session_hook_flow_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_live_test.exs`

Expected: FAIL because the calibration state, commands, and DOM ids do not exist.

- [ ] **Step 3: Implement a first-class calibration panel and transitions**

Add `SessionComponents.camera_calibration/1` between `camera_setup` and `warmup_choice`, then render it from `SessionLive`. It must use `<.panel>`, have a heading focused by `SessionRenderer`, stable button ids, retry/continue controls, and no inline script.

Extend `initialFlowState/0` with calibration status/reason. Route successful camera setup into `camera_calibrating`, start the tracker calibration there, and enter `warmup_choice` only after `CALIBRATION_READY`. A failed calibration leaves the user in that panel with retry and the existing no-camera escape hatch.

In `SessionHook`, bind/unbind the new tracker events, translate them to FSM events, and translate `startCalibration`/`retryCalibration` FSM commands into custom events. Extend `SessionRenderer.renderFlowState/1` with the calibration panel and render status/retry state accessibly.

- [ ] **Step 4: Run focused UI and flow tests**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_renderer_test.mjs js/hooks/session_hook_flow_test.mjs && cd .. && mix test test/burpee_trainer_web/live/session_live_test.exs`

Expected: PASS; valid camera flow cannot enter warmup until calibrated, and calibration failure retains an accessible no-camera path.

- [ ] **Step 5: Commit the calibration UX**

```bash
jj describe -m "feat(session): guide camera calibration"
jj new
```

## Task 4: Make Completion Counts Truthful and Durable

**Files:**

- Generate: `priv/repo/migrations/*_add_camera_tracking_provenance_to_workout_sessions.exs`
- Modify: `lib/burpee_trainer/workouts/workout_session.ex`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer/workouts_test.exs`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_store.mjs`
- Modify: `assets/js/hooks/session_{flow_fsm,hook_flow,renderer,store}_test.mjs`
- Modify: `lib/burpee_trainer_web/components/session_components.ex`

**Interfaces:**

- New database fields: `tracking_reason :string`, `detected_reps :integer`, `detected_duration_sec :float`.
- New capture mode: `:camera_reviewed`.
- Client completion shape:

```js
{
  burpeeCountActual: number | null,
  burpeeCountPlanned: number,
  detectedReps: number | null,
  detectedDurationSec: number | null,
  trackingTrust: "disabled" | "degraded" | "finished",
  trackingReason: string | null,
  countSource: "camera" | "manual" | "timer",
  actualRepsConfirmed: boolean
}
```

- [ ] **Step 1: Generate the migration and write failing persistence tests**

Run: `mix ecto.gen.migration add_camera_tracking_provenance_to_workout_sessions`

In the migration, add nullable `tracking_reason`, `detected_reps`, and `detected_duration_sec` columns. Extend the Ecto enum to include `:camera_reviewed`.

```elixir
test "camera-reviewed session preserves manual actuals and tracking provenance" do
  {:ok, session} = Workouts.create_camera_reviewed_session_from_plan(user, plan, %{
    "burpee_count_actual" => 2,
    "duration_sec_actual" => 60,
    "client_session_id" => Ecto.UUID.generate(),
    "tracking_reason" => "confidence_lost",
    "detected_reps" => nil,
    "detected_duration_sec" => nil
  })

  assert session.capture_mode == :camera_reviewed
  assert session.tracking_reason == "confidence_lost"
  assert session.burpee_count_actual == 2
  assert is_nil(session.cadence_ms)
end
```

```js
test("degraded camera completion is blank and cannot save before a manual count", () => {
  const state = completedDegradedCameraState();
  assert.equal(state.completion.burpeeCountActual, null);
  assert.equal(state.completion.actualRepsConfirmed, false);
  assert.equal(canSaveCompletion(state), false);
});
```

- [ ] **Step 2: Run tests and verify they fail**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_renderer_test.mjs js/hooks/session_store_test.mjs && cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs`

Expected: FAIL for missing schema fields, capture mode, blank/manual-confirm completion state, and new persistence path.

- [ ] **Step 3: Implement completion-source and persistence invariants**

1. Make `completionFor/2` use `result.detectedReps` for a finished trusted camera result and set `countSource: "camera"` with `actualRepsConfirmed: true`.
2. For degraded camera results, set `burpeeCountActual: null`, `countSource: "manual"`, and `actualRepsConfirmed: false`. On a valid reps input, set the value and `actualRepsConfirmed: true`; do not confirm from timer data or draft defaults.
3. Preserve every completion field above in the IndexedDB draft and restore path.
4. Render `#session-count-source`, a visible degradation explanation, and a disabled `#session-save-btn` until `actualRepsConfirmed` is true. Render blank inputs safely rather than the string `"null"`.
5. Include `count_source`, `actual_reps_confirmed`, reason, detected reps, and detected duration in the final tracking payload.
6. Make `SessionLive.persistence_mode/3` accept `:tracked` only when camera trust is finished, source is camera, confirmation is true, and actuals equal detected values. Route a camera-selected degraded/corrected result to `Workouts.create_camera_reviewed_session_from_plan/3`. Preserve existing no-camera `:timed` behavior.
7. Add an explicit `apply_tracked_session_mode/3` clause for `:camera_reviewed` that stores provenance, clears trusted cadence fields, and still uses the same idempotent `client_session_id` insertion path.

- [ ] **Step 4: Run focused client and server tests**

Run: `cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs js/hooks/session_renderer_test.mjs js/hooks/session_store_test.mjs && cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs test/burpee_trainer_web/live/session_live_test.exs`

Expected: PASS; trusted camera counts persist as `tracked`, degraded camera counts cannot save until manually entered and persist as `camera_reviewed`, repeated saves remain idempotent, and no-camera sessions remain `timed`.

- [ ] **Step 5: Commit provenance and truthful completion behavior**

```bash
jj describe -m "feat(session): persist camera count provenance"
jj new
```

## Task 5: Bound Trace Chunks and Upload Requests by Serialized Bytes

**Files:**

- Modify: `assets/js/hooks/pose_capture_recorder.mjs`
- Create: `assets/js/hooks/pose_capture_recorder_test.mjs`
- Modify: `assets/js/hooks/pose_trace_uploader.mjs`
- Modify: `assets/js/hooks/pose_trace_uploader_test.mjs`
- Modify: `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`

**Interfaces:**

```js
export const MAX_TRACE_CHUNK_BYTES = 200_000;
export const MAX_TRACE_REQUEST_BYTES = 512 * 1024;
export function serializedJsonBytes(value);
```

The recorder never emits a chunk whose `payload` JSON is over `MAX_TRACE_CHUNK_BYTES`. The uploader never calls `fetch` with a JSON body over `MAX_TRACE_REQUEST_BYTES` and retains all unacknowledged chunks after non-2xx responses.

- [ ] **Step 1: Write failing byte-boundary tests**

```js
test("recorder flushes before a payload exceeds the chunk byte budget", () => {
  let state = initialPoseCaptureRecorder();
  for (const sample of largeSamples()) {
    ({state} = recordPoseSample(state, sample, { segment: "main", nowMs: sample.tMs }));
  }
  const {chunks} = flushPoseCaptureRecorder(state);
  assert.ok(chunks.every((chunk) => serializedJsonBytes(chunk.payload) <= MAX_TRACE_CHUNK_BYTES));
});

test("uploader splits a ready queue by serialized request bytes", async () => {
  const requests = [];
  const uploader = createPoseTraceUploader({
    store: uploadStore(nearBudgetChunks()),
    fetch: async (_path, options) => {
      requests.push(options.body);
      const body = JSON.parse(options.body);
      return jsonResponse({ accepted_indexes: body.chunks.map(({chunk_index}) => chunk_index), complete: body.complete });
    },
    csrfToken: "token"
  });
  await uploader.drain();
  assert.ok(requests.every((body) => new TextEncoder().encode(body).byteLength <= MAX_TRACE_REQUEST_BYTES));
});

test("413 retains the queued chunks and ready marker", async () => {
  const store = uploadStore([largeChunk(0)]);
  await createPoseTraceUploader({ store, fetch: async () => ({ok: false, status: 413}), csrfToken: "token" }).drain();
  assert.deepEqual(store.remainingIndexes(), [0]);
  assert.equal(store.uploadMarkerExists(), true);
});
```

- [ ] **Step 2: Run JS boundary tests and verify they fail**

Run: `cd assets && node --test js/hooks/pose_capture_recorder_test.mjs js/hooks/pose_trace_uploader_test.mjs`

Expected: FAIL because both modules currently use time/count bounds only.

- [ ] **Step 3: Implement byte-aware flushing and batching**

Use `new TextEncoder().encode(JSON.stringify(value)).byteLength` in one shared helper. When the recorder's next sample would exceed `MAX_TRACE_CHUNK_BYTES`, flush the existing samples first and retry the sample in a fresh pending chunk. If the lone sample still exceeds the budget, skip that optional sample and retain a local diagnostic; never block the workout.

In the uploader, build batches incrementally and serialize the complete envelope on every candidate append. Stop before adding a chunk that would exceed `MAX_TRACE_REQUEST_BYTES`; always send one valid queued chunk if it fits. Keep existing acknowledgement/delete behavior unchanged and return without deletion on all non-2xx responses.

- [ ] **Step 4: Add controller coverage and run focused tests**

Add a controller test with several individually valid, near-limit chunks to prove a bounded request ingests and keeps idempotent indexes. Preserve the existing oversized-single-chunk 422 test.

Run: `cd assets && node --test js/hooks/pose_capture_recorder_test.mjs js/hooks/pose_trace_uploader_test.mjs && cd .. && mix test test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`

Expected: PASS; no tested request crosses 512 KiB, 413 keeps queued data, and valid chunks reach the existing controller intact.

- [ ] **Step 5: Commit the trace safety fix**

```bash
jj describe -m "fix(tracking): bound deferred trace uploads"
jj new
```

## Task 6: Validate the Whole Product Flow

**Files:**

- Modify when necessary: `docs/testing/workout-session-e2e.md`
- Create during verification only: `.e2e-artifacts/<timestamp>/...` (do not commit)

**Interfaces:**

- Consumes the calibrated tracker, completion provenance, and bounded uploader from Tasks 1–5.
- Produces current-run E2E evidence, a database verification result, and no leftover test user/server/profile resources.

- [ ] **Step 1: Run automated test suites before browser work**

Run:

```bash
cd assets && npm test
cd .. && mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/session_live_test.exs test/burpee_trainer_web/live/app_flow_test.exs test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs
```

Expected: JS and focused ExUnit suites pass with no failures.

- [ ] **Step 2: Perform current-workspace browser E2E**

Follow `docs/testing/workout-session-e2e.md` with a temporary server and isolated profile. In addition to the existing offline/camera-denied/keyboard/geometry checks, capture:

1. a successful two-reference calibration and trusted camera save;
2. a forced sustained confidence loss that visibly requires a manual count and saves `camera_reviewed` provenance;
3. no-camera behavior unchanged;
4. deferred trace request bodies below the byte budget and retry retention after a simulated non-2xx response.

Verify the saved rows with:

```bash
mix run scripts/e2e/verify.exs -- USER_ID CLIENT_SESSION_ID
```

- [ ] **Step 3: Run final project gates and clean up**

Run:

```bash
mix assets.build
mix precommit
mix run scripts/e2e/cleanup.exs -- USER_ID
jj status
```

Expected: build and precommit exit 0, E2E cleanup removes temporary user data and stops the server/profile, and only intentional source/doc changes remain. Remove `.e2e-artifacts/**` and `.pi-subagents/**` from the feature change before committing.

- [ ] **Step 4: Commit verification-facing docs only if changed**

```bash
jj describe -m "test(session): verify calibrated camera flow"
jj new
```

Skip this commit if the documentation did not need an update; never commit E2E evidence or generated artifacts.

## Plan Self-Review

- **Spec coverage:** Tasks 1–3 implement guided calibration, a deterministic DTW-gated counter, sustained-loss handling, UI states, and camera optionality. Task 4 implements truthful completion values and durable provenance. Task 5 bounds trace chunks and uploads without increasing the server body limit. Task 6 covers all automated and browser acceptance checks.
- **Placeholder scan:** No task relies on unspecified error handling, broad unbounded tests, or deferred implementation details. Every introduced interface, state, persistence field, and command is named above.
- **Type consistency:** Client completion uses `countSource`, `actualRepsConfirmed`, `detectedReps`, `detectedDurationSec`, and `trackingReason` throughout. Their server payload forms are `count_source`, `actual_reps_confirmed`, `detected_reps`, `detected_duration_sec`, and `tracking_reason`. The capture modes remain `tracked`, `camera_reviewed`, `timed`, and `logged`.
