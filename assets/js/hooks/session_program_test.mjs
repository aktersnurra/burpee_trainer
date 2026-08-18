import assert from "node:assert/strict";
import {
	programBurpeeCount,
	warmupTimelineFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";

const sourceV2Payload = {
	program_id: 7,
	program_hash: "abc",
	target_reps: 20,
	target_duration_sec: 300,
	display: {},
	events: [
		{
			kind: "work",
			reps: 10,
			sec_per_rep: 12,
			sec_per_burpee: 5,
		},
		{ kind: "rest", duration_sec: 60 },
		{
			kind: "work",
			reps: 10,
			sec_per_rep: 12,
			sec_per_burpee: 5,
		},
	],
};

const legacyEvenProgram = {
	program_id: 8,
	program_hash: "legacy",
	target_reps: 10,
	target_duration_sec: 120,
	events: [{ kind: "work", reps: 10, sec_per_rep: 12, sec_per_burpee: 12 }],
};

assert.deepEqual(
	workoutTimelineFromProgram(sourceV2Payload),
	sourceV2Payload.events,
);
assert.equal(programBurpeeCount(sourceV2Payload), sourceV2Payload.target_reps);
assert.equal(warmupTimelineFromProgram(sourceV2Payload)[0].sec_per_burpee, 5);
assert.deepEqual(
	workoutTimelineFromProgram(legacyEvenProgram),
	legacyEvenProgram.events,
);
assert.equal(programBurpeeCount(legacyEvenProgram), 10);
assert.equal(workoutTimelineFromProgram(legacyEvenProgram).length, 1);
assert.equal(workoutTimelineFromProgram(sourceV2Payload).length, 3);

console.log("session_program tests passed");
