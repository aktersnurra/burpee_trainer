import test from "node:test";
import assert from "node:assert/strict";
import SessionHook from "./session_hook.js";
import { initialFlowState } from "./session_flow_fsm.mjs";
import { initialSegmentState } from "./session_segment_fsm.mjs";
import {
	requestPreferredCameraStream,
	resolvePreviewVideo,
} from "./pose_tracker_impl.mjs";

class FakeElement {
	constructor(tagName = "div") {
		this.tagName = tagName;
		this.children = [];
		this.id = "";
		this.type = "";
		this.className = "";
		this.textContent = "";
		this.style = {};
		this.attributes = new Map();
		this.dataset = {};
		this.listeners = new Map();
	}

	setAttribute(name, value) {
		this.attributes.set(name, String(value));
	}

	removeAttribute(name) {
		this.attributes.delete(name);
	}

	hasAttribute(name) {
		return this.attributes.has(name);
	}

	append(...children) {
		this.children.push(...children);
	}

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	replaceChildren(...children) {
		this.children = [];
		this.append(...children);
	}

	remove() {
		this.removed = true;
	}

	addEventListener(type, listener) {
		const listeners = this.listeners.get(type) || [];
		listeners.push(listener);
		this.listeners.set(type, listeners);
	}

	dispatchEvent(event) {
		for (const listener of this.listeners.get(event.type) || []) {
			listener.call(this, event);
		}

		return true;
	}

	querySelector(selector) {
		if (selector.startsWith("#")) return this.findById(selector.slice(1));
		return null;
	}

	findById(id) {
		if (this.id === id) return this;

		for (const child of this.children) {
			const found = child.findById?.(id);
			if (found) return found;
		}

		return null;
	}
}

globalThis.CustomEvent = class {
	constructor(type, init = {}) {
		this.type = type;
		this.detail = init.detail;
	}
};

globalThis.document = {
	root: null,
	createElement(tagName) {
		return new FakeElement(tagName);
	},
	getElementById(id) {
		return this.root?.findById(id) || null;
	},
	dispatchEvent() {},
};

globalThis.performance = {
	now() {
		return 0;
	},
};

globalThis.requestAnimationFrame = () => 1;
globalThis.cancelAnimationFrame = () => {};
globalThis.setTimeout = () => 1;
globalThis.clearTimeout = () => {};

function buildHarness({ poseTrackerReady = false } = {}) {
	const events = [];
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	if (poseTrackerReady !== null) {
		const tracker = new FakeElement("div");
		tracker.id = "pose-tracker";
		if (poseTrackerReady) tracker.dataset.poseTrackerReady = "true";
		root.append(tracker);
	}

	const renderer = {
		resetReady() {},
		updateTotalCounter() {},
		updateTotalGoal() {},
		renderTimer() {},
		enterWorkPhase() {},
		triggerDown() {},
		updateCurrentSetRepCount() {},
		updateWorkRing() {},
		enterRestPhase() {},
		renderRestProgress() {},
		renderDisplayModel() {},
		updatePauseButton() {},
		clearTimers() {},
	};

	const audio = {
		ensureRunning() {},
		stop() {},
		playLeadBeep() {},
		playRepBeep() {},
	};

	const wakeLock = {
		acquire() {},
		release() {},
		reacquireWhenVisible() {},
	};

	return {
		...SessionHook,
		el: root,
		renderer,
		audio,
		wakeLock,
		flow: initialFlowState(),
		segment: initialSegmentState(),
		activeSegment: null,
		timeline: [],
		startTime: null,
		paused: false,
		rafId: null,
		countdownPaused: false,
		countdownCount: null,
		countdownTimeoutId: null,
		setGlyphBlocks: [],
		lastDownCueKey: null,
		pushEvent(name, payload) {
			events.push({ name, payload });
		},
		events,
	};
}

function runTimedWorkoutToCompletion(ctx, workoutTimeline) {
	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline,
		blockCount: 1,
	});
	ctx.dispatchFlow({ type: "CAPTURE_TIMED" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });
	ctx.dispatchFlow({ type: "WORKOUT_READY" });
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });
	ctx.startTime = 0;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
}

test("tracked camera setup renders a visible mobile preview video", () => {
	const ctx = buildHarness({ poseTrackerReady: null });

	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline: [],
		blockCount: 1,
	});
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	const preview = ctx.el.querySelector("#pose-tracker-preview");
	assert.ok(preview);
	assert.equal(preview.tagName, "video");
	assert.equal(preview.muted, true);
	assert.equal(preview.playsInline, true);
	assert.equal(preview.autoplay, true);
});

test("pose tracker binds camera stream to the visible setup preview", () => {
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	const preview = new FakeElement("video");
	preview.id = "pose-tracker-preview";
	root.append(preview);

	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";
	root.append(tracker);

	assert.equal(resolvePreviewVideo({ el: tracker }), preview);
	assert.equal(preview.muted, true);
	assert.equal(preview.playsInline, true);
	assert.equal(preview.autoplay, true);
});

test("camera selection prefers exposed ultra-wide device", async () => {
	const stopped = [];
	const calls = [];
	const mediaDevices = {
		async getUserMedia(constraints) {
			calls.push(constraints);
			const id = `stream-${calls.length}`;
			return {
				id,
				getTracks() {
					return [
						{
							stop() {
								stopped.push(id);
							},
						},
					];
				},
				getVideoTracks() {
					return [];
				},
			};
		},
		async enumerateDevices() {
			return [
				{ kind: "videoinput", deviceId: "front", label: "Front Camera" },
				{
					kind: "videoinput",
					deviceId: "ultra-wide",
					label: "Back Ultra Wide Camera",
				},
			];
		},
	};

	const stream = await requestPreferredCameraStream(mediaDevices);

	assert.equal(stream.id, "stream-2");
	assert.deepEqual(stopped, ["stream-1"]);
	assert.deepEqual(calls, [
		{ video: { facingMode: { ideal: "environment" } }, audio: false },
		{
			video: {
				deviceId: { exact: "ultra-wide" },
				facingMode: { ideal: "environment" },
			},
			audio: false,
		},
	]);
});

test("camera selection applies minimum zoom when supported", async () => {
	let appliedConstraints = null;
	const mediaDevices = {
		async getUserMedia() {
			return {
				getTracks() {
					return [];
				},
				getVideoTracks() {
					return [
						{
							getCapabilities() {
								return { zoom: { min: 0.5, max: 3 } };
							},
							async applyConstraints(constraints) {
								appliedConstraints = constraints;
							},
						},
					];
				},
			};
		},
		async enumerateDevices() {
			return [];
		},
	};

	await requestPreferredCameraStream(mediaDevices);

	assert.deepEqual(appliedConstraints, { advanced: [{ zoom: 0.5 }] });
});

test("timed workout completion pushes log payload with completed reps", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const workoutTimeline = [{ kind: "work", reps: 5, sec_per_rep: 2 }];

	runTimedWorkoutToCompletion(ctx, workoutTimeline);

	assert.deepEqual(ctx.events, [
		{
			name: "session_complete",
			payload: {
				warmup: { burpee_count_done: 0, duration_sec: 0 },
				main: { burpee_count_done: 5, duration_sec: 10 },
			},
		},
	]);
});

test("tracked workout completion sends finish to ready pose tracker", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	let finishDetail = null;
	tracker.addEventListener("pose-tracker:finish", (event) => {
		finishDetail = event.detail;
	});

	const workoutTimeline = [{ kind: "work", reps: 5, sec_per_rep: 2 }];

	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline,
		blockCount: 1,
	});
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });
	ctx.dispatchFlow({ type: "WORKOUT_READY" });
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });
	ctx.startTime = 0;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });

	assert.deepEqual(
		ctx.events.filter((event) => event.name === "session_complete"),
		[],
	);
	assert.deepEqual(finishDetail, { durationMs: 10_000 });
});
