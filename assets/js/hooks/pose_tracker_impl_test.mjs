import assert from "node:assert/strict";
import test from "node:test";

import { initialBurpeeHsmmState, stepBurpeeHsmm } from "./pose_burpee_hsmm.mjs";
import { createPoseTracker } from "./pose_tracker_impl.mjs";
import { sampleFromPose } from "./pose_signal.mjs";

class FakeElement {
	constructor() {
		this.children = [];
		this.dataset = {};
		this.listeners = new Map();
	}

	append(...children) {
		this.children.push(...children);
	}

	addEventListener(type, listener) {
		this.listeners.set(type, [...(this.listeners.get(type) || []), listener]);
	}

	removeEventListener(type, listener) {
		this.listeners.set(
			type,
			(this.listeners.get(type) || []).filter(
				(candidate) => candidate !== listener,
			),
		);
	}

	dispatchEvent(event) {
		for (const listener of this.listeners.get(event.type) || []) listener(event);
		return true;
	}

	querySelector(selector) {
		return this.children.find((child) => `#${child.id}` === selector) || null;
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
	documentElement: {},
	addEventListener(type, listener) {
		documentListeners.set(type, [
			...(documentListeners.get(type) || []),
			listener,
		]);
	},
	removeEventListener(type, listener) {
		documentListeners.set(
			type,
			(documentListeners.get(type) || []).filter(
				(candidate) => candidate !== listener,
			),
		);
	},
	dispatchEvent(event) {
		for (const listener of documentListeners.get(event.type) || [])
			listener(event);
	},
};

function feature(tMs, values, confidence = 0.9) {
	return {
		tMs,
		confidence,
		features: {
			tMs,
			poseConfidence: confidence,
			visibleFraction: confidence,
			macroLandmarkConfidence: confidence,
			hasFullWorldLandmarkCoverage: true,
			...values,
		},
	};
}

const LOW_FRONT_FEATURES = Object.freeze({
	upright: {
		wristToAnkle: 1.25,
		shoulderToAnkle: 2.1,
		torsoUprightness: 0.9,
		hipToKnee: 0.9,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
		worldBodyVerticalSpan: 2.75,
		worldHipVerticalSpan: 1.78,
		worldWristVerticalSpan: 1.87,
		worldTorsoElevation: 0.96,
		dWorldBodyVerticalSpan: 0,
		dWorldWristVerticalSpan: 0,
	},
	lowering: {
		wristToAnkle: 0.55,
		shoulderToAnkle: 1.2,
		torsoUprightness: 0.55,
		hipToKnee: 0.6,
		dWristToAnkle: -1.4,
		dShoulderToAnkle: -1.1,
		worldBodyVerticalSpan: 1.9,
		worldHipVerticalSpan: 1.62,
		worldWristVerticalSpan: 0.88,
		worldTorsoElevation: 0.4,
		dWorldBodyVerticalSpan: -3,
		dWorldWristVerticalSpan: -3.3,
	},
	floor: {
		wristToAnkle: 0.16,
		shoulderToAnkle: 0.38,
		torsoUprightness: 0.12,
		hipToKnee: 0.52,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
		worldBodyVerticalSpan: 0.93,
		worldHipVerticalSpan: 0.94,
		worldWristVerticalSpan: 0.23,
		worldTorsoElevation: 0.2,
		dWorldBodyVerticalSpan: 0,
		dWorldWristVerticalSpan: 0.2,
	},
	returning: {
		wristToAnkle: 0.48,
		shoulderToAnkle: 0.72,
		torsoUprightness: 0.45,
		hipToKnee: 0.3,
		dWristToAnkle: 1.2,
		dShoulderToAnkle: 1.4,
		worldBodyVerticalSpan: 2.15,
		worldHipVerticalSpan: 1.56,
		worldWristVerticalSpan: 1.1,
		worldTorsoElevation: 0.59,
		dWorldBodyVerticalSpan: 3.2,
		dWorldWristVerticalSpan: 3.9,
	},
});

function lowFrontFrame(phase, tMs, { missingWorld = [] } = {}) {
	const values = LOW_FRONT_FEATURES[phase];
	if (!values) throw new Error(`unknown low-front phase: ${phase}`);

	const missingWristWorld = missingWorld.includes("left_wrist");
	return feature(tMs, {
		...values,
		...(missingWristWorld && {
			worldWristVerticalSpan: null,
			dWorldWristVerticalSpan: null,
		}),
	});
}

function upright(tMs) {
	return lowFrontFrame("upright", tMs);
}

function lowering(tMs) {
	return lowFrontFrame("lowering", tMs);
}

function floorWork(tMs) {
	return lowFrontFrame("floor", tMs);
}

function returning(tMs) {
	return lowFrontFrame("returning", tMs);
}

// One rep sampled every 100 ms over 4 s; its return to standing starts at 2.6 s.
function lowFrontCycle(startMs) {
	const phases = [
		[upright, 1_000],
		[lowering, 400],
		[floorWork, 800],
		[returning, 400],
		[upright, 1_400],
	];
	const frames = [];
	let tMs = startMs;
	for (const [frame, durationMs] of phases) {
		for (const end = tMs + durationMs; tMs < end; tMs += 100) frames.push(frame(tMs));
	}
	return frames;
}

function completeCycle(startMs) {
	return lowFrontCycle(startMs);
}

function absent(tMs) {
	return feature(tMs, {}, 0.1);
}

function absentFrames(startMs, durationMs = 200) {
	return Array.from({ length: durationMs / 100 }, (_, index) =>
		absent(startMs + index * 100),
	);
}

function rawLowFrontFrame(tMs, { missingWorld = [], lowConfidence = [] } = {}) {
	const point = (name, x, y, world) => ({
		name,
		x,
		y,
		score: lowConfidence.includes(name) ? 0.1 : 0.9,
		...(missingWorld.includes(name) ? {} : { world }),
	});

	return {
		tMs,
		keypoints: [
			point("nose", 320, 80, { x: 0, y: 0.3, z: 0 }),
			point("left_shoulder", 240, 120, { x: -0.5, y: 0, z: 0 }),
			point("right_shoulder", 400, 120, { x: 0.5, y: 0, z: 0 }),
			point("left_wrist", 220, 270, { x: -0.7, y: -1.7, z: 0 }),
			point("right_wrist", 420, 270, { x: 0.7, y: -1.7, z: 0 }),
			point("left_hip", 260, 240, { x: -0.4, y: -1, z: 0 }),
			point("right_hip", 380, 240, { x: 0.4, y: -1, z: 0 }),
			point("left_knee", 270, 340, { x: -0.4, y: -2, z: 0 }),
			point("right_knee", 370, 340, { x: 0.4, y: -2, z: 0 }),
			point("left_ankle", 280, 440, { x: -0.4, y: -3, z: 0 }),
			point("right_ankle", 360, 440, { x: 0.4, y: -3, z: 0 }),
			point("left_foot_index", 270, 455, { x: -0.45, y: -3, z: 0.15 }),
			point("right_foot_index", 370, 455, { x: 0.45, y: -3, z: 0.15 }),
		],
	};
}

function mountedTrackerWithSamples(
	samples,
	{
		captureSegment = null,
		controlledPoseFixture = null,
		sampleFromPose: sampleFromPoseOverride = null,
	} = {},
) {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
		play: async () => {},
	};
	const context = {
		setTransform() {},
		clearRect() {},
	};
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => context,
	};
	tracker.append(video, canvas);

	const events = [];
	for (const type of [
		"pose-tracker:rep",
		"pose-tracker:status",
		"pose-tracker:trace-chunk",
	]) {
		tracker.addEventListener(type, (event) => events.push(event));
	}

	let current = null;
	let index = 0;
	let nowMs = 0;
	const animationFrames = [];
	const impl = createPoseTracker(
		{ el: tracker },
		{
			createBlazePoseDetector: controlledPoseFixture
				? async () => {
						throw new Error("controlled fixture must not load a detector");
					}
				: async () => ({
						estimatePoses() {
							current = samples[index];
							index += 1;
							return Promise.resolve([{}]);
						},
					}),
			mediaDevices: {
				getUserMedia: controlledPoseFixture
					? async () => {
							throw new Error("controlled fixture must not request a camera");
						}
					: async () => ({ getTracks: () => [] }),
			},
			controlledPoseFixture,
			now: () => nowMs,
			requestAnimationFrame(callback) {
				animationFrames.push(callback);
				return animationFrames.length;
			},
			cancelAnimationFrame() {},
			sampleFromPose: sampleFromPoseOverride || (() => current),
			waitForVideoFrame: async () => video,
			webglAvailable: () => true,
		},
	);

	return {
		async run() {
			await impl.mounted();
			if (captureSegment) {
				document.dispatchEvent(
					new CustomEvent("pose-capture:segment", {
						detail: { segment: captureSegment },
					}),
				);
			}
			await impl.start();
			let remainingControlledFrames = controlledPoseFixture
				? samples.length - 1
				: null;
			while (
				controlledPoseFixture
					? remainingControlledFrames > 0
					: index < samples.length
			) {
				nowMs += 100;
				const callback = animationFrames.shift();
				assert.ok(callback, "expected a scheduled animation frame");
				await callback();
				await Promise.resolve();
				if (controlledPoseFixture) remainingControlledFrames -= 1;
			}
			tracker.dispatchEvent(
				new CustomEvent("pose-tracker:finish", {
					detail: { durationMs: Math.round(nowMs), cadenceMs: [] },
				}),
			);
		},
		traceChunks: () =>
			events.filter((event) => event.type === "pose-tracker:trace-chunk"),
		traceChunkCount: () =>
			events.filter((event) => event.type === "pose-tracker:trace-chunk").length,
		traceSampleTimes: () =>
			events
				.filter((event) => event.type === "pose-tracker:trace-chunk")
				.flatMap((event) => event.detail.chunk.payload.samples.map(traceEntry)),
		finish(detail) {
			tracker.dispatchEvent(new CustomEvent("pose-tracker:finish", { detail }));
		},
		repIndexes: () =>
			events
				.filter((event) => event.type === "pose-tracker:rep")
				.map((event) => event.detail.index),
		repLags: () =>
			events
				.filter((event) => event.type === "pose-tracker:rep")
				.map((event) => event.detail.lagMs),
		statusEvents: () =>
			events
				.filter((event) => event.type === "pose-tracker:status")
				.map((event) => event.detail.state),
	};
}

// A trace entry: a sample's time, "<tMs>:unusable" for a dropout marker, "reset" for a reset.
function traceEntry(sample) {
	if (sample.reset) return "reset";
	if (sample.usable === false) return `${sample.tMs}:unusable`;
	return sample.tMs;
}

test("an isolated frame without required world landmarks emits no rep and is traced as unusable", async () => {
	const tracker = mountedTrackerWithSamples(
		[lowFrontFrame("lowering", 150, { missingWorld: ["left_wrist"] })],
		{ captureSegment: "workout" },
	);

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), []);
	assert.deepEqual(tracker.traceSampleTimes(), ["150:unusable"]);
	assert.equal(tracker.statusEvents().includes("lost"), false);
});

test("raw missing knee or foot world frames are silent and traced as unusable", async () => {
	for (const missingWorld of ["left_knee", "right_foot_index"]) {
		const frames = [rawLowFrontFrame(0, { missingWorld: [missingWorld] })];
		const tracker = mountedTrackerWithSamples(frames, {
			captureSegment: "workout",
			controlledPoseFixture: frames,
			sampleFromPose,
		});

		await tracker.run();

		assert.deepEqual(tracker.repIndexes(), []);
		assert.deepEqual(tracker.traceSampleTimes(), ["0:unusable"]);
		assert.equal(tracker.statusEvents().includes("lost"), false);
	}
});

test("raw low-confidence nose or foot frames are silent and traced as unusable", async () => {
	for (const lowConfidence of ["nose", "right_foot_index"]) {
		const frames = [
			rawLowFrontFrame(0, { lowConfidence: [lowConfidence] }),
			rawLowFrontFrame(100, { lowConfidence: [lowConfidence] }),
		];
		const tracker = mountedTrackerWithSamples(frames, {
			captureSegment: "workout",
			controlledPoseFixture: frames,
			sampleFromPose,
		});

		await tracker.run();

		assert.deepEqual(tracker.repIndexes(), []);
		assert.deepEqual(tracker.traceSampleTimes(), ["0:unusable", "100:unusable"]);
		assert.equal(tracker.statusEvents().includes("lost"), false);
	}
});

test("traces usable frames in full and unusable ones as markers, in order", async () => {
	const tracker = mountedTrackerWithSamples(
		[
			lowFrontFrame("upright", 0),
			lowFrontFrame("lowering", 150, { missingWorld: ["left_wrist"] }),
			lowFrontFrame("floor", 300),
		],
		{ captureSegment: "workout" },
	);

	await tracker.run();

	assert.deepEqual(tracker.traceSampleTimes(), [0, "150:unusable", 300]);
});

test("keeps counting after absent low-front frames without image-plane fallback", async () => {
	const tracker = mountedTrackerWithSamples([
		...lowFrontCycle(0),
		...absentFrames(4_000, 2_000),
		...lowFrontCycle(6_000),
	]);

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), [1, 2]);
	assert.deepEqual(tracker.statusEvents(), ["live"]);
});

test("a rep event says how long after the rep it was decided", async () => {
	const tracker = mountedTrackerWithSamples(lowFrontCycle(0));

	await tracker.run();

	const [lagMs] = tracker.repLags();
	assert.ok(lagMs >= 600 && lagMs <= 800, `lag ${lagMs}`);
});

test("a recorded trace replays to exactly the reps the tracker emitted", async () => {
	const dropout = lowFrontCycle(4_000).map((frame, index) =>
		index >= 11 && index < 13 ? absent(frame.tMs) : frame,
	);
	const tracker = mountedTrackerWithSamples(
		[
			...lowFrontCycle(0),
			...dropout,
			...absentFrames(8_000, 1_500),
			...lowFrontCycle(9_500),
		],
		{ captureSegment: "workout" },
	);

	await tracker.run();

	const payloads = tracker.traceChunks().map((event) => event.detail.chunk.payload);
	let state = initialBurpeeHsmmState();
	const replayed = [];
	for (const sample of payloads.flatMap((payload) => payload.samples)) {
		if (sample.reset) {
			state = initialBurpeeHsmmState();
			continue;
		}
		const result = stepBurpeeHsmm(state, sample.features ?? sample);
		state = result.state;
		replayed.push(...result.reps);
	}

	assert.equal(tracker.repIndexes().length, 3);
	assert.deepEqual(replayed, payloads.flatMap((payload) => payload.reps));
	assert.equal(replayed.length, 3);
});

test("runs raw controlled frames through sampleFromPose with the prior feature", async () => {
	const samples = completeCycle(0);
	const rawFrames = samples.map((sample, index) => ({
		tMs: sample.tMs,
		keypoints: { phase: index },
	}));
	const calls = [];
	const tracker = mountedTrackerWithSamples(rawFrames, {
		controlledPoseFixture: rawFrames,
		sampleFromPose(pose, tMs, _video, lastFeature) {
			calls.push({ pose, tMs, lastFeature });
			return samples[calls.length - 1];
		},
	});

	await tracker.run();

	assert.equal(calls.length, rawFrames.length);
	assert.equal(calls[0].pose.keypoints, rawFrames[0].keypoints);
	assert.equal(calls[0].lastFeature, null);
	assert.equal(calls[1].lastFeature, samples[0].features);
	assert.deepEqual(tracker.repIndexes(), [1]);
});

test("does not emit a lost status for a low-confidence frame", async () => {
	const tracker = mountedTrackerWithSamples([
		upright(0),
		absent(100),
		upright(200),
	]);

	await tracker.run();

	assert.equal(tracker.statusEvents().includes("lost"), false);
});

test("an absent observation is traced as unusable", async () => {
	const tracker = mountedTrackerWithSamples([absent(0)], {
		captureSegment: "workout",
	});

	await tracker.run();

	assert.deepEqual(tracker.traceSampleTimes(), ["0:unusable"]);
});

test("invalid finish data does not report a tracker loss", async () => {
	const tracker = mountedTrackerWithSamples([upright(0)]);

	await tracker.run();
	tracker.finish({ durationMs: -1, cadenceMs: [] });

	assert.deepEqual(tracker.statusEvents(), ["live"]);
});

test("hidden preview continues pose processing without drawing the overlay", async () => {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
	};
	let drawCalls = 0;
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => ({
			setTransform() {},
			clearRect() {
				drawCalls += 1;
			},
			save() {},
			scale() {},
			translate() {},
			beginPath() {},
			moveTo() {},
			lineTo() {},
			stroke() {},
			arc() {},
			fill() {},
			restore() {},
		}),
	};
	tracker.append(video, canvas);
	video.play = async () => {};
	const animationFrames = [];
	let nowMs = 0;
	let samples = 0;
	const impl = createPoseTracker(
		{ el: tracker },
		{
			createBlazePoseDetector: async () => ({
				estimatePoses: async () => [{ keypoints: [] }],
			}),
			mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
			waitForVideoFrame: async () => video,
			webglAvailable: () => true,
			now: () => nowMs,
			requestAnimationFrame(callback) {
				animationFrames.push(callback);
				return animationFrames.length;
			},
			cancelAnimationFrame() {},
			sampleFromPose: () => {
				samples += 1;
				return upright(nowMs);
			},
		},
	);

	await impl.mounted();
	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:preview-visibility", {
			detail: { visible: false },
		}),
	);
	await impl.start();
	nowMs = 100;
	await animationFrames.shift()();

	assert.equal(samples, 2);
	assert.equal(drawCalls, 0);
});

test("preview sizing waits for a visible non-zero canvas", async () => {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
	};
	let rect = { width: 0, height: 0 };
	const canvas = {
		id: "pose-tracker-canvas",
		width: 0,
		height: 0,
		getBoundingClientRect: () => rect,
		getContext: () => ({ setTransform() {} }),
	};
	tracker.append(video, canvas);
	const impl = createPoseTracker(
		{ el: tracker },
		{
			controlledPoseFixture: [rawLowFrontFrame(0)],
			requestAnimationFrame: () => 1,
			cancelAnimationFrame() {},
			sampleFromPose: () => upright(0),
		},
	);

	await impl.mounted();
	await impl.start();
	assert.equal(canvas.width, 0);
	assert.equal(canvas.height, 0);

	rect = { width: 320, height: 240 };
	tracker.dispatchEvent(
		new CustomEvent("pose-tracker:preview-visibility", {
			detail: { visible: true },
		}),
	);
	assert.equal(canvas.width, 320);
	assert.equal(canvas.height, 240);
});

function deferred() {
	let resolve;
	let reject;
	const promise = new Promise((resolvePromise, rejectPromise) => {
		resolve = resolvePromise;
		reject = rejectPromise;
	});
	return { promise, resolve, reject };
}

async function settleAsyncWork() {
	await Promise.resolve();
	await Promise.resolve();
}

function mountedDeferredDetectorTracker(samples = []) {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
		play: async () => {},
	};
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => ({ setTransform() {} }),
	};
	tracker.append(video, canvas);

	const estimates = [];
	const animationFrames = [];
	const cancelledFrames = new Set();
	const traceChunks = [];
	const previousFeatures = [];
	const repIndexes = [];
	let sampleIndex = 0;
	let nowMs = 0;
	tracker.addEventListener("pose-tracker:rep", (event) =>
		repIndexes.push(event.detail.index),
	);
	tracker.addEventListener("pose-tracker:trace-chunk", (event) =>
		traceChunks.push(event.detail.chunk),
	);

	const impl = createPoseTracker(
		{ el: tracker },
		{
			createBlazePoseDetector: async () => ({
				estimatePoses() {
					const next = deferred();
					estimates.push(next);
					return next.promise;
				},
			}),
			mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
			waitForVideoFrame: async () => video,
			webglAvailable: () => true,
			now: () => nowMs,
			requestAnimationFrame(callback) {
				const frame = { id: animationFrames.length + 1, callback };
				animationFrames.push(frame);
				return frame.id;
			},
			cancelAnimationFrame(id) {
				cancelledFrames.add(id);
			},
			sampleFromPose(_pose, _tMs, _video, lastFeature) {
				previousFeatures.push(lastFeature);
				return samples[sampleIndex++] || upright(nowMs);
			},
		},
	);

	return {
		tracker,
		estimates,
		animationFrames,
		cancelledFrames,
		previousFeatures,
		repIndexes,
		traceSampleTimes() {
			return traceChunks.flatMap((chunk) => chunk.payload.samples.map(traceEntry));
		},
		setNow(value) {
			nowMs = value;
		},
		async start() {
			await impl.mounted();
			document.dispatchEvent(
				new CustomEvent("pose-capture:segment", {
					detail: { segment: "workout" },
				}),
			);
			await impl.start();
		},
		finish() {
			tracker.dispatchEvent(
				new CustomEvent("pose-tracker:finish", {
					detail: { durationMs: nowMs, cadenceMs: [] },
				}),
			);
		},
	};
}

test("detector failure flushes already-sampled poses before reporting tracking lost", async () => {
	const subject = mountedDeferredDetectorTracker([upright(0)]);
	let samplesWhenLost;
	subject.tracker.addEventListener("pose-tracker:status", (event) => {
		if (event.detail.reason === "detector_error") samplesWhenLost = subject.traceSampleTimes();
	});
	await subject.start();
	subject.estimates[0].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.deepEqual(subject.traceSampleTimes(), []);
	subject.setNow(100);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	subject.estimates[1].reject(new Error("forced detector failure"));
	await settleAsyncWork();
	assert.deepEqual(samplesWhenLost, [0]);
	subject.finish();
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:stop"));
	assert.deepEqual(subject.traceSampleTimes(), [0]);
});

test("stopping capture flushes its pending tail exactly once", async () => {
	const subject = mountedDeferredDetectorTracker([upright(0)]);
	await subject.start();
	subject.estimates[0].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:stop"));
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:stop"));
	subject.finish();
	assert.deepEqual(subject.traceSampleTimes(), [0]);
});

test("a pending inference settled while suspended cannot capture or revive its loop", async () => {
	const subject = mountedDeferredDetectorTracker([
		lowering(0),
		floorWork(200),
		returning(300),
		upright(400),
	]);
	await subject.start();

	subject.estimates[0].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.deepEqual(subject.previousFeatures, [null]);

	subject.setNow(100);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	assert.equal(subject.estimates.length, 2);

	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:suspend"));
	subject.estimates[1].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.deepEqual(subject.previousFeatures, [null]);

	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:resume"));
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:resume"));
	assert.equal(subject.animationFrames.length, 1);

	subject.setNow(200);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	subject.estimates[2].resolve([{ keypoints: [] }]);
	await settleAsyncWork();

	subject.setNow(300);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	subject.estimates[3].resolve([{ keypoints: [] }]);
	await settleAsyncWork();

	subject.setNow(400);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	subject.estimates[4].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	subject.finish();

	assert.equal(subject.previousFeatures[0], null);
	assert.equal(subject.previousFeatures[1], null);
	assert.deepEqual(subject.repIndexes, []);
	assert.deepEqual(subject.traceSampleTimes(), [0, "reset", 200, 300, 400]);
});

test("resume waits for a pending inference before starting another detector call", async () => {
	const subject = mountedDeferredDetectorTracker();
	await subject.start();
	assert.equal(subject.estimates.length, 1);

	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:suspend"));
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:resume"));
	assert.equal(subject.animationFrames.length, 1);

	subject.setNow(100);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	assert.equal(subject.estimates.length, 1);

	subject.estimates[0].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.equal(subject.animationFrames.length, 1);

	subject.setNow(200);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	assert.equal(subject.estimates.length, 2);
});

test("resuming before a pending inference settles retains one sampling loop", async () => {
	const subject = mountedDeferredDetectorTracker();
	await subject.start();
	assert.equal(subject.estimates.length, 1);

	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:suspend"));
	subject.tracker.dispatchEvent(new CustomEvent("pose-tracker:resume"));
	assert.equal(subject.animationFrames.length, 1);

	subject.estimates[0].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.deepEqual(subject.previousFeatures, []);
	assert.equal(subject.animationFrames.length, 1);

	subject.setNow(100);
	subject.animationFrames.shift().callback();
	await settleAsyncWork();
	assert.equal(subject.estimates.length, 2);
	subject.estimates[1].resolve([{ keypoints: [] }]);
	await settleAsyncWork();
	assert.deepEqual(subject.previousFeatures, [null]);
});

test("suspending a stopped tracker does not block its next start", async () => {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
	};
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => ({ setTransform() {} }),
	};
	tracker.append(video, canvas);
	let sampleCalls = 0;
	const impl = createPoseTracker(
		{ el: tracker },
		{
			controlledPoseFixture: [rawLowFrontFrame(0)],
			requestAnimationFrame: () => 1,
			cancelAnimationFrame() {},
			sampleFromPose: () => {
				sampleCalls += 1;
				return upright(0);
			},
		},
	);

	await impl.mounted();
	tracker.dispatchEvent(new CustomEvent("pose-tracker:suspend"));
	await impl.start();

	assert.equal(sampleCalls, 1);
});

test("suspending skips scheduled pose work and resume resets temporal sampling", async () => {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
	};
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => ({ setTransform() {} }),
	};
	tracker.append(video, canvas);
	const frames = [rawLowFrontFrame(0), rawLowFrontFrame(100)];
	const animationFrames = [];
	let nowMs = 0;
	let samples = 0;
	const impl = createPoseTracker(
		{ el: tracker },
		{
			controlledPoseFixture: frames,
			now: () => nowMs,
			requestAnimationFrame(callback) {
				animationFrames.push(callback);
				return animationFrames.length;
			},
			cancelAnimationFrame() {},
			sampleFromPose: () => {
				samples += 1;
				return upright(nowMs);
			},
		},
	);

	await impl.mounted();
	await impl.start();
	const scheduledBeforeSuspend = animationFrames.shift();
	tracker.dispatchEvent(new CustomEvent("pose-tracker:suspend"));
	nowMs = 10;
	await scheduledBeforeSuspend();
	assert.equal(samples, 1);

	tracker.dispatchEvent(new CustomEvent("pose-tracker:resume"));
	assert.equal(animationFrames.length, 1);
	await animationFrames.shift()();
	assert.equal(samples, 2);
});

test("a pose worker that cannot start fails the camera instead of falling back", async () => {
	const tracker = new FakeElement();
	const video = {
		id: "pose-tracker-preview",
		videoWidth: 640,
		videoHeight: 480,
		play: async () => {},
	};
	const canvas = {
		id: "pose-tracker-canvas",
		getBoundingClientRect: () => ({ width: 320, height: 240 }),
		getContext: () => ({ setTransform() {} }),
	};
	tracker.append(video, canvas);
	const failures = [];
	tracker.addEventListener("pose-tracker:start-failed", (event) =>
		failures.push(event.detail),
	);

	const impl = createPoseTracker(
		{ el: tracker },
		{
			createBlazePoseDetector: async () => {
				throw new Error("pose worker unavailable");
			},
			mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) },
			waitForVideoFrame: async () => video,
			webglAvailable: () => true,
			requestAnimationFrame: () => 1,
			cancelAnimationFrame() {},
		},
	);

	await impl.mounted();
	await impl.start();

	assert.equal(failures.length, 1);
	assert.match(failures[0].reason, /pose worker unavailable/);
	assert.equal(failures[0].stage, "detector");
});
