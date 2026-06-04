import test from "node:test";
import assert from "node:assert/strict";
import { SessionRenderer } from "./session_renderer.mjs";

class FakeClassList {
	constructor() {
		this.classes = new Set();
	}

	add(...classes) {
		for (const className of classes) this.classes.add(className);
	}

	remove(...classes) {
		for (const className of classes) this.classes.delete(className);
	}

	contains(className) {
		return this.classes.has(className);
	}
}

class FakeElement {
	constructor() {
		this.attributes = new Map();
		this.children = [];
		this.firstChild = null;
		this.style = {};
		this.textContent = "";
		this.className = "";
		this.classList = new FakeClassList();
	}

	setAttribute(name, value) {
		this.attributes.set(name, String(value));
	}

	getAttribute(name) {
		return this.attributes.get(name);
	}

	appendChild(child) {
		this.children.push(child);
		this.firstChild = this.children[0] ?? null;
		return child;
	}

	removeChild(child) {
		this.children = this.children.filter((candidate) => candidate !== child);
		this.firstChild = this.children[0] ?? null;
		return child;
	}
}

function fakeRoot() {
	const elements = {
		"#ring-container": new FakeElement(),
		"#ring-svg": new FakeElement(),
		"#count": new FakeElement(),
		"#down-word": new FakeElement(),
		"#pause-icon": new FakeElement(),
		"#set-glyphs": new FakeElement(),
	};

	return {
		elements,
		querySelector(selector) {
			return elements[selector] ?? null;
		},
	};
}

globalThis.document = {
	createElement() {
		return new FakeElement();
	},

	createElementNS() {
		return new FakeElement();
	},
};

test("ready reset clears a previously built ring", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.enterWorkPhase();
	assert.ok(root.elements["#ring-svg"].children.length > 0);

	renderer.resetReady();

	assert.equal(root.elements["#ring-svg"].children.length, 0);
	assert.equal(renderer.workRingEl, null);
	assert.equal(root.elements["#count"].textContent, "—");
});

test("non-work modes clear a previously built work ring", () => {
	for (const enterMode of ["enterCountInPhase", "enterRestPhase"]) {
		const root = fakeRoot();
		const renderer = new SessionRenderer(root);

		renderer.enterWorkPhase();
		assert.ok(root.elements["#ring-svg"].children.length > 0);

		renderer[enterMode]();

		assert.equal(
			root.elements["#ring-container"].classList.contains("is-working"),
			false,
			enterMode,
		);
		assert.equal(root.elements["#ring-svg"].children.length, 0, enterMode);
		assert.equal(renderer.workRingEl, null, enterMode);
	}
});

test("work ring depletes as progress increases", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.enterWorkPhase();
	renderer.updateWorkRing(0, "#fff");
	const initialOffset = Number(
		renderer.workRingEl.getAttribute("stroke-dashoffset"),
	);

	renderer.updateWorkRing(0.75, "#fff");
	const depletedOffset = Number(
		renderer.workRingEl.getAttribute("stroke-dashoffset"),
	);

	assert.ok(depletedOffset > initialOffset);
});

test("rest mode inverts instrument class and renders time", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.enterRestPhase();
	renderer.renderRestProgress(75);

	assert.equal(
		root.elements["#ring-container"].classList.contains("is-resting"),
		true,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-working"),
		false,
	);
	assert.equal(root.elements["#count"].style.visibility, "");
	assert.equal(root.elements["#count"].textContent, "1:15");
});

test("count-in mode marks instrument without rest inversion", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.enterCountInPhase();

	assert.ok(
		root.elements["#ring-container"].classList.contains("is-counting-in"),
	);
	assert.ok(!root.elements["#ring-container"].classList.contains("is-resting"));
});

test("countdown renders dots in the primary count position", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.renderCountdownDots({ count: 5, faded: 2 });

	const count = root.elements["#count"];
	assert.equal(count.textContent, "");
	assert.equal(count.classList.contains("is-countdown-dots"), true);
	assert.equal(count.children.length, 5);
	assert.equal(count.children[0].className, "countdown-dot is-faded");
	assert.equal(count.children[2].className, "countdown-dot");
	assert.equal(root.elements["#set-glyphs"].children.length, 0);
});

test("renders grouped set glyphs from plan blocks", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.renderSetGlyphs([
		{ setCount: 3, completedSets: 3, currentSetProgress: null },
		{ setCount: 3, completedSets: 1, currentSetProgress: 0.5 },
		{ setCount: 2, completedSets: 0, currentSetProgress: null },
	]);

	const glyphs = root.elements["#set-glyphs"];

	assert.equal(glyphs.children.length, 3);
	assert.deepEqual(
		glyphs.children.map((group) => group.children.length),
		[3, 3, 2],
	);
	assert.equal(
		glyphs.children[0].children[0].style.background,
		"var(--session-ink)",
	);
	assert.equal(
		glyphs.children[1].children[1].style.background,
		"linear-gradient(to top, var(--session-ink) 50%, var(--session-track) 50%)",
	);
	assert.equal(
		glyphs.children[2].children[0].style.background,
		"var(--session-track)",
	);
});

test("down cue hides ring until count returns", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.triggerDown(4);

	assert.equal(root.elements["#count"].textContent, "DOWN");
	assert.equal(root.elements["#count"].classList.contains("is-down-cue"), true);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-down-cue-active"),
		true,
	);
});

test("pausing during down hides the cue behind pause icon", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.triggerDown(4);
	renderer.updatePauseButton(true);

	assert.equal(root.elements["#count"].style.visibility, "hidden");
	assert.equal(
		root.elements["#count"].classList.contains("is-down-cue"),
		false,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-down-cue-active"),
		false,
	);
	assert.equal(root.elements["#pause-icon"].style.display, "");
});

test("paused mode hides count and shows pause icon class", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.updatePauseButton(true);

	assert.equal(root.elements["#count"].style.visibility, "hidden");
	assert.equal(root.elements["#pause-icon"].style.display, "");
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-paused"),
		true,
	);
});

test("paused mode survives phase transitions", () => {
	const root = fakeRoot();
	const renderer = new SessionRenderer(root);

	renderer.updatePauseButton(true);
	renderer.enterRestPhase();

	assert.equal(
		root.elements["#ring-container"].classList.contains("is-paused"),
		true,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-resting"),
		true,
	);

	renderer.enterWorkPhase();

	assert.equal(
		root.elements["#ring-container"].classList.contains("is-paused"),
		true,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-working"),
		true,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-resting"),
		false,
	);
});
