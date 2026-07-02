import assert from "node:assert/strict";
import {
	programBurpeeCount,
	setBarsFromProgram,
	warmupTimelineFromProgram,
	workoutTimelineFromProgram,
} from "./session_plan.mjs";

const program = {
	program_id: 7,
	program_hash: "abc",
	target_reps: 17,
	target_duration_sec: 132,
	events: [
		{
			id: "work-001",
			kind: "work",
			phase: "work",
			set_index: 1,
			reps: 10,
			burpee_count: 10,
			duration_sec: 60,
			sec_per_rep: 6,
			sec_per_burpee: 6,
			label: "Set 1",
		},
		{
			id: "rest-001",
			kind: "rest",
			phase: "rest",
			duration_sec: 30,
			burpee_count: null,
			sec_per_burpee: null,
			label: "Rest",
		},
		{
			id: "work-002",
			kind: "work",
			phase: "work",
			set_index: 2,
			reps: 7,
			burpee_count: 7,
			duration_sec: 42,
			sec_per_rep: 6,
			sec_per_burpee: 6,
			label: "Set 2",
		},
	],
};

const warmup = warmupTimelineFromProgram(program);
assert.deepEqual(
	warmup.map((event) => event.kind),
	["work", "rest", "work", "rest"],
);
assert.equal(programBurpeeCount(warmup), 20);
assert.equal(warmup[0].duration_sec, 60);
assert.equal(warmup[2].duration_sec, 60);

const workout = workoutTimelineFromProgram(program);
assert.deepEqual(workout, program.events);
assert.equal(programBurpeeCount(workout), 17);
assert.equal(workout[0].reps, 10);
assert.equal(workout[2].reps, 7);
assert.deepEqual(setBarsFromProgram(program), [
	{ id: "work-001", index: 1, reps: 10, label: "Set 1" },
	{ id: "work-002", index: 2, reps: 7, label: "Set 2" },
]);

const pureKindProgram = {
	events: [
		{
			id: "work-a",
			kind: "work",
			set_index: 1,
			reps: 5,
			duration_sec: 50,
			sec_per_rep: 10,
		},
		{ id: "rest-a", kind: "rest", duration_sec: 10 },
	],
};

assert.equal(programBurpeeCount(pureKindProgram), 5);
assert.equal(warmupTimelineFromProgram(pureKindProgram)[0].burpee_count, 5);
assert.deepEqual(workoutTimelineFromProgram({ blocks: [{ sets: [] }] }), []);

console.log("session_plan tests passed");
