import test from "node:test";
import assert from "node:assert/strict";
import {
	keypointsFromPoseLandmarks,
	poseFromBlazePoseResults,
} from "./blazepose_detector.mjs";

test("converts BlazePose landmarks to named pixel keypoints", () => {
	const landmarks = Array.from({ length: 33 }, (_, index) => ({
		x: index / 100,
		y: index / 200,
		z: -index / 300,
		visibility: 0.9,
		presence: 0.8,
	}));

	const keypoints = keypointsFromPoseLandmarks(landmarks, {
		videoWidth: 640,
		videoHeight: 480,
	});

	const nose = keypoints.find((point) => point.name === "nose");
	const leftShoulder = keypoints.find(
		(point) => point.name === "left_shoulder",
	);
	const leftAnkle = keypoints.find((point) => point.name === "left_ankle");

	assert.deepEqual(nose, {
		name: "nose",
		x: 0,
		y: 0,
		z: 0,
		score: 0.9,
		visibility: 0.9,
		presence: 0.8,
	});
	assert.deepEqual(leftShoulder, {
		name: "left_shoulder",
		x: 70.4,
		y: 26.4,
		z: -0.0367,
		score: 0.9,
		visibility: 0.9,
		presence: 0.8,
	});
	assert.deepEqual(leftAnkle, {
		name: "left_ankle",
		x: 172.8,
		y: 64.8,
		z: -0.09,
		score: 0.9,
		visibility: 0.9,
		presence: 0.8,
	});
	assert.equal(keypoints.length, 33);
});

test("preserves BlazePose world landmarks and metadata on poses", () => {
	const landmarks = Array.from({ length: 33 }, (_, index) => ({
		x: index / 100,
		y: index / 200,
		z: -index / 300,
		visibility: 0.9,
	}));
	const worldLandmarks = Array.from({ length: 33 }, (_, index) => ({
		x: index,
		y: index + 1,
		z: index + 2,
		visibility: 0.7,
	}));

	const pose = poseFromBlazePoseResults(
		{ poseLandmarks: landmarks, poseWorldLandmarks: worldLandmarks },
		{ videoWidth: 640, videoHeight: 480 },
	);

	assert.equal(pose.model, "blazepose-full");
	assert.equal(pose.keypoints.length, 33);
	assert.deepEqual(pose.keypoints[15].world, {
		x: 15,
		y: 16,
		z: 17,
		visibility: 0.7,
	});
});
