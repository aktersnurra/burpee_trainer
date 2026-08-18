import assert from "node:assert/strict";
import test from "node:test";

import VideoHook from "./video_hook.js";

function harness(sessionId = null) {
	const listeners = new Map();
	const pushes = [];
	let pauses = 0;
	const root = { dataset: { sessionId: sessionId || "" } };
	const el = {
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
	return { hook, listeners, pushes, pauses: () => pauses };
}

test("start page prevents playback before a durable server session exists", () => {
	const ctx = harness();
	ctx.listeners.get("play")();
	ctx.listeners.get("ended")();

	assert.equal(ctx.pauses(), 1);
	assert.deepEqual(ctx.pushes, []);
});

test("started video session reveals completion only after playback ends", () => {
	const ctx = harness("42");
	ctx.listeners.get("play")();
	ctx.listeners.get("ended")();

	assert.equal(ctx.pauses(), 0);
	assert.deepEqual(ctx.pushes, [{ name: "video_ended", payload: {} }]);
});

test("destroy removes video listeners", () => {
	const ctx = harness("42");
	ctx.hook.destroyed();
	assert.equal(ctx.listeners.size, 0);
});
