import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

function feature(tMs, values, confidence = 0.9) {
	return {
		tMs,
		poseConfidence: confidence,
		visibleFraction: confidence,
		macroLandmarkConfidence: confidence,
		...values,
	};
}

function completeCycle(startMs) {
	return [
		feature(startMs, {
			wristToAnkle: 1.25,
			shoulderToAnkle: 2.1,
			torsoUprightness: 0.9,
			hipToKnee: 0.9,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
		feature(startMs + 100, {
			wristToAnkle: 0.55,
			shoulderToAnkle: 1.2,
			torsoUprightness: 0.55,
			hipToKnee: 0.6,
			dWristToAnkle: -1.4,
			dShoulderToAnkle: -1.1,
		}),
		feature(startMs + 200, {
			wristToAnkle: 0.16,
			shoulderToAnkle: 0.38,
			torsoUprightness: 0.12,
			hipToKnee: 0.52,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
		feature(startMs + 300, {
			wristToAnkle: 0.48,
			shoulderToAnkle: 0.72,
			torsoUprightness: 0.45,
			hipToKnee: 0.3,
			dWristToAnkle: 1.2,
			dShoulderToAnkle: 1.4,
		}),
		feature(startMs + 400, {
			wristToAnkle: 1.25,
			shoulderToAnkle: 2.1,
			torsoUprightness: 0.9,
			hipToKnee: 0.9,
			dWristToAnkle: 0,
			dShoulderToAnkle: 0,
		}),
	];
}

function absentFrames(startMs, durationMs) {
	return Array.from({ length: durationMs / 100 }, (_, index) =>
		feature(startMs + index * 100, {}, 0.1),
	);
}

test("the app bundle has no calibration or template matcher dependency", async () => {
	const app = await readFile(new URL("../app.js", import.meta.url), "utf8");
	assert.doesNotMatch(
		app,
		/pose_(?:calibration_button|template_calibration|template_matcher)/,
	);
});

test("fixture absence between macro-cycles emits no warning and keeps Save enabled", async () => {
	const tracker = await import("./pose_tracker_impl.mjs");
	assert.equal(typeof tracker.runControlledPoseFixture, "function");

	const page = await tracker.runControlledPoseFixture([
		...completeCycle(0),
		...absentFrames(500, 2000),
		...completeCycle(3500),
	]);

	assert.equal(page.count(), 2);
	assert.equal(page.hasText(/tracking degraded|out of frame/i), false);
	assert.equal(page.saveDisabled(), false);
});
