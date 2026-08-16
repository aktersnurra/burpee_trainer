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
		this.parentElement = null;
		this.id = "";
		this.type = "";
		this.className = "";
		const classes = new Set();
		this.classList = {
			add: (...names) => names.forEach((name) => classes.add(name)),
			remove: (...names) => names.forEach((name) => classes.delete(name)),
			contains: (name) => classes.has(name),
		};
		this.textContent = "";
		this.value = "";
		this.hidden = false;
		this.style = {};
		this.attributes = new Map();
		this.dataset = {};
		this.listeners = new Map();
	}

	toggleAttribute(name, force) {
		if (force) this.setAttribute(name, "");
		else this.removeAttribute(name);
	}

	focus() {
		this.focused = true;
	}

	setAttribute(name, value) {
		this.attributes.set(name, String(value));
	}

	getAttribute(name) {
		return this.attributes.get(name) ?? null;
	}

	removeAttribute(name) {
		this.attributes.delete(name);
	}

	hasAttribute(name) {
		return this.attributes.has(name);
	}

	append(...children) {
		for (const child of children) {
			child.parentElement = this;
			this.children.push(child);
		}
	}

	appendChild(child) {
		this.append(child);
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
		if (!event.target) event.target = this;
		event.currentTarget = this;
		for (const listener of this.listeners.get(event.type) || []) {
			listener.call(this, event);
		}

		if (event.bubbles && this.parentElement) {
			return this.parentElement.dispatchEvent(event);
		}
		return true;
	}

	querySelector(selector) {
		if (selector.startsWith("#")) return this.findById(selector.slice(1));
		return this.querySelectorAll(selector)[0] || null;
	}

	querySelectorAll(selector) {
		const matches = [];
		const visit = (element) => {
			const datasetKey = selector.match(/^\[data-([a-z-]+)\]$/)?.[1];
			const camelKey = datasetKey?.replace(/-([a-z])/g, (_, letter) =>
				letter.toUpperCase(),
			);
			if (
				(selector === "[data-session-panel]" &&
					element.hasAttribute?.("data-session-panel")) ||
				(camelKey && Object.hasOwn(element.dataset || {}, camelKey))
			) {
				matches.push(element);
			}
			for (const child of element.children || []) visit(child);
		};
		visit(this);
		return matches;
	}

	closest(selector) {
		let element = this;
		while (element) {
			if (selector.startsWith("#") && element.id === selector.slice(1)) {
				return element;
			}
			element = element.parentElement;
		}
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

function appendStablePanels(root) {
	const panelIds = [
		"session-capture-choice",
		"session-camera-status",
		"session-camera-setup",
		"session-warmup-choice",
		"session-workout-ready",
		"session-runner-client",
		"session-completion-review",
	];
	for (const id of panelIds) {
		const panel = new FakeElement("section");
		panel.id = id;
		panel.hidden = true;
		panel.setAttribute("data-session-panel", "");
		panel.setAttribute("inert", "");
		const heading = new FakeElement("h1");
		heading.id = `${id}-heading`;
		panel.append(heading);
		root.append(panel);
	}

	const stableElements = [
		["camera-choice-yes", "button", "Yes, use camera"],
		["camera-choice-no", "button", "No, continue"],
		["camera-status-starting", "div", ""],
		["camera-status-error", "div", ""],
		["camera-status-retry", "button", "Try again"],
		["camera-status-continue", "button", "Continue without camera"],
		["camera-setup-arming", "div", "Step into frame"],
		["camera-setup-ready", "div", "Camera ready"],
		["camera-setup-continue", "button", "Continue without camera"],
		["warmup-tracked-instruction", "p", "Raise one hand to warm up."],
		["warmup-skip-countdown", "p", "Skipping in "],
		["warmup-skip-seconds", "span", "4"],
		["warmup-manual-controls", "div", ""],
		["warmup-yes-btn", "button", "Warm up"],
		["warmup-skip-btn", "button", "Skip warmup"],
		["workout-ready-instruction", "p", "Hold one hand up to start."],
		["workout-ready-btn", "button", "Start workout"],
		["workout-ready-continue", "button", "Continue without camera"],
		["session-actual-reps", "p", "0"],
		["session-planned-reps", "span", "0"],
		["session-actual-duration", "p", "0:00"],
		["session-count-source", "p", ""],
		["completion-reps-input", "input", ""],
		["completion-duration-input", "input", ""],
		["completion-note-input", "textarea", ""],
		["workout_session_burpee_type", "input", ""],
		["session-completion-form", "form", ""],
		["session-save-btn", "button", "Save session"],
		["session-save-errors", "div", ""],
		["completion-reps-error", "p", ""],
		["completion-duration-error", "p", ""],
		["completion-note-error", "p", ""],
		["session-discard-btn", "button", "Discard"],
	];
	for (const [id, tag, text] of stableElements) {
		const element = new FakeElement(tag);
		element.id = id;
		element.textContent = text;
		if (id === "camera-setup-ready") {
			element.hidden = true;
			element.setAttribute("inert", "");
		}
		if (id === "session-discard-btn") {
			element.dataset.confirm = "Discard this session?";
		}
		if (id === "workout_session_burpee_type") element.value = "six_count";
		if (id.endsWith("-error") || id === "session-save-errors") {
			element.hidden = true;
		}
		let panelId = "session-completion-review";
		if (id.startsWith("camera-choice")) {
			panelId = "session-capture-choice";
		} else if (id.startsWith("camera-status")) {
			panelId = "session-camera-status";
		} else if (id.startsWith("camera-setup")) {
			panelId = "session-camera-setup";
		} else if (id.startsWith("warmup")) {
			panelId = "session-warmup-choice";
		} else if (id.startsWith("workout-ready")) {
			panelId = "session-workout-ready";
		}
		root.findById(panelId).append(element);
	}

	const completion = root.findById("session-completion-review");
	for (const mood of [-1, 0, 1]) {
		const button = new FakeElement("button");
		button.dataset.mood = String(mood);
		completion.append(button);
	}
	for (const tag of ["tired", "great_energy", "bad_sleep"]) {
		const button = new FakeElement("button");
		button.dataset.tag = tag;
		completion.append(button);
	}
}

function buildHarness({
	poseTrackerReady = false,
	openSessionStore,
	setTimeout: hookSetTimeout,
	clearTimeout: hookClearTimeout,
	realLifecycle = false,
} = {}) {
	const events = [];
	const renderedModels = [];
	const downCueValues = [];
	const totalUpdates = [];
	const saveErrorReplies = [];
	const root = new FakeElement("div");
	root.id = "burpee-session";
	root.dataset.sessionProgram = JSON.stringify({
		events: [{ kind: "work", reps: 5, sec_per_rep: 2 }],
	});
	root.dataset.planId = "plan-1";
	root.dataset.programHash = "hash-1";
	root.dataset.clientSessionId = "client-1";
	globalThis.document.root = root;
	appendStablePanels(root);

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
		renderFlowState() {},
		renderCompletion() {},
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
		clearSaveErrors() {},
		renderSaveErrors(reply) {
			saveErrorReplies.push(reply);
		},
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
		...(openSessionStore ? { openSessionStore } : {}),
		...(hookSetTimeout ? { setTimeout: hookSetTimeout } : {}),
		...(hookClearTimeout ? { clearTimeout: hookClearTimeout } : {}),
		renderer,
		audio,
		wakeLock,
		...(realLifecycle
			? {}
			: {
					requestBeginSession() {
						this.dispatchFlow({ type: "SESSION_BEGIN_ACKNOWLEDGED" });
					},
					requestReportPending() {
						this.dispatchFlow({ type: "REPORT_PENDING_ACKNOWLEDGED" });
					},
				}),
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
		pushEvent(name, payload, callback) {
			if (name === "begin_session") {
				callback?.({ status: "ok", session_id: 1, lifecycle_status: "running" });
				return;
			}
			if (name === "mark_report_pending") {
				callback?.({ status: "ok", session_id: 1, lifecycle_status: "report_pending" });
				return;
			}
			if (name === "abort_session") {
				callback?.({ status: "ok", session_id: 1, lifecycle_status: "aborted" });
				return;
			}
			events.push({ name, payload });
		},
		events,
		renderedModels,
		downCueValues,
		totalUpdates,
		saveErrorReplies,
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

function mountedTrackedCountdown(timeline) {
	const ctx = buildHarness({ poseTrackerReady: true });
	const { renderer, audio, wakeLock } = ctx;
	ctx.handleEvent = () => {};
	ctx.mounted();
	ctx.renderer = renderer;
	ctx.audio = audio;
	ctx.wakeLock = wakeLock;
	ctx.flow = { ...ctx.flow, mode: "workout_running" };
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
	ctx.flow = { ...ctx.flow, captureMode: "camera" };
	ctx.updatePoseStatus({ state: "lost" });

	assert.equal(ctx.segment.mode, "running");
	assert.equal(ctx.timeline, timelineBefore);
	assert.deepEqual(
		ctx.workoutCompletionResult({ burpeeCountDone: 2, durationSec: 10 }),
		{ burpeeCountDone: 2, durationSec: 10, cadenceMs: [] },
	);
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

function poseTrackerHarness({
	frames = [],
	holdDetector = false,
	getUserMedia,
	estimatePoses,
	detectorThrowsAfterReady = false,
	trackerElement = null,
} = {}) {
	const pushes = [];
	const localEvents = [];
	const events = [];
	const animationFrames = [];
	const cancelledAnimationFrameIds = [];
	const tracker = trackerElement || new FakeElement("div");
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
		"pose-tracker:started",
		"pose-tracker:start-failed",
		"pose-tracker:readiness",
		"pose-tracker:rep",
		"pose-tracker:status",
		"pose-tracker:gesture-confirm",
		"pose-tracker:gesture-timeout",
		"pose-tracker:trace-chunk",
		"pose-tracker:finished",
	]) {
		tracker.addEventListener(type, (event) => {
			localEvents.push(event);
			events.push({ type: event.type, detail: event.detail });
		});
	}

	let nowMs = 0;
	let currentFrame = null;
	let consumedFrames = 0;
	let inferenceCalls = 0;
	const stoppedTrack = {
		stopped: false,
		stopCalls: 0,
		stop() {
			this.stopped = true;
			this.stopCalls += 1;
		},
	};
	const detector = {
		disposed: false,
		disposeCalls: 0,
		estimatePoses() {
			if (holdDetector) return new Promise(() => {});
			if (estimatePoses) {
				const callIndex = inferenceCalls;
				inferenceCalls += 1;
				return Promise.resolve(estimatePoses(callIndex)).then((frame) => {
					currentFrame = frame;
					consumedFrames += 1;
					return frame.poses;
				});
			}
			if (detectorThrowsAfterReady && consumedFrames === 8) {
				throw new Error("detector exploded");
			}
			currentFrame = frames[consumedFrames];
			if (!currentFrame) throw new Error("unexpected pose frame");
			consumedFrames += 1;
			return currentFrame.poses;
		},
		dispose() {
			this.disposed = true;
			this.disposeCalls += 1;
		},
	};

	let nextTimeoutId = 1;
	let mediaRequests = 0;
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
				mediaRequests += 1;
				if (getUserMedia) return getUserMedia();
				return { getTracks: () => [stoppedTrack] };
			},
		},
		now: () => nowMs,
		requestAnimationFrame(callback) {
			animationFrames.push(callback);
			return animationFrames.length;
		},
		cancelAnimationFrame(id) {
			cancelledAnimationFrameIds.push(id);
		},
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
	const settleAll = async () => {
		for (let index = 0; index < 8; index += 1) await Promise.resolve();
	};

	return {
		tracker,
		pushes,
		serverPushes: pushes,
		localEvents,
		events,
		detector,
		impl: poseTracker,
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
		get mediaRequests() {
			return mediaRequests;
		},
		get pendingAnimationFrames() {
			return animationFrames.length;
		},
		get cancelledAnimationFrameIds() {
			return [...cancelledAnimationFrameIds];
		},
		get resourceCleanupCalls() {
			return stoppedTrack.stopCalls + detector.disposeCalls;
		},
		flushPromises: settle,
		flushAllPromises: settleAll,
		async mount() {
			await poseTracker.mounted();
			tracker.dispatchEvent(new CustomEvent("pose-tracker:start"));
			await settle();
		},
		async start() {
			tracker.dispatchEvent(new CustomEvent("pose-tracker:start"));
			await settle();
		},
		async startAndArm(step, holdFramesRequired) {
			await poseTracker.mounted();
			tracker.dispatchEvent(
				new CustomEvent("pose-tracker:arm", {
					detail: { step, holdFramesRequired },
				}),
			);
			await this.start();
			await this.runUntilConsumed(frames.length);
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

function buildPoseTrackerHarness(frames = [], options = {}) {
	return poseTrackerHarness({ ...options, frames });
}

test("pose tracker mount is lazy and emits local startup failure", async () => {
	const harness = poseTrackerHarness({
		getUserMedia: async () => {
			throw new Error("permission denied");
		},
	});
	await harness.impl.mounted();
	assert.equal(harness.mediaRequests, 0);
	harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:start"));
	await harness.flushPromises();
	assert.equal(harness.mediaRequests, 1);
	assert.deepEqual(harness.events.at(-1), {
		type: "pose-tracker:start-failed",
		detail: { reason: "permission denied" },
	});
	assert.deepEqual(harness.serverPushes, []);
});

test("pose tracker stop is safe while camera startup is pending", async () => {
	let resolveCamera;
	const track = {
		stopped: false,
		stop() {
			this.stopped = true;
		},
	};
	const harness = poseTrackerHarness({
		getUserMedia: () =>
			new Promise((resolve) => {
				resolveCamera = resolve;
			}),
	});
	await harness.impl.mounted();
	harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:start"));
	await harness.flushPromises();
	harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:stop"));
	resolveCamera({ getTracks: () => [track] });
	await harness.flushPromises();
	assert.equal(track.stopped, true);
	assert.equal(
		harness.events.some((event) => event.type === "pose-tracker:started"),
		false,
	);
});

test("stale inference settlement cannot affect a restarted tracker", async () => {
	for (const settlement of ["resolve", "reject"]) {
		let settleStaleInference;
		const harness = poseTrackerHarness({
			estimatePoses(callIndex) {
				if (callIndex === 0) {
					return new Promise((resolve, reject) => {
						settleStaleInference =
							settlement === "resolve"
								? () =>
										resolve(trackerFrame(trackerSample({ confidence: 0.1 }), 0))
								: () => reject(new Error("stale detector exploded"));
					});
				}
				return trackerFrame(trackerSample());
			},
		});

		await harness.impl.mounted();
		await harness.start();
		harness.tracker.dispatchEvent(new CustomEvent("pose-tracker:stop"));
		await harness.start();
		await harness.flushAllPromises();
		const cleanupCalls = harness.resourceCleanupCalls;
		assert.equal(harness.pendingAnimationFrames, 1, settlement);

		settleStaleInference();
		await harness.flushAllPromises();

		assert.equal(harness.pendingAnimationFrames, 1, settlement);
		assert.equal(harness.resourceCleanupCalls, cleanupCalls, settlement);
		assert.equal(
			harness.events.some(
				(event) =>
					event.type === "pose-tracker:status" && event.detail.state === "lost",
			),
			false,
			settlement,
		);
	}
});

test("camera gesture cannot confirm while readiness is not_ready", async () => {
	const gestureFrames = Array.from({ length: 4 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100, leftWristY: 0.1 }), 0),
	);
	const harness = poseTrackerHarness({ frames: gestureFrames });
	await harness.startAndArm("camera_setup", 3);
	assert.equal(
		harness.events.some(
			(event) => event.type === "pose-tracker:gesture-confirm",
		),
		false,
	);
});

test("detector exception emits local readiness loss and lost status", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const harness = poseTrackerHarness({
		frames: readyFrames,
		detectorThrowsAfterReady: true,
	});
	await harness.impl.mounted();
	await harness.start();
	await harness.runUntilConsumed(8);
	await harness.runUntilConsumed(9).catch(() => {});
	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.deepEqual(harness.events.slice(-2), [
		{
			type: "pose-tracker:readiness",
			detail: { state: "not_ready" },
		},
		{
			type: "pose-tracker:status",
			detail: { state: "lost", reason: "detector_error" },
		},
	]);
	assert.deepEqual(harness.serverPushes, []);
});

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
	ctx.flow = { ...ctx.flow, mode: "workout_running" };
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

function mountedFlowHarness(options = {}) {
	const ctx = buildHarness(options);
	ctx.handleEvent = () =>
		assert.fail("SessionHook must not await session_ready");
	ctx.mounted();
	ctx.audio = {
		ensureRunning() {},
		stop() {},
		playLeadBeep() {},
		playRepBeep() {},
		close() {},
	};
	ctx.wakeLock = {
		acquire() {},
		release() {},
		reacquireWhenVisible() {},
	};
	return ctx;
}

function click(ctx, id) {
	ctx.el.dispatchEvent({
		type: "click",
		target: ctx.el.querySelector(`#${id}`),
	});
}

function trackerEvent(ctx, type, detail = {}) {
	ctx.el.dispatchEvent(new CustomEvent(type, { detail, bubbles: true }));
}

test("mount bootstraps the local flow synchronously from the root dataset", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });

	assert.equal(ctx.flow.mode, "capture_choice");
	assert.equal(ctx.planId, "plan-1");
	assert.equal(ctx.programHash, "hash-1");
	assert.equal(ctx.clientSessionId, "client-1");
	assert.deepEqual(ctx.timeline, []);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

const flushHookPromises = () => new Promise((resolve) => setImmediate(resolve));

function completionDraft(overrides = {}) {
	return {
		client_session_id: "original-client",
		plan_id: "plan-1",
		program_hash: "hash-1",
		burpee_count_actual: 4,
		burpee_count_planned: 5,
		duration_sec_actual: 9,
		duration_sec_planned: 10,
		tracking: {
			enabled: true,
			trust: "finished",
			reason: null,
			detected_reps: 4,
			detected_duration_sec: 9,
			cadence_ms: [2_000, 4_000, 6_000, 8_000],
		},
		mood: 1,
		tags: ["great_energy"],
		note_post: "Strong finish",
		...overrides,
	};
}

test("trace chunks serialize without blocking the tracker event callback", async () => {
	let resolveFirst;
	const calls = [];
	const store = {
		loadDraft: async () => null,
		appendTraceChunk(_clientSessionId, chunk) {
			calls.push(structuredClone(chunk));
			if (chunk.chunk_index === 0) {
				return new Promise((resolve) => {
					resolveFirst = resolve;
				});
			}
			return Promise.resolve();
		},
	};
	let openCalls = 0;
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => {
			openCalls += 1;
			return store;
		},
	});

	const firstChunk = { chunk_index: 0, payload: { frame: 0 } };
	const secondChunk = { chunk_index: 1, payload: { frame: 1 } };
	const firstResult = ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:trace-chunk", {
			detail: { chunk: firstChunk },
			bubbles: true,
		}),
	);
	ctx.el.dispatchEvent(
		new CustomEvent("pose-tracker:trace-chunk", {
			detail: { chunk: secondChunk },
			bubbles: true,
		}),
	);
	await flushHookPromises();

	assert.equal(firstResult, true);
	assert.equal(openCalls, 1);
	assert.deepEqual(calls, [firstChunk]);
	resolveFirst();
	await ctx.traceWrite;
	assert.deepEqual(calls, [firstChunk, secondChunk]);
	assert.equal(ctx.el.listenerCount("pose-tracker:trace-chunk"), 1);
	ctx.destroyed();
	assert.equal(ctx.el.listenerCount("pose-tracker:trace-chunk"), 0);
});

test("storage rejection leaves the local workout and completion operational", async () => {
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => {
			throw new Error("storage failed");
		},
	});

	assert.equal(ctx.flow.mode, "capture_choice");
	click(ctx, "camera-choice-no");
	click(ctx, "warmup-skip-btn");
	click(ctx, "workout-ready-btn");
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 1 });
	ctx.startTime = 1;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
	await flushHookPromises();

	assert.equal(ctx.traceRetentionAvailable, false);
	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(ctx.flow.completion.burpeeCountActual, 5);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("trace write rejection degrades retention without changing workout flow", async () => {
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => ({
			loadDraft: async () => null,
			appendTraceChunk: async () => {
				throw new Error("write failed");
			},
		}),
	});
	const flow = ctx.flow;
	trackerEvent(ctx, "pose-tracker:trace-chunk", {
		chunk: { chunk_index: 0, payload: { frame: 0 } },
	});
	await ctx.traceWrite;

	assert.equal(ctx.traceRetentionAvailable, false);
	assert.equal(ctx.flow, flow);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("completion display and every stable edit queue the full draft", async () => {
	const saved = [];
	const store = {
		loadDraft: async () => null,
		async saveDraft(draft) {
			saved.push(structuredClone(draft));
		},
	};
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => store,
	});
	await ctx.draftRestore;
	const renderCompletion = ctx.renderer.renderCompletion.bind(ctx.renderer);
	ctx.renderer.renderCompletion = (completion) => {
		assert.ok(
			ctx.inMemoryCompletionDraft,
			"draft must be queued before render",
		);
		renderCompletion(completion);
	};
	ctx.flow = {
		...ctx.flow,
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "observing",
		workoutTimeline: [{ kind: "work", reps: 5, sec_per_rep: 2 }],
	};
	ctx.dispatchFlow({
		type: "SESSION_DONE",
		result: {
			burpeeCountDone: 4,
			durationSec: 9,
			detectedReps: 4,
			detectedDurationSec: 9,
			cadenceMs: [2_000, 4_000, 6_000, 8_000],
		},
	});
	await ctx.draftWrite;
	await flushHookPromises();
	await flushHookPromises();

	assert.equal(saved.length, 1);
	assert.deepEqual(
		saved[0],
		completionDraft({
			client_session_id: "client-1",
			tracking: {
				enabled: true,
				trust: "observing",
				reason: null,
				detected_reps: 4,
				detected_duration_sec: 9,
				cadence_ms: [2_000, 4_000, 6_000, 8_000],
			},
			mood: 0,
			tags: [],
			note_post: "",
		}),
	);

	const reps = ctx.el.querySelector("#completion-reps-input");
	reps.value = "5";
	ctx.el.dispatchEvent({ type: "input", target: reps });
	await ctx.draftWrite;
	assert.equal(saved.at(-1).burpee_count_actual, 5);
	assert.equal(ctx.el.querySelector("#session-actual-reps").textContent, "5");

	const duration = ctx.el.querySelector("#completion-duration-input");
	duration.value = "11";
	ctx.el.dispatchEvent({ type: "input", target: duration });
	await ctx.draftWrite;
	assert.equal(saved.at(-1).duration_sec_actual, 11);
	assert.equal(
		ctx.el.querySelector("#session-actual-duration").textContent,
		"0:11",
	);

	const mood = ctx.el
		.querySelectorAll("[data-mood]")
		.find((button) => button.dataset.mood === "1");
	ctx.el.dispatchEvent({ type: "click", target: mood });
	await ctx.draftWrite;
	assert.equal(saved.at(-1).mood, 1);

	const tag = ctx.el
		.querySelectorAll("[data-tag]")
		.find((button) => button.dataset.tag === "great_energy");
	ctx.el.dispatchEvent({ type: "click", target: tag });
	await ctx.draftWrite;
	assert.deepEqual(saved.at(-1).tags, ["great_energy"]);

	const note = ctx.el.querySelector("#completion-note-input");
	note.value = "Strong finish";
	ctx.el.dispatchEvent({ type: "input", target: note });
	await ctx.draftWrite;
	assert.equal(saved.at(-1).note_post, "Strong finish");
	assert.equal(saved.length, 6);
	ctx.destroyed();
});

test("exact plan and program draft restores its original client UUID", async () => {
	const store = { loadDraft: async () => completionDraft() };
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => store,
	});
	await ctx.draftRestore;

	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(ctx.clientSessionId, "original-client");
	assert.equal(ctx.el.querySelector("#session-actual-reps").textContent, "4");
	assert.equal(ctx.el.querySelector("#completion-reps-input").value, "4");
	assert.equal(
		ctx.el.querySelector("#completion-note-input").value,
		"Strong finish",
	);
	assert.equal(
		ctx.el
			.querySelectorAll("[data-mood]")
			.find((button) => button.dataset.mood === "1")
			.getAttribute("aria-pressed"),
		"true",
	);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("degraded tracking reason survives completion draft round-trip exactly", async () => {
	const saved = [];
	const first = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => ({
			loadDraft: async () => null,
			async saveDraft(draft) {
				saved.push(structuredClone(draft));
			},
		}),
	});
	await first.draftRestore;
	first.flow = {
		...first.flow,
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "degraded",
		trackingReason: "confidence_lost/core-pose",
		workoutTimeline: [{ kind: "work", reps: 5, sec_per_rep: 2 }],
	};
	first.dispatchFlow({
		type: "SESSION_DONE",
		result: { burpeeCountDone: 4, durationSec: 9 },
	});
	await first.draftWrite;

	assert.equal(saved.length, 1);
	assert.equal(saved[0].tracking.reason, "confidence_lost/core-pose");
	first.destroyed();

	const restoredWrites = [];
	const restored = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => ({
			loadDraft: async () => saved[0],
			async saveDraft(draft) {
				restoredWrites.push(structuredClone(draft));
			},
		}),
	});
	await restored.draftRestore;
	await restored.draftWrite;

	assert.equal(restored.flow.mode, "completion_review");
	assert.equal(restored.flow.trackingReason, "confidence_lost/core-pose");
	assert.deepEqual(restoredWrites, []);
	assert.deepEqual(restored.events, []);
	restored.destroyed();
});

test("draft load settlement after destroy cannot restore, render, or save", async () => {
	let resolveDraft;
	let signalLoadStarted;
	const draftPending = new Promise((resolve) => {
		resolveDraft = resolve;
	});
	const loadStarted = new Promise((resolve) => {
		signalLoadStarted = resolve;
	});
	const saved = [];
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => ({
			loadDraft() {
				signalLoadStarted();
				return draftPending;
			},
			async saveDraft(draft) {
				saved.push(draft);
			},
		}),
	});
	await loadStarted;
	const dispatched = [];
	const dispatchFlow = ctx.dispatchFlow.bind(ctx);
	ctx.dispatchFlow = (event) => {
		dispatched.push(event.type);
		dispatchFlow(event);
	};
	let completionRenders = 0;
	ctx.renderer.renderCompletion = () => {
		completionRenders += 1;
	};

	ctx.destroyed();
	resolveDraft(completionDraft());
	await ctx.draftRestore;
	await ctx.draftWrite;

	assert.equal(ctx.flow.mode, "capture_choice");
	assert.equal(ctx.clientSessionId, "client-1");
	assert.deepEqual(dispatched, []);
	assert.equal(completionRenders, 0);
	assert.deepEqual(saved, []);
});

test("mismatched plan or program draft is ignored", async () => {
	for (const mismatch of [
		{ plan_id: "other-plan" },
		{ program_hash: "other-hash" },
	]) {
		const ctx = mountedFlowHarness({
			poseTrackerReady: true,
			openSessionStore: async () => ({
				loadDraft: async () => completionDraft(mismatch),
			}),
		});
		await ctx.draftRestore;
		assert.equal(ctx.flow.mode, "capture_choice");
		assert.equal(ctx.clientSessionId, "client-1");
		ctx.destroyed();
	}
});

test("confirmed discard clears local session data and emits zero server events", async () => {
	const local = { draft: true, chunks: [0, 1], upload: true };
	const store = {
		loadDraft: async () => completionDraft(),
		async discardSession(clientSessionId) {
			assert.equal(clientSessionId, "original-client");
			local.draft = false;
			local.chunks = [];
			local.upload = false;
		},
	};
	const originalWindow = globalThis.window;
	const navigations = [];
	globalThis.window = {
		confirm: () => true,
		location: { assign: (path) => navigations.push(path) },
	};
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => store,
	});
	const trackerStops = [];
	ctx.el
		.querySelector("#pose-tracker")
		.addEventListener("pose-tracker:stop", () => trackerStops.push("stop"));

	try {
		await ctx.draftRestore;
		click(ctx, "session-discard-btn");
		await ctx.discardWrite;

		assert.deepEqual(local, { draft: false, chunks: [], upload: false });
		assert.deepEqual(trackerStops, ["stop"]);
		assert.deepEqual(navigations, ["/workouts"]);
		assert.deepEqual(ctx.events, []);
		assert.equal(ctx.flow.mode, "discarded");
		assert.equal(ctx.flow.completion, null);
	} finally {
		ctx.destroyed();
		globalThis.window = originalWindow;
	}
});

test("discard retains recovery data until the abort acknowledgement and local cleanup complete", async () => {
	let resolveOpen;
	const opened = new Promise((resolve) => {
		resolveOpen = resolve;
	});
	const storageCalls = [];
	const scheduled = new Map();
	let nextTimerId = 1;
	const navigations = [];
	let destroyed = false;
	const originalWindow = globalThis.window;
	globalThis.window = {
		confirm: () => true,
		location: { assign: (path) => navigations.push(path) },
	};
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: () => opened,
		setTimeout(callback, delayMs) {
			const id = nextTimerId++;
			scheduled.set(id, { callback, delayMs });
			return id;
		},
		clearTimeout(id) {
			scheduled.delete(id);
		},
	});
	const trackerStops = [];
	ctx.el
		.querySelector("#pose-tracker")
		.addEventListener("pose-tracker:stop", () => trackerStops.push("stop"));
	ctx.flow = {
		...ctx.flow,
		mode: "completion_review",
		completion: {
			burpeeCountActual: 4,
			burpeeCountPlanned: 5,
			durationSecActual: 9,
			durationSecPlanned: 10,
			trackingTrust: "disabled",
			cadenceMs: [],
		},
	};
	ctx.activeSegment = "workout";
	ctx.startTime = 1;
	ctx.queueCompletionDraft();

	try {
		click(ctx, "session-discard-btn");

		assert.equal(ctx.flow.mode, "discarded");
		assert.equal(ctx.activeSegment, null);
		assert.equal(ctx.startTime, null);
		assert.deepEqual(trackerStops, ["stop"]);
		assert.deepEqual(navigations, []);
		assert.equal(scheduled.size, 0);
		assert.deepEqual(navigations, []);

		resolveOpen({
			async loadDraft() {
				storageCalls.push("restore");
				return completionDraft();
			},
			async saveDraft() {
				storageCalls.push("save");
			},
			async discardSession(clientSessionId) {
				storageCalls.push(`discard:${clientSessionId}`);
			},
		});
		await ctx.discardWrite;
		assert.deepEqual(storageCalls, ["discard:client-1"]);
		assert.deepEqual(navigations, ["/workouts"]);
		ctx.destroyed();
		destroyed = true;
	} finally {
		if (!destroyed) ctx.destroyed();
		globalThis.window = originalWindow;
	}
});

test("discard still navigates when storage is unavailable", async () => {
	const originalWindow = globalThis.window;
	const navigations = [];
	globalThis.window = {
		confirm: () => true,
		location: { assign: (path) => navigations.push(path) },
	};
	const ctx = mountedFlowHarness({
		poseTrackerReady: true,
		openSessionStore: async () => {
			throw new Error("unavailable");
		},
	});
	ctx.flow = {
		...ctx.flow,
		mode: "completion_review",
		completion: {
			burpeeCountActual: 1,
			burpeeCountPlanned: 1,
			durationSecActual: 2,
			durationSecPlanned: 2,
			trackingTrust: "disabled",
			cadenceMs: [],
		},
	};

	try {
		click(ctx, "session-discard-btn");
		await ctx.discardWrite;
		assert.deepEqual(navigations, ["/workouts"]);
		assert.equal(ctx.flow.completion, null);
	} finally {
		ctx.destroyed();
		globalThis.window = originalWindow;
	}
});

test("camera through completion review requires no server event", async () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const trackerCommands = [];
	for (const type of [
		"pose-tracker:start",
		"pose-tracker:stop",
		"pose-tracker:arm",
	]) {
		tracker.addEventListener(type, (event) =>
			trackerCommands.push({ type, detail: event.detail }),
		);
	}

	assert.equal(ctx.flow.mode, "capture_choice");
	assert.equal(ctx.el.querySelector("#session-capture-choice").hidden, false);
	assert.equal(
		ctx.el.querySelector("#camera-choice-yes").textContent,
		"Yes, use camera",
	);
	assert.equal(
		ctx.el.querySelector("#camera-choice-no").textContent,
		"No, continue",
	);

	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	assert.equal(ctx.el.querySelector("#camera-setup-arming").hidden, false);
	assert.equal(ctx.el.querySelector("#camera-setup-ready").hidden, true);
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	assert.equal(ctx.el.querySelector("#camera-setup-arming").hidden, true);
	assert.equal(ctx.el.querySelector("#camera-setup-ready").hidden, false);
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });
	assert.equal(ctx.flow.mode, "warmup_choice");
	assert.equal(
		ctx.el.querySelector("#warmup-skip-countdown").textContent,
		"Skipping in ",
	);
	assert.equal(ctx.el.querySelector("#warmup-manual-controls").hidden, true);
	assert.equal(
		ctx.el.querySelector("#warmup-tracked-instruction").hidden,
		false,
	);
	ctx.finishWarmupTimeout();
	assert.equal(ctx.flow.mode, "workout_ready");
	assert.equal(
		ctx.el.querySelector("#workout-ready-instruction").textContent,
		"Hold one hand up to start.",
	);
	assert.equal(ctx.el.querySelector("#workout-ready-btn").hidden, true);
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "workout_start" });
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 1 });
	ctx.startTime = 1;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
	await flushHookPromises();
	await flushHookPromises();

	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(
		ctx.el.querySelector("#session-completion-review").hidden,
		false,
	);
	assert.equal(ctx.el.querySelector("#session-actual-reps").textContent, "5");
	assert.equal(
		ctx.el.querySelector("#session-actual-duration").textContent,
		"0:10",
	);
	assert.deepEqual(ctx.events, []);
	assert.ok(
		trackerCommands.some(
			({ type, detail }) =>
				type === "pose-tracker:arm" && detail?.step === null,
		),
	);
	ctx.destroyed();
});

test("completed workout stays quiescent across hidden and visible lifecycle", async () => {
	const originalVisibility = document.visibilityState;
	const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
	const scheduledFrames = [];
	globalThis.requestAnimationFrame = (callback) => {
		scheduledFrames.push(callback);
		return scheduledFrames.length;
	};

	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	let wakeLockReleases = 0;
	let wakeLockReacquires = 0;
	ctx.wakeLock = {
		acquire() {},
		release() {
			wakeLockReleases += 1;
		},
		reacquireWhenVisible() {
			wakeLockReacquires += 1;
		},
	};

	try {
		click(ctx, "camera-choice-no");
		click(ctx, "warmup-skip-btn");
		click(ctx, "workout-ready-btn");
		ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 1 });
		ctx.startTime = 1;
		scheduledFrames.length = 0;
		ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
		await flushHookPromises();
		await flushHookPromises();

		assert.equal(ctx.flow.mode, "completion_review");
		assert.equal(
			ctx.el.querySelector("#session-completion-review").hidden,
			false,
		);
		assert.equal(ctx.activeSegment, null);
		assert.equal(ctx.startTime, null);
		assert.equal(ctx.rafId, null);
		assert.equal(ctx.countdownTimeoutId, null);
		assert.equal(ctx.countdownRafId, null);
		assert.equal(wakeLockReleases, 1);
		const completedFlow = ctx.flow;
		const completedSegment = ctx.segment;

		document.visibilityState = "hidden";
		ctx.onVisibility();
		document.visibilityState = "visible";
		ctx.onVisibility();

		assert.deepEqual(scheduledFrames, []);
		assert.equal(wakeLockReacquires, 0);
		assert.equal(ctx.segment, completedSegment);
		assert.equal(ctx.flow, completedFlow);
		assert.equal(ctx.segment.mode, "done");
		assert.equal(ctx.flow.mode, "completion_review");
		assert.equal(
			ctx.el.querySelector("#session-completion-review").hidden,
			false,
		);
	} finally {
		document.visibilityState = originalVisibility;
		globalThis.requestAnimationFrame = originalRequestAnimationFrame;
		ctx.destroyed();
	}
});

test("camera failure during workout keeps timer result authoritative", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });
	ctx.finishWarmupTimeout();
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "workout_start" });
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 1 });
	ctx.startTime = 1;
	trackerEvent(ctx, "pose-tracker:status", {
		state: "lost",
		reason: "detector_error",
	});
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });

	assert.equal(ctx.flow.trackingTrust, "degraded");
	assert.equal(ctx.flow.completion.burpeeCountActual, 5);
	assert.deepEqual(ctx.flow.completion.cadenceMs, []);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("manual no-camera journey reaches local completion review", async () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	const arms = [];
	ctx.el
		.querySelector("#pose-tracker")
		.addEventListener("pose-tracker:arm", (event) => arms.push(event.detail));
	click(ctx, "camera-choice-no");
	assert.equal(ctx.flow.mode, "warmup_choice");
	assert.equal(ctx.el.querySelector("#warmup-manual-controls").hidden, false);
	click(ctx, "warmup-skip-btn");
	assert.equal(ctx.flow.mode, "workout_ready");
	assert.equal(ctx.el.querySelector("#workout-ready-btn").hidden, false);
	click(ctx, "workout-ready-btn");
	ctx.dispatchSegment({ type: "COUNTDOWN_DONE", now: 1 });
	ctx.startTime = 1;
	ctx.dispatchSegment({ type: "TICK", elapsedSec: 10 });
	await flushHookPromises();
	await flushHookPromises();

	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(
		ctx.el.querySelector("#session-completion-review").hidden,
		false,
	);
	assert.equal(ctx.el.querySelector("#session-actual-reps").textContent, "5");
	assert.equal(
		ctx.el.querySelector("#session-actual-duration").textContent,
		"0:10",
	);
	assert.deepEqual(arms, []);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("warmup timeout pauses while not ready and resumes monotonically", () => {
	const originalNow = performance.now;
	let now = 1_000;
	performance.now = () => now;
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });

	now = 2_250;
	ctx.renderWarmupTimeout();
	assert.equal(ctx.el.querySelector("#warmup-skip-seconds").textContent, "3");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "not_ready" });
	const pausedRemaining = ctx.warmupTimeoutRemainingMs;
	now = 5_000;
	ctx.renderWarmupTimeout();
	assert.equal(ctx.warmupTimeoutRemainingMs, pausedRemaining);
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	now = 5_500;
	ctx.renderWarmupTimeout();
	assert.ok(ctx.warmupTimeoutRemainingMs < pausedRemaining);
	assert.equal(ctx.el.querySelector("#warmup-skip-seconds").textContent, "3");

	performance.now = originalNow;
	ctx.destroyed();
});

test("confidence loss during warmup pauses timeout and stale expiry cannot skip warmup", async () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: false });
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const confidenceLostFrame = trackerFrame(
		trackerSample({ tMs: 800, confidence: 0.1 }),
	);
	const harness = poseTrackerHarness({
		frames: [...readyFrames, confidenceLostFrame],
		trackerElement: ctx.el.querySelector("#pose-tracker"),
	});

	try {
		await harness.impl.mounted();
		click(ctx, "camera-choice-yes");
		await harness.flushAllPromises();
		await harness.runUntilConsumed(8);
		trackerEvent(ctx, "pose-tracker:gesture-confirm", {
			step: "camera_setup",
		});
		assert.equal(ctx.flow.mode, "warmup_choice");
		assert.notEqual(ctx.warmupTimeoutDeadline, null);

		await harness.runUntilConsumed(9);

		assert.equal(ctx.trackerReadiness, "not_ready");
		assert.equal(ctx.warmupTimeoutDeadline, null);
		ctx.finishWarmupTimeout();
		assert.equal(ctx.flow.mode, "warmup_choice");
	} finally {
		harness.poseTracker.destroyed();
		ctx.destroyed();
	}
});

test("warmup timeout refreshes the visible seconds without tracker help", () => {
	const originalNow = performance.now;
	const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
	let now = 1_000;
	const frames = [];
	performance.now = () => now;
	globalThis.requestAnimationFrame = (callback) => {
		frames.push(callback);
		return frames.length;
	};
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });

	assert.ok(frames.length > 0);
	now = 2_250;
	frames.shift()();
	assert.equal(ctx.el.querySelector("#warmup-skip-seconds").textContent, "3");

	performance.now = originalNow;
	globalThis.requestAnimationFrame = originalRequestAnimationFrame;
	ctx.destroyed();
});

test("second warmup gesture cannot restart warmup", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "warmup" });
	const firstSegment = ctx.segment;
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "warmup" });
	assert.equal(ctx.segment, firstSegment);
	ctx.destroyed();
});

test("delayed stale gesture confirms cannot act on the next armed step", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	trackerEvent(ctx, "pose-tracker:readiness", { state: "ready" });
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });
	assert.equal(ctx.flow.mode, "warmup_choice");

	trackerEvent(ctx, "pose-tracker:gesture-confirm");
	assert.equal(ctx.flow.mode, "warmup_choice");
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "camera_setup" });
	assert.equal(ctx.flow.mode, "warmup_choice");

	ctx.finishWarmupTimeout();
	assert.equal(ctx.flow.mode, "workout_ready");
	trackerEvent(ctx, "pose-tracker:gesture-confirm", { step: "warmup" });
	assert.equal(ctx.flow.mode, "workout_ready");
	ctx.destroyed();
});

test("camera escape actions use stable copy and stop locally", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const commands = [];
	tracker.addEventListener("pose-tracker:arm", (event) =>
		commands.push({ type: event.type, detail: event.detail }),
	);
	tracker.addEventListener("pose-tracker:stop", (event) =>
		commands.push({ type: event.type, detail: event.detail }),
	);
	click(ctx, "camera-choice-yes");
	trackerEvent(ctx, "pose-tracker:started");
	assert.equal(
		ctx.el.querySelector("#camera-setup-continue").textContent,
		"Continue without camera",
	);
	click(ctx, "camera-setup-continue");

	assert.equal(ctx.flow.captureMode, "no_camera");
	assert.equal(ctx.flow.mode, "warmup_choice");
	assert.deepEqual(commands.slice(-2), [
		{
			type: "pose-tracker:arm",
			detail: { step: null, holdFramesRequired: 0 },
		},
		{ type: "pose-tracker:stop", detail: undefined },
	]);
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

test("ready armed camera-setup dispatches one gesture-confirm when wrist streak completes", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const raisedFrames = Array.from({ length: 3 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: 800 + index * 100, leftWristY: 0.1 })),
	);
	const harness = buildPoseTrackerHarness([...readyFrames, ...raisedFrames]);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 3 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(11);

	assert.deepEqual(
		harness.localEvents
			.filter(({ type }) => type === "pose-tracker:gesture-confirm")
			.map(({ detail }) => detail),
		[{ step: "camera_setup" }],
	);

	harness.poseTracker.destroyed();
});

test("camera setup auto-timer does not start until readiness is actually achieved", async () => {
	// Regression test: arming happens the instant the user picks tracked
	// mode, well before the pose network has ever seen a stable person in
	// frame. The auto-confirm timer must not start ticking until readiness
	// genuinely becomes ready/optimal -- otherwise camera setup silently
	// auto-confirms ~1.5s after arming regardless of whether anyone is even
	// in the picture.
	const notReadyFrames = Array.from({ length: 3 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 }), 0),
	);
	const harness = buildPoseTrackerHarness(notReadyFrames);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 15 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(3);

	assert.equal(harness.scheduledTimeouts.size, 0);
	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);

	harness.poseTracker.destroyed();
});

test("camera setup auto-timer starts once readiness becomes ready while armed", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const harness = buildPoseTrackerHarness(readyFrames);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 15 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(7);
	assert.equal(harness.scheduledTimeouts.size, 0);

	await harness.runUntilConsumed(8);
	assert.equal(harness.tracker.dataset.poseTrackerReady, "true");
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

test("camera setup auto-timer stops if readiness is lost before it fires", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const lostFrames = Array.from({ length: 3 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: 800 + index * 100 }), 0),
	);
	const harness = buildPoseTrackerHarness([...readyFrames, ...lostFrames]);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 15 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(8);
	assert.equal(harness.scheduledTimeouts.size, 1);

	await harness.runUntilConsumed(11);
	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.equal(harness.scheduledTimeouts.size, 0);
	assert.deepEqual(
		harness.localEvents.filter(
			({ type }) => type === "pose-tracker:gesture-confirm",
		),
		[],
	);

	harness.poseTracker.destroyed();
});

test("armed warmup step leaves no-gesture timeout to the session hook", async () => {
	const notRaisedFrames = Array.from({ length: 2 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const harness = buildPoseTrackerHarness(notRaisedFrames);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "warmup", holdFramesRequired: 15 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(2);

	assert.equal(harness.scheduledTimeouts.size, 0);
	assert.deepEqual(
		harness.localEvents.filter(
			({ type }) => type === "pose-tracker:gesture-timeout",
		),
		[],
	);

	harness.poseTracker.destroyed();
});

test("gesture confirm during camera-setup arm cancels the pending auto-timer", async () => {
	const readyFrames = Array.from({ length: 8 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: index * 100 })),
	);
	const raisedFrames = Array.from({ length: 2 }, (_, index) =>
		trackerFrame(trackerSample({ tMs: 800 + index * 100, leftWristY: 0.1 })),
	);
	const harness = buildPoseTrackerHarness([...readyFrames, ...raisedFrames]);

	await harness.impl.mounted();
	harness.tracker.dispatchEvent(
		new CustomEvent("pose-tracker:arm", {
			detail: { step: "camera_setup", holdFramesRequired: 2 },
		}),
	);

	await harness.start();
	await harness.runUntilConsumed(8);
	assert.equal(harness.scheduledTimeouts.size, 1);

	await harness.runUntilConsumed(10);

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

test("detector initialization emits local started without marking pose readiness", async () => {
	const harness = buildPoseTrackerHarness([], { holdDetector: true });

	await harness.mount();

	assert.equal(harness.tracker.dataset.poseTrackerReady, undefined);
	assert.deepEqual(
		harness.events.filter(({ type }) => type === "pose-tracker:started"),
		[{ type: "pose-tracker:started", detail: {} }],
	);
	assert.deepEqual(harness.pushes, []);
	harness.poseTracker.destroyed();
});

test("readiness transitions update the dataset and stay local", async () => {
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
	assert.deepEqual(harness.pushes, []);
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

test("tracker status emits deduplicated local transitions without server pushes", async () => {
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
			{
				bubbles: true,
				detail: { state: "lost", reason: "confidence_lost" },
			},
			{ bubbles: true, detail: { state: "live" } },
		],
	);
	assert.deepEqual(harness.pushes, []);
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
		harness.events.filter(({ type }) => type === "pose-tracker:status").at(-1),
		{
			type: "pose-tracker:status",
			detail: { state: "lost", reason: "invalid_finish" },
		},
	);
	assert.deepEqual(harness.pushes, []);
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

function prepareTrustedCompletion(ctx) {
	const timeline = [{ kind: "work", reps: 5, sec_per_rep: 2 }];
	ctx.flow = {
		...ctx.flow,
		mode: "workout_running",
		captureMode: "camera",
		trackingTrust: "observing",
	};
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
	ctx.observePoseRep({ index: 1 });
	ctx.segment = {
		...ctx.segment,
		clock: { ...ctx.segment.clock, elapsedSec: 5.1 },
	};
	ctx.observePoseRep({ index: 2 });
}

test("trusted completion consumes synchronous tracker output before stop", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	const commandOrder = [];
	const trackerOutput = {
		reps: 3,
		duration_ms: 9_500,
		cadence_ms: [2_000, 4_000, 7_000],
	};
	tracker.addEventListener("pose-tracker:finish", () => {
		commandOrder.push("finish");
		tracker.dispatchEvent(
			new CustomEvent("pose-tracker:finished", {
				bubbles: true,
				detail: trackerOutput,
			}),
		);
	});
	tracker.addEventListener("pose-tracker:stop", () => {
		commandOrder.push("stop");
		assert.deepEqual(ctx.trackerFinished, trackerOutput);
	});
	prepareTrustedCompletion(ctx);

	const result = ctx.workoutCompletionResult({
		burpeeCountDone: 5,
		durationSec: 10,
	});

	assert.deepEqual(result, {
		burpeeCountDone: 5,
		durationSec: 10,
		detectedReps: 3,
		detectedDurationSec: 9.5,
		cadenceMs: [2_000, 4_000, 7_000],
	});
	assert.deepEqual(commandOrder, ["finish", "stop"]);
	assert.equal(ctx.flow.trackingTrust, "finished");
	ctx.destroyed();
});

test("missing tracker finish degrades completion to timer authority", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	prepareTrustedCompletion(ctx);

	const result = ctx.workoutCompletionResult({
		burpeeCountDone: 5,
		durationSec: 10,
	});

	assert.deepEqual(result, {
		burpeeCountDone: 5,
		durationSec: 10,
		cadenceMs: [],
	});
	assert.equal(ctx.flow.trackingTrust, "degraded");
	assert.equal(ctx.flow.trackingReason, "tracking_incomplete");
	ctx.destroyed();
});

test("real trusted completion handshake preserves finish data and cleans tracker resources", async () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	const harness = poseTrackerHarness({
		frames: [trackerFrame(trackerSample())],
		trackerElement: ctx.el.querySelector("#pose-tracker"),
	});

	try {
		await harness.impl.mounted();
		await harness.start();
		await harness.runUntilConsumed(1);
		prepareTrustedCompletion(ctx);
		assert.equal(harness.resourceCleanupCalls, 0);
		assert.equal(harness.pendingAnimationFrames, 1);

		const result = ctx.workoutCompletionResult({
			burpeeCountDone: 5,
			durationSec: 10,
		});

		assert.deepEqual(ctx.trackerFinished, {
			reps: 2,
			duration_ms: 10_000,
			cadence_ms: [2_500, 5_100],
		});
		assert.deepEqual(result, {
			burpeeCountDone: 5,
			durationSec: 10,
			detectedReps: 2,
			detectedDurationSec: 10,
			cadenceMs: [2_500, 5_100],
		});
		assert.equal(harness.resourceCleanupCalls, 2);
		assert.equal(harness.detector.disposed, true);
		assert.deepEqual(harness.cancelledAnimationFrameIds, [1]);
	} finally {
		harness.poseTracker.destroyed();
		ctx.destroyed();
	}
});

test("pose tracker finished output stays local", () => {
	const ctx = mountedFlowHarness({ poseTrackerReady: true });
	trackerEvent(ctx, "pose-tracker:finished", {
		reps: 3,
		duration_ms: 10_000,
		cadence_ms: [2_500, 5_000, 7_500],
	});

	assert.deepEqual(ctx.trackerFinished, {
		reps: 3,
		duration_ms: 10_000,
		cadence_ms: [2_500, 5_000, 7_500],
	});
	assert.deepEqual(ctx.events, []);
	ctx.destroyed();
});

function prepareSaveReview(ctx, overrides = {}) {
	ctx.clientSessionId = "client-save";
	ctx.flow = {
		...ctx.flow,
		mode: "completion_review",
		captureMode: "camera",
		trackingReason: null,
		completion: {
			burpeeCountActual: 4,
			burpeeCountPlanned: 5,
			durationSecActual: 9,
			durationSecPlanned: 10,
			detectedReps: 4,
			detectedDurationSec: 9,
			trackingTrust: "finished",
			cadenceMs: [2_000, 4_000, 6_000, 8_000],
			mood: 1,
			tags: ["tired", "great_energy"],
			notePost: "Strong finish",
			...overrides,
		},
	};
	ctx.inMemoryCompletionDraft = ctx.completionDraft();
}

function submitCompletion(ctx) {
	let prevented = false;
	ctx.el.dispatchEvent({
		type: "submit",
		target: ctx.el.querySelector("#session-completion-form"),
		preventDefault() {
			prevented = true;
		},
	});
	return prevented;
}

test("final Save is the only server event and keeps invalid drafts editable", async () => {
	const store = {
		loadDraft: async () => null,
	};
	const ctx = mountedFlowHarness({
		openSessionStore: async () => store,
	});
	prepareSaveReview(ctx);
	const draft = ctx.inMemoryCompletionDraft;
	const calls = [];
	ctx.pushEvent = (name, payload, callback) => {
		calls.push({ name, payload });
		callback({
			status: "invalid",
			field_errors: { burpee_count_actual: ["must be at least 0"] },
			global_errors: ["Could not save. Try again."],
		});
	};

	assert.equal(submitCompletion(ctx), true);
	await flushHookPromises();

	assert.deepEqual(calls, [
		{
			name: "save_session",
			payload: {
				workout_session: {
					burpee_type: "six_count",
					burpee_count_actual: 4,
					burpee_count_planned: 5,
					duration_sec_actual: 9,
					duration_sec_planned: 10,
					client_session_id: "client-save",
					mood: 1,
					tags: "great_energy,tired",
					note_post: "Strong finish",
				},
				tracking: {
					enabled: true,
					trust: "finished",
					reason: null,
					detected_reps: 4,
					detected_duration_sec: 9,
					cadence_ms: [2_000, 4_000, 6_000, 8_000],
				},
			},
		},
	]);
	assert.equal(
		ctx.el.querySelector("#completion-reps-error").textContent,
		"must be at least 0",
	);
	assert.equal(ctx.el.querySelector("#completion-reps-error").hidden, false);
	assert.equal(
		ctx.el.querySelector("#session-save-errors").textContent,
		"Could not save. Try again.",
	);
	assert.equal(ctx.el.querySelector("#session-save-errors").hidden, false);
	assert.equal(ctx.inMemoryCompletionDraft, draft);
	assert.equal(
		ctx.el.querySelector("#session-save-btn").hasAttribute("disabled"),
		false,
	);
	ctx.destroyed();
});

test("successful Save marks buffered traces ready before deleting draft and navigating", async () => {
	const order = [];
	const store = {
		loadDraft: async () => null,
		hasTraceChunks: async (clientSessionId) => {
			order.push(["has", clientSessionId]);
			return true;
		},
		markTraceReady: async (clientSessionId, sessionId) => {
			order.push(["mark", clientSessionId, sessionId]);
		},
		deleteDraft: async (clientSessionId) => {
			order.push(["delete", clientSessionId]);
		},
	};
	const originalWindow = globalThis.window;
	const navigations = [];
	const readyEvents = [];
	globalThis.window = {
		location: { assign: (path) => navigations.push(path) },
		dispatchEvent: (event) => readyEvents.push(event.type),
	};
	const ctx = mountedFlowHarness({ openSessionStore: async () => store });
	prepareSaveReview(ctx);
	ctx.pushEvent = (name, payload, callback) => {
		assert.equal(name, "save_session");
		callback({ status: "ok", session_id: 99, redirect_to: "/stats" });
	};

	try {
		assert.equal(submitCompletion(ctx), true);
		await flushHookPromises();
		await flushHookPromises();

		assert.deepEqual(order, [
			["has", "client-save"],
			["mark", "client-save", 99],
			["delete", "client-save"],
		]);
		assert.deepEqual(readyEvents, ["burpee:trace-upload-ready"]);
		assert.deepEqual(navigations, ["/stats"]);
		assert.equal(ctx.inMemoryCompletionDraft, null);
	} finally {
		ctx.destroyed();
		globalThis.window = originalWindow;
	}
});

test("successful Save without trace chunks skips upload marker", async () => {
	const calls = [];
	const store = {
		loadDraft: async () => null,
		hasTraceChunks: async () => false,
		markTraceReady: async () => calls.push("mark"),
		deleteDraft: async () => calls.push("delete"),
	};
	const originalWindow = globalThis.window;
	const navigations = [];
	const readyEvents = [];
	globalThis.window = {
		location: { assign: (path) => navigations.push(path) },
		dispatchEvent: (event) => readyEvents.push(event.type),
	};
	const ctx = mountedFlowHarness({ openSessionStore: async () => store });
	prepareSaveReview(ctx, {
		trackingTrust: "disabled",
		detectedReps: null,
		detectedDurationSec: null,
		cadenceMs: [],
	});
	ctx.flow.captureMode = "no_camera";
	ctx.pushEvent = (_name, _payload, callback) =>
		callback({ status: "ok", session_id: 100, redirect_to: "/stats" });

	try {
		submitCompletion(ctx);
		await flushHookPromises();
		await flushHookPromises();
		assert.deepEqual(calls, ["delete"]);
		assert.deepEqual(readyEvents, []);
		assert.deepEqual(navigations, ["/stats"]);
	} finally {
		ctx.destroyed();
		globalThis.window = originalWindow;
	}
});

test("disconnected Save keeps controls and local draft available", () => {
	const ctx = mountedFlowHarness({
		openSessionStore: async () => ({ loadDraft: async () => null }),
	});
	prepareSaveReview(ctx);
	let callback;
	ctx.pushEvent = (_name, _payload, reply) => {
		callback = reply;
	};

	submitCompletion(ctx);

	assert.equal(typeof callback, "function");
	assert.ok(ctx.inMemoryCompletionDraft);
	assert.equal(
		ctx.el.querySelector("#session-save-btn").hasAttribute("disabled"),
		false,
	);
	assert.equal(ctx.flow.mode, "completion_review");
	ctx.destroyed();
});

test("lifecycle begin and pending commands persist before their server events", async () => {
	const order = [];
	const store = {
		loadDraft: async () => null,
		async saveDraft() {
			order.push("draft");
		},
		async saveLifecycleCommand(command) {
			order.push(`command:${command.kind}`);
		},
		loadLifecycleCommand: async () => null,
	};
	const ctx = mountedFlowHarness({ openSessionStore: async () => store, realLifecycle: true });
	await ctx.draftRestore;
	ctx.flow = { ...ctx.flow, mode: "workout_ready", captureMode: "no_camera" };
	ctx.pushEvent = (name, _payload, callback) => {
		order.push(`event:${name}`);
		callback({ status: "ok", session_id: 7, lifecycle_status: "running" });
	};

	ctx.onWorkoutReady();
	await flushHookPromises();
	await flushHookPromises();
	assert.deepEqual(order.slice(0, 2), ["command:begin_session", "event:begin_session"]);
	assert.equal(ctx.flow.mode, "workout_running");

	ctx.dispatchFlow({
		type: "SESSION_DONE",
		result: { burpeeCountDone: 5, durationSec: 10 },
	});
	await flushHookPromises();
	await flushHookPromises();
	assert.deepEqual(order.slice(-3), [
		"draft",
		"command:mark_report_pending",
		"event:mark_report_pending",
	]);
	assert.equal(ctx.flow.mode, "completion_review");
	ctx.destroyed();
});

test("pending and abort failures retain local recovery data", async () => {
	const calls = [];
	const store = {
		loadDraft: async () => null,
		async saveDraft() {
			calls.push("draft");
		},
		async saveLifecycleCommand() {
			calls.push("command");
		},
		loadLifecycleCommand: async () => null,
		async discardSession() {
			calls.push("discard");
		},
	};
	const ctx = mountedFlowHarness({ openSessionStore: async () => store, realLifecycle: true });
	await ctx.draftRestore;
	ctx.flow = {
		...ctx.flow,
		mode: "workout_running",
		captureMode: "no_camera",
		workoutTimeline: [{ kind: "work", reps: 5, sec_per_rep: 2 }],
	};
	ctx.pushEvent = (_name, _payload, callback) =>
		callback({ status: "error", message: "offline" });
	ctx.dispatchFlow({ type: "SESSION_DONE", result: { burpeeCountDone: 5, durationSec: 10 } });
	await flushHookPromises();
	await flushHookPromises();
	assert.equal(ctx.flow.mode, "completion_pending_failed");
	assert.deepEqual(calls, ["draft", "command"]);
	ctx.flow = { ...ctx.flow, mode: "completion_review" };
	ctx.discardSessionLocally();
	assert.equal(ctx.flow.mode, "completion_review");
	assert.equal(calls.includes("discard"), false);
	ctx.destroyed();
});

test("successful Save navigates by a deadline when local storage remains pending", () => {
	const opened = new Promise(() => {});
	const scheduled = new Map();
	let nextTimerId = 1;
	const originalWindow = globalThis.window;
	const navigations = [];
	globalThis.window = {
		location: { assign: (path) => navigations.push(path) },
		dispatchEvent() {},
	};
	const ctx = mountedFlowHarness({
		openSessionStore: () => opened,
		setTimeout(callback, delayMs) {
			const id = nextTimerId++;
			scheduled.set(id, { callback, delayMs });
			return id;
		},
		clearTimeout(id) {
			scheduled.delete(id);
		},
	});
	prepareSaveReview(ctx);
	ctx.pushEvent = (_name, _payload, callback) =>
		callback({ status: "ok", session_id: 101, redirect_to: "/stats" });

	try {
		submitCompletion(ctx);

		assert.equal(ctx.flow.mode, "persisted");
		assert.deepEqual(navigations, []);
		assert.equal(scheduled.size, 1);
		const [{ callback, delayMs }] = scheduled.values();
		assert.ok(delayMs <= 250, `save deadline was ${delayMs}ms`);
		callback();
		assert.deepEqual(navigations, ["/stats"]);
	} finally {
		ctx.destroyed();
		globalThis.window = originalWindow;
	}
});
