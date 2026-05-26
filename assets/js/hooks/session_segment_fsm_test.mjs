import assert from "node:assert/strict";
import {
	accountReps,
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";

const work = {
	type: "work_burpee",
	duration_sec: 10,
	burpee_count: 5,
	label: "Block 1",
};

const rest = {
	type: "work_rest",
	duration_sec: 5,
	burpee_count: 0,
	label: "Rest",
};

const warmupWork = {
	type: "warmup_burpee",
	duration_sec: 10,
	burpee_count: 5,
	label: "Warmup",
};

const warmupRest = {
	type: "warmup_rest",
	duration_sec: 5,
	burpee_count: 0,
	label: "Warmup rest",
};

assert.deepEqual(currentFrame([work, rest], 2), {
	event: work,
	index: 0,
	phase_elapsed: 2,
	phase_remaining: 8,
});

assert.equal(currentFrame([work], 10), null);

let reps = {
	currentEventKey: "0:work_burpee:Block 1",
	doneInEvent: 4,
	burpeeCountDone: 4,
	previousFrame: { event: work, index: 0 },
};

reps = accountReps(reps.previousFrame, { event: rest, index: 1 }, reps);
assert.equal(reps.burpeeCountDone, 5);

reps = {
	currentEventKey: "0:work_burpee:Block 1",
	doneInEvent: 4,
	burpeeCountDone: 4,
	previousFrame: { event: work, index: 0 },
};

reps = accountReps(reps.previousFrame, null, reps);
assert.equal(reps.burpeeCountDone, 5);

let result = segmentTransition(initialSegmentState(), {
	type: "SEGMENT_READY",
	timeline: [work, rest],
	blockCount: 1,
});
assert.equal(result.state.mode, "idle");
assert.equal(result.state.timeline.length, 2);

result = segmentTransition(result.state, { type: "COUNTDOWN_START", now: 1000 });
assert.equal(result.state.mode, "countdown");
assert.deepEqual(result.commands, [{ type: "startCountdownTimer" }]);

result = segmentTransition(result.state, { type: "COUNTDOWN_PAUSE", now: 1250 });
assert.equal(result.state.mode, "countdown_paused");
assert.equal(result.state.countdown.stepElapsedMs, 250);
assert.deepEqual(result.commands, [{ type: "pauseCountdownTimer" }]);

result = segmentTransition(result.state, { type: "COUNTDOWN_RESUME", now: 2000 });
assert.equal(result.state.mode, "countdown");
assert.equal(result.state.countdown.stepStartedAt, 2000);
assert.deepEqual(result.commands, [
	{ type: "resumeCountdownTimer", remainingMs: 750 },
]);

result = segmentTransition(result.state, {
	type: "COUNTDOWN_TICK",
	value: 4,
	now: 2100,
});
assert.equal(result.state.countdown.value, 4);
assert.equal(result.state.countdown.stepStartedAt, 2100);
assert.deepEqual(result.commands, [
	{ type: "renderCountdown", value: 4, animate: true },
	{ type: "playLeadBeep" },
	{ type: "scheduleCountdownTick", nextValue: 3, delayMs: 1000 },
]);

result = segmentTransition(result.state, {
	type: "COUNTDOWN_TICK",
	value: 0,
	now: 5100,
});
assert.equal(result.state.countdown.value, null);
assert.deepEqual(result.commands, [
	{ type: "clearCountdown" },
	{ type: "beginSegment" },
]);

result = segmentTransition(result.state, { type: "COUNTDOWN_DONE", now: 6000 });
assert.equal(result.state.mode, "running");
assert.equal(result.state.clock.totalDurationSec, 15);
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = segmentTransition(result.state, { type: "PAUSE", now: 7000 });
assert.equal(result.state.mode, "paused");
assert.deepEqual(result.commands, [{ type: "cancelAnimationFrame" }]);

result = segmentTransition(result.state, { type: "RESUME", now: 9000 });
assert.equal(result.state.mode, "running");
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);
assert.equal(result.state.clock.startTime, 8000);

result = segmentTransition(result.state, { type: "VISIBILITY_HIDDEN", now: 10000 });
assert.equal(result.state.clock.hiddenAt, 10000);
assert.deepEqual(result.commands, [{ type: "cancelAnimationFrame" }]);

result = segmentTransition(result.state, { type: "VISIBILITY_VISIBLE", now: 13000 });
assert.equal(result.state.clock.hiddenAt, null);
assert.equal(result.state.clock.startTime, 11000);
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = segmentTransition(result.state, { type: "TICK", elapsedSec: 3 });
assert.deepEqual(result.commands, [
	{ type: "renderRunningFrame", elapsedSec: 3 },
	{ type: "scheduleAnimationFrame" },
]);

result = segmentTransition(initialSegmentState(), {
	type: "DISPLAY_FRAME",
	frame: { event: work, index: 0, phase_elapsed: 2, phase_remaining: 8 },
	elapsedSec: 2,
	totalDurationSec: 15,
	doneInEvent: 1,
	blockCount: 1,
});
assert.deepEqual(result.commands.slice(0, 3), [
	{ type: "renderProgressBar", percent: 13.3, color: "#4A9EFF" },
	{ type: "renderTimer", timeLeftSec: 13 },
	{ type: "renderBlockLabel", label: "Block 1 of 1" },
]);
assert.deepEqual(result.commands.slice(3), [
	{ type: "enterWorkPhase", eventType: "work_burpee", burpeeCount: 5 },
	{ type: "triggerDown", remainingReps: 4 },
	{ type: "renderWorkRepProgress", progress: 0, color: "#4A9EFF" },
]);

result = segmentTransition(initialSegmentState(), {
	type: "DISPLAY_FRAME",
	frame: {
		event: warmupWork,
		index: 0,
		phase_elapsed: 2,
		phase_remaining: 8,
	},
	elapsedSec: 2,
	totalDurationSec: 15,
	doneInEvent: 1,
	blockCount: 0,
});
assert.deepEqual(result.commands.slice(0, 3), [
	{ type: "renderProgressBar", percent: 13.3, color: "#F59E0B" },
	{ type: "renderTimer", timeLeftSec: 13 },
	{ type: "renderBlockLabel", label: "" },
]);
assert.deepEqual(result.commands.slice(3), [
	{ type: "enterWorkPhase", eventType: "warmup_burpee", burpeeCount: 5 },
	{ type: "triggerDown", remainingReps: 4 },
	{ type: "renderWorkRepProgress", progress: 0, color: "#F59E0B" },
]);

result = segmentTransition(result.state, {
	type: "DISPLAY_FRAME",
	frame: { event: rest, index: 1, phase_elapsed: 1, phase_remaining: 4 },
	elapsedSec: 11,
	totalDurationSec: 15,
	blockCount: 1,
	doneInEvent: 0,
});
assert.deepEqual(result.commands, [
	{ type: "renderProgressBar", percent: 73.3, color: "#F59E0B" },
	{ type: "renderTimer", timeLeftSec: 4 },
	{ type: "renderBlockLabel", label: "" },
	{ type: "enterRestPhase", eventType: "work_rest" },
	{
		type: "renderRestProgress",
		progress: 0.2,
		color: "#F59E0B",
		timeLeftSec: 4,
	},
]);

let repState = {
	...initialSegmentState(),
	reps: {
		currentEventKey: "0:work_burpee:Block 1",
		doneInEvent: 4,
		burpeeCountDone: 4,
		previousFrame: { event: work, index: 0 },
	},
};

result = segmentTransition(repState, {
	type: "ACCOUNT_REPS",
	frame: { event: rest, index: 1 },
});
assert.equal(result.state.reps.burpeeCountDone, 5);
assert.deepEqual(result.commands, [
	{ type: "updateVisibleRepTotal", burpeeCountDone: 5 },
]);

result = segmentTransition(
	{
		...initialSegmentState(),
		reps: {
			currentEventKey: "0:warmup_burpee:Warmup",
			doneInEvent: 4,
			burpeeCountDone: 4,
			previousFrame: { event: warmupWork, index: 0 },
		},
	},
	{
		type: "ACCOUNT_REPS",
		frame: { event: warmupRest, index: 1 },
	},
);
assert.equal(result.state.reps.burpeeCountDone, 5);
assert.deepEqual(result.commands, [
	{ type: "updateVisibleRepTotal", burpeeCountDone: 5 },
]);

let beepState = {
	...initialSegmentState(),
	beeps: { lastRepIndex: -1, lastRestCount: null },
};

result = segmentTransition(beepState, {
	type: "BEEP_FRAME",
	frame: { event: work, phase_elapsed: 2.1, phase_remaining: 7.9 },
});
assert.deepEqual(result.commands, [{ type: "playRepBeep" }]);

result = segmentTransition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 3.1, phase_remaining: 1.9 },
});
assert.deepEqual(result.commands, [{ type: "playLeadBeep" }]);

result = segmentTransition(initialSegmentState(), {
	type: "BEEP_FRAME",
	frame: { event: warmupRest, phase_elapsed: 3.1, phase_remaining: 1.9 },
});
assert.deepEqual(result.commands, [{ type: "playLeadBeep" }]);

result = segmentTransition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 4.1, phase_remaining: 0.9 },
});
assert.deepEqual(result.commands, [{ type: "playLeadBeep" }]);

result = segmentTransition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 5, phase_remaining: 0 },
});
assert.deepEqual(result.commands, [{ type: "playRepBeep" }]);

result = segmentTransition(
	{
		...initialSegmentState(),
		mode: "running",
		clock: { ...initialSegmentState().clock, totalDurationSec: 15 },
		reps: {
			currentEventKey: "0:work_burpee:Block 1",
			doneInEvent: 5,
			burpeeCountDone: 5,
			previousFrame: { event: work, index: 0 },
		},
	},
	{ type: "FINISH_EARLY", elapsedSec: 7 },
);
assert.equal(result.state.mode, "done");
assert.deepEqual(result.commands.at(-1), {
	type: "segmentDone",
	result: { burpeeCountDone: 5, durationSec: 7 },
});

result = segmentTransition(
	{
		...initialSegmentState(),
		mode: "running",
		clock: { ...initialSegmentState().clock, totalDurationSec: 15 },
		reps: {
			currentEventKey: "0:work_burpee:Block 1",
			doneInEvent: 5,
			burpeeCountDone: 5,
			previousFrame: { event: work, index: 0 },
		},
	},
	{ type: "TICK", elapsedSec: 15 },
);
assert.equal(result.state.mode, "done");
assert.deepEqual(result.commands.at(-1), {
	type: "segmentDone",
	result: { burpeeCountDone: 5, durationSec: 15 },
});

console.log("session_segment_fsm tests passed");
