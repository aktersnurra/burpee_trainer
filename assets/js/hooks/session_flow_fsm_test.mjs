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

  const stillLost = step(lost.state, {
    type: "CAMERA_READINESS",
    readiness: "not_ready",
  });
  assert.deepEqual(stillLost.commands, [{ type: "renderFlow" }]);

  const stale = step(stillLost.state, {
    type: "WARMUP_TIMEOUT",
    step: "warmup",
  });
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

test("degraded camera completion keeps timer actuals and sanitizes detection analytics", () => {
  let state = {
    ...initialFlowState(),
    mode: "workout_running",
    captureMode: "camera",
    trackingTrust: "observing",
  };
  state = step(state, {
    type: "TRACKING_DEGRADED",
    reason: "detector_error",
  }).state;

  const result = step(state, {
    type: "SESSION_DONE",
    result: {
      burpeeCountDone: 14,
      durationSec: 91,
      detectedReps: 13,
      detectedDurationSec: 84,
      cadenceMs: [6000, 6200],
    },
  });

  assert.equal(result.state.completion.burpeeCountActual, 14);
  assert.equal(result.state.completion.durationSecActual, 91);
  assert.equal(result.state.completion.detectedReps, null);
  assert.equal(result.state.completion.detectedDurationSec, null);
  assert.deepEqual(result.state.completion.cadenceMs, []);
});

test("restored completion draft enters review without replaying workout", () => {
  const restored = step(
    step(initialFlowState(), {
      type: "SESSION_READY",
      workoutTimeline: [{ kind: "work", reps: 10, sec_per_rep: 5 }],
    }).state,
    {
      type: "RESTORE_COMPLETION_DRAFT",
      captureMode: "camera",
      trackingReason: "restored",
      completion: {
        burpeeCountActual: 9,
        burpeeCountPlanned: 10,
        durationSecActual: 52,
        durationSecPlanned: 50,
        detectedReps: 9,
        detectedDurationSec: 52,
        trackingTrust: "finished",
        cadenceMs: [5_000, 10_000],
        mood: 1,
        tags: ["great_energy"],
        notePost: "Strong finish",
      },
    },
  );

  assert.equal(restored.state.mode, "completion_review");
  assert.equal(restored.state.captureMode, "camera");
  assert.equal(restored.state.trackingTrust, "finished");
  assert.equal(restored.state.completion.notePost, "Strong finish");
  assert.deepEqual(restored.commands, [{ type: "showCompletion", restored: true }]);
});

test("completion edits only change approved draft fields", () => {
  const completed = step(
    {
      ...initialFlowState(),
      mode: "workout_running",
      captureMode: "camera",
      trackingTrust: "observing",
      workoutTimeline: [{ kind: "work", reps: 10, sec_per_rep: 5 }],
    },
    {
      type: "SESSION_DONE",
      result: {
        burpeeCountDone: 9,
        durationSec: 52,
        detectedReps: 8,
        detectedDurationSec: 49,
        cadenceMs: [6100, 6200],
      },
    },
  ).state;

  const result = step(completed, {
    type: "COMPLETION_EDITED",
    changes: {
      burpeeCountActual: 10,
      durationSecActual: 55,
      burpeeCountPlanned: 999,
      durationSecPlanned: 999,
      trackingTrust: "degraded",
      detectedReps: 999,
      detectedDurationSec: 999,
      cadenceMs: [1],
      mood: 1,
      tags: ["great_energy"],
      notePost: "Strong finish",
    },
  });

  assert.deepEqual(result.state.completion, {
    burpeeCountActual: 10,
    burpeeCountPlanned: 10,
    durationSecActual: 55,
    durationSecPlanned: 50,
    detectedReps: 8,
    detectedDurationSec: 49,
    trackingTrust: "observing",
    cadenceMs: [6100, 6200],
    mood: 1,
    tags: ["great_energy"],
    notePost: "Strong finish",
  });
});
