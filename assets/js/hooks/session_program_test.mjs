import assert from "node:assert/strict";
import {
	programBurpeeCount,
	warmupTimelineFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";

const program = {
	program_id: 7,
	program_hash: "abc",
	target_reps: 20,
	target_duration_sec: 300,
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

assert.deepEqual(workoutTimelineFromProgram(program), program.events);
assert.equal(programBurpeeCount(program), 20);
assert.equal(warmupTimelineFromProgram(program)[0].sec_per_burpee, 5);

console.log("session_program tests passed");
