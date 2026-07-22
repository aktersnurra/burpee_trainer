# Pose Tracking Observer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing BlazePose rep detector into tracked sessions as a trustworthy backup counter without giving the camera authority over workout timing, progression, or the live runner UI.

**Architecture:** `SessionHook` remains the only clock and workout-state authority. `PoseTracker` emits local candidate/status/readiness events, a pure observer records accepted timestamps from the session clock, and LiveView uses tracked results only when the observer remains trustworthy. The completion page presents one editable actual headline, quiet planned-rep context, honest camera provenance, and all existing metadata.

**Tech Stack:** Phoenix 1.8 LiveView, Elixir, HEEx, JavaScript ES modules, BlazePose/MediaPipe, `node:test`, ExUnit, LazyHTML, Tailwind CSS v4, Jujutsu.

## Global Constraints

- Work only in `/Users/aktersnurra/projects/vibe/burpee_trainer.workspaces/workout-session-redesign`.
- Use `jj`, never Git commands.
- Follow test-driven development: observe each focused test fail before implementation, then pass.
- `SessionHook` and `session_segment_fsm.mjs` remain authoritative for count-in, cadence, pause, visibility adjustment, segment progression, duration, and completion.
- Camera tracking is backup-only. It must never dispatch segment transitions or update the live runner count, fill, audio, rest, or progress.
- The live runner UI remains unchanged; no live camera count or pace feedback is added.
- Tracked start requires initialized inference plus stable core-pose readiness.
- Cropped feet never block start and do not degrade an otherwise valid core pose.
- Explicit between-set rest, count-in, pause, hidden, and completed states reject candidate reps.
- A trusted tracked result prefills the editable completion total; any tracking degradation falls back to the timer-derived total.
- Completion shows one actual headline, `of N planned`, and camera provenance. Preserve duration, mood, editable reps, editable minutes, tags, notes, Save, and discard controls.
- Existing `cadence_ms` and `target_pace_sec` persistence are reused; do not add a migration.
- Do not wire the debug-only HMM, candidate extractor, or template matcher into production.
- Do not verify README commands.

---

### Task 1: Add Stable Core-Pose Readiness

**Files:**

- Create: `assets/js/hooks/pose_readiness.mjs`
- Create: `assets/js/hooks/pose_readiness_test.mjs`

**Interfaces:**

- Consumes: `sample.confidence`, `sample.features.visibleFraction`, and normalized `sample.keypoints[name] = {x, y, score}` from `sampleFromPose/4`.
- Produces: `initialPoseReadiness()` and `stepPoseReadiness(state, {poseCount, sample})`.
- Status contract: `not_ready | ready | optimal`; both `ready` and `optimal` permit starting.

- [ ] **Step 1: Write failing readiness tests**

Create `assets/js/hooks/pose_readiness_test.mjs` with fixtures that make feet optional while requiring stable core geometry:

```js
import assert from "node:assert/strict";
import test from "node:test";

import {
  initialPoseReadiness,
  stepPoseReadiness,
} from "./pose_readiness.mjs";

const point = (score = 0.9, x = 0.5, y = 0.5) => ({ score, x, y });

function sample({ feet = false, confidence = 0.9, visibleFraction = 0.5 } = {}) {
  return {
    confidence,
    features: { visibleFraction },
    keypoints: {
      left_shoulder: point(0.9, 0.42, 0.25),
      right_shoulder: point(0.9, 0.58, 0.25),
      left_hip: point(0.9, 0.45, 0.5),
      right_hip: point(0.9, 0.55, 0.5),
      left_knee: point(0.9, 0.46, 0.72),
      ...(feet
        ? {
            right_knee: point(0.9, 0.54, 0.72),
            left_ankle: point(0.9, 0.46, 0.92),
          }
        : {}),
    },
  };
}

function repeat(state, input, count) {
  let next = state;
  for (let index = 0; index < count; index += 1) {
    next = stepPoseReadiness(next, input);
  }
  return next;
}

test("stable core pose becomes ready without visible feet", () => {
  const state = repeat(
    initialPoseReadiness(),
    { poseCount: 1, sample: sample() },
    8,
  );
  assert.equal(state.status, "ready");
});

test("strong lower-body coverage upgrades ready to optimal", () => {
  const state = repeat(
    initialPoseReadiness(),
    { poseCount: 1, sample: sample({ feet: true, visibleFraction: 0.7 }) },
    8,
  );
  assert.equal(state.status, "optimal");
});

test("one valid frame cannot enable tracked start", () => {
  const state = stepPoseReadiness(initialPoseReadiness(), {
    poseCount: 1,
    sample: sample(),
  });
  assert.equal(state.status, "not_ready");
});

test("three consecutive invalid frames remove readiness", () => {
  const ready = repeat(
    initialPoseReadiness(),
    { poseCount: 1, sample: sample() },
    8,
  );
  const lost = repeat(ready, { poseCount: 0, sample: sample() }, 3);
  assert.equal(lost.status, "not_ready");
});

test("multiple poses and missing hips remain not ready", () => {
  const missingHip = sample();
  delete missingHip.keypoints.right_hip;

  assert.equal(
    repeat(initialPoseReadiness(), { poseCount: 2, sample: sample() }, 8).status,
    "not_ready",
  );
  assert.equal(
    repeat(initialPoseReadiness(), { poseCount: 1, sample: missingHip }, 8).status,
    "not_ready",
  );
});
```

- [ ] **Step 2: Run the readiness test and observe the missing-module failure**

Run:

```bash
cd assets
node --test js/hooks/pose_readiness_test.mjs
```

Expected: FAIL because `pose_readiness.mjs` does not exist.

- [ ] **Step 3: Implement the pure readiness state machine**

Create `assets/js/hooks/pose_readiness.mjs`:

```js
const MIN_SCORE = 0.5;
const MIN_VISIBLE_FRACTION = 0.35;
const READY_STREAK = 8;
const LOST_STREAK = 3;

export function initialPoseReadiness() {
  return {
    status: "not_ready",
    passStreak: 0,
    failStreak: 0,
  };
}

export function stepPoseReadiness(state, { poseCount, sample }) {
  const coreReady = corePoseReady(poseCount, sample);
  const passStreak = coreReady ? state.passStreak + 1 : 0;
  const failStreak = coreReady ? 0 : state.failStreak + 1;

  if (state.status === "not_ready") {
    if (passStreak < READY_STREAK) {
      return { status: "not_ready", passStreak, failStreak };
    }
    return {
      status: optimalPose(sample) ? "optimal" : "ready",
      passStreak,
      failStreak: 0,
    };
  }

  if (failStreak >= LOST_STREAK) {
    return { status: "not_ready", passStreak: 0, failStreak };
  }

  return {
    status: coreReady && optimalPose(sample) ? "optimal" : state.status,
    passStreak,
    failStreak,
  };
}

function corePoseReady(poseCount, sample) {
  if (poseCount !== 1 || !sample) return false;
  if (sample.confidence < MIN_SCORE) return false;
  if ((sample.features?.visibleFraction || 0) < MIN_VISIBLE_FRACTION) return false;

  const points = sample.keypoints || {};
  const required = [
    points.left_shoulder,
    points.right_shoulder,
    points.left_hip,
    points.right_hip,
  ];
  const kneeReady = visible(points.left_knee) || visible(points.right_knee);

  return required.every(visible) && kneeReady;
}

function optimalPose(sample) {
  const points = sample?.keypoints || {};
  const kneesReady = visible(points.left_knee) && visible(points.right_knee);
  const ankleReady = visible(points.left_ankle) || visible(points.right_ankle);
  return kneesReady && ankleReady && sample.features.visibleFraction >= 0.5;
}

function visible(point) {
  return (
    point != null &&
    point.score >= MIN_SCORE &&
    Number.isFinite(point.x) &&
    Number.isFinite(point.y) &&
    point.x >= 0 &&
    point.x <= 1 &&
    point.y >= 0 &&
    point.y <= 1
  );
}
```

- [ ] **Step 4: Run readiness tests**

Run:

```bash
cd assets
node --test js/hooks/pose_readiness_test.mjs
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit the readiness classifier**

```bash
jj describe -m "feat(tracking): classify stable pose readiness"
jj new
```

---

### Task 2: Lock Down the Existing Live Rep Counter

**Files:**

- Create: `assets/js/hooks/pose_rep_counter_test.mjs`
- Test: `assets/js/hooks/pose_rep_counter.mjs`

**Interfaces:**

- Consumes: existing `initialCounterState()` and `countRep(state, sample)`.
- Produces: regression coverage proving one ordered movement cycle emits one candidate and reset starts clean.

- [ ] **Step 1: Write focused counter tests**

Create `assets/js/hooks/pose_rep_counter_test.mjs`:

```js
import assert from "node:assert/strict";
import test from "node:test";

import { countRep, initialCounterState } from "./pose_rep_counter.mjs";

const sample = (tMs, closeness, confidence = 0.9) => ({
  tMs,
  closeness,
  confidence,
});

function step(state, nextSample) {
  return countRep(state, nextSample);
}

test("standing down and recovered standing emits exactly one rep", () => {
  let result = step(initialCounterState(), sample(0, 0.2));
  result = step(result.state, sample(500, 0.5));
  result = step(result.state, sample(900, 0.25));
  result = step(result.state, sample(1_100, 0.2));

  assert.equal(result.rep, true);
  assert.deepEqual(result.state.cadenceMs, [1_100]);
});

test("low-confidence samples cannot advance the detector", () => {
  const initial = initialCounterState();
  const result = step(initial, sample(500, 0.6, 0.1));
  assert.equal(result.rep, false);
  assert.deepEqual(result.state, initial);
});

test("refractory movement cannot double count", () => {
  let result = step(initialCounterState(), sample(0, 0.2));
  for (const next of [
    sample(500, 0.5),
    sample(900, 0.25),
    sample(1_100, 0.2),
    sample(1_300, 0.5),
    sample(1_500, 0.25),
    sample(1_700, 0.2),
  ]) {
    result = step(result.state, next);
  }

  assert.equal(result.rep, false);
  assert.deepEqual(result.state.cadenceMs, [1_100]);
});

test("a fresh initial state clears setup and warmup cadence", () => {
  const dirty = {
    ...initialCounterState(),
    phase: "ascending",
    cadenceMs: [1_100],
    lastRepTMs: 1_100,
  };
  assert.notDeepEqual(dirty, initialCounterState());
  assert.deepEqual(initialCounterState().cadenceMs, []);
  assert.equal(initialCounterState().phase, "standing");
});
```

- [ ] **Step 2: Run the focused tests**

Run:

```bash
cd assets
node --test js/hooks/pose_rep_counter_test.mjs
```

Expected: 4 tests pass against the current detector. If the synthetic cycle exposes a real mismatch, preserve the production thresholds and adjust only sample timing/closeness to model the documented standing → down → standing contract.

- [ ] **Step 3: Run the readiness and counter tests together**

```bash
cd assets
node --test js/hooks/pose_readiness_test.mjs js/hooks/pose_rep_counter_test.mjs
```

Expected: 9 tests pass.

- [ ] **Step 4: Commit detector contract coverage**

```bash
jj describe -m "test(tracking): cover live rep detector contract"
jj new
```

---

### Task 3: Add the Pure Tracking Observer

**Files:**

- Create: `assets/js/hooks/pose_tracking_observer.mjs`
- Create: `assets/js/hooks/pose_tracking_observer_test.mjs`

**Interfaces:**

- Produces:
  - `initialTrackingObserver()`
  - `updateTrackingStatus(state, status)`
  - `updateTrackingReadiness(state, readiness)`
  - `startTrackingObserver(state, readiness)`
  - `observeTrackingRep(state, {index, elapsedMs, eligible})`
  - `finishTrackingObserver(state, durationMs)`
- `finishTrackingObserver` returns `{state, result}` where result is `{trusted, cadenceMs, reason}`.

- [ ] **Step 1: Write failing observer tests**

Cover the complete trust boundary:

```js
import assert from "node:assert/strict";
import test from "node:test";

import {
  finishTrackingObserver,
  initialTrackingObserver,
  observeTrackingRep,
  startTrackingObserver,
  updateTrackingReadiness,
  updateTrackingStatus,
} from "./pose_tracking_observer.mjs";

function liveReadyObserver() {
  const live = updateTrackingStatus(initialTrackingObserver(), "live");
  return startTrackingObserver(live, "ready");
}

test("eligible work reps produce authoritative cadence", () => {
  let state = liveReadyObserver();
  state = observeTrackingRep(state, { index: 1, elapsedMs: 2_500, eligible: true });
  state = observeTrackingRep(state, { index: 2, elapsedMs: 5_100, eligible: true });

  const finished = finishTrackingObserver(state, 10_000);
  assert.deepEqual(finished.result, {
    trusted: true,
    cadenceMs: [2_500, 5_100],
    reason: null,
  });
});

test("count-in pause and explicit rest candidates are ignored", () => {
  let state = liveReadyObserver();
  state = observeTrackingRep(state, { index: 1, elapsedMs: 1_000, eligible: false });
  assert.deepEqual(state.cadenceMs, []);
  assert.equal(state.mode, "observing");
});

test("feet-limited ready quality remains trustworthy", () => {
  const state = startTrackingObserver(
    updateTrackingStatus(initialTrackingObserver(), "live"),
    "ready",
  );
  assert.equal(state.mode, "observing");
  assert.equal(state.degradedReason, null);
});

test("tracking loss is sticky and forces fallback", () => {
  const lost = updateTrackingStatus(liveReadyObserver(), "lost");
  const recovered = updateTrackingStatus(lost, "live");
  const finished = finishTrackingObserver(recovered, 10_000);
  assert.equal(finished.result.trusted, false);
  assert.equal(finished.result.reason, "tracking_lost");
});

test("core readiness loss after start is sticky", () => {
  const lost = updateTrackingReadiness(liveReadyObserver(), "not_ready");
  const finished = finishTrackingObserver(lost, 10_000);
  assert.equal(finished.result.trusted, false);
  assert.equal(finished.result.reason, "pose_not_ready");
});

test("duplicate index and decreasing timestamp degrade", () => {
  let state = liveReadyObserver();
  state = observeTrackingRep(state, { index: 1, elapsedMs: 2_500, eligible: true });
  state = observeTrackingRep(state, { index: 1, elapsedMs: 2_600, eligible: true });
  assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);

  state = liveReadyObserver();
  state = observeTrackingRep(state, { index: 1, elapsedMs: 2_500, eligible: true });
  state = observeTrackingRep(state, { index: 2, elapsedMs: 2_000, eligible: true });
  assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);
});

test("timestamp beyond duration forces fallback", () => {
  let state = liveReadyObserver();
  state = observeTrackingRep(state, { index: 1, elapsedMs: 10_001, eligible: true });
  assert.equal(finishTrackingObserver(state, 10_000).result.trusted, false);
});
```

- [ ] **Step 2: Run the observer test and observe the missing-module failure**

```bash
cd assets
node --test js/hooks/pose_tracking_observer_test.mjs
```

Expected: FAIL because the observer module does not exist.

- [ ] **Step 3: Implement the observer state machine**

Create `assets/js/hooks/pose_tracking_observer.mjs`:

```js
export function initialTrackingObserver() {
  return {
    mode: "idle",
    trackerStatus: "lost",
    readiness: "not_ready",
    cadenceMs: [],
    lastIndex: null,
    lastTimestampMs: null,
    degradedReason: null,
  };
}

export function updateTrackingStatus(state, status) {
  if (status !== "live" && status !== "lost") return state;
  if (state.mode === "observing" && status === "lost") {
    return degrade({ ...state, trackerStatus: status }, "tracking_lost");
  }
  return { ...state, trackerStatus: status };
}

export function updateTrackingReadiness(state, readiness) {
  if (!["not_ready", "ready", "optimal"].includes(readiness)) return state;
  const next = { ...state, readiness };
  if (state.mode === "observing" && readiness === "not_ready") {
    return degrade(next, "pose_not_ready");
  }
  return next;
}

export function startTrackingObserver(state, readiness) {
  const next = {
    ...initialTrackingObserver(),
    trackerStatus: state.trackerStatus,
    readiness,
  };
  if (state.trackerStatus !== "live") return degrade(next, "tracker_not_live");
  if (readiness !== "ready" && readiness !== "optimal") {
    return degrade(next, "pose_not_ready");
  }
  return { ...next, mode: "observing" };
}

export function observeTrackingRep(state, { index, elapsedMs, eligible }) {
  if (state.mode !== "observing" || !eligible) return state;
  if (!Number.isInteger(index) || index <= 0) return degrade(state, "invalid_index");
  if (!Number.isInteger(elapsedMs) || elapsedMs < 0) {
    return degrade(state, "invalid_timestamp");
  }
  if (state.lastIndex !== null && index <= state.lastIndex) {
    return degrade(state, "duplicate_index");
  }
  if (state.lastTimestampMs !== null && elapsedMs < state.lastTimestampMs) {
    return degrade(state, "decreasing_timestamp");
  }

  return {
    ...state,
    cadenceMs: [...state.cadenceMs, elapsedMs],
    lastIndex: index,
    lastTimestampMs: elapsedMs,
  };
}

export function finishTrackingObserver(state, durationMs) {
  let finished = state;
  if (!Number.isInteger(durationMs) || durationMs < 0) {
    finished = degrade(state, "invalid_duration");
  } else if (state.cadenceMs.some((timestamp) => timestamp > durationMs)) {
    finished = degrade(state, "timestamp_beyond_duration");
  }

  const trusted = finished.mode === "observing" && !finished.degradedReason;
  return {
    state: { ...finished, mode: "finished" },
    result: {
      trusted,
      cadenceMs: trusted ? [...finished.cadenceMs] : [],
      reason: trusted ? null : finished.degradedReason || "tracking_unavailable",
    },
  };
}

function degrade(state, reason) {
  return {
    ...state,
    mode: "degraded",
    degradedReason: state.degradedReason || reason,
  };
}
```

- [ ] **Step 4: Run observer tests**

```bash
cd assets
node --test js/hooks/pose_tracking_observer_test.mjs
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit the pure observer**

```bash
jj describe -m "feat(tracking): add fallible rep observer"
jj new
```

---

### Task 4: Emit Local Tracker Events and Gate Camera Readiness

**Files:**

- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Test: `assets/js/hooks/pose_readiness_test.mjs`

**Interfaces:**

- Consumes: Task 1 readiness state machine and existing `initialCounterState()`.
- Emits bubbling DOM events: `pose-tracker:rep`, `pose-tracker:status`, `pose-tracker:readiness`.
- Accepts: `pose-tracker:reset` and existing `pose-tracker:finish`.
- Completion detail accepts `{durationMs, cadenceMs}`; `cadenceMs` comes from Task 3 observer through `SessionHook`.

- [ ] **Step 1: Add a failing authoritative-finish-payload test**

Extend the existing import from `pose_tracker_impl.mjs` to include `trackingFinishPayload`, then add:

```js
test("tracker finish uses observer cadence instead of tracker-relative time", () => {
  assert.deepEqual(
    trackingFinishPayload({
      durationMs: 10_000,
      cadenceMs: [2_500, 5_100],
    }),
    {
      reps: 2,
      duration_ms: 10_000,
      cadence_ms: [2_500, 5_100],
    },
  );
});
```

Run `node --test js/hooks/session_hook_flow_test.mjs` and expect an import failure because `trackingFinishPayload` is not exported yet.

- [ ] **Step 2: Add readiness and local-event wiring in `createPoseTracker`**

Import readiness helpers and add state:

```js
import {
  initialPoseReadiness,
  stepPoseReadiness,
} from "./pose_readiness.mjs";

let readiness = initialPoseReadiness();
let lastReadinessStatus = readiness.status;

const dispatchLocal = (type, detail) => {
  hook.el.dispatchEvent(
    new CustomEvent(type, { bubbles: true, detail }),
  );
};
```

After each sampled pose:

```js
const nextReadiness = stepPoseReadiness(readiness, {
  poseCount: poses.length,
  sample,
});
readiness = nextReadiness;

if (nextReadiness.status !== lastReadinessStatus) {
  lastReadinessStatus = nextReadiness.status;
  const ready = nextReadiness.status === "ready" || nextReadiness.status === "optimal";
  if (ready) hook.el.dataset.poseTrackerReady = "true";
  else delete hook.el.dataset.poseTrackerReady;

  const detail = { state: nextReadiness.status };
  dispatchLocal("pose-tracker:readiness", detail);
  hook.pushEvent("tracker_readiness", detail);
}
```

Do not set `poseTrackerReady` immediately after detector creation. Detector creation proves initialization, not pose readiness. Push a one-time `tracker_initialized` event instead.

- [ ] **Step 3: Replace per-rep server pushes with local candidate events**

Change the current `hook.pushEvent("rep", ...)` block to:

```js
if (result.rep) {
  dispatchLocal("pose-tracker:rep", {
    index: state.cadenceMs.length,
    confidence: sample.confidence,
  });
}
```

Keep `state.cadenceMs` only as detector-local indexing; it is no longer persisted.

- [ ] **Step 4: Mirror live/lost status locally**

Whenever the existing code pushes `track` to LiveView, also dispatch:

```js
dispatchLocal("pose-tracker:status", { state: trackingState });
```

Dispatch only on debounced status changes, matching the current server push behavior.

- [ ] **Step 5: Reset detector state and accept authoritative finish cadence**

Register:

```js
const reset = () => {
  state = initialCounterState();
  lastFeature = null;
};

hook.el.addEventListener("pose-tracker:reset", reset);
```

Export the pure payload boundary and use it from `finish`:

```js
export function trackingFinishPayload({ durationMs, cadenceMs }) {
  return buildFinishPayload({ durationMs, cadenceMs });
}

function finish(event) {
  const flushed = flushPoseCaptureRecorder(captureRecorder, {
    reason: "finish",
    nowMs: performance.now() - (startedAt || performance.now()),
  });
  captureRecorder = flushed.state;
  flushed.chunks.forEach(pushCaptureChunk);

  try {
    hook.pushEvent("finish", trackingFinishPayload(event.detail || {}));
  } catch (_error) {
    hook.pushEvent("track", { state: "lost", reason: "invalid_finish" });
  }
}
```

Remove the reset listener in `destroyed()`.

- [ ] **Step 6: Run focused JavaScript tests**

```bash
cd assets
node --test \
  js/hooks/pose_readiness_test.mjs \
  js/hooks/pose_rep_counter_test.mjs \
  js/hooks/pose_tracking_observer_test.mjs \
  js/hooks/session_hook_flow_test.mjs
```

Expected: all focused tests pass.

- [ ] **Step 7: Commit the local tracker bridge**

```bash
jj describe -m "feat(tracking): emit local pose observations"
jj new
```

---

### Task 5: Enforce Readiness in the Camera Setup Flow

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`

**Interfaces:**

- Consumes: `tracker_initialized` and `tracker_readiness` server events from Task 4.
- Produces: server-authoritative setup states `:arming | :ready | :started`, disabled start control while not ready, and `fallback_to_timed`.

- [ ] **Step 1: Add failing LiveView tests for the readiness gate**

Extend the tracked-flow test before `camera_setup_started`:

```elixir
assert has_element?(session, "#camera-setup-start-btn[disabled]")

render_hook(session, "tracker_initialized", %{})
assert has_element?(session, "#camera-setup-start-btn[disabled]")

render_hook(session, "tracker_readiness", %{"state" => "ready"})
refute has_element?(session, "#camera-setup-start-btn[disabled]")
assert has_element?(session, "#camera-setup-timed-btn")
```

Add a test that `camera_setup_started` while arming leaves the panel present, then readiness followed by start hides it.

- [ ] **Step 2: Add explicit readiness handlers**

Replace the old initialization-only `tracker_ready` semantics with:

```elixir
def handle_event("tracker_initialized", _, socket) do
  {:noreply, assign(socket, :tracking_state, :initializing)}
end

def handle_event(
      "tracker_readiness",
      %{"state" => state},
      %{assigns: %{capture_setup_state: setup_state}} = socket
    )
    when state in ["ready", "optimal"] and setup_state in [:arming, :ready] do
  {:noreply,
   socket
   |> assign(:capture_setup_state, :ready)
   |> assign(:tracking_state, :ready)}
end

def handle_event(
      "tracker_readiness",
      %{"state" => "not_ready"},
      %{assigns: %{capture_setup_state: setup_state}} = socket
    )
    when setup_state in [:arming, :ready] do
  {:noreply,
   socket
   |> assign(:capture_setup_state, :arming)
   |> assign(:tracking_state, :arming)}
end

def handle_event("tracker_readiness", _params, socket), do: {:noreply, socket}

def handle_event(
      "camera_setup_started",
      _,
      %{assigns: %{capture_setup_state: :ready}} = socket
    ) do
  {:noreply, assign(socket, :capture_setup_state, :started)}
end

def handle_event("camera_setup_started", _, socket), do: {:noreply, socket}
```

Retain the existing `track` events for runtime degraded/running state.

- [ ] **Step 3: Render a genuinely disabled start button and timer fallback**

Update `camera_setup_panel/1`:

```heex
<button
  id="camera-setup-start-btn"
  type="button"
  disabled={@setup_state != :ready}
  class="pointer-events-auto row-start-3 min-h-14 w-full max-w-[430px] place-self-center rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition enabled:hover:opacity-90 enabled:active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-35"
>
  Start tracked session
</button>
<button
  id="camera-setup-timed-btn"
  type="button"
  class="pointer-events-auto row-start-3 mt-20 place-self-center px-5 py-3 text-sm text-[var(--session-muted)] underline decoration-[var(--session-track)] underline-offset-4"
>
  Use timer instead
</button>
```

Keep setup copy factual: arming asks for visible shoulders/hips; ready may say wider framing improves accuracy. Do not require or mention visible feet as a blocker.

- [ ] **Step 4: Guard the client click and support fallback**

In `onCameraSetupStart()`:

```js
const tracker = this.el.querySelector("#pose-tracker");
if (tracker?.dataset?.poseTrackerReady !== "true") return;
```

Add the timer fallback click path:

```js
const cameraSetupTimed = e.target.closest("#camera-setup-timed-btn");
if (cameraSetupTimed) {
  this.pushEvent("fallback_to_timed", {});
  this.dispatchFlow({ type: "CAPTURE_TIMED" });
}
```

Add LiveView handling that aborts the active pose capture run and restores timer mode:

```elixir
def handle_event("fallback_to_timed", _, socket) do
  {:noreply,
   socket
   |> abort_active_pose_capture("camera_setup_fallback")
   |> assign(:capture_mode, :timed)
   |> assign(:capture_setup_state, :idle)
   |> assign(:tracking_state, :disabled)}
end
```

The readiness handlers above intentionally ignore later setup-readiness changes after `capture_setup_state` becomes `:started`; runtime `track` events may degrade observation but must never reopen the camera setup panel.

- [ ] **Step 5: Run focused setup-flow tests**

```bash
cd assets
node --test js/hooks/session_hook_flow_test.mjs
cd ..
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: JavaScript hook flow and LiveView setup tests pass.

- [ ] **Step 6: Commit the readiness-gated setup flow**

```bash
jj describe -m "feat(tracking): gate tracked start on pose readiness"
jj new
```

---

### Task 6: Wire the Observer to the Authoritative Session Clock

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs`

**Interfaces:**

- Consumes: Task 3 observer API and Task 4 local DOM events.
- Produces: accepted main-work cadence, tracker reset at reliable boundaries, trusted finish detail, and timer fallback metadata.

- [ ] **Step 1: Add failing hook-flow tests for acceptance and isolation**

Update the test harness renderer so `updateTotalCounter(value)` appends to a returned `totalUpdates` array. Then add:

```js
function trackedContext(timeline) {
  const ctx = buildHarness({ poseTrackerReady: true });
  ctx.activeSegment = "workout";
  ctx.timeline = timeline;
  ctx.segment = {
    ...initialSegmentState(),
    mode: "running",
    timeline,
    clock: {
      ...initialSegmentState().clock,
      elapsedSec: 2.5,
      totalDurationSec: 10,
    },
  };
  ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
  ctx.trackerReadiness = "ready";
  ctx.startPoseObservation();
  return ctx;
}

test("tracked reps use session elapsed time without updating visible reps", () => {
  const ctx = trackedContext([
    { kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
  ]);

  ctx.observePoseRep({ index: 1, confidence: 0.9 });

  assert.deepEqual(ctx.tracking.cadenceMs, [2_500]);
  assert.deepEqual(ctx.totalUpdates, []);
});

test("explicit rest and pause candidate reps are ignored", () => {
  const resting = trackedContext([{ kind: "rest", duration_sec: 10 }]);
  resting.observePoseRep({ index: 1, confidence: 0.9 });
  assert.deepEqual(resting.tracking.cadenceMs, []);

  const paused = trackedContext([
    { kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
  ]);
  paused.segment = { ...paused.segment, mode: "paused" };
  paused.observePoseRep({ index: 1, confidence: 0.9 });
  assert.deepEqual(paused.tracking.cadenceMs, []);
});

test("tracking loss keeps workout state but forces timer fallback", () => {
  const ctx = trackedContext([
    { kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
  ]);
  const timelineBefore = ctx.timeline;
  ctx.updatePoseStatus({ state: "lost" });

  assert.equal(ctx.segment.mode, "running");
  assert.equal(ctx.timeline, timelineBefore);
  assert.equal(
    ctx.pushTrackedFinish({ main: { duration_sec: 10 } }),
    false,
  );
  assert.equal(ctx.trackingCompletion.reason, "tracking_lost");
});
```

Import the Task 3 observer helpers into the test file. Run the test and expect failures because the SessionHook observer methods do not exist yet. Do not use timers or sleeps.

- [ ] **Step 2: Import and initialize observer state**

In `session_hook.js`:

```js
import {
  finishTrackingObserver,
  initialTrackingObserver,
  observeTrackingRep,
  startTrackingObserver,
  updateTrackingReadiness,
  updateTrackingStatus,
} from "./pose_tracking_observer.mjs";
```

In `mounted()` initialize:

```js
this.tracking = initialTrackingObserver();
this.trackerReadiness = "not_ready";
this.trackingCompletion = null;
this.onPoseTrackerRep = (event) => this.observePoseRep(event.detail || {});
this.onPoseTrackerStatus = (event) => this.updatePoseStatus(event.detail || {});
this.onPoseTrackerReadiness = (event) => {
  this.trackerReadiness = event.detail?.state || "not_ready";
  this.tracking = updateTrackingReadiness(
    this.tracking,
    this.trackerReadiness,
  );
};
this.el.addEventListener("pose-tracker:rep", this.onPoseTrackerRep);
this.el.addEventListener("pose-tracker:status", this.onPoseTrackerStatus);
this.el.addEventListener("pose-tracker:readiness", this.onPoseTrackerReadiness);
```

Remove all three listeners in `destroyed()`.

- [ ] **Step 3: Start observation only at authoritative main-work start**

Add explicit helpers:

```js
startPoseObservation() {
  this.resetPoseTracker();
  this.tracking = startTrackingObserver(
    this.tracking,
    this.trackerReadiness,
  );
}

resetPoseTracker() {
  this.el.querySelector("#pose-tracker")?.dispatchEvent(
    new CustomEvent("pose-tracker:reset"),
  );
}
```

After `COUNTDOWN_DONE` has updated segment state in `beginSegment()`:

```js
if (this.activeSegment === "workout") {
  this.startPoseObservation();
}
```

Also call `resetPoseTracker()` after resume and visibility restoration. Resetting detector phase does not reset accepted observer cadence.

- [ ] **Step 4: Stamp eligible candidates from session elapsed time**

Add:

```js
observePoseRep({ index }) {
  const elapsedSec = this.segment.clock.elapsedSec || 0;
  const frame = currentFrame(this.timeline, elapsedSec);
  const eligible =
    this.activeSegment === "workout" &&
    this.segment.mode === "running" &&
    this.segment.clock.hiddenAt === null &&
    frame?.event?.kind === "work";

  this.tracking = observeTrackingRep(this.tracking, {
    index,
    elapsedMs: Math.max(0, Math.round(elapsedSec * 1_000)),
    eligible,
  });
}

updatePoseStatus({ state }) {
  this.tracking = updateTrackingStatus(this.tracking, state);
}
```

Do not call renderer or `dispatchSegment` from either method.

- [ ] **Step 5: Finish with observer cadence or fall back unchanged**

At the top of `pushTrackedFinish(payload)`:

```js
const durationMs = Math.round(payload?.main?.duration_sec * 1_000);
const finished = finishTrackingObserver(this.tracking, durationMs);
this.tracking = finished.state;
this.trackingCompletion = finished.result;
if (!finished.result.trusted) return false;
```

Dispatch:

```js
tracker.dispatchEvent(
  new CustomEvent("pose-tracker:finish", {
    detail: {
      durationMs,
      cadenceMs: finished.result.cadenceMs,
    },
  }),
);
```

When `pushTrackedFinish` returns false for tracked mode, augment only the server completion payload:

```js
this.pushEvent("session_complete", {
  ...command.payload,
  tracking: {
    status: "degraded",
    reason: this.trackingCompletion?.reason || "tracking_unavailable",
  },
});
```

Timed mode continues sending the existing payload shape.

- [ ] **Step 6: Run hook and observer tests**

```bash
cd assets
node --test \
  js/hooks/pose_tracking_observer_test.mjs \
  js/hooks/session_hook_flow_test.mjs
```

Expected: all tests pass; existing timer completion test remains unchanged.

- [ ] **Step 7: Commit authoritative-clock integration**

```bash
jj describe -m "feat(tracking): record reps on the session clock"
jj new
```

---

### Task 7: Present Tracked Results Without Removing Metadata

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`

**Interfaces:**

- Consumes: trusted `finish` payload or optional degraded `session_complete.tracking` metadata from Task 6.
- Produces: approved option-A summary hierarchy and unchanged metadata/edit controls.

- [ ] **Step 1: Add failing LiveView assertions for the approved summary**

Update the tracked-flow test after the trusted `finish` hook:

```elixir
assert has_element?(session, "#session-completion-summary")
assert has_element?(session, "#session-actual-reps", "3")
assert has_element?(session, "#session-planned-reps", "30")
assert has_element?(session, "#session-count-source", "Counted by camera")
refute has_element?(session, "#tracked-review")

assert has_element?(session, "#completion-reps-input")
assert has_element?(session, "#completion-duration-min-input")
assert has_element?(session, "#session-completion-mood")
assert has_element?(session, "#session-completion-tags")
assert has_element?(session, "#completion-note-input")
assert has_element?(session, "#session-save-btn")
```

Add a degraded completion test using `render_hook(session, "session_complete", payload)` with tracking status degraded; assert the planned count remains and `#session-count-source` contains `Camera view was interrupted`.

Add an edit test: submit `phx-change` with a changed actual count, then assert source copy contains `Edited` and the original camera count.

- [ ] **Step 2: Preserve degraded status from completion payload**

In `handle_event("session_complete", payload, socket)`, after successful main parsing:

```elixir
tracking_state =
  case payload do
    %{"tracking" => %{"status" => "degraded"}} -> :degraded
    _payload -> socket.assigns.tracking_state
  end

socket =
  socket
  |> assign(:phase, :done)
  |> assign(:tracking_state, tracking_state)
  |> assign(
    :completion_form,
    build_completion_form(socket, main.burpee_count_done, main.duration_sec)
  )
```

Do not reject the otherwise valid main result because optional tracking metadata is absent.

- [ ] **Step 3: Replace duplicate tracked review with one summary hierarchy**

Remove `#tracked-review`. In `#session-completion-summary` render:

```heex
<p
  id="session-actual-reps"
  class="qs-tabular text-[clamp(5rem,24vw,9rem)] font-semibold leading-none tracking-[-0.08em]"
>
  {completion_integer(@form, :burpee_count_actual)}
</p>
<p class="qs-tabular mt-4 text-sm text-[var(--session-muted)]">
  of
  <span id="session-planned-reps" class="font-medium text-[var(--session-ink)]">
    {completion_integer(@form, :burpee_count_planned)}
  </span>
  planned
</p>
<p
  :if={source = completion_count_source(@tracking_state, @tracked_finish, @form)}
  id="session-count-source"
  class="mt-3 text-xs text-[var(--session-muted)]"
>
  {source}
</p>
```

Keep the existing duration immediately below.

- [ ] **Step 4: Add honest provenance helper**

```elixir
defp completion_count_source(:review, %{reps: camera_reps}, form) do
  if completion_integer(form, :burpee_count_actual) == camera_reps do
    "Counted by camera"
  else
    "Edited · camera counted #{camera_reps}"
  end
end

defp completion_count_source(:degraded, _tracked_finish, _form) do
  "Camera view was interrupted · Check the total"
end

defp completion_count_source(_tracking_state, _tracked_finish, _form), do: nil
```

This helper describes provenance only; it does not change persisted values.

- [ ] **Step 5: Add stable IDs without removing metadata**

Retain every existing metadata field and action. Add IDs to existing wrappers if absent:

- mood container: `session-completion-mood`
- tags container: `session-completion-tags`

Do not remove:

- `completion-reps-input`
- `completion-duration-min-input`
- `completion-note-input`
- mood options
- tag options
- `session-save-btn`
- `session-discard-btn`

- [ ] **Step 6: Run focused LiveView tests**

```bash
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: trusted, degraded, edited, timed, metadata-preservation, save, cadence, and pose-capture tests pass.

- [ ] **Step 7: Commit summary and persistence integration**

```bash
jj describe -m "feat(tracking): review camera-counted reps"
jj new
```

---

### Task 8: Complete Verification and Browser Checks

**Files:**

- Verify all touched files; make no unrelated changes.

**Interfaces:**

- Consumes: Tasks 1–7.
- Produces: evidence that tracking is isolated, setup is gated, completion is honest, and existing session behavior remains intact.

- [ ] **Step 1: Run LSP diagnostics before builds**

Run diagnostics for:

- `assets/js/hooks/pose_readiness.mjs`
- `assets/js/hooks/pose_readiness_test.mjs`
- `assets/js/hooks/pose_rep_counter_test.mjs`
- `assets/js/hooks/pose_tracking_observer.mjs`
- `assets/js/hooks/pose_tracking_observer_test.mjs`
- `assets/js/hooks/pose_tracker_impl.mjs`
- `assets/js/hooks/session_hook.js`
- `assets/js/hooks/session_hook_flow_test.mjs`
- `lib/burpee_trainer_web/live/session_live.ex`
- `test/burpee_trainer_web/live/app_flow_test.exs`

Expected: zero errors or warnings in supported files.

- [ ] **Step 2: Run the complete asset suite**

```bash
cd assets
npm test
```

Expected: all JavaScript tests pass. The existing `MODULE_TYPELESS_PACKAGE_JSON` warning may remain; do not change package configuration as part of this feature.

- [ ] **Step 3: Run project precommit**

```bash
cd ..
mix precommit
```

Expected: formatter, compilation, and complete ExUnit suite pass.

- [ ] **Step 4: Build production assets**

```bash
mix assets.build
```

Expected: Tailwind and esbuild complete successfully and MediaPipe pose assets are copied.

- [ ] **Step 5: Verify tracked setup in Firefox**

Check:

1. Start tracked session is disabled while model/pose readiness is arming.
2. Stable shoulders/hips plus one knee enable start.
3. Cropped feet still permit start and do not show an error.
4. Timer fallback exits setup without leaving an active capture run.
5. The start click cannot bypass a stale disabled state.

- [ ] **Step 6: Verify workout isolation in Firefox**

Check:

1. No tracking count or pace UI appears in the runner.
2. Candidate movement during count-in, pause, and explicit rest does not affect completion cadence.
3. Camera loss does not alter audio, timer, fill, overall progress, or completion timing.
4. Recovery resets detector phase without clearing already accepted cadence.

- [ ] **Step 7: Verify completion hierarchy and metadata in Firefox**

Trusted path:

- one actual headline;
- `of N planned` directly beneath;
- `Counted by camera` provenance;
- duration, mood, reps, minutes, tags, notes, Save, and discard controls all present.

Edited path:

- edited actual becomes headline;
- planned target remains visible;
- provenance reads `Edited · camera counted N`.

Degraded path:

- timer-derived actual is headline;
- planned target remains visible;
- provenance asks the athlete to check the total;
- no partial camera count is shown.

- [ ] **Step 8: Confirm final workspace state**

```bash
jj --config signing.behavior=drop status
jj diff --stat @-
```

Expected: clean working copy after the final commit and only intended tracking/setup/summary files in the implementation commits. Do not push unless explicitly requested.
