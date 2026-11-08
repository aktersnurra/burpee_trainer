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

// An element the hook reads or writes: text, hidden, attributes.
function node(text = "") {
	const attributes = new Map();
	return {
		textContent: text,
		hidden: false,
		focused: false,
		setAttribute: (name, value) => attributes.set(name, value),
		removeAttribute: (name) => attributes.delete(name),
		hasAttribute: (name) => attributes.has(name),
		focus() {
			this.focused = true;
		},
	};
}

function harness(sessionId = null, { camera = false, play = "resolves" } = {}) {
	const listeners = new Map();
	const finishListeners = new Map();
	const pushes = [];
	const commands = [];
	const deferred = [];
	let pauses = 0;
	let plays = 0;
	const tracker = {
		...node(),
		dataset: { stage: "setup" },
		dispatchEvent: (event) => commands.push({ type: event.type, detail: event.detail }),
	};
	tracker.setAttribute("role", "dialog");
	const nodes = {
		"#pose-tracker": tracker,
		"#video-camera-count": node("0"),
		"#video-camera-status": node("Starting camera"),
		"#video-camera-detail": node("Burpee Ladder 20"),
		"#video-camera-play": node(),
		"#video-camera-retry": { ...node(), hidden: true },
	};
	const root = {
		dataset: { sessionId: sessionId || "", camera: String(camera) },
		...listenable(finishListeners),
		querySelector: (selector) => (camera ? nodes[selector] : null) ?? null,
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
		play() {
			plays += 1;
			return play === "resolves"
				? Promise.resolve()
				: Promise.reject(new DOMException("No user gesture", "NotAllowedError"));
		},
	};
	const hook = {
		...VideoHook,
		el,
		defer: (fn) => deferred.push(fn),
		pushEvent(name, payload) {
			pushes.push({ name, payload });
		},
	};
	hook.mounted();
	const fire = (name, detail = {}) => finishListeners.get(name)({ detail });
	return {
		hook,
		el,
		root,
		listeners,
		finishListeners,
		pushes,
		commands,
		types: () => commands.map((c) => c.type),
		nodes,
		count: nodes["#video-camera-count"],
		tracker,
		fire,
		runDeferred: () => deferred.splice(0).forEach((fn) => fn()),
		pauses: () => pauses,
		plays: () => plays,
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

test("with the camera on, the camera starts as the page opens, not on play", () => {
	const ctx = harness("42", { camera: true });
	assert.deepEqual(ctx.types(), []);
	ctx.runDeferred();
	assert.equal(ctx.types().at(-1), "pose-tracker:start");
	assert.deepEqual(
		ctx.commands.find((c) => c.type === "pose-tracker:preview-visibility").detail,
		{ visible: true },
	);
	assert.equal(ctx.tracker.dataset.stage, "setup");
	assert.equal(ctx.nodes["#video-camera-status"].focused, true);
});

test("found, the camera arms a raised hand; nothing plays before it", () => {
	const ctx = harness("42", { camera: true });
	ctx.runDeferred();
	ctx.fire("pose-tracker:started");
	assert.equal(ctx.nodes["#video-camera-status"].textContent, "Step into frame");
	assert.equal(ctx.plays(), 0);

	ctx.fire("pose-tracker:readiness", { state: "ready" });
	assert.equal(ctx.nodes["#video-camera-status"].textContent, "Hand up");
	// Its own step, never the plan's camera_setup, whose timer would start the video alone.
	assert.deepEqual(ctx.commands.at(-1), {
		type: "pose-tracker:arm",
		detail: { step: "video_play", holdFramesRequired: 15 },
	});
	assert.equal(ctx.plays(), 0);

	// Out of frame again, the hand is no longer armed.
	ctx.fire("pose-tracker:readiness", { state: "not_ready" });
	assert.equal(ctx.commands.at(-1).detail.step, null);
	assert.equal(ctx.plays(), 0);
});

test("a raised hand plays the video, and the feed moves to the corner", () => {
	const ctx = harness("42", { camera: true });
	ctx.runDeferred();
	ctx.fire("pose-tracker:readiness", { state: "ready" });
	ctx.fire("pose-tracker:gesture-confirm", { step: "video_play" });
	assert.equal(ctx.plays(), 1);

	ctx.listeners.get("play")();
	assert.equal(ctx.tracker.dataset.stage, "live");
	assert.equal(ctx.tracker.hasAttribute("role"), false);
	// Another step's gesture never plays it.
	ctx.fire("pose-tracker:gesture-confirm", { step: "camera_setup" });
	assert.equal(ctx.plays(), 1);
});

test("refused without a tap, play asks for one and the tap plays", async () => {
	const ctx = harness("42", { camera: true, play: "rejects" });
	ctx.runDeferred();
	ctx.fire("pose-tracker:readiness", { state: "ready" });
	ctx.fire("pose-tracker:gesture-confirm", { step: "video_play" });
	await new Promise((resolve) => setImmediate(resolve));

	assert.equal(ctx.nodes["#video-camera-status"].textContent, "Tap play");
	assert.equal(ctx.nodes["#video-camera-detail"].textContent, "Burpee Ladder 20");
	assert.equal(ctx.nodes["#video-camera-play"].hasAttribute("data-attention"), true);
	assert.equal(ctx.tracker.dataset.stage, "setup");

	ctx.finishListeners.get("click")(clickOn("video-camera-play"));
	assert.equal(ctx.plays(), 2);
});

test("only reps from when the video plays count, and the end carries them", () => {
	const ctx = harness("42", { camera: true });
	ctx.runDeferred();
	// Getting into frame looks like reps; none of it counts.
	ctx.fire("pose-tracker:rep", { index: 1 });
	ctx.fire("pose-tracker:rep", { index: 2 });
	assert.equal(ctx.count.textContent, "0");

	ctx.listeners.get("play")();
	assert.ok(ctx.types().includes("pose-tracker:reset"));
	ctx.fire("pose-tracker:rep", { index: 3 });
	ctx.fire("pose-tracker:rep", { index: 4 });
	assert.equal(ctx.count.textContent, "2");

	ctx.el.currentTime = 1200;
	ctx.listeners.get("ended")();
	assert.deepEqual(ctx.pushes, [
		{ name: "video_ended", payload: { watched_sec: 1200, counted_reps: 2 } },
	]);
	assert.equal(ctx.types().at(-1), "pose-tracker:stop");
});

test("a camera that cannot start offers Retry, or carrying on without it", () => {
	const ctx = harness("42", { camera: true });
	ctx.runDeferred();
	ctx.fire("pose-tracker:start-failed", { reason: "denied" });
	assert.equal(ctx.tracker.dataset.stage, "failed");
	assert.equal(ctx.nodes["#video-camera-status"].textContent, "Camera unavailable");
	assert.equal(ctx.nodes["#video-camera-retry"].hidden, false);

	ctx.finishListeners.get("click")(clickOn("video-camera-retry"));
	assert.equal(ctx.tracker.dataset.stage, "setup");
	assert.equal(ctx.types().filter((t) => t === "pose-tracker:start").length, 2);

	ctx.fire("pose-tracker:start-failed", { reason: "denied" });
	ctx.finishListeners.get("click")(clickOn("video-camera-off"));
	assert.equal(ctx.tracker.dataset.stage, "off");
	assert.equal(ctx.tracker.hidden, true);

	// Without the camera the video plays as it always did, and the athlete counts.
	ctx.listeners.get("play")();
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
