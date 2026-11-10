import test from "node:test";
import assert from "node:assert/strict";
import { shouldSamplePose } from "./pose_sampler.mjs";

// Animation frames come every 16.67 ms, give or take a millisecond of timer rounding.
function sampleTimes(frameMs, jitterMs, frames) {
	const sampled = [];
	let last = -Infinity;
	for (let index = 0; index < frames; index++) {
		const now = index * frameMs + (index % 2 === 0 ? -jitterMs : jitterMs);
		if (shouldSamplePose(now, last)) {
			sampled.push(now);
			last = now;
		}
	}
	return sampled;
}

test("a 60 Hz display samples every fourth frame despite timer jitter", () => {
	const sampled = sampleTimes(1000 / 60, 1, 600);

	assert.equal(sampled.length, 150);
});

test("a 120 Hz display still samples 15 times a second", () => {
	const sampled = sampleTimes(1000 / 120, 0.5, 1200);

	assert.equal(sampled.length, 150);
});
