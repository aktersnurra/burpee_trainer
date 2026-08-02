import { SessionAudio } from "./session_audio.mjs";
import {
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";
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
import {
	finishTrackingObserver,
	initialTrackingObserver,
	observeTrackingRep,
	startTrackingObserver,
	updateTrackingReadiness,
	updateTrackingStatus,
} from "./pose_tracking_observer.mjs";

const DISCARD_NAVIGATION_DEADLINE_MS = 100;
const SAVE_NAVIGATION_DEADLINE_MS = 100;

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
		this.trackerReadiness = "not_ready";
		this.trackingCompletion = null;
		this.armedPoseStep = null;
		this.armedPoseHoldFramesRequired = 0;
		this.warmupTimeoutRemainingMs = 0;
		this.warmupTimeoutDeadline = null;
		this.warmupTimeoutId = null;
		this.warmupTimeoutRafId = null;
		this.trackerFinished = null;
		this.traceRetentionAvailable = true;
		this.store = null;
		this.storeReady = null;
		this.traceWrite = Promise.resolve();
		this.draftWrite = Promise.resolve();
		this.draftRestore = Promise.resolve();
		this.inMemoryCompletionDraft = null;
		this.discarding = false;
		this.saveCleanup = Promise.resolve();
		this.saveNavigationTimeoutId = null;
		this.onPoseTrackerInitialized = () => this.reissuePendingArm();
		this.onPoseTrackerStarted = () =>
			this.dispatchFlow({ type: "CAMERA_STARTED" });
		this.onPoseTrackerStartFailed = (event) =>
			this.dispatchFlow({
				type: "CAMERA_START_FAILED",
				reason: event.detail?.reason,
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
			this.queueTraceChunk(event.detail || {});
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
		} catch (_error) {
			this.program = {};
		}
		this.planId = this.el.dataset.planId;
		this.programHash = this.el.dataset.programHash;
		this.clientSessionId = this.el.dataset.clientSessionId;
		this.initializeSessionStore();
		this.renderer.resetReady();
		this.dispatchFlow({
			type: "SESSION_READY",
			workoutTimeline: workoutTimelineFromProgram(this.program),
		});

		this.el.addEventListener("click", (e) => {
			const warmupYes = e.target.closest("#warmup-yes-btn");
			const warmupSkip = e.target.closest("#warmup-skip-btn");
			const workoutReady = e.target.closest("#workout-ready-btn");
			const chooseCamera = e.target.closest("#camera-choice-yes");
			const chooseNoCamera = e.target.closest("#camera-choice-no");
			const retryCamera = e.target.closest("#camera-status-retry");
			const continueWithoutCamera =
				e.target.closest("#camera-status-continue") ||
				e.target.closest("#camera-setup-continue") ||
				e.target.closest("#workout-ready-continue");
			const ringContainer = e.target.closest("#ring-container");
			const finishEarly = e.target.closest("#finish-early-btn");
			const discard = e.target.closest("#session-discard-btn");
			const mood = e.target.dataset?.mood;
			const tag = e.target.dataset?.tag;

			if (warmupYes) this.onWarmupYes();
			if (warmupSkip) this.onWarmupSkip();
			if (workoutReady) this.onWorkoutReady();
			if (chooseCamera) this.dispatchFlow({ type: "CHOOSE_CAMERA" });
			if (chooseNoCamera) this.dispatchFlow({ type: "CHOOSE_NO_CAMERA" });
			if (retryCamera) this.dispatchFlow({ type: "RETRY_CAMERA" });
			if (continueWithoutCamera) {
				this.dispatchFlow({ type: "CONTINUE_WITHOUT_CAMERA" });
			}
			if (ringContainer && this.canTogglePause()) this.togglePause();
			if (finishEarly) this.onFinishEarly();
			if (mood !== undefined) this.editCompletion({ mood: Number(mood) });
			if (tag !== undefined) this.toggleCompletionTag(tag);
			if (
				discard &&
				window.confirm(discard.dataset.confirm || "Discard this session?")
			) {
				this.discardSessionLocally();
			}
		});

		this.onCompletionInput = (event) => {
			const { id, value } = event.target;
			if (id === "completion-reps-input") {
				this.editCompletionNumber("burpeeCountActual", value);
			}
			if (id === "completion-duration-input") {
				this.editCompletionNumber("durationSecActual", value);
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

		this.el.addEventListener("keydown", (e) => {
			const ringContainer = e.target.closest("#ring-container");
			if (!ringContainer || !isPauseToggleKey(e) || !this.canTogglePause())
				return;

			e.preventDefault();
			if (!e.repeat) this.togglePause();
		});
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
				if (this.lifecycleActive(generation)) this.store = store;
				return store;
			})
			.catch(() => {
				if (this.lifecycleActive(generation)) {
					this.traceRetentionAvailable = false;
					this.store = null;
				}
				return null;
			});

		this.draftRestore = this.storeReady
			.then(async (store) => {
				if (!store || this.discarding || !this.lifecycleActive(generation)) {
					return;
				}
				const draft = await store.loadDraft({
					planId: this.planId,
					programHash: this.programHash,
				});
				if (this.lifecycleActive(generation) && !this.discarding) {
					this.restoreCompletionDraft(draft);
				}
			})
			.catch(() => {
				if (this.lifecycleActive(generation)) {
					this.traceRetentionAvailable = false;
				}
			});
	},

	queueTraceChunk(chunk) {
		const generation = this.lifecycleGeneration;
		if (this.discarding || !this.lifecycleActive(generation)) return;
		const clientSessionId = this.clientSessionId;
		this.traceWrite = this.traceWrite
			.then(async () => {
				const store = await this.storeReady;
				if (store && !this.discarding && this.lifecycleActive(generation)) {
					await store.appendTraceChunk(clientSessionId, chunk);
				}
			})
			.catch(() => {
				if (this.lifecycleActive(generation)) {
					this.traceRetentionAvailable = false;
				}
			});
	},

	completionDraft() {
		const completion = this.flow.completion;
		if (!completion) return null;
		return {
			client_session_id: this.clientSessionId,
			plan_id: this.planId,
			program_hash: this.programHash,
			burpee_count_actual: completion.burpeeCountActual,
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
			mood: completion.mood ?? 0,
			tags: [...(completion.tags || [])],
			note_post: completion.notePost || "",
		};
	},

	queueCompletionDraft() {
		const generation = this.lifecycleGeneration;
		if (this.discarding || !this.lifecycleActive(generation)) return;
		const draft = this.completionDraft();
		if (!draft) return;
		this.inMemoryCompletionDraft = draft;
		this.draftWrite = this.draftWrite
			.then(async () => {
				const store = await this.storeReady;
				if (store && !this.discarding && this.lifecycleActive(generation)) {
					await store.saveDraft(draft);
				}
			})
			.catch(() => {
				if (this.lifecycleActive(generation)) {
					this.traceRetentionAvailable = false;
				}
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
				duration_sec_planned: completion.durationSecPlanned,
				client_session_id: this.clientSessionId,
				mood: completion.mood ?? 0,
				tags: [...(completion.tags || [])].sort().join(","),
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
		if (this.flow.mode !== "completion_review" || this.discarding) return;
		const payload = this.completionPayload();
		if (!payload) return;
		const generation = this.lifecycleGeneration;
		this.renderer.clearSaveErrors();
		this.dispatchFlow({ type: "SAVE_STARTED" });

		try {
			this.pushEvent("save_session", payload, (reply) => {
				if (!this.lifecycleActive(generation)) return;
				void this.handleSaveReply(reply, generation);
			});
		} catch (_error) {
			this.handleSaveFailure({
				status: "error",
				message: "Could not save. Try again.",
				retryable: true,
			});
		}
	},

	handleSaveReply(reply, generation) {
		if (!this.lifecycleActive(generation)) return;
		if (reply?.status !== "ok") {
			this.handleSaveFailure(reply || {});
			return;
		}

		this.dispatchFlow({ type: "SAVE_SUCCEEDED" });
		let navigated = false;
		const clearTimer = this.clearTimeout || clearTimeout;
		const navigate = () => {
			if (navigated || !this.lifecycleActive(generation)) return;
			navigated = true;
			if (this.saveNavigationTimeoutId) {
				clearTimer(this.saveNavigationTimeoutId);
				this.saveNavigationTimeoutId = null;
			}
			window.location.assign(reply.redirect_to);
		};
		const scheduleTimer = this.setTimeout || setTimeout;
		this.saveNavigationTimeoutId = scheduleTimer(
			navigate,
			SAVE_NAVIGATION_DEADLINE_MS,
		);

		this.saveCleanup = Promise.all([this.traceWrite, this.draftWrite])
			.then(async () => {
				const store = await this.storeReady;
				if (store && (await store.hasTraceChunks(this.clientSessionId))) {
					await store.markTraceReady(this.clientSessionId, reply.session_id);
					window.dispatchEvent(new CustomEvent("burpee:trace-upload-ready"));
				}
				if (store) await store.deleteDraft(this.clientSessionId);
			})
			.catch(() => {
				this.traceRetentionAvailable = false;
			})
			.then(() => {
				if (this.lifecycleActive(generation)) {
					this.inMemoryCompletionDraft = null;
				}
				navigate();
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
			draft.plan_id !== this.planId ||
			draft.program_hash !== this.programHash ||
			!draft.client_session_id ||
			this.flow.mode !== "capture_choice"
		) {
			return;
		}

		const tracking = draft.tracking || {};
		const completion = {
			burpeeCountActual: draft.burpee_count_actual ?? 0,
			burpeeCountPlanned: draft.burpee_count_planned ?? 0,
			durationSecActual: draft.duration_sec_actual ?? 0,
			durationSecPlanned: draft.duration_sec_planned ?? 0,
			detectedReps: tracking.detected_reps ?? null,
			detectedDurationSec: tracking.detected_duration_sec ?? null,
			trackingTrust: tracking.trust || "disabled",
			cadenceMs: [...(tracking.cadence_ms || [])],
			mood: draft.mood ?? 0,
			tags: [...(draft.tags || [])],
			notePost: draft.note_post || "",
		};

		this.clientSessionId = draft.client_session_id;
		this.inMemoryCompletionDraft = draft;
		this.dispatchFlow({
			type: "RESTORE_COMPLETION_DRAFT",
			captureMode: tracking.enabled ? "camera" : "no_camera",
			trackingReason: tracking.reason ?? null,
			completion,
		});
	},

	editCompletionNumber(field, value) {
		const number = Number(value);
		if (!Number.isFinite(number) || number < 0) return;
		this.editCompletion({ [field]: number });
	},

	editCompletion(changes) {
		if (this.flow.mode !== "completion_review") return;
		this.dispatchFlow({ type: "COMPLETION_EDITED", changes });
		this.queueCompletionDraft();
		this.renderer.renderCompletion(this.flow.completion);
	},

	toggleCompletionTag(tag) {
		if (this.flow.mode !== "completion_review") return;
		const current = this.flow.completion.tags || [];
		const tags = current.includes(tag)
			? current.filter((currentTag) => currentTag !== tag)
			: [...current, tag];
		this.editCompletion({ tags });
	},

	discardSessionLocally() {
		if (this.flow.mode !== "completion_review" || this.discarding) return;
		this.discarding = true;
		const clientSessionId = this.clientSessionId;
		this.cancelWarmupTimeout();
		this.dispatchTrackerCommand("pose-tracker:stop");
		this.quiesceCompletedWorkout();
		this.inMemoryCompletionDraft = null;
		this.dispatchFlow({ type: "DISCARD_LOCAL" });

		let navigated = false;
		const clearTimer = this.clearTimeout || clearTimeout;
		const navigate = () => {
			if (navigated) return;
			navigated = true;
			if (this.discardNavigationTimeoutId) {
				clearTimer(this.discardNavigationTimeoutId);
				this.discardNavigationTimeoutId = null;
			}
			window.location.assign("/workouts");
		};
		const scheduleTimer = this.setTimeout || setTimeout;
		this.discardNavigationTimeoutId = scheduleTimer(
			navigate,
			DISCARD_NAVIGATION_DEADLINE_MS,
		);

		this.discardWrite = Promise.all([this.traceWrite, this.draftWrite])
			.then(async () => {
				const store = await this.storeReady;
				if (store) await store.discardSession(clientSessionId);
			})
			.catch(() => {
				this.traceRetentionAvailable = false;
			})
			.then(navigate);
	},

	canTogglePause() {
		return this.startTime !== null || this.countdownCount !== null;
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
		this.cancelWarmupTimeout();
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
		this.el.removeEventListener("input", this.onCompletionInput);
		this.el.removeEventListener("submit", this.onCompletionSubmit);
		if (this.saveNavigationTimeoutId) {
			clearTimeout(this.saveNavigationTimeoutId);
			this.saveNavigationTimeoutId = null;
		}
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
				break;
			case "startCamera":
				this.dispatchTrackerCommand("pose-tracker:start");
				break;
			case "stopCamera":
				this.dispatchTrackerCommand("pose-tracker:stop");
				break;
			case "armGesture":
				this.armPoseTrackerStep(
					command.step,
					command.step === "workout_start" ? 30 : 15,
				);
				break;
			case "disarmGesture":
				this.disarmPoseTrackerStep();
				break;
			case "startWarmupTimeout":
				this.startWarmupTimeout();
				break;
			case "pauseWarmupTimeout":
				this.pauseWarmupTimeout();
				break;
			case "resumeWarmupTimeout":
				this.resumeWarmupTimeout();
				break;
			case "cancelWarmupTimeout":
				this.cancelWarmupTimeout();
				break;
			case "startSegment":
				this.startSegment(command);
				break;
			case "showCompletion":
				this.cancelWarmupTimeout();
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

	startWarmupTimeout() {
		this.cancelWarmupTimeout();
		this.warmupTimeoutRemainingMs = 4_000;
		this.warmupTimeoutDeadline = performance.now() + 4_000;
		this.scheduleWarmupTimeout();
		this.renderWarmupTimeoutContinuously();
	},

	renderWarmupTimeoutContinuously() {
		this.renderWarmupTimeout();
		if (this.warmupTimeoutDeadline === null) return;
		this.warmupTimeoutRafId = requestAnimationFrame(() =>
			this.renderWarmupTimeoutContinuously(),
		);
	},

	scheduleWarmupTimeout() {
		if (this.warmupTimeoutDeadline === null) return;
		if (this.warmupTimeoutId) clearTimeout(this.warmupTimeoutId);
		this.warmupTimeoutId = setTimeout(
			() => this.finishWarmupTimeout(),
			this.warmupTimeoutRemainingMs,
		);
	},

	renderWarmupTimeout() {
		if (this.warmupTimeoutDeadline !== null) {
			this.warmupTimeoutRemainingMs = Math.min(
				this.warmupTimeoutRemainingMs,
				Math.max(this.warmupTimeoutDeadline - performance.now(), 0),
			);
		}
		const seconds = Math.max(
			1,
			Math.ceil(this.warmupTimeoutRemainingMs / 1_000),
		);
		const output = this.el.querySelector("#warmup-skip-seconds");
		if (output) output.textContent = String(seconds);
	},

	pauseWarmupTimeout() {
		if (this.warmupTimeoutDeadline === null) return;
		this.renderWarmupTimeout();
		this.warmupTimeoutDeadline = null;
		if (this.warmupTimeoutId) clearTimeout(this.warmupTimeoutId);
		if (this.warmupTimeoutRafId) {
			cancelAnimationFrame(this.warmupTimeoutRafId);
		}
		this.warmupTimeoutId = null;
		this.warmupTimeoutRafId = null;
	},

	resumeWarmupTimeout() {
		if (
			this.flow.mode !== "warmup_choice" ||
			this.warmupTimeoutDeadline !== null ||
			this.warmupTimeoutRemainingMs <= 0
		) {
			return;
		}
		this.warmupTimeoutDeadline =
			performance.now() + this.warmupTimeoutRemainingMs;
		this.scheduleWarmupTimeout();
		this.renderWarmupTimeoutContinuously();
	},

	finishWarmupTimeout() {
		if (this.flow.mode !== "warmup_choice") return;
		this.renderWarmupTimeout();
		this.dispatchFlow({
			type: "WARMUP_TIMEOUT",
			step: "warmup",
		});
	},

	cancelWarmupTimeout() {
		if (this.warmupTimeoutId) clearTimeout(this.warmupTimeoutId);
		if (this.warmupTimeoutRafId) {
			cancelAnimationFrame(this.warmupTimeoutRafId);
		}
		this.warmupTimeoutId = null;
		this.warmupTimeoutRafId = null;
		this.warmupTimeoutDeadline = null;
		this.warmupTimeoutRemainingMs = 0;
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
				this.renderRunningFrame(command.elapsedSec);
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
				const result =
					this.activeSegment === "workout"
						? this.workoutCompletionResult(command.result)
						: command.result;
				this.dispatchFlow({
					type: "SEGMENT_DONE",
					segment: this.activeSegment,
					result,
				});
				break;
			}
		}
	},

	onWarmupYes() {
		const warmupTimeline = warmupTimelineFromProgram(this.program);
		this.dispatchFlow({
			type: "WARMUP_READY",
			warmupTimeline,
			burpeeCountTarget: programBurpeeCount(warmupTimeline),
		});
	},

	onWarmupSkip() {
		this.dispatchFlow({ type: "WARMUP_SKIP" });
	},

	onWorkoutReady() {
		this.dispatchFlow({ type: "WORKOUT_READY" });
	},

	handlePoseGestureConfirm({ step }) {
		if (!step) return;
		this.dispatchFlow({
			type: "GESTURE_CONFIRM",
			step,
			warmupTimeline: warmupTimelineFromProgram(this.program),
			burpeeCountTarget: programBurpeeCount(
				warmupTimelineFromProgram(this.program),
			),
		});
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
		const countEl = this.el.querySelector("#count");
		if (countEl) {
			countEl.style.color = "";
			countEl.textContent = "—";
		}
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

	renderRunningFrame(elapsed) {
		const frame = currentFrame(this.timeline, elapsed);

		this.dispatchSegment({ type: "ACCOUNT_REPS", frame });
		this.syncRepStateFromSegment();
		const remainingReps = Math.max(
			(frame?.event?.reps || 0) - this.doneReps,
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
			totalDone: this.segment.reps.burpeeCountDone,
			totalTarget: this.segment.reps.burpeeCountTarget,
			doneInEvent: this.doneReps,
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
		this.resetPoseTracker();
		if (!this.rafId) this.rafId = requestAnimationFrame(() => this.tick());
		this.renderer.updatePauseButton(false);
		this.updatePauseActionsVisibility();
	},

	updatePauseActionsVisibility() {
		const actions = this.el.querySelector("#session-pause-actions");
		const finishEarlyBtn = this.el.querySelector("#finish-early-btn");
		const abortBtn = this.el.querySelector("#session-abort-btn");
		if (!actions) return;

		const isPaused = this.paused || this.countdownPaused;
		const canFinishEarly =
			this.paused &&
			!this.countdownPaused &&
			this.activeSegment === "workout" &&
			this.startTime !== null;
		actions.style.opacity = isPaused ? "1" : "0";
		actions.style.transform = isPaused ? "translateY(0)" : "";
		actions.style.pointerEvents = isPaused ? "auto" : "none";
		actions.setAttribute("aria-hidden", isPaused ? "false" : "true");

		if (isPaused) {
			actions.removeAttribute("inert");
			abortBtn?.removeAttribute("disabled");
		} else {
			actions.setAttribute("inert", "");
			abortBtn?.setAttribute("disabled", "disabled");
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

	observePoseRep({ index }) {
		const elapsedSec = this.segment.clock.elapsedSec || 0;
		const frame = currentFrame(this.timeline, elapsedSec);
		const eligible =
			this.activeSegment === "workout" &&
			this.segment.mode === "running" &&
			this.segment.clock.hiddenAt === null &&
			document.visibilityState === "visible" &&
			frame?.event?.kind === "work";

		this.tracking = observeTrackingRep(this.tracking, {
			index,
			elapsedMs: Math.max(0, Math.round(elapsedSec * 1_000)),
			eligible,
		});
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

	onFinishEarly() {
		if (
			this.activeSegment !== "workout" ||
			this.countdownCount !== null ||
			this.startTime === null
		)
			return;
		if (!confirm("End the session now and log what you've done so far?"))
			return;
		const elapsed = this.segment?.clock?.elapsedSec ?? 0;
		this.dispatchSegment({ type: "FINISH_EARLY", elapsedSec: elapsed });
	},

	syncRepStateFromSegment() {
		this.doneReps = this.segment.reps.doneInEvent;
	},
};

export default SessionHook;
