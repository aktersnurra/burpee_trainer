import assert from "node:assert/strict";
import test from "node:test";

import { featureFrameFromPose } from "./pose_features.mjs";

const video = { videoWidth: 200, videoHeight: 200 };

function point(name, x, y) {
	return { name, x, y, score: 0.9 };
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
