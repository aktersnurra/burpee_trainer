export function initialFlowState() {
  return {
    mode: "booting",
    captureMode: "no_camera",
    camera: { status: "idle", readiness: "not_ready", reason: null },
    trackingTrust: "disabled",
    armedStep: null,
    workoutTimeline: [],
    warmupResult: { burpeeCountDone: 0, durationSec: 0 },
    workoutResult: null,
    completion: null,
    saveStatus: "idle",
    pendingRuntime: null,
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
      if (Number.isFinite(segment.duration_sec)) {
        return total + segment.duration_sec;
      }
      return total + (segment.reps || 0) * (segment.sec_per_rep || 0);
    }
    if (segment.kind === "rest") return total + (segment.duration_sec || 0);
    return total;
  }, 0);
}

function completionFor(state, result) {
  const trackingFinished =
    state.captureMode === "camera" && state.trackingTrust === "finished";
  const scheduledRepsDone =
    result.scheduledRepsDone ?? result.burpeeCountDone ?? 0;

  return {
    scheduledRepsDone,
    burpeeCountActual: trackingFinished ? (result.detectedReps ?? 0) : null,
    burpeeCountProvenance: trackingFinished
      ? "camera_confirmed"
      : "unresolved",
    burpeeCountPlanned: plannedBurpees(state.workoutTimeline),
    durationSecActual: trackingFinished
      ? (result.detectedDurationSec ?? 0)
      : result.durationSec || 0,
    durationSecPlanned: plannedDurationSec(state.workoutTimeline),
    detectedReps: result.detectedReps ?? null,
    detectedDurationSec: result.detectedDurationSec ?? null,
    trackingTrust: state.trackingTrust,
    cadenceMs: result.cadenceMs || [],
    mood: 0,
    tags: [],
    notePost: "",
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

function requestRuntime(state, pendingRuntime, commands = []) {
  const restartWarmupTimeout =
    state.captureMode === "camera" &&
    state.mode === "warmup_choice" &&
    state.armedStep === "warmup";
  const pending = {
    ...pendingRuntime,
    restoreArmedStep:
      state.captureMode === "camera" ? state.armedStep : null,
    restartWarmupTimeout,
  };

  return moved(
    state,
    { mode: "starting_session", armedStep: null, pendingRuntime: pending },
    [...commands, { type: "persistBeginAndRequest", pendingRuntime: pending }, { type: "renderFlow" }],
  );
}

function startWarmup(state, event, commands = []) {
  return requestRuntime(
    state,
    {
      mode: "warmup_running",
      readyMode: "warmup_choice",
      segment: "warmup",
      timeline: event.warmupTimeline || [],
      burpeeCountTarget: event.burpeeCountTarget,
    },
    commands,
  );
}

function startWorkout(state, commands = []) {
  return requestRuntime(
    state,
    {
      mode: "workout_running",
      readyMode: "workout_ready",
      segment: "workout",
      timeline: state.workoutTimeline,
    },
    commands,
  );
}

function beginAcknowledged(state) {
  const pendingRuntime = state.pendingRuntime;
  if (!pendingRuntime) return unchanged(state);
  const nextState = {
    ...state,
    mode: pendingRuntime.mode,
    pendingRuntime: null,
    trackingTrust:
      pendingRuntime.mode === "workout_running" &&
      state.captureMode === "camera"
        ? "observing"
        : state.trackingTrust,
  };
  return moved(nextState, {}, [
    {
      type: "startSegment",
      segment: pendingRuntime.segment,
      timeline: pendingRuntime.timeline,
      burpeeCountTarget: pendingRuntime.burpeeCountTarget,
    },
  ]);
}

function finishWorkout(state, result) {
  const workoutResult = result || { burpeeCountDone: 0, durationSec: 0 };
  return moved(
    state,
    {
      mode: "reporting_completion",
      workoutResult,
      completion: completionFor(state, workoutResult),
      saveStatus: "idle",
    },
    [{ type: "persistCompletionAndRequestPending" }, { type: "renderFlow" }],
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
        trackingTrust: "disabled",
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

    case "SESSION_BEGIN_ACKNOWLEDGED":
      if (state.mode !== "starting_session") return unchanged(state);
      return beginAcknowledged(state);

    case "SESSION_BEGIN_FAILED": {
      if (state.mode !== "starting_session" || !state.pendingRuntime) {
        return unchanged(state);
      }

      const pendingRuntime = state.pendingRuntime;
      const commands = [];
      if (pendingRuntime.restoreArmedStep) {
        commands.push({
          type: "armGesture",
          step: pendingRuntime.restoreArmedStep,
        });
      }
      if (pendingRuntime.restartWarmupTimeout) {
        commands.push({ type: "startWarmupTimeout", step: "warmup" });
      }

      return moved(
        state,
        {
          mode: pendingRuntime.readyMode,
          armedStep: pendingRuntime.restoreArmedStep,
          pendingRuntime: null,
        },
        [...commands, { type: "renderFlow" }],
      );
    }

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

    case "TRACKING_FINISHED":
      if (
        state.mode !== "workout_running" ||
        state.captureMode !== "camera"
      ) {
        return unchanged(state);
      }
      return moved(state, { trackingTrust: "finished" });

    case "SEGMENT_FINISHED":
      if (state.mode !== "workout_running" || state.captureMode !== "camera") {
        return unchanged(state);
      }
      return finishWorkout({ ...state, trackingTrust: "finished" }, event.result);

    case "SESSION_DONE":
      if (state.mode !== "workout_running") return unchanged(state);
      return finishWorkout(state, event.result);

    case "FINISH_EARLY":
      if (state.mode !== "workout_running") return unchanged(state);
      return finishWorkout(state, event.result);

    case "RESTORE_COMPLETION_DRAFT":
      if (state.mode !== "capture_choice" || !event.completion) {
        return unchanged(state);
      }
      return moved(
        state,
        {
          mode: event.pendingAcknowledgement
            ? "reporting_completion"
            : "completion_review",
          captureMode: event.captureMode || "no_camera",
          trackingTrust: event.completion.trackingTrust || "disabled",
          workoutResult: {
            burpeeCountDone: event.completion.burpeeCountActual || 0,
            durationSec: event.completion.durationSecActual || 0,
          },
          completion: event.completion,
          saveStatus: "idle",
        },
        event.pendingAcknowledgement
          ? [{ type: "requestPending" }, { type: "renderFlow" }]
          : [{ type: "showCompletion", restored: true }],
      );

    case "REPORT_PENDING_ACKNOWLEDGED":
      if (state.mode !== "reporting_completion") return unchanged(state);
      return moved(state, { mode: "completion_review" }, [{ type: "showCompletion" }]);

    case "REPORT_PENDING_FAILED":
      if (state.mode !== "reporting_completion") return unchanged(state);
      return moved(state, { mode: "completion_pending_failed" });

    case "RETRY_REPORT_PENDING":
      if (state.mode !== "completion_pending_failed") return unchanged(state);
      return moved(state, { mode: "reporting_completion" }, [
        { type: "requestPending" },
        { type: "renderFlow" },
      ]);

    case "COMPLETION_EDITED": {
      if (state.mode !== "completion_review") return unchanged(state);
      const changes = event.changes || {};
      const completion = { ...state.completion };

      for (const field of [
        "burpeeCountActual",
        "durationSecActual",
        "mood",
        "notePost",
      ]) {
        if (Object.hasOwn(changes, field)) completion[field] = changes[field];
      }
      if (Object.hasOwn(changes, "burpeeCountActual")) {
        completion.burpeeCountProvenance = "manual";
      }
      if (Object.hasOwn(changes, "tags")) {
        completion.tags = [...changes.tags];
      }

      return moved(state, { completion, saveStatus: "idle" });
    }

    case "DISCARD_LOCAL":
      if (state.mode !== "completion_review") return unchanged(state);
      return moved(
        state,
        { mode: "discarded", completion: null, workoutResult: null },
        [],
      );

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
