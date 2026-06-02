const CX = 140,
	CY = 140,
	R = 107;
const CIRC = 2 * Math.PI * R;
const NS = "http://www.w3.org/2000/svg";

export class SessionRenderer {
	constructor(root) {
		this.root = root;
		this.workRingEl = null;
		this.restRingEl = null;
		this.lastDisplayed = -1;
		this.downTimeout = null;
	}

	clearTimers() {
		if (this.downTimeout) clearTimeout(this.downTimeout);
		this.downTimeout = null;
	}

	renderProgressBar(percent, color) {
		const fill = this.root.querySelector("#progress-fill");
		if (!fill) return;
		fill.style.width = percent.toFixed(1) + "%";
		fill.style.backgroundColor = color;
	}

	renderTimer(timeLeftSec) {
		const timeLeftEl = this.root.querySelector("#time-left");
		if (timeLeftEl) timeLeftEl.textContent = this.formatTime(timeLeftSec);
	}

	renderBlockLabel(label) {
		const blockInfo = this.root.querySelector("#block-info");
		if (blockInfo) blockInfo.textContent = label;
	}

	setMode(mode) {
		const ringContainer = this.root.querySelector("#ring-container");
		if (!ringContainer) return;
		ringContainer.classList.remove(
			"is-working",
			"is-resting",
			"is-counting-in",
		);
		if (mode) ringContainer.classList.add(mode);
	}

	depletingOffset(progress) {
		const clampedProgress = Math.min(Math.max(progress, 0), 1);
		return CIRC * clampedProgress;
	}

	updatePauseButton(paused) {
		const pauseIcon = this.root.querySelector("#pause-icon");
		const countEl = this.root.querySelector("#count");
		const downEl = this.root.querySelector("#down-word");
		const ringContainer = this.root.querySelector("#ring-container");

		if (paused) {
			if (countEl) countEl.style.visibility = "hidden";
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			if (ringContainer) {
				ringContainer.style.opacity = "0.6";
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

	enterWorkPhase() {
		this.setMode("is-working");
		this.buildWorkRing();
	}

	enterCountInPhase() {
		this.setMode("is-counting-in");
		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.style.color = "#070707";
			countEl.style.visibility = "";
		}
	}

	enterRestPhase() {
		this.setMode("is-resting");
		const svgEl = this.root.querySelector("#ring-svg");
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
	}

	renderRestProgress(progress, color, timeLeftSec) {
		const offset = this.depletingOffset(progress);
		if (this.restRingEl) {
			this.restRingEl.setAttribute("stroke", color);
			this.restRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
			this.restRingEl.setAttribute("stroke-dashoffset", offset.toFixed(4));
		}

		const countEl = this.root.querySelector("#count");
		if (countEl) {
			countEl.style.visibility = "";
			countEl.textContent = this.formatTime(timeLeftSec);
			countEl.style.color = color;
		}
		const downEl = this.root.querySelector("#down-word");
		if (downEl) downEl.style.display = "none";
	}

	buildWorkRing() {
		this.lastDisplayed = -1;
		const svgEl = this.root.querySelector("#ring-svg");
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
	}

	updateWorkRing(repProgress, color) {
		if (!this.workRingEl) return;
		const offset = this.depletingOffset(repProgress);
		this.workRingEl.setAttribute("stroke", color);
		this.workRingEl.setAttribute("stroke-dasharray", CIRC.toFixed(4));
		this.workRingEl.setAttribute("stroke-dashoffset", offset.toFixed(4));
	}

	triggerDown(repsLeft) {
		this.clearTimers();
		const countEl = this.root.querySelector("#count");
		const downEl = this.root.querySelector("#down-word");
		if (!countEl || !downEl) return;

		countEl.style.visibility = "hidden";
		downEl.style.display = "";

		this.downTimeout = setTimeout(() => {
			this.downTimeout = null;
			downEl.style.display = "none";
			this.updateCurrentSetRepCount(repsLeft);
		}, 350);
	}

	updateCurrentSetRepCount(repsLeft) {
		const countEl = this.root.querySelector("#count");
		if (!countEl) return;
		countEl.textContent = repsLeft;
		countEl.style.color = "#C8D8F0";
		countEl.style.visibility = "";
		this.lastDisplayed = repsLeft;
	}

	triggerFlash() {
		const flashEl = this.root.querySelector("#flash-circle");
		if (!flashEl) return;
		flashEl.style.transition = "none";
		flashEl.setAttribute("opacity", "0.5");
		requestAnimationFrame(() =>
			requestAnimationFrame(() => {
				flashEl.style.transition = "opacity 0.2s ease-out";
				flashEl.setAttribute("opacity", "0");
			}),
		);
	}

	updateTotalCounter(n) {
		const el = this.root.querySelector("#total-done");
		if (!el) return;
		el.textContent = n;
		el.style.color = "#FFFFFF";
		setTimeout(() => {
			el.style.color = "";
		}, 160);
	}

	updateTotalGoal(n) {
		const el = this.root.querySelector("#total-plan");
		if (!el) return;
		el.textContent = n;
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
					mark.style.background = "#070707";
				} else if (
					index === block.completedSets &&
					block.currentSetProgress !== null
				) {
					const pct = Math.round(
						Math.min(Math.max(block.currentSetProgress, 0), 1) * 100,
					);
					mark.style.background = `linear-gradient(to top, #070707 ${pct}%, #ddd6c7 ${pct}%)`;
				} else {
					mark.style.background = "#ddd6c7";
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
