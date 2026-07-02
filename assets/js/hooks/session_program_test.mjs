import assert from "node:assert/strict";
import {
	programBurpeeCount,
	setBarsFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";

const program = {
	program_id: 7,
	program_hash: "abc",
	target_reps: 20,
	target_duration_sec: 300,
	events: [
		{
			id: "work-001",
			kind: "work",
			reps: 10,
			sec_per_rep: 12,
			label: "Set 1",
		},
		{ id: "rest-001", kind: "rest", duration_sec: 60, label: "Rest" },
		{
			id: "work-002",
			kind: "work",
			reps: 10,
			sec_per_rep: 12,
			label: "Set 2",
		},
	],
};

assert.deepEqual(workoutTimelineFromProgram(program), program.events);
assert.equal(programBurpeeCount(program), 20);
assert.deepEqual(setBarsFromProgram(program), [
	{ id: "work-001", index: 1, reps: 10, label: "Set 1" },
	{ id: "work-002", index: 2, reps: 10, label: "Set 2" },
]);

console.log("session_program tests passed");
