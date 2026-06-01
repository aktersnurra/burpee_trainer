import test from "node:test";
import assert from "node:assert/strict";
import {
	initialTraceRecorder,
	startTraceRecording,
	stepTraceRecorder,
} from "./pose_trace_recorder.mjs";

function sample(tMs, signal = 0.6, closeness = 0.3) {
	return { tMs, signal, closeness, confidence: 0.9 };
}

test("trace recorder counts down before collecting samples", () => {
	const state = startTraceRecording(initialTraceRecorder(), 1000);

	let result = stepTraceRecorder(state, sample(2000));
	assert.equal(result.state.phase, "countdown");
	assert.equal(result.state.samples.length, 0);
	assert.equal(result.status, "Trace starts in 2s");

	result = stepTraceRecorder(result.state, sample(4100));
	assert.equal(result.state.phase, "recording");
	assert.equal(result.state.samples.length, 1);
	assert.equal(result.status, "Recording trace 10s");
});

test("trace recorder auto-stops and exports samples", () => {
	let state = startTraceRecording(initialTraceRecorder(), 0);
	for (const item of [sample(3000), sample(6000), sample(9000), sample(13000)]) {
		state = stepTraceRecorder(state, item).state;
	}

	assert.equal(state.phase, "complete");
	assert.equal(state.samples.length, 4);
	assert.equal(state.export.samples.length, 4);
	assert.equal(state.export.durationMs, 10000);
});
