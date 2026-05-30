import assert from "node:assert/strict";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";

const workoutTimeline = [
	{ type: "work_burpee", duration_sec: 10, burpee_count: 5, label: "Block 1" },
];
const warmupTimeline = [
	{ type: "warmup_burpee", duration_sec: 6, burpee_count: 3, label: "Warmup" },
];

let result = flowTransition(initialFlowState(), {
	type: "SESSION_READY",
	workoutTimeline,
	blockCount: 1,
});
assert.equal(result.state.mode, "warmup_prompt");
assert.deepEqual(result.commands, [{ type: "renderPrompt" }]);

result = flowTransition(result.state, { type: "WARMUP_SKIP" });
assert.equal(result.state.mode, "capture_prompt");
assert.deepEqual(result.commands, [{ type: "showCapturePrompt" }]);

result = flowTransition(result.state, { type: "CAPTURE_TIMED" });
assert.equal(result.state.captureMode, "timed");
assert.deepEqual(result.commands, []);

result = flowTransition(result.state, { type: "WORKOUT_READY" });
assert.equal(result.state.mode, "workout_countdown");
assert.deepEqual(result.commands, [
	{
		type: "startSegment",
		segment: "workout",
		timeline: workoutTimeline,
		blockCount: 1,
	},
]);

result = flowTransition(initialFlowState(), {
	type: "SESSION_READY",
	workoutTimeline,
	blockCount: 1,
});
result = flowTransition(result.state, {
	type: "WARMUP_READY",
	warmupTimeline,
	burpeeCountTarget: 6,
});
assert.equal(result.state.mode, "warmup_countdown");
assert.deepEqual(result.commands, [
	{
		type: "startSegment",
		segment: "warmup",
		timeline: warmupTimeline,
		blockCount: 1,
		burpeeCountTarget: 6,
	},
]);

result = flowTransition(result.state, {
	type: "SEGMENT_DONE",
	segment: "warmup",
	result: { burpeeCountDone: 3, durationSec: 6 },
});
assert.equal(result.state.mode, "capture_prompt");
assert.deepEqual(result.commands, [{ type: "showCapturePrompt" }]);

result = flowTransition(result.state, { type: "CAPTURE_TRACKED" });
assert.equal(result.state.captureMode, "tracked");
assert.deepEqual(result.commands, [{ type: "chooseTrackedCapture" }]);

result = flowTransition(result.state, { type: "WORKOUT_READY" });
assert.equal(result.state.mode, "workout_countdown");
assert.deepEqual(result.commands, [
	{
		type: "startSegment",
		segment: "workout",
		timeline: workoutTimeline,
		blockCount: 1,
	},
]);

result = flowTransition(result.state, {
	type: "SEGMENT_DONE",
	segment: "workout",
	result: { burpeeCountDone: 5, durationSec: 10 },
});
assert.equal(result.state.mode, "workout_done");
assert.deepEqual(result.commands, [
	{
		type: "pushSessionComplete",
		payload: {
			warmup: { burpee_count_done: 3, duration_sec: 6 },
			main: { burpee_count_done: 5, duration_sec: 10 },
		},
	},
]);

console.log("session_flow_fsm tests passed");
