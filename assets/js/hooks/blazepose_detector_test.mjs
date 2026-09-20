import test from "node:test";
import assert from "node:assert/strict";
import {
	keypointsFromPoseLandmarks,
	poseFromBlazePoseResults,
} from "./blazepose_detector.mjs";

const video = { videoWidth: 640, videoHeight: 480 };

test("landmarks are scaled to video pixels and named in BlazePose order", () => {
	const keypoints = keypointsFromPoseLandmarks(
		[
			{ x: 0.5, y: 0.25, z: -0.125, visibility: 0.9 },
			{ x: 0, y: 1, z: 0.5, visibility: 0.1 },
		],
		video,
	);

	assert.equal(keypoints[0].name, "nose");
	assert.equal(keypoints[0].x, 320);
	assert.equal(keypoints[0].y, 120);
	assert.equal(keypoints[0].z, -0.125);
	assert.equal(keypoints[1].name, "left_eye_inner");
	assert.equal(keypoints[1].x, 0);
	assert.equal(keypoints[1].y, 480);
});

test("score prefers visibility and retains visibility and presence", () => {
	const [withVisibility, withPresence, withNeither] =
		keypointsFromPoseLandmarks(
			[
				{ x: 0, y: 0, visibility: 0.8 },
				{ x: 0, y: 0, presence: 0.6 },
				{ x: 0, y: 0 },
			],
			video,
		);

	assert.equal(withVisibility.score, 0.8);
	assert.equal(withVisibility.visibility, 0.8);
	assert.equal(withPresence.score, 0.6);
	assert.equal(withPresence.presence, 0.6);
	assert.equal(withNeither.score, 0);
	assert.equal(withNeither.visibility, undefined);
	assert.equal(withNeither.presence, undefined);
});

test("world landmarks are attached unscaled for metric features", () => {
	const [keypoint] = keypointsFromPoseLandmarks(
		[{ x: 0.5, y: 0.5, visibility: 0.9 }],
		video,
		[{ x: 0.11, y: -0.22, z: 0.33, visibility: 0.7 }],
	);

	assert.deepEqual(keypoint.world, {
		x: 0.11,
		y: -0.22,
		z: 0.33,
		visibility: 0.7,
	});
});

test("missing world landmarks leave the keypoint without world geometry", () => {
	const [keypoint] = keypointsFromPoseLandmarks(
		[{ x: 0.5, y: 0.5, visibility: 0.9 }],
		video,
	);

	assert.equal(keypoint.world, undefined);
});

test("a pose result carries the model tag the features record", () => {
	const pose = poseFromBlazePoseResults(
		{ poseLandmarks: [{ x: 0.5, y: 0.5, visibility: 0.9 }] },
		video,
	);

	assert.equal(pose.model, "blazepose-full");
	assert.equal(pose.keypoints.length, 1);
});
