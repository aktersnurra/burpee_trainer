import test from "node:test";
import assert from "node:assert/strict";
import { initialFlowState } from "./session_flow_fsm.mjs";
import { SessionRenderer } from "./session_renderer.mjs";

function classList() {
	const values = new Set();
	let mutations = 0;
	return {
		add: (...names) => {
			names.forEach((name) => values.add(name));
			mutations += 1;
		},
		remove: (...names) => {
			names.forEach((name) => values.delete(name));
			mutations += 1;
		},
		contains: (name) => values.has(name),
		toggle: (name, force) => {
			const on = force === undefined ? !values.has(name) : Boolean(force);
			if (on === values.has(name)) return on;
			if (on) values.add(name);
			else values.delete(name);
			mutations += 1;
			return on;
		},
		mutationCount: () => mutations,
	};
}

function styleDeclaration() {
	let assignments = 0;
	return new Proxy(
		{
			setProperty(name, value) {
				this[name] = value;
			},
			get assignmentCount() {
				return assignments;
			},
		},
		{
			set(target, property, value) {
				assignments += 1;
				target[property] = value;
				return true;
			},
		},
	);
}

function element() {
	const attributes = new Map();
	const children = [];
	let textContent = "";
	let textContentAssignments = 0;
	let textContentReads = 0;
	let hidden = false;
	let hiddenAssignments = 0;
	let attributeAssignments = 0;
	let focusCalls = 0;
	let focusOptions;
	const node = {
		attributes,
		children,
		classList: classList(),
		className: "",
		dataset: {},
		get hidden() {
			return hidden;
		},
		set hidden(value) {
			hidden = Boolean(value);
			hiddenAssignments += 1;
		},
		get hiddenAssignments() {
			return hiddenAssignments;
		},
		get attributeAssignments() {
			return attributeAssignments;
		},
		style: styleDeclaration(),
		ownerDocument: {
			createElement() {
				return element();
			},
		},
		get textContent() {
			textContentReads += 1;
			return textContent;
		},
		set textContent(value) {
			textContent = String(value);
			textContentAssignments += 1;
			children.splice(0);
		},
		get textContentAssignments() {
			return textContentAssignments;
		},
		get textContentReads() {
			return textContentReads;
		},
		get focusCalls() {
			return focusCalls;
		},
		get focusOptions() {
			return focusOptions;
		},
		focus(options) {
			focusCalls += 1;
			focusOptions = options;
		},
		get firstChild() {
			return children[0] || null;
		},
		appendChild(child) {
			children.push(child);
			return child;
		},
		removeChild(child) {
			const index = children.indexOf(child);
			if (index >= 0) children.splice(index, 1);
			return child;
		},
		setAttribute(name, value) {
			attributes.set(name, String(value));
			attributeAssignments += 1;
		},
		toggleAttribute(name, force) {
			if (force) attributes.set(name, "");
			else attributes.delete(name);
		},
		removeAttribute(name) {
			attributes.delete(name);
			attributeAssignments += 1;
		},
		hasAttribute(name) {
			return attributes.has(name);
		},
		getAttribute(name) {
			return attributes.get(name) || null;
		},
	};
	return node;
}

function harness() {
	const elements = {
		"#session-runner-client": element(),
		"#session-line-fill": element(),
		"#ring-container": element(),
		"#session-ring": element(),
		"#session-pause-actions": element(),
		"#session-accessible-status": element(),
		"#count": element(),
		"#count-on-fill": element(),
		"#set-progress": element(),
		"#session-meta": element(),
		"#session-camera-lost": element(),
		"#session-abort-btn": element(),
		"#session-abort-error": element(),
		"#session-time-accessible": element(),
		"#total-reps-accessible": element(),
		"#session-live-status": element(),
		"#camera-setup-failure-detail": element(),
		"#session-begin-conflict": element(),
		"#session-begin-conflict-message": element(),
		"#session-begin-conflict-resolve": element(),
		"#session-completion-review [data-session-heading]": element(),
		"#session-save-status": element(),
		"#session-save-errors": element(),
		"#completion-reps-error": element(),
		"#completion-note-error": element(),
		"#completion-context-low-energy-error": element(),
		"#completion-context-high-energy-error": element(),
		"#completion-context-heat-affected-error": element(),
		"#completion-primary-limiter-error": element(),
		"#completion-preference-feedback-error": element(),
		"#session-actual-reps": element(),
		"#completion-note-input": element(),
		"#completion-context-low-energy": element(),
		"#completion-context-high-energy": element(),
		"#completion-context-heat-affected": element(),
		"#completion-primary-limiter": element(),
		"#completion-preference-feedback": element(),
	};
	elements["#session-meta"].textContent = "3 sets · 20 reps";
	const root = {
		classList: classList(),
		querySelector: (selector) => elements[selector] || null,
		querySelectorAll: () => [],
	};
	return { renderer: new SessionRenderer(root), elements };
}

test("completion save controls keep icons while announcing save, pending and retry states", () => {
	const { renderer, elements } = harness();
	const save = (elements["#session-save-btn"] = element());
	const readyIcon = (elements["#session-save-icon-ready"] = element());
	const pendingIcon = (elements["#session-save-icon-pending"] = element());
	pendingIcon.setAttribute("hidden", "");
	save.appendChild(readyIcon);
	save.appendChild(pendingIcon);

	renderer.renderCompletionControls({ mode: "completion_review", saveStatus: "idle", completionLocked: false });
	assert.equal(save.getAttribute("aria-label"), "Save session");
	assert.equal(readyIcon.hasAttribute("hidden"), false);
	assert.equal(pendingIcon.hasAttribute("hidden"), true);
	assert.equal(save.children.length, 2);

	renderer.renderCompletionControls({ mode: "completion_review", saveStatus: "saving", completionLocked: false });
	assert.equal(save.getAttribute("aria-label"), "Saving session…");
	assert.equal(save.hasAttribute("disabled"), true);
	assert.equal(readyIcon.hasAttribute("hidden"), true);
	assert.equal(pendingIcon.hasAttribute("hidden"), false);
	assert.equal(save.children.length, 2);

	renderer.renderCompletionControls({ mode: "completion_review", saveStatus: "failed", completionLocked: true });
	assert.equal(save.getAttribute("aria-label"), "Retry finalization");
	assert.equal(save.dataset.localOnly, "true");
	assert.equal(save.hasAttribute("disabled"), false);
	assert.equal(save.children.length, 2);
});

test("save progress is separate from errors and is cleared on failure or retry", () => {
	const { renderer, elements } = harness();
	const status = elements["#session-save-status"];
	const errors = elements["#session-save-errors"];
	const message = "Session saved. Finishing up…";

	renderer.renderSaveErrors({ global_errors: ["Previous failure"] });
	renderer.renderSavePending(message);
	assert.equal(errors.hidden, true);
	assert.equal(errors.textContent, "");
	assert.equal(status.hidden, false);
	assert.equal(status.textContent, message);
	assert.equal(elements["#session-live-status"].textContent, message);

	renderer.renderSaveErrors({ global_errors: ["Could not finish saving"] });
	assert.equal(status.hidden, true);
	assert.equal(errors.hidden, false);
	assert.equal(errors.textContent, "Could not finish saving");

	renderer.renderSavePending(message);
	renderer.clearSaveErrors();
	assert.equal(status.hidden, true);
	assert.equal(status.textContent, "");
});

test("validation for removed fields is visible instead of silently blocking Save", () => {
	const { renderer, elements } = harness();
	delete elements["#completion-context-high-energy-error"];
	delete elements["#completion-context-high-energy"];

	renderer.renderSaveErrors({
		status: "invalid",
		field_errors: { context_high_energy: ["cannot be true when low energy is also true"] },
		global_errors: [],
	});

	const error = elements["#session-save-errors"];
	assert.equal(error.hidden, false);
	assert.match(error.textContent, /cannot be true when low energy is also true/);
});

function model(state, overrides = {}) {
	return {
		visual: { state, progress: 0, pulse: null },
		primaryCount: state === "rest" ? "18" : 5,
		countdownDots: null,
		setProgress: "1/3",
		totalDone: 8,
		totalTarget: 20,
		timeLeftSec: 40,
		sessionProgress: 0.25,
		...overrides,
	};
}

test("camera, count-in, pause, completion, save, and errors are announced", () => {
	const { renderer, elements } = harness();
	const status = elements["#session-live-status"];

	renderer.renderFlowState({ mode: "camera_starting" });
	assert.equal(status.textContent, "Starting camera");

	renderer.renderFlowState({ mode: "camera_error" });
	assert.equal(status.textContent, "Camera unavailable");

	renderer.renderDisplayModel(model("count_in", { primaryCount: 3 }));
	assert.equal(status.textContent, "Workout starts in 3");

	renderer.updatePauseButton(true);
	assert.equal(status.textContent, "Workout paused");

	renderer.renderFlowState({ mode: "completion_review", saveStatus: "idle" });
	assert.equal(status.textContent, "Workout complete");

	renderer.renderFlowState({ mode: "completion_review", saveStatus: "saving" });
	assert.equal(status.textContent, "Saving session");

	renderer.renderSaveErrors({
		global_errors: ["Could not save. Try again."],
	});
	assert.equal(status.textContent, "Could not save. Try again.");

	const assignments = status.textContentAssignments;
	renderer.announce("Could not save. Try again.");
	assert.equal(status.textContentAssignments, assignments);
});

test("camera failure shows its stage and reason and clears them on retry", () => {
	const { renderer, elements } = harness();
	const detail = elements["#camera-setup-failure-detail"];

	renderer.renderFlowState({
		mode: "camera_error",
		camera: { stage: "detector", reason: "pose worker crashed" },
	});
	assert.equal(detail.textContent, "Detector: pose worker crashed");
	assert.equal(detail.hidden, false);

	renderer.renderFlowState({ mode: "camera_starting" });
	assert.equal(detail.textContent, "");
	assert.equal(detail.hidden, true);
});

test("panel heading focus prevents scroll", () => {
	const { renderer, elements } = harness();
	const heading = elements["#session-completion-review [data-session-heading]"];

	renderer.focusPanelHeading("session-completion-review");

	assert.equal(heading.focusCalls, 1);
	assert.deepEqual(heading.focusOptions, { preventScroll: true });
});

function withReducedMotion(reduce, run) {
	const original = globalThis.matchMedia;
	globalThis.matchMedia = () => ({ matches: reduce });
	try {
		return run();
	} finally {
		globalThis.matchMedia = original;
	}
}

const fillOf = (elements) => Number(elements["#session-runner-client"].style["--fill"]);

test("a set's fill eases toward its target without jumping, and steps under reduced motion", () => {
	withReducedMotion(false, () => {
		const { renderer, elements } = harness();
		renderer.updateWorkFill(0.2, 1_000);
		assert.equal(fillOf(elements), 0.2);
		renderer.updateWorkFill(1, 1_016);
		assert.ok(fillOf(elements) > 0.2 && fillOf(elements) < 1, `${fillOf(elements)}`);
		renderer.updateWorkFill(1, 1_400);
		assert.equal(fillOf(elements), 1);
	});
	withReducedMotion(true, () => {
		const { renderer, elements } = harness();
		renderer.updateWorkFill(0.2, 1_000);
		renderer.updateWorkFill(0.9, 1_016);
		assert.equal(fillOf(elements), 0.9);
	});
});

test("a set shows its pace, its drain and its last rep on the runner", () => {
	const { renderer, elements } = harness();
	const surface = elements["#session-runner-client"];
	renderer.renderDisplayModel(
		model("work_active", {
			visual: { state: "work_active", progress: 0.4, draining: true, pace: "ahead", pulse: null },
			primaryCount: 3,
		}),
	);
	assert.equal(surface.getAttribute("data-pace"), "ahead");
	assert.equal(surface.hasAttribute("data-draining"), true);
	assert.equal(surface.hasAttribute("data-last"), false);
	assert.equal(elements["#count-on-fill"].textContent, "3");

	renderer.renderDisplayModel(
		model("work_active", {
			visual: { state: "work_active", progress: 1, draining: false, pace: "behind", pulse: null },
			primaryCount: 1,
		}),
	);
	assert.equal(surface.getAttribute("data-pace"), "behind");
	assert.equal(surface.hasAttribute("data-draining"), false);
	assert.equal(surface.hasAttribute("data-last"), true);

	renderer.renderDisplayModel(model("rest"));
	assert.equal(surface.hasAttribute("data-pace"), false);
	assert.equal(elements["#set-progress"].textContent, "1/3");
	assert.equal(elements["#set-progress"].hidden, false);
});

test("the workout line shows the time elapsed, clamped", () => {
	const { renderer, elements } = harness();
	const line = elements["#session-line-fill"];

	renderer.renderDisplayModel(model("work_active", { sessionProgress: 0.25 }));
	assert.equal(line.style.transform, "scaleX(0.25)");
	renderer.renderDisplayModel(model("rest_count_in", { sessionProgress: 2 }));
	assert.equal(line.style.transform, "scaleX(1)");
	renderer.updatePauseButton(true);
	assert.equal(line.style.transform, "scaleX(1)");
});

test("the camera-lost chip shows once the camera stops counting", () => {
	const { renderer, elements } = harness();
	const chip = elements["#session-camera-lost"];
	renderer.renderFlowState({ mode: "workout_running", captureMode: "camera", trackingTrust: "observing" });
	assert.equal(chip.hidden, true);
	renderer.renderFlowState({ mode: "workout_running", captureMode: "camera", trackingTrust: "degraded" });
	assert.equal(chip.hidden, false);
	renderer.renderFlowState({ mode: "workout_running", captureMode: "no_camera" });
	assert.equal(chip.hidden, true);
});

test("abort arms on the first tap and says so, and lets go when reset", () => {
	const { renderer, elements } = harness();
	const abort = elements["#session-abort-btn"];
	const status = elements["#session-live-status"];
	renderer.armPauseChoice(null);
	assert.equal(renderer.armedPauseChoice(), null);
	renderer.armPauseChoice("abort");
	assert.equal(renderer.armedPauseChoice(), "abort");
	assert.equal(abort.getAttribute("aria-pressed"), "true");
	assert.equal(abort.getAttribute("aria-label"), "Tap again to abort");
	assert.equal(status.textContent, "Abort workout? It won't be saved. Tap again to abort.");
	renderer.resetPauseChoice();
	assert.equal(abort.getAttribute("aria-pressed"), "false");
	assert.equal(abort.getAttribute("aria-label"), "Abort workout");
});

test("identical display models skip hot-path DOM mutations", () => {
	const { renderer, elements } = harness();
	const workModel = model("work_active", {
		visual: { state: "work_active", progress: 0.25, pulse: null },
	});
	const mutationCounts = () =>
		Object.values(elements).reduce(
			(counts, node) => ({
				text: counts.text + node.textContentAssignments,
				hidden: counts.hidden + node.hiddenAssignments,
				attributes: counts.attributes + node.attributeAssignments,
				styles: counts.styles + node.style.assignmentCount,
				classes: counts.classes + node.classList.mutationCount(),
			}),
			{ text: 0, hidden: 0, attributes: 0, styles: 0, classes: 0 },
		);

	renderer.renderDisplayModel(workModel);
	const firstRender = mutationCounts();
	renderer.renderDisplayModel(workModel);

	assert.deepEqual(mutationCounts(), firstRender);
});

test("duplicate visual states skip class mutations while live values still update", () => {
	const { renderer, elements } = harness();
	const surfaceClasses = elements["#session-runner-client"].classList;
	const workModel = model("work_active", {
		visual: {
			state: "work_active",
			progress: 0.25,
			pulse: null,
		},
		primaryCount: 5,
	});

	renderer.renderDisplayModel(workModel);
	const workMutations = surfaceClasses.mutationCount();

	renderer.renderDisplayModel({
		...workModel,
		visual: { ...workModel.visual, progress: 0.75 },
		primaryCount: 4,
	});
	assert.equal(surfaceClasses.mutationCount(), workMutations);
	assert.equal(elements["#count"].textContent, "4");
	assert.equal(surfaceClasses.contains("is-working"), true);
	assert.equal(surfaceClasses.contains("is-work-active"), true);

	renderer.renderDisplayModel(model("rest"));
	assert.ok(surfaceClasses.mutationCount() > workMutations);
	assert.equal(surfaceClasses.contains("is-working"), false);
	assert.equal(surfaceClasses.contains("is-rest"), true);
	assert.equal(elements["#count"].textContent, "18");
});

test("initial count-in renders the same centered numeral as rest count-in", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel({
		...model("count_in"),
		primaryCount: 3,
		countdownDots: null,
	});

	assert.equal(
		elements["#session-runner-client"].classList.contains("is-count-in"),
		true,
	);
	assert.equal(elements["#count"].textContent, "3");
	assert.equal(elements["#set-progress"].hidden, true);
});

test("legacy rest rendering reads as a time; ten minutes and more are sized down", () => {
	const { renderer, elements } = harness();

	renderer.renderRestProgress(16);
	assert.equal(elements["#count"].textContent, "0:16");

	renderer.renderRestProgress(65);
	assert.equal(elements["#count"].textContent, "1:05");
	assert.equal(elements["#count"].classList.contains("is-rest-time-long"), false);

	renderer.renderRestProgress(600);
	assert.equal(elements["#count"].textContent, "10:00");
	assert.equal(elements["#count"].classList.contains("is-rest-time-long"), true);
});

test("clearing countdown state renders a subsequent one-second rest count-in", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel(
		model("count_in", { primaryCount: 1, setProgress: null }),
	);
	renderer.clearCountdown();
	renderer.renderDisplayModel(
		model("rest_count_in", { primaryCount: 1, setProgress: null }),
	);

	assert.equal(elements["#count"].textContent, "1");
});

test("zero transitions to work and resets the active fill", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel(
		model("rest_count_in", { primaryCount: 1, setProgress: null }),
	);
	renderer.renderDisplayModel(
		model("work_active", {
			visual: {
				state: "work_active",
				progress: 0,
				pulse: null,
			},
			primaryCount: 6,
		}),
	);

	const surfaceClasses = elements["#session-runner-client"].classList;
	assert.equal(surfaceClasses.contains("is-working"), true);
	assert.equal(fillOf(elements), 0);
	assert.equal(elements["#set-progress"].hidden, true);
});

test("pause says where the workout is, and resuming puts the screen back", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel(model("rest"));

	renderer.updatePauseButton(true);
	assert.equal(elements["#count"].style.visibility, "hidden");
	assert.equal(elements["#set-progress"].hidden, true);
	assert.equal(elements["#session-meta"].textContent, "Set 1 of 3 · 0:40 left");
	assert.equal(elements["#session-runner-client"].classList.contains("is-paused"), true);

	renderer.updatePauseButton(false);
	assert.equal(elements["#count"].style.visibility, "");
	assert.equal(elements["#set-progress"].hidden, false);
	assert.equal(elements["#session-meta"].textContent, "3 sets · 20 reps");
	assert.equal(elements["#session-runner-client"].classList.contains("is-paused"), false);
});

test("renderer keeps normal-rest live status stable while non-live time changes", () => {
	const { renderer, elements } = harness();
	const status = elements["#session-accessible-status"];
	const workModel = model("work_active", {
		visual: { state: "work_active", progress: 1, pulse: null },
		primaryCount: 5,
	});

	renderer.renderDisplayModel(workModel);
	assert.equal(status.textContent, "5 reps remaining");
	assert.equal(status.textContentAssignments, 1);
	assert.equal(elements["#count"].getAttribute("aria-label"), null);

	renderer.renderDisplayModel(workModel);
	assert.equal(status.textContentAssignments, 1);

	renderer.renderDisplayModel(model("rest"));
	assert.equal(status.textContent, "Rest, set progress 1 of 3");
	assert.equal(status.textContentAssignments, 2);
	assert.equal(elements["#count"].textContent, "18");
	assert.equal(
		elements["#total-reps-accessible"].textContent,
		"Pace progress: 8 of 20 reps",
	);
	assert.equal(
		elements["#session-time-accessible"].textContent,
		"Session time remaining 0:40",
	);

	renderer.renderDisplayModel(
		model("rest", {
			primaryCount: "17",
			totalDone: 9,
			totalTarget: 21,
			timeLeftSec: 39,
		}),
	);
	assert.equal(elements["#count"].textContent, "17");
	assert.equal(status.textContent, "Rest, set progress 1 of 3");
	assert.equal(
		status.textContentAssignments,
		2,
		"the atomic polite region must not be rewritten on each rest clock tick",
	);
	assert.equal(
		elements["#total-reps-accessible"].textContent,
		"Pace progress: 9 of 21 reps",
	);
	assert.equal(
		elements["#session-time-accessible"].textContent,
		"Session time remaining 0:39",
	);

	assert.equal(
		elements["#ring-container"].getAttribute("aria-label"),
		"Pause session",
	);

	renderer.updatePauseButton(true);
	assert.equal(status.textContentAssignments, 2);
	assert.equal(
		elements["#ring-container"].getAttribute("aria-label"),
		"Resume session",
	);
});

test("structured Save errors reuse visible field and global targets", () => {
	const { renderer, elements } = harness();
	renderer.renderSaveErrors({
		field_errors: {
			burpee_count_actual: ["must be at least 0"],
			duration_sec_actual: ["is invalid"],
		},
		global_errors: ["Could not save. Try again."],
	});

	assert.equal(elements["#completion-reps-error"].textContent, "must be at least 0");
	assert.equal(elements["#completion-reps-error"].hidden, false);
	assert.equal(elements["#completion-note-error"].hidden, true);
	// The time has no field of its own any more, so its error is a page error.
	assert.equal(
		elements["#session-save-errors"].textContent,
		"Could not save. Try again. is invalid",
	);
	assert.equal(elements["#session-save-errors"].hidden, false);
	assert.equal(elements["#session-actual-reps"].getAttribute("aria-invalid"), "true");

	renderer.clearSaveErrors();
	for (const selector of [
		"#completion-reps-error",
		"#completion-note-error",
		"#session-save-errors",
	]) {
		assert.equal(elements[selector].textContent, "");
		assert.equal(elements[selector].hidden, true);
	}
	assert.equal(elements["#session-actual-reps"].hasAttribute("aria-invalid"), false);
});

test("error for a removed field preserves the visible completion note", () => {
	const { renderer, elements } = harness();
	const contradiction = "cannot be true when low energy is also true";
	elements["#completion-note-input"].value = "Keep this note";

	renderer.renderSaveErrors({
		field_errors: { context_high_energy: [contradiction] },
		global_errors: [],
	});

	assert.equal(elements["#session-save-errors"].textContent, contradiction);
	assert.equal(elements["#session-live-status"].textContent, contradiction);
	assert.equal(elements["#completion-note-input"].value, "Keep this note");
});

test("a repeated rest count is restored after the rest clock overwrites it", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel(model("rest", { primaryCount: "18" }));
	assert.equal(elements["#count"].textContent, "18");

	renderer.renderRestProgress(12);
	assert.equal(elements["#count"].textContent, "0:12");

	renderer.renderDisplayModel(model("rest", { primaryCount: "18" }));
	assert.equal(elements["#count"].textContent, "18");
});

test("pausing and resuming restores a repeated work rep count", () => {
	const { renderer, elements } = harness();

	renderer.updateCurrentSetRepCount(6);
	assert.equal(elements["#count"].textContent, "6");

	renderer.updatePauseButton(true);
	assert.equal(elements["#count"].style.visibility, "hidden");

	renderer.updatePauseButton(false);
	renderer.updateCurrentSetRepCount(6);
	assert.equal(elements["#count"].style.visibility, "");
	assert.equal(elements["#count"].textContent, "6");
});

test("a repeated rest count is restored after entering the count-in phase", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel(model("rest", { primaryCount: "18" }));
	assert.equal(elements["#count"].textContent, "18");

	renderer.renderRestProgress(9);
	assert.equal(elements["#count"].textContent, "0:09");

	renderer.renderDisplayModel(model("rest", { primaryCount: "18" }));
	assert.equal(elements["#count"].textContent, "18");
});

test("a repeated work rep count is restored after a ready reset", () => {
	const { renderer, elements } = harness();

	renderer.updateCurrentSetRepCount(4);
	assert.equal(elements["#count"].textContent, "4");

	renderer.resetReady();
	assert.equal(elements["#count"].textContent, "—");

	renderer.updateCurrentSetRepCount(4);
	assert.equal(elements["#count"].textContent, "4");
});

test("updating the rep goal preserves the completed rep count", () => {
	const { renderer, elements } = harness();

	renderer.updateTotalCounter(7);
	renderer.updateTotalGoal(25);

	assert.equal(
		elements["#total-reps-accessible"].textContent,
		"Pace progress: 7 of 25 reps",
	);
});

test("the pace announcement waits until both totals are known", () => {
	const { renderer, elements } = harness();

	renderer.updateTotalCounter(3);

	assert.equal(elements["#total-reps-accessible"].textContent, "");
});

function finishFields(elements) {
	for (const id of [
		"#session-count-source",
		"#session-count-source-text",
		"#completion-reps-undo",
		"#completion-reps-less",
		"#session-discard-confirm",
		"#session-completion-actions",
		"#session-discard-keep",
		"#session-discard-btn",
	]) {
		elements[id] = element();
	}
	elements["#session-discard-confirm"].hidden = true;
	return elements;
}

const finished = {
	burpeeCountActual: 40,
	burpeeCountPlanned: 40,
	durationSecActual: 1_200,
	burpeeCountProvenance: "scheduled",
	notePost: "",
};

function source(elements) {
	return {
		text: elements["#session-count-source-text"].textContent,
		line: !elements["#session-count-source"].hidden,
		undo: !elements["#completion-reps-undo"].hidden,
	};
}

test("the count says where it came from, and a correction shows the original", () => {
	const { renderer, elements } = harness();
	finishFields(elements);
	const planned = { ...finished, scheduledRepsDone: 40 };
	renderer.renderCompletion(planned);
	assert.deepEqual(source(elements), { text: "From your plan", line: true, undo: false });

	renderer.renderCompletion({ ...planned, burpeeCountActual: 38, burpeeCountProvenance: "manual" });
	assert.deepEqual(source(elements), {
		text: "From your plan: 40",
		line: true,
		undo: true,
	});

	const camera = { ...finished, trackingTrust: "finished", detectedReps: 41 };
	renderer.renderCompletion({ ...camera, burpeeCountProvenance: "camera_confirmed" });
	assert.deepEqual(source(elements), { text: "Counted by camera", line: true, undo: false });
	renderer.renderCompletion({ ...camera, burpeeCountActual: 43, burpeeCountProvenance: "manual" });
	assert.deepEqual(source(elements), { text: "Camera counted 41", line: true, undo: true });

	// A count with nothing to go back to says nothing.
	renderer.renderCompletion({ ...finished, burpeeCountProvenance: "manual" });
	assert.deepEqual(source(elements), { text: "", line: false, undo: false });
});

test("minus is off at zero and while the result is being saved", () => {
	const { renderer, elements } = harness();
	finishFields(elements);
	const less = elements["#completion-reps-less"];
	renderer.renderCompletion({ ...finished, burpeeCountActual: 0 });
	assert.equal(less.hasAttribute("disabled"), true);
	renderer.renderCompletion(finished);
	assert.equal(less.hasAttribute("disabled"), false);
	renderer.renderCompletionControls({
		mode: "completion_review",
		saveStatus: "saving",
		completion: finished,
	});
	assert.equal(less.hasAttribute("disabled"), true);
	renderer.renderCompletion(finished);
	assert.equal(less.hasAttribute("disabled"), true);
});

test("focus on − at zero, or on Undo once used, moves to +", () => {
	const { renderer, elements } = harness();
	finishFields(elements);
	const more = (elements["#completion-reps-more"] = element());
	const document = { activeElement: null };
	for (const id of ["#completion-reps-less", "#completion-reps-undo"]) {
		elements[id].ownerDocument = document;
	}

	document.activeElement = elements["#completion-reps-less"];
	renderer.renderCompletion({ ...finished, burpeeCountActual: 0 });
	assert.equal(more.focusCalls, 1);

	const camera = { ...finished, trackingTrust: "finished", detectedReps: 41 };
	renderer.renderCompletion({ ...camera, burpeeCountActual: 43, burpeeCountProvenance: "manual" });
	document.activeElement = elements["#completion-reps-undo"];
	renderer.renderCompletion({ ...camera, burpeeCountActual: 41, burpeeCountProvenance: "camera_confirmed" });
	assert.equal(more.focusCalls, 2);

	// Focus elsewhere is left alone.
	document.activeElement = null;
	renderer.renderCompletion({ ...finished, burpeeCountActual: 0 });
	assert.equal(more.focusCalls, 2);
});

test("discard's answers are off while it waits on the server", () => {
	const { renderer, elements } = harness();
	finishFields(elements);
	elements["#session-discard-yes"] = element();
	renderer.setDiscardBusy(true);
	assert.equal(elements["#session-discard-keep"].hasAttribute("disabled"), true);
	assert.equal(elements["#session-discard-yes"].hasAttribute("disabled"), true);
	renderer.setDiscardBusy(false);
	assert.equal(elements["#session-discard-keep"].hasAttribute("disabled"), false);
});

test("an edit on the finish screen does not repeat its announcement", () => {
	const { renderer, elements } = harness();
	const status = elements["#session-live-status"];
	const review = { ...initialFlowState(), mode: "completion_review", saveStatus: "idle" };
	renderer.renderFlowState(review);
	assert.equal(status.textContent, "Workout complete");
	renderer.announce("11 reps");
	renderer.renderFlowState({ ...review });
	assert.equal(status.textContent, "11 reps");
	renderer.renderFlowState({ ...review, saveStatus: "saving" });
	assert.equal(status.textContent, "Saving session");
});

test("the discard question replaces the trash and save buttons, and goes back", () => {
	const { renderer, elements } = harness();
	finishFields(elements);
	renderer.showDiscardConfirm(true);
	assert.equal(elements["#session-discard-confirm"].hidden, false);
	assert.equal(elements["#session-completion-actions"].hidden, true);
	assert.equal(elements["#session-discard-keep"].focusCalls, 1);

	renderer.showDiscardConfirm(false);
	assert.equal(elements["#session-discard-confirm"].hidden, true);
	assert.equal(elements["#session-completion-actions"].hidden, false);
	assert.equal(elements["#session-discard-btn"].focusCalls, 1);
});

test("the heading says whether the workout was completed or ended early", () => {
	const { renderer, elements } = harness();
	const heading = (elements["#session-completion-heading"] = element());
	renderer.renderCompletion({ ...finished, endedEarly: false });
	assert.equal(heading.textContent, "Workout complete");
	renderer.renderCompletion({ ...finished, endedEarly: true });
	assert.equal(heading.textContent, "Ended early");
});
