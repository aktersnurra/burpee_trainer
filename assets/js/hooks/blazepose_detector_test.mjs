import test from "node:test";
import assert from "node:assert/strict";
import {
	createBlazePoseDetector,
	keypointsFromPoseLandmarks,
	poseFromBlazePoseResults,
	poseFromPoseLandmarkerResult,
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

test("a pose landmarker result maps landmarks and world landmarks together", () => {
	const pose = poseFromPoseLandmarkerResult(
		{
			landmarks: [[{ x: 0.5, y: 0.25, z: -0.1, visibility: 0.9 }]],
			worldLandmarks: [[{ x: 0.2, y: -0.3, z: 0.4, visibility: 0.8 }]],
		},
		video,
	);

	assert.equal(pose.model, "blazepose-full");
	assert.equal(pose.keypoints[0].name, "nose");
	assert.equal(pose.keypoints[0].x, 320);
	assert.equal(pose.keypoints[0].y, 120);
	assert.equal(pose.keypoints[0].score, 0.9);
	assert.deepEqual(pose.keypoints[0].world, {
		x: 0.2,
		y: -0.3,
		z: 0.4,
		visibility: 0.8,
	});
});

test("an empty pose landmarker result yields no pose", () => {
	assert.equal(
		poseFromPoseLandmarkerResult({ landmarks: [], worldLandmarks: [] }, video),
		null,
	);
	assert.equal(poseFromPoseLandmarkerResult(null, video), null);
});

test("the detector reports poses from synchronous video detection", async () => {
	let closed = false;
	let lastTimestamp = null;
	const detector = await createBlazePoseDetector({
		createPoseLandmarker: async () => ({
			detectForVideo(_video, timestamp) {
				lastTimestamp = timestamp;
				return {
					landmarks: [[{ x: 0.5, y: 0.5, z: 0, visibility: 0.95 }]],
					worldLandmarks: [[{ x: 0.1, y: 0.2, z: 0.3, visibility: 0.95 }]],
				};
			},
			close() {
				closed = true;
			},
		}),
		now: () => 1234,
	});

	const poses = await detector.estimatePoses(video);

	assert.equal(poses.length, 1);
	assert.equal(poses[0].keypoints[0].name, "nose");
	assert.equal(poses[0].keypoints[0].x, 320);
	assert.equal(lastTimestamp, 1234);

	detector.dispose();
	assert.equal(closed, true);
});

test("a frame without a detected pose reports no poses", async () => {
	const detector = await createBlazePoseDetector({
		createPoseLandmarker: async () => ({
			detectForVideo: () => ({ landmarks: [], worldLandmarks: [] }),
			close() {},
		}),
	});

	assert.deepEqual(await detector.estimatePoses(video), []);
});

test("timestamps passed to the landmarker never go backwards", async () => {
	const seen = [];
	let clock = 100;
	const detector = await createBlazePoseDetector({
		createPoseLandmarker: async () => ({
			detectForVideo(_video, timestamp) {
				seen.push(timestamp);
				return { landmarks: [], worldLandmarks: [] };
			},
			close() {},
		}),
		now: () => clock,
	});

	await detector.estimatePoses(video);
	clock = 100;
	await detector.estimatePoses(video);
	clock = 50;
	await detector.estimatePoses(video);

	assert.deepEqual(
		seen,
		seen.slice().sort((a, b) => a - b),
	);
	assert.equal(new Set(seen).size, seen.length);
});
