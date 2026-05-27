import { SessionAudio } from "./session_audio.mjs";
import {
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";
import { SessionRenderer } from "./session_renderer.mjs";
import { SessionWakeLock } from "./session_wake_lock.mjs";

const CX = 140,
	CY = 140,
	R = 107;
const CIRC = 2 * Math.PI * R;
const NS = "http://www.w3.org/2000/svg";

const SessionHook = {
	mounted() {
		this.audio = new SessionAudio();
		this.renderer = new SessionRenderer(this.el);
		this.wakeLock = new SessionWakeLock();

		this.flow = initialFlowState();
		this.segment = initialSegmentState();
		this.activeSegment = null;
		this.timeline = [];
		this.startTime = null;
		this.paused = false;
		this.rafId = null;
		this.countdownPaused = false;
		this.countdownCount = null;
		this.countdownTimeoutId = null;
		this.countdownStepStarted = null;
		this.countdownStepElapsed = 0;

		this.doneReps = 0;
		this.countdownRingEl = null;
		this.hiddenAt = null;
		this.blockCount = 0;

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

		this.handleEvent("session_ready", ({ timeline, block_count }) => {
			this.dispatchFlow({
				type: "SESSION_READY",
				workoutTimeline: timeline,
				blockCount: block_count || 0,
			});
		});

		this.handleEvent("warmup_ready", ({ warmup, burpee_count_target }) => {
			this.dispatchFlow({
				type: "WARMUP_READY",
				warmupTimeline: warmup,
				burpeeCountTarget: burpee_count_target,
			});
		});

		this.el.addEventListener("click", (e) => {
			const warmupYes = e.target.closest("#warmup-yes-btn");
			const warmupSkip = e.target.closest("#warmup-skip-btn");
			const workoutReady = e.target.closest("#workout-ready-btn");
			const ringContainer = e.target.closest("#ring-container");
			const finishEarly = e.target.closest("#finish-early-btn");

			if (warmupYes) this.onWarmupYes();
			if (warmupSkip) this.onWarmupSkip();
			if (workoutReady) this.onWorkoutReady();
			if (
				ringContainer &&
				(this.startTime !== null || this.countdownCount !== null)
			)
				this.togglePause();
			if (finishEarly) this.onFinishEarly();
		});
	},

	destroyed() {
		if (this.rafId) cancelAnimationFrame(this.rafId);
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
			case "pushWarmupRequested":
				this.pushEvent("warmup_requested", {});
				break;
			case "startSegment":
				this.startSegment(command);
				break;
			case "showWarmupDonePrompt":
				this.showWarmupDonePrompt();
				break;
			case "pushSessionComplete":
				this.pushEvent("session_complete", command.payload);
				break;
		}
	},

	dispatchSegment(event) {
		const result = segmentTransition(this.segment, event);
		this.segment = result.state;
		this.timeline = this.segment.timeline;
		this.blockCount = this.segment.blockCount;
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
			case "renderProgressBar":
				this.renderer.renderProgressBar(command.percent, command.color);
				break;
			case "renderTimer":
				this.renderer.renderTimer(command.timeLeftSec);
				break;
			case "renderBlockLabel":
				this.renderer.renderBlockLabel(command.label);
				break;
			case "enterWorkPhase":
				this.renderer.enterWorkPhase();
				break;
			case "triggerDown":
				this.renderer.triggerDown(command.remainingReps);
				break;
			case "renderWorkRepProgress":
				this.renderer.updateWorkRing(command.progress, command.color);
				break;
			case "enterRestPhase":
				this.renderer.enterRestPhase();
				break;
			case "renderRestProgress":
				this.renderer.renderRestProgress(
					command.progress,
					command.color,
					command.timeLeftSec,
				);
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

	showWarmupPrompt() {},

	showWarmupDonePrompt() {
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
			"absolute inset-0 z-10 flex flex-col items-center justify-center gap-4 rounded-[2rem] bg-base-100/95 p-6 text-center shadow-2xl backdrop-blur-sm";
		overlay.replaceChildren();

		const title = document.createElement("span");
		title.className = "text-xl font-semibold tracking-tight";
		title.textContent = "Warmup complete";

		const description = document.createElement("p");
		description.className = "max-w-xs text-sm text-base-content/60";
		description.textContent =
			"Take a breath. Start the workout when you're ready.";

		const button = document.createElement("button");
		button.type = "button";
		button.id = "workout-ready-btn";
		button.className =
			"rounded-xl bg-primary px-8 py-4 text-sm font-semibold text-primary-content transition active:scale-[0.97] hover:brightness-110";
		button.textContent = "Start workout";

		overlay.append(title, description, button);
		parent.appendChild(overlay);
	},

	onWarmupYes() {
		this.dispatchFlow({ type: "WARMUP_YES" });
	},

	onWarmupSkip() {
		this.dispatchFlow({ type: "WARMUP_SKIP" });
	},

	onWorkoutReady() {
		this.dispatchFlow({ type: "WORKOUT_READY" });
	},

	countdownColor(n) {
		return (
			["#EF4444", "#F97316", "#F97316", "#F59E0B", "#F59E0B"][n] || "#F59E0B"
		);
	},

	startCountdown() {
		this.audio.ensureRunning();
		this.wakeLock.acquire();

		const overlay = this.el.querySelector("#start-overlay");
		if (overlay) overlay.remove();

		const svgEl = this.el.querySelector("#ring-svg");
		if (svgEl) {
			while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
			const cdRing = document.createElementNS(NS, "circle");
			cdRing.setAttribute("cx", CX);
			cdRing.setAttribute("cy", CY);
			cdRing.setAttribute("r", R);
			cdRing.setAttribute("fill", "none");
			cdRing.setAttribute("stroke-width", "16");
			cdRing.setAttribute("stroke-linecap", "round");
			cdRing.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
			cdRing.setAttribute("stroke-dasharray", CIRC.toFixed(4));
			cdRing.setAttribute("stroke-dashoffset", "0");
			cdRing.setAttribute("stroke", this.countdownColor(5));
			svgEl.appendChild(cdRing);
			this.countdownRingEl = cdRing;
		}

		const countEl = this.el.querySelector("#count");
		if (countEl) countEl.style.visibility = "";

		const showCount = (value, animate) => {
			const color = this.countdownColor(value);

			if (countEl) {
				countEl.textContent = value;
				countEl.style.color = color;
				countEl.classList.remove("countdown-pop");
				void countEl.offsetWidth;
				countEl.classList.add("countdown-pop");
			}

			if (this.countdownRingEl) {
				const remaining = value / 5;
				this.countdownRingEl.style.transition = animate
					? "stroke-dashoffset 0.8s ease-out, stroke 0.3s"
					: "none";
				this.countdownRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
				this.countdownRingEl.setAttribute(
					"stroke-dashoffset",
					(CIRC * (1 - remaining)).toFixed(4),
				);
				this.countdownRingEl.setAttribute("stroke", color);
			}
		};

		this.countdownShowCount = showCount;
		this.countdownCount = 5;
		showCount(5, false);
		this.audio.playLeadBeep();
		this.scheduleCountdownTick(4);
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
		this.countdownTimeoutId = null;
		this.countdownStepStarted = null;
		const countEl = this.el.querySelector("#count");
		if (countEl) {
			countEl.style.color = "#C8D8F0";
			countEl.textContent = "—";
		}
	},

	beginSegment() {
		this.dispatchSegment({
			type: "COUNTDOWN_DONE",
			now: performance.now(),
		});

		const finishEarlyBtn = this.el.querySelector("#finish-early-btn");
		if (finishEarlyBtn) {
			if (this.activeSegment === "workout") {
				finishEarlyBtn.removeAttribute("disabled");
			} else {
				finishEarlyBtn.setAttribute("disabled", "disabled");
			}
		}

		this.countdownRingEl = null;
		const firstEvent = this.timeline[0];
		const isFirstWork =
			firstEvent &&
			(firstEvent.type === "work_burpee" ||
				firstEvent.type === "warmup_burpee");
		if (isFirstWork) {
			this.renderer.buildWorkRing();
			this.renderer.triggerDown(firstEvent.burpee_count);
		}

		this.startTime = this.segment.clock.startTime;
	},

	startSegment({ segment, timeline, blockCount, burpeeCountTarget }) {
		this.activeSegment = segment;
		this.segment = initialSegmentState();
		this.dispatchSegment({
			type: "SEGMENT_READY",
			timeline,
			blockCount,
			burpeeCountTarget,
		});
		this.dispatchSegment({ type: "COUNTDOWN_START", now: performance.now() });
	},

	tick() {
		const now = performance.now();
		const elapsed = (now - this.startTime) / 1000;
		this.dispatchSegment({ type: "TICK", elapsedSec: elapsed });
	},

	renderRunningFrame(elapsed) {
		const frame = currentFrame(this.timeline, elapsed);

		this.dispatchSegment({ type: "ACCOUNT_REPS", frame });
		this.syncRepStateFromSegment();
		this.dispatchSegment({
			type: "DISPLAY_FRAME",
			frame,
			elapsedSec: elapsed,
			totalDurationSec: this.segment.clock.totalDurationSec,
			blockCount: this.blockCount,
			doneInEvent: this.doneReps,
		});
		this.dispatchSegment({ type: "BEEP_FRAME", frame });
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
		this.audio.stop();
		this.renderer.updatePauseButton(true);
	},

	resumeCountdown() {
		this.dispatchSegment({ type: "COUNTDOWN_RESUME", now: performance.now() });
		this.countdownPaused = false;
		this.renderer.updatePauseButton(false);

		const n = this.countdownCount;
		if (n === null) return;

		this.countdownShowCount(n, false);
		const remaining = Math.max(1000 - (this.countdownStepElapsed || 0), 0);
		this.scheduleCountdownTick(n - 1, remaining);
	},

	pause() {
		if (this.paused) return;
		this.dispatchSegment({ type: "PAUSE", now: performance.now() });
		this.paused = true;
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.audio.stop();
		this.renderer.updatePauseButton(true);
	},

	resume() {
		if (!this.paused) return;
		this.dispatchSegment({ type: "RESUME", now: performance.now() });
		this.startTime = this.segment.clock.startTime;
		this.paused = false;
		this.hiddenAt = null;
		this.rafId = requestAnimationFrame(() => this.tick());
		this.renderer.updatePauseButton(false);
	},

	onFinishEarly() {
		if (this.activeSegment !== "workout") return;
		if (!confirm("End the session now and log what you've done so far?"))
			return;
		const elapsed = (performance.now() - this.startTime) / 1000;
		this.dispatchSegment({ type: "FINISH_EARLY", elapsedSec: elapsed });
	},

	syncRepStateFromSegment() {
		this.doneReps = this.segment.reps.doneInEvent;
	},
};

export default SessionHook;
