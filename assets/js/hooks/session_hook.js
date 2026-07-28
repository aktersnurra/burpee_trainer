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
import {
	finishTrackingObserver,
	initialTrackingObserver,
	observeTrackingRep,
	startTrackingObserver,
	updateTrackingReadiness,
	updateTrackingStatus,
} from "./pose_tracking_observer.mjs";

const SessionHook = {
	mounted() {
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
		});

		this.el.addEventListener("keydown", (e) => {
			const ringContainer = e.target.closest("#ring-container");
			if (!ringContainer || !isPauseToggleKey(e) || !this.canTogglePause())
				return;

			e.preventDefault();
			if (!e.repeat) this.togglePause();
		});
	},

	canTogglePause() {
		return this.startTime !== null || this.countdownCount !== null;
	},

	activeRuntimeForFlow() {
		return (
			(this.flow.mode === "warmup_running" &&
				this.activeSegment === "warmup") ||
			(this.flow.mode === "workout_running" &&
				this.activeSegment === "workout")
		);
	},

	destroyed() {
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
			return { ...timerResult, cadenceMs: [] };
		}
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
