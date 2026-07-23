# Gesture-Controlled Camera Setup, Warmup, and Start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tracked-session camera setup, "Warm up first?", and "Start workout" hands-free via a raised-wrist gesture (with an auto-timer fallback for camera setup and a no-gesture timeout for warmup-skip), and delete the dead server-rendered warmup/mood overlay this work sits next to.

**Architecture:** A new pure module (`pose_start_gesture.mjs`) classifies "wrist raised above shoulder" from pose samples using a hold-frame streak, mirroring `pose_readiness.mjs`. `pose_tracker_impl.mjs` owns one armed-step slot plus timers, driven by a `pose-tracker:arm` custom event dispatched from `session_hook.js` (the two hooks communicate only via DOM custom events — never a shared JS object). On satisfaction it dispatches `pose-tracker:gesture-confirm`/`pose-tracker:gesture-timeout`, which `session_hook.js` routes to the exact same handler methods (`onCameraSetupStart`, `onWarmupYes`, `onWarmupSkip`, `onWorkoutReady`) the deleted/hidden buttons used to call. Separately, `session_live.ex`'s dead `tap_to_start_overlay`/`session_started`/mood-picker code is deleted.

**Tech Stack:** Elixir/Phoenix LiveView, vanilla JS hooks (`.mjs`), `node --test` for JS unit tests, ExUnit for Elixir tests.

---

## File Structure

- **Create** `assets/js/hooks/pose_start_gesture.mjs` — pure streak-based raised-wrist gesture detector.
- **Create** `assets/js/hooks/pose_start_gesture_test.mjs` — unit tests for the above.
- **Modify** `assets/js/hooks/pose_tracker_impl.mjs` — add armed-step state, `pose-tracker:arm` listener, gesture-streak stepping in `loop()`, auto-timer (camera setup) and no-gesture timeout (warmup) using `setTimeout`/`clearTimeout`, `pose-tracker:gesture-confirm`/`pose-tracker:gesture-timeout` dispatch.
- **Modify** `assets/js/hooks/session_hook.js` — remove `camera-setup-start-btn` click wiring; add `pose-tracker:gesture-confirm`/`pose-tracker:gesture-timeout` listeners; add `armPoseTrackerStep`/`disarmPoseTrackerStep` helper dispatching `pose-tracker:arm`; call it from `showCameraSetupPrompt`, `showWarmupPrompt`, `showWorkoutStartPrompt`; hide warmup/workout-ready buttons for tracked mode.
- **Modify** `assets/js/hooks/session_hook_flow_test.mjs` — extend/add tests for the new gesture-confirm/timeout routing and button-hiding behavior.
- **Modify** `lib/burpee_trainer_web/live/session_live.ex` — delete `tap_to_start_overlay/1`, `handle_event("session_started", ...)`, `@mood_options`-in-that-overlay usage (completion panel's own stays), `warmup_asked` assign/attr/prop-threading, delete `#camera-setup-start-btn` from `camera_setup_panel/1`; collapse `case @phase` branch; change mount's `assign(:phase, :idle)` to `assign(:phase, :running)`.
- **Create** `test/burpee_trainer_web/live/session_live_test.exs` — new LiveView test file (none exists today) covering the dead-code removal and camera-setup panel changes.

---

## Task 1: Pure gesture detector module

**Files:**

- Create: `assets/js/hooks/pose_start_gesture.mjs`
- Test: `assets/js/hooks/pose_start_gesture_test.mjs`

- [ ] **Step 1: Write failing tests**

Create `assets/js/hooks/pose_start_gesture_test.mjs`:

```javascript
import assert from "node:assert/strict";
import test from "node:test";

import {
	initialStartGesture,
	stepStartGesture,
} from "./pose_start_gesture.mjs";

const point = (score = 0.9, x = 0.5, y = 0.5) => ({ score, x, y });

function sample({
	leftWristY = 0.8,
	rightWristY = 0.8,
	leftShoulderY = 0.25,
	rightShoulderY = 0.25,
	includeLeftWrist = true,
	includeRightWrist = true,
} = {}) {
	return {
		keypoints: {
			left_shoulder: point(0.9, 0.42, leftShoulderY),
			right_shoulder: point(0.9, 0.58, rightShoulderY),
			...(includeLeftWrist
				? { left_wrist: point(0.9, 0.42, leftWristY) }
				: {}),
			...(includeRightWrist
				? { right_wrist: point(0.9, 0.58, rightWristY) }
				: {}),
		},
	};
}

function repeat(state, sample, holdFramesRequired, count) {
	let next = state;
	for (let index = 0; index < count; index += 1) {
		next = stepStartGesture(next, { sample, holdFramesRequired });
	}
	return next;
}

test("wrist raised above shoulder accumulates streak toward satisfied", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 15);
	assert.equal(state.satisfied, true);
	assert.equal(state.streak, 15);
});

test("streak below hold-frames threshold is not satisfied", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 14);
	assert.equal(state.satisfied, false);
	assert.equal(state.streak, 14);
});

test("either wrist raised is sufficient", () => {
	const raised = sample({ leftWristY: 0.8, rightWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 15);
	assert.equal(state.satisfied, true);
});

test("lowering the arm mid-hold resets the streak", () => {
	const raised = sample({ leftWristY: 0.1 });
	const lowered = sample({ leftWristY: 0.8, rightWristY: 0.8 });
	const partial = repeat(initialStartGesture(), raised, 15, 10);
	const dropped = stepStartGesture(partial, { sample: lowered, holdFramesRequired: 15 });
	assert.equal(dropped.streak, 0);
	assert.equal(dropped.satisfied, false);
});

test("missing wrist landmarks are treated as not raised", () => {
	const missing = sample({ includeLeftWrist: false, includeRightWrist: false });
	const state = repeat(initialStartGesture(), missing, 15, 15);
	assert.equal(state.satisfied, false);
	assert.equal(state.streak, 0);
});

test("low-confidence wrist landmark does not count as raised", () => {
	const weak = sample({ leftWristY: 0.1 });
	weak.keypoints.left_wrist.score = 0.2;
	const state = repeat(initialStartGesture(), weak, 15, 15);
	assert.equal(state.satisfied, false);
});

test("satisfied streak keeps counting past the threshold without resetting", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 20);
	assert.equal(state.satisfied, true);
	assert.equal(state.streak, 20);
});
```

- [ ] **Step 2: Run the test and observe the missing-module failure**

Run: `cd assets && node --test js/hooks/pose_start_gesture_test.mjs`
Expected: FAIL — `Cannot find module './pose_start_gesture.mjs'`

- [ ] **Step 3: Implement the pure gesture detector**

Create `assets/js/hooks/pose_start_gesture.mjs`:

```javascript
const MIN_SCORE = 0.5;

export function initialStartGesture() {
	return { streak: 0, satisfied: false };
}

export function stepStartGesture(state, { sample, holdFramesRequired }) {
	const raised = wristRaised(sample);
	const streak = raised ? state.streak + 1 : 0;

	return {
		streak,
		satisfied: streak >= holdFramesRequired,
	};
}

function wristRaised(sample) {
	const points = sample?.keypoints || {};
	return (
		raisedPair(points.left_wrist, points.left_shoulder) ||
		raisedPair(points.right_wrist, points.right_shoulder)
	);
}

function raisedPair(wrist, shoulder) {
	return visible(wrist) && visible(shoulder) && wrist.y < shoulder.y;
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd assets && node --test js/hooks/pose_start_gesture_test.mjs`
Expected: all 7 tests PASS

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(tracking): classify raised-wrist start gesture"
jj new
```

---

## Task 2: Wire gesture and timers into the pose tracker

**Files:**

- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Test: `assets/js/hooks/session_hook_flow_test.mjs` (extends existing file — `createPoseTracker` is already imported there)

The pose tracker (`createPoseTracker`) needs to: (a) accept `pose-tracker:arm` custom events declaring which step is currently armed and its hold-frame requirement, (b) step the gesture detector on every sampled frame when a step is armed, (c) run a camera-setup auto-timer and a warmup no-gesture timeout, (d) dispatch `pose-tracker:gesture-confirm` / `pose-tracker:gesture-timeout` on satisfaction/timeout, (e) clean up timers on `destroyed()`.

- [ ] **Step 1: Write a failing test for gesture-confirm on satisfied streak**

Add to `assets/js/hooks/session_hook_flow_test.mjs` (near the other `createPoseTracker`-based tests — search for `"pose tracker binds only to the preview"` around line 824 for the surrounding pattern of constructing a tracker directly):

```javascript
test("armed camera-setup step dispatches gesture-confirm when wrist streak completes", async () => {
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";
	const preview = new FakeElement("video");
	preview.id = "pose-tracker-preview";
	const canvas = new FakeElement("canvas");
	canvas.id = "pose-tracker-canvas";
	tracker.append(preview, canvas);
	root.append(tracker);

	const dispatched = [];
	tracker.addEventListener("pose-tracker:gesture-confirm", (event) => {
		dispatched.push(event.type);
	});

	const raisedSample = {
		keypoints: {
			left_shoulder: { score: 0.9, x: 0.42, y: 0.25 },
			left_wrist: { score: 0.9, x: 0.42, y: 0.1 },
		},
	};

	let poseCount = 0;
	const fakePoses = [{ keypoints: [] }];

	const hookStub = {
		el: tracker,
		pushEvent() {},
	};

	const impl = createPoseTracker(hookStub, {
		createBlazePoseDetector: async () => ({
			estimatePoses: async () => {
				poseCount += 1;
				return fakePoses;
			},
		}),
		mediaDevices: {
			getUserMedia: async () => ({ getTracks: () => [] }),
		},
		now: () => poseCount * 100,
		requestAnimationFrame: (cb) => {
			cb();
			return 1;
		},
		cancelAnimationFrame: () => {},
		webglAvailable: () => true,
		waitForVideoFrame: async () => {},
		sampleFromPose: () => raisedSample,
	});

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 3 },
		}),
	);

	await impl.mounted();

	assert.deepEqual(dispatched, ["pose-tracker:gesture-confirm"]);

	impl.destroyed();
});
```

- [ ] **Step 2: Run the test and observe failure**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: FAIL — either `pose-tracker:arm` is never handled (no armed state exists yet) so `dispatched` stays empty, or an assertion mismatch. Confirm the test fails for the expected reason (missing feature, not a typo) before proceeding.

- [ ] **Step 3: Implement armed-step state, gesture stepping, and event dispatch in `pose_tracker_impl.mjs`**

Add the import at the top of `assets/js/hooks/pose_tracker_impl.mjs` (after the existing `pose_readiness.mjs` import on line 3):

```javascript
import { initialStartGesture, stepStartGesture } from "./pose_start_gesture.mjs";
```

Inside `createPoseTracker`, after the existing state declarations (after `let lastReadinessStatus = readiness.status;` at line 85), add:

```javascript
	let armedStep = null;
	let armedHoldFramesRequired = 0;
	let startGesture = initialStartGesture();
	let autoConfirmTimeoutId = null;
	let noGestureTimeoutId = null;
```

Add these constants near the top of the file, after the existing `export` statements (after line 19, before `configurePreviewVideo`):

```javascript
const CAMERA_SETUP_AUTO_CONFIRM_MS = 1500;
const WARMUP_NO_GESTURE_TIMEOUT_MS = 4000;
```

Add an `armStep` handler function inside `createPoseTracker`, near `reset` (after the `reset` declaration around line 102):

```javascript
	const clearArmTimers = () => {
		if (autoConfirmTimeoutId !== null) {
			clearTimeout(autoConfirmTimeoutId);
			autoConfirmTimeoutId = null;
		}
		if (noGestureTimeoutId !== null) {
			clearTimeout(noGestureTimeoutId);
			noGestureTimeoutId = null;
		}
	};

	const armStep = (event) => {
		clearArmTimers();
		startGesture = initialStartGesture();
		const detail = event.detail || {};
		armedStep = detail.step || null;
		armedHoldFramesRequired = detail.holdFramesRequired || 0;

		if (armedStep === "camera_setup") {
			autoConfirmTimeoutId = setTimeout(() => {
				autoConfirmTimeoutId = null;
				dispatchLocal("pose-tracker:gesture-confirm", {});
			}, CAMERA_SETUP_AUTO_CONFIRM_MS);
		}

		if (armedStep === "warmup") {
			noGestureTimeoutId = setTimeout(() => {
				noGestureTimeoutId = null;
				dispatchLocal("pose-tracker:gesture-timeout", {});
			}, WARMUP_NO_GESTURE_TIMEOUT_MS);
		}
	};
```

Register the listener in `mountedHook()`, alongside the existing listeners (after line 106, `hook.el.addEventListener("pose-tracker:reset", reset);`):

```javascript
		hook.el.addEventListener("pose-tracker:arm", armStep);
```

Remove it in `destroyed()`, alongside the existing removals (after line 251, `hook.el.removeEventListener("pose-tracker:reset", reset);`):

```javascript
		hook.el.removeEventListener("pose-tracker:arm", armStep);
		clearArmTimers();
```

Inside `loop()`, after the existing readiness-transition block (after line 191, the closing `}` of the `if (nextReadiness.status !== lastReadinessStatus)` block), add gesture stepping:

```javascript
		if (armedStep && armedHoldFramesRequired > 0) {
			const wasSatisfied = startGesture.satisfied;
			startGesture = stepStartGesture(startGesture, {
				sample,
				holdFramesRequired: armedHoldFramesRequired,
			});
			if (startGesture.satisfied && !wasSatisfied) {
				clearArmTimers();
				dispatchLocal("pose-tracker:gesture-confirm", {});
			}
		}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: the new test PASSES; all pre-existing tests in this file still PASS.

- [ ] **Step 5: Write a failing test for the warmup no-gesture timeout**

Add to the same file, after the previous test:

```javascript
test("armed warmup step dispatches gesture-timeout when no gesture arrives", async () => {
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";
	const preview = new FakeElement("video");
	preview.id = "pose-tracker-preview";
	const canvas = new FakeElement("canvas");
	canvas.id = "pose-tracker-canvas";
	tracker.append(preview, canvas);
	root.append(tracker);

	const dispatched = [];
	tracker.addEventListener("pose-tracker:gesture-timeout", (event) => {
		dispatched.push(event.type);
	});

	let scheduledCallback = null;
	const notRaisedSample = {
		keypoints: {
			left_shoulder: { score: 0.9, x: 0.42, y: 0.25 },
			left_wrist: { score: 0.9, x: 0.42, y: 0.8 },
		},
	};

	const hookStub = { el: tracker, pushEvent() {} };

	const impl = createPoseTracker(hookStub, {
		createBlazePoseDetector: async () => ({
			estimatePoses: async () => [{ keypoints: [] }],
		}),
		mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
		now: () => 0,
		requestAnimationFrame: () => 1,
		cancelAnimationFrame: () => {},
		webglAvailable: () => true,
		waitForVideoFrame: async () => {},
		sampleFromPose: () => notRaisedSample,
		setTimeout: (callback, _ms) => {
			scheduledCallback = callback;
			return 1;
		},
		clearTimeout: () => {},
	});

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "warmup", holdFramesRequired: 15 },
		}),
	);

	await impl.mounted();

	assert.ok(scheduledCallback, "expected a timeout to have been scheduled");
	scheduledCallback();

	assert.deepEqual(dispatched, ["pose-tracker:gesture-timeout"]);

	impl.destroyed();
});
```

- [ ] **Step 6: Run the test and observe failure**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: FAIL — `createPoseTracker` does not yet accept `setTimeout`/`clearTimeout` as injectable `runtime` overrides, so the real global timers are used and `scheduledCallback` stays `null`.

- [ ] **Step 7: Make timers injectable via `runtime`**

In `assets/js/hooks/pose_tracker_impl.mjs`, inside `createPoseTracker(hook, runtime = {})`, add alongside the existing runtime destructuring (after line 73, `const cancelFrame = runtime.cancelAnimationFrame || cancelAnimationFrame;`):

```javascript
	const scheduleTimeout = runtime.setTimeout || ((cb, ms) => setTimeout(cb, ms));
	const clearScheduledTimeout = runtime.clearTimeout || clearTimeout;
```

Update `clearArmTimers` and `armStep` (written in Step 3) to use `scheduleTimeout`/`clearScheduledTimeout` instead of the raw globals:

```javascript
	const clearArmTimers = () => {
		if (autoConfirmTimeoutId !== null) {
			clearScheduledTimeout(autoConfirmTimeoutId);
			autoConfirmTimeoutId = null;
		}
		if (noGestureTimeoutId !== null) {
			clearScheduledTimeout(noGestureTimeoutId);
			noGestureTimeoutId = null;
		}
	};

	const armStep = (event) => {
		clearArmTimers();
		startGesture = initialStartGesture();
		const detail = event.detail || {};
		armedStep = detail.step || null;
		armedHoldFramesRequired = detail.holdFramesRequired || 0;

		if (armedStep === "camera_setup") {
			autoConfirmTimeoutId = scheduleTimeout(() => {
				autoConfirmTimeoutId = null;
				dispatchLocal("pose-tracker:gesture-confirm", {});
			}, CAMERA_SETUP_AUTO_CONFIRM_MS);
		}

		if (armedStep === "warmup") {
			noGestureTimeoutId = scheduleTimeout(() => {
				noGestureTimeoutId = null;
				dispatchLocal("pose-tracker:gesture-timeout", {});
			}, WARMUP_NO_GESTURE_TIMEOUT_MS);
		}
	};
```

- [ ] **Step 8: Run both new tests to verify they pass**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: both new tests PASS; all pre-existing tests in this file still PASS.

- [ ] **Step 9: Write a failing test confirming gesture-confirm clears a pending auto-timer (no double-fire)**

Add to the same file:

```javascript
test("gesture confirm during camera-setup arm cancels the pending auto-timer", async () => {
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";
	const preview = new FakeElement("video");
	preview.id = "pose-tracker-preview";
	const canvas = new FakeElement("canvas");
	canvas.id = "pose-tracker-canvas";
	tracker.append(preview, canvas);
	root.append(tracker);

	const dispatched = [];
	tracker.addEventListener("pose-tracker:gesture-confirm", (event) => {
		dispatched.push(event.type);
	});

	const raisedSample = {
		keypoints: {
			left_shoulder: { score: 0.9, x: 0.42, y: 0.25 },
			left_wrist: { score: 0.9, x: 0.42, y: 0.1 },
		},
	};

	let poseCount = 0;
	const clearedIds = [];

	const hookStub = { el: tracker, pushEvent() {} };

	const impl = createPoseTracker(hookStub, {
		createBlazePoseDetector: async () => ({
			estimatePoses: async () => {
				poseCount += 1;
				return [{ keypoints: [] }];
			},
		}),
		mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
		now: () => poseCount * 100,
		requestAnimationFrame: (cb) => {
			cb();
			return 1;
		},
		cancelAnimationFrame: () => {},
		webglAvailable: () => true,
		waitForVideoFrame: async () => {},
		sampleFromPose: () => raisedSample,
		setTimeout: () => 42,
		clearTimeout: (id) => clearedIds.push(id),
	});

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 2 },
		}),
	);

	await impl.mounted();

	assert.deepEqual(dispatched, ["pose-tracker:gesture-confirm"]);
	assert.ok(clearedIds.includes(42), "expected the auto-confirm timer to be cleared");

	impl.destroyed();
});
```

- [ ] **Step 10: Run the test and confirm it passes without further changes**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: PASS — this is covered by the existing `clearArmTimers()` call inside the gesture-satisfied branch in `loop()` (Step 3). If it fails, check that branch calls `clearArmTimers()` before dispatching, not after.

- [ ] **Step 11: Commit**

```bash
jj describe -m "feat(tracking): arm gesture and timeout confirmation in pose tracker"
jj new
```

---

## Task 3: Route gesture events in `session_hook.js` and hide superseded buttons

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Test: `assets/js/hooks/session_hook_flow_test.mjs`

- [ ] **Step 1: Write a failing test for camera-setup arming and gesture routing**

Add to `assets/js/hooks/session_hook_flow_test.mjs`, near the existing camera-setup tests (after the `"camera setup timer fallback..."` test around line 822):

```javascript
test("camera setup prompt arms the pose tracker for the camera_setup step", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "camera_setup",
		holdFramesRequired: 15,
	});
});

test("gesture-confirm on the pose tracker triggers camera setup start", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const wrapper = ctx.el.querySelector("#pose-tracker-visibility");

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(wrapper.style.visibility, "hidden");
	assert.deepEqual(ctx.events.at(-1), {
		name: "camera_setup_started",
		payload: {},
	});
});

test("warmup prompt arms the warmup step and hides tap buttons for tracked mode", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.onCameraSetupStart(); // no-op until ready, but exercises the path safely
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "warmup",
		holdFramesRequired: 15,
	});
	assert.match(
		ctx.el.querySelector("#warmup-yes-btn").className,
		/\bhidden\b/,
	);
	assert.match(
		ctx.el.querySelector("#warmup-skip-btn").className,
		/\bhidden\b/,
	);
});

test("warmup prompt leaves tap buttons visible for timer mode", () => {
	const ctx = buildHarness();
	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TIMED" });

	assert.doesNotMatch(
		ctx.el.querySelector("#warmup-yes-btn").className,
		/\bhidden\b/,
	);
});

test("gesture-confirm on the pose tracker during warmup answers yes", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "warmup_countdown");
});

test("gesture-timeout on the pose tracker during warmup skips warmup", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-timeout", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "workout_ready_prompt");
});

test("start-workout prompt arms the workout_start step with a longer hold and hides the tap button for tracked mode", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "workout_start",
		holdFramesRequired: 30,
	});
	assert.match(
		ctx.el.querySelector("#workout-ready-btn").className,
		/\bhidden\b/,
	);
});

test("gesture-confirm on the pose tracker during start-workout prompt starts the workout", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "workout_countdown");
});
```

- [ ] **Step 2: Run the tests and observe failures**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: FAIL — no `pose-tracker:arm` is ever dispatched from `session_hook.js` yet, no `pose-tracker:gesture-confirm`/`pose-tracker:gesture-timeout` listeners exist, and no `hidden` class is ever applied to the warmup/workout-ready buttons.

- [ ] **Step 3: Add the arm helper and gesture-event listeners in `session_hook.js`**

In `assets/js/hooks/session_hook.js`, add a helper method (anywhere among the other helper methods, e.g. right after `resetPoseTracker()` at line 818-822):

```javascript
	armPoseTrackerStep(step, holdFramesRequired) {
		if (this.flow.captureMode !== "tracked") return;
		this.el
			.querySelector("#pose-tracker")
			?.dispatchEvent(
				new CustomEvent("pose-tracker:arm", {
					detail: { step, holdFramesRequired },
				}),
			);
	},

	disarmPoseTrackerStep() {
		this.armPoseTrackerStep(null, 0);
	},
```

In `mounted()`, register the two new listeners alongside the existing `pose-tracker:*` listeners (after line 75, the closing of the `this.el.addEventListener("pose-tracker:readiness", ...)` call):

```javascript
		this.onPoseTrackerGestureConfirm = () => this.handlePoseGestureConfirm();
		this.onPoseTrackerGestureTimeout = () => this.handlePoseGestureTimeout();
		this.el.addEventListener(
			"pose-tracker:gesture-confirm",
			this.onPoseTrackerGestureConfirm,
		);
		this.el.addEventListener(
			"pose-tracker:gesture-timeout",
			this.onPoseTrackerGestureTimeout,
		);
```

In `destroyed()`, remove them symmetrically (after line 178, the closing of the existing `pose-tracker:readiness` removal):

```javascript
		this.el.removeEventListener(
			"pose-tracker:gesture-confirm",
			this.onPoseTrackerGestureConfirm,
		);
		this.el.removeEventListener(
			"pose-tracker:gesture-timeout",
			this.onPoseTrackerGestureTimeout,
		);
```

Add the two handler methods, near `onCameraSetupStart`/`onWarmupYes`/`onWarmupSkip`/`onWorkoutReady` (after `onCameraSetupTimed()` at line 536-539):

```javascript
	handlePoseGestureConfirm() {
		switch (this.armedPoseStep) {
			case "camera_setup":
				this.onCameraSetupStart();
				break;
			case "warmup":
				this.onWarmupYes();
				break;
			case "workout_start":
				this.onWorkoutReady();
				break;
		}
	},

	handlePoseGestureTimeout() {
		if (this.armedPoseStep === "warmup") this.onWarmupSkip();
	},
```

Track which step is armed by setting `this.armedPoseStep` inside `armPoseTrackerStep`/`disarmPoseTrackerStep` — update those two methods:

```javascript
	armPoseTrackerStep(step, holdFramesRequired) {
		this.armedPoseStep = step;
		if (this.flow.captureMode !== "tracked") return;
		this.el
			.querySelector("#pose-tracker")
			?.dispatchEvent(
				new CustomEvent("pose-tracker:arm", {
					detail: { step, holdFramesRequired },
				}),
			);
	},

	disarmPoseTrackerStep() {
		this.armPoseTrackerStep(null, 0);
	},
```

Initialize `this.armedPoseStep = null;` in `mounted()`, alongside the other initial field assignments (after line 59, `this.trackingCompletion = null;`).

- [ ] **Step 4: Run tests to verify gesture-confirm/timeout routing tests pass**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: the routing tests (`gesture-confirm on the pose tracker triggers camera setup start`, `...during warmup answers yes`, `...timeout ... skips warmup`, `...during start-workout ... starts the workout`) PASS. The arming/hidden-class tests still FAIL (not wired yet) — confirm no unrelated regressions among pre-existing tests.

- [ ] **Step 5: Delete the manual camera-setup start button and wire arming into `showCameraSetupPrompt`**

In `lib/burpee_trainer_web/live/session_live.ex`, delete the `#camera-setup-start-btn` button from `camera_setup_panel/1` (lines 622-629):

```elixir
      <button
        id="camera-setup-start-btn"
        type="button"
        disabled={@setup_state != :ready}
        class="pointer-events-auto row-start-3 min-h-14 w-full max-w-[430px] place-self-center rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition enabled:hover:opacity-90 enabled:active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-35"
      >
        Start tracked session
      </button>
```

Delete this whole block. The `#camera-setup-timed-btn` button stays as-is.

In `assets/js/hooks/session_hook.js`, delete the `cameraSetupStart`/`if (cameraSetupStart) this.onCameraSetupStart();` lines from the click dispatch table (lines 129 and 139):

```javascript
			const cameraSetupStart = e.target.closest("#camera-setup-start-btn");
```
and
```javascript
			if (cameraSetupStart) this.onCameraSetupStart();
```

Delete both lines.

In `showCameraSetupPrompt()` (lines 422-436), add arming right before the function returns (after `overlay.replaceChildren();` at line 435, before the closing `},`):

```javascript
		this.armPoseTrackerStep("camera_setup", 15);
```

- [ ] **Step 6: Run tests to verify camera-setup arming test passes**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: `"camera setup prompt arms the pose tracker for the camera_setup step"` PASSES.

- [ ] **Step 7: Wire arming and button-hiding into `showWarmupPrompt`**

In `assets/js/hooks/session_hook.js`, inside `showWarmupPrompt()` (lines 314-366), update the `yes`/`skip` button class assignment (lines 352-353 and 359-360) to add a `hidden` class conditionally, and arm the step at the end of the function:

Replace:
```javascript
		const yes = document.createElement("button");
		yes.type = "button";
		yes.id = "warmup-yes-btn";
		yes.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-6 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]";
		yes.textContent = "Warm up";

		const skip = document.createElement("button");
		skip.type = "button";
		skip.id = "warmup-skip-btn";
		skip.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-border)] bg-transparent px-6 py-4 text-base font-medium text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)] active:scale-[0.98]";
		skip.textContent = "Skip warmup";

		buttons.append(yes, skip);
		overlay.append(title, description, buttons);
		parent.appendChild(overlay);
	},
```

With:
```javascript
		const hiddenClass = this.flow.captureMode === "tracked" ? " hidden" : "";

		const yes = document.createElement("button");
		yes.type = "button";
		yes.id = "warmup-yes-btn";
		yes.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-6 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]" +
			hiddenClass;
		yes.textContent = "Warm up";

		const skip = document.createElement("button");
		skip.type = "button";
		skip.id = "warmup-skip-btn";
		skip.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-border)] bg-transparent px-6 py-4 text-base font-medium text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)] active:scale-[0.98]" +
			hiddenClass;
		skip.textContent = "Skip warmup";

		buttons.append(yes, skip);
		overlay.append(title, description, buttons);
		parent.appendChild(overlay);
		this.armPoseTrackerStep("warmup", 15);
	},
```

- [ ] **Step 8: Run tests to verify warmup arming and button-hiding tests pass**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: `"warmup prompt arms the warmup step and hides tap buttons for tracked mode"` and `"warmup prompt leaves tap buttons visible for timer mode"` PASS.

- [ ] **Step 9: Wire arming and button-hiding into `showWorkoutStartPrompt`**

In `assets/js/hooks/session_hook.js`, inside `showWorkoutStartPrompt(_titleText, _descriptionText)` (lines 452-493), update the button creation (lines 484-489) and add arming at the end:

Replace:
```javascript
		const button = document.createElement("button");
		button.type = "button";
		button.id = "workout-ready-btn";
		button.className =
			"mt-2 min-h-14 w-full max-w-lg rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]";
		button.textContent = "Start workout";

		overlay.append(meta, title, button);
		parent.appendChild(overlay);
	},
```

With:
```javascript
		const button = document.createElement("button");
		button.type = "button";
		button.id = "workout-ready-btn";
		button.className =
			"mt-2 min-h-14 w-full max-w-lg rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]" +
			(this.flow.captureMode === "tracked" ? " hidden" : "");
		button.textContent = "Start workout";

		overlay.append(meta, title, button);
		parent.appendChild(overlay);
		this.armPoseTrackerStep("workout_start", 30);
	},
```

- [ ] **Step 10: Disarm the pose tracker once the workout actually starts**

Without this, the `workout_start` step stays armed for the entire main workout — a burpee's arm-raise at the top of the movement would satisfy the same raised-wrist streak and re-fire `onWorkoutReady()` mid-session. Guard against that by disarming as soon as `WORKOUT_READY` is handled.

In `assets/js/hooks/session_hook.js`, inside `onWorkoutReady()` (lines 508-510), disarm before dispatching the flow event:

```javascript
	onWorkoutReady() {
		this.disarmPoseTrackerStep();
		this.dispatchFlow({ type: "WORKOUT_READY" });
	},
```

Add a test to `assets/js/hooks/session_hook_flow_test.mjs`, after the `"gesture-confirm on the pose tracker during start-workout prompt starts the workout"` test:

```javascript
test("starting the workout disarms the pose tracker so mid-workout arm-raises are ignored", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	ctx.onWorkoutReady();

	assert.deepEqual(armedEvents.at(-1), { step: null, holdFramesRequired: 0 });
});
```

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`
Expected: PASS.

- [ ] **Step 11: Run the full JS test suite to verify everything passes**

Run: `cd assets && npm test`
Expected: all tests PASS, including every test written in this task and Task 1/2.

- [ ] **Step 12: Commit**

```bash
jj describe -m "feat(tracking): route pose gestures to camera setup, warmup, and start"
jj new
```

---

## Task 4: Delete the dead server-side warmup/mood overlay

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Create: `test/burpee_trainer_web/live/session_live_test.exs`

- [ ] **Step 1: Write failing LiveView tests establishing the target server-side behavior**

This mirrors the existing pattern in `test/burpee_trainer_web/live/app_flow_test.exs` (`init_test_session(conn, %{user_id: user.id})`, `BurpeeTrainer.Fixtures.plan_fixture/2`, route `~p"/session/#{plan.id}"`).

Create `test/burpee_trainer_web/live/session_live_test.exs`:

```elixir
defmodule BurpeeTrainerWeb.SessionLiveTest do
  use BurpeeTrainerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import BurpeeTrainer.Fixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders without a dead warmup/mood overlay", %{conn: conn, user: user} do
    plan = plan_fixture(user)

    {:ok, view, html} = live(conn, ~p"/session/#{plan.id}")

    refute html =~ "How do you feel?"
    refute has_element?(view, "[phx-click=\"session_started\"]")
  end

  test "camera setup panel no longer renders a manual start button", %{
    conn: conn,
    user: user
  } do
    plan = plan_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

    refute has_element?(view, "#camera-setup-start-btn")
  end
end
```

- [ ] **Step 2: Run the tests and observe current failures**

Run: `mix test test/burpee_trainer_web/live/session_live_test.exs`
Expected: FAIL on `refute html =~ "How do you feel?"` (the dead overlay's text is still in the initial server-rendered HTML even though it's clobbered by JS at runtime) and PASS is not yet reached for `refute has_element?(view, "#camera-setup-start-btn")` until Task 3 Step 5's server-side deletion (already done if Task 3 ran first) — confirm both assertions fail for the mood-overlay reason specifically, not a routing/fixture error.

- [ ] **Step 3: Delete `tap_to_start_overlay/1` and its call site**

In `lib/burpee_trainer_web/live/session_live.ex`, delete the call site inside `session_runner/1` (lines 789-791):

```elixir
      <%= if @phase == :idle do %>
        <.tap_to_start_overlay warmup_asked={@warmup_asked} />
      <% end %>
```

Delete this block entirely (the `session_runner` function's closing `</div>` and `"""` remain).

Delete the `attr(:warmup_asked, :boolean, required: true)` line from `session_runner/1`'s attrs (line 661) and the `warmup_asked={@warmup_asked}` prop passed into it from the call site in the main render (line 588).

Delete the entire `tap_to_start_overlay/1` function definition and its `attr` declaration (lines 796-843):

```elixir
  attr(:warmup_asked, :boolean, required: true)

  defp tap_to_start_overlay(assigns) do
    ~H"""
    <div
      id="start-overlay"
      class="absolute inset-0 z-10 flex flex-col items-center justify-center gap-6 bg-[var(--session-bg)] text-center text-[var(--session-ink)]"
    >
      <%= if not @warmup_asked do %>
        <span class="text-sm font-medium text-[var(--session-muted)]">
          Warmup?
        </span>
        <div class="flex gap-2">
          <button
            type="button"
            id="warmup-yes-btn"
            class="min-w-24 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-6 py-4 text-sm font-medium text-[var(--session-ink)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70"
          >
            Yes
          </button>
          <button
            type="button"
            id="warmup-skip-btn"
            class="min-w-24 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-6 py-4 text-sm font-medium text-[var(--session-muted)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70 hover:text-[var(--session-ink)]"
          >
            Skip
          </button>
        </div>
      <% else %>
        <span class="text-sm font-medium text-[var(--session-muted)]">
          How do you feel?
        </span>
        <div class="flex gap-2">
          <%= for {icon, label, value} <- [{"hero-face-frown", "Tired", -1}, {"hero-minus-circle", "OK", 0}, {"hero-bolt", "Hyped", 1}] do %>
            <button
              type="button"
              phx-click="session_started"
              phx-value-mood={value}
              class="min-w-20 rounded-xl border border-[var(--session-border)] bg-[var(--session-bg)]/55 px-4 py-4 text-sm font-medium text-[var(--session-ink)] transition active:scale-[0.98] hover:bg-[var(--session-track)]/70"
            >
              {label}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
```

Delete this entire function.

- [ ] **Step 4: Delete `handle_event("session_started", ...)`**

Delete lines 65-68:

```elixir
  @impl true
  def handle_event("session_started", _params, socket) do
    {:noreply, socket |> assign(:phase, :running) |> assign(:warmup_asked, true)}
  end
```

Note: `@impl true` is only on this clause if it's the first `handle_event` clause carrying that annotation for the group — check the surrounding clauses; if `handle_event("choose_tracked", ...)` immediately below still needs `@impl true`, add it there instead of leaving the group without one.

- [ ] **Step 5: Delete the `warmup_asked` mount assign**

Delete line 43:

```elixir
          |> assign(:warmup_asked, false)
```

- [ ] **Step 6: Collapse the `:idle`/`:running` phase distinction**

Change the mount assign on line 41 from:

```elixir
          |> assign(:phase, :idle)
```

to:

```elixir
          |> assign(:phase, :running)
```

Change the `case @phase do` branch (line 531-542) from:

```elixir
        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <.completion_panel
              form={@completion_form}
              mood={@mood}
              completion_tags={@completion_tags}
              tracking_state={@tracking_state}
              tracked_finish={@tracked_finish}
            />
          <% phase when phase in [:idle, :running] -> %>
```

to:

```elixir
        <%= case @phase do %>
          <% :not_runnable -> %>
            <.not_runnable_panel />
          <% :done -> %>
            <.completion_panel
              form={@completion_form}
              mood={@mood}
              completion_tags={@completion_tags}
              tracking_state={@tracking_state}
              tracked_finish={@tracked_finish}
            />
          <% :running -> %>
```

Leave the rest of that clause's body (the `<%= if @capture_mode == :tracked do %>...<.session_runner .../>` content) unchanged.

- [ ] **Step 7: Update the stale moduledoc**

The module's `@moduledoc` (lines 1-16) documents `State machine (server-side phase): :idle → :running → :done`, which is now inaccurate. Change:

```elixir
  State machine (server-side phase):
      :idle → :running → :done
```

to:

```elixir
  State machine (server-side phase):
      :running → :done
```

- [ ] **Step 8: Run the LiveView tests to verify they pass**

Run: `mix test test/burpee_trainer_web/live/session_live_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the full Elixir test suite to check for regressions**

Run: `mix test`
Expected: all tests PASS (in particular, confirm nothing else in the suite referenced `:idle`, `warmup_asked`, or `session_started` — grep first if any failure looks related: `grep -rn "warmup_asked\|:idle\|session_started" test/`).

- [ ] **Step 10: Commit**

```bash
jj describe -m "fix(session): remove dead warmup and mood overlay"
jj new
```

---

## Task 5: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run full JS test suite**

Run: `cd assets && npm test`
Expected: all tests PASS.

- [ ] **Step 2: Run `mix precommit`**

Run: `mix precommit`
Expected: compiles with `--warnings-as-errors` cleanly, no unused deps, formatting clean, all Elixir tests PASS.

- [ ] **Step 3: Build production assets**

Run: `mix assets.build`
Expected: builds cleanly, no errors.

- [ ] **Step 4: Manual Firefox verification — camera setup auto-confirm**

Start the dev server (`mix phx.server`), open a tracked session in Firefox, stand in frame without touching the phone, and confirm the camera-setup panel auto-advances to the warmup prompt within ~1.5s of achieving a stable "Camera ready" state, with no `#camera-setup-start-btn` present anywhere.

- [ ] **Step 5: Manual Firefox verification — warmup gesture and timeout**

On the "Warm up first?" prompt (tracked mode), confirm: (a) raising a hand and holding it ~1s advances to the warmup countdown, (b) standing normally without raising a hand for ~4s advances to the "Ready when you are" prompt (skip path), (c) no `#warmup-yes-btn`/`#warmup-skip-btn` are visibly clickable during this.

- [ ] **Step 6: Manual Firefox verification — start-workout gesture**

On the "Ready when you are" / "Warmup complete" prompt (tracked mode), confirm raising a hand requires a noticeably longer hold (~2s) than the warmup step before the workout countdown starts, and that a brief/quick hand raise (shorter than warmup's ~1s) does not fire it early.

- [ ] **Step 7: Manual Firefox verification — timer-mode unaffected**

Start a timer-only session (declining camera tracking at the "Track your workout?" prompt) and confirm every step (warmup Yes/Skip, Start workout) still requires and responds to a manual tap exactly as before this change.

- [ ] **Step 8: Confirm final workspace state**

Run: `jj st`
Expected: working copy has no uncommitted changes; all task commits are present in `jj log`.
