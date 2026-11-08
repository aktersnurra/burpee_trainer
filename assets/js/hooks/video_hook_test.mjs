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

function harness(sessionId = null, { camera = false } = {}) {
	const listeners = new Map();
	const finishListeners = new Map();
	const pushes = [];
	const commands = [];
	let pauses = 0;
	const tracker = {
		hidden: false,
		dispatchEvent: (event) => commands.push(event.type),
	};
	const count = { textContent: "0" };
	const root = {
		dataset: { sessionId: sessionId || "", camera: String(camera) },
		...listenable(finishListeners),
		querySelector: (selector) =>
			({ "#pose-tracker": camera ? tracker : null, "#video-camera-count": camera ? count : null })[
				selector
			] ?? null,
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
	return {
		hook,
		el,
		root,
		listeners,
		finishListeners,
		pushes,
		commands,
		count,
		tracker,
		pauses: () => pauses,
	};
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

test("Finish early ends the video only once it has asked, at the time reached", () => {
	const ctx = harness("42");
	ctx.el.currentTime = 312.2;
	ctx.finishListeners.get("click")(clickOn("video-abort-btn"));
	// The first tap only asks (the LiveView arms it).
	ctx.finishListeners.get("click")(clickOn("video-finish-early"));
	assert.deepEqual(ctx.pushes, []);

	ctx.root.dataset.armed = "finish";
	ctx.finishListeners.get("click")(clickOn("video-finish-early"));
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 312 } },
	]);
});

test("with the camera on, playing starts it, each rep counts, and the end carries the count", () => {
	const ctx = harness("42", { camera: true });
	ctx.listeners.get("play")();
	ctx.listeners.get("play")();
	assert.deepEqual(ctx.commands, ["pose-tracker:start"]);

	ctx.finishListeners.get("pose-tracker:rep")({ detail: { index: 1 } });
	ctx.finishListeners.get("pose-tracker:rep")({ detail: { index: 2 } });
	assert.equal(ctx.count.textContent, "2");

	ctx.el.currentTime = 1200;
	ctx.listeners.get("ended")();
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 1200, counted_reps: 2 } },
	]);
	assert.deepEqual(ctx.commands, ["pose-tracker:start", "pose-tracker:stop"]);
});

test("a camera that cannot start leaves the count to the athlete", () => {
	const ctx = harness("42", { camera: true });
	ctx.listeners.get("play")();
	ctx.finishListeners.get("pose-tracker:start-failed")({ detail: {} });
	assert.equal(ctx.tracker.hidden, true);

	ctx.el.currentTime = 600;
	ctx.listeners.get("ended")();
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 600 } },
	]);
});

test("destroy removes video and Finish early listeners", () => {
	const ctx = harness("42");
	ctx.hook.destroyed();
	assert.equal(ctx.listeners.size, 0);
	assert.equal(ctx.finishListeners.size, 0);
});
