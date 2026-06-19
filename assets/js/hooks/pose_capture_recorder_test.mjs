import test from "node:test";
import assert from "node:assert/strict";
import {
	flushPoseCaptureRecorder,
	initialPoseCaptureRecorder,
	recordPoseSample,
} from "./pose_capture_recorder.mjs";

function sample(tMs) {
	return {
		tMs,
		confidence: 0.9,
		keypoints: { nose: { x: 0.5, y: 0.2, score: 0.9 } },
		features: { hipY: 0.4 },
	};
}

test("flushes a chunk when the interval elapses", () => {
	let state = initialPoseCaptureRecorder({ flushIntervalMs: 3000 });

	let result = recordPoseSample(state, sample(0), { segment: "warmup", nowMs: 0 });
	state = result.state;
	assert.deepEqual(result.chunks, []);

	result = recordPoseSample(state, sample(1000), {
		segment: "warmup",
		nowMs: 1000,
	});
	state = result.state;
	assert.deepEqual(result.chunks, []);

	result = recordPoseSample(state, sample(3000), {
		segment: "warmup",
		nowMs: 3000,
	});

	assert.equal(result.chunks.length, 1);
	assert.deepEqual(result.chunks[0], {
		segment: "warmup",
		chunk_index: 0,
		started_at_ms: 0,
		ended_at_ms: 3000,
		sample_count: 3,
		payload: { version: 1, samples: [sample(0), sample(1000), sample(3000)] },
	});
	assert.equal(result.state.nextChunkIndex, 1);
	assert.equal(result.state.pendingSamples.length, 0);
});

test("flushes the previous segment before recording a new segment", () => {
	let state = initialPoseCaptureRecorder({ flushIntervalMs: 3000 });

	state = recordPoseSample(state, sample(0), { segment: "warmup", nowMs: 0 }).state;
	const result = recordPoseSample(state, sample(100), {
		segment: "main",
		nowMs: 100,
	});

	assert.equal(result.chunks.length, 1);
	assert.equal(result.chunks[0].segment, "warmup");
	assert.equal(result.chunks[0].chunk_index, 0);
	assert.equal(result.chunks[0].sample_count, 1);
	assert.equal(result.state.pendingSegment, "main");
	assert.equal(result.state.pendingSamples.length, 1);
	assert.equal(result.state.nextChunkIndex, 1);
});

test("final flush emits remaining samples with monotonically increasing chunk index", () => {
	let state = initialPoseCaptureRecorder({ flushIntervalMs: 3000 });

	state = recordPoseSample(state, sample(0), { segment: "main", nowMs: 0 }).state;
	state = recordPoseSample(state, sample(3000), { segment: "main", nowMs: 3000 }).state;
	state = recordPoseSample(state, sample(3500), { segment: "main", nowMs: 3500 }).state;

	const result = flushPoseCaptureRecorder(state, { reason: "finish", nowMs: 3600 });

	assert.equal(result.chunks.length, 1);
	assert.equal(result.chunks[0].chunk_index, 1);
	assert.equal(result.chunks[0].started_at_ms, 3500);
	assert.equal(result.chunks[0].ended_at_ms, 3500);
	assert.equal(result.chunks[0].sample_count, 1);
	assert.equal(result.state.pendingSamples.length, 0);
});
