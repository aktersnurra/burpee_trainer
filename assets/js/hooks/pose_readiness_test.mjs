import assert from "node:assert/strict";
import test from "node:test";

import { initialPoseReadiness, stepPoseReadiness } from "./pose_readiness.mjs";

const point = (score = 0.9, x = 0.5, y = 0.5) => ({ score, x, y });

function sample({
	feet = false,
	confidence = 0.9,
	visibleFraction = 0.5,
} = {}) {
	return {
		confidence,
		features: { visibleFraction },
		keypoints: {
			left_shoulder: point(0.9, 0.42, 0.25),
			right_shoulder: point(0.9, 0.58, 0.25),
			left_hip: point(0.9, 0.45, 0.5),
			right_hip: point(0.9, 0.55, 0.5),
			left_knee: point(0.9, 0.46, 0.72),
			...(feet
				? {
						right_knee: point(0.9, 0.54, 0.72),
						left_ankle: point(0.9, 0.46, 0.92),
					}
				: {}),
		},
	};
}

function repeat(state, input, count) {
	let next = state;
	for (let index = 0; index < count; index += 1) {
		next = stepPoseReadiness(next, input);
	}
	return next;
}

test("stable core pose becomes ready without visible feet", () => {
	const state = repeat(
		initialPoseReadiness(),
		{ poseCount: 1, sample: sample() },
		8,
	);
	assert.equal(state.status, "ready");
});

test("strong lower-body coverage upgrades ready to optimal", () => {
	const state = repeat(
		initialPoseReadiness(),
		{ poseCount: 1, sample: sample({ feet: true, visibleFraction: 0.7 }) },
		8,
	);
	assert.equal(state.status, "optimal");
});

test("one valid frame cannot enable tracked start", () => {
	const state = stepPoseReadiness(initialPoseReadiness(), {
		poseCount: 1,
		sample: sample(),
	});
	assert.equal(state.status, "not_ready");
});

test("three consecutive invalid frames remove readiness", () => {
	const ready = repeat(
		initialPoseReadiness(),
		{ poseCount: 1, sample: sample() },
		8,
	);
	const lost = repeat(ready, { poseCount: 0, sample: sample() }, 3);
	assert.equal(lost.status, "not_ready");
});

test("multiple poses and missing hips remain not ready", () => {
	const missingHip = sample();
	delete missingHip.keypoints.right_hip;

	assert.equal(
		repeat(initialPoseReadiness(), { poseCount: 2, sample: sample() }, 8)
			.status,
		"not_ready",
	);
	assert.equal(
		repeat(initialPoseReadiness(), { poseCount: 1, sample: missingHip }, 8)
			.status,
		"not_ready",
	);
});
