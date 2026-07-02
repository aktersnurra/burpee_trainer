import assert from "node:assert/strict";
import {
	programBurpeeCount,
	setBarsFromProgram,
	warmupTimelineFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";
import { eventDurationSec } from "./session_segment_fsm.mjs";

const program = {
	program_id: 7,
	program_hash: "abc",
	target_reps: 17,
	target_duration_sec: 132,
	events: [
		{
			kind: "work",
			reps: 10,
			sec_per_rep: 6,
		},
		{
			kind: "rest",
			duration_sec: 30,
		},
		{
			kind: "work",
			reps: 7,
			sec_per_rep: 6,
		},
	],
};

const warmup = warmupTimelineFromProgram(program);
assert.deepEqual(
	warmup.map((event) => event.kind),
	["work", "rest", "work", "rest"],
);
assert.equal(programBurpeeCount(warmup), 20);
assert.equal(eventDurationSec(warmup[0]), 60);
assert.equal(eventDurationSec(warmup[2]), 60);

const workout = workoutTimelineFromProgram(program);
assert.deepEqual(workout, program.events);
assert.equal(programBurpeeCount(workout), 17);
assert.equal(workout[0].reps, 10);
assert.equal(workout[2].reps, 7);
assert.deepEqual(setBarsFromProgram(program), [
	{ id: "work-1", index: 1, reps: 10, label: "Set 1" },
	{ id: "work-2", index: 2, reps: 7, label: "Set 2" },
]);

const pureKindProgram = {
	events: [
		{
			kind: "work",
			reps: 5,
			sec_per_rep: 10,
		},
		{ kind: "rest", duration_sec: 10 },
	],
};

assert.equal(programBurpeeCount(pureKindProgram), 5);
assert.equal(warmupTimelineFromProgram(pureKindProgram)[0].reps, 5);
assert.deepEqual(workoutTimelineFromProgram({ blocks: [{ sets: [] }] }), []);

console.log("session_plan tests passed");
