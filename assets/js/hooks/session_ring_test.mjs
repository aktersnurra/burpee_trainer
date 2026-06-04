import test from "node:test";
import assert from "node:assert/strict";
import {
	appendSessionRing,
	ringDepletingOffset,
	RING_INK_COLOR,
	RING_TRACK_COLOR,
	updateSessionRing,
} from "./session_ring.mjs";

class FakeElement {
	constructor() {
		this.attributes = new Map();
		this.children = [];
		this.firstChild = null;
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

globalThis.document = {
	createElementNS() {
		return new FakeElement();
	},
};

test("session ring uses matching thick sharp-edged track and progress arcs", () => {
	const svg = new FakeElement();

	const progress = appendSessionRing(svg);
	const [track] = svg.children;

	assert.equal(svg.children.length, 2);
	assert.equal(track.getAttribute("stroke"), RING_TRACK_COLOR);
	assert.equal(progress.getAttribute("stroke"), RING_INK_COLOR);
	assert.equal(track.getAttribute("stroke-width"), "18");
	assert.equal(progress.getAttribute("stroke-width"), "18");
	assert.equal(track.getAttribute("stroke-linecap"), "butt");
	assert.equal(progress.getAttribute("stroke-linecap"), "butt");
	assert.equal(track.getAttribute("r"), progress.getAttribute("r"));
});

test("session ring depletes by increasing dash offset", () => {
	const svg = new FakeElement();
	const progress = appendSessionRing(svg);

	updateSessionRing(progress, 0);
	const start = Number(progress.getAttribute("stroke-dashoffset"));
	updateSessionRing(progress, 0.75);
	const later = Number(progress.getAttribute("stroke-dashoffset"));

	assert.equal(ringDepletingOffset(-1), 0);
	assert.ok(later > start);
});
