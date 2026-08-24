import test from "node:test";
import assert from "node:assert/strict";
import {
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";

function restFrame(remaining) {
	return {
		event: { kind: "rest", duration_sec: 30 },
		phase_elapsed: 30 - remaining,
		phase_remaining: remaining,
		index: 1,
	};
}

test("between-set countdown emits one lead beep for 3, 2, and 1", () => {
	let state = initialSegmentState();

	for (const remaining of [3, 2, 1]) {
		const first = segmentTransition(state, {
			type: "BEEP_FRAME",
			frame: restFrame(remaining),
		});
		assert.deepEqual(first.commands, [{ type: "playLeadBeep" }]);
		state = first.state;

		const duplicate = segmentTransition(state, {
			type: "BEEP_FRAME",
			frame: restFrame(remaining - 0.2),
		});
		assert.deepEqual(duplicate.commands, []);
		state = duplicate.state;
	}
});

test("rest does not emit countdown beeps before three seconds", () => {
	const result = segmentTransition(initialSegmentState(), {
		type: "BEEP_FRAME",
		frame: restFrame(4),
	});

	assert.deepEqual(result.commands, []);
});

test("resume excludes overlapping hidden and paused time exactly once", () => {
	const running = {
		...initialSegmentState(),
		mode: "running",
		clock: {
			...initialSegmentState().clock,
			startTime: 100,
		},
	};
	const hidden = segmentTransition(running, {
		type: "VISIBILITY_HIDDEN",
		now: 500,
	}).state;
	const paused = segmentTransition(hidden, { type: "PAUSE", now: 700 }).state;

	const resumed = segmentTransition(paused, { type: "RESUME", now: 1_000 });

	assert.equal(resumed.state.mode, "running");
	assert.deepEqual(resumed.state.clock, {
		...running.clock,
		startTime: 600,
		pauseTime: null,
		hiddenAt: null,
	});
	assert.deepEqual(resumed.commands, [{ type: "startAnimationFrame" }]);
});

test("natural completion clamps a delayed animation tick to timeline duration", () => {
	const timeline = [{ kind: "work", reps: 3, sec_per_rep: 20 }];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 3,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_START", now: 1 }).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 1 }).state;

	const completed = segmentTransition(state, { type: "TICK", elapsedSec: 170 });
	const done = completed.commands.find(
		(command) => command.type === "segmentDone",
	);
	const rendered = completed.commands.find(
		(command) => command.type === "renderRunningFrame",
	);

	assert.equal(completed.state.clock.elapsedSec, 60);
	assert.equal(rendered.elapsedSec, 60);
	assert.deepEqual(done.result, {
		burpeeCountDone: 3,
		scheduledRepsDone: 3,
		durationSec: 60,
	});
});

test("active completion advances pace progress before rest and final active ends the segment", () => {
	const timeline = [
		{ kind: "work", reps: 1, sec_per_rep: 10 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 1, sec_per_rep: 10 },
	];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 2,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	state = segmentTransition(state, { type: "TICK", elapsedSec: 10 }).state;
	assert.equal(state.reps.burpeeCountDone, 1);

	state = segmentTransition(state, { type: "TICK", elapsedSec: 14.9 }).state;
	assert.equal(state.reps.burpeeCountDone, 1);

	const complete = segmentTransition(state, { type: "TICK", elapsedSec: 25 });
	const done = complete.commands.find((command) => command.type === "segmentDone");
	assert.deepEqual(done.result, {
		burpeeCountDone: 2,
		scheduledRepsDone: 2,
		durationSec: 25,
	});
});

test("finishing before the first active tick does not count scheduled work", () => {
	const timeline = [{ kind: "work", reps: 3, sec_per_rep: 20 }];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 3,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;
	state = segmentTransition(state, { type: "PAUSE", now: 0 }).state;

	const finished = segmentTransition(state, {
		type: "FINISH_EARLY",
		elapsedSec: 0,
	});
	const done = finished.commands.find((command) => command.type === "segmentDone");

	assert.equal(finished.state.reps.burpeeCountDone, 0);
	assert.equal(done.result.scheduledRepsDone, 0);
});

test("finishing early at five seconds does not credit a partial active interval", () => {
	const timeline = [{ kind: "work", reps: 3, sec_per_rep: 20 }];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 3,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	const finished = segmentTransition(state, {
		type: "FINISH_EARLY",
		elapsedSec: 5,
	});
	const done = finished.commands.find((command) => command.type === "segmentDone");

	assert.equal(finished.state.reps.burpeeCountDone, 0);
	assert.equal(done.result.scheduledRepsDone, 0);
});

test("finishing early at 25 seconds credits one completed active interval", () => {
	const timeline = [{ kind: "work", reps: 3, sec_per_rep: 20 }];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 3,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	const finished = segmentTransition(state, {
		type: "FINISH_EARLY",
		elapsedSec: 25,
	});
	const done = finished.commands.find((command) => command.type === "segmentDone");

	assert.equal(finished.state.reps.burpeeCountDone, 1);
	assert.equal(done.result.scheduledRepsDone, 1);
});

test("finishing early during rest credits completed work but not rest", () => {
	const timeline = [
		{ kind: "work", reps: 3, sec_per_rep: 20 },
		{ kind: "rest", duration_sec: 20 },
		{ kind: "work", reps: 1, sec_per_rep: 20 },
	];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 4,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	const finished = segmentTransition(state, {
		type: "FINISH_EARLY",
		elapsedSec: 65,
	});
	const done = finished.commands.find((command) => command.type === "segmentDone");

	assert.equal(finished.state.reps.burpeeCountDone, 3);
	assert.equal(done.result.scheduledRepsDone, 3);
});

test("explicit work duration credits reps at active ends and finishes at terminal active end", () => {
	const timeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 20 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 13 },
	];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 4,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	for (const [elapsedSec, expected] of [
		[2.999, 0],
		[3, 1],
		[10, 1],
		[13, 2],
		[20, 2],
		[24.999, 2],
		[25, 2],
		[27.999, 2],
		[28, 3],
		[37.999, 3],
	]) {
		state = segmentTransition(state, { type: "TICK", elapsedSec }).state;
		assert.equal(state.reps.burpeeCountDone, expected, `at ${elapsedSec}s`);
	}

	const lastInWorkFrame = currentFrame(timeline, 37.999);
	assert.equal(lastInWorkFrame.event, timeline[2]);
	assert.ok(Math.abs(lastInWorkFrame.phase_elapsed - 12.999) < 1e-9);
	assert.equal(currentFrame(timeline, 38), null);

	const complete = segmentTransition(state, { type: "TICK", elapsedSec: 38 });
	const done = complete.commands.filter((command) => command.type === "segmentDone");
	assert.equal(complete.state.reps.burpeeCountDone, 4);
	assert.deepEqual(done, [
		{
			type: "segmentDone",
			result: { burpeeCountDone: 4, scheduledRepsDone: 4, durationSec: 38 },
		},
	]);
});

test("delayed ticks and early finish credit only completed active portions", () => {
	const timeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 20 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 13 },
	];
	const runningState = () => {
		const state = segmentTransition(initialSegmentState(), {
			type: "SEGMENT_READY",
			timeline,
			burpeeCountTarget: 4,
		}).state;
		return segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;
	};

	let delayed = segmentTransition(runningState(), { type: "TICK", elapsedSec: 28.1 });
	delayed = segmentTransition(delayed.state, {
		type: "ACCOUNT_REPS",
		frame: currentFrame(timeline, 28.1),
	});
	assert.equal(delayed.state.reps.burpeeCountDone, 3);
	delayed = segmentTransition(delayed.state, { type: "TICK", elapsedSec: 38.1 });
	assert.deepEqual(
		delayed.commands.filter((command) => command.type === "segmentDone"),
		[
			{
				type: "segmentDone",
				result: { burpeeCountDone: 4, scheduledRepsDone: 4, durationSec: 38 },
			},
		],
	);

	for (const [elapsedSec, expected] of [
		[2.999, 0],
		[5, 1],
		[37, 3],
		[38, 4],
	]) {
		const finished = segmentTransition(runningState(), {
			type: "FINISH_EARLY",
			elapsedSec,
		});
		const done = finished.commands.find((command) => command.type === "segmentDone");
		assert.equal(done.result.scheduledRepsDone, expected, `finish at ${elapsedSec}s`);
	}
});

test("delayed ticks derive scheduled progress from all elapsed work while preserving the current frame", () => {
	const timeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
		{ kind: "rest", duration_sec: 5 },
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3 },
	];
	let state = segmentTransition(initialSegmentState(), {
		type: "SEGMENT_READY",
		timeline,
		burpeeCountTarget: 6,
	}).state;
	state = segmentTransition(state, { type: "COUNTDOWN_DONE", now: 0 }).state;

	const delayed = segmentTransition(state, { type: "TICK", elapsedSec: 53 });
	const frame = currentFrame(timeline, 53);
	const display = segmentTransition(delayed.state, {
		type: "DISPLAY_FRAME",
		frame,
		elapsedSec: 53,
	});

	assert.equal(delayed.state.reps.burpeeCountDone, 5);
	assert.equal(frame.index, 4);
	assert.equal(frame.phase_elapsed, 3);
	assert.deepEqual(
		display.commands.find((command) => command.type === "renderWorkRepProgress"),
		{ type: "renderWorkRepProgress", progress: 0.3 },
	);
});

test("short explicit work durations never fabricate scheduled reps on departure or finish", () => {
	const timeline = [
		{ kind: "work", reps: 2, sec_per_rep: 10, sec_per_burpee: 3, duration_sec: 12 },
	];
	const runningState = () => {
		const ready = segmentTransition(initialSegmentState(), {
			type: "SEGMENT_READY",
			timeline,
			burpeeCountTarget: 2,
		}).state;
		return segmentTransition(ready, { type: "COUNTDOWN_DONE", now: 0 }).state;
	};

	const completed = segmentTransition(runningState(), { type: "TICK", elapsedSec: 12 });
	const naturallyDone = completed.commands.find(
		(command) => command.type === "segmentDone",
	);
	assert.equal(naturallyDone.result.scheduledRepsDone, 1);

	const finished = segmentTransition(runningState(), {
		type: "FINISH_EARLY",
		elapsedSec: 12,
	});
	const earlyDone = finished.commands.find((command) => command.type === "segmentDone");
	assert.equal(earlyDone.result.scheduledRepsDone, 1);
});

test("pause-only and visibility-only recovery retain their clock shifts", () => {
	const running = {
		...initialSegmentState(),
		mode: "running",
		clock: {
			...initialSegmentState().clock,
			startTime: 100,
		},
	};

	const paused = segmentTransition(running, { type: "PAUSE", now: 500 }).state;
	const pauseResumed = segmentTransition(paused, {
		type: "RESUME",
		now: 800,
	}).state;
	assert.equal(pauseResumed.clock.startTime, 400);
	assert.equal(pauseResumed.clock.pauseTime, null);
	assert.equal(pauseResumed.clock.hiddenAt, null);

	const hidden = segmentTransition(running, {
		type: "VISIBILITY_HIDDEN",
		now: 500,
	}).state;
	const visible = segmentTransition(hidden, {
		type: "VISIBILITY_VISIBLE",
		now: 800,
	}).state;
	assert.equal(visible.clock.startTime, 400);
	assert.equal(visible.clock.pauseTime, null);
	assert.equal(visible.clock.hiddenAt, null);
});
