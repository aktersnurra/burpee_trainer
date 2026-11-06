import { formatClock } from "./session_display_model.mjs";
import { countOrigin } from "./session_flow_fsm.mjs";
import { setsReached } from "./session_plan.mjs";
import { createSink } from "./session_sink.mjs";
const VISUAL_STATE_CLASSES = [
	"is-working",
	"is-work-active",
	"is-rest",
	"is-rest-count-in",
	"is-count-in",
];

// The fill eases toward its target, about 50 ms behind it, so it never jumps.
const FILL_EASE_SEC = 0.05;

function reducedMotion() {
	return Boolean(globalThis.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches);
}

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

// The choices that ask in place before they act, and the screen each one is on.
const PAUSE_CHOICES = {
	finish: {
		id: "#finish-early-btn",
		screen: "#session-runner-client",
		label: "Finish early",
		armedLabel: "Tap again to finish",
		question: "Finish early? What you've done is kept. Tap again to finish.",
	},
	abort: {
		id: "#session-abort-btn",
		screen: "#session-runner-client",
		label: "Abort workout",
		armedLabel: "Tap again to abort",
		question: "Abort workout? It won't be saved. Tap again to abort.",
	},
	delete: {
		id: "#session-discard-btn",
		screen: "#session-completion-review",
		label: "Delete session",
		armedLabel: "Tap again to delete",
		question: "Delete this session? It won't be saved. Tap again to delete.",
	},
};

// What steps back on the finish screen while its trash is armed.
const FINISH_STEPS_BACK = [
	"#session-completion-summary",
	"#session-completion-fields",
	"#session-save-btn",
];

// The finish screen's sets line: how many of the plan's sets the schedule reached.
function setsLine(state) {
	const repsDone = state.completion?.scheduledRepsDone;
	if (!Number.isInteger(repsDone)) return null;
	const { done, total } = setsReached(state.workoutTimeline || [], repsDone);
	if (total === 0) return null;
	return `${done} of ${total} ${total === 1 ? "set" : "sets"}`;
}

export class SessionRenderer {
	constructor(root) {
		this.root = root;
		this.lastDisplayed = -1;
		this.paused = false;
		this.lastPulseValue = null;
		this.appliedVisualState = undefined;
		this.visiblePanelId = undefined;
		this.rendered = Object.create(null);
		this.nodes = Object.fromEntries(
			[
				"#session-runner-client",
				"#session-line-fill",
				"#ring-container",
				"#session-ring",
				"#session-accessible-status",
				"#session-time-accessible",
				"#count",
				"#count-on-fill",
				"#set-progress",
				"#session-meta",
				"#session-camera-lost",
				"#total-reps-accessible",
			].map((selector) => [selector, root.querySelector(selector)]),
		);
		this.countInMeta = this.node("#session-meta")?.textContent?.trim() ?? "";
		this.fill = 0;
		this.fillAt = null;
		this.timeLeftSec = null;
		const sinkCanvas = root.querySelector("#session-sink");
		this.sink = sinkCanvas
			? createSink(sinkCanvas, {
					reducedMotion,
					onDisc: (radius) =>
						this.setSurfaceVar("--disc-r", `${Math.max(radius, 0).toFixed(1)}px`),
				})
			: null;
		this.sinkRunning = false;
	}

	setSurfaceVar(name, value) {
		const surface = this.node("#session-runner-client");
		if (!surface?.style || this.rendered[name] === value) return;
		this.rendered[name] = value;
		surface.style.setProperty?.(name, value);
	}

	setSurfaceData(name, value) {
		const surface = this.node("#session-runner-client");
		const key = `data-${name}`;
		const next = value == null || value === false ? null : String(value);
		if (!surface || this.rendered[key] === next) return;
		this.rendered[key] = next;
		if (next === null) surface.removeAttribute(key);
		else surface.setAttribute(key, next);
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

		if (text !== undefined) {
			this.setText(count, text, "countText");
			this.setText(this.node("#count-on-fill"), text, "countOnFillText");
		}
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
		this.sink?.hold();
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
		if (state.mode === "completion_review") {
			const sets = setsLine(state);
			const line = this.root.querySelector("#session-sets-done");
			this.setText(line, sets ?? "", "setsDone");
			this.setHidden(line, sets === null, "setsDoneHidden");
		}
		this.setHidden(
			this.node("#session-camera-lost"),
			!(state.captureMode === "camera" && state.trackingTrust === "degraded"),
			"cameraLostHidden",
		);
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
		else if (cameraReady) status = "Hand up";

		this.setText(
			this.root.querySelector("#camera-setup-heading"),
			status,
			"cameraSetupStatus",
		);
		const detailLine = this.root.querySelector("#camera-setup-detail");
		this.workoutName ??= detailLine?.textContent?.trim() ?? "";
		this.setText(detailLine, cameraReady && !failed ? "or hold still" : this.workoutName, "cameraSetupDetail");
		this.setHidden(detailLine, failed, "cameraSetupDetailHidden");
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
			let label = "Save";
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

	// Paused, Finish early and Abort each ask before they act, and so does the finish screen's
	// trash: the first tap arms one (`kind` "finish", "abort" or "delete"), whose question takes
	// the screen's place while it stands alone in the middle; the second tap acts. `null` lets go.
	armPauseChoice(kind) {
		const was = this.armedPauseChoice();
		const screen = kind ? PAUSE_CHOICES[kind].screen : null;
		for (const [choice, { id, label, armedLabel, screen: on }] of Object.entries(PAUSE_CHOICES)) {
			const button = this.root.querySelector(id);
			if (!button) continue;
			const armed = kind === choice;
			button.setAttribute("aria-pressed", armed ? "true" : "false");
			button.setAttribute("aria-label", armed ? armedLabel : label);
			button.setAttribute("title", armed ? armedLabel : label);
			button.toggleAttribute("inert", on === screen && !armed);
		}
		this.setSurfaceData("armed", screen === "#session-runner-client" ? kind : null);
		const deleting = kind === "delete";
		const finish = this.root.querySelector("#session-completion-review");
		if (deleting) finish?.setAttribute("data-armed", "delete");
		else finish?.removeAttribute("data-armed");
		for (const selector of FINISH_STEPS_BACK) {
			this.root.querySelector(selector)?.toggleAttribute("inert", deleting);
		}
		if (kind) {
			this.showAbortError(null);
			if (was !== kind) this.announce(PAUSE_CHOICES[kind].question);
		}
	}

	armedPauseChoice() {
		for (const [choice, { id }] of Object.entries(PAUSE_CHOICES)) {
			if (this.root.querySelector(id)?.getAttribute("aria-pressed") === "true") return choice;
		}
		return null;
	}

	showAbortError(text) {
		const error = this.root.querySelector("#session-abort-error");
		if (!error) return;
		error.textContent = text || "";
		error.hidden = !text;
	}

	// Resuming lets go of an armed choice, without moving focus.
	resetPauseChoice() {
		this.armPauseChoice(null);
		this.showAbortError(null);
	}

	// While a discard waits on the server, its second tap waits too.
	setDiscardBusy(busy) {
		for (const id of ["#session-discard-btn", "#session-abort-btn"]) {
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
		const heading = this.root.querySelector("#session-completion-heading");
		this.setText(
			heading,
			completion.endedEarly ? "Ended early" : heading?.dataset.name,
			"completionHeading",
		);
		const actualReps = this.root.querySelector("#session-actual-reps");
		const plannedReps = this.root.querySelector("#session-planned-reps");
		const duration = this.root.querySelector("#session-actual-duration");
		const plannedDuration = this.root.querySelector("#session-planned-duration");
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
		if (plannedDuration)
			plannedDuration.textContent = this.formatTime(completion.durationSecPlanned);
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
		this.timeLeftSec = timeLeftSec;
		const formattedTime = this.formatTime(timeLeftSec);
		this.setText(
			this.node("#session-time-accessible"),
			`Session time remaining ${formattedTime}`,
			"timerText",
		);
	}

	// The workout line: time elapsed.
	updateSessionProgress(progress) {
		const numeric = Number(progress);
		const elapsed = Number.isFinite(numeric) ? Math.min(Math.max(numeric, 0), 1) : 0;
		this.setStyle(
			this.node("#session-line-fill"),
			"transform",
			`scaleX(${elapsed})`,
			"sessionLineTransform",
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

	// The set's fill, eased toward its target; reduced motion steps it.
	updateWorkFill(progress, now = globalThis.performance?.now?.() ?? Date.now()) {
		const target = Math.min(Math.max(Number(progress) || 0, 0), 1);
		if (reducedMotion() || this.fillAt === null) {
			this.fill = target;
		} else {
			const dt = Math.min(Math.max((now - this.fillAt) / 1000, 0), 1);
			this.fill += (target - this.fill) * (1 - Math.exp(-dt / FILL_EASE_SEC));
			if (Math.abs(target - this.fill) < 0.001) this.fill = target;
		}
		this.fillAt = now;
		this.setSurfaceVar("--fill", this.fill.toFixed(4));
	}

	// A ring pulses out from the number: ink when the camera counts a rep, orange on each
	// second of a count-in. None under reduced motion.
	pulseRing(kind) {
		const ring = this.node("#session-ring");
		if (!ring || reducedMotion() || typeof ring.animate !== "function") return;
		ring.classList.toggle("is-pace", kind === "count");
		ring.animate(
			[
				{ transform: "scale(0.6)", opacity: 0.9 },
				{ transform: "scale(1.2)", opacity: 0 },
			],
			{ duration: 600, easing: "cubic-bezier(.22,1,.36,1)" },
		);
	}

	pulseCounted() {
		this.pulseRing("counted");
	}

	updateAccessibleState({ state, primaryCount, setProgress }) {
		const target = this.node("#ring-container");
		const status = this.node("#session-accessible-status");
		const accessibleSetProgress = this.formatSetProgress(setProgress);
		const statusText = ["work", "work_active"].includes(state)
			? `${primaryCount} reps remaining`
			: state === "rest"
				? `Rest${accessibleSetProgress ? `, set progress ${accessibleSetProgress}` : ""}`
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

	// Paused: the title block says where the workout is, "Set 7 of 20 · 12:40 left".
	updatePauseButton(paused) {
		this.paused = paused;
		const surface = this.node("#session-runner-client");
		surface?.classList.toggle("is-paused", paused);
		const position = String(this.currentSetProgress ?? "").match(/^(\d+)\/(\d+)$/);
		const left = this.timeLeftSec == null ? null : `${this.formatTime(this.timeLeftSec)} left`;
		const pausedMeta = [position && `Set ${position[1]} of ${position[2]}`, left]
			.filter(Boolean)
			.join(" · ");
		this.setText(
			this.node("#session-meta"),
			paused ? pausedMeta : this.countInMeta,
			"sessionMeta",
		);
		if (paused) this.sink?.hold();
		this.writeCount({ visibility: paused ? "hidden" : "" });
		this.updateSetProgress(this.currentSetProgress);

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
		this.updateSessionProgress(0);
		this.fillAt = null;
		this.updateWorkFill(0);
		this.setSurfaceData("pace", null);
		this.setSurfaceData("draining", null);
		this.setSurfaceData("last", null);
		this.lastPulseValue = null;
		this.currentSetProgress = null;
		this.updateSetProgress(null);
		const countEl = this.node("#count");
		if (countEl) {
			this.setCountLengthClass(countEl, "");
			countEl.classList.remove("is-rest-time-long");
			this.writeCount({ text: "—" });
		}
	}

	renderDisplayModel(model) {
		if (!model) return;
		const visual = model.visual || { state: "work_active", progress: 0, pulse: null };
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

		const working = ["work", "work_active"].includes(visual.state);
		const resting = ["rest", "rest_count_in"].includes(visual.state);
		this.setSurfaceData("pace", working ? (visual.pace ?? "steady") : null);
		this.setSurfaceData("draining", working && visual.draining ? "" : null);
		this.setSurfaceData("last", working && model.primaryCount === 1 ? "" : null);

		if (working) {
			this.updateWorkFill(visual.progress);
			this.updateCurrentSetRepCount(model.primaryCount);
		} else {
			this.fillAt = null;
			this.updateWorkFill(0);
		}
		if (visual.state === "count_in" || visual.state === "rest_count_in") {
			if (model.primaryCount !== this.lastPulseValue) this.pulseRing("count");
			this.lastPulseValue = model.primaryCount;
		} else {
			this.lastPulseValue = null;
		}
		if (resting || visual.state === "count_in") this.renderRestState(model);
		this.renderSink(resting && !this.paused, model.restTimeLeftSec);

		this.updateSetProgress(resting ? model.setProgress : null);
		if (model.timeLeftSec !== undefined) this.renderTimer(model.timeLeftSec);
		if (model.totalDone !== undefined) this.updateTotalCounter(model.totalDone);
		if (model.totalTarget !== undefined) this.updateTotalGoal(model.totalTarget);
	}

	// The sink runs only while the rest shows; a new rest starts the breath in.
	renderSink(resting, remainingSec) {
		if (!this.sink) return;
		if (!resting) {
			if (this.sinkRunning) this.sink.hold();
			this.sinkRunning = false;
			if (this.currentVisualState !== "rest" && this.currentVisualState !== "rest_count_in") {
				this.restStarted = false;
			}
			return;
		}
		if (!this.restStarted) this.sink.start();
		this.restStarted = true;
		this.sinkRunning = true;
		this.sink.frame(remainingSec ?? 0);
	}

	enterWorkPhase() {
		this.setVisualState("work_active");
		this.fillAt = null;
		this.updateWorkFill(0);
		this.updateSetProgress(null);
		this.lastPulseValue = null;
	}

	enterRestPhase() {
		this.setVisualState("rest");
		this.fillAt = null;
		this.updateWorkFill(0);
	}

	renderRestState(model) {
		const count = this.node("#count");
		if (!count) return;

		const text = String(model.primaryCount ?? "");
		const visibility = this.paused ? "hidden" : "";
		if (this.rendered.restCount === text && this.rendered.restCountVisibility === visibility) {
			return;
		}

		this.setCountLengthClass(count, "");
		// Ten minutes and more need a fifth character; it gets a smaller size.
		count.classList.toggle("is-rest-time-long", text.length >= 5);
		this.node("#count-on-fill")?.classList.toggle("is-rest-time-long", text.length >= 5);
		this.writeCount({ text, visibility, identity: "restCount" });
	}

	// Sets done over sets in the workout, in the foot slot during rest.
	updateSetProgress(value) {
		const setProgress = this.node("#set-progress");
		const text = value ?? null;
		this.setText(setProgress, text, "setProgressText");
		this.setHidden(setProgress, this.paused || text == null, "setProgressHidden");
	}

	renderRestProgress(timeLeftSec) {
		this.renderRestState({ primaryCount: this.formatClock(timeLeftSec) });
	}

	updateCurrentSetRepCount(repsLeft) {
		const countEl = this.node("#count");
		if (!countEl) return;

		const text = String(repsLeft);
		const visibility = this.paused ? "hidden" : "";
		if (this.rendered.currentSetRep === text && this.rendered.countVisibility === visibility)
			return;

		countEl.classList.remove("is-rest-time-long");
		this.node("#count-on-fill")?.classList.remove("is-rest-time-long");
		this.setCountLengthClass(countEl, text);
		this.writeCount({ text, visibility, identity: "currentSetRep" });
		this.lastDisplayed = repsLeft;
	}

	setCountLengthClass(countEl, text) {
		const long = String(text).length >= 3;
		countEl.classList.toggle("is-count-long", long);
		this.node("#count-on-fill")?.classList.toggle("is-count-long", long);
	}

	updateTotalCounter(n) {
		this.rendered.totalDone = String(n);
		this.updateTotalAccessibility();
	}

	updateTotalGoal(n) {
		this.rendered.totalPlan = String(n);
		this.updateTotalAccessibility();
	}

	// Both totals come from the render cache: this runs on every animation frame.
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
