import test from "node:test";
import assert from "node:assert/strict";
import { initialCounterState, countRep } from "./pose_rep_counter.mjs";

function run(samples) {
	let state = initialCounterState();
	const reps = [];

	for (const sample of samples) {
		const result = countRep(state, sample);
		state = result.state;
		if (result.rep) reps.push(sample.tMs);
	}

	return { state, reps };
}

test("closeness phase cycles emit one rep per standing-down-standing cycle", () => {
	const samples = [
		{ tMs: 0, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 500, signal: 0.14, closeness: 0.62, confidence: 0.9 },
		{ tMs: 1000, signal: 0.12, closeness: 0.88, confidence: 0.9 },
		{ tMs: 1600, signal: 0.14, closeness: 0.64, confidence: 0.9 },
		{ tMs: 2400, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 3600, signal: 0.14, closeness: 0.67, confidence: 0.9 },
		{ tMs: 4300, signal: 0.13, closeness: 0.92, confidence: 0.9 },
		{ tMs: 5200, signal: 0.15, closeness: 0.55, confidence: 0.9 },
		{ tMs: 5600, signal: 0.15, closeness: 0.52, confidence: 0.9 },
	];

	const { state, reps } = run(samples);
	assert.deepEqual(reps, [2400, 5600]);
	assert.deepEqual(state.cadenceMs, [2400, 5600]);
});

test("small closeness noise emits zero reps", () => {
	const samples = [0, 1, 2, 3, 4].map((i) => ({
		tMs: i * 500,
		signal: 0.15,
		closeness: i % 2 === 0 ? 0.58 : 0.54,
		confidence: 0.9,
	}));

	const { reps } = run(samples);
	assert.deepEqual(reps, []);
});

test("moderate closeness sway does not count as a rep", () => {
	const samples = [
		{ tMs: 0, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 400, signal: 0.15, closeness: 0.66, confidence: 0.9 },
		{ tMs: 800, signal: 0.14, closeness: 0.82, confidence: 0.9 },
		{ tMs: 1300, signal: 0.15, closeness: 0.64, confidence: 0.9 },
		{ tMs: 1800, signal: 0.15, closeness: 0.53, confidence: 0.9 },
	];

	const { reps } = run(samples);
	assert.deepEqual(reps, []);
});

test("refractory suppresses double count", () => {
	const samples = [
		{ tMs: 0, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 500, signal: 0.12, closeness: 0.9, confidence: 0.9 },
		{ tMs: 900, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 1100, signal: 0.12, closeness: 0.91, confidence: 0.9 },
		{ tMs: 1300, signal: 0.15, closeness: 0.53, confidence: 0.9 },
		{ tMs: 3000, signal: 0.12, closeness: 0.9, confidence: 0.9 },
		{ tMs: 4300, signal: 0.14, closeness: 0.7, confidence: 0.9 },
		{ tMs: 4500, signal: 0.15, closeness: 0.52, confidence: 0.9 },
	];

	const { reps } = run(samples);
	assert.deepEqual(reps, [1300, 4500]);
});

test("low confidence samples do not transition", () => {
	const samples = [
		{ tMs: 0, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 1000, signal: 0.12, closeness: 0.9, confidence: 0.1 },
		{ tMs: 2500, signal: 0.15, closeness: 0.52, confidence: 0.9 },
	];

	const { reps } = run(samples);
	assert.deepEqual(reps, []);
});

test("ring buffer backdates down timestamp to closeness peak", () => {
	const samples = [
		{ tMs: 0, signal: 0.15, closeness: 0.52, confidence: 0.9 },
		{ tMs: 500, signal: 0.14, closeness: 0.7, confidence: 0.9 },
		{ tMs: 900, signal: 0.12, closeness: 0.93, confidence: 0.9 },
		{ tMs: 1400, signal: 0.13, closeness: 0.86, confidence: 0.9 },
		{ tMs: 2100, signal: 0.14, closeness: 0.68, confidence: 0.9 },
		{ tMs: 2800, signal: 0.15, closeness: 0.53, confidence: 0.9 },
	];

	const { state, reps } = run(samples);
	assert.deepEqual(reps, [2800]);
	assert.equal(state.lastDownTMs, 900);
});
