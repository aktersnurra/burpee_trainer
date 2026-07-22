import test from "node:test";
import assert from "node:assert/strict";
import {
	countdownDisplayModel,
	runningDisplayModel,
	sessionProgressForElapsed,
} from "./session_display_model.mjs";
import { currentFrame } from "./session_segment_fsm.mjs";

function runningModel(timeline, index, frameOverrides = {}) {
	const event = timeline[index];
	return runningDisplayModel({
		timeline,
		frame: {
			event,
			index,
			phase_elapsed: 0,
			phase_remaining: event.duration_sec || event.reps * event.sec_per_rep,
			...frameOverrides,
		},
		timeLeftSec: 60,
		sessionProgress: 0.25,
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

const threeSetTimeline = Object.freeze([
	Object.freeze({
		kind: "work",
		reps: 6,
		sec_per_rep: 4,
		sec_per_burpee: 3,
	}),
	Object.freeze({ kind: "rest", duration_sec: 30 }),
	Object.freeze({
		kind: "work",
		reps: 6,
		sec_per_rep: 4,
		sec_per_burpee: 3,
	}),
	Object.freeze({ kind: "rest", duration_sec: 30 }),
	Object.freeze({
		kind: "work",
		reps: 8,
		sec_per_rep: 4,
		sec_per_burpee: 3,
	}),
]);

const runningKeys = [
	"visual",
	"primaryCount",
	"countdownDots",
	"restTimeLeftSec",
	"sessionProgress",
	"setProgress",
	"totalDone",
	"totalTarget",
	"timeLeftSec",
];

test("initial count-in uses the same centered numeral treatment as rest count-in", () => {
	const model = countdownDisplayModel({
		value: 3,
		totalDone: 0,
		totalTarget: 20,
		timeLeftSec: 60,
		sessionProgress: 0,
	});

	assert.deepEqual(model.visual, {
		state: "count_in",
		progress: 0,
		pulse: null,
	});
	assert.equal(model.primaryCount, 3);
	assert.equal(model.countdownDots, null);
	assert.equal(model.setProgress, null);
	assertLeanContract(model, [
		"visual",
		"primaryCount",
		"countdownDots",
		"sessionProgress",
		"setProgress",
		"totalDone",
		"totalTarget",
		"timeLeftSec",
	]);
});

test("overall session progress is clamped and monotonic across event boundaries", () => {
	assert.equal(sessionProgressForElapsed(-1, 84), 0);
	assert.equal(sessionProgressForElapsed(0, 84), 0);
	assert.equal(sessionProgressForElapsed(21, 84), 0.25);
	assert.equal(sessionProgressForElapsed(42, 84), 0.5);
	assert.equal(sessionProgressForElapsed(84, 84), 1);
	assert.equal(sessionProgressForElapsed(100, 84), 1);
	assert.equal(sessionProgressForElapsed(10, 0), 0);

	const samples = [23.999, 24, 53.999, 54].map((elapsed) =>
		sessionProgressForElapsed(elapsed, 84),
	);
	assert.ok(
		samples.every((value, index) => index === 0 || value >= samples[index - 1]),
	);
});

test("active fill completes before full-screen recovery shows exact remaining time", () => {
	const activeStart = runningModel(threeSetTimeline, 0, {
		phase_elapsed: 0,
		phase_remaining: 24,
	});
	const activeMidpoint = runningModel(threeSetTimeline, 0, {
		phase_elapsed: 1.5,
		phase_remaining: 22.5,
	});
	const recoveryStart = runningModel(threeSetTimeline, 0, {
		phase_elapsed: 3,
		phase_remaining: 21,
	});
	const recoveryMidpoint = runningModel(threeSetTimeline, 0, {
		phase_elapsed: 3.5,
		phase_remaining: 20.5,
	});

	assert.deepEqual(activeStart.visual, {
		state: "work_active",
		progress: 0,
		pulse: null,
	});
	assert.deepEqual(activeMidpoint.visual, {
		state: "work_active",
		progress: 0.5,
		pulse: null,
	});
	assert.deepEqual(recoveryStart.visual, {
		state: "work_recovery",
		progress: 0,
		pulse: null,
	});
	assert.deepEqual(recoveryMidpoint.visual, {
		state: "work_recovery",
		progress: 0,
		pulse: null,
	});
	assert.equal(recoveryMidpoint.primaryCount, "1");
	assert.equal(recoveryMidpoint.restTimeLeftSec, 0.5);
	assert.equal(recoveryMidpoint.sessionProgress, 0.25);
	assert.equal(recoveryMidpoint.setProgress, "1/3");
	assertLeanContract(recoveryMidpoint, runningKeys);
});

test("single-set recovery hides redundant 1/1 position", () => {
	const timeline = [
		{ kind: "work", reps: 6, sec_per_rep: 4, sec_per_burpee: 3 },
	];
	const recovery = runningModel(timeline, 0, {
		phase_elapsed: 3.5,
		phase_remaining: 20.5,
	});

	assert.equal(recovery.visual.state, "work_recovery");
	assert.equal(recovery.primaryCount, "1");
	assert.equal(recovery.setProgress, null);
});

test("unbroken work fills across each cadence interval instead of staying solid", () => {
	const timeline = [
		{ kind: "work", reps: 6, sec_per_rep: 4, sec_per_burpee: 4 },
	];
	const start = runningModel(timeline, 0, { phase_elapsed: 0 });
	const midpoint = runningModel(timeline, 0, { phase_elapsed: 2 });
	const end = runningModel(timeline, 0, { phase_elapsed: 3.999 });

	assert.deepEqual(start.visual, {
		state: "work_active",
		progress: 0,
		pulse: null,
	});
	assert.deepEqual(midpoint.visual, {
		state: "work_active",
		progress: 0.5,
		pulse: null,
	});
	assert.equal(end.visual.state, "work_active");
	assert.ok(end.visual.progress > 0.999);
});

test("normal rest uses bare seconds and derives set progress from immutable work events", () => {
	const firstRest = runningModel(threeSetTimeline, 1, {
		phase_elapsed: 12,
		phase_remaining: 18,
	});
	const secondRest = runningModel(threeSetTimeline, 3, {
		phase_elapsed: 26,
		phase_remaining: 4,
	});

	assert.equal(firstRest.visual.state, "rest");
	assert.equal(firstRest.primaryCount, "18");
	assert.equal(firstRest.setProgress, "1/3");
	assert.equal(secondRest.visual.state, "rest");
	assert.equal(secondRest.primaryCount, "4");
	assert.equal(secondRest.setProgress, "2/3");
	assert.equal(Object.hasOwn(threeSetTimeline[1], "setProgress"), false);
	assertLeanContract(firstRest, runningKeys);
});

test("rest always uses bare total seconds", () => {
	const timeline = [
		{ kind: "work", reps: 1, sec_per_rep: 4, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 90 },
		{ kind: "work", reps: 1, sec_per_rep: 4, sec_per_burpee: 3 },
	];

	for (const [remaining, expected] of [
		[65, "65"],
		[60, "60"],
		[59, "59"],
	]) {
		const model = runningModel(timeline, 1, {
			phase_elapsed: 90 - remaining,
			phase_remaining: remaining,
		});
		assert.equal(model.primaryCount, expected);
	}
});

test("just above three seconds remains normal rest", () => {
	const model = runningModel(threeSetTimeline, 1, {
		phase_elapsed: 26.999,
		phase_remaining: 3.001,
	});

	assert.equal(model.visual.state, "rest");
	assert.equal(model.primaryCount, "4");
	assert.equal(model.setProgress, "1/3");
});

test("exactly three seconds enters rest_count_in with plain centered numerals", () => {
	for (const remaining of [3, 2, 1]) {
		const model = runningModel(threeSetTimeline, 1, {
			phase_elapsed: 30 - remaining,
			phase_remaining: remaining,
		});

		assert.deepEqual(model.visual, {
			state: "rest_count_in",
			progress: 0,
			pulse: null,
		});
		assert.equal(model.primaryCount, remaining);
		assert.equal(model.countdownDots, null);
		assert.equal(model.setProgress, null);
	}
});

test("the exact rest boundary enters work at zero per-rep progress", () => {
	const boundarySec = 54;
	const finalRestFrame = currentFrame(threeSetTimeline, boundarySec - 0.001);
	const boundaryFrame = currentFrame(threeSetTimeline, boundarySec);

	assert.equal(finalRestFrame.event.kind, "rest");
	assert.equal(finalRestFrame.index, 1);
	assert.equal(
		runningDisplayModel({
			timeline: threeSetTimeline,
			frame: finalRestFrame,
			timeLeftSec: 56.001,
			totalDone: 6,
			totalTarget: 20,
			doneInEvent: 0,
		}).visual.state,
		"rest_count_in",
	);

	assert.deepEqual(boundaryFrame, {
		event: threeSetTimeline[2],
		index: 2,
		phase_elapsed: 0,
		phase_remaining: 24,
	});

	const boundaryModel = runningDisplayModel({
		timeline: threeSetTimeline,
		frame: boundaryFrame,
		timeLeftSec: 56,
		totalDone: 6,
		totalTarget: 20,
		doneInEvent: 0,
	});

	assert.deepEqual(boundaryModel.visual, {
		state: "work_active",
		progress: 0,
		pulse: null,
	});
	assert.equal(boundaryModel.primaryCount, 6);
	assert.equal(boundaryModel.setProgress, null);
});
