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
				if (!this.paused && this.hiddenAt !== null && this.startTime !== null) {
					this.dispatchSegment({
						type: "VISIBILITY_VISIBLE",
						now: performance.now(),
					});
					this.startTime = this.segment.clock.startTime;
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

		this.handleEvent("session_ready", (payload) => {
			this.program = payload;
			this.renderer.resetReady();
			this.dispatchFlow({
				type: "SESSION_READY",
				workoutTimeline: workoutTimelineFromProgram(payload),
			});
		});

		this.el.addEventListener("click", (e) => {
			const warmupYes = e.target.closest("#warmup-yes-btn");
			const warmupSkip = e.target.closest("#warmup-skip-btn");
			const workoutReady = e.target.closest("#workout-ready-btn");
			const captureTracked = e.target.closest("#capture-tracked-btn");
			const captureTimed = e.target.closest("#capture-timed-btn");
			const cameraSetupStart = e.target.closest("#camera-setup-start-btn");
			const ringContainer = e.target.closest("#ring-container");
			const finishEarly = e.target.closest("#finish-early-btn");

			if (warmupYes) this.onWarmupYes();
			if (warmupSkip) this.onWarmupSkip();
			if (workoutReady) this.onWorkoutReady();
			if (captureTracked) this.onCaptureTracked();
			if (captureTimed) this.onCaptureTimed();
			if (cameraSetupStart) this.onCameraSetupStart();
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

	destroyed() {
		if (this.rafId) cancelAnimationFrame(this.rafId);
		if (this.countdownRafId) cancelAnimationFrame(this.countdownRafId);
		if (this.countdownTimeoutId) clearTimeout(this.countdownTimeoutId);
		this.renderer.clearTimers();
		this.audio.stop();
		document.removeEventListener("visibilitychange", this.onVisibility);
		document.removeEventListener("click", this.primeAudio, { capture: true });
		document.removeEventListener("touchstart", this.primeAudio, {
			capture: true,
		});
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
			case "renderPrompt":
				this.showWarmupPrompt();
				break;
			case "startSegment":
				this.startSegment(command);
				break;
			case "showWarmupDonePrompt":
				this.showWarmupDonePrompt();
				break;
			case "showWorkoutReadyPrompt":
				this.showWorkoutReadyPrompt();
				break;
			case "showCapturePrompt":
				this.showCapturePrompt();
				break;
			case "showCameraSetupPrompt":
				this.showCameraSetupPrompt();
				break;
			case "chooseTrackedCapture":
				this.pushEvent("choose_tracked", {});
				break;
			case "pushSessionComplete":
				if (this.pushTrackedFinish(command.payload)) {
					break;
				}
				this.pushEvent("session_complete", command.payload);
				break;
		}
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
			case "segmentDone":
				this.dispatchFlow({
					type: "SEGMENT_DONE",
					segment: this.activeSegment,
					result: command.result,
				});
				break;
		}
	},

	showWarmupPrompt() {
		this.renderer.resetReady();
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.rafId = null;
		this.audio.stop();
		this.startTime = null;
		this.countdownCount = null;
		this.countdownPaused = false;

		const parent = this.el.querySelector("#session-runner-client") || this.el;
		let overlay = this.el.querySelector("#start-overlay");

		if (!overlay) {
			overlay = document.createElement("div");
			overlay.id = "start-overlay";
		}

		overlay.className =
			"absolute inset-0 z-10 flex flex-col items-center justify-center gap-6 bg-[var(--session-bg)] p-5 text-center text-[var(--session-ink)] sm:p-8";
		overlay.replaceChildren();

		const title = document.createElement("h1");
		title.className =
			"qs-heading-tight text-[clamp(2.75rem,10vw,4.75rem)] font-medium leading-[0.98]";
		title.textContent = "Warm up first?";

		const description = document.createElement("p");
		description.className =
			"max-w-lg text-lg leading-relaxed text-[var(--session-muted)]";
		description.textContent =
			"Start with a short warmup, or skip straight to the workout.";

		const buttons = document.createElement("div");
		buttons.className = "grid w-full max-w-lg grid-cols-1 gap-3 sm:grid-cols-2";

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

	showCapturePrompt() {
		this.renderer.resetReady();
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.rafId = null;
		this.audio.stop();
		this.startTime = null;
		this.countdownCount = null;
		this.countdownPaused = false;

		const parent = this.el.querySelector("#session-runner-client") || this.el;
		let overlay = this.el.querySelector("#start-overlay");

		if (!overlay) {
			overlay = document.createElement("div");
			overlay.id = "start-overlay";
		}

		overlay.className =
			"absolute inset-0 z-10 flex flex-col items-center justify-center gap-6 bg-[var(--session-bg)] p-5 text-center text-[var(--session-ink)] sm:p-8";
		overlay.replaceChildren();

		const title = document.createElement("h1");
		title.className =
			"qs-heading-tight text-[clamp(2.75rem,10vw,4.75rem)] font-medium leading-[0.98]";
		title.textContent = "Track your workout?";

		const description = document.createElement("p");
		description.className =
			"max-w-lg text-lg leading-relaxed text-[var(--session-muted)]";
		description.textContent =
			"Use camera tracking for pace and rep detection, or run the session with the timer only.";

		const buttons = document.createElement("div");
		buttons.className = "grid w-full max-w-lg grid-cols-1 gap-3 sm:grid-cols-2";

		const yes = document.createElement("button");
		yes.type = "button";
		yes.id = "capture-tracked-btn";
		yes.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-6 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]";
		yes.textContent = "Use camera";

		const no = document.createElement("button");
		no.type = "button";
		no.id = "capture-timed-btn";
		no.className =
			"min-h-14 w-full rounded-xl border border-[var(--session-border)] bg-transparent px-6 py-4 text-base font-medium text-[var(--session-muted)] transition hover:border-[var(--session-ink)] hover:text-[var(--session-ink)] active:scale-[0.98]";
		no.textContent = "Timer only";

		buttons.append(yes, no);
		overlay.append(title, description, buttons);
		parent.appendChild(overlay);
	},

	showCameraSetupPrompt() {
		this.renderer.resetReady();
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.rafId = null;
		this.audio.stop();
		this.startTime = null;
		this.countdownCount = null;
		this.countdownPaused = false;

		const overlay = this.el.querySelector("#start-overlay");
		if (!overlay) return;

		overlay.className = "hidden";
		overlay.replaceChildren();
	},

	showWarmupDonePrompt() {
		this.showWorkoutStartPrompt(
			"Warmup complete",
			"Take a breath. Start the workout when you're ready.",
		);
	},

	showWorkoutReadyPrompt() {
		this.showWorkoutStartPrompt(
			"Ready when you are",
			"Start the workout when you're ready.",
		);
	},

	showWorkoutStartPrompt(_titleText, _descriptionText) {
		this.renderer.resetReady();
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.rafId = null;
		this.audio.stop();
		this.startTime = null;
		this.countdownCount = null;
		this.countdownPaused = false;

		const parent = this.el.querySelector("#session-runner-client") || this.el;
		let overlay = this.el.querySelector("#start-overlay");

		if (!overlay) {
			overlay = document.createElement("div");
			overlay.id = "start-overlay";
		}

		overlay.className =
			"absolute inset-0 z-10 flex flex-col items-center justify-center gap-6 bg-[var(--session-bg)] p-5 text-center text-[var(--session-ink)] sm:p-8";
		overlay.replaceChildren();

		const meta = document.createElement("p");
		meta.className =
			"text-xs font-semibold uppercase tracking-[0.2em] text-[var(--session-muted)]";
		meta.textContent = "Ready when you are";

		const title = document.createElement("h1");
		title.id = "start-overlay-title";
		title.className =
			"qs-heading-tight max-w-xl text-[clamp(2.75rem,10vw,4.75rem)] font-medium leading-[0.98]";
		title.textContent = "Start when you’re ready.";

		const button = document.createElement("button");
		button.type = "button";
		button.id = "workout-ready-btn";
		button.className =
			"mt-2 min-h-14 w-full max-w-lg rounded-xl border border-[var(--session-ink)] bg-[var(--session-ink)] px-8 py-4 text-base font-medium text-[var(--session-bg)] transition hover:opacity-90 active:scale-[0.98]";
		button.textContent = "Start workout";

		overlay.append(meta, title, button);
		parent.appendChild(overlay);
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

	onCaptureTracked() {
		this.dispatchFlow({ type: "CAPTURE_TRACKED" });
	},

	onCaptureTimed() {
		this.dispatchFlow({ type: "CAPTURE_TIMED" });
	},

	onCameraSetupStart() {
		const cameraVisibility = this.el.querySelector("#pose-tracker-visibility");
		if (cameraVisibility) {
			cameraVisibility.style.visibility = "hidden";
			cameraVisibility.style.opacity = "0";
			cameraVisibility.style.pointerEvents = "none";
			cameraVisibility.setAttribute("aria-hidden", "true");
		}

		this.pushEvent("camera_setup_started", {});
		this.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	},

	startCountdown() {
		this.audio.ensureRunning();
		this.wakeLock.acquire();

		const overlay = this.el.querySelector("#start-overlay");
		if (overlay) overlay.remove();

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
		this.dispatchSegment({
			type: "COUNTDOWN_DONE",
			now: performance.now(),
		});

		this.updatePauseActionsVisibility();

		this.startTime = this.segment.clock.startTime;
	},

	startSegment({ segment, timeline, burpeeCountTarget }) {
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
		this.triggerDownCueForFrame(frame, model.primaryCount);

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

	pushTrackedFinish(payload) {
		const tracker = this.el.querySelector("#pose-tracker");
		if (
			!tracker ||
			tracker.dataset?.poseTrackerReady !== "true" ||
			!payload?.main
		)
			return false;

		tracker.dispatchEvent(
			new CustomEvent("pose-tracker:finish", {
				detail: { durationMs: Math.round(payload.main.duration_sec * 1000) },
			}),
		);
		return true;
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
