import test from "node:test";
import assert from "node:assert/strict";
import SessionHook from "./session_hook.js";
import { initialFlowState } from "./session_flow_fsm.mjs";
import { initialSegmentState } from "./session_segment_fsm.mjs";
import {
	initialTrackingObserver,
	updateTrackingStatus,
} from "./pose_tracking_observer.mjs";
import {
	createPoseTracker,
	requestPreferredCameraStream,
	resolvePreviewVideo,
	trackingFinishPayload,
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

	removeEventListener(type, listener) {
		const listeners = this.listeners.get(type) || [];
		this.listeners.set(
			type,
			listeners.filter((candidate) => candidate !== listener),
		);
	}

	listenerCount(type) {
		return (this.listeners.get(type) || []).length;
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
		this.bubbles = Boolean(init.bubbles);
	}
};

const documentListeners = new Map();
globalThis.document = {
	root: null,
	documentElement: {},
	visibilityState: "visible",
	createElement(tagName) {
		return new FakeElement(tagName);
	},
	getElementById(id) {
		return this.root?.findById(id) || null;
	},
	addEventListener(type, listener) {
		const listeners = documentListeners.get(type) || [];
		listeners.push(listener);
		documentListeners.set(type, listeners);
	},
	removeEventListener(type, listener) {
		const listeners = documentListeners.get(type) || [];
		documentListeners.set(
			type,
			listeners.filter((candidate) => candidate !== listener),
		);
	},
	dispatchEvent(event) {
		for (const listener of documentListeners.get(event.type) || []) {
			listener.call(this, event);
		}
	},
};

globalThis.getComputedStyle = () => ({
	getPropertyValue() {
		return "";
	},
});

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
	const downCueValues = [];
	const totalUpdates = [];
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
		updateTotalCounter(value) {
			totalUpdates.push(value);
		},
		updateTotalGoal() {},
		renderTimer() {},
		enterWorkPhase() {},
		triggerDown(value) {
			downCueValues.push(value);
		},
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
		close() {},
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
		downCueValues,
		totalUpdates,
	};
}

function trackedContext(timeline) {
	const ctx = buildHarness({ poseTrackerReady: true });
	ctx.activeSegment = "workout";
	ctx.timeline = timeline;
	ctx.segment = {
		...initialSegmentState(),
		mode: "running",
		timeline,
		clock: {
			...initialSegmentState().clock,
			elapsedSec: 2.5,
			totalDurationSec: 10,
		},
	};
	ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
	ctx.trackerReadiness = "ready";
	ctx.startPoseObservation();
	return ctx;
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

function mountedTrackedCountdown(timeline) {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;
	ctx.activeSegment = "workout";
	ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
	ctx.trackerReadiness = "ready";
	ctx.dispatchSegment({
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: timeline[0].reps,
	});
	ctx.dispatchSegment({ type: "COUNTDOWN_START", now: performance.now() });
	return ctx;
}

test("tracked reps use session elapsed time without updating visible reps", () => {
	const ctx = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);

	ctx.observePoseRep({ index: 1, confidence: 0.9 });

	assert.deepEqual(ctx.tracking.cadenceMs, [2_500]);
	assert.deepEqual(ctx.totalUpdates, []);
});

test("explicit rest and pause candidate reps are ignored", () => {
	const resting = trackedContext([{ kind: "rest", duration_sec: 10 }]);
	resting.observePoseRep({ index: 1, confidence: 0.9 });
	assert.deepEqual(resting.tracking.cadenceMs, []);

	const paused = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);
	paused.segment = { ...paused.segment, mode: "paused" };
	paused.observePoseRep({ index: 1, confidence: 0.9 });
	assert.deepEqual(paused.tracking.cadenceMs, []);
});

test("tracking loss keeps workout state but forces timer fallback", () => {
	const ctx = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);
	const timelineBefore = ctx.timeline;
	ctx.updatePoseStatus({ state: "lost" });

	assert.equal(ctx.segment.mode, "running");
	assert.equal(ctx.timeline, timelineBefore);
	assert.equal(ctx.pushTrackedFinish({ main: { duration_sec: 10 } }), false);
	assert.equal(ctx.trackingCompletion.reason, "tracking_lost");
});

test("count-in hidden and done candidate reps are ignored", () => {
	for (const mode of ["countdown", "done"]) {
		const ctx = trackedContext([
			{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
		]);
		ctx.segment = { ...ctx.segment, mode };
		ctx.observePoseRep({ index: 1 });
		assert.deepEqual(ctx.tracking.cadenceMs, []);
	}

	const hidden = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);
	hidden.segment = {
		...hidden.segment,
		clock: { ...hidden.segment.clock, hiddenAt: 1_000 },
	};
	hidden.observePoseRep({ index: 1 });
	assert.deepEqual(hidden.tracking.cadenceMs, []);
});

test("countdown completion while hidden records hidden state and rejects a rep", () => {
	const originalNow = performance.now;
	const originalVisibility = document.visibilityState;
	performance.now = () => 500;
	document.visibilityState = "hidden";
	const ctx = mountedTrackedCountdown([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);

	try {
		ctx.beginSegment();
		ctx.observePoseRep({ index: 1 });

		assert.equal(ctx.segment.mode, "running");
		assert.equal(ctx.segment.clock.startTime, 500);
		assert.equal(ctx.segment.clock.hiddenAt, 500);
		assert.equal(ctx.hiddenAt, 500);
		assert.equal(ctx.rafId, null);
		assert.deepEqual(ctx.tracking.cadenceMs, []);
	} finally {
		ctx.destroyed();
		performance.now = originalNow;
		document.visibilityState = originalVisibility;
	}
});

test("hidden work candidates are rejected before visibility dispatch", () => {
	const originalVisibility = document.visibilityState;
	const ctx = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);

	try {
		document.visibilityState = "hidden";
		ctx.observePoseRep({ index: 1 });

		assert.equal(ctx.segment.mode, "running");
		assert.equal(ctx.segment.clock.hiddenAt, null);
		assert.deepEqual(ctx.tracking.cadenceMs, []);
	} finally {
		document.visibilityState = originalVisibility;
	}
});

test("visibility restoration after hidden countdown resumes at zero elapsed", () => {
	const originalNow = performance.now;
	const originalVisibility = document.visibilityState;
	let now = 500;
	performance.now = () => now;
	document.visibilityState = "hidden";
	const ctx = mountedTrackedCountdown([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);

	try {
		ctx.beginSegment();
		now = 800;
		document.visibilityState = "visible";
		ctx.onVisibility();
		ctx.tick();

		assert.equal(ctx.segment.mode, "running");
		assert.equal(ctx.segment.clock.startTime, 800);
		assert.equal(ctx.segment.clock.hiddenAt, null);
		assert.equal(ctx.segment.clock.elapsedSec, 0);
	} finally {
		ctx.destroyed();
		performance.now = originalNow;
		document.visibilityState = originalVisibility;
	}
});

test("hidden pause overlap resumes once and accepts the next work rep", () => {
	const originalNow = performance.now;
	const originalVisibility = document.visibilityState;
	let now = 100;
	performance.now = () => now;
	document.visibilityState = "visible";
	const ctx = mountedTrackedCountdown([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);

	try {
		ctx.beginSegment();
		now = 500;
		document.visibilityState = "hidden";
		ctx.onVisibility();
		now = 700;
		ctx.pause();
		now = 800;
		document.visibilityState = "visible";
		ctx.onVisibility();
		now = 1_000;
		ctx.resume();
		now = 1_200;
		ctx.tick();
		ctx.observePoseRep({ index: 1 });

		assert.equal(ctx.segment.mode, "running");
		assert.equal(ctx.segment.clock.startTime, 600);
		assert.equal(ctx.segment.clock.pauseTime, null);
		assert.equal(ctx.segment.clock.hiddenAt, null);
		assert.equal(ctx.hiddenAt, null);
		assert.equal(ctx.segment.clock.elapsedSec, 0.6);
		assert.deepEqual(ctx.tracking.cadenceMs, [600]);
	} finally {
		ctx.destroyed();
		performance.now = originalNow;
		document.visibilityState = originalVisibility;
	}
});

test("main-work start resets the detector and starts observation", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	let resets = 0;
	tracker.addEventListener("pose-tracker:reset", () => {
		resets += 1;
	});
	ctx.activeSegment = "workout";
	ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
	ctx.trackerReadiness = "ready";
	ctx.dispatchSegment({
		type: "SEGMENT_READY",
		timeline: [{ kind: "work", reps: 2, sec_per_rep: 4 }],
		burpeeCountTarget: 2,
	});
	ctx.dispatchSegment({ type: "COUNTDOWN_START", now: 0 });

	ctx.beginSegment();

	assert.equal(resets, 1);
	assert.equal(ctx.tracking.mode, "observing");
});

test("detector reset after resume preserves accepted cadence", () => {
	const ctx = trackedContext([
		{ kind: "work", reps: 2, sec_per_rep: 4, sec_per_burpee: 3 },
	]);
	const tracker = ctx.el.querySelector("#pose-tracker");
	let resets = 0;
	tracker.addEventListener("pose-tracker:reset", () => {
		resets += 1;
	});
	ctx.observePoseRep({ index: 1 });
	ctx.segment = {
		...ctx.segment,
		mode: "paused",
		clock: { ...ctx.segment.clock, startTime: 0, pauseTime: 0 },
	};
	ctx.paused = true;
	ctx.startTime = 0;

	ctx.resume();
	ctx.segment = {
		...ctx.segment,
		clock: { ...ctx.segment.clock, elapsedSec: 3.5 },
	};
	ctx.observePoseRep({ index: 2 });

	assert.equal(resets, 1);
	assert.deepEqual(ctx.tracking.cadenceMs, [2_500, 3_500]);
	assert.equal(ctx.tracking.lastIndex, 2);
	assert.equal(ctx.tracking.mode, "observing");
});

const trackerPoint = (score = 0.9, x = 0.5, y = 0.5) => ({ score, x, y });

function trackerSample({
	tMs = 0,
	closeness = 0.2,
	confidence = 0.9,
	leftWristY = null,
} = {}) {
	return {
		tMs,
		closeness,
		confidence,
		features: { visibleFraction: 0.5 },
		keypoints: {
			left_shoulder: trackerPoint(0.9, 0.42, 0.25),
			right_shoulder: trackerPoint(0.9, 0.58, 0.25),
			left_hip: trackerPoint(0.9, 0.45, 0.5),
			right_hip: trackerPoint(0.9, 0.55, 0.5),
			left_knee: trackerPoint(0.9, 0.46, 0.72),
			...(leftWristY === null
				? {}
				: { left_wrist: trackerPoint(0.9, 0.42, leftWristY) }),
		},
	};
}

function trackerFrame(sample, poseCount = 1) {
	return {
		poses: Array.from({ length: poseCount }, () => ({})),
		sample,
	};
}

function buildPoseTrackerHarness(frames = [], { holdDetector = false } = {}) {
	const pushes = [];
	const localEvents = [];
	const animationFrames = [];
	const tracker = new FakeElement("div");
	tracker.id = "pose-tracker";

	const video = new FakeElement("video");
	video.id = "pose-tracker-preview";
	video.videoWidth = 640;
	video.videoHeight = 480;
	video.readyState = 4;
	video.paused = false;
	video.play = async () => {};
	video.getBoundingClientRect = () => ({ width: 320, height: 240 });

	const context = {
		setTransform() {},
		clearRect() {},
	};
	const canvas = new FakeElement("canvas");
	canvas.id = "pose-tracker-canvas";
	canvas.getBoundingClientRect = () => ({ width: 320, height: 240 });
	canvas.getContext = () => context;
	tracker.append(video, canvas);

	for (const type of [
		"pose-tracker:readiness",
		"pose-tracker:rep",
		"pose-tracker:status",
		"pose-tracker:gesture-confirm",
		"pose-tracker:gesture-timeout",
	]) {
		tracker.addEventListener(type, (event) => localEvents.push(event));
	}

	let nowMs = 0;
	let currentFrame = null;
	let consumedFrames = 0;
	const stoppedTrack = {
		stopped: false,
		stop() {
			this.stopped = true;
		},
	};
	const detector = {
		disposed: false,
		estimatePoses() {
			if (holdDetector) return new Promise(() => {});
			currentFrame = frames[consumedFrames];
			if (!currentFrame) throw new Error("unexpected pose frame");
			consumedFrames += 1;
			return currentFrame.poses;
		},
		dispose() {
			this.disposed = true;
		},
	};

	let nextTimeoutId = 1;
	const scheduledTimeouts = new Map();
	const clearedTimeoutIds = [];

	const hook = {
		el: tracker,
		pushEvent(name, payload) {
			pushes.push({ name, payload });
		},
	};
	const poseTracker = createPoseTracker(hook, {
		createBlazePoseDetector: async () => detector,
		mediaDevices: {
			async getUserMedia() {
				return { getTracks: () => [stoppedTrack] };
			},
		},
		now: () => nowMs,
		requestAnimationFrame(callback) {
			animationFrames.push(callback);
			return animationFrames.length;
		},
		cancelAnimationFrame() {},
		sampleFromPose: () => currentFrame.sample,
		waitForVideoFrame: async () => video,
		webglAvailable: () => true,
		setTimeout(callback) {
			const id = nextTimeoutId;
			nextTimeoutId += 1;
			scheduledTimeouts.set(id, callback);
			return id;
		},
		clearTimeout(id) {
			clearedTimeoutIds.push(id);
			scheduledTimeouts.delete(id);
		},
	});

	const settle = async () => {
		await Promise.resolve();
		await Promise.resolve();
	};

	return {
		tracker,
		pushes,
		localEvents,
		detector,
		poseTracker,
		scheduledTimeouts,
		clearedTimeoutIds,
		fireTimeout(id) {
			const callback = scheduledTimeouts.get(id);
			assert.ok(callback, `no timeout scheduled with id ${id}`);
			scheduledTimeouts.delete(id);
			callback();
		},
		get consumedFrames() {
			return consumedFrames;
		},
		async mount() {
			await poseTracker.mounted();
			await settle();
		},
		async runUntilConsumed(expectedCount) {
			await settle();
			while (consumedFrames < expectedCount) {
				nowMs += 100;
				const callback = animationFrames.shift();
				assert.ok(
					callback,
					`missing animation frame before sample ${expectedCount}`,
				);
				await callback();
				await settle();
			}
		},
	};
}

test("session hook removes pose observer listeners on destroy", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	ctx.handleEvent = () => {};

	ctx.mounted();

	assert.equal(ctx.el.listenerCount("pose-tracker:rep"), 1);
	assert.equal(ctx.el.listenerCount("pose-tracker:status"), 1);
	assert.equal(ctx.el.listenerCount("pose-tracker:readiness"), 1);
	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:readiness", {
			detail: { state: "ready" },
			bubbles: true,
		}),
	);
	assert.equal(ctx.trackerReadiness, "ready");

	ctx.destroyed();

	assert.equal(ctx.el.listenerCount("pose-tracker:rep"), 0);
	assert.equal(ctx.el.listenerCount("pose-tracker:status"), 0);
	assert.equal(ctx.el.listenerCount("pose-tracker:readiness"), 0);
});

test("visibility restoration resets detector phase", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.activeSegment = "workout";
	ctx.timeline = [{ kind: "work", reps: 2, sec_per_rep: 4 }];
	ctx.segment = {
		...initialSegmentState(),
		mode: "running",
		timeline: ctx.timeline,
		clock: {
			...initialSegmentState().clock,
			startTime: 100,
			totalDurationSec: 8,
		},
	};
	ctx.startTime = 100;
	let resets = 0;
	tracker.addEventListener("pose-tracker:reset", () => {
		resets += 1;
	});
	const originalNow = performance.now;
	const originalVisibility = document.visibilityState;
	let now = 500;
	performance.now = () => now;

	try {
		document.visibilityState = "hidden";
		ctx.onVisibility();
		now = 800;
		document.visibilityState = "visible";
		ctx.onVisibility();

		assert.equal(resets, 1);
	} finally {
		performance.now = originalNow;
		document.visibilityState = originalVisibility;
		ctx.destroyed();
	}
});

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

test("camera confirmation is ignored until stable pose readiness", () => {
	const ctx = buildHarness();
	const wrapper = ctx.el.querySelector("#pose-tracker-visibility");

	ctx.onCameraSetupStart();

	assert.equal(wrapper.style.visibility, undefined);
	assert.equal(wrapper.attributes.get("aria-hidden"), undefined);
	assert.deepEqual(ctx.events, []);
});

test("camera confirmation hides the patchable wrapper without unmounting PoseTracker", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const wrapper = ctx.el.querySelector("#pose-tracker-visibility");
	const tracker = ctx.el.querySelector("#pose-tracker");

	ctx.onCameraSetupStart();

	assert.equal(wrapper.style.visibility, "hidden");
	assert.equal(wrapper.attributes.get("aria-hidden"), "true");
	assert.equal(ctx.el.querySelector("#pose-tracker"), tracker);
	assert.equal(tracker.removed, undefined);
	assert.deepEqual(ctx.events, [{ name: "camera_setup_started", payload: {} }]);
});

test("camera setup timer fallback returns to the ordinary timed warmup flow", () => {
	const ctx = buildHarness();
	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	ctx.onCameraSetupTimed();

	assert.deepEqual(ctx.events.at(-1), {
		name: "fallback_to_timed",
		payload: {},
	});
	assert.equal(ctx.flow.captureMode, "timed");
	assert.equal(ctx.flow.mode, "warmup_prompt");
	assert.ok(ctx.el.querySelector("#warmup-yes-btn"));
	assert.ok(ctx.el.querySelector("#warmup-skip-btn"));
});

test("camera setup prompt arms the pose tracker for the camera_setup step", () => {
	const ctx = buildHarness({ poseTrackerReady: false });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "camera_setup",
		holdFramesRequired: 15,
	});
});

test("gesture-confirm on the pose tracker triggers camera setup start", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;
	const wrapper = ctx.el.querySelector("#pose-tracker-visibility");

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });

	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(wrapper.style.visibility, "hidden");
	assert.deepEqual(ctx.events.at(-1), {
		name: "camera_setup_started",
		payload: {},
	});
});

test("warmup prompt arms the warmup step and hides tap buttons for tracked mode", () => {
	const ctx = buildHarness({ poseTrackerReady: false });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "warmup",
		holdFramesRequired: 15,
	});
	assert.match(
		ctx.el.querySelector("#warmup-yes-btn").className,
		/\bhidden\b/,
	);
	assert.match(
		ctx.el.querySelector("#warmup-skip-btn").className,
		/\bhidden\b/,
	);
});

test("warmup prompt leaves tap buttons visible for timer mode", () => {
	const ctx = buildHarness();
	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TIMED" });

	assert.doesNotMatch(
		ctx.el.querySelector("#warmup-yes-btn").className,
		/\bhidden\b/,
	);
});

test("gesture-confirm on the pose tracker during warmup answers yes", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "warmup_countdown");
});

test("gesture-timeout on the pose tracker during warmup skips warmup", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });

	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-timeout", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "workout_ready_prompt");
});

test("start-workout prompt arms the workout_start step with a longer hold and hides the tap button for tracked mode", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	assert.deepEqual(armedEvents.at(-1), {
		step: "workout_start",
		holdFramesRequired: 30,
	});
	assert.match(
		ctx.el.querySelector("#workout-ready-btn").className,
		/\bhidden\b/,
	);
});

test("gesture-confirm on the pose tracker during start-workout prompt starts the workout", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:gesture-confirm", { bubbles: true }),
	);

	assert.equal(ctx.flow.mode, "workout_countdown");
});

test("starting the workout disarms the pose tracker so mid-workout arm-raises are ignored", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const armedEvents = [];
	tracker.addEventListener("pose-tracker:arm", (event) => {
		armedEvents.push(event.detail);
	});

	ctx.dispatchFlow({ type: "SESSION_READY", workoutTimeline: [] });
	ctx.dispatchFlow({ type: "CAPTURE_TRACKED" });
	ctx.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	ctx.dispatchFlow({ type: "WARMUP_SKIP" });

	ctx.onWorkoutReady();

	assert.deepEqual(armedEvents.at(-1), { step: null, holdFramesRequired: 0 });
});

test("armed camera-setup step dispatches gesture-confirm when wrist streak completes", async () => {
	const raisedFrames = Array.from({ length: 3 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100, leftWristY: 0.1 })),
	);
	const harness = buildPoseTrackerHarness(raisedFrames);

	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 3 },
		}),
	);

	await harness.mount();
	await harness.runUntilConsumed(3);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:gesture-confirm")
			.map(({ type }) => type),
		["pose-tracker:gesture-confirm"],
	);

	harness.poseTracker.destroyed();
});

test("camera setup auto-timer confirms without a gesture", async () => {
	const notRaisedFrames = Array.from({ length: 2 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const harness = buildPoseTrackerHarness(notRaisedFrames);

	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 15 },
		}),
	);

	await harness.mount();
	await harness.runUntilConsumed(2);

	assert.equal(harness.scheduledTimeouts.size, 1);
	const [timeoutId] = harness.scheduledTimeouts.keys();
	harness.fireTimeout(timeoutId);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:gesture-confirm")
			.map(({ type }) => type),
		["pose-tracker:gesture-confirm"],
	);

	harness.poseTracker.destroyed();
});

test("armed warmup step dispatches gesture-timeout when no gesture arrives", async () => {
	const notRaisedFrames = Array.from({ length: 2 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const harness = buildPoseTrackerHarness(notRaisedFrames);

	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "warmup", holdFramesRequired: 15 },
		}),
	);

	await harness.mount();
	await harness.runUntilConsumed(2);

	assert.equal(harness.scheduledTimeouts.size, 1);
	const [timeoutId] = harness.scheduledTimeouts.keys();
	harness.fireTimeout(timeoutId);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:gesture-timeout")
			.map(({ type }) => type),
		["pose-tracker:gesture-timeout"],
	);

	harness.poseTracker.destroyed();
});

test("gesture confirm during camera-setup arm cancels the pending auto-timer", async () => {
	const raisedFrames = Array.from({ length: 2 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100, leftWristY: 0.1 })),
	);
	const harness = buildPoseTrackerHarness(raisedFrames);

	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 2 },
		}),
	);

	await harness.mount();
	await harness.runUntilConsumed(2);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:gesture-confirm")
			.map(({ type }) => type),
		["pose-tracker:gesture-confirm"],
	);
	assert.equal(harness.scheduledTimeouts.size, 0);
	assert.equal(harness.clearedTimeoutIds.length, 1);

	harness.poseTracker.destroyed();
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

test("tracker finish uses observer cadence instead of tracker-relative time", () => {
	assert.deepEqual(
		trackingFinishPayload({
			durationMs: 10_000,
			cadenceMs: [2_500, 5_100],
		}),
		{
			reps: 2,
			duration_ms: 10_000,
			cadence_ms: [2_500, 5_100],
		},
	);
});

test("detector initialization reports initialized without marking pose readiness", async () => {
	const harness = buildPoseTrackerHarness([], { holdDetector: true });

	await harness.mount();

	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.deepEqual(
		harness.pushes.filter(({ name }) => name.startsWith("tracker_")),
		[{ name: "tracker_initialized", payload: {} }],
	);
	harness.poseTracker.destroyed();
});

test("readiness transitions update the dataset and emit local and server events", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const lostFrames = Array.from({ length: 3 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: 800 + index * 100 }), 0),
	);
	const harness = buildPoseTrackerHarness([...readyFrames, ...lostFrames]);

	await harness.mount();
	await harness.runUntilConsumed(8);
	assert.equal(harness.tracker.dataset.poseTrackerReady, "true");

	await harness.runUntilConsumed(11);
	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:readiness")
			.map(({ bubbles, detail }) => ({ bubbles, detail })),
		[
			{ bubbles: true, detail: { state: "ready" } },
			{ bubbles: true, detail: { state: "not_ready" } },
		],
	);
	assert.deepEqual(
		harness.pushes.filter(({ name }) => name === "tracker_readiness"),
		[
			{ name: "tracker_readiness", payload: { state: "ready" } },
			{ name: "tracker_readiness", payload: { state: "not_ready" } },
		],
	);
	harness.poseTracker.destroyed();
});

test("accepted rep emits only a bubbling local candidate", async () => {
	const harness = buildPoseTrackerHarness(
		[0.2, 0.5, 0.25, 0.2].map((closeness, index) =>
			trackerFrame(
				trackerSample({ tMs: [0, 500, 900, 1_100][index], closeness }),
			),
		),
	);

	await harness.mount();
	await harness.runUntilConsumed(4);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:rep")
			.map(({ bubbles, detail }) => ({ bubbles, detail })),
		[{ bubbles: true, detail: { index: 1, confidence: 0.9 } }],
	);
	assert.equal(
		harness.pushes.some(({ name }) => name === "rep"),
		false,
	);
	harness.poseTracker.destroyed();
});

test("tracker reset clears detector phase but keeps candidate indexes increasing", async () => {
	const samples = [
		[0, 0.2],
		[500, 0.5],
		[900, 0.25],
		[1_100, 0.2],
		[1_300, 0.5],
		[1_400, 0.2],
		[1_500, 0.5],
		[1_600, 0.25],
		[1_700, 0.2],
	].map(([tMs, closeness]) => trackerFrame(trackerSample({ tMs, closeness })));
	const harness = buildPoseTrackerHarness(samples);

	await harness.mount();
	await harness.runUntilConsumed(5);
	assert.equal(harness.tracker.listenerCount("pose-tracker:reset"), 1);
	harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:reset"));
	await harness.runUntilConsumed(9);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:rep")
			.map(({ detail }) => detail.index),
		[1, 2],
	);
	harness.poseTracker.destroyed();
	assert.equal(harness.tracker.listenerCount("pose-tracker:reset"), 0);
});

test("tracker status emits matching deduplicated local and server transitions", async () => {
	const harness = buildPoseTrackerHarness(
		[0.9, 0.9, 0.1, 0.1, 0.9].map((confidence, index) =>
			trackerFrame(trackerSample({ tMs: index * 100, confidence })),
		),
	);

	await harness.mount();
	await harness.runUntilConsumed(5);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:status")
			.map(({ bubbles, detail }) => ({ bubbles, detail })),
		[
			{ bubbles: true, detail: { state: "live" } },
			{ bubbles: true, detail: { state: "lost" } },
			{ bubbles: true, detail: { state: "live" } },
		],
	);
	assert.deepEqual(
		harness.pushes.filter(({ name }) => name === "track"),
		[
			{ name: "track", payload: { state: "live" } },
			{ name: "track", payload: { state: "lost" } },
			{ name: "track", payload: { state: "live" } },
		],
	);
	harness.poseTracker.destroyed();
});

test("invalid tracker finish retains the lost fallback", async () => {
	const harness = buildPoseTrackerHarness([], { holdDetector: true });
	await harness.mount();

	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:finish", {
			detail: { durationMs: -1, cadenceMs: [] },
		}),
	);

	assert.deepEqual(
		harness.pushes.filter(({ name }) => name === "track"),
		[
			{
				name: "track",
				payload: { state: "lost", reason: "invalid_finish" },
			},
		],
	);
	harness.poseTracker.destroyed();
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

test("running frames cue authoritative remaining reps during work recovery", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	const timeline = Object.freeze([
		Object.freeze({
			kind: "work",
			reps: 5,
			sec_per_rep: 10,
			sec_per_burpee: 3,
		}),
	]);

	ctx.dispatchSegment({
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 5,
	});
	ctx.activeSegment = "workout";
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 0 });

	ctx.renderRunningFrame(4);
	ctx.renderRunningFrame(5);
	ctx.renderRunningFrame(10.5);

	assert.equal(ctx.renderedModels[0].visual.state, "work_recovery");
	assert.equal(ctx.renderedModels[0].primaryCount, "6");
	assert.deepEqual(ctx.downCueValues, [5, 4]);
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

test("degraded tracked completion preserves timer result and adds metadata", () => {
	const ctx = trackedContext([{ kind: "work", reps: 5, sec_per_rep: 2 }]);
	ctx.flow = { ...ctx.flow, captureMode: "tracked" };
	ctx.updatePoseStatus({ state: "lost" });
	const payload = {
		warmup: { burpee_count_done: 0, duration_sec: 0 },
		main: { burpee_count_done: 5, duration_sec: 10 },
	};

	ctx.runFlowCommand({ type: "pushSessionComplete", payload });

	assert.deepEqual(ctx.events, [
		{
			name: "session_complete",
			payload: {
				...payload,
				tracking: { status: "degraded", reason: "tracking_lost" },
			},
		},
	]);
});

test("missing tracker falls back to timer completion metadata", () => {
	const ctx = buildHarness({ poseTrackerReady: null });
	ctx.flow = { ...ctx.flow, captureMode: "tracked" };
	ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
	ctx.trackerReadiness = "ready";
	ctx.startPoseObservation();
	const payload = {
		warmup: { burpee_count_done: 0, duration_sec: 0 },
		main: { burpee_count_done: 5, duration_sec: 10 },
	};

	assert.equal(ctx.el.querySelector("#pose-tracker"), null);
	ctx.runFlowCommand({ type: "pushSessionComplete", payload });

	assert.deepEqual(ctx.events, [
		{
			name: "session_complete",
			payload: {
				...payload,
				tracking: { status: "degraded", reason: "tracking_unavailable" },
			},
		},
	]);
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
	ctx.tracking = updateTrackingStatus(initialTrackingObserver(), "live");
	ctx.trackerReadiness = "ready";
	ctx.beginSegment();
	ctx.startTime = 0;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });

	assert.deepEqual(
		ctx.events.filter((event) => event.name === "session_complete"),
		[],
	);
	assert.deepEqual(finishDetail, { durationMs: 10_000, cadenceMs: [] });
});
