import test from "node:test";
import assert from "node:assert/strict";
import { SessionRenderer } from "./session_renderer.mjs";

function classList() {
	const values = new Set();
	const additions = [];
	return {
		add: (...names) => {
			names.forEach((name) => values.add(name));
			additions.push(...names);
		},
		remove: (...names) => names.forEach((name) => values.delete(name)),
		contains: (name) => values.has(name),
		addCount: (name) => additions.filter((added) => added === name).length,
	};
}

function element() {
	return {
		classList: classList(),
		style: {},
		textContent: "",
		firstChild: null,
		appendChild() {},
		removeChild() {},
		setAttribute() {},
	};
}

function harness() {
	const elements = {
		"#session-work-fill": element(),
		"#session-rest-shape": element(),
		"#session-runner-client": element(),
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
