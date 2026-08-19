import assert from "node:assert/strict";
import test from "node:test";

import { featureFrameFromPose } from "./pose_features.mjs";

const video = { videoWidth: 200, videoHeight: 200 };

function point(name, x, y, world = null) {
	return { name, x, y, score: 0.9, ...(world && { world }) };
}

function lowFrontPose(position, missing = []) {
	const worlds = {
		upright: {
			left_shoulder: [-0.5, 0, 0],
			right_shoulder: [0.5, 0, 0],
			left_elbow: [-0.65, -0.4, 0],
			right_elbow: [0.65, -0.4, 0],
			left_wrist: [-0.7, -0.8, 0],
			right_wrist: [0.7, -0.8, 0],
			left_hip: [-0.4, -1, 0],
			right_hip: [0.4, -1, 0],
			left_knee: [-0.4, -2.25, 0],
			right_knee: [0.4, -2.25, 0],
			left_ankle: [-0.4, -3.5, 0],
			right_ankle: [0.4, -3.5, 0],
		},
		lowering: {
			left_shoulder: [-0.5, 0, 0],
			right_shoulder: [0.5, 0, 0],
			left_elbow: [-0.65, -1, 0],
			right_elbow: [0.65, -1, 0],
			left_wrist: [-0.7, -1.75, 0],
			right_wrist: [0.7, -1.75, 0],
			left_hip: [-0.4, -1, 0],
			right_hip: [0.4, -1, 0],
			left_knee: [-0.4, -2, 0],
			right_knee: [0.4, -2, 0],
			left_ankle: [-0.4, -3, 0],
			right_ankle: [0.4, -3, 0],
		},
		floor: {
			left_shoulder: [-0.5, 0, 0],
			right_shoulder: [0.5, 0, 0],
			left_elbow: [-0.65, -0.1, 0],
			right_elbow: [0.65, -0.1, 0],
			left_wrist: [-0.7, -0.2, 0],
			right_wrist: [0.7, -0.2, 0],
			left_hip: [-0.4, -0.1, 0],
			right_hip: [0.4, -0.1, 0],
			left_knee: [-0.4, -0.2, 0],
			right_knee: [0.4, -0.2, 0],
			left_ankle: [-0.4, -0.25, 0],
			right_ankle: [0.4, -0.25, 0],
		},
	}[position];
	const imagePoints = {
		left_shoulder: [88, 88],
		right_shoulder: [112, 88],
		left_elbow: [84, 104],
		right_elbow: [116, 104],
		left_wrist: [82, 120],
		right_wrist: [118, 120],
		left_hip: [90, 116],
		right_hip: [110, 116],
		left_knee: [91, 145],
		right_knee: [109, 145],
		left_ankle: [92, 174],
		right_ankle: [108, 174],
	};

	return {
		keypoints: [
			point("nose", 100, 62, { x: 0, y: 0.4, z: 0 }),
			...Object.entries(imagePoints).map(([name, [x, y]]) =>
				point(
					name,
					x,
					y,
					missing.includes(name)
						? null
						: { x: worlds[name][0], y: worlds[name][1], z: worlds[name][2] },
				),
			),
		],
	};
}

function pose(offset = 0) {
	return {
		keypoints: [
			point("nose", 100, 20),
			point("left_shoulder", 80, 60),
			point("right_shoulder", 120, 60),
			point("left_elbow", 75, 85),
			point("right_elbow", 125, 85),
			point("left_wrist", 70, 110 + offset),
			point("right_wrist", 130, 110 + offset),
			point("left_hip", 85, 110),
			point("right_hip", 115, 110),
			point("left_knee", 85, 145),
			point("right_knee", 115, 145),
			point("left_ankle", 85, 180),
			point("right_ankle", 115, 180),
		],
	};
}

test("derives body-scale-normalized world geometry without camera coordinates", () => {
	const previous = featureFrameFromPose(lowFrontPose("upright"), 0, video);
	const frame = featureFrameFromPose(
		lowFrontPose("lowering"),
		100,
		video,
		previous,
	);

	assert.equal(frame.worldBodyVerticalSpan, 3);
	assert.equal(frame.worldHipVerticalSpan, 2);
	assert.equal(frame.worldWristVerticalSpan, 1.25);
	assert.equal(frame.worldTorsoElevation, 1);
	assert.equal(frame.dWorldBodyVerticalSpan, -5);
});

test("omits world macro features when a required landmark has no world point", () => {
	const frame = featureFrameFromPose(
		lowFrontPose("floor", ["left_wrist"]),
		0,
		video,
	);

	assert.equal(frame.worldWristVerticalSpan, null);
	assert.equal(frame.worldBodyVerticalSpan, 0.25);
});

test("omits all world macro features when a pose has no world points", () => {
	const frame = featureFrameFromPose(pose(), 0, video);

	assert.equal(frame.worldBodyVerticalSpan, null);
	assert.equal(frame.worldHipVerticalSpan, null);
	assert.equal(frame.worldWristVerticalSpan, null);
	assert.equal(frame.worldTorsoElevation, null);
	assert.equal(frame.worldBodyScale, null);
});

test("adds body-relative macro geometry and velocities while retaining landmarks", () => {
	const previous = featureFrameFromPose(pose(), 0, video);
	const features = featureFrameFromPose(pose(10), 100, video, previous);

	assert.equal(features.normalizedLandmarks.left_wrist.x, -0.6);
	assert.equal(features.wristToAnkle, 1.2);
	assert.equal(features.shoulderToAnkle, 2.4);
	assert.equal(features.torsoUprightness, 1);
	assert.equal(features.hipToKnee, 0.7);
	assert.equal(features.macroLandmarkConfidence, 0.9);
	assert.equal(features.dWristToAnkle, -2);
	assert.equal(features.dShoulderToAnkle, 0);
});
