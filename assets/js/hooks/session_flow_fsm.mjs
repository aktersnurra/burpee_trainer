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
  return (
    state.camera.readiness === "ready" || state.camera.readiness === "optimal"
  );
}

function matchingArm(state, event, step) {
  return state.armedStep === step && event.step === step;
}

function plannedBurpees(timeline) {
  return timeline.reduce(
    (total, segment) =>
      total + (segment.kind === "work" ? segment.reps || 0 : 0),
    0,
  );
}

function plannedDurationSec(timeline) {
  return timeline.reduce((total, segment) => {
    if (segment.kind === "work") {
      return total + (segment.reps || 0) * (segment.sec_per_rep || 0);
    }
    if (segment.kind === "rest") return total + (segment.duration_sec || 0);
    return total;
  }, 0);
}

function completionFor(state, result) {
  const trackingDegraded = state.trackingTrust === "degraded";

  return {
    burpeeCountActual: result.burpeeCountDone || 0,
    burpeeCountPlanned: plannedBurpees(state.workoutTimeline),
    durationSecActual: result.durationSec || 0,
    durationSecPlanned: plannedDurationSec(state.workoutTimeline),
    detectedReps: trackingDegraded ? null : (result.detectedReps ?? null),
    detectedDurationSec: trackingDegraded
      ? null
      : (result.detectedDurationSec ?? null),
    trackingTrust: state.trackingTrust,
    cadenceMs: trackingDegraded ? [] : result.cadenceMs || [],
  };
}

function enterWarmupChoice(state, commands = []) {
  if (state.captureMode === "camera") {
    return moved(state, { mode: "warmup_choice", armedStep: "warmup" }, [
      ...commands,
      { type: "armGesture", step: "warmup" },
      { type: "startWarmupTimeout", step: "warmup" },
      { type: "renderFlow" },
    ]);
  }

  return moved(state, { mode: "warmup_choice", armedStep: null }, [
    ...commands,
    { type: "renderFlow" },
  ]);
}

function enterWorkoutReady(state, commands = []) {
  if (state.captureMode === "camera") {
    return moved(state, { mode: "workout_ready", armedStep: "workout_start" }, [
      ...commands,
      { type: "armGesture", step: "workout_start" },
      { type: "renderFlow" },
    ]);
  }

  return moved(state, { mode: "workout_ready", armedStep: null }, [
    ...commands,
    { type: "renderFlow" },
  ]);
}

function startWarmup(state, event, commands = []) {
  return moved(state, { mode: "warmup_running", armedStep: null }, [
    ...commands,
    {
      type: "startSegment",
      segment: "warmup",
      timeline: event.warmupTimeline || [],
      burpeeCountTarget: event.burpeeCountTarget,
    },
  ]);
}

function startWorkout(state, commands = []) {
  return moved(
    state,
    {
      mode: "workout_running",
      armedStep: null,
      trackingTrust:
        state.captureMode === "camera" && state.trackingTrust !== "degraded"
          ? "observing"
          : state.trackingTrust,
    },
    [
      ...commands,
      {
        type: "startSegment",
        segment: "workout",
        timeline: state.workoutTimeline,
      },
    ],
  );
}

function finishWorkout(state, result) {
  const workoutResult = result || { burpeeCountDone: 0, durationSec: 0 };
  return moved(
    state,
    {
      mode: "completion_review",
      workoutResult,
      completion: completionFor(state, workoutResult),
      saveStatus: "idle",
    },
    [{ type: "showCompletion" }],
  );
}

export function flowTransition(state, event) {
  switch (event.type) {
    case "SESSION_READY":
      if (state.mode !== "booting") return unchanged(state);
      return moved(state, {
        mode: "capture_choice",
        workoutTimeline: event.workoutTimeline || [],
      });

    case "CHOOSE_CAMERA":
      if (state.mode !== "capture_choice") return unchanged(state);
      return moved(
        state,
        {
          mode: "camera_starting",
          captureMode: "camera",
          camera: {
            status: "starting",
            readiness: "not_ready",
            reason: null,
          },
          trackingTrust: "arming",
          trackingReason: null,
        },
        [{ type: "startCamera" }, { type: "renderFlow" }],
      );

    case "RETRY_CAMERA":
      if (state.mode !== "camera_error") return unchanged(state);
      return moved(
        state,
        {
          mode: "camera_starting",
          camera: {
            status: "starting",
            readiness: "not_ready",
            reason: null,
          },
          trackingTrust: "arming",
          trackingReason: null,
        },
        [
          { type: "stopCamera" },
          { type: "startCamera" },
          { type: "renderFlow" },
        ],
      );

    case "CAMERA_STARTED":
      if (state.mode !== "camera_starting") return unchanged(state);
      return moved(
        state,
        {
          mode: "camera_setup",
          camera: {
            status: "arming",
            readiness: "not_ready",
            reason: null,
          },
          armedStep: "camera_setup",
        },
        [{ type: "armGesture", step: "camera_setup" }, { type: "renderFlow" }],
      );

    case "CAMERA_START_FAILED":
      if (state.mode !== "camera_starting") return unchanged(state);
      return moved(state, {
        mode: "camera_error",
        camera: {
          status: "failed",
          readiness: "not_ready",
          reason: event.reason || null,
        },
        trackingTrust: "degraded",
        trackingReason: event.reason || null,
      });

    case "CHOOSE_NO_CAMERA":
      if (state.mode !== "capture_choice") return unchanged(state);
      return enterWarmupChoice(
        {
          ...state,
          captureMode: "no_camera",
          camera: {
            status: "idle",
            readiness: "not_ready",
            reason: null,
          },
          trackingTrust: "disabled",
          trackingReason: null,
        },
        [{ type: "stopCamera" }],
      );

    case "CONTINUE_WITHOUT_CAMERA": {
      if (
        ![
          "camera_starting",
          "camera_error",
          "camera_setup",
          "warmup_choice",
          "workout_ready",
        ].includes(state.mode) ||
        state.captureMode !== "camera"
      ) {
        return unchanged(state);
      }

      const commands = [];
      if (state.armedStep) commands.push({ type: "disarmGesture" });
      if (state.mode === "warmup_choice") {
        commands.push({ type: "cancelWarmupTimeout" });
      }
      commands.push({ type: "stopCamera" });

      const nextState = {
        ...state,
        captureMode: "no_camera",
        camera: {
          status: "idle",
          readiness: "not_ready",
          reason: null,
        },
        trackingTrust: "disabled",
        trackingReason: null,
        armedStep: null,
      };

      if (state.mode === "workout_ready") {
        return moved(nextState, {}, [...commands, { type: "renderFlow" }]);
      }
      return enterWarmupChoice(nextState, commands);
    }

    case "CAMERA_READINESS": {
      if (state.captureMode !== "camera") return unchanged(state);
      if (
        !["camera_setup", "warmup_choice", "workout_ready"].includes(state.mode)
      ) {
        return unchanged(state);
      }

      const wasReady = cameraReady(state);
      const nextState = {
        ...state,
        camera: {
          ...state.camera,
          status:
            event.readiness === "ready" || event.readiness === "optimal"
              ? "ready"
              : "arming",
          readiness: event.readiness,
        },
      };
      const isReady = cameraReady(nextState);

      if (state.mode === "warmup_choice") {
        if (wasReady && !isReady) {
          return moved(nextState, {}, [
            { type: "pauseWarmupTimeout" },
            { type: "renderFlow" },
          ]);
        }
        if (!wasReady && isReady) {
          return moved(nextState, {}, [
            { type: "resumeWarmupTimeout" },
            { type: "renderFlow" },
          ]);
        }
      }

      return moved(nextState, {});
    }

    case "GESTURE_CONFIRM":
      if (state.mode === "camera_setup") {
        if (!matchingArm(state, event, "camera_setup") || !cameraReady(state)) {
          return unchanged(state);
        }
        return enterWarmupChoice({ ...state, armedStep: null }, [
          { type: "disarmGesture" },
        ]);
      }

      if (state.mode === "warmup_choice") {
        if (!matchingArm(state, event, "warmup") || !cameraReady(state)) {
          return unchanged(state);
        }
        return startWarmup(state, event, [
          { type: "disarmGesture" },
          { type: "cancelWarmupTimeout" },
        ]);
      }

      if (state.mode === "workout_ready") {
        if (
          !matchingArm(state, event, "workout_start") ||
          !cameraReady(state)
        ) {
          return unchanged(state);
        }
        return startWorkout(state, [{ type: "disarmGesture" }]);
      }

      return unchanged(state);

    case "WARMUP_TIMEOUT_TICK":
      if (
        state.mode !== "warmup_choice" ||
        !matchingArm(state, event, "warmup") ||
        !cameraReady(state)
      ) {
        return unchanged(state);
      }
      return moved(state, {});

    case "WARMUP_TIMEOUT":
      if (
        state.mode !== "warmup_choice" ||
        !matchingArm(state, event, "warmup") ||
        !cameraReady(state)
      ) {
        return unchanged(state);
      }
      return enterWorkoutReady({ ...state, armedStep: null }, [
        { type: "disarmGesture" },
        { type: "cancelWarmupTimeout" },
      ]);

    case "WARMUP_READY":
      if (state.mode !== "warmup_choice" || state.captureMode !== "no_camera") {
        return unchanged(state);
      }
      return startWarmup(state, event);

    case "WARMUP_SKIP":
      if (state.mode !== "warmup_choice" || state.captureMode !== "no_camera") {
        return unchanged(state);
      }
      return enterWorkoutReady(state);

    case "SEGMENT_DONE":
      if (event.segment === "warmup" && state.mode === "warmup_running") {
        return enterWorkoutReady({
          ...state,
          warmupResult: event.result || state.warmupResult,
        });
      }
      if (event.segment === "workout" && state.mode === "workout_running") {
        return finishWorkout(state, event.result);
      }
      return unchanged(state);

    case "WORKOUT_READY":
      if (state.mode !== "workout_ready" || state.captureMode !== "no_camera") {
        return unchanged(state);
      }
      return startWorkout(state);

    case "TRACKING_DEGRADED":
      if (state.captureMode !== "camera") return unchanged(state);
      return moved(state, {
        trackingTrust: "degraded",
        trackingReason: event.reason || null,
      });

    case "SESSION_DONE":
      if (state.mode !== "workout_running") return unchanged(state);
      return finishWorkout(state, event.result);

    case "FINISH_EARLY":
      if (state.mode !== "workout_running") return unchanged(state);
      return finishWorkout(state, event.result);

    case "COMPLETION_EDITED": {
      if (state.mode !== "completion_review") return unchanged(state);
      const changes = event.changes || {};
      const completion = { ...state.completion };

      if (Object.hasOwn(changes, "burpeeCountActual")) {
        completion.burpeeCountActual = changes.burpeeCountActual;
      }
      if (Object.hasOwn(changes, "durationSecActual")) {
        completion.durationSecActual = changes.durationSecActual;
      }

      return moved(state, { completion, saveStatus: "idle" });
    }

    case "SAVE_STARTED":
      if (state.mode !== "completion_review") return unchanged(state);
      return moved(state, { saveStatus: "saving" });

    case "SAVE_FAILED":
      if (state.mode !== "completion_review") return unchanged(state);
      return moved(state, { saveStatus: "failed" });

    case "SAVE_SUCCEEDED":
      if (state.mode !== "completion_review") return unchanged(state);
      return moved(state, { mode: "persisted", saveStatus: "saved" });

    default:
      return unchanged(state);
  }
}
