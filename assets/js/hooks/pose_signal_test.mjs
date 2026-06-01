import test from "node:test";
import assert from "node:assert/strict";
import { sampleFromPose } from "./pose_signal.mjs";

const video = { videoWidth: 300, videoHeight: 600 };

function pose({ shoulderY, hipY, shoulderX = [120, 180], hipX = [130, 170] }) {
	return {
		keypoints: [
			{ name: "left_shoulder", x: shoulderX[0], y: shoulderY, score: 0.9 },
			{ name: "right_shoulder", x: shoulderX[1], y: shoulderY, score: 0.9 },
			{ name: "left_hip", x: hipX[0], y: hipY, score: 0.9 },
			{ name: "right_hip", x: hipX[1], y: hipY, score: 0.9 },
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
