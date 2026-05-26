import assert from "node:assert/strict";
import {
  accountReps,
  currentFrame,
  initialSessionState,
  transition,
} from "./session_fsm.mjs";

const warmup = { type: "warmup_burpee", duration_sec: 10, burpee_count: 5, label: "Warmup" };
const work = { type: "work_burpee", duration_sec: 10, burpee_count: 5, label: "Block 1" };
const rest = { type: "work_rest", duration_sec: 5, burpee_count: 0, label: "Rest" };

assert.deepEqual(currentFrame([work, rest], 2), {
  event: work,
  index: 0,
  phase_elapsed: 2,
  phase_remaining: 8,
});

assert.equal(currentFrame([work], 10), null);

let reps = { currentEventKey: "0:warmup_burpee:Warmup", doneInEvent: 4, mainDone: 0, warmupDone: 4 };
reps = accountReps({ event: warmup, index: 0 }, { event: rest, index: 1 }, reps);
assert.equal(reps.warmupDone, 5);
assert.equal(reps.mainDone, 0);

reps = { currentEventKey: "0:work_burpee:Block 1", doneInEvent: 4, mainDone: 4, warmupDone: 0 };
reps = accountReps({ event: work, index: 0 }, { event: rest, index: 1 }, reps);
assert.equal(reps.mainDone, 5);

reps = { currentEventKey: "0:work_burpee:Block 1", doneInEvent: 4, mainDone: 4, warmupDone: 0 };
reps = accountReps({ event: work, index: 0 }, null, reps);
assert.equal(reps.mainDone, 5);

let result = transition(initialSessionState(), {
  type: "SESSION_READY",
  timeline: [work],
  blockCount: 1,
});
assert.equal(result.state.mode, "warmup_prompt");
assert.equal(result.state.mainTimeline.length, 1);

result = transition(result.state, { type: "WARMUP_SKIP" });
assert.equal(result.state.mode, "mood_prompt");
assert.deepEqual(result.state.timeline, [work]);

result = transition(result.state, { type: "MOOD_SELECTED", mood: "0", now: 1000 });
assert.equal(result.state.mode, "countdown");
assert.deepEqual(result.commands, [
  { type: "pushSessionStarted", mood: "0" },
  { type: "startCountdownTimer" },
]);

result = transition(initialSessionState(), {
  type: "SESSION_READY",
  timeline: [work],
  blockCount: 1,
});
result = transition(result.state, { type: "WARMUP_READY", warmup: [warmup] });
assert.equal(result.state.mode, "mood_prompt");
assert.deepEqual(result.state.timeline, [warmup, work]);

console.log("session_fsm tests passed");
