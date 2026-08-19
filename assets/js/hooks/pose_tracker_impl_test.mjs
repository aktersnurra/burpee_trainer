import assert from "node:assert/strict";
import test from "node:test";

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
		for (const listener of this.listeners.get(event.type) || [])
			listener(event);
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
		worldBodyVerticalSpan: 3.2,
		worldHipVerticalSpan: 2.35,
		worldWristVerticalSpan: 1.5,
		worldTorsoElevation: 0.85,
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
		worldBodyVerticalSpan: 2.1,
		worldHipVerticalSpan: 1.65,
		worldWristVerticalSpan: 0.7,
		worldTorsoElevation: 0.45,
		dWorldBodyVerticalSpan: -1,
		dWorldWristVerticalSpan: -1,
	},
	floor: {
		wristToAnkle: 0.16,
		shoulderToAnkle: 0.38,
		torsoUprightness: 0.12,
		hipToKnee: 0.52,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
		worldBodyVerticalSpan: 1.05,
		worldHipVerticalSpan: 0.7,
		worldWristVerticalSpan: 0.45,
		worldTorsoElevation: 0.35,
		dWorldBodyVerticalSpan: 0,
		dWorldWristVerticalSpan: 0,
	},
	returning: {
		wristToAnkle: 0.48,
		shoulderToAnkle: 0.72,
		torsoUprightness: 0.45,
		hipToKnee: 0.3,
		dWristToAnkle: 1.2,
		dShoulderToAnkle: 1.4,
		worldBodyVerticalSpan: 1.65,
		worldHipVerticalSpan: 1.1,
		worldWristVerticalSpan: 0.8,
		worldTorsoElevation: 0.55,
		dWorldBodyVerticalSpan: 1,
		dWorldWristVerticalSpan: 1,
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

function lowFrontCycle(startMs) {
	return [
		upright(startMs),
		lowering(startMs + 150),
		floorWork(startMs + 300),
		returning(startMs + 750),
		upright(startMs + 900),
	];
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

function rawLowFrontFrame(
	tMs,
	{ missingWorld = [], lowConfidence = [] } = {},
) {
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
			events.filter((event) => event.type === "pose-tracker:trace-chunk")
				.length,
		traceSampleTimes: () =>
			events
				.filter((event) => event.type === "pose-tracker:trace-chunk")
				.flatMap((event) =>
					event.detail.chunk.payload.samples.map((sample) => sample.tMs),
				),
		finish(detail) {
			tracker.dispatchEvent(new CustomEvent("pose-tracker:finish", { detail }));
		},
		repIndexes: () =>
			events
				.filter((event) => event.type === "pose-tracker:rep")
				.map((event) => event.detail.index),
		statusEvents: () =>
			events
				.filter((event) => event.type === "pose-tracker:status")
				.map((event) => event.detail.state),
	};
}

test("does not emit a candidate or persist an isolated frame without required world landmarks", async () => {
	const tracker = mountedTrackerWithSamples(
		[lowFrontFrame("lowering", 150, { missingWorld: ["left_wrist"] })],
		{ captureSegment: "workout" },
	);

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), []);
	assert.equal(tracker.traceChunkCount(), 0);
	assert.equal(tracker.statusEvents().includes("lost"), false);
});

test("raw missing knee or foot world frames are silent and unpersisted", async () => {
	for (const missingWorld of ["left_knee", "right_foot_index"]) {
		const frames = [rawLowFrontFrame(0, { missingWorld: [missingWorld] })];
		const tracker = mountedTrackerWithSamples(frames, {
			captureSegment: "workout",
			controlledPoseFixture: frames,
			sampleFromPose,
		});

		await tracker.run();

		assert.deepEqual(tracker.repIndexes(), []);
		assert.equal(tracker.traceChunkCount(), 0);
		assert.equal(tracker.statusEvents().includes("lost"), false);
	}
});

test("raw low-confidence nose or foot frames are silent and unpersisted", async () => {
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
		assert.equal(tracker.traceChunkCount(), 0);
		assert.equal(tracker.statusEvents().includes("lost"), false);
	}
});

test("persists only usable world frames from a mixed low-front sequence", async () => {
	const tracker = mountedTrackerWithSamples(
		[
			lowFrontFrame("upright", 0),
			lowFrontFrame("lowering", 150, { missingWorld: ["left_wrist"] }),
			lowFrontFrame("floor", 300),
		],
		{ captureSegment: "workout" },
	);

	await tracker.run();

	assert.deepEqual(tracker.traceSampleTimes(), [0, 300]);
});

test("keeps counting after absent low-front frames without image-plane fallback", async () => {
	const tracker = mountedTrackerWithSamples([
		...lowFrontCycle(0),
		...absentFrames(1000, 2000),
		...lowFrontCycle(3500),
	]);

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), [1, 2]);
	assert.deepEqual(tracker.statusEvents(), ["live"]);
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

test("does not persist an absent observation to a pose trace", async () => {
	const tracker = mountedTrackerWithSamples([absent(0)], {
		captureSegment: "workout",
	});

	await tracker.run();

	assert.deepEqual(tracker.traceChunks(), []);
});

test("invalid finish data does not report a tracker loss", async () => {
	const tracker = mountedTrackerWithSamples([upright(0)]);

	await tracker.run();
	tracker.finish({ durationMs: -1, cadenceMs: [] });

	assert.deepEqual(tracker.statusEvents(), ["live"]);
});
