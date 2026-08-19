import assert from "node:assert/strict";
import test from "node:test";

import { createPoseTracker } from "./pose_tracker_impl.mjs";

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

function mountedTrackerWithSamples(
	samples,
	{ captureSegment = null, controlledPoseFixture = null } = {},
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
			sampleFromPose: () => current,
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

test("runs controlled feature frames without a camera or detector", async () => {
	const samples = completeCycle(0);
	const tracker = mountedTrackerWithSamples(samples, {
		controlledPoseFixture: samples.map((sample) => sample.features),
	});

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), [1]);
	assert.deepEqual(tracker.statusEvents(), ["live"]);
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
