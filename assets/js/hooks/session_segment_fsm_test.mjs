import test from "node:test";
import assert from "node:assert/strict";
import {
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
