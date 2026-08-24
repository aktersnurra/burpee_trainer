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
		this.visiblePanelId = undefined;
	}

	clearTimers() {
		if (this.downTimeout) clearTimeout(this.downTimeout);
		this.downTimeout = null;
		this.downCueActive = false;
	}

	renderFlowState(state) {
		const visibleId = {
			capture_choice: "session-capture-choice",
			camera_starting: "session-camera-status",
			camera_error: "session-camera-status",
			camera_setup: "session-camera-setup",
			warmup_choice: "session-warmup-choice",
			warmup_running: "session-runner-client",
			workout_ready: "session-workout-ready",
			workout_running: "session-runner-client",
			reporting_completion: "session-completion-review",
			completion_pending_failed: "session-completion-review",
			completion_review: "session-completion-review",
		}[state.mode];

		for (const panel of this.root.querySelectorAll("[data-session-panel]")) {
			const visible = panel.id === visibleId;
			panel.hidden = !visible;
			panel.toggleAttribute("inert", !visible);
		}

		this.renderCameraStatus(state);
		this.renderCameraSetup(state);
		this.renderCaptureControls(state);
		this.renderReportPendingStatus(state);
		if (visibleId !== this.visiblePanelId) {
			this.visiblePanelId = visibleId;
			this.focusPanelHeading(visibleId);
		}
		if (state.mode === "camera_starting") {
			this.announce("Starting camera");
		} else if (state.mode === "camera_error") {
			this.announce("Camera unavailable");
		} else if (state.mode === "reporting_completion") {
			this.announce("Preparing workout report");
		} else if (state.mode === "completion_pending_failed") {
			this.announce("Could not prepare workout report. Try again.");
		} else if (
			state.mode === "completion_review" &&
			state.saveStatus === "saving"
		) {
			this.announce("Saving session");
		} else if (state.mode === "completion_review") {
			this.announce("Workout complete");
		} else if (state.mode === "persisted") {
			this.announce("Session saved");
		}
	}

	renderCameraSetup(state) {
		const arming = this.root.querySelector("#camera-setup-arming");
		const ready = this.root.querySelector("#camera-setup-ready");
		const cameraReady = ["ready", "optimal"].includes(state.camera?.readiness);

		if (arming) {
			arming.hidden = cameraReady;
			arming.toggleAttribute("inert", cameraReady);
		}
		if (ready) {
			ready.hidden = !cameraReady;
			ready.toggleAttribute("inert", !cameraReady);
		}
	}

	renderCameraStatus(state) {
		const starting = this.root.querySelector("#camera-status-starting");
		const error = this.root.querySelector("#camera-status-error");
		const failed = state.mode === "camera_error";
		if (starting) {
			starting.hidden = failed;
			starting.toggleAttribute("inert", failed);
		}
		if (error) {
			error.hidden = !failed;
			error.toggleAttribute("inert", !failed);
		}
	}

	renderReportPendingStatus(state) {
		const failed = state.mode === "completion_pending_failed";
		const status = this.root.querySelector("#session-report-pending-status");
		const retry = this.root.querySelector("#session-report-pending-retry");

		if (status) {
			status.hidden = !failed;
			status.toggleAttribute("inert", !failed);
		}
		if (retry) {
			retry.hidden = !failed;
			retry.toggleAttribute("inert", !failed);
		}
	}

	clearBeginConflict() {
		const conflict = this.root.querySelector("#session-begin-conflict");
		if (!conflict) return;

		conflict.hidden = true;
		conflict.toggleAttribute("inert", true);
	}

	renderBeginConflict(reply = {}) {
		const conflict = this.root.querySelector("#session-begin-conflict");
		const message = this.root.querySelector("#session-begin-conflict-message");
		const resolve = this.root.querySelector("#session-begin-conflict-resolve");
		const text =
			reply.message ||
			"Finish or discard your current workout before starting another one.";

		if (message) message.textContent = text;
		if (resolve && reply.resolve_to)
			resolve.setAttribute("href", reply.resolve_to);
		if (conflict) {
			conflict.hidden = false;
			conflict.toggleAttribute("inert", false);
		}
		this.announce(text);
	}

	renderCaptureControls(state) {
		const manual = state.captureMode === "no_camera";
		const manualWarmup = this.root.querySelector("#warmup-manual-controls");
		const trackedWarmup = this.root.querySelector(
			"#warmup-tracked-instruction",
		);
		const warmupCountdown = this.root.querySelector("#warmup-skip-countdown");
		const manualStart = this.root.querySelector("#workout-ready-btn");
		const trackedStart = this.root.querySelector("#workout-ready-instruction");
		const cameraEscape = this.root.querySelector("#workout-ready-continue");

		for (const element of [manualWarmup, manualStart]) {
			if (!element) continue;
			element.hidden = !manual;
			element.toggleAttribute("inert", !manual);
		}
		for (const element of [
			trackedWarmup,
			warmupCountdown,
			trackedStart,
			cameraEscape,
		]) {
			if (!element) continue;
			element.hidden = manual;
			element.toggleAttribute("inert", manual);
		}
	}

	announce(text) {
		const status = this.root.querySelector("#session-live-status");
		if (status && status.textContent !== text) status.textContent = text;
	}

	focusPanelHeading(panelId) {
		if (!panelId) return;
		this.root
			.querySelector(`#${panelId} [data-session-heading]`)
			?.focus({ preventScroll: true });
	}

	renderCompletion(completion) {
		if (!completion) return;
		const actualReps = this.root.querySelector("#session-actual-reps");
		const plannedReps = this.root.querySelector("#session-planned-reps");
		const duration = this.root.querySelector("#session-actual-duration");
		const repsInput = this.root.querySelector("#completion-reps-input");
		const durationInput = this.root.querySelector("#completion-duration-input");
		const noteInput = this.root.querySelector("#completion-note-input");
		const hasActualReps = Number.isInteger(completion.burpeeCountActual);
		const countProvenance = completion.burpeeCountProvenance ??
			(hasActualReps ? "manual" : "unresolved");
		const scheduledRepsDone = completion.scheduledRepsDone ?? 0;
		const countSource = this.root.querySelector("#session-count-source");
		if (actualReps) {
			actualReps.textContent = hasActualReps
				? String(completion.burpeeCountActual)
				: "—";
		}
		if (plannedReps)
			plannedReps.textContent = String(completion.burpeeCountPlanned);
		if (duration)
			duration.textContent = this.formatTime(completion.durationSecActual);
		if (repsInput)
			repsInput.value = hasActualReps ? String(completion.burpeeCountActual) : "";
		if (countSource) {
			countSource.textContent =
				countProvenance === "camera_confirmed"
					? "Camera-confirmed reps"
					: countProvenance === "manual"
						? "Manually entered reps"
						: `Pace progress: ${scheduledRepsDone} of ${completion.burpeeCountPlanned}. Enter actual reps below.`;
			countSource.hidden = false;
		}
		if (durationInput)
			durationInput.value = String(completion.durationSecActual);
		if (noteInput) noteInput.value = completion.notePost || "";

		for (const button of this.root.querySelectorAll("[data-mood]")) {
			button.setAttribute(
				"aria-pressed",
				String(Number(button.dataset.mood) === completion.mood),
			);
		}
		for (const button of this.root.querySelectorAll("[data-tag]")) {
			button.setAttribute(
				"aria-pressed",
				String((completion.tags || []).includes(button.dataset.tag)),
			);
		}
	}

	clearSaveErrors() {
		const fields = [
			["#completion-reps-error", "#completion-reps-input"],
			["#completion-duration-error", "#completion-duration-input"],
			["#completion-note-error", "#completion-note-input"],
		];
		for (const [errorSelector, inputSelector] of fields) {
			const error = this.root.querySelector(errorSelector);
			if (error) {
				error.textContent = "";
				error.hidden = true;
			}
			this.root.querySelector(inputSelector)?.removeAttribute("aria-invalid");
		}

		const global = this.root.querySelector("#session-save-errors");
		if (global) {
			global.textContent = "";
			global.hidden = true;
			global.classList.add("hidden");
		}
	}

	renderSaveErrors(reply = {}) {
		this.clearSaveErrors();
		const fieldMessages = [];
		const fields = {
			burpee_count_actual: ["#completion-reps-error", "#completion-reps-input"],
			duration_sec_actual: [
				"#completion-duration-error",
				"#completion-duration-input",
			],
			note_post: ["#completion-note-error", "#completion-note-input"],
		};

		for (const [field, messages] of Object.entries(reply.field_errors || {})) {
			const targets = fields[field];
			if (!targets) continue;
			const error = this.root.querySelector(targets[0]);
			const input = this.root.querySelector(targets[1]);
			const text = (Array.isArray(messages) ? messages : [messages])
				.filter(Boolean)
				.join(" ");
			if (error && text) {
				error.textContent = text;
				error.hidden = false;
			}
			if (text) fieldMessages.push(text);
			if (input && text) input.setAttribute("aria-invalid", "true");
		}

		const globalMessages = Array.isArray(reply.global_errors)
			? reply.global_errors.filter(Boolean)
			: [];
		const global = this.root.querySelector("#session-save-errors");
		if (global && globalMessages.length > 0) {
			global.textContent = globalMessages.join(" ");
			global.hidden = false;
			global.classList.remove("hidden");
		}

		const announcement = globalMessages.join(" ") || fieldMessages.join(" ");
		if (announcement) this.announce(announcement);
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
			work_recovery: ["is-rest", "is-work-recovery"],
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

	updateWorkFill(progress) {
		const fill = this.root.querySelector("#session-work-fill");
		if (!fill) return;

		const clampedProgress = Math.min(Math.max(Number(progress) || 0, 0), 1);
		const clip = `inset(${(1 - clampedProgress) * 100}% 0 0 0)`;
		fill.style.clipPath = clip;
		fill.style.webkitClipPath = clip;
	}

	updateAccessibleState({ state, primaryCount, setProgress }) {
		const target = this.root.querySelector("#ring-container");
		const status = this.root.querySelector("#session-accessible-status");
		const accessibleSetProgress = this.formatSetProgress(setProgress);
		const statusText = ["work", "work_active"].includes(state)
			? `${primaryCount} reps remaining`
			: state === "work_recovery"
				? `Recovery time remaining ${primaryCount}${
						accessibleSetProgress
							? `, set progress ${accessibleSetProgress}`
							: ""
					}`
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
		this.announce(paused ? "Workout paused" : "Workout resumed");
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
				"is-count-double",
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
		if (visual.state === "count_in") {
			this.announce(`Workout starts in ${model.primaryCount}`);
		}
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
			this.renderRestState(model);
		} else if (["work", "work_active"].includes(visual.state)) {
			this.lastPulseValue = null;
			this.updateWorkFill(visual.progress);
			this.updateCurrentSetRepCount(model.primaryCount);
		} else if (
			["work_recovery", "rest", "rest_count_in"].includes(visual.state)
		) {
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
			countEl.classList.remove(
				"is-down-cue",
				"is-count-double",
				"is-count-long",
				"countdown-pop",
			);
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
			"is-count-double",
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
				"is-count-double",
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
			"is-count-double",
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
		const length = String(text).length;
		if (length === 2) {
			countEl.classList.add("is-count-double");
		} else {
			countEl.classList.remove("is-count-double");
		}
		if (length >= 3) {
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
			accessibleTotal.textContent = `Pace progress: ${done} of ${target} reps`;
		}
	}

	formatTime(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return `${m}:${String(r).padStart(2, "0")}`;
	}

	formatClock(sec) {
		return String(Math.max(Math.ceil(sec), 0));
	}

	formatSetProgress(value) {
		const match = String(value ?? "").match(/^(\d+)\/(\d+)$/);
		return match ? `${match[1]} of ${match[2]}` : null;
	}
}
