# Client-Authoritative Workout Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the complete workout session client-authoritative through editable completion review, with final Save and deferred pose-trace upload as the only network boundaries.

**Architecture:** Extend the pure client flow FSM and make `SessionHook` the single runtime authority. Render stable session panels once, start `PoseTracker` lazily, buffer completion/traces in IndexedDB, persist the final session idempotently, then upload traces through an authenticated retryable endpoint.

**Tech Stack:** Phoenix LiveView 1.8, Elixir/Ecto/SQLite, vanilla JavaScript hooks and FSMs, IndexedDB, Node test runner, ExUnit, Tailwind CSS v4, Jujutsu.

## Global Constraints

- No application API request, LiveView event, telemetry push, or pose-trace upload from camera choice through completion review. Camera startup may fetch same-origin static model/WASM assets; failure must stay local and preserve the no-camera path.
- Client timer/cadence remains authoritative whether camera tracking is enabled, degraded, or unavailable.
- Camera or pose failure during exercise must not pause, delay, restart, or terminate the workout.
- Tracked warmup/start remains strict hands-free; no tracked-mode Warm up/Skip/Start buttons.
- Exact camera choice copy:
  - heading: `Track burpees with the camera?`
  - helper: `The workout timer runs either way. Camera tracking adds a backup rep count.`
  - actions: `Yes, use camera` and `No, continue`
- User-facing copy must not call the choice “timer mode” or use “Use timer.”
- Camera escape copy is `Continue without camera`.
- Final Save is idempotent by authenticated user plus `client_session_id`.
- Corrected or degraded camera results persist no cadence/pace analytics.
- Pose chunks are buffered in IndexedDB during exercise and uploaded only after Save.
- Intra-rep recovery is static muted blue; between-set rest retains breathing motion.
- Keep global zoom and hidden-scrollbar behavior unchanged.
- Add no third-party state, storage, or upload dependency.
- Follow `docs/superpowers/specs/2026-07-28-client-authoritative-workout-session-design.md` and resolve the verified findings in `.rpiv/artifacts/reviews/2026-07-28_workout-session-redesign.md`.

---

## File Structure

### Create

- `assets/js/hooks/session_flow_fsm_test.mjs` — pure client flow transition contract.
- `assets/js/hooks/session_store.mjs` — IndexedDB engine plus completion-draft and pose-chunk repository.
- `assets/js/hooks/session_store_test.mjs` — repository contract using an in-memory engine.
- `assets/js/hooks/pose_trace_uploader.mjs` — retryable authenticated queue drain with injected fetch/store.
- `assets/js/hooks/pose_trace_uploader_test.mjs` — batching, retry, and acknowledgement tests.
- `lib/burpee_trainer_web/components/session_components.ex` — stable pre-workout, runner, and completion function components.
- `lib/burpee_trainer_web/controllers/pose_trace_upload_controller.ex` — authenticated deferred trace ingestion endpoint.
- `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs` — auth, idempotency, and validation coverage.
- `priv/repo/migrations/*_add_unique_pose_capture_session_index.exs` — generated migration enforcing one pose run per saved session.

### Modify

- `assets/js/hooks/session_flow_fsm.mjs` — authoritative flow through completion review.
- `assets/js/hooks/session_hook.js` — stable-panel renderer, local flow, draft restore, final Save/retry.
- `assets/js/hooks/session_hook_flow_test.mjs` — edge-to-edge client runtime and zero-network assertions.
- `assets/js/hooks/pose_tracker.js` — lazy implementation start.
- `assets/js/hooks/pose_tracker_impl.mjs` — local-only status/gesture/chunk events and unified degradation.
- `assets/js/hooks/pose_capture_recorder.mjs` — retain bounded chunk production without network ownership.
- `assets/js/hooks/pose_tracking_observer.mjs` — sticky degradation contract.
- `assets/js/hooks/session_renderer.mjs` — focus/live announcements and recovery state.
- `assets/js/hooks/session_renderer_test.mjs` — accessibility and recovery assertions.
- `assets/js/app.js` — global deferred trace queue drain triggers.
- `assets/css/app.css` — stable panel states and static `is-work-recovery` treatment.
- `lib/burpee_trainer_web/live/session_live.ex` — bootstrap/static surface and structured final-Save reply only.
- `lib/burpee_trainer/workouts.ex` — corrected/degraded persistence and deferred trace ingestion.
- `lib/burpee_trainer/workouts/pose_capture_run.ex` — completed deferred-upload run changeset.
- `lib/burpee_trainer_web/router.ex` — authenticated JSON upload route.
- `test/burpee_trainer_web/live/session_live_test.exs` — stable initial surface and structured reply contract.
- `test/burpee_trainer_web/live/app_flow_test.exs` — idempotent trusted/corrected/degraded Save flows.
- `test/burpee_trainer/workouts_test.exs` — corrected/degraded persistence semantics.

---

### Task 1: Make the Client Flow FSM Authoritative

**Files:**

- Create: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`

**Interfaces:**

- Consumes: canonical workout timeline and segment results.
- Produces:
  - `initialFlowState()`
  - `flowTransition(state, event) -> {state, commands}`
  - modes `capture_choice | camera_starting | camera_error | camera_setup | warmup_choice | warmup_running | workout_ready | workout_running | completion_review | persisted`
  - commands `renderFlow`, `startCamera`, `stopCamera`, `armGesture`, `disarmGesture`, `startWarmupTimeout`, `pauseWarmupTimeout`, `resumeWarmupTimeout`, `cancelWarmupTimeout`, `startSegment`, `showCompletion`.

- [ ] **Step 1: Write failing pure transition tests**

Create `assets/js/hooks/session_flow_fsm_test.mjs` with these complete scenarios:

```javascript
import assert from "node:assert/strict";
import test from "node:test";

import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";

const step = (state, event) => flowTransition(state, event);

function readyCameraState() {
	let state = initialFlowState();
	state = step(state, { type: "SESSION_READY", workoutTimeline: [] }).state;
	state = step(state, { type: "CHOOSE_CAMERA" }).state;
	state = step(state, { type: "CAMERA_STARTED" }).state;
	return step(state, { type: "CAMERA_READINESS", readiness: "ready" }).state;
}

test("camera choice starts locally and startup failure has explicit recovery", () => {
	let result = step(initialFlowState(), {
		type: "SESSION_READY",
		workoutTimeline: [],
	});
	assert.equal(result.state.mode, "capture_choice");

	result = step(result.state, { type: "CHOOSE_CAMERA" });
	assert.equal(result.state.mode, "camera_starting");
	assert.deepEqual(result.commands, [
		{ type: "startCamera" },
		{ type: "renderFlow" },
	]);

	result = step(result.state, {
		type: "CAMERA_START_FAILED",
		reason: "permission_denied",
	});
	assert.equal(result.state.mode, "camera_error");
	assert.equal(result.state.camera.reason, "permission_denied");
});

test("camera confirmation is ignored until readiness is valid", () => {
	let state = initialFlowState();
	state = step(state, { type: "SESSION_READY", workoutTimeline: [] }).state;
	state = step(state, { type: "CHOOSE_CAMERA" }).state;
	state = step(state, { type: "CAMERA_STARTED" }).state;

	const ignored = step(state, {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	});
	assert.equal(ignored.state.mode, "camera_setup");
	assert.deepEqual(ignored.commands, []);

	const accepted = step(readyCameraState(), {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	});
	assert.equal(accepted.state.mode, "warmup_choice");
});

test("warmup arm is consumed before warmup begins", () => {
	let state = readyCameraState();
	state = step(state, {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	}).state;

	const started = step(state, {
		type: "GESTURE_CONFIRM",
		step: "warmup",
		warmupTimeline: [{ kind: "work", reps: 2, sec_per_rep: 5 }],
	});
	assert.equal(started.state.mode, "warmup_running");
	assert.equal(started.state.armedStep, null);

	const stale = step(started.state, {
		type: "GESTURE_CONFIRM",
		step: "warmup",
	});
	assert.equal(stale.state.mode, "warmup_running");
	assert.deepEqual(stale.commands, []);
});

test("warmup timeout pauses on readiness loss and ignores stale expiry", () => {
	let state = readyCameraState();
	state = step(state, {
		type: "GESTURE_CONFIRM",
		step: "camera_setup",
	}).state;

	const lost = step(state, {
		type: "CAMERA_READINESS",
		readiness: "not_ready",
	});
	assert.deepEqual(lost.commands, [
		{ type: "pauseWarmupTimeout" },
		{ type: "renderFlow" },
	]);

	const stale = step(lost.state, { type: "WARMUP_TIMEOUT", step: "warmup" });
	assert.equal(stale.state.mode, "warmup_choice");
	assert.deepEqual(stale.commands, []);
});

test("camera failure during workout degrades tracking without leaving workout", () => {
	const state = {
		...initialFlowState(),
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "observing",
	};
	const result = step(state, {
		type: "TRACKING_DEGRADED",
		reason: "detector_error",
	});
	assert.equal(result.state.mode, "workout_running");
	assert.equal(result.state.trackingTrust, "degraded");
	assert.equal(result.state.trackingReason, "detector_error");
});

test("session result enters local completion review", () => {
	const state = {
		...initialFlowState(),
		mode: "workout_running",
		captureMode: "no_camera",
	};
	const result = step(state, {
		type: "SESSION_DONE",
		result: { burpeeCountDone: 12, durationSec: 75 },
	});
	assert.equal(result.state.mode, "completion_review");
	assert.equal(result.state.completion.burpeeCountActual, 12);
	assert.deepEqual(result.commands, [{ type: "showCompletion" }]);
});
```

- [ ] **Step 2: Run the tests and confirm the current FSM fails**

Run:

```bash
cd assets && node --test js/hooks/session_flow_fsm_test.mjs
```

Expected: FAIL because the current FSM has no `camera_starting`, readiness-gated confirmation, sticky degradation, or completion-review state.

- [ ] **Step 3: Implement the expanded state and guarded transitions**

Replace the initial state with this exact shape and add guarded transition helpers:

```javascript
export function initialFlowState() {
	return {
		mode: "booting",
		captureMode: "no_camera",
		camera: { status: "idle", readiness: "not_ready", reason: null },
		trackingTrust: "disabled",
		trackingReason: null,
		armedStep: null,
		workoutTimeline: [],
		warmupResult: { burpeeCountDone: 0, durationSec: 0 },
		workoutResult: null,
		completion: null,
		saveStatus: "idle",
	};
}

function unchanged(state) {
	return { state, commands: [] };
}

function moved(state, changes, commands = [{ type: "renderFlow" }]) {
	return { state: { ...state, ...changes }, commands };
}

function cameraReady(state) {
	return state.camera.readiness === "ready" || state.camera.readiness === "optimal";
}

function matchingArm(state, event, step) {
	return state.armedStep === step && event.step === step;
}
```

Implement `flowTransition/2` with explicit cases for all events exercised above plus the existing warmup/workout segment commands. Every `GESTURE_CONFIRM` branch must check `matchingArm`; camera confirmation must also check `cameraReady`. The warmup state accepts `WARMUP_TIMEOUT_TICK` only for the current warmup arm, pauses timeout commands when readiness becomes `not_ready`, resumes when readiness recovers, and accepts `WARMUP_TIMEOUT` only while still in `warmup_choice`. Every accepted branch sets `armedStep: null` before returning `disarmGesture`, `cancelWarmupTimeout` when applicable, and the next command.

Use these exact completion fields:

```javascript
{
	burpeeCountActual,
	burpeeCountPlanned,
	durationSecActual,
	durationSecPlanned,
	detectedReps,
	detectedDurationSec,
	trackingTrust,
	cadenceMs,
}
```

- [ ] **Step 4: Run pure FSM and existing hook-flow tests**

Run:

```bash
cd assets && node --test js/hooks/session_flow_fsm_test.mjs js/hooks/session_hook_flow_test.mjs
```

Expected: new FSM tests PASS; existing hook-flow tests may fail only where Task 4 intentionally replaces old event names/DOM ownership. Record those failing names in the task handoff rather than changing hook code in this task.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(session): model client-authoritative workout flow"
jj new
```

---

### Task 2: Add Local Completion and Pose-Trace Storage

**Files:**

- Create: `assets/js/hooks/session_store.mjs`
- Create: `assets/js/hooks/session_store_test.mjs`

**Interfaces:**

- Produces `createSessionStore(engine)` with:
  - `saveDraft(draft)`
  - `loadDraft({planId, programHash})`
  - `deleteDraft(clientSessionId)`
  - `appendTraceChunk(clientSessionId, chunk)`
  - `listTraceChunks(clientSessionId)`
  - `markTraceReady(clientSessionId, sessionId)`
  - `listReadyTraceUploads()`
  - `hasTraceChunks(clientSessionId)`
  - `deleteTraceChunks(clientSessionId, indexes)`
  - `completeTraceUpload(clientSessionId)`
  - `discardSession(clientSessionId)`
- Produces `openSessionStore(indexedDB = globalThis.indexedDB)`.

- [ ] **Step 1: Write failing storage contract tests with an in-memory engine**

Create a test engine whose methods are `put(store, value)`, `get(store, key)`, `delete(store, key)`, and `all(store)`. Add tests proving:

```javascript
import assert from "node:assert/strict";
import test from "node:test";

import { createSessionStore } from "./session_store.mjs";

function memoryEngine() {
	const stores = new Map();
	const bucket = (name) => {
		if (!stores.has(name)) stores.set(name, new Map());
		return stores.get(name);
	};
	const key = (value) =>
		value.chunk_index === undefined
			? value.client_session_id
			: `${value.client_session_id}:${value.chunk_index}`;
	return {
		async put(name, value) {
			bucket(name).set(key(value), structuredClone(value));
		},
		async get(name, valueKey) {
			return structuredClone(bucket(name).get(valueKey) || null);
		},
		async delete(name, valueKey) {
			bucket(name).delete(valueKey);
		},
		async all(name) {
			return [...bucket(name).values()].map(structuredClone);
		},
	};
}

test("completion draft survives updates and resolves by plan/program", async () => {
	const store = createSessionStore(memoryEngine());
	await store.saveDraft({
		client_session_id: "session-1",
		plan_id: 7,
		program_hash: "abc",
		burpee_count_actual: 12,
	});
	await store.saveDraft({
		client_session_id: "session-1",
		plan_id: 7,
		program_hash: "abc",
		burpee_count_actual: 13,
	});
	const draft = await store.loadDraft({ planId: 7, programHash: "abc" });
	assert.equal(draft.burpee_count_actual, 13);
});

test("trace chunks are ordered, acknowledged selectively, and queued after save", async () => {
	const store = createSessionStore(memoryEngine());
	await store.appendTraceChunk("session-1", { chunk_index: 1, payload: {} });
	await store.appendTraceChunk("session-1", { chunk_index: 0, payload: {} });
	assert.deepEqual(
		(await store.listTraceChunks("session-1")).map((chunk) => chunk.chunk_index),
		[0, 1],
	);
	await store.markTraceReady("session-1", 99);
	assert.equal((await store.listReadyTraceUploads())[0].session_id, 99);
	await store.deleteTraceChunks("session-1", [0]);
	assert.deepEqual(
		(await store.listTraceChunks("session-1")).map((chunk) => chunk.chunk_index),
		[1],
	);
});

test("discard removes draft, chunks, and upload marker", async () => {
	const store = createSessionStore(memoryEngine());
	await store.saveDraft({
		client_session_id: "session-1",
		plan_id: 7,
		program_hash: "abc",
	});
	await store.appendTraceChunk("session-1", { chunk_index: 0, payload: {} });
	await store.markTraceReady("session-1", 99);
	await store.discardSession("session-1");
	assert.equal(await store.loadDraft({ planId: 7, programHash: "abc" }), null);
	assert.deepEqual(await store.listTraceChunks("session-1"), []);
	assert.deepEqual(await store.listReadyTraceUploads(), []);
});
```

- [ ] **Step 2: Run the test and confirm the module is missing**

Run:

```bash
cd assets && node --test js/hooks/session_store_test.mjs
```

Expected: FAIL with module-not-found.

- [ ] **Step 3: Implement the repository and IndexedDB engine**

Use database `burpee-session-runtime`, version `1`, and object stores:

```javascript
const DATABASE = "burpee-session-runtime";
const VERSION = 1;
const DRAFTS = "completion_drafts";
const CHUNKS = "pose_trace_chunks";
const UPLOADS = "trace_uploads";
```

Use `client_session_id` as the draft/upload key and `[client_session_id, chunk_index]` as the chunk key. `loadDraft` filters by exact `plan_id` and `program_hash` and returns the latest `updated_at_ms`. `saveDraft` always writes `updated_at_ms: Date.now()`. `completeTraceUpload` deletes the upload marker after the last acknowledged chunk. `discardSession` deletes the draft, all matching chunks, and the upload marker in one repository operation.

`openSessionStore` must reject with `Error("IndexedDB is unavailable")` when the API is absent. Do not silently fall back to memory in production; Task 4 converts storage failure into non-blocking trace degradation while keeping the in-memory completion state alive.

- [ ] **Step 4: Run storage tests**

Run:

```bash
cd assets && node --test js/hooks/session_store_test.mjs
```

Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(session): persist completion and traces locally"
jj new
```

---

### Task 3: Make Pose Tracking Lazy, Local, and Non-Blocking

**Files:**

- Modify: `assets/js/hooks/pose_tracker.js`
- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Modify: `assets/js/hooks/pose_tracking_observer.mjs`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`

**Interfaces:**

- PoseTracker local control events:
  - `pose-tracker:start`
  - `pose-tracker:stop`
  - `pose-tracker:arm` with `{step, holdFramesRequired}`
  - `pose-tracker:reset`
  - `pose-tracker:finish`
- PoseTracker bubbling outputs:
  - `pose-tracker:started`
  - `pose-tracker:start-failed`
  - `pose-tracker:readiness`
  - `pose-tracker:gesture-confirm`
  - `pose-tracker:status`
  - `pose-tracker:rep`
  - `pose-tracker:trace-chunk`
  - `pose-tracker:finished`
- No PoseTracker call to `hook.pushEvent` during camera choice, setup, warmup, workout, or finish.

- [ ] **Step 1: Add failing local-only tracker tests**

Add focused tests to `session_hook_flow_test.mjs` proving:

```javascript
test("pose tracker mount is lazy and emits local startup failure", async () => {
	const harness = poseTrackerHarness({
		getUserMedia: async () => {
			throw new Error("permission denied");
		},
	});
	await harness.impl.mounted();
	assert.equal(harness.mediaRequests, 0);
	harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:start"));
	await harness.flushPromises();
	assert.equal(harness.mediaRequests, 1);
	assert.deepEqual(harness.events.at(-1), {
		type: "pose-tracker:start-failed",
		detail: { reason: "permission denied" },
	});
	assert.deepEqual(harness.serverPushes, []);
});

test("camera gesture cannot confirm while readiness is not_ready", async () => {
	const harness = poseTrackerHarness({ readinessSamples: "gesture_only" });
	await harness.startAndArm("camera_setup", 3);
	assert.equal(
		harness.events.some((event) => event.type === "pose-tracker:gesture-confirm"),
		false,
	);
});

test("detector exception emits one local lost event and clears readiness", async () => {
	const harness = poseTrackerHarness({ detectorThrowsAfterReady: true });
	await harness.start();
	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.deepEqual(
		harness.events.filter((event) => event.type === "pose-tracker:status").at(-1),
		{ type: "pose-tracker:status", detail: { state: "lost", reason: "detector_error" } },
	);
	assert.deepEqual(harness.serverPushes, []);
});
```

Use the existing fake DOM/runtime patterns already present in the file; expose the helper as `poseTrackerHarness` inside the test file rather than duplicating tracker setup per test.

- [ ] **Step 2: Run the focused tests and observe failures**

Run:

```bash
cd assets && node --test --test-name-pattern="pose tracker mount is lazy|camera gesture cannot|detector exception" js/hooks/session_hook_flow_test.mjs
```

Expected: all three tests FAIL against eager startup/server pushes/readiness-agnostic gesture logic.

- [ ] **Step 3: Implement lazy start and one degradation helper**

`pose_tracker.js` must mount listeners without starting resources. `pose_tracker_impl.mjs` must expose:

```javascript
return { mounted: mountedHook, start, stop, destroyed };
```

`mountedHook` registers local control listeners. `start` owns the existing WebGL, camera, video, detector, and loop setup. `stop` cancels timers/RAF, disposes detector, stops tracks, clears readiness, and can be called safely more than once.

Add one helper used by camera startup, frame exceptions, and confidence loss:

```javascript
function markLost(reason) {
	delete hook.el.dataset.poseTrackerReady;
	stopCameraSetupAutoConfirmTimer();
	startGesture = initialStartGesture();
	if (trackingState !== "lost") trackingState = "lost";
	dispatchLocal("pose-tracker:status", { state: "lost", reason });
}
```

Remove active-session `hook.pushEvent` calls for diagnostics, initialization, status, readiness, reps, finish, abort, and chunks. Dispatch local events instead.

When a recorder chunk is produced, dispatch:

```javascript
dispatchLocal("pose-tracker:trace-chunk", { chunk });
```

Camera-setup gesture stepping requires current readiness `ready | optimal`. A satisfied gesture clears timers, sets `armedStep = null`, and dispatches exactly once. Remove `WARMUP_NO_GESTURE_TIMEOUT_MS` and all warmup timeout dispatch from PoseTracker; SessionHook owns the visible, readiness-pausable warmup timeout in Task 5.

- [ ] **Step 4: Make observer degradation sticky**

Add/retain a single `degrade` path in `pose_tracking_observer.mjs`. `updateTrackingStatus(state, "lost")` must keep `mode: "degraded"`; later `live` or readiness events may update diagnostics but may not restore `observing`.

- [ ] **Step 5: Run focused and full JavaScript tests**

Run:

```bash
cd assets && node --test js/hooks/pose_*_test.mjs js/hooks/session_hook_flow_test.mjs
```

Expected: all tracker/readiness/observer tests PASS; remaining failures are limited to old SessionHook prompt/server-event expectations replaced in Task 5.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(tracking): keep pose runtime local and lazy"
jj new
```

---

### Task 4: Render a Stable Client-Owned Session Surface

**Files:**

- Create: `lib/burpee_trainer_web/components/session_components.ex`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`

**Interfaces:**

- Produces stable IDs:
  - `#session-capture-choice`
  - `#session-camera-status`
  - `#session-camera-setup`
  - `#session-warmup-choice`
  - `#session-workout-ready`
  - `#session-runner-client`
  - `#session-completion-review`
  - `#session-live-status`
  - `#session-save-errors`
- Every inactive panel is both `hidden` and `inert`.
- `SessionLive` initially renders every panel once under the client-owned `phx-update="ignore"` surface.

- [ ] **Step 1: Write failing LiveView stable-surface tests**

Replace raw HTML assertions with selectors and add:

```elixir
test "renders the complete client-owned session surface once", %{conn: conn, user: user} do
  plan = plan_fixture(user)
  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  for id <- ~w[
    session-capture-choice
    session-camera-status
    session-camera-setup
    session-warmup-choice
    session-workout-ready
    session-runner-client
    session-completion-review
    session-live-status
    session-save-errors
  ] do
    assert has_element?(view, "##{id}")
  end

  assert has_element?(view, "#session-capture-choice", "Track burpees with the camera?")
  assert has_element?(view, "#camera-choice-yes", "Yes, use camera")
  assert has_element?(view, "#camera-choice-no", "No, continue")
  refute has_element?(view, "[phx-click='session_started']")
end

test "server surface contains no active-session camera controls", %{conn: conn, user: user} do
  plan = plan_fixture(user)
  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  refute has_element?(view, "[phx-click='choose_tracked']")
  refute has_element?(view, "[phx-click='fallback_to_timed']")
  refute has_element?(view, "[phx-click='set_mood']")
  refute has_element?(view, "[phx-click='toggle_tag']")
end
```

- [ ] **Step 2: Run tests and observe missing stable panels**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: FAIL because current prompts are created by JavaScript or conditionally rendered by server assigns.

- [ ] **Step 3: Create `SessionComponents` with stable function components**

Create `BurpeeTrainerWeb.SessionComponents` using `use BurpeeTrainerWeb, :html`. Implement components for capture choice, camera status/setup, warmup choice, workout ready, runner, and completion review. Use the exact IDs and copy above. Each panel accepts a `hidden` boolean and emits:

```heex
<section id={@id} hidden={@hidden} inert={@hidden && "inert"} aria-labelledby={@heading_id}>
```

The completion component receives `@form`, renders `<.form for={@form} id="session-completion-form">`, uses `<.input>` where fields map directly to the form, and includes stable error containers that JavaScript can populate. It has no `phx-change`, `phx-submit`, mood, or tag server events; SessionHook owns those interactions.

- [ ] **Step 4: Simplify SessionLive mount/render to bootstrap only**

At mount:

- keep authenticated plan/program loading;
- assign a blank `to_form` completion changeset instead of `nil`;
- remove active server phase/capture/readiness/tracker assigns;
- return the initial socket without a post-mount `session_ready` push.

Render one `#burpee-session` hook root with `data-session-program`, `data-plan-id`, `data-program-hash`, and `data-client-session-id`, plus one PoseTracker element and all `SessionComponents` panels. Encode the immutable program in the initial HTML so SessionHook boots synchronously without a LiveView event. Keep the client-owned area under `phx-update="ignore"`.

Delete `choose_tracked`, tracker readiness/status, camera setup, pose chunk, rep, finish, `session_complete`, mood, tag, and discard active-session handlers only after the stable surface tests prove those controls are absent.

- [ ] **Step 5: Run LiveView tests**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(session): render stable client-owned session surface"
jj new
```

---

### Task 5: Wire SessionHook Through Local Completion Review

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Modify: `assets/js/hooks/session_display_model_test.mjs`

**Interfaces:**

- Consumes Task 1 FSM, Task 2 store, Task 3 local PoseTracker events, Task 4 stable IDs.
- Produces immediate completion review and `save_session` as the only SessionHook `pushEvent` before persistence.

- [ ] **Step 1: Replace obsolete flow tests with failing client-only journeys**

Add tests that instrument `ctx.pushEvent` and assert zero pushes until Save:

```javascript
test("camera through completion review requires no server event", async () => {
	const ctx = buildHarness({ connected: false });
	ctx.click("#camera-choice-yes");
	ctx.dispatchTracker("pose-tracker:started");
	ctx.dispatchTracker("pose-tracker:readiness", { state: "ready" });
	ctx.dispatchTracker("pose-tracker:gesture-confirm", { step: "camera_setup" });
	ctx.advanceWarmupTimeout(4_000);
	ctx.dispatchTracker("pose-tracker:gesture-confirm", { step: "workout_start" });
	ctx.completeWorkout({ burpeeCountDone: 12, durationSec: 75 });

	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(ctx.isVisible("#session-completion-review"), true);
	assert.deepEqual(ctx.serverEvents, []);
});

test("camera failure during workout keeps timer result authoritative", () => {
	const ctx = runningCameraHarness();
	ctx.dispatchTracker("pose-tracker:status", {
		state: "lost",
		reason: "detector_error",
	});
	ctx.tickToCompletion();
	assert.equal(ctx.flow.trackingTrust, "degraded");
	assert.equal(ctx.completion.burpee_count_actual, ctx.timerResult.burpeeCountDone);
	assert.deepEqual(ctx.completion.cadence_ms, []);
});

test("second warmup gesture cannot restart warmup", () => {
	const ctx = trackedWarmupHarness();
	ctx.dispatchTracker("pose-tracker:gesture-confirm", { step: "warmup" });
	const firstSegment = ctx.segment;
	ctx.dispatchTracker("pose-tracker:gesture-confirm", { step: "warmup" });
	assert.equal(ctx.segment, firstSegment);
});
```

Also add exact copy assertions for camera choice, warmup countdown, workout start, and `Continue without camera`.

- [ ] **Step 2: Run tests and confirm old SessionHook fails**

Run:

```bash
cd assets && node --test js/hooks/session_hook_flow_test.mjs
```

Expected: FAIL because the old hook creates overlays, pushes active events, and waits for server completion rendering.

- [ ] **Step 3: Replace prompt creation with stable-panel rendering**

Add one renderer method:

```javascript
renderFlowState(state) {
	const visibleId = {
		capture_choice: "session-capture-choice",
		camera_starting: "session-camera-status",
		camera_error: "session-camera-status",
		camera_setup: "session-camera-setup",
		warmup_choice: "session-warmup-choice",
		workout_ready: "session-workout-ready",
		workout_running: "session-runner-client",
		completion_review: "session-completion-review",
	}[state.mode];

	for (const panel of this.el.querySelectorAll("[data-session-panel]")) {
		const visible = panel.id === visibleId;
		panel.hidden = !visible;
		panel.toggleAttribute("inert", !visible);
	}
	this.focusPanelHeading(visibleId);
}
```

Do not build prompt elements in JavaScript. Event listeners target stable buttons/inputs.

- [ ] **Step 4: Wire local camera/gesture/segment events to the FSM**

- On mount, parse `data-session-program`, `data-plan-id`, `data-program-hash`, and `data-client-session-id`, then synchronously dispatch `SESSION_READY`; remove the old `handleEvent("session_ready", ...)` dependency.
- **Yes, use camera** dispatches `CHOOSE_CAMERA` then local `pose-tracker:start`.
- **No, continue** and every camera escape dispatch `CHOOSE_NO_CAMERA` or `CONTINUE_WITHOUT_CAMERA` and local `pose-tracker:stop`.
- Tracker local outputs dispatch matching FSM events.
- SessionHook—not PoseTracker—owns the four-second warmup timeout. It updates the visible `Skipping in N` value, pauses while readiness is `not_ready`, resumes with the remaining monotonic duration, and cancels before leaving `warmup_choice`.
- Segment completion dispatches `SEGMENT_DONE`/`SESSION_DONE` locally.
- Every accepted arm is disarmed before starting a segment.

Delete `showCapturePrompt`, `showCameraSetupPrompt`, `showWarmupPrompt`, and `showWorkoutStartPrompt` DOM construction after equivalent stable-panel tests pass.

- [ ] **Step 5: Add IndexedDB draft/chunk integration**

Open the Task 2 store at mount. On storage failure:

- keep completion state in memory;
- mark trace retention unavailable;
- never affect timing/tracking.

Handle `pose-tracker:trace-chunk` with a serialized promise chain so IndexedDB writes remain ordered without blocking the tracker/RAF callback:

```javascript
this.traceWrite = this.traceWrite
	.then(() => this.store.appendTraceChunk(this.clientSessionId, chunk))
	.catch(() => {
		this.traceRetentionAvailable = false;
	});
```

Persist the completion draft before showing completion and after every edit. Restore a draft only when both plan ID and program hash match the current bootstrap.

Handle confirmed `#session-discard-btn` locally: stop PoseTracker, call `store.discardSession(clientSessionId)`, and navigate to `/workouts` without a server event. Add a test proving no draft, chunks, or upload marker remains.

- [ ] **Step 6: Make final Save the only network event**

On `#session-completion-form` submit:

```javascript
this.pushEvent("save_session", this.completionPayload(), async (reply) => {
	if (reply.status === "ok") {
		if (await this.store.hasTraceChunks(this.clientSessionId)) {
			await this.store.markTraceReady(this.clientSessionId, reply.session_id);
			window.dispatchEvent(new CustomEvent("burpee:trace-upload-ready"));
		}
		await this.store.deleteDraft(this.clientSessionId);
		window.location.assign(reply.redirect_to);
		return;
	}
	this.renderer.renderSaveErrors(reply);
});
```

Keep the draft and controls enabled on invalid/error/timeout/disconnect.

- [ ] **Step 7: Run complete JavaScript tests**

Run:

```bash
cd assets && npm test
```

Expected: all tests PASS; server event assertions show only `save_session` after submit.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(session): run workout and completion entirely on client"
jj new
```

---

### Task 6: Persist Trusted, Corrected, and Degraded Results

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`
- Modify: `test/burpee_trainer/workouts_test.exs`

**Interfaces:**

- `SessionLive.handle_event("save_session", payload, socket)` returns `{:reply, reply, socket}`.
- Extend `Workouts.create_tracked_session_from_plan/4`:

```elixir
create_tracked_session_from_plan(user, plan, attrs, tracking_mode)
```

where `tracking_mode` is:

```elixir
{:trusted, cadence_ms, target_pace_sec} | :manual_correction
```

- Degraded/no-camera results use existing `create_session_from_plan/3`.

- [ ] **Step 1: Write failing context tests for persistence modes**

Add:

```elixir
test "manual camera correction saves tracked without cadence analytics", %{user: user} do
  plan = plan_fixture(user)

  assert {:ok, session} =
           Workouts.create_tracked_session_from_plan(
             user,
             plan,
             %{
               "burpee_count_actual" => 4,
               "duration_sec_actual" => 15,
               "client_session_id" => Ecto.UUID.generate()
             },
             :manual_correction
           )

  assert session.capture_mode == :tracked
  assert session.burpee_count_actual == 4
  assert session.cadence_ms == nil
  assert session.target_pace_sec == nil
  assert session.pace_consistency == nil
end

test "trusted camera result retains strict cadence validation", %{user: user} do
  plan = plan_fixture(user)

  assert {:error, changeset} =
           Workouts.create_tracked_session_from_plan(
             user,
             plan,
             %{
               "burpee_count_actual" => 4,
               "duration_sec_actual" => 15,
               "client_session_id" => Ecto.UUID.generate()
             },
             {:trusted, [5_000, 10_000, 15_000], 5.0}
           )

  assert "must contain one timestamp per rep" in errors_on(changeset).cadence_ms
end
```

- [ ] **Step 2: Write failing LiveView Save reply tests**

Exercise `render_hook(view, "save_session", payload)` or the reply-capable LiveView test helper and assert:

- trusted unchanged result saves cadence;
- corrected result saves without cadence;
- degraded result uses timer values and ordinary session persistence;
- invalid payload returns `status: "invalid"` with field/global errors;
- repeated `client_session_id` returns the existing session ID.

The edited tracked test must submit, not stop at `render_change`.

- [ ] **Step 3: Run focused tests and observe failures**

Run:

```bash
mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: FAIL because `create_tracked_session_from_plan/4` and structured Save replies do not exist.

- [ ] **Step 4: Implement explicit tracked persistence modes**

Keep strict validation only for `{:trusted, cadence, target_pace}`. For `:manual_correction`, set:

```elixir
capture_mode: :tracked,
cadence_ms: nil,
target_pace_sec: nil,
pace_consistency: nil
```

Do not call `validate_tracked_capture/2` or `PaceConsistency.score/1` in manual-correction mode.

- [ ] **Step 5: Implement structured Save replies**

Parse one payload shape with:

```text
workout_session
tracking: {enabled, trust, detected_reps, detected_duration_sec, cadence_ms}
```

Server-side mode selection:

- trusted + actual equals detected reps/duration → trusted tracked;
- tracking enabled + corrected actual/duration → manual correction;
- degraded or no camera → ordinary timer-authoritative session.

Return:

```elixir
{:reply, %{status: "ok", session_id: session.id, redirect_to: ~p"/stats"}, socket}
```

or structured validation errors using field names consumed by SessionHook.

- [ ] **Step 6: Run focused tests**

Run:

```bash
mix test test/burpee_trainer/workouts_test.exs test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: all trusted/corrected/degraded/idempotent Save tests PASS.

- [ ] **Step 7: Commit**

```bash
jj describe -m "fix(session): persist corrected camera results safely"
jj new
```

---

### Task 7: Upload Buffered Pose Traces After Save

**Files:**

- Create via generator: `priv/repo/migrations/*_add_unique_pose_capture_session_index.exs`
- Create: `assets/js/hooks/pose_trace_uploader.mjs`
- Create: `assets/js/hooks/pose_trace_uploader_test.mjs`
- Create: `lib/burpee_trainer_web/controllers/pose_trace_upload_controller.ex`
- Create: `test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs`
- Modify: `assets/js/app.js`
- Modify: `lib/burpee_trainer/workouts.ex`
- Modify: `lib/burpee_trainer/workouts/pose_capture_run.ex`
- Modify: `lib/burpee_trainer_web/router.ex`

**Interfaces:**

- Endpoint: `POST /api/session-pose-traces`
- Request:

```json
{
  "client_session_id": "uuid",
  "chunks": [],
  "complete": false
}
```

- Response:

```json
{
  "accepted_indexes": [0, 1],
  "complete": false
}
```

- Context:

```elixir
ingest_pose_trace_batch(user, client_session_id, chunks, complete?)
```

- [ ] **Step 1: Generate the migration**

Run:

```bash
mix ecto.gen.migration add_unique_pose_capture_session_index
```

Expected: one migration file is created under `priv/repo/migrations/`.

Set its `change/0` body to:

```elixir
create unique_index(:pose_capture_runs, [:workout_session_id],
         where: "workout_session_id IS NOT NULL",
         name: :pose_capture_runs_workout_session_id_unique_index
       )
```

- [ ] **Step 2: Write failing controller/context tests**

Cover:

- unauthenticated request redirects/rejects;
- another user’s `client_session_id` is not found;
- first batch creates one run linked to the saved session;
- repeated batch returns the same accepted indexes without duplicate rows;
- final `complete: true` marks the run completed;
- invalid/oversized chunk returns 422 without changing the saved session.

Use existing `PoseTraceChunk` validation limits and the existing unique chunk index.

- [ ] **Step 3: Write failing uploader tests**

Create an injected fake fetch/store and prove:

```javascript
test("uploader acknowledges only accepted chunks", async () => {
	const store = uploadStore([chunk(0), chunk(1)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => jsonResponse({ accepted_indexes: [0], complete: false }),
		csrfToken: "token",
		batchSize: 2,
	});
	await uploader.drain();
	assert.deepEqual(store.remainingIndexes(), [1]);
});

test("network failure keeps chunks queued and resolves without throwing", async () => {
	const store = uploadStore([chunk(0)]);
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			throw new TypeError("offline");
		},
		csrfToken: "token",
	});
	await uploader.drain();
	assert.deepEqual(store.remainingIndexes(), [0]);
});

test("empty ready upload markers are removed without a request", async () => {
	const store = uploadStore([]);
	let requests = 0;
	const uploader = createPoseTraceUploader({
		store,
		fetch: async () => {
			requests += 1;
			return jsonResponse({ accepted_indexes: [], complete: true });
		},
		csrfToken: "token",
	});
	await uploader.drain();
	assert.equal(requests, 0);
	assert.equal(store.uploadMarkerExists(), false);
});
```

- [ ] **Step 4: Run focused tests and observe failures**

Run:

```bash
cd assets && node --test js/hooks/pose_trace_uploader_test.mjs
mix test test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs
```

Expected: FAIL because uploader, endpoint, and context operation do not exist.

- [ ] **Step 5: Implement idempotent server ingestion**

Use one `Ecto.Multi` to:

1. resolve the current user’s session by `client_session_id`;
2. get or insert the unique pose run linked to that session/plan;
3. insert each validated chunk with conflict target `(pose_capture_run_id, chunk_index)` and no duplicate effect;
4. mark the run completed only when `complete?` is true.

Return accepted indexes from both inserted and already-existing chunks.

Add an authenticated JSON pipeline with session fetch, CSRF protection, current-user fetch, and `require_authenticated_user`. The controller reads `conn.assigns.current_user`; it never accepts user IDs from JSON.

- [ ] **Step 6: Implement the retryable client uploader**

`createPoseTraceUploader`:

- serializes drains with one in-flight promise;
- loads only `markTraceReady` queues;
- sends bounded batches;
- includes `x-csrf-token` and `content-type: application/json`;
- deletes only acknowledged chunk indexes;
- leaves failed chunks queued;
- removes an empty upload marker with `completeTraceUpload` without issuing a request;
- sends `complete: true` only with the final queued batch and then calls `completeTraceUpload` after acknowledgement.

In `app.js`, open the store once and call `drain()` on:

- initial authenticated page boot;
- browser `online`;
- `burpee:trace-upload-ready`;
- LiveView page-loading stop.

Upload failures must not throw into global event handlers.

- [ ] **Step 7: Run migration and focused tests**

Run:

```bash
mix ecto.migrate
cd assets && node --test js/hooks/pose_trace_uploader_test.mjs
cd .. && mix test test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs
```

Expected: migration succeeds; uploader and controller tests PASS.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(tracking): upload buffered pose traces after save"
jj new
```

---

### Task 8: Finish Accessibility and Recovery-State Polish

**Files:**

- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_renderer_test.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/css/app.css`
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`

**Interfaces:**

- `SessionRenderer.announce(text)` updates `#session-live-status` only when text changes.
- `SessionRenderer.focusPanelHeading(panelId)` focuses the stable heading with `preventScroll: true`.
- `is-work-recovery` is static and never inherits `session-blue-breathe`.

- [ ] **Step 1: Write failing renderer and stable-markup tests**

Add assertions for:

```javascript
test("count-in, pause, completion, and errors are announced", () => {
	const { renderer, elements } = harness();
	renderer.renderCountdown(3);
	assert.equal(elements["#session-live-status"].textContent, "Workout starts in 3");
	renderer.updatePauseButton(true);
	assert.equal(elements["#session-live-status"].textContent, "Workout paused");
	renderer.showCompletion();
	assert.equal(elements["#session-live-status"].textContent, "Workout complete");
	renderer.renderSaveErrors({ global_errors: ["Could not save. Try again."] });
	assert.equal(elements["#session-live-status"].textContent, "Could not save. Try again.");
});

test("work recovery keeps its distinct class", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel(model("work_recovery"));
	assert.equal(elements["#session-runner-client"].classList.contains("is-work-recovery"), true);
});
```

Add a source/style assertion that `.is-work-recovery` disables the breathing animation without adding labels.

- [ ] **Step 2: Run focused tests and observe failures**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs js/hooks/session_styles_test.mjs
```

Expected: FAIL because announcements and recovery CSS are incomplete.

- [ ] **Step 3: Implement announcement/focus helpers**

Use:

```javascript
announce(text) {
	const status = this.root.querySelector("#session-live-status");
	if (status && status.textContent !== text) status.textContent = text;
}

focusPanelHeading(panelId) {
	this.root
		.querySelector(`#${panelId} [data-session-heading]`)
		?.focus({ preventScroll: true });
}
```

Stable headings use `tabindex="-1"` and `data-session-heading`.

Announce exact operation/state language, not generic “Loading.”

- [ ] **Step 4: Add static recovery CSS**

Add after the normal rest rule:

```css
#session-runner-client.is-work-recovery {
  background: var(--session-rest);
  animation: none;
}
```

Keep centered bare seconds, set progress, and overall progress behavior from the approved runner contract. Do not add a `RECOVER` label.

- [ ] **Step 5: Run focused tests**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs js/hooks/session_styles_test.mjs
cd .. && mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all accessibility, stable-ID, and recovery-state tests PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "fix(session): polish offline flow accessibility and recovery"
jj new
```

---

### Task 9: Verify the Complete Client-Authoritative Session

**Files:**

- Modify tests only if verification exposes a real uncovered contract.

- [ ] **Step 1: Run the full JavaScript suite**

Run:

```bash
cd assets && npm test
```

Expected: all tests PASS, including flow, final tick, tracker degradation, local storage, and uploader tests.

- [ ] **Step 2: Run focused server flows**

Run:

```bash
mix test \
  test/burpee_trainer/workouts_test.exs \
  test/burpee_trainer_web/live/session_live_test.exs \
  test/burpee_trainer_web/live/app_flow_test.exs \
  test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs
```

Expected: all tests PASS.

- [ ] **Step 3: Run proactive diagnostics**

Run LSP diagnostics on every changed `.ex`, `.js`, and `.mjs` file, then run session-wide lens diagnostics. Expected: no blocking errors; fix actionable warnings introduced by this implementation.

- [ ] **Step 4: Run project verification**

Run:

```bash
mix precommit
mix assets.build
```

Expected: both commands exit 0 with no compile warnings or asset errors.

- [ ] **Step 5: Prove the no-network runtime in Firefox**

Manual sequence:

1. Load a session while connected.
2. Open browser network controls and go offline before choosing camera.
3. Exercise **No, continue** through manual warmup/start and completion review.
4. Reload the same session URL and confirm the unsaved completion draft restores.
5. Repeat with camera resources already available; force detector failure during work and confirm the workout continues with timer-derived completion.
6. Reconnect, Save, and confirm exactly one session exists for the original `client_session_id`.
7. Navigate immediately; confirm buffered pose chunks upload later without duplicate chunk rows.

Expected: no session transition waits for an application API request or LiveView event; optional same-origin camera model/WASM assets may load during camera startup, and Save is the only blocked action while offline.

- [ ] **Step 6: Verify responsive and room-distance UX**

Check portrait, 640×360 short landscape, safe areas, keyboard pause, reduced motion, camera setup, strict hands-free warmup/start, static intra-rep recovery, breathing set rest, completion errors, and focus/live announcements.

Expected: no clipping, hidden primary state, stale gesture action, or competing active-workout chrome.

- [ ] **Step 7: Inspect the final jj diff**

Run:

```bash
jj status
jj diff --stat
jj diff --git
```

Expected: only planned implementation/test/migration files are changed; no `.pi-subagents` artifacts, generated static assets, logs, or unrelated formatting.

- [ ] **Step 8: Commit verification-only fixes if needed**

If verification required source/test corrections:

```bash
jj describe -m "fix(session): resolve client runtime verification findings"
jj new
```

If no corrections were needed, do not create an empty change.
