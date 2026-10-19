import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";

import { initialBurpeeHsmmState, stepBurpeeHsmm } from "./pose_burpee_hsmm.mjs";
import { featureFrameFromPose } from "./pose_features.mjs";

// Every pose sample the camera recorded in a real 20-minute six-count session, in order.
const sessions = [
	// Steady: 140 reps logged, every set on time.
	{
		file: "pose_burpee_session_140_reps.json.gz",
		reps: 140,
		kind: "a steady session",
	},
	// Messy: 150 planned, slipped from the middle, with a pause of about 2.5 minutes. The
	// athlete logged 131 by hand and thinks 135 is right.
	{
		file: "pose_burpee_session_135_reps.json.gz",
		reps: 135,
		kind: "a session that slipped",
	},
];

// World geometry the HSMM reads; stored keypoints are rounded to 4 decimals.
const WORLD_FEATURES = [
	"worldBodyVerticalSpan",
	"worldHipVerticalSpan",
	"worldTorsoElevation",
	"worldWristVerticalSpan",
];
const ROUNDING = 0.002;

function load(file) {
	return JSON.parse(
		gunzipSync(readFileSync(new URL(`./fixtures/${file}`, import.meta.url))),
	).samples;
}

function count(frames) {
	let state = initialBurpeeHsmmState();
	for (const frame of frames) state = stepBurpeeHsmm(state, frame).state;
	return state.cadenceMs.length;
}

// The detector's pose, rebuilt from a recorded sample's keypoints. Image coordinates were
// stored as fractions of the frame, so a 1x1 video keeps them as they are.
function poseFrom(keypoints) {
	return {
		keypoints: Object.entries(keypoints).map(([name, point]) => ({
			name,
			x: point.x,
			y: point.y,
			z: point.z,
			score: point.score,
			visibility: point.visibility,
			world:
				point.world_x == null
					? undefined
					: {
							x: point.world_x,
							y: point.world_y,
							z: point.world_z,
							visibility: point.world_visibility,
						},
		})),
	};
}

for (const { file, reps, kind } of sessions) {
	test(`${kind} counts exactly its ${reps} reps`, () => {
		assert.equal(count(load(file).map((sample) => sample.features)), reps);
	});

	// Velocities are not compared: unusable frames were never recorded, so a recorded
	// frame's previous frame is often missing.
	test(`${kind}: features rebuilt from its keypoints match and still count ${reps}`, () => {
		const video = { videoWidth: 1, videoHeight: 1 };
		let previous = null;

		const frames = load(file).map((sample) => {
			const frame = featureFrameFromPose(
				poseFrom(sample.keypoints),
				sample.tMs,
				video,
				previous,
			);
			previous = frame;

			assert.equal(
				frame.hasFullWorldLandmarkCoverage,
				sample.features.hasFullWorldLandmarkCoverage,
			);
			for (const name of WORLD_FEATURES) {
				assert.ok(
					Math.abs(frame[name] - sample.features[name]) <= ROUNDING,
					`${name} at ${sample.tMs} ms: ${frame[name]} vs ${sample.features[name]}`,
				);
			}

			// Confidences come from the image plane, which was stored rounded; keep the recorded ones.
			return {
				...sample.features,
				...frame,
				poseConfidence: sample.features.poseConfidence,
				confidence: sample.features.confidence,
				macroLandmarkConfidence: sample.features.macroLandmarkConfidence,
				visibleFraction: sample.features.visibleFraction,
			};
		});

		assert.equal(count(frames), reps);
	});
}
