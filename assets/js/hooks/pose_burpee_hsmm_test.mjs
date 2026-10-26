import assert from "node:assert/strict";
import test from "node:test";

import {
	flushBurpeeHsmm,
	initialBurpeeHsmmState,
	stepBurpeeHsmm,
	usableBurpeeHsmmFrame,
} from "./pose_burpee_hsmm.mjs";
import { featureFrameFromPose } from "./pose_features.mjs";

const video = { videoWidth: 400, videoHeight: 400 };
const FRAME_MS = 83;

// Typical world features of each phase in the recorded sessions.
const PHASE_FEATURES = Object.freeze({
	standing: { body: 2.75, hip: 1.78, torso: 0.96, wrist: 1.87, dBody: 0, dWrist: 0 },
	lowering: { body: 1.9, hip: 1.62, torso: 0.4, wrist: 0.88, dBody: -3, dWrist: -3.3 },
	pushup: { body: 0.93, hip: 0.94, torso: 0.2, wrist: 0.23, dBody: 0, dWrist: 0.2 },
	rising: { body: 2.15, hip: 1.56, torso: 0.59, wrist: 1.1, dBody: 3.2, dWrist: 3.9 },
	// Bent over with an upright torso during a rest, as in the recordings.
	bend: { body: 2.0, hip: 1.7, torso: 0.85, wrist: 1.4, dBody: -0.4, dWrist: -0.3 },
});

function macroFrame(phase, tMs) {
	const geometry = PHASE_FEATURES[phase];
	return {
		tMs,
		hasFullWorldLandmarkCoverage: true,
		poseConfidence: 0.9,
		macroLandmarkConfidence: 0.9,
		visibleFraction: 0.9,
		worldBodyVerticalSpan: geometry.body,
		worldHipVerticalSpan: geometry.hip,
		worldTorsoElevation: geometry.torso,
		worldWristVerticalSpan: geometry.wrist,
		dWorldBodyVerticalSpan: geometry.dBody,
		dWorldWristVerticalSpan: geometry.dWrist,
	};
}

// [phase, durationMs] segments sampled every frameMs; "absent" segments are unusable frames.
function frames(segments, { startMs = 0, frameMs = FRAME_MS } = {}) {
	const out = [];
	let segmentStart = startMs;
	for (const [phase, durationMs] of segments) {
		for (let tMs = segmentStart; tMs < segmentStart + durationMs; tMs += frameMs) {
			out.push(phase === "absent" ? { tMs: Math.round(tMs) } : macroFrame(phase, Math.round(tMs)));
		}
		segmentStart += durationMs;
	}
	return out;
}

const CYCLE = Object.freeze([
	["lowering", 400],
	["pushup", 800],
	["rising", 400],
	["standing", 3_400],
]);

function run(input) {
	let state = initialBurpeeHsmmState();
	const reps = [];
	for (const frame of input) {
		const result = stepBurpeeHsmm(state, frame);
		state = result.state;
		reps.push(...result.reps);
	}
	const flushed = flushBurpeeHsmm(state);
	return { reps: reps.concat(flushed.reps), state: flushed.state };
}

test("counts each clean cycle once, when it is back to standing", () => {
	const { reps } = run(frames([["standing", 2_000], ...CYCLE, ...CYCLE, ...CYCLE]));

	assert.equal(reps.length, 3);
	// The return to standing begins at 3.6 s, 8.6 s and 13.6 s.
	[3_600, 8_600, 13_600].forEach((expected, index) =>
		assert.ok(Math.abs(reps[index] - expected) <= 200, `rep ${index} at ${reps[index]}`),
	);
});

test("several pushups on the floor are one rep", () => {
	const { reps } = run(
		frames([["standing", 2_000], ["lowering", 400], ["pushup", 6_000], ["rising", 400], ["standing", 2_000]]),
	);

	assert.equal(reps.length, 1);
});

test("a rep is decided after the lag and dated when it happened", () => {
	let state = initialBurpeeHsmmState();
	const emitted = [];
	for (const frame of frames([["standing", 2_000], ...CYCLE])) {
		const result = stepBurpeeHsmm(state, frame);
		state = result.state;
		for (const repMs of result.reps) emitted.push({ repMs, atMs: frame.tMs });
	}

	assert.equal(emitted.length, 1);
	const lagMs = emitted[0].atMs - emitted[0].repMs;
	assert.ok(lagMs >= 600 && lagMs <= 800, `lag ${lagMs}`);
	assert.deepEqual(flushBurpeeHsmm(state).reps, []);
});

test("no rep is counted until the return to standing is seen", () => {
	const { reps } = run(
		frames([["standing", 2_000], ["lowering", 400], ["pushup", 800], ["rising", 400], ["absent", 3_000]]),
	);

	assert.deepEqual(reps, []);
});

test("a long dropout while standing counts nothing", () => {
	const { reps } = run(frames([["standing", 2_000], ["absent", 8_000], ["standing", 2_000]]));

	assert.deepEqual(reps, []);
});

test("a pushup out of sight for 12 s counts once it is seen rising and standing", () => {
	const { reps } = run(
		frames([
			["standing", 2_000],
			["lowering", 400],
			["pushup", 300],
			["absent", 12_000],
			["pushup", 300],
			["rising", 400],
			["standing", 2_000],
		]),
	);

	assert.equal(reps.length, 1);
});

test("a short dropout while lowering still counts the rep", () => {
	const { reps } = run(
		frames([
			["standing", 2_000],
			["lowering", 170],
			["absent", 250],
			["pushup", 800],
			["rising", 400],
			["standing", 2_000],
		]),
	);

	assert.equal(reps.length, 1);
});

test("bending over during a rest is not a rep", () => {
	const { reps } = run(
		frames([["standing", 2_000], ["bend", 1_500], ["standing", 1_000], ["bend", 800], ["standing", 2_000]]),
	);

	assert.deepEqual(reps, []);
});

test("half the frame rate counts the same reps", () => {
	const segments = [["standing", 2_000], ...CYCLE, ...CYCLE, ...CYCLE, ...CYCLE];

	assert.equal(run(frames(segments, { frameMs: FRAME_MS * 2 })).reps.length, 4);
	assert.equal(run(frames(segments)).reps.length, 4);
});

const WORLD_PHASES = Object.freeze({
	upright: { body: 3.2, hip: 2.35, torso: 0.85, wrist: 1.5 },
	lowering: { body: 2.1, hip: 1.65, torso: 0.45, wrist: 0.7 },
	floor: { body: 1.05, hip: 0.7, torso: 0.35, wrist: 0.45 },
	floor_pushup: { body: 1.05, hip: 0.7, torso: 0.35, wrist: 0.45 },
	returning: { body: 1.65, hip: 1.1, torso: 0.55, wrist: 0.8 },
	squat: { body: 3, hip: 2.1, torso: 0.9, wrist: 1.4 },
});

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

test("raw low-front frames with full world landmarks are usable once they have a velocity", () => {
	const [first, ...rest] = lowFrontFeatureFrames(lowFrontCycle());

	assert.equal(usableBurpeeHsmmFrame(first), false);
	assert.ok(rest.every(usableBurpeeHsmmFrame));
});

test("a missing knee or foot world landmark makes a frame unusable", () => {
	for (const missingWorldName of ["left_knee", "right_foot_index"]) {
		const [frame] = lowFrontFeatureFrames([
			["floor", 300, { missingWorldNames: [missingWorldName] }],
		]);

		assert.equal(usableBurpeeHsmmFrame(frame), false, missingWorldName);
	}
});

test("low-confidence wrists, ankles, nose or feet make a frame unusable", () => {
	for (const names of [
		["left_wrist", "right_wrist", "left_ankle", "right_ankle"],
		["nose"],
		["right_foot_index"],
	]) {
		const [frame] = lowFrontFeatureFrames([["lowering", 150, { lowConfidenceNames: names }]]);

		assert.equal(usableBurpeeHsmmFrame(frame), false, names.join(", "));
	}
});
