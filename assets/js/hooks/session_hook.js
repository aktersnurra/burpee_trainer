import { SessionAudio } from "./session_audio.mjs";
import {
	currentFrame,
	initialSessionState,
	transition,
} from "./session_fsm.mjs";
import { SessionWakeLock } from "./session_wake_lock.mjs";

// SessionHook — client-driven session runtime.
//
// The server pushes a flat timeline on mount ("session_ready"). The client
// owns the clock (performance.now + requestAnimationFrame), state machine,
// beeps, and all high-frequency DOM updates. The server is idle during the
// workout and only involved at save time.
//
// Events sent TO the server:
//   warmup_requested  — user tapped Yes on warmup prompt
//   session_started   — user picked mood, session begins
//   session_complete  — workout finished; carries main + warmup counts
//
// Events received FROM the server:
//   session_ready     — initial main timeline
//   warmup_ready      — warmup timeline prepended on Yes

const CX = 140,
	CY = 140,
	R = 107;
const CIRC = 2 * Math.PI * R;
const NS = "http://www.w3.org/2000/svg";

const SessionHook = {
	mounted() {
		this.audio = new SessionAudio();
		this.wakeLock = new SessionWakeLock();

		this.fsm = initialSessionState();
		this.timeline = [];
		this.startTime = null;
		this.paused = false;
		this.rafId = null;
		this.countdownPaused = false;
		this.countdownCount = null;
		this.countdownTimeoutId = null;
		this.countdownStepStarted = null; // performance.now() when the current step began
		this.countdownStepElapsed = 0; // ms elapsed in the current step when paused

		this.warmupBurpeeCount = 0;
		this.mainBurpeeCount = 0;

		this.workRingEl = null;
		this.doneReps = 0;
		this.downTimeout = null;
		this.lastDisplayed = -1;
		this.restRingEl = null;
		this.countdownRingEl = null;

		this.hiddenAt = null; // track when tab went hidden for pause accounting

		this.onVisibility = () => {
			if (document.visibilityState === "hidden") {
				// Screen locked / tab backgrounded — pause the clock silently.
				if (!this.paused && this.startTime !== null) {
					this.dispatchSession({
						type: "VISIBILITY_HIDDEN",
						now: performance.now(),
					});
					this.hiddenAt = this.fsm.clock.hiddenAt;
					if (this.rafId) cancelAnimationFrame(this.rafId);
					this.rafId = null;
					this.audio.stop();
				}
			} else {
				// Tab visible again — absorb the gap into startTime so elapsed is unaffected.
				if (!this.paused && this.hiddenAt !== null && this.startTime !== null) {
					this.dispatchSession({
						type: "VISIBILITY_VISIBLE",
						now: performance.now(),
					});
					this.startTime = this.fsm.clock.startTime;
				}
				this.hiddenAt = null;
				this.wakeLock.reacquireWhenVisible();
				// Restart the RAF loop if we were running.
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

		this.blockCount = 0;

		this.handleEvent("session_ready", ({ timeline, block_count }) => {
			this.dispatchSession({
				type: "SESSION_READY",
				timeline,
				blockCount: block_count || 0,
			});
		});

		this.handleEvent("warmup_ready", ({ warmup }) => {
			this.dispatchSession({ type: "WARMUP_READY", warmup });
		});

		// Event delegation on the outer hook element — survives LiveView re-renders
		// because the hook root (#burpee-session) is never replaced.
		this.el.addEventListener("click", (e) => {
			const warmupYes = e.target.closest("#warmup-yes-btn");
			const warmupSkip = e.target.closest("#warmup-skip-btn");
			const ringContainer = e.target.closest("#ring-container");
			const finishEarly = e.target.closest("#finish-early-btn");

			if (warmupYes) this.onWarmupYes();
			if (warmupSkip) this.onWarmupSkip();
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
		if (this.downTimeout) clearTimeout(this.downTimeout);
		this.audio.stop();
		document.removeEventListener("visibilitychange", this.onVisibility);
		document.removeEventListener("click", this.primeAudio, { capture: true });
		document.removeEventListener("touchstart", this.primeAudio, {
			capture: true,
		});
		this.wakeLock.release();
		this.audio.close();
	},

	// ---------------------------------------------------------------------------
	// Session flow
	// ---------------------------------------------------------------------------

	dispatchSession(event) {
		const result = transition(this.fsm, event);
		this.fsm = result.state;
		this.timeline = this.fsm.timeline;
		this.blockCount = this.fsm.blockCount;
		result.commands.forEach((command) => this.runSessionCommand(command));
	},

	runSessionCommand(command) {
		switch (command.type) {
			case "renderPrompt":
				this.showWarmupPrompt();
				break;
			case "pushWarmupRequested":
				this.pushEvent("warmup_requested", {});
				break;
			case "renderMoodPrompt":
				this.showMoodPicker();
				break;
			case "pushSessionStarted":
				this.pushEvent("session_started", { mood: command.mood });
				break;
			case "startCountdownTimer":
				this.startCountdown();
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
			case "beginSession":
				this.beginSession();
				break;
			case "renderRunningFrame":
				this.renderRunningFrame(command.elapsedSec);
				break;
			case "updateVisibleRepTotal":
				this.mainBurpeeCount = command.mainDone;
				this.updateTotalCounter(command.mainDone);
				break;
			case "renderProgressBar":
				this.renderProgressBar(command.percent, command.color);
				break;
			case "renderTimer":
				this.renderTimer(command.timeLeftSec);
				break;
			case "renderBlockLabel":
				this.renderBlockLabel(command.label);
				break;
			case "enterWorkPhase":
				this.enterWorkPhase();
				break;
			case "triggerDown":
				this.triggerDown(command.remainingReps);
				break;
			case "renderWorkRepProgress":
				this.updateWorkRing(command.progress, command.color);
				break;
			case "enterRestPhase":
				this.enterRestPhase();
				break;
			case "renderRestProgress":
				this.renderRestProgress(
					command.progress,
					command.color,
					command.timeLeftSec,
				);
				break;
			case "scheduleAnimationFrame":
				this.rafId = requestAnimationFrame(() => this.tick());
				break;
			case "completeWorkout":
				this.onComplete(command.elapsedSec);
				break;
			case "playCompletionFanfare":
				this.audio.playCompletionFanfare();
				break;
			case "pushSessionComplete":
				this.pushEvent("session_complete", command.payload);
				break;
		}
	},

	showWarmupPrompt() {
		// Overlay is already rendered by the server; nothing to do here.
	},

	onWarmupYes() {
		this.dispatchSession({ type: "WARMUP_YES" });
		// server responds with warmup_ready → mood picker
	},

	onWarmupSkip() {
		this.dispatchSession({ type: "WARMUP_SKIP" });
	},

	showMoodPicker() {
		const overlay = this.el.querySelector("#start-overlay");
		if (!overlay) return;

		const moodIcons = {
			"-1": `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M15.182 16.318A4.486 4.486 0 0 0 12.016 15a4.486 4.486 0 0 0-3.198 1.318M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0ZM9.75 9.75c0 .414-.168.75-.375.75S9 10.164 9 9.75 9.168 9 9.375 9s.375.336.375.75Zm-.375 0h.008v.015h-.008V9.75Zm5.625 0c0 .414-.168.75-.375.75s-.375-.336-.375-.75.168-.75.375-.75.375.336.375.75Zm-.375 0h.008v.015h-.008V9.75Z" /></svg>`,
			0: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="M15 12H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" /></svg>`,
			1: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-6"><path stroke-linecap="round" stroke-linejoin="round" d="m3.75 13.5 10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75Z" /></svg>`,
		};

		// Patch the overlay in-place — delegation on the hook root catches the clicks.
		overlay.innerHTML = `
      <span class="text-xl font-semibold tracking-tight">How do you feel?</span>
      <div class="flex gap-3">
        ${[
					["Tired", "-1"],
					["OK", "0"],
					["Hyped", "1"],
				]
					.map(
						([label, val]) => `
          <button type="button" data-mood="${val}"
            class="flex flex-col items-center gap-1.5 rounded-xl border border-[#1E2535] px-5 py-3 text-sm font-medium transition active:scale-[0.97] hover:bg-[#181C26]">
            ${moodIcons[val]}
            <span>${label}</span>
          </button>
        `,
					)
					.join("")}
      </div>
    `;

		// Delegation won't reach data-mood — wire these directly since the overlay is JS-owned.
		overlay.querySelectorAll("[data-mood]").forEach((btn) => {
			btn.addEventListener("click", () => {
				const mood = btn.getAttribute("data-mood");
				this.dispatchSession({
					type: "MOOD_SELECTED",
					mood,
					now: performance.now(),
				});
			});
		});
	},

	// Show a 5-4-3-2-1 countdown overlay before the workout clock begins.
	// Color ramp: 5=amber, 4=amber-orange, 3=orange, 2=orange-red, 1=red
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

		// Build a single amber ring in #ring-svg for the countdown
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

		const showCount = (n, animate) => {
			const color = this.countdownColor(n);

			if (countEl) {
				countEl.textContent = n;
				countEl.style.color = color;
				countEl.classList.remove("countdown-pop");
				void countEl.offsetWidth;
				countEl.classList.add("countdown-pop");
			}

			if (this.countdownRingEl) {
				const remaining = n / 5;
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

		// Render 5 with no transition — ring stays full, no animation flash.
		this.countdownCount = 5;
		showCount(5, false);
		this.audio.playLeadBeep();
		this.scheduleCountdownTick(4);
	},

	scheduleCountdownTick(n, delayMs = 1000) {
		this.countdownStepStarted = performance.now();
		this.countdownTimeoutId = setTimeout(() => {
			if (this.countdownPaused) return;
			this.dispatchSession({
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

	beginSession() {
		const result = transition(this.fsm, {
			type: "COUNTDOWN_DONE",
			now: performance.now(),
		});
		this.fsm = result.state;

		const finishEarlyBtn = this.el.querySelector("#finish-early-btn");
		if (finishEarlyBtn) finishEarlyBtn.removeAttribute("disabled");

		// Clear countdown ring; build work ring for the first event
		this.countdownRingEl = null;
		const firstEvent = this.timeline[0];
		const isFirstWork =
			firstEvent &&
			(firstEvent.type === "work_burpee" ||
				firstEvent.type === "warmup_burpee");
		if (isFirstWork) {
			this.buildWorkRing();
			this.triggerDown(firstEvent.burpee_count);
		}

		this.startTime = performance.now();
		this.rafId = requestAnimationFrame(() => this.tick());
	},

	// ---------------------------------------------------------------------------
	// Clock loop
	// ---------------------------------------------------------------------------

	tick() {
		const now = performance.now();
		const elapsed = (now - this.startTime) / 1000;
		this.dispatchSession({ type: "TICK", elapsedSec: elapsed });
	},

	renderRunningFrame(elapsed) {
		const frame = currentFrame(this.timeline, elapsed);

		this.dispatchSession({ type: "ACCOUNT_REPS", frame });
		this.syncRepStateFromFsm();
		this.dispatchSession({
			type: "DISPLAY_FRAME",
			frame,
			elapsedSec: elapsed,
			totalDurationSec: this.fsm.clock.totalDurationSec,
			blockCount: this.blockCount,
			doneInEvent: this.doneReps,
		});
		this.dispatchSession({ type: "BEEP_FRAME", frame });
	},

	// ---------------------------------------------------------------------------
	// Pause / resume
	// ---------------------------------------------------------------------------

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
		this.dispatchSession({ type: "COUNTDOWN_PAUSE", now: performance.now() });
		this.countdownPaused = true;
		if (this.countdownTimeoutId) {
			clearTimeout(this.countdownTimeoutId);
			this.countdownTimeoutId = null;
		}
		// Record how much of the current 1-second step has already elapsed.
		this.countdownStepElapsed = this.fsm.countdown.stepElapsedMs;
		this.audio.stop();
		this.updatePauseBtn(true);
	},

	resumeCountdown() {
		this.dispatchSession({ type: "COUNTDOWN_RESUME", now: performance.now() });
		this.countdownPaused = false;
		this.updatePauseBtn(false);

		const n = this.countdownCount;
		if (n === null) return;

		// Show the current number and wait only the remaining portion of its second.
		this.countdownShowCount(n, false);
		const remaining = Math.max(1000 - (this.countdownStepElapsed || 0), 0);
		this.scheduleCountdownTick(n - 1, remaining);
	},

	pause() {
		if (this.paused) return;
		this.dispatchSession({ type: "PAUSE", now: performance.now() });
		this.paused = true;
		if (this.rafId) cancelAnimationFrame(this.rafId);
		this.audio.stop();
		this.updatePauseBtn(true);
	},

	resume() {
		if (!this.paused) return;
		this.dispatchSession({ type: "RESUME", now: performance.now() });
		this.startTime = this.fsm.clock.startTime;
		this.paused = false;
		this.hiddenAt = null;
		this.rafId = requestAnimationFrame(() => this.tick());
		this.updatePauseBtn(false);
	},

	updatePauseBtn(paused) {
		const pauseIcon = this.el.querySelector("#pause-icon");
		const countEl = this.el.querySelector("#count");
		const downEl = this.el.querySelector("#down-word");
		const ringContainer = this.el.querySelector("#ring-container");

		if (paused) {
			if (countEl) countEl.style.visibility = "hidden";
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			if (ringContainer) ringContainer.style.opacity = "0.6";
		} else {
			if (pauseIcon) pauseIcon.style.display = "none";
			if (ringContainer) ringContainer.style.opacity = "";
			if (countEl) countEl.style.visibility = "";
		}
	},

	onFinishEarly() {
		if (!confirm("End the session now and log what you've done so far?"))
			return;
		const elapsed = (performance.now() - this.startTime) / 1000;
		this.dispatchSession({ type: "FINISH_EARLY", elapsedSec: elapsed });
	},

	syncRepStateFromFsm() {
		this.mainBurpeeCount = this.fsm.reps.mainDone;
		this.warmupBurpeeCount = this.fsm.reps.warmupDone;
		this.doneReps = this.fsm.reps.doneInEvent;
	},

	// ---------------------------------------------------------------------------
	// UI updates (direct DOM writes for high-frequency elements)
	// ---------------------------------------------------------------------------

	renderProgressBar(percent, color) {
		const fill = this.el.querySelector("#progress-fill");
		if (!fill) return;
		fill.style.width = percent.toFixed(1) + "%";
		fill.style.backgroundColor = color;
	},

	renderTimer(timeLeftSec) {
		const timeLeftEl = this.el.querySelector("#time-left");
		if (timeLeftEl) timeLeftEl.textContent = this.formatTime(timeLeftSec);
	},

	renderBlockLabel(label) {
		const blockInfo = this.el.querySelector("#block-info");
		if (blockInfo) blockInfo.textContent = label;
	},

	enterWorkPhase() {
		this.buildWorkRing();
	},

	enterRestPhase() {
		const svgEl = this.el.querySelector("#ring-svg");
		if (svgEl) {
			while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);
			const restRing = document.createElementNS(NS, "circle");
			restRing.setAttribute("cx", CX);
			restRing.setAttribute("cy", CY);
			restRing.setAttribute("r", R);
			restRing.setAttribute("fill", "none");
			restRing.setAttribute("stroke-width", "16");
			restRing.setAttribute("stroke-linecap", "round");
			restRing.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
			svgEl.appendChild(restRing);
			this.restRingEl = restRing;
		}
	},

	renderRestProgress(progress, color, timeLeftSec) {
		const offset = CIRC * (1 - Math.min(progress, 1));
		if (this.restRingEl) {
			this.restRingEl.setAttribute("stroke", color);
			this.restRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
			this.restRingEl.setAttribute("stroke-dashoffset", offset.toFixed(4));
		}

		const countEl = this.el.querySelector("#count");
		if (countEl) {
			countEl.style.visibility = "";
			countEl.textContent = this.formatTime(timeLeftSec);
			countEl.style.color = color;
		}
		const downEl = this.el.querySelector("#down-word");
		if (downEl) downEl.style.display = "none";
	},

	// ---------------------------------------------------------------------------
	// Work ring — single arc that fills continuously per rep, resets each rep
	// ---------------------------------------------------------------------------

	buildWorkRing() {
		this.doneReps = 0;
		this.lastDisplayed = -1;
		const svgEl = this.el.querySelector("#ring-svg");
		if (!svgEl) return;
		while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);

		const ring = document.createElementNS(NS, "circle");
		ring.setAttribute("cx", CX);
		ring.setAttribute("cy", CY);
		ring.setAttribute("r", R);
		ring.setAttribute("fill", "none");
		ring.setAttribute("stroke-width", "16");
		ring.setAttribute("stroke-linecap", "round");
		ring.setAttribute("transform", `rotate(-90 ${CX} ${CY})`);
		ring.setAttribute("stroke-dasharray", CIRC.toFixed(4));
		ring.setAttribute("stroke-dashoffset", CIRC.toFixed(4));
		svgEl.appendChild(ring);
		this.workRingEl = ring;
	},

	updateWorkRing(repProgress, color) {
		if (!this.workRingEl) return;
		const offset = CIRC * (1 - Math.min(repProgress, 1));
		this.workRingEl.setAttribute("stroke", color);
		this.workRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
		this.workRingEl.setAttribute("stroke-dashoffset", offset.toFixed(4));
	},

	triggerDown(repsLeft) {
		if (this.downTimeout) clearTimeout(this.downTimeout);
		const countEl = this.el.querySelector("#count");
		const downEl = this.el.querySelector("#down-word");
		if (!countEl || !downEl) return;

		// Hard cut: hide count, show "Down" instantly
		countEl.style.visibility = "hidden";
		downEl.style.display = "";

		this.downTimeout = setTimeout(() => {
			this.downTimeout = null;
			// Hard cut: hide "Down", show new count
			downEl.style.display = "none";
			countEl.textContent = repsLeft;
			countEl.style.color = "#C8D8F0";
			countEl.style.visibility = "";
			this.lastDisplayed = repsLeft;
		}, 350);
	},

	triggerFlash() {
		const flashEl = this.el.querySelector("#flash-circle");
		if (!flashEl) return;
		flashEl.style.transition = "none";
		flashEl.setAttribute("opacity", "0.5");
		requestAnimationFrame(() =>
			requestAnimationFrame(() => {
				flashEl.style.transition = "opacity 0.2s ease-out";
				flashEl.setAttribute("opacity", "0");
			}),
		);
	},

	updateTotalCounter(n) {
		const el = this.el.querySelector("#total-done");
		if (!el) return;
		el.textContent = n;
		el.style.color = "#FFFFFF";
		setTimeout(() => {
			el.style.color = "";
		}, 160);
	},

	// ---------------------------------------------------------------------------
	// Completion
	// ---------------------------------------------------------------------------

	onComplete(elapsed) {
		this.dispatchSession({ type: "ACCOUNT_REPS", frame: null });
		this.syncRepStateFromFsm();
		this.dispatchSession({ type: "COMPLETE_SESSION", elapsedSec: elapsed });
	},

	// ---------------------------------------------------------------------------
	// Helpers
	// ---------------------------------------------------------------------------

	formatTime(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`;
	},
};

export default SessionHook;
