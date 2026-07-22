const VISUAL_STATE_CLASSES = [
	"is-working",
	"is-work-active",
	"is-work-recovery",
	"is-rest",
	"is-rest-count-in",
	"is-count-in",
];

export class SessionRenderer {
	constructor(root) {
		this.root = root;
		this.lastDisplayed = -1;
		this.downTimeout = null;
		this.downCueActive = false;
		this.paused = false;
		this.lastPulseValue = null;
		this.appliedVisualState = undefined;
	}

	clearTimers() {
		if (this.downTimeout) clearTimeout(this.downTimeout);
		this.downTimeout = null;
		this.downCueActive = false;
	}

	renderTimer(timeLeftSec) {
		const formattedTime = this.formatTime(timeLeftSec);
		const accessibleTime = this.root.querySelector("#session-time-accessible");
		if (accessibleTime) {
			accessibleTime.textContent = `Session time remaining ${formattedTime}`;
		}
	}

	updateSessionProgress(progress) {
		const track = this.root.querySelector("#session-progress");
		const fill = this.root.querySelector("#session-progress-fill");
		const numericProgress = Number(progress);
		const visible = progress != null && Number.isFinite(numericProgress);
		const clampedProgress = visible
			? Math.min(Math.max(numericProgress, 0), 1)
			: 0;

		if (track) track.hidden = !visible;
		if (fill) fill.style.transform = `scaleX(${clampedProgress})`;
	}

	setVisualState(state) {
		if (this.appliedVisualState === state) return;

		const surface = this.root.querySelector("#session-runner-client");
		this.root.classList?.remove?.(...VISUAL_STATE_CLASSES);
		surface?.classList?.remove?.(...VISUAL_STATE_CLASSES);

		const classNames = {
			work: ["is-working", "is-work-active"],
			work_active: ["is-working", "is-work-active"],
			work_recovery: ["is-working", "is-work-recovery"],
			rest: ["is-rest"],
			rest_count_in: ["is-rest-count-in"],
			count_in: ["is-count-in"],
		}[state];

		if (classNames) {
			this.root.classList?.add?.(...classNames);
			surface?.classList?.add?.(...classNames);
		}

		this.appliedVisualState = state;
	}

	updateWorkFill(progress, activeRatio = 1) {
		const fill = this.root.querySelector("#session-work-fill");
		const surface = this.root.querySelector("#session-runner-client");
		if (!fill) return;

		const clampedProgress = Math.min(Math.max(Number(progress) || 0, 0), 1);
		const clampedActiveRatio = Math.min(
			Math.max(Number(activeRatio) || 0, 0),
			1,
		);
		const clip = `inset(${(1 - clampedProgress) * 100}% 0 0 0)`;
		fill.style.clipPath = clip;
		fill.style.webkitClipPath = clip;
		surface?.style?.setProperty(
			"--session-active-ratio",
			`${clampedActiveRatio * 100}%`,
		);
	}

	updateAccessibleState({ state, primaryCount, setProgress }) {
		const target = this.root.querySelector("#ring-container");
		const status = this.root.querySelector("#session-accessible-status");
		const accessibleSetProgress = this.formatSetProgress(setProgress);
		const statusText =
			["work", "work_active", "work_recovery"].includes(state)
				? `${primaryCount} reps remaining`
				: state === "rest"
					? `Rest${
							accessibleSetProgress
								? `, set progress ${accessibleSetProgress}`
								: ""
						}`
					: state === "rest_count_in"
						? `Rest time remaining ${primaryCount}`
						: "Workout starting";

		if (target) {
			target.setAttribute(
				"aria-label",
				this.paused ? "Resume session" : "Pause session",
			);
		}
		if (status && status.textContent !== statusText) {
			status.textContent = statusText;
		}
	}

	updatePauseButton(paused) {
		this.paused = paused;
		const pauseIcon = this.root.querySelector("#pause-icon");
		const countEl = this.root.querySelector("#count");
		const downEl = this.root.querySelector("#down-word");
		const ringContainer = this.root.querySelector("#ring-container");
		const surface = this.root.querySelector("#session-runner-client");
		const setProgress = this.root.querySelector("#set-progress");
		const totalReps = this.root.querySelector("#total-reps");
		const totalSeparator = this.root.querySelector("#total-separator");
		const totalPlan = this.root.querySelector("#total-plan");

		if (paused) {
			this.clearTimers();
			if (countEl) {
				countEl.classList.remove("is-down-cue", "countdown-pop");
				countEl.style.visibility = "hidden";
			}
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			if (totalReps) totalReps.hidden = false;
			if (totalSeparator) totalSeparator.hidden = false;
			if (totalPlan) totalPlan.hidden = false;
			ringContainer?.classList.remove("is-down-cue-active");
			if (setProgress) setProgress.hidden = true;
			surface?.classList.add("is-paused");
		} else {
			if (pauseIcon) pauseIcon.style.display = "none";
			if (totalReps) totalReps.hidden = false;
			if (totalSeparator) totalSeparator.hidden = true;
			if (totalPlan) totalPlan.hidden = true;
			surface?.classList.remove("is-paused");
			if (countEl) countEl.style.visibility = "";
			this.updateSetProgress(this.currentSetProgress);
		}

		this.updateAccessibleState({
			state: this.currentVisualState,
			primaryCount: this.currentPrimaryCount,
			setProgress: this.currentSetProgress,
		});
	}

	resetReady() {
		this.clearTimers();
		this.setVisualState(null);
		this.updateSessionProgress(null);
		this.updateWorkFill(0);
		this.lastPulseValue = null;
		this.currentSetProgress = null;
		this.updateSetProgress(null);
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.classList.remove(
				"is-down-cue",
				"is-rest-time-long",
				"is-count-long",
				"is-countdown-dots",
				"countdown-pop",
			);
			countEl.textContent = "—";
			countEl.style.visibility = "";
			countEl.style.color = "";
		}
		const downEl = this.root.querySelector("#down-word");
		if (downEl) downEl.style.display = "none";
		const pauseIcon = this.root.querySelector("#pause-icon");
		if (pauseIcon) pauseIcon.style.display = "none";
		const totalReps = this.root.querySelector("#total-reps");
		const totalSeparator = this.root.querySelector("#total-separator");
		const totalPlan = this.root.querySelector("#total-plan");
		if (totalReps) totalReps.hidden = true;
		if (totalSeparator) totalSeparator.hidden = true;
		if (totalPlan) totalPlan.hidden = true;
	}

	renderDisplayModel(model) {
		if (!model) return;
		const visual = model.visual || {
			state: "work_active",
			progress: 0,
			pulse: null,
		};
		this.currentVisualState = visual.state;
		this.currentPrimaryCount = model.primaryCount;
		this.currentSetProgress = model.setProgress;
		this.updateAccessibleState({
			state: visual.state,
			primaryCount: model.primaryCount,
			setProgress: model.setProgress,
		});
		this.setVisualState(visual.state);
		this.updateSessionProgress(model.sessionProgress);

		if (visual.state === "count_in") {
			this.lastPulseValue = null;
			this.renderCountdownDots(model.countdownDots || { count: 5, faded: 0 });
		} else if (["work", "work_active", "work_recovery"].includes(visual.state)) {
			this.lastPulseValue = null;
			this.updateWorkFill(visual.progress, visual.activeRatio);
			this.updateCurrentSetRepCount(model.primaryCount);
		} else if (["rest", "rest_count_in"].includes(visual.state)) {
			this.updateWorkFill(0);
			this.renderRestState(model);
		}

		this.updateSetProgress(model.setProgress);
		if (model.timeLeftSec !== undefined) this.renderTimer(model.timeLeftSec);
		if (model.totalDone !== undefined) {
			this.updateTotalCounter(model.totalDone);
			const totalReps = this.root.querySelector("#total-reps");
			if (totalReps) totalReps.hidden = false;
		}
		if (model.totalTarget !== undefined)
			this.updateTotalGoal(model.totalTarget);
	}

	enterWorkPhase() {
		this.setVisualState("work_active");
		this.updateWorkFill(0);
		this.updateSetProgress(null);
		this.lastPulseValue = null;
	}

	enterCountInPhase() {
		this.setVisualState("count_in");
		this.updateWorkFill(0);
		this.updateSetProgress(null);
		this.lastPulseValue = null;
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.classList.remove("is-down-cue", "is-count-long", "countdown-pop");
			countEl.style.color = "";
			countEl.style.visibility = "";
		}
	}

	enterRestPhase() {
		this.setVisualState("rest");
		this.updateWorkFill(0);
	}

	renderRestState(model) {
		const count = this.root.querySelector("#count");
		if (!count) return;

		count.classList.remove(
			"is-down-cue",
			"is-count-long",
			"is-countdown-dots",
			"countdown-pop",
		);
		count.textContent = String(model.primaryCount ?? "");
		count.style.visibility = this.paused ? "hidden" : "";
		this.lastPulseValue = null;
	}

	updateSetProgress(value) {
		const setProgress = this.root.querySelector("#set-progress");
		if (!setProgress) return;

		setProgress.textContent = value ?? "";
		setProgress.hidden = this.paused || value == null;
	}

	renderRestProgress(timeLeftSec) {
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			const timeText = this.formatClock(timeLeftSec);
			countEl.classList.remove(
				"is-down-cue",
				"is-rest-time-long",
				"is-count-long",
				"is-countdown-dots",
			);
			countEl.style.visibility = "";
			countEl.textContent = timeText;
			countEl.style.color = "";
		}
		const downEl = this.root.querySelector("#down-word");
		if (downEl) downEl.style.display = "none";
	}

	triggerDown(repsLeft) {
		this.clearTimers();
		const countEl = this.root.querySelector("#count");
		const downEl = this.root.querySelector("#down-word");
		if (!countEl) return;

		if (downEl) downEl.style.display = "none";
		this.downCueActive = true;
		const ringContainer = this.root.querySelector("#ring-container");
		if (ringContainer) ringContainer.classList.add("is-down-cue-active");
		countEl.classList.remove(
			"is-rest-time-long",
			"is-count-long",
			"is-countdown-dots",
		);
		countEl.classList.add("is-down-cue");
		countEl.textContent = "DOWN";
		countEl.style.color = "";
		countEl.style.visibility = "";
		countEl.classList.remove("countdown-pop");
		void countEl.offsetWidth;
		countEl.classList.add("countdown-pop");

		this.downTimeout = setTimeout(() => {
			this.downTimeout = null;
			this.downCueActive = false;
			if (ringContainer) ringContainer.classList.remove("is-down-cue-active");
			if (!this.paused) this.updateCurrentSetRepCount(repsLeft);
		}, 650);
	}

	updateCurrentSetRepCount(repsLeft) {
		if (this.downCueActive) return;
		const countEl = this.root.querySelector("#count");
		if (!countEl) return;
		countEl.classList.remove(
			"is-down-cue",
			"is-rest-time-long",
			"is-countdown-dots",
			"countdown-pop",
		);
		this.setCountLengthClass(countEl, String(repsLeft));
		countEl.textContent = repsLeft;
		countEl.style.color = "";
		countEl.style.visibility = this.paused ? "hidden" : "";
		this.lastDisplayed = repsLeft;
	}

	setCountLengthClass(countEl, text) {
		if (String(text).length >= 3) {
			countEl.classList.add("is-count-long");
		} else {
			countEl.classList.remove("is-count-long");
		}
	}

	updateTotalCounter(n) {
		const el = this.root.querySelector("#total-done");
		if (!el) return;
		el.textContent = n;
		el.style.color = "";
		this.updateTotalAccessibility();
	}

	updateTotalGoal(n) {
		const counter = this.root.querySelector("#total-done");
		if (counter?.dataset) counter.dataset.totalPlan = n;
		const el = this.root.querySelector("#total-plan");
		if (el) el.textContent = n;
		this.updateTotalCounter(
			Number.parseInt(counter?.textContent || "0", 10) || 0,
		);
	}

	updateTotalAccessibility() {
		const done = this.root.querySelector("#total-done")?.textContent;
		const target = this.root.querySelector("#total-plan")?.textContent;
		const accessibleTotal = this.root.querySelector("#total-reps-accessible");
		if (accessibleTotal && done !== "" && target !== "") {
			accessibleTotal.textContent = `${done} of ${target} total reps`;
		}
	}

	renderCountdownDots({ count, faded }) {
		const countEl = this.root.querySelector("#count");
		if (!countEl) return;

		while (countEl.firstChild) countEl.removeChild(countEl.firstChild);
		countEl.textContent = "";
		countEl.classList.add("is-countdown-dots");

		const documentRef = countEl.ownerDocument || globalThis.document;
		if (!documentRef) return;

		for (let index = 0; index < count; index += 1) {
			const dot = documentRef.createElement("span");
			dot.className = "countdown-dot";
			if (index < faded) dot.className += " is-faded";
			countEl.appendChild(dot);
		}
	}

	formatTime(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return `${m}:${String(r).padStart(2, "0")}`;
	}

	formatClock(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return `${m}:${String(r).padStart(2, "0")}`;
	}

	formatSetProgress(value) {
		const match = String(value ?? "").match(/^(\d+)\/(\d+)$/);
		return match ? `${match[1]} of ${match[2]}` : null;
	}
}
