import assert from "node:assert/strict";
import {
	accountReps,
	currentFrame,
	initialSessionState,
	transition,
} from "./session_fsm.mjs";

const warmup = {
	type: "warmup_burpee",
	duration_sec: 10,
	burpee_count: 5,
	label: "Warmup",
};
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

assert.deepEqual(currentFrame([work, rest], 2), {
	event: work,
	index: 0,
	phase_elapsed: 2,
	phase_remaining: 8,
});

assert.equal(currentFrame([work], 10), null);

let reps = {
	currentEventKey: "0:warmup_burpee:Warmup",
	doneInEvent: 4,
	mainDone: 0,
	warmupDone: 4,
};
reps = accountReps(
	{ event: warmup, index: 0 },
	{ event: rest, index: 1 },
	reps,
);
assert.equal(reps.warmupDone, 5);
assert.equal(reps.mainDone, 0);

reps = {
	currentEventKey: "0:work_burpee:Block 1",
	doneInEvent: 4,
	mainDone: 4,
	warmupDone: 0,
};
reps = accountReps({ event: work, index: 0 }, { event: rest, index: 1 }, reps);
assert.equal(reps.mainDone, 5);

reps = {
	currentEventKey: "0:work_burpee:Block 1",
	doneInEvent: 4,
	mainDone: 4,
	warmupDone: 0,
};
reps = accountReps({ event: work, index: 0 }, null, reps);
assert.equal(reps.mainDone, 5);

let result = transition(initialSessionState(), {
	type: "SESSION_READY",
	timeline: [work],
	blockCount: 1,
});
assert.equal(result.state.mode, "warmup_prompt");
assert.equal(result.state.mainTimeline.length, 1);

result = transition(result.state, { type: "WARMUP_SKIP" });
assert.equal(result.state.mode, "mood_prompt");
assert.deepEqual(result.state.timeline, [work]);

result = transition(result.state, {
	type: "MOOD_SELECTED",
	mood: "0",
	now: 1000,
});
assert.equal(result.state.mode, "countdown");
assert.deepEqual(result.commands, [
	{ type: "pushSessionStarted", mood: "0" },
	{ type: "startCountdownTimer" },
]);

result = transition(initialSessionState(), {
	type: "SESSION_READY",
	timeline: [work],
	blockCount: 1,
});
result = transition(result.state, { type: "WARMUP_READY", warmup: [warmup] });
assert.equal(result.state.mode, "mood_prompt");
assert.deepEqual(result.state.timeline, [warmup, work]);

result = transition(result.state, {
	type: "MOOD_SELECTED",
	mood: "1",
	now: 1000,
});
result = transition(result.state, { type: "COUNTDOWN_PAUSE", now: 1250 });
assert.equal(result.state.mode, "countdown_paused");
assert.equal(result.state.countdown.stepElapsedMs, 250);
assert.deepEqual(result.commands, [{ type: "pauseCountdownTimer" }]);

result = transition(result.state, { type: "COUNTDOWN_RESUME", now: 2000 });
assert.equal(result.state.mode, "countdown");
assert.equal(result.state.countdown.stepStartedAt, 2000);
assert.deepEqual(result.commands, [
	{ type: "resumeCountdownTimer", remainingMs: 750 },
]);

result = transition(result.state, {
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

result = transition(result.state, {
	type: "COUNTDOWN_TICK",
	value: 0,
	now: 5100,
});
assert.equal(result.state.countdown.value, null);
assert.deepEqual(result.commands, [
	{ type: "clearCountdown" },
	{ type: "beginSession" },
]);

result = transition(result.state, { type: "COUNTDOWN_DONE", now: 3000 });
assert.equal(result.state.mode, "running");
result = transition(result.state, { type: "PAUSE", now: 3500 });
assert.equal(result.state.mode, "paused");
assert.equal(result.state.clock.pauseTime, 3500);
assert.deepEqual(result.commands, [{ type: "cancelAnimationFrame" }]);

result = transition(result.state, { type: "RESUME", now: 5000 });
assert.equal(result.state.mode, "running");
assert.equal(result.state.clock.startTime, 4500);
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = transition(result.state, { type: "VISIBILITY_HIDDEN", now: 6000 });
assert.equal(result.state.clock.hiddenAt, 6000);
assert.deepEqual(result.commands, [{ type: "cancelAnimationFrame" }]);

result = transition(result.state, { type: "VISIBILITY_VISIBLE", now: 8000 });
assert.equal(result.state.clock.hiddenAt, null);
assert.equal(result.state.clock.startTime, 6500);
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = transition(result.state, { type: "TICK", elapsedSec: 2 });
assert.deepEqual(result.commands, [
	{ type: "renderRunningFrame", elapsedSec: 2 },
	{ type: "scheduleAnimationFrame" },
]);

result = transition(result.state, { type: "TICK", elapsedSec: 20 });
assert.equal(result.state.mode, "completed");
assert.deepEqual(result.commands, [
	{ type: "renderRunningFrame", elapsedSec: 20 },
	{ type: "completeWorkout", elapsedSec: 20 },
]);

result = transition(result.state, { type: "FINISH_EARLY", elapsedSec: 7 });
assert.equal(result.state.mode, "completed");
assert.deepEqual(result.commands, [{ type: "completeWorkout", elapsedSec: 7 }]);

const beepState = {
	...result.state,
	mode: "running",
	beeps: { lastRepIndex: -1, lastRestCount: null },
};

result = transition(beepState, {
	type: "BEEP_FRAME",
	frame: { event: work, phase_elapsed: 2.1, phase_remaining: 7.9 },
});
assert.equal(result.state.beeps.lastRepIndex, 1);
assert.deepEqual(result.commands, [{ type: "playRepBeep" }]);

result = transition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: work, phase_elapsed: 2.2, phase_remaining: 7.8 },
});
assert.deepEqual(result.commands, []);

result = transition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 3.1, phase_remaining: 1.9 },
});
assert.equal(result.state.beeps.lastRestCount, 2);
assert.deepEqual(result.commands, [{ type: "playLeadBeep" }]);

result = transition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 4.1, phase_remaining: 0.9 },
});
assert.equal(result.state.beeps.lastRestCount, 1);
assert.deepEqual(result.commands, [{ type: "playLeadBeep" }]);

result = transition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: rest, phase_elapsed: 5, phase_remaining: 0 },
});
assert.equal(result.state.beeps.lastRestCount, 0);
assert.deepEqual(result.commands, [{ type: "playRepBeep" }]);

let repState = {
	...initialSessionState(),
	reps: {
		currentEventKey: "0:warmup_burpee:Warmup",
		doneInEvent: 4,
		mainDone: 0,
		warmupDone: 4,
		previousFrame: { event: warmup, index: 0 },
	},
};

result = transition(repState, {
	type: "ACCOUNT_REPS",
	frame: { event: rest, index: 1 },
});
assert.equal(result.state.reps.warmupDone, 5);
assert.equal(result.state.reps.mainDone, 0);
assert.deepEqual(result.commands, [{ type: "updateVisibleRepTotal", mainDone: 0 }]);

repState = {
	...initialSessionState(),
	reps: {
		currentEventKey: "0:work_burpee:Block 1",
		doneInEvent: 4,
		mainDone: 4,
		warmupDone: 0,
		previousFrame: { event: work, index: 0 },
	},
};

result = transition(repState, { type: "ACCOUNT_REPS", frame: null });
assert.equal(result.state.reps.mainDone, 5);
assert.deepEqual(result.commands, [{ type: "updateVisibleRepTotal", mainDone: 5 }]);

console.log("session_fsm tests passed");
