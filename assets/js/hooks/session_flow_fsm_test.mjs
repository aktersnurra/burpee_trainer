import assert from "node:assert/strict";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";

const workoutTimeline = [
	{ kind: "work", reps: 5, sec_per_rep: 2 },
];
const warmupTimeline = [
	{ kind: "work", reps: 3, sec_per_rep: 2 },
];

let result = flowTransition(initialFlowState(), {
	type: "SESSION_READY",
	workoutTimeline,
	blockCount: 1,
});
assert.equal(result.state.mode, "capture_prompt");
assert.deepEqual(result.commands, [{ type: "showCapturePrompt" }]);

result = flowTransition(result.state, { type: "CAPTURE_TIMED" });
assert.equal(result.state.captureMode, "timed");
assert.equal(result.state.mode, "warmup_prompt");
assert.deepEqual(result.commands, [{ type: "renderPrompt" }]);

result = flowTransition(result.state, { type: "WARMUP_SKIP" });
assert.equal(result.state.mode, "workout_ready_prompt");
assert.deepEqual(result.commands, [{ type: "showWorkoutReadyPrompt" }]);

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
result = flowTransition(result.state, { type: "CAPTURE_TRACKED" });
assert.equal(result.state.captureMode, "tracked");
assert.equal(result.state.mode, "camera_setup");
assert.deepEqual(result.commands, [
	{ type: "chooseTrackedCapture" },
	{ type: "showCameraSetupPrompt" },
]);

result = flowTransition(result.state, { type: "CAMERA_SETUP_READY" });
assert.equal(result.state.mode, "warmup_prompt");
assert.deepEqual(result.commands, [{ type: "renderPrompt" }]);

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
assert.equal(result.state.mode, "workout_ready_prompt");
assert.deepEqual(result.commands, [{ type: "showWarmupDonePrompt" }]);

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
