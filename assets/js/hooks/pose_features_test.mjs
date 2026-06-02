import test from "node:test";
import assert from "node:assert/strict";
import {
	featureFrameFromPose,
	featureFramesFromSamples,
} from "./pose_features.mjs";

const video = { videoWidth: 400, videoHeight: 800 };

function keypoint(name, x, y, score = 0.9, extra = {}) {
	return { name, x, y, score, visibility: score, ...extra };
}

function poseAt({ tMs = 0, shoulderY = 200, hipY = 400, wristY = 360 }) {
	return {
		model: "blazepose-full",
		keypoints: [
			keypoint("nose", 200, shoulderY - 120),
			keypoint("left_shoulder", 160, shoulderY),
			keypoint("right_shoulder", 240, shoulderY),
			keypoint("left_elbow", 150, wristY - 40),
			keypoint("right_elbow", 250, wristY - 40),
			keypoint("left_wrist", 140, wristY, 0.8, {
				world: { x: 1, y: 2, z: 3 },
			}),
			keypoint("right_wrist", 260, wristY, 0.8),
			keypoint("left_hip", 170, hipY),
			keypoint("right_hip", 230, hipY),
			keypoint("left_knee", 175, hipY + 170, 0.7),
			keypoint("right_knee", 225, hipY + 170, 0.7),
			keypoint("left_ankle", 180, hipY + 300, 0.6),
			keypoint("right_ankle", 220, hipY + 300, 0.6),
			keypoint("left_heel", 178, hipY + 320, 0.5),
			keypoint("right_heel", 222, hipY + 320, 0.5),
			keypoint("left_foot_index", 176, hipY + 340, 0.5),
			keypoint("right_foot_index", 224, hipY + 340, 0.5),
		],
		tMs,
	};
}

test("extracts shared BlazePose feature frame with body geometry and normalized landmarks", () => {
	const frame = featureFrameFromPose(poseAt({}), 1234, video);

	assert.equal(frame.tMs, 1234);
	assert.equal(frame.model, "blazepose-full");
	assert.equal(frame.visibleFraction > 0.45, true);
	assert.equal(frame.shoulderMidY, 0.25);
	assert.equal(frame.hipMidY, 0.5);
	assert.equal(frame.wristMidY, 0.45);
	assert.equal(frame.elbowMidY, 0.4);
	assert.equal(frame.footMidY, 0.925);
	assert.equal(frame.heelMidY, 0.9);
	assert.equal(frame.shoulderWidth, 0.2);
	assert.equal(frame.hipWidth, 0.15);
	assert.equal(frame.torsoLength, 0.25);
	assert.equal(frame.bboxWidth, 0.3);
	assert.equal(frame.bboxHeight, 0.825);
	assert.equal(frame.signal, 0.1207);
	assert.equal(frame.closeness, 0.775);
	assert.equal(frame.upperBodyScore > frame.footScore, true);
	assert.equal(frame.handScore, 0.8);
	assert.equal(frame.footScore, 0.5333);
	assert.deepEqual(frame.normalizedLandmarks.left_wrist, {
		x: -0.3,
		y: -0.2,
		z: null,
		weight: 0.8,
		world_x: 1,
		world_y: 2,
		world_z: 3,
	});
});

test("adds velocity features from actual timestamps", () => {
	const frames = featureFramesFromSamples(
		[
			{ pose: poseAt({ tMs: 0, shoulderY: 200, hipY: 400 }), tMs: 0 },
			{ pose: poseAt({ tMs: 200, shoulderY: 260, hipY: 460 }), tMs: 200 },
		],
		video,
	);

	assert.equal(frames[0].dShoulderY, null);
	assert.equal(frames[0].dSignal, null);
	assert.equal(frames[0].dCloseness, null);
	assert.equal(frames[1].dShoulderY, 0.375);
	assert.equal(frames[1].dHipY, 0.375);
	assert.equal(frames[1].dSignal, -0.375);
	assert.equal(frames[1].dCloseness, 0);
});
