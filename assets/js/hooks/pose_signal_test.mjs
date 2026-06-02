import test from "node:test";
import assert from "node:assert/strict";
import { sampleFromPose } from "./pose_signal.mjs";

const video = { videoWidth: 300, videoHeight: 600 };

function pose({
	shoulderY,
	hipY,
	shoulderX = [120, 180],
	hipX = [130, 170],
	extraKeypoints = [],
}) {
	return {
		keypoints: [
			{ name: "left_shoulder", x: shoulderX[0], y: shoulderY, score: 0.9 },
			{ name: "right_shoulder", x: shoulderX[1], y: shoulderY, score: 0.9 },
			{ name: "left_hip", x: hipX[0], y: hipY, score: 0.9 },
			{ name: "right_hip", x: hipX[1], y: hipY, score: 0.9 },
			...extraKeypoints,
		],
	};
}

test("closer/larger body lowers uprightness signal even when vertical center is similar", () => {
	const farUp = sampleFromPose(
		pose({
			shoulderY: 250,
			hipY: 350,
			shoulderX: [135, 165],
			hipX: [140, 160],
		}),
		0,
		video,
	);
	const closeDown = sampleFromPose(
		pose({ shoulderY: 200, hipY: 400, shoulderX: [80, 220], hipX: [95, 205] }),
		1000,
		video,
	);

	assert.ok(farUp.signal > closeDown.signal);
});

test("trace sample preserves every BlazePose landmark", () => {
	const allKeypoints = Array.from({ length: 33 }, (_, index) => ({
		name: `landmark_${index}`,
		x: index,
		y: index * 2,
		z: -index / 10,
		score: 0.9,
		visibility: 0.8,
		presence: 0.7,
		world: { x: index + 1, y: index + 2, z: index + 3, visibility: 0.6 },
	}));
	allKeypoints[0].name = "nose";
	allKeypoints[15].name = "left_wrist";
	allKeypoints[31].name = "left_foot_index";

	const sample = sampleFromPose(
		{ keypoints: allKeypoints, model: "blazepose-full" },
		1000,
		video,
	);

	assert.equal(Object.keys(sample.keypoints).length, 33);
	assert.deepEqual(sample.keypoints.left_wrist, {
		x: 0.05,
		y: 0.05,
		z: -1.5,
		score: 0.9,
		visibility: 0.8,
		presence: 0.7,
		world_x: 16,
		world_y: 17,
		world_z: 18,
		world_visibility: 0.6,
	});
	assert.deepEqual(sample.keypoints.left_foot_index.world_z, 34);
	assert.equal(sample.model, "blazepose-full");
});

test("full-body keypoints contribute to closeness when visible", () => {
	const torsoOnly = sampleFromPose(
		pose({ shoulderY: 180, hipY: 320 }),
		0,
		video,
	);
	const fullBody = sampleFromPose(
		pose({
			shoulderY: 180,
			hipY: 320,
			extraKeypoints: [
				{ name: "nose", x: 150, y: 80, score: 0.9 },
				{ name: "left_knee", x: 105, y: 430, score: 0.9 },
				{ name: "right_knee", x: 195, y: 430, score: 0.9 },
				{ name: "left_ankle", x: 85, y: 560, score: 0.9 },
				{ name: "right_ankle", x: 215, y: 560, score: 0.9 },
			],
		}),
		1000,
		video,
	);

	assert.ok(fullBody.closeness > torsoOnly.closeness);
});
