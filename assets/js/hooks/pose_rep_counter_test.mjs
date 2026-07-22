import assert from "node:assert/strict";
import test from "node:test";

import { countRep, initialCounterState } from "./pose_rep_counter.mjs";

const sample = (tMs, closeness, confidence = 0.9) => ({
	tMs,
	closeness,
	confidence,
});

function step(state, nextSample) {
	return countRep(state, nextSample);
}

test("standing down and recovered standing emits exactly one rep", () => {
	let result = step(initialCounterState(), sample(0, 0.2));
	result = step(result.state, sample(500, 0.5));
	result = step(result.state, sample(900, 0.25));
	result = step(result.state, sample(1_100, 0.2));

	assert.equal(result.rep, true);
	assert.deepEqual(result.state.cadenceMs, [1_100]);
});

test("low-confidence samples cannot advance the detector", () => {
	const initial = initialCounterState();
	const result = step(initial, sample(500, 0.6, 0.1));
	assert.equal(result.rep, false);
	assert.deepEqual(result.state, initial);
});

test("refractory movement cannot double count", () => {
	let result = step(initialCounterState(), sample(0, 0.2));
	for (const next of [
		sample(500, 0.5),
		sample(900, 0.25),
		sample(1_100, 0.2),
		sample(1_300, 0.5),
		sample(1_500, 0.25),
		sample(1_700, 0.2),
	]) {
		result = step(result.state, next);
	}

	assert.equal(result.rep, false);
	assert.deepEqual(result.state.cadenceMs, [1_100]);
});

test("a fresh initial state clears setup and warmup cadence", () => {
	const dirty = {
		...initialCounterState(),
		phase: "ascending",
		cadenceMs: [1_100],
		lastRepTMs: 1_100,
	};
	assert.notDeepEqual(dirty, initialCounterState());
	assert.deepEqual(initialCounterState().cadenceMs, []);
	assert.equal(initialCounterState().phase, "standing");
});
