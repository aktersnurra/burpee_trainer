import test from "node:test";
import assert from "node:assert/strict";
import { shouldSamplePose, POSE_INTERVAL_MS } from "./pose_sampler.mjs";

test("samples pose inference at 15 FPS using actual timestamps", () => {
	let lastPoseMs = -Infinity;

	assert.equal(POSE_INTERVAL_MS, 1000 / 15);
	assert.equal(shouldSamplePose(0, lastPoseMs), true);
	lastPoseMs = 0;

	assert.equal(shouldSamplePose(30, lastPoseMs), false);
	assert.equal(shouldSamplePose(66, lastPoseMs), false);
	assert.equal(shouldSamplePose(67, lastPoseMs), true);
});
