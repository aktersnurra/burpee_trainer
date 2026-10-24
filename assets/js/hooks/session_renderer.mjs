import { formatClock } from "./session_display_model.mjs";
import { countOrigin } from "./session_flow_fsm.mjs";
const VISUAL_STATE_CLASSES = [
	"is-working",
	"is-work-active",
	"is-work-recovery",
	"is-rest",
	"is-rest-count-in",
	"is-count-in",
];

function flowAnnouncement(state) {
	if (state.mode === "camera_starting") return "Starting camera";
	if (state.mode === "camera_error") return "Camera unavailable";
	if (state.mode === "completion_review" && state.saveStatus === "saving") {
		return "Saving session";
	}
	if (state.mode === "completion_review") return "Workout complete";
	if (state.mode === "persisted") return "Session saved";
	return null;
}

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
		this.rendered = Object.create(null);
		this.nodes = Object.fromEntries(
			[
				"#session-runner-client",
				"#session-work-fill",
				"#session-progress",
				"#session-progress-fill",
				"#ring-container",
				"#session-accessible-status",
				"#session-time-accessible",
				"#count",
				"#down-word",
				"#set-progress",
				"#total-reps",
				"#total-done",
				"#total-separator",
				"#total-plan",
				"#total-reps-accessible",
				"#pause-icon",
			].map((selector) => [selector, root.querySelector(selector)]),
		);
		this.downAnimationFrame = null;
	}

	node(selector) {
		return this.nodes[selector];
	}

	setText(node, value, key) {
		const text = String(value ?? "");
		if (!node || this.rendered[key] === text) return;
		this.rendered[key] = text;
		node.textContent = text;
	}

	setHidden(node, value, key) {
		const hidden = Boolean(value);
		if (!node || this.rendered[key] === hidden) return;
		this.rendered[key] = hidden;
		node.hidden = hidden;
	}

	setAttribute(node, name, value, key) {
		const attributeValue = String(value);
		if (!node || this.rendered[key] === attributeValue) return;
		this.rendered[key] = attributeValue;
		node.setAttribute(name, attributeValue);
	}

	setStyle(node, property, value, key) {
		if (!node || this.rendered[key] === value) return;
		this.rendered[key] = value;
		node.style[property] = value;
	}

	// Sole writer of #count. Owns every cache key for that element so callers
	// cannot leave the cache disagreeing with what is on screen. `identity`
	// names the fast path a caller may later short-circuit on ("restCount" or
	// "currentSetRep"); the other identity is always invalidated.
	writeCount({ text, visibility = "", color = "", identity = null } = {}) {
		const count = this.node("#count");
		if (!count) return;

		this.rendered.restCount = undefined;
		this.rendered.restCountVisibility = undefined;
		this.rendered.currentSetRep = undefined;

		if (text !== undefined) this.setText(count, text, "countText");
		this.setStyle(count, "visibility", visibility, "countVisibility");
		this.setStyle(count, "color", color, "countColor");

		if (identity === "restCount") {
			this.rendered.restCount = this.rendered.countText;
			this.rendered.restCountVisibility = visibility;
		} else if (identity === "currentSetRep") {
			this.rendered.currentSetRep = this.rendered.countText;
		}
	}

	clearCountdown() {
		this.writeCount({ text: "—" });
	}

	clearTimers() {
		if (this.downTimeout) clearTimeout(this.downTimeout);
		if (this.downAnimationFrame != null) {
			globalThis.cancelAnimationFrame?.(this.downAnimationFrame);
			clearTimeout(this.downAnimationFrame);
		}
		this.downTimeout = null;
		this.downAnimationFrame = null;
		this.downCueActive = false;
	}

	renderFlowState(state) {
		const visibleId = {
			camera_starting: "session-camera-setup",
			camera_error: "session-camera-setup",
			camera_setup: "session-camera-setup",
			warmup_running: "session-runner-client",
			workout_running: "session-runner-client",
			completion_review: "session-completion-review",
		}[state.mode];

		for (const panel of this.root.querySelectorAll("[data-session-panel]")) {
			const visible = panel.id === visibleId;
			panel.hidden = !visible;
			panel.toggleAttribute("inert", !visible);
		}

		this.renderCameraSetup(state);
		this.renderCompletionControls(state);
		if (visibleId !== this.visiblePanelId) {
			this.visiblePanelId = visibleId;
			this.focusPanelHeading(visibleId);
		}
		// Said once when it changes, so an edit on the finish screen (which renders the
		// flow again) does not repeat it over the edit's own announcement.
		const announcement = flowAnnouncement(state);
		if (announcement && announcement !== this.flowAnnouncement) {
			this.announce(announcement);
		}
		this.flowAnnouncement = announcement;
	}

	// One camera screen: its heading is the status, from starting to "hand up".
	renderCameraSetup(state) {
		const failed = state.mode === "camera_error";
		const cameraReady = ["ready", "optimal"].includes(state.camera?.readiness);
		let status = "Step into frame";
		if (state.mode === "camera_starting") status = "Starting camera";
		else if (failed) status = "Camera unavailable";
		else if (cameraReady) status = "Hand up or hold still";

		this.setText(
			this.root.querySelector("#camera-setup-heading"),
			status,
			"cameraSetupStatus",
		);
		this.setHidden(
			this.root.querySelector("#pose-tracker-preview-frame"),
			failed,
			"cameraPreviewHidden",
		);
		const retry = this.root.querySelector("#camera-setup-retry");
		this.setHidden(retry, !failed, "cameraRetryHidden");
		retry?.toggleAttribute("inert", !failed);

		const detail = this.root.querySelector("#camera-setup-failure-detail");
		const stage = {
			webgl: "WebGL",
			camera_stream: "Camera stream",
			video_playback: "Video playback",
			video_frame: "Video frame",
			canvas: "Canvas",
			detector: "Detector",
		}[state.camera?.stage] || "Startup";
		this.setText(
			detail,
			failed && state.camera?.reason ? `${stage}: ${state.camera.reason}` : "",
			"cameraFailureDetail",
		);
		this.setHidden(detail, !failed || !state.camera?.reason, "cameraFailureHidden");
	}

	renderCompletionControls(state) {
		const saving =
			state.mode === "completion_review" && state.saveStatus === "saving";
		const locked =
			state.mode === "completion_review" && state.completionLocked === true;
		const factsDisabled = saving || locked;
		const factIds = [
			"completion-reps-more",
			"completion-reps-undo",
			"completion-note-input",
			"completion-context-low-energy",
			"completion-context-high-energy",
			"completion-context-heat-affected",
			"completion-primary-limiter",
			"completion-preference-feedback",
			"workout_session_burpee_type",
			"session-discard-btn",
			"session-discard-yes",
		];

		for (const id of factIds) {
			this.root
				.querySelector(`#${id}`)
				?.toggleAttribute("disabled", factsDisabled);
		}
		for (const input of this.root
			.querySelector("#session-completion-form")
			?.querySelectorAll?.("input, textarea, select") || []) {
			input.toggleAttribute("disabled", factsDisabled);
		}
		this.completionFactsDisabled = factsDisabled;
		this.renderRepsLess(state.completion);
		for (const selector of ["[data-mood]", "[data-tag]"]) {
			for (const button of this.root.querySelectorAll(selector)) {
				button.toggleAttribute("disabled", factsDisabled);
			}
		}

		const save = this.root.querySelector("#session-save-btn");
		if (save) {
			let label = "Save session";
			if (locked && saving) label = "Finalizing local evidence…";
			else if (locked) label = "Retry finalization";
			else if (saving) label = "Saving session…";
			save.toggleAttribute("disabled", saving);
			save.setAttribute("aria-label", label);
			save.setAttribute("title", label);
			save.setAttribute("aria-busy", String(saving));
			if (locked) save.dataset.localOnly = "true";
			else delete save.dataset.localOnly;
			this.root
				.querySelector("#session-save-icon-ready")
				?.toggleAttribute("hidden", saving || locked);
			this.root
				.querySelector("#session-save-icon-pending")
				?.toggleAttribute("hidden", !saving && !locked);
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

	// The discard question takes the place of the trash and save buttons while it is asked.
	showDiscardConfirm(visible) {
		const confirm = this.root.querySelector("#session-discard-confirm");
		if (!confirm) return;
		const actions = this.root.querySelector("#session-completion-actions");
		const wasVisible = !confirm.hidden;
		confirm.hidden = !visible;
		if (actions) actions.hidden = visible;
		if (visible) this.root.querySelector("#session-discard-keep")?.focus();
		else if (wasVisible) this.root.querySelector("#session-discard-btn")?.focus();
	}

	// Paused, the abort question takes the place of Finish early and Abort.
	showAbortConfirm(visible) {
		const confirm = this.root.querySelector("#session-abort-confirm");
		if (!confirm) return;
		const choices = this.root.querySelector("#session-pause-choices");
		const wasVisible = !confirm.hidden;
		confirm.hidden = !visible;
		if (choices) choices.hidden = visible;
		if (visible) {
			this.showAbortError(null);
			this.root.querySelector("#session-abort-keep")?.focus();
		} else if (wasVisible) this.root.querySelector("#session-abort-btn")?.focus();
	}

	showAbortError(text) {
		const error = this.root.querySelector("#session-abort-error");
		if (!error) return;
		error.textContent = text || "";
		error.hidden = !text;
	}

	// Resuming puts the paused choices back as they were, without moving focus.
	resetAbort() {
		const confirm = this.root.querySelector("#session-abort-confirm");
		if (confirm) confirm.hidden = true;
		const choices = this.root.querySelector("#session-pause-choices");
		if (choices) choices.hidden = false;
		this.showAbortError(null);
	}

	// While a discard waits on the server, its answers wait too.
	setDiscardBusy(busy) {
		for (const id of [
			"#session-discard-keep",
			"#session-discard-yes",
			"#session-abort-keep",
			"#session-abort-yes",
		]) {
			this.root.querySelector(id)?.toggleAttribute("disabled", busy);
		}
	}

	// A control about to be disabled or hidden hands its focus to +, beside the count.
	keepFocusFrom(element) {
		if (!element || element.ownerDocument?.activeElement !== element) return;
		this.root.querySelector("#completion-reps-more")?.focus();
	}

	// − cannot take the count below zero.
	renderRepsLess(completion) {
		const count = completion?.burpeeCountActual;
		const atZero = !Number.isInteger(count) || count <= 0;
		const less = this.root.querySelector("#completion-reps-less");
		const disabled = atZero || this.completionFactsDisabled === true;
		if (disabled) this.keepFocusFrom(less);
		less?.toggleAttribute("disabled", disabled);
	}

	// Where the count came from; once corrected, the original stays in view with undo.
	renderCountSource(completion, provenance) {
		const text = this.root.querySelector("#session-count-source-text");
		const undo = this.root.querySelector("#completion-reps-undo");
		const line = this.root.querySelector("#session-count-source");
		const origin = countOrigin(completion);
		let label = "";
		if (provenance === "camera_confirmed") label = "Counted by camera";
		else if (provenance === "scheduled") label = "From your plan";
		else if (origin.reps !== null) {
			label =
				origin.provenance === "camera_confirmed"
					? `Camera counted ${origin.reps}`
					: `From your plan: ${origin.reps}`;
		}
		if (text) text.textContent = label;
		if (undo) {
			const hidden = provenance !== "manual" || origin.reps === null;
			if (hidden) this.keepFocusFrom(undo);
			undo.hidden = hidden;
		}
		if (line) line.hidden = label === "";
	}

	renderCompletion(completion) {
		if (!completion) return;
		this.setText(
			this.root.querySelector("#session-completion-heading"),
			completion.endedEarly ? "Ended early" : "Workout complete",
			"completionHeading",
		);
		const actualReps = this.root.querySelector("#session-actual-reps");
		const plannedReps = this.root.querySelector("#session-planned-reps");
		const duration = this.root.querySelector("#session-actual-duration");
		const noteInput = this.root.querySelector("#completion-note-input");
		const lowEnergyInput = this.root.querySelector(
			"#completion-context-low-energy",
		);
		const highEnergyInput = this.root.querySelector(
			"#completion-context-high-energy",
		);
		const heatAffectedInput = this.root.querySelector(
			"#completion-context-heat-affected",
		);
		const limiterInput = this.root.querySelector("#completion-primary-limiter");
		const preferenceInput = this.root.querySelector(
			"#completion-preference-feedback",
		);
		const hasActualReps = Number.isInteger(completion.burpeeCountActual);
		const countProvenance =
			completion.burpeeCountProvenance ??
			(hasActualReps ? "manual" : "unresolved");
		if (actualReps) {
			actualReps.textContent = hasActualReps
				? String(completion.burpeeCountActual)
				: "—";
		}
		if (plannedReps)
			plannedReps.textContent = String(completion.burpeeCountPlanned);
		if (duration)
			duration.textContent = this.formatTime(completion.durationSecActual);
		this.renderCountSource(completion, countProvenance);
		this.renderRepsLess(completion);
		if (noteInput) noteInput.value = completion.notePost || "";
		if (lowEnergyInput)
			lowEnergyInput.checked = completion.contextLowEnergy ?? false;
		if (highEnergyInput)
			highEnergyInput.checked = completion.contextHighEnergy ?? false;
		if (heatAffectedInput)
			heatAffectedInput.checked = completion.contextHeatAffected ?? false;
		if (limiterInput) limiterInput.value = completion.primaryLimiter || "";
		if (preferenceInput)
			preferenceInput.value = completion.preferenceFeedback || "";

		for (const button of this.root.querySelectorAll("[data-mood]")) {
			button.setAttribute(
				"aria-pressed",
				String(Number(button.dataset.mood) === completion.mood),
			);
		}
		const tags = completion.tags || [];
		for (const button of this.root.querySelectorAll("[data-tag]")) {
			button.setAttribute("aria-pressed", String(tags.includes(button.dataset.tag)));
		}

	}

	clearSaveErrors() {
		const fields = [
			["#completion-reps-error", "#session-actual-reps"],
			["#completion-note-error", "#completion-note-input"],
			[
				"#completion-context-low-energy-error",
				"#completion-context-low-energy",
			],
			[
				"#completion-context-high-energy-error",
				"#completion-context-high-energy",
			],
			[
				"#completion-context-heat-affected-error",
				"#completion-context-heat-affected",
			],
			["#completion-primary-limiter-error", "#completion-primary-limiter"],
			[
				"#completion-preference-feedback-error",
				"#completion-preference-feedback",
			],
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
		const status = this.root.querySelector("#session-save-status");
		if (status) {
			status.textContent = "";
			status.hidden = true;
		}
	}

	renderSavePending(message) {
		this.clearSaveErrors();
		const status = this.root.querySelector("#session-save-status");
		if (status) {
			status.textContent = message;
			status.hidden = false;
		}
		this.announce(message);
	}

	renderSaveErrors(reply = {}) {
		this.clearSaveErrors();
		const fieldMessages = [];
		const globalMessages = Array.isArray(reply.global_errors)
			? reply.global_errors.filter(Boolean)
			: [];
		const fields = {
			burpee_count_actual: ["#completion-reps-error", "#session-actual-reps"],
			note_post: ["#completion-note-error", "#completion-note-input"],
		};

		for (const [field, messages] of Object.entries(reply.field_errors || {})) {
			const text = (Array.isArray(messages) ? messages : [messages])
				.filter(Boolean)
				.join(" ");
			if (!text) continue;
			const targets = fields[field];
			if (!targets) {
				globalMessages.push(text);
				continue;
			}
			const error = this.root.querySelector(targets[0]);
			const input = this.root.querySelector(targets[1]);
			if (error) {
				error.textContent = text;
				error.hidden = false;
				fieldMessages.push(text);
			} else {
				globalMessages.push(text);
			}
			if (input) input.setAttribute("aria-invalid", "true");
		}
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
		this.setText(
			this.node("#session-time-accessible"),
			`Session time remaining ${formattedTime}`,
			"timerText",
		);
	}

	updateSessionProgress(progress) {
		const track = this.node("#session-progress");
		const fill = this.node("#session-progress-fill");
		const numericProgress = Number(progress);
		const visible = progress != null && Number.isFinite(numericProgress);
		const clampedProgress = visible
			? Math.min(Math.max(numericProgress, 0), 1)
			: 0;

		this.setHidden(track, !visible, "sessionProgressHidden");
		this.setStyle(
			fill,
			"transform",
			`scaleX(${clampedProgress})`,
			"sessionProgressTransform",
		);
	}

	setVisualState(state) {
		if (this.appliedVisualState === state) return;

		const surface = this.node("#session-runner-client");
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
		const fill = this.node("#session-work-fill");
		if (!fill) return;

		const clampedProgress = Math.min(Math.max(Number(progress) || 0, 0), 1);
		const translateY = (1 - clampedProgress) * 100;
		this.setStyle(
			fill,
			"transform",
			`translate3d(0, ${translateY}%, 0)`,
			"workFillTransform",
		);
	}

	updateAccessibleState({ state, primaryCount, setProgress }) {
		const target = this.node("#ring-container");
		const status = this.node("#session-accessible-status");
		const accessibleSetProgress = this.formatSetProgress(setProgress);
		const statusText = ["work", "work_active"].includes(state)
			? `${primaryCount} reps remaining`
			: state === "work_recovery"
				? `Recovery time remaining ${primaryCount}${
						accessibleSetProgress ? `, set progress ${accessibleSetProgress}` : ""
					}`
				: state === "rest"
					? `Rest${
							accessibleSetProgress ? `, set progress ${accessibleSetProgress}` : ""
						}`
					: state === "rest_count_in"
						? `Rest time remaining ${primaryCount}`
						: "Workout starting";

		this.setAttribute(
			target,
			"aria-label",
			this.paused ? "Resume session" : "Pause session",
			"ringAriaLabel",
		);
		this.setText(status, statusText, "accessibleStatus");
	}

	updatePauseButton(paused) {
		this.paused = paused;
		const pauseIcon = this.root.querySelector("#pause-icon");
		const countEl = this.node("#count");
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
				this.writeCount({ visibility: "hidden" });
			}
			if (downEl) downEl.style.display = "none";
			if (pauseIcon) pauseIcon.style.display = "";
			if (totalReps) totalReps.hidden = false;
			if (totalSeparator) totalSeparator.hidden = false;
			if (totalPlan) totalPlan.hidden = false;
			ringContainer?.classList.remove("is-down-cue-active");
			this.setHidden(setProgress, true, "setProgressHidden");
			surface?.classList.add("is-paused");
		} else {
			if (pauseIcon) pauseIcon.style.display = "none";
			if (totalReps) totalReps.hidden = false;
			if (totalSeparator) totalSeparator.hidden = true;
			if (totalPlan) totalPlan.hidden = true;
			surface?.classList.remove("is-paused");
			if (countEl) this.writeCount({});
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
		const countEl = this.node("#count");
		if (countEl) {
			countEl.classList.remove(
				"is-down-cue",
				"is-rest-time-long",
				"is-count-double",
				"is-count-long",
				"is-countdown-dots",
				"countdown-pop",
			);
			this.writeCount({ text: "—" });
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
			this.setHidden(this.node("#total-reps"), false, "totalRepsHidden");
		}
		if (model.totalTarget !== undefined) this.updateTotalGoal(model.totalTarget);
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
		const countEl = this.node("#count");
		if (countEl) {
			countEl.classList.remove(
				"is-down-cue",
				"is-count-double",
				"is-count-long",
				"countdown-pop",
			);
			this.writeCount({});
		}
	}

	enterRestPhase() {
		this.setVisualState("rest");
		this.updateWorkFill(0);
	}

	renderRestState(model) {
		const count = this.node("#count");
		if (!count) return;

		const text = String(model.primaryCount ?? "");
		const visibility = this.paused ? "hidden" : "";
		if (
			this.rendered.restCount === text &&
			this.rendered.restCountVisibility === visibility
		) {
			this.lastPulseValue = null;
			return;
		}

		count.classList.remove(
			"is-down-cue",
			"is-count-double",
			"is-count-long",
			"is-countdown-dots",
			"countdown-pop",
		);
		this.writeCount({ text, visibility, identity: "restCount" });
		this.lastPulseValue = null;
	}

	updateSetProgress(value) {
		const setProgress = this.node("#set-progress");
		this.setText(setProgress, value, "setProgressText");
		this.setHidden(
			setProgress,
			this.paused || value == null,
			"setProgressHidden",
		);
	}

	renderRestProgress(timeLeftSec) {
		const countEl = this.node("#count");
		if (countEl) {
			const timeText = this.formatClock(timeLeftSec);
			countEl.classList.remove(
				"is-down-cue",
				"is-rest-time-long",
				"is-count-double",
				"is-count-long",
				"is-countdown-dots",
			);
			// Ten minutes and more need a fifth character; it gets a smaller size.
			if (timeText.length >= 5) countEl.classList.add("is-rest-time-long");
			this.writeCount({ text: timeText });
		}
		const downEl = this.root.querySelector("#down-word");
		if (downEl) downEl.style.display = "none";
	}

	triggerDown(repsLeft) {
		this.clearTimers();
		const countEl = this.node("#count");
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
		this.writeCount({ text: "DOWN" });
		countEl.classList.remove("countdown-pop");
		const reducedMotion = globalThis.matchMedia?.(
			"(prefers-reduced-motion: reduce)",
		)?.matches;
		if (!reducedMotion && typeof countEl.animate === "function") {
			countEl.animate(
				[
					{ transform: "scale(1.35)", opacity: 0.6 },
					{ transform: "scale(1)", opacity: 1, offset: 0.4 },
					{ transform: "scale(1)", opacity: 1 },
				],
				{
					duration: 350,
					easing: "cubic-bezier(0.22, 1, 0.36, 1)",
					fill: "both",
				},
			);
		} else if (!reducedMotion) {
			const scheduleFrame =
				globalThis.requestAnimationFrame || ((callback) => setTimeout(callback, 0));
			this.downAnimationFrame = scheduleFrame(() => {
				this.downAnimationFrame = null;
				if (this.downCueActive && !this.paused)
					countEl.classList.add("countdown-pop");
			});
		}

		this.downTimeout = setTimeout(() => {
			this.downTimeout = null;
			this.downCueActive = false;
			if (ringContainer) ringContainer.classList.remove("is-down-cue-active");
			if (!this.paused) this.updateCurrentSetRepCount(repsLeft);
		}, 650);
	}

	updateCurrentSetRepCount(repsLeft) {
		if (this.downCueActive) return;
		const countEl = this.node("#count");
		if (!countEl) return;

		const text = String(repsLeft);
		const visibility = this.paused ? "hidden" : "";
		if (
			this.rendered.currentSetRep === text &&
			this.rendered.countVisibility === visibility
		)
			return;

		countEl.classList.remove(
			"is-down-cue",
			"is-rest-time-long",
			"is-countdown-dots",
			"countdown-pop",
		);
		this.setCountLengthClass(countEl, text);
		this.writeCount({ text, visibility, identity: "currentSetRep" });
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
		const el = this.node("#total-done");
		this.setText(el, n, "totalDone");
		this.setStyle(el, "color", "", "totalDoneColor");
		this.updateTotalAccessibility();
	}

	updateTotalGoal(n) {
		const counter = this.node("#total-done");
		if (counter?.dataset && this.rendered.totalPlanData !== String(n)) {
			this.rendered.totalPlanData = String(n);
			counter.dataset.totalPlan = n;
		}
		this.setText(this.node("#total-plan"), n, "totalPlan");
		// Re-render the counter so the pace announcement picks up the new goal,
		// keeping the rep count the cache already holds.
		this.updateTotalCounter(this.rendered.totalDone ?? "");
	}

	// Both totals come from the render cache rather than the DOM: this runs on
	// every animation frame, and the cache is authoritative for what is shown.
	updateTotalAccessibility() {
		const done = this.rendered.totalDone;
		const target = this.rendered.totalPlan;
		if (done && target) {
			this.setText(
				this.node("#total-reps-accessible"),
				`Pace progress: ${done} of ${target} reps`,
				"totalAccessibility",
			);
		}
	}

	formatTime(sec) {
		const s = Math.max(Math.ceil(sec), 0);
		const m = Math.floor(s / 60);
		const r = s % 60;
		return `${m}:${String(r).padStart(2, "0")}`;
	}

	formatClock(sec) {
		return formatClock(sec);
	}

	formatSetProgress(value) {
		const match = String(value ?? "").match(/^(\d+)\/(\d+)$/);
		return match ? `${match[1]} of ${match[2]}` : null;
	}
}
