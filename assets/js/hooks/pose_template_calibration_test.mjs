import test from "node:test";
import assert from "node:assert/strict";
import {
	initialTemplateCalibration,
	startTemplateCalibration,
	stepTemplateCalibration,
} from "./pose_template_calibration.mjs";

function sample(tMs, signal = 0.6, closeness = 0.3) {
	return { tMs, signal, closeness, confidence: 0.9 };
}

test("calibration counts down before recording samples", () => {
	const state = startTemplateCalibration(initialTemplateCalibration(), 1000);

	let result = stepTemplateCalibration(state, sample(2000));
	assert.equal(result.state.phase, "countdown");
	assert.equal(result.state.recording.samples.length, 0);
	assert.equal(result.status, "Starting in 2s");

	result = stepTemplateCalibration(result.state, sample(4100));
	assert.equal(result.state.phase, "recording");
	assert.equal(result.state.recording.samples.length, 1);
	assert.equal(result.status, "Recording 5s");
});

test("calibration auto-saves template after recording window", () => {
	let state = startTemplateCalibration(initialTemplateCalibration(), 0);
	for (const item of [
		sample(3100, 0.72, 0.2),
		sample(3600, 0.38, 0.74),
		sample(4300, 0.69, 0.25),
		sample(8200, 0.68, 0.24),
	]) {
		state = stepTemplateCalibration(state, item).state;
	}

	assert.equal(state.phase, "ready");
	assert.ok(state.template);
	assert.equal(state.recording.samples.length, 4);
});
