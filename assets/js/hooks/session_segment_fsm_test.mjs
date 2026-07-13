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
