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
