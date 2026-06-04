import assert from "node:assert/strict";
import {
	timelineBurpeeCount,
	warmupTimelineFromPlan,
	workoutTimelineFromPlan,
} from "./session_plan.mjs";

const plan = {
	sec_per_burpee: 5.5,
	blocks: [
		{
			position: 1,
			repeat_count: 1,
			sets: [
				{
					position: 2,
					burpee_count: 7,
					sec_per_rep: 6,
					sec_per_burpee: 6,
					end_of_set_rest: 0,
				},
				{
					position: 1,
					burpee_count: 10,
					sec_per_rep: 6,
					sec_per_burpee: 6,
					end_of_set_rest: 30,
				},
			],
		},
	],
};

const warmup = warmupTimelineFromPlan(plan);
assert.deepEqual(
	warmup.map((event) => event.phase),
	["work", "rest", "work", "rest"],
);
assert.equal(timelineBurpeeCount(warmup), 20);
assert.equal(warmup[0].duration_sec, 55);
assert.equal(warmup[2].duration_sec, 55);

const workout = workoutTimelineFromPlan(plan);
assert.deepEqual(
	workout.map((event) => event.phase),
	["work", "rest", "work"],
);
assert.equal(timelineBurpeeCount(workout), 17);
assert.equal(workout[0].burpee_count, 10);
assert.equal(workout[2].burpee_count, 7);

console.log("session_plan tests passed");
