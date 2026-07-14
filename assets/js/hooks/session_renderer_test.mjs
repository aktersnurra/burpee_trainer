import test from "node:test";
import assert from "node:assert/strict";
import { SessionRenderer } from "./session_renderer.mjs";

function classList() {
	const values = new Set();
	const additions = [];
	let mutations = 0;
	return {
		add: (...names) => {
			names.forEach((name) => values.add(name));
			additions.push(...names);
			mutations += 1;
		},
		remove: (...names) => {
			names.forEach((name) => values.delete(name));
			mutations += 1;
		},
		contains: (name) => values.has(name),
		addCount: (name) => additions.filter((added) => added === name).length,
		mutationCount: () => mutations,
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
		style: {},
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
		"#session-work-fill": element(),
		"#session-rest-shape": element(),
		"#session-runner-client": element(),
		"#ring-container": element(),
		"#session-accessible-status": element(),
		"#count": element(),
		"#time-left": element(),
		"#total-done": element(),
		"#total-plan": element(),
		"#pause-icon": element(),
	};
	const root = {
		classList: classList(),
		querySelector: (selector) => elements[selector] || null,
	};
	return { renderer: new SessionRenderer(root), elements };
}

test("work fill uses the existing zero-to-one progress", () => {
	const { renderer, elements } = harness();

	renderer.updateWorkFill(0.5);
	assert.equal(elements["#session-work-fill"].style.transform, "scaleY(0.5)");

	renderer.updateWorkFill(0);
	assert.equal(elements["#session-work-fill"].style.transform, "scaleY(0)");
});

test("duplicate visual states skip class mutations while live values still update", () => {
	const { renderer, elements } = harness();
	const surfaceClasses = elements["#session-runner-client"].classList;
	const workModel = {
		visual: { state: "work", progress: 0.25, pulse: null },
		primaryCount: 5,
	};

	renderer.renderDisplayModel(workModel);
	const workMutations = surfaceClasses.mutationCount();

	renderer.renderDisplayModel({
		...workModel,
		visual: { ...workModel.visual, progress: 0.75 },
		primaryCount: 4,
	});
	assert.equal(surfaceClasses.mutationCount(), workMutations);
	assert.equal(elements["#session-work-fill"].style.transform, "scaleY(0.75)");
	assert.equal(elements["#count"].textContent, "4");

	renderer.renderDisplayModel({
		visual: { state: "rest-breathe", progress: 0, pulse: null },
		primaryCount: "12",
	});
	assert.ok(surfaceClasses.mutationCount() > workMutations);
	assert.equal(surfaceClasses.contains("is-working"), false);
	assert.equal(surfaceClasses.contains("is-rest-breathe"), true);
	assert.equal(elements["#count"].textContent, "12");
});

test("initial countdown still renders dots", () => {
	const { renderer, elements } = harness();
	renderer.renderDisplayModel({
		visual: { state: "initial-countdown", progress: 0, pulse: null },
		primaryCount: 3,
		countdownDots: { count: 5, faded: 2 },
		totalDone: 0,
		totalTarget: 20,
		timeLeftSec: 60,
	});

	assert.equal(
		elements["#session-runner-client"].classList.contains(
			"is-initial-countdown",
		),
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
});

test("rest switches from breathing to settle to numeric countdown", () => {
	const { renderer, elements } = harness();

	renderer.renderDisplayModel({
		visual: { state: "rest-breathe", progress: 0, pulse: null },
		primaryCount: "12",
		countdownDots: null,
		totalDone: 8,
		totalTarget: 20,
		timeLeftSec: 40,
	});
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-rest-breathe"),
		true,
	);
	assert.equal(elements["#count"].textContent, "12");

	renderer.renderDisplayModel({
		visual: { state: "rest-settle", progress: 0, pulse: null },
		primaryCount: "5",
		countdownDots: null,
		totalDone: 8,
		totalTarget: 20,
		timeLeftSec: 33,
	});
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-rest-settle"),
		true,
	);

	renderer.renderDisplayModel({
		visual: { state: "rest-countdown", progress: 0, pulse: 3 },
		primaryCount: 3,
		countdownDots: null,
		totalDone: 8,
		totalTarget: 20,
		timeLeftSec: 31,
	});
	assert.equal(elements["#count"].textContent, "3");
	assert.equal(
		elements["#count"].classList.contains("is-between-set-pulse"),
		true,
	);
});

test("between-set pulse survives duplicate frames and retriggers once per number", () => {
	const { renderer, elements } = harness();
	const count = elements["#count"];

	for (const [index, pulse] of [3, 2, 1].entries()) {
		const model = {
			visual: { state: "rest-countdown", progress: 0, pulse },
			primaryCount: pulse,
		};

		renderer.renderDisplayModel(model);
		assert.equal(count.classList.contains("is-between-set-pulse"), true);
		assert.equal(count.classList.contains("countdown-pop"), true);
		assert.equal(count.classList.addCount("countdown-pop"), index + 1);

		renderer.renderDisplayModel(model);
		assert.equal(count.classList.contains("is-between-set-pulse"), true);
		assert.equal(count.classList.contains("countdown-pop"), true);
		assert.equal(count.classList.addCount("countdown-pop"), index + 1);
	}
});

test("pause hides the active number and shows the pause glyph", () => {
	const { renderer, elements } = harness();
	renderer.updatePauseButton(true);

	assert.equal(elements["#count"].style.visibility, "hidden");
	assert.equal(elements["#pause-icon"].style.display, "");
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-paused"),
		true,
	);

	renderer.updatePauseButton(false);
	assert.equal(elements["#count"].style.visibility, "");
	assert.equal(elements["#pause-icon"].style.display, "none");
	assert.equal(
		elements["#session-runner-client"].classList.contains("is-paused"),
		false,
	);
});

test("renderer exposes count state through a separate status without repeat announcements", () => {
	const { renderer, elements } = harness();
	const status = elements["#session-accessible-status"];
	const workModel = {
		visual: { state: "work", progress: 0.5, pulse: null },
		primaryCount: 5,
		countdownDots: null,
		totalDone: 4,
		totalTarget: 20,
		timeLeftSec: 60,
	};

	renderer.renderDisplayModel(workModel);
	assert.equal(status.textContent, "5 reps remaining");
	assert.equal(status.textContentAssignments, 1);
	assert.equal(elements["#count"].getAttribute("aria-label"), null);

	renderer.renderDisplayModel(workModel);
	assert.equal(status.textContentAssignments, 1);

	renderer.renderDisplayModel({
		...workModel,
		visual: { state: "rest-breathe", progress: 0, pulse: null },
		primaryCount: "12",
	});
	assert.equal(status.textContent, "Rest time remaining 12");
	assert.equal(status.textContentAssignments, 2);

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
