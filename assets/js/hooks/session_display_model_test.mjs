import test from "node:test";
import assert from "node:assert/strict";
import {
	beatState,
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
	"beat",
	"primaryCount",
	"countdownDots",
	"restTimeLeftSec",
	"sessionProgress",
	"repProgress",
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

test("normal rest reads as a time and derives set progress from immutable work events", () => {
	const firstRest = runningModel(threeSetTimeline, 1, {
		phase_elapsed: 12,
		phase_remaining: 18,
	});
	const secondRest = runningModel(threeSetTimeline, 3, {
		phase_elapsed: 26,
		phase_remaining: 4,
	});

	assert.equal(firstRest.visual.state, "rest");
	assert.equal(firstRest.primaryCount, "0:18");
	assert.equal(firstRest.setProgress, "1/3");
	assert.equal(secondRest.visual.state, "rest");
	assert.equal(secondRest.primaryCount, "0:04");
	assert.equal(secondRest.setProgress, "2/3");
	assert.equal(Object.hasOwn(threeSetTimeline[1], "setProgress"), false);
	assertLeanContract(firstRest, runningKeys);
});

test("rest reads as minutes and seconds, so it is never taken for reps", () => {
	const timeline = [
		{ kind: "work", reps: 1, sec_per_rep: 4, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 90 },
		{ kind: "work", reps: 1, sec_per_rep: 4, sec_per_burpee: 3 },
	];

	for (const [remaining, expected] of [
		[65, "1:05"],
		[60, "1:00"],
		[59, "0:59"],
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
	assert.equal(model.primaryCount, "0:04");
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

test("terminal explicit work duration leaves no trailing recovery frame", () => {
	const timeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 20 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 13 },
	];
	const lastFrame = currentFrame(timeline, 37.999);
	const lastModel = runningDisplayModel({
		timeline,
		frame: lastFrame,
		timeLeftSec: 0.001,
		totalDone: 3,
		totalTarget: 4,
	});

	assert.equal(lastModel.visual.state, "work_active");
	assert.equal(currentFrame(timeline, 38), null);
});

test("the completed timeline shows zero remaining and a full fill during final-rep grace", () => {
	const timeline = [{ kind: "work", reps: 2, sec_per_rep: 4 }];
	const model = runningDisplayModel({
		timeline,
		frame: currentFrame(timeline, 8),
		timeLeftSec: 0,
		sessionProgress: 1,
		totalDone: 2,
	});

	assert.equal(model.primaryCount, 0);
	assert.equal(model.visual.state, "work_active");
	assert.equal(model.visual.progress, 1);
	assert.equal(model.sessionProgress, 1);
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
	});

	assert.deepEqual(boundaryModel.visual, {
		state: "work_active",
		progress: 0,
		draining: false,
		pace: "steady",
		lead: null,
		pulse: null,
	});
	assert.equal(boundaryModel.primaryCount, 6);
	assert.equal(boundaryModel.setProgress, null);
});

// Beats: rep k has its beat at (k-1)c and is due at (k-1)c + a.
const unbroken = Object.freeze({ kind: "work", reps: 8, sec_per_rep: 4, sec_per_burpee: 4 });
const even = Object.freeze({ kind: "work", reps: 5, sec_per_rep: 10, sec_per_burpee: 4 });
const beat = (event, t, countedAtSec, cameraTrusted = countedAtSec !== undefined) =>
	beatState({ event, phaseElapsedSec: t, countedAtSec, cameraTrusted });
const near = (actual, expected) =>
	assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} is not ${expected}`);

test("the fill rises from a rep's beat to its due time", () => {
	near(beat(unbroken, 0).fill, 0);
	near(beat(unbroken, 1).fill, 0.25);
	near(beat(even, 2).fill, 0.5);
	assert.equal(beat(even, 2).draining, false);
	assert.equal(beat(even, 2).repOn, 1);
});

test("without the camera each rep is done at its due time and drains to the next beat", () => {
	const gap = beat(even, 7);
	assert.equal(gap.done, 1);
	assert.equal(gap.repOn, 2);
	assert.equal(gap.draining, true);
	near(gap.fill, 0.5);
	near(beat(even, 10).fill, 0);
	assert.equal(beat(even, 10).draining, false);
	assert.equal(beat(unbroken, 4).done, 1);
	assert.equal(beat(unbroken, 4).pace, "steady");
});

test("a counted rep drains from where it stood to empty at the next beat", () => {
	const early = beat(unbroken, 3, [3]);
	assert.equal(early.done, 1);
	assert.equal(early.draining, true);
	near(early.fill, 0.75);
	near(beat(unbroken, 3.5, [3]).fill, 0.375);
	near(beat(unbroken, 4, [3]).fill, 0);
	assert.equal(beat(unbroken, 4, [3]).draining, false);
});

test("a rep past its due time holds the fill full and reads behind until it is counted", () => {
	const late = beat(unbroken, 5, []);
	assert.equal(late.repOn, 1);
	assert.equal(late.fill, 1);
	assert.equal(late.pace, "behind");
	assert.equal(late.draining, false);
	assert.equal(beat(unbroken, 5.5, [5.2]).pace, "steady");
	near(beat(unbroken, 5.5, [5.2]).fill, 0.375);
});

test("ahead needs the last counted rep a fifth of its rep time early", () => {
	assert.equal(beat(unbroken, 3.3, [3.2]).pace, "ahead");
	assert.equal(beat(unbroken, 3.3, [3.21]).pace, "steady");
	assert.equal(beat(unbroken, 1, []).pace, "steady");
	assert.equal(beat(unbroken, 3.3, [3.2], false).pace, "steady");
});

test("a gap over three seconds leads into the next beat with 3, 2, 1", () => {
	assert.equal(beat(even, 6.5).lead, null);
	assert.equal(beat(even, 7.5).lead, 3);
	assert.equal(beat(even, 9.5).lead, 1);
	assert.equal(beat(even, 10.5).lead, null);
	assert.equal(beat(unbroken, 3.5, [1]).lead, null);
	assert.equal(beat(unbroken, 2, [0.5]).lead, 2);
});

test("the set's last rep has no gap after it", () => {
	const last = beat(even, 44.5);
	assert.equal(last.done, 5);
	assert.equal(last.repOn, 5);
	assert.equal(last.fill, 0);
	assert.equal(last.lead, null);
});

test("a set shows the reps left by the beats, not a recovery clock", () => {
	const model = runningDisplayModel({
		timeline: [even],
		frame: { event: even, index: 0, phase_elapsed: 7, phase_remaining: 37 },
		timeLeftSec: 37,
	});
	assert.equal(model.visual.state, "work_active");
	assert.equal(model.primaryCount, 4);
	assert.equal(model.visual.draining, true);
});

test("the fill stays in range and the rep you are on never goes back", () => {
	let seed = 7;
	const random = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
	for (let run = 0; run < 200; run++) {
		const c = 2 + random() * 10;
		const event = { kind: "work", reps: 1 + Math.floor(random() * 12), sec_per_rep: c, sec_per_burpee: c * (0.3 + random() * 0.7) };
		const camera = random() < 0.6;
		const counted = [];
		for (let t = 0; t < event.reps * c * 1.5; t += random() * 4) {
			if (counted.length < event.reps) counted.push(t);
		}
		let previous = 0;
		for (let t = 0; t <= event.reps * c * 1.6; t += 0.05) {
			const state = beat(event, t, camera ? counted.filter((at) => at <= t) : undefined, camera);
			assert.ok(state.fill >= 0 && state.fill <= 1, `fill ${state.fill}`);
			assert.ok(state.repOn >= previous);
			previous = state.repOn;
		}
	}
});
