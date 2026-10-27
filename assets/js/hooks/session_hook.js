import { SessionAudio } from "./session_audio.mjs";
import {
  cameraRepsBySet,
  currentFrame,
  initialSegmentState,
  segmentTransition,
} from "./session_segment_fsm.mjs";
import {
  countOrigin,
  flowTransition,
  initialFlowState,
} from "./session_flow_fsm.mjs";
import {
  programBurpeeCount,
  warmupTimelineFromProgram,
  workoutTimelineFromProgram,
} from "./session_plan.mjs";
import { SessionRenderer } from "./session_renderer.mjs";
import { isPauseToggleKey } from "./session_input.mjs";
import {
  countdownDisplayModel,
  runningDisplayModel,
  sessionProgressForElapsed,
} from "./session_display_model.mjs";
import { SessionWakeLock } from "./session_wake_lock.mjs";
import { openSessionStore } from "./session_store.mjs";
import { cameraAvailable } from "./camera_available.mjs";
import { readStartChoices } from "./start_choices.mjs";
import {
  finishTrackingObserver,
  initialTrackingObserver,
  observeTrackingRep,
  startTrackingObserver,
  updateTrackingReadiness,
  updateTrackingStatus,
} from "./pose_tracking_observer.mjs";

// How long after a set or the workout ends a rep the camera sees still counts for it: the
// camera sees a rep as you stand up, which can be a moment after the bell.
const LATE_REP_GRACE_MS = 2_000;

// Holding − or + on the finish screen: the wait before it repeats, and the fastest pace.
const REP_HOLD_DELAY_MS = 400;
const REP_HOLD_FASTEST_MS = 50;

// How long discard waits for the server before it gives up and says so.
const DISCARD_TIMEOUT_MS = 10_000;

// Where a draft's count came from. Drafts from before this was stored are the camera's
// when they still hold its count unchanged; otherwise they can't say.
function restoredProvenance(draft) {
  if (draft.burpee_count_provenance) {
    return { burpeeCountProvenance: draft.burpee_count_provenance };
  }
  const tracking = draft.tracking || {};
  if (
    tracking.trust === "finished" &&
    Number.isInteger(tracking.detected_reps) &&
    tracking.detected_reps === draft.burpee_count_actual
  ) {
    return { burpeeCountProvenance: "camera_confirmed" };
  }
  return {};
}

// −1 or +1 for the finish screen's rep buttons, else null.
function repStepFor(target) {
  if (target?.closest?.("#completion-reps-less")) return -1;
  if (target?.closest?.("#completion-reps-more")) return 1;
  return null;
}

// The first moments of a rest that follows work, when a set's last rep can still land.
function justAfterWork(timeline, frame) {
  return (
    frame?.event?.kind === "rest" &&
    (frame.phase_elapsed || 0) * 1_000 <= LATE_REP_GRACE_MS &&
    timeline?.[frame.index - 1]?.kind === "work"
  );
}

const SessionHook = {
  mounted() {
    this.lifecycleGeneration = (this.lifecycleGeneration || 0) + 1;
    this.lifecycleDestroyed = false;
    this.audio = new SessionAudio();
    this.renderer = new SessionRenderer(this.el);
    this.wakeLock = new SessionWakeLock();

    this.flow = initialFlowState();
    this.segment = initialSegmentState();
    this.activeSegment = null;
    this.program = null;
    this.timeline = [];
    this.startTime = null;
    this.paused = false;
    this.rafId = null;
    this.countdownPaused = false;
    this.countdownCount = null;
    this.countdownTimeoutId = null;
    this.countdownRafId = null;
    this.countdownStartedAt = null;
    this.countdownElapsedMs = 0;
    this.renderCountdownFrame = null;
    this.countdownStepStarted = null;
    this.countdownStepElapsed = 0;

    this.doneReps = 0;
    this.lastDownCueKey = null;
    this.hiddenAt = null;
    this.tracking = initialTrackingObserver();
    this.cameraSetReps = [];
    this.trackerReadiness = "not_ready";
    this.trackingCompletion = null;
    this.armedPoseStep = null;
    this.armedPoseHoldFramesRequired = 0;
    this.trackerFinished = null;
    this.traceRetentionAvailable = true;
    this.store = null;
    this.storeReady = null;
    this.traceWrite = Promise.resolve(true);
    this.draftWrite = Promise.resolve(true);
    this.draftRestore = Promise.resolve();
    this.pendingTraceChunks = new Map();
    this.traceCaptureId = crypto.randomUUID();
    this.completionDraftPending = false;
    this.inMemoryCompletionDraft = null;
    this.serverCompletion = null;
    this.pendingServerCompletionFacts = null;
    this.storageFailureMessage = null;
    this.saveCleanup = Promise.resolve();
    this.onPoseTrackerInitialized = () => this.reissuePendingArm();
    this.onPoseTrackerStarted = () =>
      this.dispatchFlow({ type: "CAMERA_STARTED" });
    this.onPoseTrackerStartFailed = (event) =>
      this.dispatchFlow({
        type: "CAMERA_START_FAILED",
        reason: event.detail?.reason,
        stage: event.detail?.stage,
      });
    this.onPoseTrackerRep = (event) => this.observePoseRep(event.detail || {});
    this.onPoseTrackerStatus = (event) =>
      this.updatePoseStatus(event.detail || {});
    this.onPoseTrackerReadiness = (event) => {
      this.trackerReadiness = event.detail?.state || "not_ready";
      this.tracking = updateTrackingReadiness(
        this.tracking,
        this.trackerReadiness,
      );
      this.dispatchFlow({
        type: "CAMERA_READINESS",
        readiness: this.trackerReadiness,
      });
    };
    this.onPoseTrackerFinished = (event) => {
      this.trackerFinished = event.detail || null;
    };
    this.onPoseTrackerTraceChunk = (event) => {
      const chunk = event.detail?.chunk;
      if (chunk) this.queueTraceChunk(chunk);
    };
    this.el.addEventListener("pose-tracker:started", this.onPoseTrackerStarted);
    this.el.addEventListener(
      "pose-tracker:start-failed",
      this.onPoseTrackerStartFailed,
    );
    this.el.addEventListener("pose-tracker:rep", this.onPoseTrackerRep);
    this.el.addEventListener("pose-tracker:status", this.onPoseTrackerStatus);
    this.el.addEventListener(
      "pose-tracker:readiness",
      this.onPoseTrackerReadiness,
    );
    this.onPoseTrackerGestureConfirm = (event) =>
      this.handlePoseGestureConfirm(event.detail || {});
    this.el.addEventListener(
      "pose-tracker:gesture-confirm",
      this.onPoseTrackerGestureConfirm,
    );
    this.el.addEventListener(
      "pose-tracker:initialized",
      this.onPoseTrackerInitialized,
    );
    this.el.addEventListener(
      "pose-tracker:finished",
      this.onPoseTrackerFinished,
    );
    this.el.addEventListener(
      "pose-tracker:trace-chunk",
      this.onPoseTrackerTraceChunk,
    );

    this.onVisibility = () => {
      if (document.visibilityState === "hidden") {
        if (!this.paused && this.startTime !== null) {
          this.dispatchSegment({
            type: "VISIBILITY_HIDDEN",
            now: performance.now(),
          });
          this.hiddenAt = this.segment.clock.hiddenAt;
          if (this.rafId) cancelAnimationFrame(this.rafId);
          this.rafId = null;
          this.audio.stop();
        }
      } else {
        if (!this.activeRuntimeForFlow()) {
          this.hiddenAt = null;
          return;
        }
        if (!this.paused && this.hiddenAt !== null && this.startTime !== null) {
          this.dispatchSegment({
            type: "VISIBILITY_VISIBLE",
            now: performance.now(),
          });
          this.startTime = this.segment.clock.startTime;
          this.resetPoseTracker();
        }
        this.hiddenAt = null;
        this.wakeLock.reacquireWhenVisible();
        if (!this.paused && this.startTime !== null && !this.rafId) {
          this.rafId = requestAnimationFrame(() => this.tick());
        }
      }
    };
    document.addEventListener("visibilitychange", this.onVisibility);

    this.primeAudio = () => this.audio.ensureRunning();
    document.addEventListener("click", this.primeAudio, { capture: true });
    document.addEventListener("touchstart", this.primeAudio, {
      capture: true,
      passive: true,
    });

    try {
      this.program = JSON.parse(this.el.dataset.sessionProgram || "{}");
    } catch {
      this.program = {};
    }
    this.sessionId = Number(this.el.dataset.sessionId);
    this.contentHash = this.el.dataset.contentHash;
    this.sourceKind = this.el.dataset.sourceKind;
    this.clientSessionId = this.el.dataset.clientSessionId;
    this.initializeSessionStore();
    this.renderer.resetReady();
    this.dispatchFlow({
      type: "SESSION_READY",
      workoutTimeline: workoutTimelineFromProgram(this.program),
      choices: readStartChoices(this.startChoiceStorage),
    });
    // A session that was finishing reopens on its finish screen; anything else starts.
    const bootGeneration = this.lifecycleGeneration;
    const cameraCheck =
      this.flow.captureMode === "camera"
        ? cameraAvailable(this.mediaDevices)
        : Promise.resolve(null);
    this.started = Promise.all([cameraCheck, this.draftRestore]).then(
      ([available]) => {
        if (this.lifecycleActive(bootGeneration)) {
          this.dispatchFlow({
            type: "START",
            cameraAvailable: available,
            ...this.warmupStart(),
          });
        }
      },
    );

    this.onRootClick = (e) => {
      const retryCamera = e.target.closest("#camera-setup-retry");
      const repStep = repStepFor(e.target);
      const repsUndo = e.target.closest("#completion-reps-undo");
      const discardAsk = e.target.closest("#session-discard-btn");
      const discardKeep = e.target.closest("#session-discard-keep");
      const discardYes = e.target.closest("#session-discard-yes");
      const abortAsk = e.target.closest("#session-abort-btn");
      const abortKeep = e.target.closest("#session-abort-keep");
      const abortYes = e.target.closest("#session-abort-yes");
      const continueWithoutCamera = e.target.closest("#camera-setup-continue");
      const ringContainer = e.target.closest("#ring-container");
      const finishEarly = e.target.closest("#finish-early-btn");
      const mood = e.target.dataset?.mood;
      const tag = e.target.dataset?.tag;

      if (retryCamera) this.dispatchFlow({ type: "RETRY_CAMERA" });
      if (continueWithoutCamera) {
        this.dispatchFlow({
          type: "CONTINUE_WITHOUT_CAMERA",
          ...this.warmupStart(),
        });
      }
      if (ringContainer && this.canTogglePause()) this.togglePause();
      if (finishEarly) this.onFinishEarly();
      if (tag !== undefined && this.flow.completion) {
        const tags = this.flow.completion.tags || [];
        this.editCompletion({
          tags: tags.includes(tag)
            ? tags.filter((chosen) => chosen !== tag)
            : [...tags, tag],
        });
      }
      // Mood is optional: tapping the chosen one again clears it.
      if (mood !== undefined) {
        const chosen = Number(mood);
        this.editCompletion({
          mood: this.flow.completion?.mood === chosen ? null : chosen,
        });
      }
      if (repStep) {
        // The click that ends a hold is not one more rep.
        const held = this.repHoldEnded;
        this.repHoldEnded = false;
        this.stopRepHold();
        if (!held) {
          this.stepReps(repStep);
          this.announceReps();
        }
      }
      if (repsUndo) {
        const origin = countOrigin(this.flow.completion);
        if (origin.reps !== null) {
          this.editCompletion({ burpeeCountActual: origin.reps });
          this.announceReps();
        }
      }
      if (discardAsk && this.canDiscard()) this.renderer.showDiscardConfirm(true);
      if (discardKeep) this.renderer.showDiscardConfirm(false);
      if (discardYes) this.discardSession();
      if (abortAsk && this.canDiscard()) this.renderer.showAbortConfirm(true);
      if (abortKeep) this.renderer.showAbortConfirm(false);
      if (abortYes) this.discardSession();
    };
    this.el.addEventListener("click", this.onRootClick);

    // Holding − or + keeps counting, faster the longer it is held.
    this.onRepHoldStart = (e) => {
      const step = repStepFor(e.target);
      if (step && (e.button ?? 0) === 0) {
        this.startRepHold(step, e.target.closest(step < 0 ? "#completion-reps-less" : "#completion-reps-more"));
      }
    };
    this.onRepHoldEnd = () => {
      if (!this.endRepHold()) return;
      // The release's own click follows in the same moment; it must not add a rep.
      this.repHoldEnded = true;
      setTimeout(() => {
        this.repHoldEnded = false;
      }, 0);
    };
    this.onRepHoldOut = (e) => {
      const button = this.repHold?.button;
      if (!button || e.relatedTarget?.closest?.(`#${button.id}`) === button) return;
      this.endRepHold();
    };
    this.el.addEventListener("pointerdown", this.onRepHoldStart);
    this.el.addEventListener("pointerup", this.onRepHoldEnd);
    this.el.addEventListener("pointercancel", this.onRepHoldEnd);
    this.el.addEventListener("pointerout", this.onRepHoldOut);

    this.onCompletionInput = (event) => {
      const { id, value } = event.target;
      if (id === "completion-context-low-energy") {
        this.editCompletion({ contextLowEnergy: event.target.checked });
      }
      if (id === "completion-context-high-energy") {
        this.editCompletion({ contextHighEnergy: event.target.checked });
      }
      if (id === "completion-context-heat-affected") {
        this.editCompletion({ contextHeatAffected: event.target.checked });
      }
      if (id === "completion-primary-limiter") {
        this.editCompletion({ primaryLimiter: value || null });
      }
      if (id === "completion-preference-feedback") {
        this.editCompletion({ preferenceFeedback: value || null });
      }
      if (id === "completion-note-input") {
        this.editCompletion({ notePost: value });
      }
    };
    this.el.addEventListener("input", this.onCompletionInput);
    this.onCompletionSubmit = (event) => {
      if (!event.target.closest("#session-completion-form")) return;
      event.preventDefault();
      this.saveCompletion();
    };
    this.el.addEventListener("submit", this.onCompletionSubmit);

    this.onRootKeydown = (e) => {
      const ringContainer = e.target.closest("#ring-container");
      if (!ringContainer || !isPauseToggleKey(e) || !this.canTogglePause())
        return;

      e.preventDefault();
      if (!e.repeat) this.togglePause();
    };
    this.el.addEventListener("keydown", this.onRootKeydown);
  },

  lifecycleActive(generation) {
    return !this.lifecycleDestroyed && generation === this.lifecycleGeneration;
  },

  initializeSessionStore() {
    const generation = this.lifecycleGeneration;
    const openStore = this.openSessionStore || openSessionStore;
    let opened;
    try {
      opened = openStore();
    } catch (error) {
      opened = Promise.reject(error);
    }

    this.storeReady = Promise.resolve(opened)
      .then((store) => {
        if (this.lifecycleActive(generation)) {
          this.store = store;
          this.storageFailureMessage = null;
        }
        return store;
      })
      .catch((error) => {
        if (this.lifecycleActive(generation)) {
          this.traceRetentionAvailable = false;
          this.storageFailureMessage =
            error?.code === "indexeddb_blocked" ? error.message : null;
          this.store = null;
        }
        return null;
      });

    this.draftRestore = this.storeReady
      .then(async (store) => {
        if (!store || !this.lifecycleActive(generation)) return;
        const draft = await store.loadDraft({
          sessionId: this.sessionId,
          contentHash: this.contentHash,
        });
        if (this.lifecycleActive(generation))
          this.restoreCompletionDraft(draft);
      })
      .catch(() => {
        if (this.lifecycleActive(generation)) {
          this.traceRetentionAvailable = false;
        }
      });
  },

  queueTraceChunk(chunk) {
    const generation = this.lifecycleGeneration;
    if (!this.lifecycleActive(generation)) return;
    const clientSessionId = this.clientSessionId;
    const chunkKey = chunk.chunk_index;
    this.pendingTraceChunks.set(chunkKey, chunk);
    this.traceWrite = this.traceWrite
      .then(async (priorWritesDurable) => {
        const store = await this.storeReady;
        if (!store || !this.lifecycleActive(generation)) return false;
        await store.appendTraceChunk(this.sessionId, clientSessionId, chunk, this.traceCaptureId);
        if (this.pendingTraceChunks.get(chunkKey) === chunk) {
          this.pendingTraceChunks.delete(chunkKey);
        }
        return priorWritesDurable;
      })
      .catch(() => {
        if (this.lifecycleActive(generation)) {
          this.traceRetentionAvailable = false;
        }
        return false;
      });
  },

  completionDraft() {
    const completion = this.flow.completion;
    if (!completion) return null;
    return {
      session_id: this.sessionId,
      content_hash: this.contentHash,
      client_session_id: this.clientSessionId,
      burpee_count_actual: completion.burpeeCountActual,
      burpee_count_provenance: completion.burpeeCountProvenance ?? null,
      scheduled_reps_done: completion.scheduledRepsDone ?? null,
      burpee_count_planned: completion.burpeeCountPlanned,
      duration_sec_actual: completion.durationSecActual,
      duration_sec_planned: completion.durationSecPlanned,
      tracking: {
        enabled: this.flow.captureMode === "camera",
        trust: completion.trackingTrust,
        reason: this.flow.trackingReason ?? null,
        detected_reps: completion.detectedReps,
        detected_duration_sec: completion.detectedDurationSec,
        cadence_ms: [...(completion.cadenceMs || [])],
      },
      mood: completion.mood ?? null,
      ended_early: completion.endedEarly === true,
      tags: [...(completion.tags || [])],
      context_low_energy: completion.contextLowEnergy ?? false,
      context_high_energy: completion.contextHighEnergy ?? false,
      context_heat_affected: completion.contextHeatAffected ?? false,
      primary_limiter: completion.primaryLimiter ?? null,
      preference_feedback: completion.preferenceFeedback ?? null,
      note_post: completion.notePost || "",
    };
  },

  queueCompletionDraft() {
    const generation = this.lifecycleGeneration;
    if (!this.lifecycleActive(generation)) return;
    const draft = this.completionDraft();
    if (!draft) return;
    this.inMemoryCompletionDraft = draft;
    this.completionDraftPending = true;
    this.draftWrite = this.draftWrite
      .then(async () => {
        const store = await this.storeReady;
        if (!store || !this.lifecycleActive(generation)) return false;
        await store.saveDraft(draft);
        if (this.inMemoryCompletionDraft === draft) {
          this.completionDraftPending = false;
        }
        return true;
      })
      .catch(() => {
        if (this.lifecycleActive(generation)) {
          this.traceRetentionAvailable = false;
        }
        return false;
      });
  },

  completionPayload() {
    const completion = this.flow.completion;
    if (!completion) return null;
    const burpeeType = this.el.querySelector(
      "#workout_session_burpee_type",
    )?.value;
    return {
      workout_session: {
        burpee_type: burpeeType || null,
        burpee_count_actual: completion.burpeeCountActual,
        burpee_count_planned: completion.burpeeCountPlanned,
        duration_sec_actual: completion.durationSecActual,
        duration_sec_planned: Math.round(completion.durationSecPlanned),
        client_session_id: this.clientSessionId,
        ...(completion.mood == null ? {} : { mood: completion.mood }),
        ...(completion.tags?.length ? { tags: completion.tags.join(",") } : {}),
        note_post: completion.notePost || "",
      },
      tracking: {
        enabled: this.flow.captureMode === "camera",
        trust: completion.trackingTrust,
        reason: this.flow.trackingReason ?? null,
        detected_reps: completion.detectedReps,
        detected_duration_sec: completion.detectedDurationSec,
        cadence_ms: [...(completion.cadenceMs || [])],
      },
    };
  },

  saveCompletion() {
    if (
      this.discarding ||
      this.flow.mode !== "completion_review" ||
      this.flow.saveStatus === "saving"
    )
      return;
    const payload = this.completionPayload();
    if (!payload) return;
    const generation = this.lifecycleGeneration;
    this.renderer.clearSaveErrors();
    this.dispatchFlow({ type: "SAVE_STARTED" });

    if (this.serverCompletion) {
      if (!this.store) this.initializeSessionStore();
      this.retryPendingLocalWrites();
      this.renderStoragePending();
      this.finalizeSavedCompletion(this.serverCompletion, generation);
      return;
    }

    const submittedFacts = structuredClone(this.flow.completion);
    this.pendingServerCompletionFacts = submittedFacts;

    try {
      this.pushEvent("save_session", payload, (reply) => {
        if (!this.lifecycleActive(generation)) return;
        void this.handleSaveReply(reply, generation, submittedFacts);
      });
    } catch {
      this.pendingServerCompletionFacts = null;
      this.handleSaveFailure({
        status: "error",
        message: "Could not save. Try again.",
        retryable: true,
      });
    }
  },

  handleSaveReply(reply, generation, acknowledgedFacts) {
    if (!this.lifecycleActive(generation)) return;
    if (reply?.status !== "ok" || Number(reply.session_id) !== this.sessionId) {
      this.pendingServerCompletionFacts = null;
      this.handleSaveFailure(reply || {});
      return;
    }

    this.serverCompletion = {
      session_id: Number(reply.session_id),
      redirect_to: reply.redirect_to,
    };
    this.pendingServerCompletionFacts = null;
    this.dispatchFlow({
      type: "SERVER_COMPLETION_ACKNOWLEDGED",
      completion: acknowledgedFacts,
    });
    this.renderer.renderCompletion(this.flow.completion);
    this.renderStoragePending();
    this.finalizeSavedCompletion(this.serverCompletion, generation);
  },

  retryPendingLocalWrites() {
    if (this.pendingTraceChunks.size > 0) {
      const chunks = [...this.pendingTraceChunks.values()];
      this.traceWrite = Promise.resolve(true);
      for (const chunk of chunks) this.queueTraceChunk(chunk);
    }

    if (this.completionDraftPending) {
      this.draftWrite = Promise.resolve(true);
      this.queueCompletionDraft();
    }
  },

  finalizeSavedCompletion(serverCompletion, generation) {
    this.saveCleanup = Promise.all([this.traceWrite, this.draftWrite])
      .then(async ([traceDurable, draftDurable]) => {
        if (!traceDurable || !draftDurable) {
          throw new Error("pending evidence was not durable");
        }

        const store = await this.storeReady;
        if (!store) throw new Error("session storage is unavailable");

        const result = await store.finalizeServerCompletion(
          this.sessionId,
          this.contentHash,
          this.clientSessionId,
        );
        if (result.traceReady) {
          window.dispatchEvent(new CustomEvent("burpee:trace-upload-ready"));
        }

        if (this.lifecycleActive(generation)) {
          this.inMemoryCompletionDraft = null;
          this.dispatchFlow({ type: "SAVE_SUCCEEDED" });
          window.location.assign(serverCompletion.redirect_to);
        }
      })
      .catch(() => {
        if (this.lifecycleActive(generation)) {
          this.dispatchFlow({ type: "SAVE_FAILED" });
          this.renderStorageFailure(
            this.storageFailureMessage ||
              "Session saved, but local evidence is still pending. Stay on this page.",
          );
        }
      });
  },

  renderStoragePending() {
    this.renderer.renderSavePending("Session saved. Finishing up…");
  },

  renderStorageFailure(message) {
    this.traceRetentionAvailable = false;
    this.renderer.renderSaveErrors({
      status: "error",
      field_errors: {},
      global_errors: [message],
    });
  },

  handleSaveFailure(reply) {
    this.dispatchFlow({ type: "SAVE_FAILED" });
    const globalErrors = [...(reply.global_errors || [])];
    if (reply.message) globalErrors.push(reply.message);
    if (globalErrors.length === 0 && reply.status === "error") {
      globalErrors.push("Could not save. Try again.");
    }
    this.renderer.renderSaveErrors({
      ...reply,
      field_errors: reply.field_errors || {},
      global_errors: globalErrors,
    });
  },

  restoreCompletionDraft(draft) {
    if (
      !draft ||
      draft.session_id !== this.sessionId ||
      draft.content_hash !== this.contentHash ||
      draft.client_session_id !== this.clientSessionId ||
      this.flow.mode !== "starting"
    ) {
      return;
    }

    const tracking = draft.tracking || {};
    const legacyTags = Array.isArray(draft.tags) ? draft.tags : [];
    const completion = {
      burpeeCountActual: draft.burpee_count_actual ?? 0,
      ...restoredProvenance(draft),
      ...(Number.isInteger(draft.scheduled_reps_done)
        ? { scheduledRepsDone: draft.scheduled_reps_done }
        : {}),
      burpeeCountPlanned: draft.burpee_count_planned ?? 0,
      durationSecActual: draft.duration_sec_actual ?? 0,
      durationSecPlanned: draft.duration_sec_planned ?? 0,
      detectedReps: tracking.detected_reps ?? null,
      detectedDurationSec: tracking.detected_duration_sec ?? null,
      trackingTrust: tracking.trust || "disabled",
      cadenceMs: [...(tracking.cadence_ms || [])],
      mood: draft.mood ?? null,
      endedEarly: draft.ended_early === true,
      tags: [...legacyTags],
      contextLowEnergy:
        draft.context_low_energy ?? legacyTags.includes("tired"),
      contextHighEnergy:
        draft.context_high_energy ?? legacyTags.includes("great_energy"),
      contextHeatAffected:
        draft.context_heat_affected ?? legacyTags.includes("hot"),
      primaryLimiter: draft.primary_limiter || null,
      preferenceFeedback: draft.preference_feedback || null,
      notePost: draft.note_post || "",
    };

    this.inMemoryCompletionDraft = draft;
    this.dispatchFlow({
      type: "RESTORE_COMPLETION_DRAFT",
      captureMode: tracking.enabled ? "camera" : "no_camera",
      trackingReason: tracking.reason ?? null,
      completion,
    });
  },

  stepReps(step) {
    const count = this.flow.completion?.burpeeCountActual;
    const from = Number.isInteger(count) ? count : 0;
    const next = Math.max(0, from + step);
    if (next !== count) this.editCompletion({ burpeeCountActual: next });
  },

  // A disabled button (− at zero, or while saving) may never see its release, so the
  // hold also ends itself there.
  startRepHold(step, button) {
    this.stopRepHold();
    let wait = REP_HOLD_DELAY_MS;
    const repeat = () => {
      if (!this.repHold) return;
      if (!button || button.hasAttribute("disabled")) {
        this.endRepHold();
        return;
      }
      this.repHold.repeated = true;
      this.stepReps(step);
      if (button.hasAttribute("disabled")) {
        this.endRepHold();
        return;
      }
      wait = Math.max(REP_HOLD_FASTEST_MS, wait * 0.8);
      this.repHold.timer = setTimeout(repeat, wait);
    };
    this.repHold = { button, repeated: false, timer: setTimeout(repeat, wait) };
  },

  // Ends a hold and says the count it reached; true when it had counted.
  endRepHold() {
    const repeated = this.repHold?.repeated === true;
    this.stopRepHold();
    if (repeated) this.announceReps();
    return repeated;
  },

  stopRepHold() {
    if (this.repHold) clearTimeout(this.repHold.timer);
    this.repHold = null;
  },

  announceReps() {
    const count = this.flow.completion?.burpeeCountActual;
    if (!Number.isInteger(count)) return;
    this.renderer.announce(count === 1 ? "1 rep" : `${count} reps`);
  },

  editCompletion(changes) {
    if (
      this.discarding ||
      this.flow.mode !== "completion_review" ||
      this.flow.saveStatus === "saving" ||
      this.flow.completionLocked ||
      this.serverCompletion
    ) {
      if (this.flow.completionLocked) {
        this.renderer.renderCompletion(this.flow.completion);
      }
      return;
    }
    this.dispatchFlow({ type: "COMPLETION_EDITED", changes });
    this.queueCompletionDraft();
    this.renderer.renderCompletion(this.flow.completion);
  },

  // A paused workout may be aborted, and a finished one not saved yet thrown away.
  canDiscard() {
    if (this.discarding) return false;
    if (this.flow.mode !== "completion_review") return this.isPaused();
    return (
      this.flow.saveStatus !== "saving" &&
      !this.flow.completionLocked &&
      !this.serverCompletion
    );
  },

  isPaused() {
    return Boolean(this.paused || this.countdownPaused);
  },

  discardSession() {
    if (!this.canDiscard()) return;
    const generation = this.lifecycleGeneration;
    let timer = null;
    const aborting = this.flow.mode !== "completion_review";
    const refused = () => {
      clearTimeout(timer);
      if (!this.lifecycleActive(generation)) return;
      this.discarding = null;
      this.renderer.setDiscardBusy(false);
      if (aborting) {
        this.renderer.showAbortConfirm(false);
        this.renderer.showAbortError("Could not abort the workout. Try again.");
        return;
      }
      this.renderer.showDiscardConfirm(false);
      this.renderer.renderSaveErrors({
        field_errors: {},
        global_errors: ["Could not discard the session. Try again."],
      });
    };

    // Nothing else on the screen changes while the server answers; no answer gives up.
    this.renderer.setDiscardBusy(true);
    this.discarding = new Promise((resolve) => {
      timer = setTimeout(() => resolve({ status: "timeout" }), DISCARD_TIMEOUT_MS);
      this.pushEvent("discard_session", {}, resolve);
    }).then(
      async (reply) => {
        clearTimeout(timer);
        if (!this.lifecycleActive(generation)) return;
        if (reply?.status !== "discarded") return refused();
        // The server has deleted it; the device copy goes too, best effort.
        await Promise.resolve(this.draftWrite).catch(() => undefined);
        const store = await this.storeReady;
        await Promise.resolve(
          store?.discardSession?.(this.sessionId, this.contentHash),
        ).catch(() => undefined);
        if (this.lifecycleActive(generation)) window.location.assign("/");
      },
      refused,
    );
  },

  // Once an abort is sent, the workout stays paused until the server answers.
  canTogglePause() {
    return (
      !this.discarding &&
      (this.startTime !== null || this.countdownCount !== null)
    );
  },

  activeRuntimeForFlow() {
    return (
      (this.flow.mode === "warmup_running" &&
        this.activeSegment === "warmup") ||
      (this.flow.mode === "workout_running" && this.activeSegment === "workout")
    );
  },

  destroyed() {
    this.lifecycleDestroyed = true;
    this.lifecycleGeneration = (this.lifecycleGeneration || 0) + 1;
    if (this.rafId) cancelAnimationFrame(this.rafId);
    if (this.countdownRafId) cancelAnimationFrame(this.countdownRafId);
    if (this.countdownTimeoutId) clearTimeout(this.countdownTimeoutId);
    if (this.finalRepGraceTimeoutId) clearTimeout(this.finalRepGraceTimeoutId);
    this.renderer.clearTimers();
    this.audio.stop();
    document.removeEventListener("visibilitychange", this.onVisibility);
    document.removeEventListener("click", this.primeAudio, { capture: true });
    document.removeEventListener("touchstart", this.primeAudio, {
      capture: true,
    });
    this.el.removeEventListener(
      "pose-tracker:started",
      this.onPoseTrackerStarted,
    );
    this.el.removeEventListener(
      "pose-tracker:start-failed",
      this.onPoseTrackerStartFailed,
    );
    this.el.removeEventListener("pose-tracker:rep", this.onPoseTrackerRep);
    this.el.removeEventListener(
      "pose-tracker:status",
      this.onPoseTrackerStatus,
    );
    this.el.removeEventListener(
      "pose-tracker:readiness",
      this.onPoseTrackerReadiness,
    );
    this.el.removeEventListener(
      "pose-tracker:gesture-confirm",
      this.onPoseTrackerGestureConfirm,
    );
    this.el.removeEventListener(
      "pose-tracker:initialized",
      this.onPoseTrackerInitialized,
    );
    this.el.removeEventListener(
      "pose-tracker:finished",
      this.onPoseTrackerFinished,
    );
    this.el.removeEventListener(
      "pose-tracker:trace-chunk",
      this.onPoseTrackerTraceChunk,
    );
    this.el.removeEventListener("click", this.onRootClick);
    this.el.removeEventListener("pointerdown", this.onRepHoldStart);
    this.el.removeEventListener("pointerup", this.onRepHoldEnd);
    this.el.removeEventListener("pointercancel", this.onRepHoldEnd);
    this.el.removeEventListener("pointerout", this.onRepHoldOut);
    this.stopRepHold();
    this.el.removeEventListener("keydown", this.onRootKeydown);
    this.el.removeEventListener("input", this.onCompletionInput);
    this.el.removeEventListener("submit", this.onCompletionSubmit);
    this.wakeLock.release();
    this.audio.close();
  },

  dispatchFlow(event) {
    const result = flowTransition(this.flow, event);
    this.flow = result.state;
    result.commands.forEach((command) => this.runFlowCommand(command));
  },

  runFlowCommand(command) {
    switch (command.type) {
      case "renderFlow":
        this.renderer.renderFlowState(this.flow);
        this.dispatchTrackerCommand("pose-tracker:preview-visibility", {
          visible: this.flow.mode === "camera_setup",
        });
        break;
      case "startCamera":
        this.dispatchTrackerCommand("pose-tracker:start");
        break;
      case "stopCamera":
        this.dispatchTrackerCommand("pose-tracker:stop");
        break;
      case "armGesture":
        this.armPoseTrackerStep(command.step, 15);
        break;
      case "disarmGesture":
        this.disarmPoseTrackerStep();
        break;
      case "startSegment":
        this.startSegment(command);
        break;
      case "showCompletion":
        this.quiesceCompletedWorkout();
        this.queueCompletionDraft();
        this.renderer.renderCompletion(this.flow.completion);
        this.renderer.renderFlowState(this.flow);
        break;
    }
  },

  quiesceCompletedWorkout() {
    if (this.rafId) cancelAnimationFrame(this.rafId);
    if (this.countdownRafId) cancelAnimationFrame(this.countdownRafId);
    if (this.countdownTimeoutId) clearTimeout(this.countdownTimeoutId);
    this.rafId = null;
    this.countdownRafId = null;
    this.countdownTimeoutId = null;
    this.countdownCount = null;
    this.countdownStartedAt = null;
    this.countdownElapsedMs = 0;
    this.renderCountdownFrame = null;
    this.countdownStepStarted = null;
    this.countdownStepElapsed = 0;
    this.countdownPaused = false;
    this.startTime = null;
    this.hiddenAt = null;
    this.paused = false;
    this.activeSegment = null;
    this.wakeLock.release();
  },

  dispatchTrackerCommand(type, detail = undefined) {
    this.el
      .querySelector("#pose-tracker")
      ?.dispatchEvent(new CustomEvent(type, { detail }));
  },

  dispatchSegment(event) {
    const result = segmentTransition(this.segment, event);
    this.segment = result.state;
    this.timeline = this.segment.timeline;
    result.commands.forEach((command) => this.runSegmentCommand(command));
  },

  runSegmentCommand(command) {
    switch (command.type) {
      case "startCountdownTimer":
        this.startCountdown();
        break;
      case "pauseCountdownTimer":
        break;
      case "resumeCountdownTimer":
        break;
      case "renderCountdown":
        this.countdownCount = command.value;
        this.countdownShowCount(command.value, command.animate);
        break;
      case "playLeadBeep":
        this.audio.playLeadBeep();
        break;
      case "playRepBeep":
        this.audio.playRepBeep();
        break;
      case "scheduleCountdownTick":
        this.scheduleCountdownTick(command.nextValue, command.delayMs);
        break;
      case "clearCountdown":
        this.clearCountdown();
        break;
      case "beginSegment":
        this.beginSegment();
        break;
      case "renderRunningFrame":
        this.renderRunningFrame(command.elapsedSec, command.frame);
        break;
      case "updateVisibleRepTotal":
        this.renderer.updateTotalCounter(command.burpeeCountDone);
        break;
      case "updateVisibleRepGoal":
        this.renderer.updateTotalGoal(command.burpeeCountTarget);
        break;
      case "renderTimer":
        this.renderer.renderTimer(command.timeLeftSec);
        break;
      case "enterWorkPhase":
        this.renderer.enterWorkPhase();
        break;
      case "triggerDown":
        this.renderer.triggerDown(command.remainingReps);
        break;
      case "renderCurrentSetRepCount":
        this.renderer.updateCurrentSetRepCount(command.remainingReps);
        break;
      case "renderWorkRepProgress":
        this.renderer.updateWorkFill(command.progress);
        break;
      case "enterRestPhase":
        this.renderer.enterRestPhase();
        break;
      case "renderRestProgress":
        this.renderer.renderRestProgress(command.timeLeftSec);
        break;
      case "scheduleAnimationFrame":
      case "startAnimationFrame":
        this.rafId = requestAnimationFrame(() => this.tick());
        break;
      case "cancelAnimationFrame":
        if (this.rafId) cancelAnimationFrame(this.rafId);
        this.rafId = null;
        break;
      case "segmentDone": {
        // The camera sees a rep when you stand up, which can be a moment after the timer
        // ends; with tracking on, the count waits briefly for that last rep.
        // Finishing early happens while paused, when there is no rep to wait for.
        if (
          this.activeSegment === "workout" &&
          this.flow.captureMode === "camera" &&
          this.flow.trackingTrust !== "degraded" &&
          !this.finishingEarly
        ) {
          this.pendingWorkoutResult = command.result;
          this.finalRepGraceTimeoutId = setTimeout(
            () => this.completeWorkoutSegment(),
            LATE_REP_GRACE_MS,
          );
          break;
        }
        const result =
          this.activeSegment === "workout"
            ? this.workoutCompletionResult(command.result)
            : command.result;
        // Finish early ends the timer too; the finish screen should say which it was.
        this.dispatchFlow({
          type: this.finishingEarly ? "FINISH_EARLY" : "SEGMENT_DONE",
          segment: this.activeSegment,
          result,
        });
        break;
      }
    }
  },

  warmupStart() {
    const warmupTimeline = warmupTimelineFromProgram(this.program);
    return {
      warmupTimeline,
      burpeeCountTarget: programBurpeeCount(warmupTimeline),
    };
  },

  handlePoseGestureConfirm({ step }) {
    if (!step) return;
    this.dispatchFlow({ type: "GESTURE_CONFIRM", step, ...this.warmupStart() });
  },

  startCountdown() {
    this.audio.ensureRunning();
    this.wakeLock.acquire();

    const renderCountdown = (value) => {
      const model = countdownDisplayModel({
        value,
        totalDone: this.segment.reps.burpeeCountDone,
        totalTarget: this.segment.reps.burpeeCountTarget,
        timeLeftSec: this.segment.clock.totalDurationSec,
        sessionProgress: this.activeSegment === "workout" ? 0 : null,
      });
      this.renderer.renderDisplayModel(model);
    };

    this.renderCountdownFrame = renderCountdown;
    this.countdownShowCount = (value, _animate) => renderCountdown(value);
    this.countdownCount = 5;
    this.countdownStartedAt = performance.now();
    this.renderCountdownContinuously(renderCountdown);
    this.countdownShowCount(5, false);
    this.audio.playLeadBeep();
    this.scheduleCountdownTick(4);
  },

  renderCountdownContinuously(renderCountdown) {
    const draw = () => {
      if (this.countdownCount === null || this.countdownPaused) return;
      const elapsedMs = this.countdownStartedAt
        ? performance.now() - this.countdownStartedAt
        : 0;
      renderCountdown(
        this.countdownCount,
        Math.min(Math.max(elapsedMs / 5000, 0), 1),
        false,
      );
      this.countdownRafId = requestAnimationFrame(draw);
    };
    this.countdownRafId = requestAnimationFrame(draw);
  },

  scheduleCountdownTick(n, delayMs = 1000) {
    this.countdownStepStarted = performance.now();
    this.countdownTimeoutId = setTimeout(() => {
      if (this.countdownPaused) return;
      this.dispatchSegment({
        type: "COUNTDOWN_TICK",
        value: n,
        now: performance.now(),
      });
    }, delayMs);
  },

  clearCountdown() {
    this.countdownCount = null;
    if (this.countdownRafId) cancelAnimationFrame(this.countdownRafId);
    this.countdownRafId = null;
    this.countdownStartedAt = null;
    this.countdownElapsedMs = 0;
    this.renderCountdownFrame = null;
    this.countdownTimeoutId = null;
    this.countdownStepStarted = null;
    this.renderer.clearCountdown();
  },

  beginSegment() {
    const now = performance.now();
    this.dispatchSegment({ type: "COUNTDOWN_DONE", now });
    if (document.visibilityState === "hidden") {
      this.dispatchSegment({ type: "VISIBILITY_HIDDEN", now });
      this.hiddenAt = this.segment.clock.hiddenAt;
    }

    if (this.activeSegment === "workout") {
      this.startPoseObservation();
    }

    this.updatePauseActionsVisibility();

    this.startTime = this.segment.clock.startTime;
  },

  startSegment({ segment, timeline, burpeeCountTarget }) {
    this.renderer.renderFlowState(this.flow);
    this.activeSegment = segment;
    document.dispatchEvent(
      new CustomEvent("pose-capture:segment", {
        detail: { segment: segment === "workout" ? "main" : segment },
      }),
    );
    this.lastDownCueKey = null;
    this.segment = initialSegmentState();
    this.dispatchSegment({
      type: "SEGMENT_READY",
      timeline,
      burpeeCountTarget,
    });
    this.dispatchSegment({ type: "COUNTDOWN_START", now: performance.now() });
  },

  tick() {
    this.rafId = null;
    if (this.paused || this.startTime === null) return;
    const now = performance.now();
    const elapsed = (now - this.startTime) / 1000;
    this.dispatchSegment({ type: "TICK", elapsedSec: elapsed });
  },

  renderRunningFrame(elapsed, frame) {
    this.syncRepStateFromSegment();
    // While the camera is counting, the screen shows its reps; otherwise the schedule's.
    const paced = this.cameraPaced();
    const doneInEvent = paced ? (this.cameraSetReps[frame?.index] ?? 0) : this.doneReps;
    const totalDone = paced ? this.tracking.cadenceMs.length : this.segment.reps.burpeeCountDone;
    const remainingReps = Math.max(
      (frame?.event?.reps || 0) - doneInEvent,
      0,
    );

    const totalDurationSec = this.segment.clock.totalDurationSec;
    const sessionProgress =
      this.activeSegment === "workout"
        ? sessionProgressForElapsed(elapsed, totalDurationSec)
        : null;
    const model = runningDisplayModel({
      timeline: this.timeline,
      frame,
      timeLeftSec: Math.max(totalDurationSec - elapsed, 0),
      sessionProgress,
      repProgress: paced ? totalDone / programBurpeeCount(this.timeline) : null,
      totalDone,
      totalTarget: this.segment.reps.burpeeCountTarget,
      doneInEvent,
    });
    this.renderer.renderDisplayModel(model);
    this.triggerDownCueForFrame(frame, remainingReps);

    this.dispatchSegment({ type: "BEEP_FRAME", frame });
  },

  triggerDownCueForFrame(frame, remainingReps) {
    const event = frame?.event;
    if (event?.kind !== "work") {
      this.lastDownCueKey = null;
      return;
    }

    const secondsPerRep = event.sec_per_rep;
    if (!secondsPerRep || secondsPerRep <= 0) return;

    const repIndex = Math.floor((frame.phase_elapsed || 0) / secondsPerRep);
    const cueKey = `${this.activeSegment}:${frame.index}:${repIndex}`;
    if (cueKey === this.lastDownCueKey) return;

    this.lastDownCueKey = cueKey;
    this.renderer.triggerDown(remainingReps);
  },

  togglePause() {
    if (this.countdownCount !== null) {
      if (this.countdownPaused) {
        this.resumeCountdown();
      } else {
        this.pauseCountdown();
      }
      return;
    }
    if (this.paused) {
      this.resume();
    } else {
      this.pause();
    }
  },

  pauseCountdown() {
    this.dispatchSegment({ type: "COUNTDOWN_PAUSE", now: performance.now() });
    this.countdownPaused = true;
    this.dispatchTrackerCommand("pose-tracker:suspend");
    if (this.countdownTimeoutId) {
      clearTimeout(this.countdownTimeoutId);
      this.countdownTimeoutId = null;
    }
    this.countdownStepElapsed = this.segment.countdown.stepElapsedMs;
    this.countdownElapsedMs = this.countdownStartedAt
      ? performance.now() - this.countdownStartedAt
      : 0;
    if (this.countdownRafId) cancelAnimationFrame(this.countdownRafId);
    this.countdownRafId = null;
    this.audio.stop();
    this.renderer.updatePauseButton(true);
    this.updatePauseActionsVisibility();
  },

  resumeCountdown() {
    this.dispatchSegment({ type: "COUNTDOWN_RESUME", now: performance.now() });
    this.countdownPaused = false;
    this.dispatchTrackerCommand("pose-tracker:resume");
    this.renderer.updatePauseButton(false);
    this.updatePauseActionsVisibility();

    const n = this.countdownCount;
    if (n === null) return;

    this.countdownStartedAt =
      performance.now() - (this.countdownElapsedMs || 0);
    this.countdownShowCount(n, false);
    if (this.renderCountdownFrame) {
      this.renderCountdownContinuously(this.renderCountdownFrame);
    }
    const remaining = Math.max(1000 - (this.countdownStepElapsed || 0), 0);
    this.scheduleCountdownTick(n - 1, remaining);
  },

  pause() {
    if (this.paused) return;
    this.dispatchSegment({ type: "PAUSE", now: performance.now() });
    this.paused = true;
    this.dispatchTrackerCommand("pose-tracker:suspend");
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.rafId = null;
    this.audio.stop();
    this.renderer.updatePauseButton(true);
    this.updatePauseActionsVisibility();
  },

  resume() {
    if (!this.paused) return;
    this.dispatchSegment({ type: "RESUME", now: performance.now() });
    this.startTime = this.segment.clock.startTime;
    this.paused = false;
    this.hiddenAt = null;
    this.dispatchTrackerCommand("pose-tracker:resume");
    this.resetPoseTracker();
    if (!this.rafId) this.rafId = requestAnimationFrame(() => this.tick());
    this.renderer.updatePauseButton(false);
    this.updatePauseActionsVisibility();
  },

  updatePauseActionsVisibility() {
    const actions = this.el.querySelector("#session-pause-actions");
    const finishEarlyBtn = this.el.querySelector("#finish-early-btn");
    if (!actions) return;

    const isPaused = this.paused || this.countdownPaused;
    if (!isPaused) this.renderer.resetAbort();
    const canFinishEarly =
      isPaused && ["warmup", "workout"].includes(this.activeSegment);
    actions.style.opacity = isPaused ? "1" : "0";
    actions.style.transform = isPaused ? "translateY(0)" : "";
    actions.style.pointerEvents = isPaused ? "auto" : "none";
    actions.setAttribute("aria-hidden", isPaused ? "false" : "true");

    if (isPaused) {
      actions.removeAttribute("inert");
    } else {
      actions.setAttribute("inert", "");
    }

    if (finishEarlyBtn) {
      if (canFinishEarly) {
        finishEarlyBtn.removeAttribute("disabled");
      } else {
        finishEarlyBtn.setAttribute("disabled", "disabled");
      }
    }
  },

  startPoseObservation() {
    this.resetPoseTracker();
    this.tracking = startTrackingObserver(this.tracking, this.trackerReadiness);
    this.cameraSetReps = [];
  },

  cameraPaced() {
    return this.activeSegment === "workout" && this.tracking.mode === "observing";
  },

  resetPoseTracker() {
    this.el
      .querySelector("#pose-tracker")
      ?.dispatchEvent(new CustomEvent("pose-tracker:reset"));
  },

  armPoseTrackerStep(step, holdFramesRequired) {
    this.armedPoseStep = step;
    this.armedPoseHoldFramesRequired = holdFramesRequired;
    if (this.flow.captureMode !== "camera") return;
    this.el.querySelector("#pose-tracker")?.dispatchEvent(
      new CustomEvent("pose-tracker:arm", {
        detail: { step, holdFramesRequired },
      }),
    );
  },

  disarmPoseTrackerStep() {
    this.armedPoseStep = null;
    this.armedPoseHoldFramesRequired = 0;
    this.dispatchTrackerCommand("pose-tracker:arm", {
      step: null,
      holdFramesRequired: 0,
    });
  },

  reissuePendingArm() {
    if (this.flow.captureMode !== "camera" || !this.armedPoseStep) return;
    this.el.querySelector("#pose-tracker")?.dispatchEvent(
      new CustomEvent("pose-tracker:arm", {
        detail: {
          step: this.armedPoseStep,
          holdFramesRequired: this.armedPoseHoldFramesRequired,
        },
      }),
    );
  },

  observePoseRep({ index, lagMs = 0 }) {
    // A rep that lands while the workout waits for its last one counts at its end.
    if (this.pendingWorkoutResult) {
      this.tracking = observeTrackingRep(this.tracking, {
        index,
        elapsedMs: Math.max(
          0,
          Math.round((this.pendingWorkoutResult.durationSec || 0) * 1_000),
        ),
        eligible:
          this.activeSegment === "workout" && document.visibilityState === "visible",
      });
      return;
    }

    // The counter decides a rep a moment after it happens; date it when it happened.
    const elapsedSec = Math.max(
      0,
      (this.segment.clock.elapsedSec || 0) - Math.max(0, lagMs) / 1_000,
    );
    const frame = currentFrame(this.timeline, elapsedSec);
    const eligible =
      this.activeSegment === "workout" &&
      this.segment.mode === "running" &&
      this.segment.clock.hiddenAt === null &&
      document.visibilityState === "visible" &&
      (frame?.event?.kind === "work" || justAfterWork(this.timeline, frame));

    this.tracking = observeTrackingRep(this.tracking, {
      index,
      elapsedMs: Math.max(0, Math.round(elapsedSec * 1_000)),
      eligible,
    });
    if (!this.cameraPaced()) return;

    // Once the camera has counted the set's reps, its rest starts.
    this.cameraSetReps = cameraRepsBySet(this.timeline, this.tracking.cadenceMs);
    const now = this.segment.clock.elapsedSec || 0;
    const current = currentFrame(this.timeline, now);
    if (
      current?.event?.kind === "work" &&
      this.cameraSetReps[current.index] >= (current.event.reps || 0)
    ) {
      this.dispatchSegment({ type: "END_SET", elapsedSec: now });
    }
  },

  updatePoseStatus({ state, reason }) {
    this.tracking = updateTrackingStatus(this.tracking, state);
    if (state === "lost" && this.flow.captureMode === "camera") {
      this.dispatchFlow({
        type: "TRACKING_DEGRADED",
        reason: reason || "tracking_lost",
      });
    }
  },

  // Ends the workout after the grace for its last rep; the count is final from here.
  completeWorkoutSegment() {
    if (this.finalRepGraceTimeoutId) clearTimeout(this.finalRepGraceTimeoutId);
    this.finalRepGraceTimeoutId = null;
    const pending = this.pendingWorkoutResult;
    if (!pending) return;
    this.pendingWorkoutResult = null;
    this.dispatchFlow({
      type: "SEGMENT_DONE",
      segment: "workout",
      result: this.workoutCompletionResult(pending),
    });
  },

  workoutCompletionResult(timerResult) {
    if (this.flow.captureMode !== "camera") return timerResult;
    const durationMs = Math.round((timerResult.durationSec || 0) * 1_000);
    const finished = finishTrackingObserver(this.tracking, durationMs);
    this.tracking = finished.state;
    this.trackingCompletion = finished.result;
    this.trackerFinished = null;
    this.dispatchTrackerCommand("pose-tracker:finish", {
      durationMs,
      cadenceMs: finished.result.trusted ? finished.result.cadenceMs : [],
    });
    const trackerFinished = this.trackerFinished;
    this.dispatchTrackerCommand("pose-tracker:stop");

    if (
      !finished.result.trusted ||
      this.flow.trackingTrust === "degraded" ||
      !trackerFinished
    ) {
      if (this.flow.trackingTrust !== "degraded") {
        this.dispatchFlow({
          type: "TRACKING_DEGRADED",
          reason: "tracking_incomplete",
        });
      }
      return { ...timerResult, cadenceMs: [] };
    }
    this.dispatchFlow({ type: "TRACKING_FINISHED" });
    return {
      ...timerResult,
      detectedReps: trackerFinished.reps,
      detectedDurationSec: trackerFinished.duration_ms / 1_000,
      cadenceMs: trackerFinished.cadence_ms,
    };
  },

  // Nothing is saved until Save, so this asks nothing: the finish screen can still leave
  // or discard. Before the workout's clock runs (warmup, countdown) nothing is counted.
  onFinishEarly() {
    if (!(this.paused || this.countdownPaused)) return;
    if (!["warmup", "workout"].includes(this.activeSegment)) return;
    if (
      this.activeSegment === "warmup" ||
      this.countdownCount !== null ||
      this.startTime === null
    ) {
      this.dispatchTrackerCommand("pose-tracker:stop");
      this.dispatchFlow({
        type: "FINISH_EARLY",
        result: { burpeeCountDone: 0, scheduledRepsDone: 0, durationSec: 0 },
      });
      return;
    }
    const elapsed = this.segment?.clock?.elapsedSec ?? 0;
    this.finishingEarly = true;
    this.dispatchSegment({ type: "FINISH_EARLY", elapsedSec: elapsed });
    this.finishingEarly = false;
  },

  syncRepStateFromSegment() {
    this.doneReps = this.segment.reps.doneInEvent;
  },
};

export default SessionHook;
