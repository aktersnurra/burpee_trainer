import test from "node:test";
import assert from "node:assert/strict";
import {
	initialTemplateMatcherState,
	recordTemplateSample,
	finishTemplateRecording,
	matchTemplateWindow,
} from "./pose_template_matcher.mjs";

function sample(tMs, signal, closeness = 0.2) {
	return { tMs, signal, closeness, confidence: 0.9 };
}

test("records a normalized template from calibration samples", () => {
	let state = initialTemplateMatcherState();
	for (const item of [
		sample(1000, 0.7, 0.2),
		sample(1500, 0.4, 0.7),
		sample(2200, 0.68, 0.25),
	]) {
		state = recordTemplateSample(state, item);
	}

	const result = finishTemplateRecording(state);

	assert.equal(result.ok, true);
	assert.equal(result.template.points.length, 3);
	assert.deepEqual(
		result.template.points.map((point) => point.t),
		[0, 0.42, 1],
	);
	assert.equal(result.template.points[0].signal, 1);
	assert.equal(result.template.points[1].signal, 0);
	assert.equal(result.template.points[1].closeness, 1);
});

test("rejects templates without a visible down then up recovery", () => {
	let state = initialTemplateMatcherState();
	for (const item of [
		sample(1000, 0.6, 0.2),
		sample(1500, 0.58, 0.22),
		sample(2200, 0.59, 0.21),
	]) {
		state = recordTemplateSample(state, item);
	}

	const result = finishTemplateRecording(state);

	assert.equal(result.ok, false);
	assert.equal(result.reason, "low_motion");
});

test("trims idle tail from fast calibration rep", () => {
	let state = initialTemplateMatcherState();
	for (const item of [
		sample(0, 0.71, 0.2),
		sample(500, 0.7, 0.21),
		sample(1000, 0.38, 0.72),
		sample(1600, 0.69, 0.24),
		sample(2500, 0.7, 0.22),
		sample(3500, 0.71, 0.21),
		sample(5000, 0.7, 0.2),
	]) {
		state = recordTemplateSample(state, item);
	}

	const result = finishTemplateRecording(state);

	assert.equal(result.ok, true);
	assert.equal(result.template.sourceStartTMs, 500);
	assert.equal(result.template.sourceEndTMs, 1600);
	assert.equal(result.template.durationMs, 1100);
});

test("matches a stretched rep and backdates down/up timing from the sample window", () => {
	let state = initialTemplateMatcherState();
	for (const item of [
		sample(0, 0.72, 0.2),
		sample(500, 0.38, 0.72),
		sample(1100, 0.69, 0.25),
	]) {
		state = recordTemplateSample(state, item);
	}
	const template = finishTemplateRecording(state).template;

	const window = [
		sample(5000, 0.71, 0.22),
		sample(5600, 0.5, 0.45),
		sample(6300, 0.36, 0.76),
		sample(7000, 0.47, 0.5),
		sample(7800, 0.67, 0.27),
	];

	const result = matchTemplateWindow(template, window);

	assert.equal(result.ok, true);
	assert.equal(result.downTMs, 6300);
	assert.equal(result.upTMs, 7800);
	assert.ok(result.distance < 0.18);
});
