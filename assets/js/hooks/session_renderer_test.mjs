import test from "node:test";
import assert from "node:assert/strict";
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
		mutationCount: () => mutations,
	};
}

function styleDeclaration() {
	return {
		setProperty(name, value) {
			this[name] = value;
		},
	};
}

function element() {
	const attributes = new Map();
	const children = [];
	let textContent = "";
	let textContentAssignments = 0;
	const node = {
		attributes,
		children,
		classList: classList(),
		className: "",
		hidden: false,
		style: styleDeclaration(),
		ownerDocument: {
			createElement() {
				return element();
			},
		},
		get textContent() {
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
		},
		getAttribute(name) {
			return attributes.get(name) || null;
		},
	};
	return node;
}

function harness() {
	const elements = {
		"#session-work-track": element(),
		"#session-work-fill": element(),
		"#session-rest-shape": element(),
		"#session-runner-client": element(),
		"#session-runner-layout": element(),
		"#ring-container": element(),
		"#session-pause-actions": element(),
		"#session-status-line": element(),
		"#session-progress": element(),
		"#session-progress-fill": element(),
		"#session-accessible-status": element(),
		"#count": element(),
		"#set-progress": element(),
		"#session-time-accessible": element(),
		"#total-reps": element(),
		"#total-reps-accessible": element(),
		"#total-done": element(),
		"#total-separator": element(),
		"#total-plan": element(),
		"#pause-icon": element(),
	};
	elements["#session-progress"].hidden = true;
	elements["#total-reps"].hidden = true;
	elements["#total-separator"].hidden = true;
	elements["#total-plan"].hidden = true;
	const root = {
		classList: classList(),
		querySelector: (selector) => elements[selector] || null,
	};
	return { renderer: new SessionRenderer(root), elements };
}

function model(state, overrides = {}) {
	return {
		visual: { state, progress: 0, pulse: null },
		primaryCount: state === "rest" ? "18" : 5,
		countdownDots: null,
		setProgress: state === "rest" ? "1/3" : null,
		totalDone: 8,
		totalTarget: 20,
		timeLeftSec: 40,
		sessionProgress: 0.25,
		...overrides,
	};
}

test("work fill reveals fixed cadence colors without scaling the gradient", () => {
	const { renderer, elements } = harness();

	renderer.updateWorkFill(0.5, 0.6);
	assert.equal(
		elements["#session-work-fill"].style.clipPath,
		"inset(50% 0 0 0)",
	);
	assert.equal(elements["#session-work-fill"].style.transform, undefined);
	assert.equal(
		elements["#session-runner-client"].style["--session-active-ratio"],
		"60%",
	);

	renderer.updateWorkFill(0, 1);
	assert.equal(
		elements["#session-work-fill"].style.clipPath,
		"inset(100% 0 0 0)",
	);
	assert.equal(
		elements["#session-runner-client"].style["--session-active-ratio"],
		"100%",
	);
});

test("overall progress uses a clamped horizontal transform and freezes on pause", () => {
	const { renderer, elements } = harness();
	const track = elements["#session-progress"];
	const fill = elements["#session-progress-fill"];

	renderer.renderDisplayModel(model("work_active", { sessionProgress: 0.25 }));
	assert.equal(track.hidden, false);
	assert.equal(fill.style.transform, "scaleX(0.25)");

	renderer.renderDisplayModel(model("rest", { sessionProgress: 0.5 }));
	assert.equal(fill.style.transform, "scaleX(0.5)");

	renderer.renderDisplayModel(model("rest_count_in", { sessionProgress: 2 }));
	assert.equal(fill.style.transform, "scaleX(1)");

	renderer.updatePauseButton(true);
	assert.equal(fill.style.transform, "scaleX(1)");

	renderer.updateSessionProgress(null);
	assert.equal(track.hidden, true);
	assert.equal(fill.style.transform, "scaleX(0)");
});

test("duplicate visual states skip class mutations while live values still update", () => {
	const { renderer, elements } = harness();
	const surfaceClasses = elements["#session-runner-client"].classList;
	const workModel = model("work_recovery", {
		visual: {
			state: "work_recovery",
			progress: 0.25,
			activeRatio: 0.6,
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
	assert.equal(
		elements["#session-work-fill"].style.clipPath,
		"inset(25% 0 0 0)",
	);
	assert.equal(
		elements["#session-runner-client"].style["--session-active-ratio"],
		"60%",
	);
	assert.equal(elements["#count"].textContent, "4");
	assert.equal(surfaceClasses.contains("is-working"), true);
	assert.equal(surfaceClasses.contains("is-work-recovery"), true);

	renderer.renderDisplayModel(model("rest"));
	assert.ok(surfaceClasses.mutationCount() > workMutations);
	assert.equal(surfaceClasses.contains("is-working"), false);
	assert.equal(surfaceClasses.contains("is-rest"), true);
	assert.equal(elements["#count"].textContent, "18");
});

test("work count distinguishes single, double, and triple digit values", () => {
	const { renderer, elements } = harness();
	const count = elements["#count"];

	renderer.updateCurrentSetRepCount(9);
	assert.equal(count.classList.contains("is-count-double"), false);
	assert.equal(count.classList.contains("is-count-long"), false);

	renderer.updateCurrentSetRepCount(10);
	assert.equal(count.classList.contains("is-count-double"), true);
	assert.equal(count.classList.contains("is-count-long"), false);

	renderer.updateCurrentSetRepCount(100);
	assert.equal(count.classList.contains("is-count-double"), false);
	assert.equal(count.classList.contains("is-count-long"), true);

	renderer.renderDisplayModel(model("rest", { primaryCount: "18" }));
	assert.equal(count.classList.contains("is-count-double"), false);
	assert.equal(count.classList.contains("is-count-long"), false);
});

test("initial count-in still renders dots", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel({
		...model("count_in"),
		primaryCount: 3,
		countdownDots: { count: 5, faded: 2 },
	});

	assert.equal(
		elements["#session-runner-client"].classList.contains("is-count-in"),
		true,
	);
	assert.equal(elements["#count"].children.length, 5);
	assert.deepEqual(
		elements["#count"].children.map((dot) => dot.className),
		[
			"countdown-dot is-faded",
			"countdown-dot is-faded",
			"countdown-dot",
			"countdown-dot",
			"countdown-dot",
		],
	);
	assert.equal(elements["#set-progress"].hidden, true);
});

test("normal rest shows set progress but rest_count_in removes supporting visuals", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel(model("rest"));
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-rest"),
		true,
	);
	assert.equal(elements["#count"].textContent, "18");
	assert.equal(elements["#set-progress"].textContent, "1/3");
	assert.equal(elements["#set-progress"].hidden, false);

	renderer.renderDisplayModel(
		model("work_recovery", {
			visual: { state: "work_recovery", progress: 0.5, pulse: null },
		}),
	);
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-working"),
		true,
	);

	renderer.renderDisplayModel(
		model("rest_count_in", {
			primaryCount: 3,
			setProgress: null,
		}),
	);
	assert.equal(elements["#count"].textContent, "3");
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-rest-count-in"),
		true,
	);
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-working"),
		false,
	);
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-rest"),
		false,
	);
	assert.equal(elements["#set-progress"].hidden, true);
	assert.equal(elements["#count"].classList.contains("countdown-pop"), false);
	assert.equal(
		elements["#count"].classList.contains("is-between-set-pulse"),
		false,
	);
});

test("legacy rest rendering uses bare seconds below one minute", () => {
	const { renderer, elements } = harness();

	renderer.renderRestProgress(16);
	assert.equal(elements["#count"].textContent, "16");

	renderer.renderRestProgress(65);
	assert.equal(elements["#count"].textContent, "1:05");
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
				activeRatio: 0.75,
				pulse: null,
			},
			primaryCount: 6,
		}),
	);

	const surfaceClasses = elements["#session-runner-client"].classList;
	assert.equal(surfaceClasses.contains("is-working"), true);
	assert.equal(surfaceClasses.contains("is-work-active"), true);
	assert.equal(surfaceClasses.contains("is-work-recovery"), false);
	assert.equal(
		elements["#session-work-fill"].style.clipPath,
		"inset(100% 0 0 0)",
	);
	assert.equal(elements["#set-progress"].hidden, true);
});

test("state changes retain anchor nodes without positional inline styles", () => {
	const { renderer, elements } = harness();
	const anchorSelectors = [
		"#ring-container",
		"#session-pause-actions",
		"#session-status-line",
	];
	const positionalStyleKeys = [
		"position",
		"top",
		"right",
		"bottom",
		"left",
		"inset",
		"insetBlock",
		"insetBlockStart",
		"insetBlockEnd",
		"insetInline",
		"insetInlineStart",
		"insetInlineEnd",
		"transform",
		"translate",
		"margin",
		"marginTop",
		"marginRight",
		"marginBottom",
		"marginLeft",
		"marginBlock",
		"marginBlockStart",
		"marginBlockEnd",
		"marginInline",
		"marginInlineStart",
		"marginInlineEnd",
	];
	const anchors = Object.fromEntries(
		anchorSelectors.map((selector) => [selector, elements[selector]]),
	);
	const assertStableAnchors = () => {
		for (const selector of anchorSelectors) {
			assert.equal(elements[selector], anchors[selector]);
			for (const key of positionalStyleKeys) {
				assert.equal(
					elements[selector].style[key] ?? "",
					"",
					`${selector} must not write inline ${key}`,
				);
			}
		}
	};

	for (const state of [
		"count_in",
		"rest",
		"rest_count_in",
		"work_active",
		"work_recovery",
	]) {
		renderer.renderDisplayModel(model(state));
		assertStableAnchors();
	}

	renderer.updatePauseButton(true);
	assertStableAnchors();
});

test("running shows completed reps and pause adds the total target", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel(model("rest"));

	assert.equal(elements["#total-reps"].hidden, false);
	assert.equal(elements["#total-done"].textContent, "8");
	assert.equal(elements["#total-separator"].hidden, true);
	assert.equal(elements["#total-plan"].hidden, true);

	renderer.updatePauseButton(true);
	assert.equal(elements["#count"].style.visibility, "hidden");
	assert.equal(elements["#set-progress"].hidden, true);
	assert.equal(elements["#pause-icon"].style.display, "");
	assert.equal(elements["#total-reps"].hidden, false);
	assert.equal(elements["#total-separator"].hidden, false);
	assert.equal(elements["#total-plan"].hidden, false);
	assert.equal(elements["#total-plan"].textContent, "20");
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-paused"),
		true,
	);

	renderer.updatePauseButton(false);
	assert.equal(elements["#count"].style.visibility, "");
	assert.equal(elements["#total-reps"].hidden, false);
	assert.equal(elements["#total-separator"].hidden, true);
	assert.equal(elements["#total-plan"].hidden, true);
	assert.equal(elements["#set-progress"].hidden, false);
	assert.equal(elements["#pause-icon"].style.display, "none");
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-paused"),
		false,
	);
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
		"8 of 20 total reps",
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
		"9 of 21 total reps",
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
