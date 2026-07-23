import assert from "node:assert/strict";
import test from "node:test";

import {
	initialStartGesture,
	stepStartGesture,
} from "./pose_start_gesture.mjs";

const point = (score = 0.9, x = 0.5, y = 0.5) => ({ score, x, y });

function sample({
	leftWristY = 0.8,
	rightWristY = 0.8,
	leftShoulderY = 0.25,
	rightShoulderY = 0.25,
	includeLeftWrist = true,
	includeRightWrist = true,
} = {}) {
	return {
		keypoints: {
			left_shoulder: point(0.9, 0.42, leftShoulderY),
			right_shoulder: point(0.9, 0.58, rightShoulderY),
			...(includeLeftWrist
				? { left_wrist: point(0.9, 0.42, leftWristY) }
				: {}),
			...(includeRightWrist
				? { right_wrist: point(0.9, 0.58, rightWristY) }
				: {}),
		},
	};
}

function repeat(state, sample, holdFramesRequired, count) {
	let next = state;
	for (let index = 0; index < count; index += 1) {
		next = stepStartGesture(next, { sample, holdFramesRequired });
	}
	return next;
}

test("wrist raised above shoulder accumulates streak toward satisfied", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 15);
	assert.equal(state.satisfied, true);
	assert.equal(state.streak, 15);
});

test("streak below hold-frames threshold is not satisfied", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 14);
	assert.equal(state.satisfied, false);
	assert.equal(state.streak, 14);
});

test("either wrist raised is sufficient", () => {
	const raised = sample({ leftWristY: 0.8, rightWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 15);
	assert.equal(state.satisfied, true);
});

test("lowering the arm mid-hold resets the streak", () => {
	const raised = sample({ leftWristY: 0.1 });
	const lowered = sample({ leftWristY: 0.8, rightWristY: 0.8 });
	const partial = repeat(initialStartGesture(), raised, 15, 10);
	const dropped = stepStartGesture(partial, { sample: lowered, holdFramesRequired: 15 });
	assert.equal(dropped.streak, 0);
	assert.equal(dropped.satisfied, false);
});

test("missing wrist landmarks are treated as not raised", () => {
	const missing = sample({ includeLeftWrist: false, includeRightWrist: false });
	const state = repeat(initialStartGesture(), missing, 15, 15);
	assert.equal(state.satisfied, false);
	assert.equal(state.streak, 0);
});

test("low-confidence wrist landmark does not count as raised", () => {
	const weak = sample({ leftWristY: 0.1 });
	weak.keypoints.left_wrist.score = 0.2;
	const state = repeat(initialStartGesture(), weak, 15, 15);
	assert.equal(state.satisfied, false);
});

test("satisfied streak keeps counting past the threshold without resetting", () => {
	const raised = sample({ leftWristY: 0.1 });
	const state = repeat(initialStartGesture(), raised, 15, 20);
	assert.equal(state.satisfied, true);
	assert.equal(state.streak, 20);
});
