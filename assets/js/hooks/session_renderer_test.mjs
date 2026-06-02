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
	};

	return {
		elements,
		querySelector(selector) {
			return elements[selector] ?? null;
		},
	};
}

globalThis.document = {
	createElementNS() {
		return new FakeElement();
	},
};

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
	renderer.renderRestProgress(0.5, "#0ff", 75);

	assert.equal(
		root.elements["#ring-container"].classList.contains("is-resting"),
		true,
	);
	assert.equal(
		root.elements["#ring-container"].classList.contains("is-working"),
		false,
	);
	assert.equal(root.elements["#count"].textContent, "1:15");
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
