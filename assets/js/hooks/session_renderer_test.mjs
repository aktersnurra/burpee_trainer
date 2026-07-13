import test from "node:test";
import assert from "node:assert/strict";
import { SessionRenderer } from "./session_renderer.mjs";

function classList() {
	const values = new Set();
	return {
		add: (...names) => names.forEach((name) => values.add(name)),
		remove: (...names) => names.forEach((name) => values.delete(name)),
		contains: (name) => values.has(name),
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
