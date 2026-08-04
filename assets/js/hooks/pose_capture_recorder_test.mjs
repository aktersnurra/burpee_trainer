import assert from "node:assert/strict";
import test from "node:test";

import {
	MAX_TRACE_CHUNK_BYTES,
	flushPoseCaptureRecorder,
	initialPoseCaptureRecorder,
	recordPoseSample,
	serializedJsonBytes,
} from "./pose_capture_recorder.mjs";

function largeSamples() {
	return [
		{ tMs: 0, landmark_data: "x".repeat(120_000) },
		{ tMs: 1_000, landmark_data: "x".repeat(120_000) },
	];
}

test("recorder flushes before a payload exceeds the chunk byte budget", () => {
	let state = initialPoseCaptureRecorder();
	const chunks = [];

	for (const sample of largeSamples()) {
		const recorded = recordPoseSample(state, sample, {
			segment: "main",
			nowMs: sample.tMs,
		});
		state = recorded.state;
		chunks.push(...recorded.chunks);
	}

	const flushed = flushPoseCaptureRecorder(state);
	chunks.push(...flushed.chunks);

	assert.ok(
		chunks.every(
			(chunk) => serializedJsonBytes(chunk.payload) < MAX_TRACE_CHUNK_BYTES,
		),
	);
});

test("recorder never emits a payload at the chunk byte boundary", () => {
	const sample = { tMs: 0, landmark_data: "" };
	const emptyPayloadBytes = serializedJsonBytes({ version: 1, samples: [sample] });
	sample.landmark_data = "x".repeat(MAX_TRACE_CHUNK_BYTES - emptyPayloadBytes);

	assert.equal(
		serializedJsonBytes({ version: 1, samples: [sample] }),
		MAX_TRACE_CHUNK_BYTES,
	);

	const recorded = recordPoseSample(initialPoseCaptureRecorder(), sample, {
		segment: "main",
		nowMs: 0,
	});
	const flushed = flushPoseCaptureRecorder(recorded.state);
	const chunks = [...recorded.chunks, ...flushed.chunks];

	assert.deepEqual(chunks, []);
	assert.deepEqual(recorded.state.diagnostics, [
		{ type: "sample_exceeds_chunk_byte_budget", tMs: 0 },
	]);
});

test("recorder skips a sample that exceeds the chunk byte budget alone", () => {
	const { state, chunks } = recordPoseSample(
		initialPoseCaptureRecorder(),
		{ tMs: 0, landmark_data: "x".repeat(MAX_TRACE_CHUNK_BYTES) },
		{ segment: "main", nowMs: 0 },
	);

	assert.deepEqual(chunks, []);
	assert.deepEqual(state.pendingSamples, []);
	assert.deepEqual(state.diagnostics, [
		{ type: "sample_exceeds_chunk_byte_budget", tMs: 0 },
	]);
});
