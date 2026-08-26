import assert from "node:assert/strict";
import test from "node:test";

import { initialBurpeeHsmmState, stepBurpeeHsmm } from "./pose_burpee_hsmm.mjs";
import { featureFrameFromPose } from "./pose_features.mjs";
import { userLabeledRepFeatureFrames } from "./pose_burpee_hsmm_user_labeled_fixture.mjs";

const video = { videoWidth: 400, videoHeight: 400 };

const WORLD_PHASES = Object.freeze({
	upright: { body: 3.2, hip: 2.35, torso: 0.85, wrist: 1.5 },
	lowering: { body: 2.1, hip: 1.65, torso: 0.45, wrist: 0.7 },
	floor: { body: 1.05, hip: 0.7, torso: 0.35, wrist: 0.45 },
	floor_pushup: { body: 1.05, hip: 0.7, torso: 0.35, wrist: 0.45 },
	returning: { body: 1.65, hip: 1.1, torso: 0.55, wrist: 0.8 },
	squat: { body: 3, hip: 2.1, torso: 0.9, wrist: 1.4 },
});

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

function lowFrontFeatureFrames(phases, options = {}) {
	const frames = [];
	for (const [phase, tMs, poseOptions] of phases) {
		frames.push(
			featureFrameFromPose(
				lowFrontPose(phase, { ...options, ...poseOptions }),
				tMs,
				video,
				frames.at(-1) || null,
			),
		);
	}
	return frames;
}

function lowFrontFrame(phase, tMs, overrides = {}) {
	const frames = lowFrontFeatureFrames([
		["upright", tMs - 150],
		[phase, tMs],
	]);
	return { ...frames.at(-1), ...overrides };
}

function lowFrontCycle(startMs = 0) {
	return [
		["upright", startMs],
		["lowering", startMs + 150],
		["floor", startMs + 300],
		["floor_pushup", startMs + 450],
		["returning", startMs + 750],
		["upright", startMs + 900],
	];
}

function lowFrontPose(phase, options = {}) {
	const geometry = WORLD_PHASES[phase];
	if (!geometry) throw new Error(`unknown low-front phase: ${phase}`);

	const imageScale = options.foreshortenImage ? 0.08 : 1;
	const imageY = (y) => 80 + (y - 80) * imageScale;
	const score = (name) =>
		options.lowConfidenceNames?.includes(name) ? 0.1 : 0.9;
	const point = (name, x, y, world) => ({
		name,
		x,
		y,
		score: score(name),
		...(options.missingWorldNames?.includes(name) ? {} : { world }),
	});
	const shoulderY = 0;
	const shoulderCenterX = Math.sqrt(1 - geometry.torso ** 2);
	const hipY = -geometry.torso;
	const ankleY = -geometry.body;
	const wristY = ankleY + geometry.wrist;
	const image = {
		shoulder: imageY(90),
		hip: imageY(170),
		knee: imageY(250),
		ankle: imageY(340),
		wrist: imageY(220),
	};

	return {
		keypoints: [
			point("nose", 200, imageY(50), { x: 0, y: 0.3, z: 0 }),
			point("left_shoulder", 150, image.shoulder, {
				x: shoulderCenterX - 0.5,
				y: shoulderY,
				z: 0,
			}),
			point("right_shoulder", 250, image.shoulder, {
				x: shoulderCenterX + 0.5,
				y: shoulderY,
				z: 0,
			}),
			point("left_elbow", 135, imageY(155), {
				x: shoulderCenterX - 0.65,
				y: (shoulderY + wristY) / 2,
				z: 0,
			}),
			point("right_elbow", 265, imageY(155), {
				x: shoulderCenterX + 0.65,
				y: (shoulderY + wristY) / 2,
				z: 0,
			}),
			point("left_wrist", 125, image.wrist, { x: -0.7, y: wristY, z: 0 }),
			point("right_wrist", 275, image.wrist, { x: 0.7, y: wristY, z: 0 }),
			point("left_hip", 160, image.hip, { x: -0.4, y: hipY, z: 0 }),
			point("right_hip", 240, image.hip, { x: 0.4, y: hipY, z: 0 }),
			point("left_knee", 165, image.knee, {
				x: -0.4,
				y: (hipY + ankleY) / 2,
				z: 0,
			}),
			point("right_knee", 235, image.knee, {
				x: 0.4,
				y: (hipY + ankleY) / 2,
				z: 0,
			}),
			point("left_ankle", 170, image.ankle, { x: -0.4, y: ankleY, z: 0 }),
			point("right_ankle", 230, image.ankle, { x: 0.4, y: ankleY, z: 0 }),
			point("left_foot_index", 165, imageY(350), {
				x: -0.45,
				y: ankleY,
				z: 0.15,
			}),
			point("right_foot_index", 235, imageY(350), {
				x: 0.45,
				y: ankleY,
				z: 0.15,
			}),
		],
	};
}

test("counts one low-front observed cycle with one or three floor pushups", () => {
	const frames = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
		["floor", 300],
		["floor_pushup", 450],
		["returning", 750],
		["upright", 900],
		["upright", 2500],
		["lowering", 2650],
		["floor", 2800],
		["floor_pushup", 2950],
		["floor", 3100],
		["floor_pushup", 3250],
		["floor", 3400],
		["returning", 3550],
		["upright", 3700],
	]);

	assert.deepEqual(run(frames).reps, [900, 3700]);
});

test("counts the two user-labeled reps from their derived macro features", () => {
	assert.deepEqual(run(userLabeledRepFeatureFrames).reps, [7_080, 31_076]);
});

test("foreshortened image coordinates do not change world-based phase results", () => {
	assert.deepEqual(
		run(lowFrontFeatureFrames(lowFrontCycle(), { foreshortenImage: true }))
			.reps,
		[900],
	);
});

test("advances only when weighted low-front evidence clears the forward threshold", () => {
	const result = stepBurpeeHsmm(
		{ ...initialBurpeeHsmmState(), phase: "upright", phaseStartedAtMs: 0 },
		lowFrontFrame("lowering", 150, { worldWristVerticalSpan: 1.8 }),
	);

	assert.equal(result.state.phase, "lowering_to_floor");
});

test("a qualifying velocity spike cannot return from floor below the body-span minimum", () => {
	const result = stepBurpeeHsmm(
		{
			...initialBurpeeHsmmState(),
			phase: "floor_work",
			phaseStartedAtMs: 0,
		},
		lowFrontFrame("returning", 150, {
			worldBodyVerticalSpan: 1.05,
			worldHipVerticalSpan: 1.1,
			worldTorsoElevation: 0.55,
			dWorldBodyVerticalSpan: 0.8,
		}),
	);

	assert.equal(result.state.phase, "floor_work");
});

test("does not count a squat-only or interrupted floor sequence", () => {
	const frames = lowFrontFeatureFrames([
		["upright", 0],
		["squat", 150],
		["upright", 300],
		["upright", 1000],
		["lowering", 1150],
		["floor", 1300],
		["upright", 1450],
	]);

	assert.deepEqual(run(frames).reps, []);
});

test("a slow valid return completes only when upright evidence reaches the return threshold", () => {
	const prefix = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
		["floor", 300],
		["returning", 450],
	]);
	const slowUpright = lowFrontFrame("upright", 7_232, {
		worldBodyVerticalSpan: 2.6805,
		worldHipVerticalSpan: 1.6902,
		worldTorsoElevation: 0.9902,
		worldWristVerticalSpan: 1.7297,
	});

	assert.deepEqual(run(prefix.concat(slowUpright)).reps, [7_232]);
});

test("a slow return below the return-to-upright threshold does not count", () => {
	const prefix = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
		["floor", 300],
		["returning", 450],
	]);
	const weakUpright = lowFrontFrame("upright", 7_232, {
		worldBodyVerticalSpan: 2.55,
		worldHipVerticalSpan: 1.6,
		worldTorsoElevation: 0.99,
		worldWristVerticalSpan: 1.72,
	});

	assert.deepEqual(run(prefix.concat(weakUpright)).reps, []);
});

test("an unusable frame abandons a partial path before a fresh cycle", () => {
	const frames = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
		["floor", 300],
		["floor_pushup", 450],
		["returning", 600],
		["upright", 750],
		...lowFrontCycle(1_000),
	]);
	frames[3] = { ...frames[3], poseConfidence: 0.1, visibleFraction: 0.1 };

	assert.deepEqual(run(frames).reps, [1_900]);
});

test("a strong out-of-order observation abandons a partial path before a fresh cycle", () => {
	const frames = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
		["upright", 300],
		["floor", 450],
		["returning", 600],
		["upright", 750],
		...lowFrontCycle(1_000),
	]);

	assert.deepEqual(run(frames).reps, [1_900]);
});

test("missing knee or foot world landmarks reset the partial path", () => {
	for (const missingWorldName of ["left_knee", "right_foot_index"]) {
		let state = initialBurpeeHsmmState();
		for (const nextFrame of lowFrontFeatureFrames([
			["upright", 0],
			["lowering", 150],
		])) {
			state = stepBurpeeHsmm(state, nextFrame).state;
		}

		const [floor] = lowFrontFeatureFrames([
			["floor", 300, { missingWorldNames: [missingWorldName] }],
		]);
		const result = stepBurpeeHsmm(state, floor);

		assert.equal(result.rep, false);
		assert.deepEqual(
			result.state,
			{ ...state, phase: "upright", phaseStartedAtMs: null },
			`${missingWorldName} world point must reset the HSMM candidate`,
		);
	}
});

test("low-confidence required macro landmarks reset the partial path", () => {
	let state = initialBurpeeHsmmState();
	for (const nextFrame of lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150],
	])) {
		state = stepBurpeeHsmm(state, nextFrame).state;
	}

	const [lowConfidenceFloor] = lowFrontFeatureFrames([
		[
			"floor",
			300,
			{
				lowConfidenceNames: [
					"left_wrist",
					"right_wrist",
					"left_ankle",
					"right_ankle",
				],
			},
		],
	]);
	const result = stepBurpeeHsmm(state, lowConfidenceFloor);

	assert.equal(result.rep, false);
	assert.deepEqual(result.state, {
		...state,
		phase: "upright",
		phaseStartedAtMs: null,
	});
});

test("raw low-front feature output drives one complete macro cycle", () => {
	assert.deepEqual(run(lowFrontFeatureFrames(lowFrontCycle())).reps, [900]);
});

test("low-confidence wrists and ankles in raw low-front features cannot advance a macro cycle", () => {
	const lowConfidenceExtremities = [
		"left_wrist",
		"right_wrist",
		"left_ankle",
		"right_ankle",
	];
	const frames = lowFrontFeatureFrames([
		["upright", 0],
		["lowering", 150, { lowConfidenceNames: lowConfidenceExtremities }],
		["floor", 300],
		["returning", 450],
		["upright", 600],
	]);

	assert.deepEqual(run(frames).reps, []);
});

test("low-confidence nose or feet in raw low-front features cannot complete a macro cycle", () => {
	for (const name of ["nose", "right_foot_index"]) {
		const frames = lowFrontFeatureFrames(lowFrontCycle(), {
			lowConfidenceNames: [name],
		});

		assert.deepEqual(
			run(frames).reps,
			[],
			`${name} must make every frame absent`,
		);
	}
});
