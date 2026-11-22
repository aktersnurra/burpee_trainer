import test from "node:test";
import assert from "node:assert/strict";
import { LEAVING_SAVED, savedTransition } from "../saved_transition.mjs";

function pageswap(win) {
	const calls = { skipped: 0 };
	const event = new Event("pageswap");
	event.viewTransition = { skipTransition: () => (calls.skipped += 1) };
	win.dispatchEvent(event);
	return calls;
}

test("leaving a saved session keeps its transition into Home", () => {
	const win = new EventTarget();
	savedTransition(win);
	win.dispatchEvent(new Event(LEAVING_SAVED));
	assert.deepEqual(pageswap(win), { skipped: 0 });
});

test("every other page load skips the cross-document transition", () => {
	const win = new EventTarget();
	savedTransition(win);
	assert.deepEqual(pageswap(win), { skipped: 1 });
});

test("the save's transition is spent on one page load", () => {
	const win = new EventTarget();
	savedTransition(win);
	win.dispatchEvent(new Event(LEAVING_SAVED));
	pageswap(win);
	assert.deepEqual(pageswap(win), { skipped: 1 });
});

test("a page load without a transition (reduced motion, no support) is left alone", () => {
	const win = new EventTarget();
	savedTransition(win);
	win.dispatchEvent(new Event(LEAVING_SAVED));
	assert.doesNotThrow(() => win.dispatchEvent(new Event("pageswap")));
});
