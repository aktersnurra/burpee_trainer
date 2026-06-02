import test from "node:test";
import assert from "node:assert/strict";
import { keypointsFromPoseLandmarks } from "./blazepose_detector.mjs";

test("converts BlazePose landmarks to named pixel keypoints", () => {
	const landmarks = Array.from({ length: 33 }, (_, index) => ({
		x: index / 100,
		y: index / 200,
		visibility: 0.9,
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

	assert.deepEqual(nose, { name: "nose", x: 0, y: 0, score: 0.9 });
	assert.deepEqual(leftShoulder, {
		name: "left_shoulder",
		x: 70.4,
		y: 26.4,
		score: 0.9,
	});
	assert.deepEqual(leftAnkle, {
		name: "left_ankle",
		x: 172.8,
		y: 64.8,
		score: 0.9,
	});
});
