import assert from "node:assert/strict";
import test from "node:test";

import {
	initialBurpeeHsmmState,
	stepBurpeeHsmm,
} from "./pose_burpee_hsmm.mjs";

function frame(tMs, features) {
	return {
		tMs,
		poseConfidence: 0.9,
		visibleFraction: 0.9,
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

test("counts one observed outer cycle regardless of internal pushup count", () => {
	const frames = onePushupCycle().concat(threePushupCycle());
	const { reps } = run(frames);

	assert.deepEqual(reps, [onePushupCycle().at(-1).tMs, threePushupCycle().at(-1).tMs]);
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

test("an overlong partial path expires without emitting a rep", () => {
	let state = initialBurpeeHsmmState();
	for (const nextFrame of [upright(0), loweringToFloor(150), floorWork(300)]) {
		state = stepBurpeeHsmm(state, nextFrame).state;
	}

	const result = stepBurpeeHsmm(state, upright(20_000));
	assert.equal(result.rep, false);
	assert.equal(result.state.phase, "upright");
});
