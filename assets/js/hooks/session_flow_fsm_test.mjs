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

function cameraRunningState() {
  return {
    ...initialFlowState(),
    mode: "workout_running",
    captureMode: "camera",
    trackingTrust: "observing",
  };
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
  assert.equal(started.state.mode, "starting_session");
  assert.equal(started.state.armedStep, null);

  const acknowledged = step(started.state, { type: "SESSION_BEGIN_ACKNOWLEDGED" });
  assert.equal(acknowledged.state.mode, "warmup_running");

  const stale = step(acknowledged.state, {
    type: "GESTURE_CONFIRM",
    step: "warmup",
  });
  assert.equal(stale.state.mode, "warmup_running");
  assert.deepEqual(stale.commands, []);
});

test("camera begin conflict restores the warmup gesture and timeout", () => {
  const warmupTimeline = [{ kind: "work", reps: 2, sec_per_rep: 5 }];
  let state = readyCameraState();
  state = step(state, {
    type: "GESTURE_CONFIRM",
    step: "camera_setup",
  }).state;

  const requested = step(state, {
    type: "GESTURE_CONFIRM",
    step: "warmup",
    warmupTimeline,
    burpeeCountTarget: 2,
  });
  const recovered = step(requested.state, { type: "SESSION_BEGIN_FAILED" });

  assert.equal(recovered.state.mode, "warmup_choice");
  assert.equal(recovered.state.armedStep, "warmup");
  assert.equal(recovered.state.pendingRuntime, null);
  assert.deepEqual(recovered.commands, [
    { type: "armGesture", step: "warmup" },
    { type: "startWarmupTimeout", step: "warmup" },
    { type: "renderFlow" },
  ]);

  const retried = step(recovered.state, {
    type: "GESTURE_CONFIRM",
    step: "warmup",
    warmupTimeline,
    burpeeCountTarget: 2,
  });
  assert.equal(retried.state.mode, "starting_session");
  assert.deepEqual(retried.state.pendingRuntime, requested.state.pendingRuntime);
});

test("camera begin conflict restores the workout-start gesture", () => {
  let state = readyCameraState();
  state = step(state, {
    type: "GESTURE_CONFIRM",
    step: "camera_setup",
  }).state;
  state = step(state, { type: "WARMUP_TIMEOUT", step: "warmup" }).state;

  const requested = step(state, {
    type: "GESTURE_CONFIRM",
    step: "workout_start",
  });
  const recovered = step(requested.state, { type: "SESSION_BEGIN_FAILED" });

  assert.equal(recovered.state.mode, "workout_ready");
  assert.equal(recovered.state.armedStep, "workout_start");
  assert.equal(recovered.state.pendingRuntime, null);
  assert.deepEqual(recovered.commands, [
    { type: "armGesture", step: "workout_start" },
    { type: "renderFlow" },
  ]);

  const retried = step(recovered.state, {
    type: "GESTURE_CONFIRM",
    step: "workout_start",
  });
  assert.equal(retried.state.mode, "starting_session");
  assert.deepEqual(retried.state.pendingRuntime, requested.state.pendingRuntime);
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

test("camera completion pre-fills detected count after absent frames", () => {
  const result = step(cameraRunningState(), {
    type: "SEGMENT_FINISHED",
    result: {
      burpeeCountDone: 99,
      detectedReps: 4,
      detectedDurationSec: 42,
      cadenceMs: [8_000, 18_000, 29_000, 42_000],
    },
  });

  assert.equal(result.state.completion.burpeeCountActual, 4);
  assert.equal(result.state.completion.durationSecActual, 42);
  assert.equal(result.state.completion.trackingTrust, "finished");
  assert.deepEqual(result.state.completion.cadenceMs, [
    8_000,
    18_000,
    29_000,
    42_000,
  ]);
});

test("session result waits for report-pending acknowledgement before completion review", () => {
  const state = {
    ...initialFlowState(),
    mode: "workout_running",
    captureMode: "no_camera",
  };
  const result = step(state, {
    type: "SESSION_DONE",
    result: { burpeeCountDone: 12, durationSec: 75 },
  });
  assert.equal(result.state.mode, "reporting_completion");
  assert.equal(result.state.completion.burpeeCountActual, 12);
  assert.deepEqual(result.commands, [
    { type: "persistCompletionAndRequestPending" },
    { type: "renderFlow" },
  ]);

  const acknowledged = step(result.state, { type: "REPORT_PENDING_ACKNOWLEDGED" });
  assert.equal(acknowledged.state.mode, "completion_review");
});

test("failed pending report retries without changing the completion draft", () => {
  const completion = {
    burpeeCountActual: 12,
    burpeeCountPlanned: 12,
    durationSecActual: 75,
    durationSecPlanned: 75,
  };
  const failed = step(
    { ...initialFlowState(), mode: "reporting_completion", completion },
    { type: "REPORT_PENDING_FAILED" },
  );

  assert.equal(failed.state.mode, "completion_pending_failed");
  assert.equal(failed.state.completion, completion);

  const retried = step(failed.state, { type: "RETRY_REPORT_PENDING" });
  assert.equal(retried.state.mode, "reporting_completion");
  assert.equal(retried.state.completion, completion);
  assert.deepEqual(retried.commands, [
    { type: "requestPending" },
    { type: "renderFlow" },
  ]);
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
  const completedReview = step(completed, {
    type: "REPORT_PENDING_ACKNOWLEDGED",
  }).state;

  const result = step(completedReview, {
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
