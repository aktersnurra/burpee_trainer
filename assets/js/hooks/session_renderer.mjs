const VISUAL_STATE_CLASSES = [
	"is-working",
	"is-rest-breathe",
	"is-rest-settle",
	"is-rest-countdown",
	"is-initial-countdown",
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
		const timeLeftEl = this.root.querySelector("#time-left");
		if (timeLeftEl) timeLeftEl.textContent = this.formatTime(timeLeftSec);
	}

	setVisualState(state) {
		if (this.appliedVisualState === state) return;

		const surface = this.root.querySelector("#session-runner-client");
		this.root.classList?.remove?.(...VISUAL_STATE_CLASSES);
		surface?.classList?.remove?.(...VISUAL_STATE_CLASSES);

		const className = {
			work: "is-working",
			"rest-breathe": "is-rest-breathe",
			"rest-settle": "is-rest-settle",
			"rest-countdown": "is-rest-countdown",
			"initial-countdown": "is-initial-countdown",
		}[state];

		if (className) {
			this.root.classList?.add?.(className);
			surface?.classList?.add?.(className);
		}

		this.appliedVisualState = state;
	}

	updateWorkFill(progress) {
		const fill = this.root.querySelector("#session-work-fill");
		if (!fill) return;
		const clamped = Math.min(Math.max(Number(progress) || 0, 0), 1);
		fill.style.transform = `scaleY(${clamped})`;
	}

	updateAccessibleState({ state, primaryCount }) {
		const target = this.root.querySelector("#ring-container");
		const status = this.root.querySelector("#session-accessible-status");
		const statusText =
			state === "work"
				? `${primaryCount} reps remaining`
				: state?.startsWith("rest-")
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

		if (paused) {
			this.clearTimers();
			if (countEl) {
				countEl.classList.remove("is-down-cue", "countdown-pop");
				countEl.style.visibility = "hidden";
			}
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			ringContainer?.classList.remove("is-down-cue-active");
			surface?.classList.add("is-paused");
		} else {
			if (pauseIcon) pauseIcon.style.display = "none";
			surface?.classList.remove("is-paused");
			if (countEl) countEl.style.visibility = "";
		}

		this.updateAccessibleState({
			state: this.currentVisualState,
			primaryCount: this.currentPrimaryCount,
		});
	}

	resetReady() {
		this.clearTimers();
		this.setVisualState(null);
		this.updateWorkFill(0);
		this.lastPulseValue = null;
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.classList.remove(
				"is-down-cue",
				"is-rest-time-long",
				"is-count-long",
				"is-countdown-dots",
				"is-between-set-pulse",
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
	}

	renderDisplayModel(model) {
		if (!model) return;
		const visual = model.visual || {
			state: "work",
			progress: 0,
			pulse: null,
		};
		this.currentVisualState = visual.state;
		this.currentPrimaryCount = model.primaryCount;
		this.updateAccessibleState({
			state: visual.state,
			primaryCount: model.primaryCount,
		});
		this.setVisualState(visual.state);

		if (visual.state === "initial-countdown") {
			this.lastPulseValue = null;
			this.renderCountdownDots(model.countdownDots || { count: 5, faded: 0 });
		} else if (visual.state === "work") {
			this.lastPulseValue = null;
			this.updateWorkFill(visual.progress);
			this.updateCurrentSetRepCount(model.primaryCount);
		} else if (
			["rest-breathe", "rest-settle", "rest-countdown"].includes(visual.state)
		) {
			this.updateWorkFill(0);
			this.renderRestState(model);
		}

		if (model.timeLeftSec !== undefined) this.renderTimer(model.timeLeftSec);
		if (model.totalDone !== undefined) this.updateTotalCounter(model.totalDone);
		if (model.totalTarget !== undefined)
			this.updateTotalGoal(model.totalTarget);
	}

	enterWorkPhase() {
		this.setVisualState("work");
		this.updateWorkFill(0);
		this.lastPulseValue = null;
	}

	enterCountInPhase() {
		this.setVisualState("initial-countdown");
		this.updateWorkFill(0);
		this.lastPulseValue = null;
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.classList.remove(
				"is-down-cue",
				"is-count-long",
				"is-between-set-pulse",
				"countdown-pop",
			);
			countEl.style.color = "";
			countEl.style.visibility = "";
		}
	}

	enterRestPhase() {
		this.setVisualState("rest-breathe");
		this.updateWorkFill(0);
	}

	renderRestState(model) {
		const count = this.root.querySelector("#count");
		if (!count) return;

		count.textContent = String(model.primaryCount ?? "");
		count.style.visibility = this.paused ? "hidden" : "";

		const pulse = model.visual?.pulse;
		if (model.visual?.state === "rest-countdown") {
			if (pulse !== this.lastPulseValue) {
				count.classList.remove("is-between-set-pulse", "countdown-pop");
				count.classList.add("is-between-set-pulse");
				void count.offsetWidth;
				count.classList.add("countdown-pop");
			}
		} else {
			count.classList.remove("is-between-set-pulse", "countdown-pop");
		}
		this.lastPulseValue = pulse;
	}

	renderRestProgress(timeLeftSec) {
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			const timeText = this.formatTime(timeLeftSec);
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
			"is-between-set-pulse",
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
		return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`;
	}
}
