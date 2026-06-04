import {
	appendSessionRing,
	clearRing,
	updateSessionRing,
} from "./session_ring.mjs";

const SESSION_INK = "var(--session-ink)";
const SESSION_TRACK = "var(--session-track)";

export class SessionRenderer {
	constructor(root) {
		this.root = root;
		this.workRingEl = null;
		this.lastDisplayed = -1;
		this.downTimeout = null;
		this.downCueActive = false;
		this.paused = false;
		this.currentMode = null;
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

	setMode(mode) {
		const ringContainer = this.root.querySelector("#ring-container");
		const phaseLabel = this.root.querySelector("#phase-label");
		const sessionSurface = this.root.querySelector("#session-runner-client");
		if (!ringContainer) return;
		this.root.classList?.remove?.("is-working", "is-resting", "is-counting-in");
		sessionSurface?.classList?.remove?.(
			"is-working",
			"is-resting",
			"is-counting-in",
		);
		ringContainer.classList.remove(
			"is-working",
			"is-resting",
			"is-counting-in",
		);
		if (phaseLabel) {
			phaseLabel.classList.remove("is-counting-in");
			if (mode === "is-counting-in") phaseLabel.classList.add("is-counting-in");
		}
		if (mode) {
			this.root.classList?.add?.(mode);
			sessionSurface?.classList?.add?.(mode);
			ringContainer.classList.add(mode);
		}
		if (mode !== this.currentMode) {
			this.workRingEl = null;
		}
		this.currentMode = mode;
	}

	updatePauseButton(paused) {
		this.paused = paused;
		const pauseIcon = this.root.querySelector("#pause-icon");
		const countEl = this.root.querySelector("#count");
		const downEl = this.root.querySelector("#down-word");
		const ringContainer = this.root.querySelector("#ring-container");

		if (paused) {
			this.clearTimers();
			if (countEl) {
				countEl.classList.remove("is-down-cue", "countdown-pop");
				countEl.style.visibility = "hidden";
			}
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			if (ringContainer) {
				ringContainer.style.opacity = "0.6";
				ringContainer.classList.remove("is-down-cue-active");
				ringContainer.classList.add("is-paused");
			}
		} else {
			if (pauseIcon) pauseIcon.style.display = "none";
			if (ringContainer) {
				ringContainer.style.opacity = "";
				ringContainer.classList.remove("is-paused");
			}
			if (countEl) countEl.style.visibility = "";
		}
	}

	resetReady() {
		this.clearTimers();
		this.setMode(null);
		const svgEl = this.root.querySelector("#ring-svg");
		if (svgEl) clearRing(svgEl);
		this.workRingEl = null;
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
		this.renderSetGlyphs([]);
	}

	renderDisplayModel(model) {
		if (!model) return;
		if (model.mode === "rest") {
			this.enterRestPhase();
			this.renderRestProgress(model.restTimeLeftSec ?? 0);
		} else {
			if (model.mode === "countdown") {
				this.enterCountInPhase();
			} else {
				this.setMode("is-working");
				this.ensureWorkRing();
				this.updateWorkRing(model.ring?.progress || 0, null);
				this.updateCurrentSetRepCount(model.primaryCount);
			}
		}

		this.renderPhaseLabel(model.phaseLabel || "");
		if (model.timeLeftSec !== undefined) this.renderTimer(model.timeLeftSec);
		if (model.totalDone !== undefined) this.updateTotalCounter(model.totalDone);
		if (model.totalTarget !== undefined)
			this.updateTotalGoal(model.totalTarget);
		if (model.mode === "countdown" && model.countdownDots) {
			this.renderCountdownDots(model.countdownDots);
		} else {
			this.renderSetGlyphs(model.setGlyphs || []);
		}
	}

	renderPhaseLabel(label) {
		const el = this.root.querySelector("#phase-label");
		if (el) el.textContent = label;
	}

	enterWorkPhase() {
		this.setMode("is-working");
		this.buildWorkRing();
	}

	enterCountInPhase() {
		this.setMode("is-counting-in");
		this.clearWorkRing();
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.classList.remove("is-down-cue", "is-count-long", "countdown-pop");
			countEl.style.color = "";
			countEl.style.visibility = "";
		}
	}

	enterRestPhase() {
		this.setMode("is-resting");
		this.clearWorkRing();
	}

	clearWorkRing() {
		const svgEl = this.root.querySelector("#ring-svg");
		if (svgEl) clearRing(svgEl);
		this.workRingEl = null;
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

	buildWorkRing() {
		this.lastDisplayed = -1;
		const svgEl = this.root.querySelector("#ring-svg");
		if (!svgEl) return;
		this.workRingEl = appendSessionRing(svgEl);
	}

	ensureWorkRing() {
		if (!this.workRingEl) this.buildWorkRing();
	}

	updateWorkRing(repProgress, _color) {
		if (!this.workRingEl) return;
		updateSessionRing(this.workRingEl, repProgress);
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

	triggerFlash() {
		const flashEl = this.root.querySelector("#flash-circle");
		if (!flashEl) return;
		flashEl.style.display = "block";
		flashEl.style.transition = "none";
		flashEl.setAttribute("opacity", "0.5");
		requestAnimationFrame(() =>
			requestAnimationFrame(() => {
				flashEl.style.transition = "opacity 0.2s ease-out";
				flashEl.setAttribute("opacity", "0");
				setTimeout(() => {
					flashEl.style.display = "none";
				}, 220);
			}),
		);
	}

	updateTotalCounter(n) {
		const el = this.root.querySelector("#total-done");
		if (!el) return;
		el.textContent = n;
		el.style.color = "";
	}

	updateTotalGoal(n) {
		const el = this.root.querySelector("#total-plan");
		if (el) el.textContent = n;
	}

	renderCountdownDots({ count, faded }) {
		const countEl = this.root.querySelector("#count");
		const glyphsEl = this.root.querySelector("#set-glyphs");
		if (!countEl) return;

		if (glyphsEl) {
			while (glyphsEl.firstChild) glyphsEl.removeChild(glyphsEl.firstChild);
		}
		while (countEl.firstChild) countEl.removeChild(countEl.firstChild);
		countEl.textContent = "";
		countEl.classList.add("is-countdown-dots");

		for (let index = 0; index < count; index += 1) {
			const dot = document.createElement("span");
			dot.className = "countdown-dot";
			if (index < faded) dot.className += " is-faded";
			countEl.appendChild(dot);
		}
	}

	renderSetGlyphs(blocks) {
		const container = this.root.querySelector("#set-glyphs");
		if (!container) return;

		while (container.firstChild) container.removeChild(container.firstChild);

		blocks.forEach((block) => {
			const group = document.createElement("div");
			group.className = "flex items-end gap-1";

			for (let index = 0; index < block.setCount; index += 1) {
				const mark = document.createElement("span");
				mark.className = "block w-[7px] h-[22px]";

				if (index < block.completedSets) {
					mark.style.background = SESSION_INK;
				} else if (
					index === block.completedSets &&
					block.currentSetProgress !== null
				) {
					const pct = Math.round(
						Math.min(Math.max(block.currentSetProgress, 0), 1) * 100,
					);
					mark.style.background = `linear-gradient(to top, ${SESSION_INK} ${pct}%, ${SESSION_TRACK} ${pct}%)`;
				} else {
					mark.style.background = SESSION_TRACK;
				}

				group.appendChild(mark);
			}

			container.appendChild(group);
		});
	}

	formatTime(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return m > 0 ? `${m}:${String(r).padStart(2, "0")}` : `${r}`;
	}
}
