import test from "node:test";
import assert from "node:assert/strict";
import SessionHook from "./session_hook.js";
import { initialFlowState } from "./session_flow_fsm.mjs";
import { initialSegmentState } from "./session_segment_fsm.mjs";
import {
	requestPreferredCameraStream,
	resolvePreviewVideo,
} from "./pose_tracker_impl.mjs";
import * as PoseTrackerDiagnostics from "./pose_tracker_impl.mjs";

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
	const renderedModels = [];
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	if (poseTrackerReady !== null) {
		const trackerVisibility = new FakeElement("div");
		trackerVisibility.id = "pose-tracker-visibility";
		const tracker = new FakeElement("div");
		tracker.id = "pose-tracker";
		if (poseTrackerReady) tracker.dataset.poseTrackerReady = "true";
		trackerVisibility.append(tracker);
		root.append(trackerVisibility);
	}

	const pauseActions = new FakeElement("div");
	pauseActions.id = "session-pause-actions";
	pauseActions.setAttribute("inert", "");
	const finishEarly = new FakeElement("button");
	finishEarly.id = "finish-early-btn";
	finishEarly.setAttribute("disabled", "disabled");
	const abort = new FakeElement("button");
	abort.id = "session-abort-btn";
	abort.setAttribute("disabled", "disabled");
	pauseActions.append(finishEarly, abort);
	root.append(pauseActions);

	const renderer = {
		resetReady() {},
		updateTotalCounter() {},
		updateTotalGoal() {},
		renderTimer() {},
		enterWorkPhase() {},
		triggerDown() {},
		updateCurrentSetRepCount() {},
		updateWorkFill() {},
		enterRestPhase() {},
		renderRestProgress() {},
		renderDisplayModel(model) {
			renderedModels.push(model);
		},
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
		lastDownCueKey: null,
		pushEvent(name, payload) {
			events.push({ name, payload });
		},
		events,
		renderedModels,
	};
}

function runTimedWorkoutToCompletion(ctx, workoutTimeline) {
	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline,
	});
	ctx.dispatchFlow({ type: "CAPTURE_TIMED" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });
	ctx.dispatchFlow({ type: "WORKOUT_READY" });
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });
	ctx.startTime = 0;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
}

test("capture prompt uses the mock hierarchy and stable actions", () => {
	const ctx = buildHarness();
	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline: [],
	});

	const overlay = ctx.el.querySelector("#start-overlay");
	assert.equal(overlay.children[0].textContent, "Track your workout?");
	assert.ok(ctx.el.querySelector("#capture-tracked-btn"));
	assert.ok(ctx.el.querySelector("#capture-timed-btn"));
});

test("warmup and ready prompts retain their stable action ids", () => {
	const ctx = buildHarness();
	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline: [],
	});
	ctx.dispatchFlow({ type: "CAPTURE_TIMED" });

	assert.equal(
		ctx.el.querySelector("#start-overlay").children[0].textContent,
		"Warm up first?",
	);
	assert.ok(ctx.el.querySelector("#warmup-yes-btn"));
	assert.ok(ctx.el.querySelector("#warmup-skip-btn"));

	ctx.dispatchFlow({ type: "WARMUP_SKIP" });
	assert.ok(ctx.el.querySelector("#workout-ready-btn"));
});

test("tracked camera prompt leaves preview rendering to PoseTracker", () => {
	const ctx = buildHarness({ poseTrackerReady: null });

	ctx.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline: [],
	});
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	assert.equal(ctx.el.querySelector("#pose-tracker-preview"), null);
	assert.match(ctx.el.querySelector("#start-overlay").className, /\bhidden\b/);
});

test("camera confirmation hides the patchable wrapper without unmounting PoseTracker", () => {
	const ctx = buildHarness();
	const wrapper = ctx.el.querySelector("#pose-tracker-visibility");
	const tracker = ctx.el.querySelector("#pose-tracker");

	ctx.onCameraSetupStart();

	assert.equal(wrapper.style.visibility, "hidden");
	assert.equal(wrapper.attributes.get("aria-hidden"), "true");
	assert.equal(ctx.el.querySelector("#pose-tracker"), tracker);
	assert.equal(tracker.removed, undefined);
	assert.deepEqual(ctx.events, [{ name: "camera_setup_started", payload: {} }]);
});

test("pose tracker binds only to the preview rendered inside its hook", () => {
	const root = new FakeElement("div");
	root.id = "burpee-session";
	globalThis.document.root = root;

	const stalePreview = new FakeElement("video");
	stalePreview.id = "pose-tracker-preview";
	root.append(stalePreview);

	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";
	const preview = new FakeElement("video");
	preview.id = "pose-tracker-preview";
	tracker.append(preview);
	root.append(tracker);

	assert.equal(resolvePreviewVideo({ el: tracker }), preview);
	assert.equal(preview.muted, true);
	assert.equal(preview.playsInline, true);
	assert.equal(preview.autoplay, true);
});

test("tracked pose overlay resizes and draws visible keypoints", () => {
	assert.equal(typeof PoseTrackerDiagnostics.resizePoseCanvas, "function");
	assert.equal(typeof PoseTrackerDiagnostics.drawPoseOverlay, "function");

	const calls = [];
	const context = {
		setTransform(...args) {
			calls.push(["setTransform", ...args]);
		},
		clearRect(...args) {
			calls.push(["clearRect", ...args]);
		},
		save() {
			calls.push(["save"]);
		},
		scale(...args) {
			calls.push(["scale", ...args]);
		},
		translate(...args) {
			calls.push(["translate", ...args]);
		},
		beginPath() {},
		moveTo(...args) {
			calls.push(["moveTo", ...args]);
		},
		lineTo(...args) {
			calls.push(["lineTo", ...args]);
		},
		stroke() {
			calls.push(["stroke"]);
		},
		arc(...args) {
			calls.push(["arc", ...args]);
		},
		fill() {
			calls.push(["fill"]);
		},
		restore() {
			calls.push(["restore"]);
		},
	};
	const canvas = {
		width: 0,
		height: 0,
		getBoundingClientRect() {
			return { width: 200, height: 300 };
		},
		getContext() {
			return context;
		},
	};
	const video = { videoWidth: 400, videoHeight: 600 };
	const pose = {
		keypoints: [
			{ name: "left_shoulder", x: 100, y: 150, score: 0.9 },
			{ name: "right_shoulder", x: 300, y: 150, score: 0.9 },
			{ name: "nose", x: 200, y: 50, score: 0.1 },
		],
	};

	PoseTrackerDiagnostics.resizePoseCanvas(canvas, 2);
	PoseTrackerDiagnostics.drawPoseOverlay(canvas, pose, video, "#fff");

	assert.equal(canvas.width, 400);
	assert.equal(canvas.height, 600);
	assert.deepEqual(
		calls.find(([name]) => name === "setTransform"),
		["setTransform", 2, 0, 0, 2, 0, 0],
	);
	assert.deepEqual(
		calls.find(([name]) => name === "moveTo"),
		["moveTo", 50, 75],
	);
	assert.deepEqual(
		calls.find(([name]) => name === "lineTo"),
		["lineTo", 150, 75],
	);
	assert.equal(calls.filter(([name]) => name === "arc").length, 2);
});

test("camera preview diagnostics report the rendered video boundary", () => {
	assert.equal(typeof PoseTrackerDiagnostics.previewDiagnostics, "function");

	const video = {
		isConnected: true,
		videoWidth: 1920,
		videoHeight: 1080,
		readyState: 4,
		paused: false,
		parentElement: { id: "pose-tracker-preview-frame" },
		getBoundingClientRect() {
			return { width: 0, height: 0 };
		},
	};

	assert.deepEqual(PoseTrackerDiagnostics.previewDiagnostics(video), {
		connected: true,
		rendered_width: 0,
		rendered_height: 0,
		video_width: 1920,
		video_height: 1080,
		ready_state: 4,
		paused: false,
		parent_id: "pose-tracker-preview-frame",
	});
});

test("camera selection matches the working debug page", async () => {
	const calls = [];
	const stream = { id: "front-camera" };
	const mediaDevices = {
		async getUserMedia(constraints) {
			calls.push(constraints);
			return stream;
		},
		async enumerateDevices() {
			throw new Error("the debug camera path does not enumerate devices");
		},
	};

	assert.equal(await requestPreferredCameraStream(mediaDevices), stream);
	assert.deepEqual(calls, [{ video: { facingMode: "user" }, audio: false }]);
});

test("pause actions are inert and disabled whenever hidden", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const actions = ctx.el.querySelector("#session-pause-actions");
	const finishEarly = ctx.el.querySelector("#finish-early-btn");
	const abort = ctx.el.querySelector("#session-abort-btn");
	ctx.activeSegment = "workout";
	ctx.startTime = 0;
	ctx.paused = true;

	ctx.updatePauseActionsVisibility();
	assert.equal(actions.style.opacity, "1");
	assert.equal(actions.style.pointerEvents, "auto");
	assert.equal(actions.attributes.get("aria-hidden"), "false");
	assert.equal(actions.hasAttribute("inert"), false);
	assert.equal(finishEarly.hasAttribute("disabled"), false);
	assert.equal(abort.hasAttribute("disabled"), false);

	ctx.paused = false;
	ctx.updatePauseActionsVisibility();
	assert.equal(actions.style.opacity, "0");
	assert.equal(actions.style.pointerEvents, "none");
	assert.equal(actions.attributes.get("aria-hidden"), "true");
	assert.equal(actions.hasAttribute("inert"), true);
	assert.equal(finishEarly.hasAttribute("disabled"), true);
	assert.equal(abort.hasAttribute("disabled"), true);
});

test("running frames derive rest set progress from the hook timeline", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const timeline = Object.freeze([
		Object.freeze({ kind: "work", reps: 6, sec_per_rep: 4 }),
		Object.freeze({ kind: "rest", duration_sec: 30 }),
		Object.freeze({ kind: "work", reps: 6, sec_per_rep: 4 }),
		Object.freeze({ kind: "rest", duration_sec: 30 }),
		Object.freeze({ kind: "work", reps: 8, sec_per_rep: 4 }),
	]);

	ctx.dispatchSegment({
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 20,
	});
	ctx.activeSegment = "workout";
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });
	ctx.renderRunningFrame(30);

	assert.equal(ctx.renderedModels.length, 1);
	assert.equal(ctx.renderedModels[0].setProgress, "1/3");
	assert.equal(ctx.renderedModels[0].sessionProgress, 30 / 140);

	const warmupCtx = buildHarness({ poseTrackerReady: null });
	warmupCtx.dispatchSegment({
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 20,
	});
	warmupCtx.activeSegment = "warmup";
	warmupCtx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });
	warmupCtx.renderRunningFrame(30);
	assert.equal(warmupCtx.renderedModels[0].sessionProgress, null);
});

test("countdown pause enables Abort but keeps Finish early disabled", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const actions = ctx.el.querySelector("#session-pause-actions");
	const finishEarly = ctx.el.querySelector("#finish-early-btn");
	const abort = ctx.el.querySelector("#session-abort-btn");
	ctx.activeSegment = "workout";
	ctx.startTime = null;
	ctx.countdownPaused = true;

	ctx.updatePauseActionsVisibility();

	assert.equal(actions.hasAttribute("inert"), false);
	assert.equal(actions.attributes.get("aria-hidden"), "false");
	assert.equal(actions.style.pointerEvents, "auto");
	assert.equal(finishEarly.hasAttribute("disabled"), true);
	assert.equal(abort.hasAttribute("disabled"), false);
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
