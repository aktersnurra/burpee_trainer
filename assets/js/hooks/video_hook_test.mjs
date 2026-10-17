import assert from "node:assert/strict";
import test from "node:test";

import VideoHook from "./video_hook.js";

function listenable(listeners) {
	return {
		addEventListener(name, listener) {
			listeners.set(name, listener);
		},
		removeEventListener(name, listener) {
			if (listeners.get(name) === listener) listeners.delete(name);
		},
	};
}

function harness(sessionId = null) {
	const listeners = new Map();
	const finishListeners = new Map();
	const pushes = [];
	let pauses = 0;
	const root = {
		dataset: { sessionId: sessionId || "" },
		...listenable(finishListeners),
	};
	const el = {
		currentTime: 0,
		closest() {
			return root;
		},
		addEventListener(name, listener) {
			listeners.set(name, listener);
		},
		removeEventListener(name, listener) {
			if (listeners.get(name) === listener) listeners.delete(name);
		},
		pause() {
			pauses += 1;
		},
	};
	const hook = {
		...VideoHook,
		el,
		pushEvent(name, payload) {
			pushes.push({ name, payload });
		},
	};
	hook.mounted();
	return { hook, el, listeners, finishListeners, pushes, pauses: () => pauses };
}

test("start page prevents playback before a durable server session exists", () => {
	const ctx = harness();
	ctx.listeners.get("play")();
	ctx.listeners.get("ended")();

	assert.equal(ctx.pauses(), 1);
	assert.deepEqual(ctx.pushes, []);
});

test("started video session reveals completion when playback ends, with the time watched", () => {
	const ctx = harness("42");
	ctx.listeners.get("play")();
	ctx.el.currentTime = 599.6;
	ctx.listeners.get("ended")();

	assert.equal(ctx.pauses(), 0);
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 600 } },
	]);
});

// A target as LiveView renders it: Finish early, or anything else on the page.
const clickOn = (id) => ({
	target: { closest: (selector) => (selector === `#${id}` ? {} : null) },
});

test("Finish early opens completion at the time reached, even after a re-render", () => {
	const ctx = harness("42");
	ctx.el.currentTime = 312.2;
	ctx.finishListeners.get("click")(clickOn("video-discard-btn"));
	assert.deepEqual(ctx.pushes, []);

	ctx.finishListeners.get("click")(clickOn("video-finish-early"));
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 312 } },
	]);
});

test("destroy removes video and Finish early listeners", () => {
	const ctx = harness("42");
	ctx.hook.destroyed();
	assert.equal(ctx.listeners.size, 0);
	assert.equal(ctx.finishListeners.size, 0);
});
