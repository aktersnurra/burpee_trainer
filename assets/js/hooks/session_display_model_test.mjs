import test from "node:test";
import assert from "node:assert/strict";
import {
	countdownDisplayModel,
	runningDisplayModel,
} from "./session_display_model.mjs";

function runningModel(event, frameOverrides = {}) {
	return runningDisplayModel({
		timeline: [event],
		frame: {
			event,
			index: 0,
			phase_elapsed: 0,
			phase_remaining: event.duration_sec || event.reps * event.sec_per_rep,
			...frameOverrides,
		},
		timeLeftSec: 60,
		totalDone: 4,
		totalTarget: 20,
		doneInEvent: 1,
	});
}

function assertLeanContract(model, expectedKeys) {
	assert.deepEqual(Object.keys(model).sort(), expectedKeys.toSorted());
	for (const deadField of ["mode", "phaseLabel", "ring"]) {
		assert.equal(Object.hasOwn(model, deadField), false);
	}
}

test("initial count-in keeps dots", () => {
	const model = countdownDisplayModel({
		value: 3,
		total: 5,
		totalDone: 0,
		totalTarget: 20,
		timeLeftSec: 60,
	});

	assert.deepEqual(model.visual, {
		state: "initial-countdown",
		progress: 0,
		pulse: null,
	});
	assert.deepEqual(model.countdownDots, { count: 5, faded: 2 });
	assertLeanContract(model, [
		"visual",
		"primaryCount",
		"countdownDots",
		"totalDone",
		"totalTarget",
		"timeLeftSec",
	]);
});

test("work exposes existing per-rep progress", () => {
	const model = runningModel(
		{ kind: "work", reps: 6, sec_per_rep: 4 },
		{ phase_elapsed: 6, phase_remaining: 18 },
	);

	assert.deepEqual(model.visual, {
		state: "work",
		progress: 0.5,
		pulse: null,
	});
	assert.equal(model.primaryCount, 5);
	assertLeanContract(model, [
		"visual",
		"primaryCount",
		"countdownDots",
		"restTimeLeftSec",
		"totalDone",
		"totalTarget",
		"timeLeftSec",
	]);
});

test("rest breathes before the final five seconds", () => {
	const model = runningModel(
		{ kind: "rest", duration_sec: 30 },
		{ phase_elapsed: 18, phase_remaining: 12 },
	);

	assert.equal(model.visual.state, "rest-breathe");
	assert.equal(model.primaryCount, "12");
	assert.equal(model.countdownDots, null);
});

test("rest settles at five and four seconds", () => {
	for (const remaining of [5, 4]) {
		const model = runningModel(
			{ kind: "rest", duration_sec: 30 },
			{ phase_elapsed: 30 - remaining, phase_remaining: remaining },
		);

		assert.equal(model.visual.state, "rest-settle");
		assert.equal(model.visual.pulse, null);
		assert.equal(model.primaryCount, String(remaining));
	}
});

test("between-set final three seconds use numeric pulses, not dots", () => {
	for (const remaining of [3, 2, 1]) {
		const model = runningModel(
			{ kind: "rest", duration_sec: 30 },
			{ phase_elapsed: 30 - remaining, phase_remaining: remaining },
		);

		assert.equal(model.visual.state, "rest-countdown");
		assert.equal(model.visual.pulse, remaining);
		assert.equal(model.primaryCount, remaining);
		assert.equal(model.countdownDots, null);
	}
});
