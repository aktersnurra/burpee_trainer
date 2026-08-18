import assert from "node:assert/strict";
import test from "node:test";

import { initialBurpeeHsmmState, stepBurpeeHsmm } from "./pose_burpee_hsmm.mjs";
import { featureFrameFromPose } from "./pose_features.mjs";

const video = { videoWidth: 400, videoHeight: 400 };
const LANDMARK_NAMES = [
	"nose",
	"left_eye_inner",
	"left_eye",
	"left_eye_outer",
	"right_eye",
	"right_ear",
	"mouth_left",
	"mouth_right",
	"left_shoulder",
	"right_shoulder",
	"left_elbow",
	"right_elbow",
	"left_wrist",
	"right_wrist",
	"left_pinky",
	"right_pinky",
	"left_index",
	"right_index",
	"left_thumb",
	"right_thumb",
	"left_hip",
	"right_hip",
	"left_knee",
	"right_knee",
	"left_ankle",
	"right_ankle",
	"left_heel",
	"right_heel",
	"left_foot_index",
	"right_foot_index",
];

function frame(tMs, features) {
	return {
		tMs,
		poseConfidence: 0.9,
		visibleFraction: 0.9,
		macroLandmarkConfidence: 0.9,
		...features,
	};
}

function upright(tMs) {
	return frame(tMs, {
		wristToAnkle: 1.25,
		shoulderToAnkle: 2.1,
		torsoUprightness: 0.9,
		hipToKnee: 0.9,
		dWristToAnkle: 0,
		dShoulderToAnkle: 0,
	});
}

function loweringToFloor(tMs) {
	return frame(tMs, {
		wristToAnkle: 0.55,
		shoulderToAnkle: 1.2,
		torsoUprightness: 0.55,
		hipToKnee: 0.6,
		dWristToAnkle: -1.4,
		dShoulderToAnkle: -1.1,
	});
}

function floorWork(tMs, oscillation = 0) {
	return frame(tMs, {
		wristToAnkle: 0.16,
		shoulderToAnkle: 0.38 + oscillation,
		torsoUprightness: 0.12,
		hipToKnee: 0.52,
		dWristToAnkle: 0,
		dShoulderToAnkle: oscillation * 10,
	});
}

function returningFromFloor(tMs) {
	return frame(tMs, {
		wristToAnkle: 0.48,
		shoulderToAnkle: 0.72,
		torsoUprightness: 0.45,
		hipToKnee: 0.3,
		dWristToAnkle: 1.2,
		dShoulderToAnkle: 1.4,
	});
}

function onePushupCycle(startMs = 0) {
	return [
		upright(startMs),
		loweringToFloor(startMs + 150),
		floorWork(startMs + 300),
		floorWork(startMs + 450, 0.12),
		floorWork(startMs + 600),
		returningFromFloor(startMs + 750),
		upright(startMs + 900),
	];
}

function threePushupCycle(startMs = 2_500) {
	return [
		upright(startMs),
		loweringToFloor(startMs + 150),
		floorWork(startMs + 300),
		floorWork(startMs + 450, 0.12),
		floorWork(startMs + 600),
		floorWork(startMs + 750, 0.12),
		floorWork(startMs + 900),
		floorWork(startMs + 1_050, 0.12),
		floorWork(startMs + 1_200),
		returningFromFloor(startMs + 1_350),
		upright(startMs + 1_500),
	];
}

function squatOnlyFrames() {
	return [
		upright(0),
		frame(150, {
			wristToAnkle: 1.1,
			shoulderToAnkle: 1.15,
			torsoUprightness: 0.86,
			hipToKnee: 0.25,
			dWristToAnkle: -0.2,
			dShoulderToAnkle: -0.7,
		}),
		upright(300),
	];
}

function interruptedFloorFrames() {
	return [
		upright(1_000),
		loweringToFloor(1_150),
		floorWork(1_300),
		upright(1_450),
	];
}

function run(frames) {
	let state = initialBurpeeHsmmState();
	const reps = [];

	for (const nextFrame of frames) {
		const result = stepBurpeeHsmm(state, nextFrame);
		state = result.state;
		if (result.rep) reps.push(result.repAtMs);
	}

	return { state, reps };
}

function poseFor(phase, lowConfidenceNames = []) {
	const points = new Map(
		LANDMARK_NAMES.map((name) => [
			name,
			{
				name,
				x: 200,
				y: 200,
				score: lowConfidenceNames.includes(name) ? 0.1 : 0.9,
			},
		]),
	);
	const set = (names, leftX, rightX, y) => {
		setPoint(names[0], leftX, y);
		setPoint(names[1], rightX, y);
	};
	const setPoint = (name, x, y) =>
		points.set(name, { ...points.get(name), x, y });

	set(["left_shoulder", "right_shoulder"], 150, 250, 100);
	set(["left_hip", "right_hip"], 150, 250, 200);
	set(["left_knee", "right_knee"], 150, 250, 280);
	set(["left_ankle", "right_ankle"], 150, 250, 350);
	set(["left_wrist", "right_wrist"], 150, 250, 225);

	if (phase === "lowering") {
		set(["left_shoulder", "right_shoulder"], 150, 250, 150);
		set(["left_hip", "right_hip"], 200, 400, 190);
		set(["left_knee", "right_knee"], 200, 400, 220);
		set(["left_ankle", "right_ankle"], 150, 250, 270);
		set(["left_wrist", "right_wrist"], 150, 250, 230);
	}
	if (phase === "floor") {
		set(["left_shoulder", "right_shoulder"], 150, 250, 150);
		set(["left_hip", "right_hip"], 200, 400, 150);
		set(["left_knee", "right_knee"], 200, 400, 170);
		set(["left_ankle", "right_ankle"], 100, 300, 190);
		set(["left_wrist", "right_wrist"], 100, 300, 180);
	}
	if (phase === "returning") {
		set(["left_shoulder", "right_shoulder"], 150, 250, 150);
		set(["left_hip", "right_hip"], 210, 330, 200);
		set(["left_knee", "right_knee"], 210, 330, 210);
		set(["left_ankle", "right_ankle"], 150, 250, 220);
		set(["left_wrist", "right_wrist"], 230, 310, 210);
	}

	return { keypoints: Array.from(points.values()) };
}

function featureFrames(phases) {
	const frames = [];
	for (const [tMs, phase, lowConfidenceNames] of phases) {
		frames.push(
			featureFrameFromPose(
				poseFor(phase, lowConfidenceNames),
				tMs,
				video,
				frames.at(-1) || null,
			),
		);
	}
	return frames;
}

test("counts one observed outer cycle regardless of internal pushup count", () => {
	const frames = onePushupCycle().concat(threePushupCycle());
	const { reps } = run(frames);

	assert.deepEqual(reps, [
		onePushupCycle().at(-1).tMs,
		threePushupCycle().at(-1).tMs,
	]);
});

test("does not count a squat-only or interrupted floor sequence", () => {
	const { reps } = run(squatOnlyFrames().concat(interruptedFloorFrames()));

	assert.deepEqual(reps, []);
});

test("unusable frames leave the partial path untouched and never emit a rep", () => {
	let state = initialBurpeeHsmmState();
	for (const nextFrame of [upright(0), loweringToFloor(150), floorWork(300)]) {
		state = stepBurpeeHsmm(state, nextFrame).state;
	}

	const result = stepBurpeeHsmm(state, {
		tMs: 450,
		poseConfidence: 0.1,
		visibleFraction: 0.1,
	});

	assert.equal(result.rep, false);
	assert.equal(result.repAtMs, null);
	assert.deepEqual(result.state, state);
});

test("low-confidence required macro landmarks leave the partial path untouched", () => {
	let state = initialBurpeeHsmmState();
	for (const nextFrame of [upright(0), loweringToFloor(150)]) {
		state = stepBurpeeHsmm(state, nextFrame).state;
	}

	const result = stepBurpeeHsmm(
		state,
		frame(300, {
			...floorWork(300),
			macroLandmarkConfidence: 0.1,
		}),
	);

	assert.equal(result.rep, false);
	assert.deepEqual(result.state, state);
});

test("featureFrameFromPose output drives one complete macro cycle", () => {
	const { reps } = run(
		featureFrames([
			[0, "upright"],
			[150, "lowering"],
			[300, "floor"],
			[450, "returning"],
			[600, "upright"],
		]),
	);

	assert.deepEqual(reps, [600]);
});

test("low-confidence wrists and ankles in extracted features cannot advance a macro cycle", () => {
	const lowConfidenceExtremities = [
		"left_wrist",
		"right_wrist",
		"left_ankle",
		"right_ankle",
	];
	const { reps } = run(
		featureFrames([
			[0, "upright"],
			[150, "lowering", lowConfidenceExtremities],
			[300, "floor"],
			[450, "returning"],
			[600, "upright"],
		]),
	);

	assert.deepEqual(reps, []);
});

test("an overlong partial path expires without emitting a rep", () => {
	let state = initialBurpeeHsmmState();
	for (const nextFrame of [upright(0), loweringToFloor(150), floorWork(300)]) {
		state = stepBurpeeHsmm(state, nextFrame).state;
	}

	const result = stepBurpeeHsmm(state, upright(20_000));
	assert.equal(result.rep, false);
	assert.equal(result.state.phase, "upright");
});
