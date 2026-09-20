import test from "node:test";
import assert from "node:assert/strict";
import {
	createBlazePoseDetector,
	keypointsFromPoseLandmarks,
	poseFromBlazePoseResults,
	poseFromPoseLandmarkerResult,
} from "./blazepose_detector.mjs";
import { createWorkerPoseDetector } from "./pose_worker_detector.mjs";

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

function fakeWorker({ onDetect, failInit = false } = {}) {
	const worker = {
		posted: [],
		terminated: false,
		onmessage: null,
		postMessage(message, transfer) {
			worker.posted.push({ message, transfer });
			queueMicrotask(() => {
				const { id, type, payload } = message;
				if (type === "init") {
					worker.onmessage?.({
						data: failInit
							? { id, ok: false, error: "no gpu" }
							: { id, ok: true },
					});
					return;
				}
				if (type === "detect") {
					worker.onmessage?.({
						data: {
							id,
							ok: true,
							result: onDetect
								? onDetect(payload)
								: { landmarks: [], worldLandmarks: [] },
						},
					});
					return;
				}
				worker.onmessage?.({ data: { id, ok: true } });
			});
		},
		terminate() {
			worker.terminated = true;
		},
	};
	return worker;
}

const bitmapVideo = { videoWidth: 640, videoHeight: 480 };

test("the worker detector transfers a frame bitmap and maps the result back", async () => {
	const closed = [];
	const worker = fakeWorker({
		onDetect: () => ({
			landmarks: [{ x: 0.5, y: 0.25, z: 0, visibility: 0.9 }],
			worldLandmarks: [{ x: 0.1, y: 0.2, z: 0.3, visibility: 0.9 }],
		}),
	});
	const detector = await createWorkerPoseDetector({
		createWorker: () => worker,
		createImageBitmap: async () => ({ close: () => closed.push(true) }),
		now: () => 500,
	});

	const poses = await detector.estimatePoses(bitmapVideo);

	assert.equal(poses.length, 1);
	assert.equal(poses[0].keypoints[0].name, "nose");
	assert.equal(poses[0].keypoints[0].x, 320);
	assert.equal(poses[0].keypoints[0].y, 120);
	assert.deepEqual(poses[0].keypoints[0].world, {
		x: 0.1,
		y: 0.2,
		z: 0.3,
		visibility: 0.9,
	});

	const detectCall = worker.posted.find((c) => c.message.type === "detect");
	assert.deepEqual(detectCall.transfer, [detectCall.message.payload.bitmap]);
	assert.equal(detectCall.message.payload.timestamp, 500);
});

test("a frame with no detected pose reports no poses", async () => {
	const detector = await createWorkerPoseDetector({
		createWorker: () => fakeWorker(),
		createImageBitmap: async () => ({ close() {} }),
	});

	assert.deepEqual(await detector.estimatePoses(bitmapVideo), []);
});

test("worker timestamps never repeat or go backwards", async () => {
	const seen = [];
	let clock = 100;
	const detector = await createWorkerPoseDetector({
		createWorker: () =>
			fakeWorker({
				onDetect: (payload) => {
					seen.push(payload.timestamp);
					return { landmarks: [], worldLandmarks: [] };
				},
			}),
		createImageBitmap: async () => ({ close() {} }),
		now: () => clock,
	});

	await detector.estimatePoses(bitmapVideo);
	clock = 100;
	await detector.estimatePoses(bitmapVideo);
	clock = 40;
	await detector.estimatePoses(bitmapVideo);

	assert.deepEqual(
		seen,
		seen.slice().sort((a, b) => a - b),
	);
	assert.equal(new Set(seen).size, seen.length);
});

test("a failed worker initialization rejects instead of returning a detector", async () => {
	await assert.rejects(
		createWorkerPoseDetector({
			createWorker: () => fakeWorker({ failInit: true }),
			createImageBitmap: async () => ({ close() {} }),
		}),
		/no gpu/,
	);
});

test("disposing terminates the worker", async () => {
	const worker = fakeWorker();
	const detector = await createWorkerPoseDetector({
		createWorker: () => worker,
		createImageBitmap: async () => ({ close() {} }),
	});

	detector.dispose();

	assert.equal(worker.terminated, true);
});

test("a worker error rejects the frame in flight instead of hanging", async () => {
	const worker = fakeWorker({ onDetect: () => null });
	worker.postMessage = (message) => {
		if (message.type === "init") {
			queueMicrotask(() =>
				worker.onmessage?.({ data: { id: message.id, ok: true } }),
			);
			return;
		}
		queueMicrotask(() => worker.onerror?.(new Error("worker crashed")));
	};
	const detector = await createWorkerPoseDetector({
		createWorker: () => worker,
		createImageBitmap: async () => ({ close() {} }),
	});

	await assert.rejects(detector.estimatePoses(bitmapVideo));
});

test("disposing rejects a frame still in flight", async () => {
	const worker = fakeWorker();
	worker.postMessage = (message) => {
		if (message.type === "init") {
			queueMicrotask(() =>
				worker.onmessage?.({ data: { id: message.id, ok: true } }),
			);
		}
	};
	const detector = await createWorkerPoseDetector({
		createWorker: () => worker,
		createImageBitmap: async () => ({ close() {} }),
	});

	const inFlight = detector.estimatePoses(bitmapVideo);
	await Promise.resolve();
	detector.dispose();

	await assert.rejects(inFlight);
});

test("the short-side cap leaves headroom for the cropped pose ROI", async () => {
	const requested = [];
	const detector = await createWorkerPoseDetector({
		createWorker: () => fakeWorker(),
		createImageBitmap: async (_video, options) => {
			requested.push(options);
			return { close() {} };
		},
	});

	await detector.estimatePoses({ videoWidth: 1080, videoHeight: 1920 });

	// The landmark model runs on a crop around the person, not the whole
	// frame, so the short side must stay well above the 256px model input or
	// a person filling part of the frame gets upscaled detail.
	assert.equal(
		Math.min(requested[0].resizeWidth, requested[0].resizeHeight) >= 512,
		true,
	);
});

test("portrait frames are capped on their short side, not their width", async () => {
	const requested = [];
	const detector = await createWorkerPoseDetector({
		createWorker: () => fakeWorker(),
		createImageBitmap: async (_video, options) => {
			requested.push(options);
			return { close() {} };
		},
	});

	// A portrait camera frame: capping width would leave the long side huge.
	await detector.estimatePoses({ videoWidth: 720, videoHeight: 1280 });

	const [options] = requested;
	assert.equal(Math.min(options.resizeWidth, options.resizeHeight), 512);
	assert.equal(
		Math.round((options.resizeWidth / options.resizeHeight) * 1000),
		Math.round((720 / 1280) * 1000),
		"aspect ratio must be preserved",
	);
});

test("frames are downscaled before transfer to cut main-thread copy cost", async () => {
	const requested = [];
	const detector = await createWorkerPoseDetector({
		createWorker: () => fakeWorker(),
		createImageBitmap: async (_video, options) => {
			requested.push(options);
			return { close() {} };
		},
	});

	await detector.estimatePoses({ videoWidth: 1280, videoHeight: 720 });

	const [options] = requested;
	assert.ok(options, "expected resize options to be passed");
	assert.equal(Math.min(options.resizeWidth, options.resizeHeight), 512);
	assert.equal(
		Math.round((options.resizeWidth / options.resizeHeight) * 100),
		Math.round((1280 / 720) * 100),
		"aspect ratio must be preserved so landmark scaling stays correct",
	);
});

test("a frame smaller than the cap is not upscaled", async () => {
	const requested = [];
	const detector = await createWorkerPoseDetector({
		createWorker: () => fakeWorker(),
		createImageBitmap: async (_video, options) => {
			requested.push(options);
			return { close() {} };
		},
	});

	// Short side already at or below the model input: leave it alone.
	await detector.estimatePoses({ videoWidth: 320, videoHeight: 240 });

	assert.equal(requested[0].resizeWidth, 320);
	assert.equal(requested[0].resizeHeight, 240);
});
