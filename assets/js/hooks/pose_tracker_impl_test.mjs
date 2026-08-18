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
			(this.listeners.get(type) || []).filter((candidate) => candidate !== listener),
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
		documentListeners.set(type, [...(documentListeners.get(type) || []), listener]);
	},
	removeEventListener(type, listener) {
		documentListeners.set(
			type,
			(documentListeners.get(type) || []).filter((candidate) => candidate !== listener),
		);
	},
	dispatchEvent(event) {
		for (const listener of documentListeners.get(event.type) || []) listener(event);
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

function upright(tMs) {
	return feature(tMs, {
		wristToAnkle: 1.25,
		shoulderToAnkle: 2.1,
		torsoUprightness: 0.9,
		hipToKnee: 0.9,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
	});
}

function lowering(tMs) {
	return feature(tMs, {
		wristToAnkle: 0.55,
		shoulderToAnkle: 1.2,
		torsoUprightness: 0.55,
		hipToKnee: 0.6,
		dWristToAnkle: -1.4,
		dShoulderToAnkle: -1.1,
	});
}

function floorWork(tMs) {
	return feature(tMs, {
		wristToAnkle: 0.16,
		shoulderToAnkle: 0.38,
		torsoUprightness: 0.12,
		hipToKnee: 0.52,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
	});
}

function returning(tMs) {
	return feature(tMs, {
		wristToAnkle: 0.48,
		shoulderToAnkle: 0.72,
		torsoUprightness: 0.45,
		hipToKnee: 0.3,
		dWristToAnkle: 1.2,
		dShoulderToAnkle: 1.4,
	});
}

function completeCycle(startMs) {
	return [
		upright(startMs),
		lowering(startMs + 100),
		floorWork(startMs + 200),
		returning(startMs + 300),
		upright(startMs + 400),
	];
}

function absent(tMs) {
	return feature(tMs, {}, 0.1);
}

function absentFrames(startMs) {
	return [absent(startMs), absent(startMs + 100)];
}

function mountedTrackerWithSamples(samples, { captureSegment = null } = {}) {
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
			createBlazePoseDetector: async () => ({
				estimatePoses() {
					current = samples[index];
					index += 1;
					return Promise.resolve([{}]);
				},
			}),
			mediaDevices: {
				getUserMedia: async () => ({ getTracks: () => [] }),
			},
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
			while (index < samples.length) {
				nowMs += 100;
				const callback = animationFrames.shift();
				assert.ok(callback, "expected a scheduled animation frame");
				await callback();
				await Promise.resolve();
			}
			tracker.dispatchEvent(
				new CustomEvent("pose-tracker:finish", {
					detail: { durationMs: Math.round(nowMs), cadenceMs: [] },
				}),
			);
		},
		traceChunks: () =>
			events.filter((event) => event.type === "pose-tracker:trace-chunk"),
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

test("keeps the same HSMM state through absent frames and counts the next full cycle", async () => {
	const tracker = mountedTrackerWithSamples([
		...completeCycle(0),
		...absentFrames(2600),
		...completeCycle(4000),
	]);

	await tracker.run();

	assert.deepEqual(tracker.repIndexes(), [1, 2]);
	assert.deepEqual(tracker.statusEvents(), ["live"]);
});

test("does not emit a lost status for a low-confidence frame", async () => {
	const tracker = mountedTrackerWithSamples([upright(0), absent(100), upright(200)]);

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
