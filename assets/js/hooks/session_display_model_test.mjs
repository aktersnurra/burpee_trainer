import test from "node:test";
import assert from "node:assert/strict";
import {
	countdownDisplayModel,
	runningDisplayModel,
} from "./session_display_model.mjs";

const workoutTimeline = [
	{ kind: "work", duration_sec: 10, reps: 5, label: "Block 1" },
	{ kind: "rest", duration_sec: 5, label: "Rest" },
	{ kind: "work", duration_sec: 10, reps: 5, label: "Block 1" },
];

const warmupFrame = {
	index: 0,
	phase_elapsed: 2,
	event: { kind: "work", duration_sec: 6, reps: 3 },
};

const workoutFrame = {
	index: 0,
	phase_elapsed: 5,
	event: workoutTimeline[0],
};

const restFrame = {
	index: 1,
	phase_elapsed: 2,
	event: workoutTimeline[1],
};

test("runner display uses generic work/rest phases", () => {
	const warmupTimeline = [
		{ kind: "work", duration_sec: 6, reps: 3 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", duration_sec: 6, reps: 3 },
	];
	const model = runningDisplayModel({
		timeline: warmupTimeline,
		frame: warmupFrame,
		timeLeftSec: 4,
		totalDone: 0,
		totalTarget: 6,
	});

	assert.equal(model.mode, "work");
	assert.equal(model.ring.kind, "session");
	assert.equal(model.primaryCount, 3);
	assert.deepEqual(model.setGlyphs, [
		{ setCount: 2, completedSets: 0, currentSetProgress: 1 / 3 },
	]);
});

test("work ring cycles once per rep, not once per set", () => {
	const model = runningDisplayModel({
		timeline: workoutTimeline,
		frame: {
			index: 0,
			phase_elapsed: 3,
			event: {
				...workoutTimeline[0],
				duration_sec: 10,
				reps: 5,
				sec_per_rep: 2,
			},
		},
		timeLeftSec: 17,
		totalDone: 0,
		totalTarget: 10,
	});

	assert.equal(model.ring.progress, 0.5);
});

test("workout display owns workout glyphs and current set progress", () => {
	const model = runningDisplayModel({
		timeline: workoutTimeline,
		frame: workoutFrame,
		timeLeftSec: 20,
		totalDone: 0,
		totalTarget: 10,
	});

	assert.equal(model.mode, "work");
	assert.equal(model.ring.kind, "session");
	assert.equal(model.ring.progress, 0.5);
	assert.deepEqual(model.setGlyphs, [
		{ setCount: 2, completedSets: 0, currentSetProgress: 0.5 },
	]);
});

test("workout rest display keeps completed set glyphs and uses rest mode", () => {
	const model = runningDisplayModel({
		timeline: workoutTimeline,
		frame: { ...restFrame, phase_remaining: 4, phase_elapsed: 1 },
		timeLeftSec: 4,
		totalDone: 5,
		totalTarget: 10,
	});

	assert.equal(model.mode, "rest");
	assert.equal(model.primaryCount, "4");
	assert.equal(model.ring.progress, 0.2);
	assert.deepEqual(model.setGlyphs, [
		{ setCount: 2, completedSets: 1, currentSetProgress: null },
	]);
});

test("final three seconds of rest become ready count-in", () => {
	const model = runningDisplayModel({
		timeline: workoutTimeline,
		frame: restFrame,
		timeLeftSec: 3,
		totalDone: 5,
		totalTarget: 10,
	});

	assert.equal(model.mode, "countdown");
	assert.equal(model.phaseLabel, "starting in");
	assert.equal(model.primaryCount, 3);
	assert.deepEqual(model.setGlyphs, [
		{ setCount: 2, completedSets: 1, currentSetProgress: null },
	]);
});

test("countdown display never leaks workout glyphs", () => {
	const model = countdownDisplayModel({ value: 3, total: 5 });

	assert.equal(model.mode, "countdown");
	assert.equal(model.primaryCount, 3);
	assert.equal(model.ring.kind, "session");
	assert.equal(model.ring.progress, 0.4);
	assert.deepEqual(model.setGlyphs, []);
});
