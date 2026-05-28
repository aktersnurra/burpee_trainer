# Session Segment Flow FSM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status note (2026-05-28):** This historical plan predates the client-owned runner boundary. Current implementation derives warmup/workout timelines in `assets/js/hooks/session_plan.mjs`; Phoenix no longer serves `warmup_requested`/`warmup_ready` timeline events.

**Goal:** Split the runner into a generic segment FSM and a session flow FSM so warmup and workout run through the same segment machine with different orchestration outcomes.

**Architecture:** `session_segment_fsm.mjs` owns one runnable segment and emits `segmentDone`. `session_flow_fsm.mjs` owns warmup/workout orchestration and emits session-specific commands. `session_hook.js` routes browser/server events and commands without calculating segment meaning.

**Tech Stack:** Phoenix LiveView, JavaScript ES modules, Node-based reducer tests, existing `SessionRenderer`, `SessionAudio`, and `SessionWakeLock` adapters.

---

## File map

- Create: `assets/js/hooks/session_segment_fsm.mjs`
  - Generic FSM for one segment timeline.
  - Contains current generic helpers from `session_fsm.mjs`: `currentFrame`, `eventKey`, `accountReps`, display command derivation, beep command derivation, countdown/running/pause transitions.
  - Emits `segmentDone` with `{burpeeCountDone, durationSec}`.

- Create: `assets/js/hooks/session_segment_fsm_test.mjs`
  - Unit tests for the generic segment FSM.

- Create: `assets/js/hooks/session_flow_fsm.mjs`
  - Session orchestration FSM for warmup prompt, warmup segment, workout ready prompt, workout segment, and final save payload.

- Create: `assets/js/hooks/session_flow_fsm_test.mjs`
  - Unit tests for flow-level orchestration.

- Modify: `assets/js/hooks/session_fsm_test.mjs`
  - Replace with an aggregator that imports and runs both new test files, or update `assets/package.json` to run both directly.

- Modify: `assets/package.json`
  - Keep `npm --prefix assets test` as the single asset test command.

- Modify: `assets/js/hooks/session_hook.js`
  - Instantiate flow FSM and segment FSM.
  - Route flow commands and segment commands separately.
  - Add “Ready for workout?” overlay action.

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
  - Keep payload parsing unchanged.
  - No schema or persistence changes.

- Modify: `test/burpee_trainer_web/live/session_live_test.exs`
  - Keep existing LiveView contract tests passing.
  - Add/adjust only if hook/server event payloads change.

---

### Task 1: Extract generic segment FSM tests

**Files:**

- Create: `assets/js/hooks/session_segment_fsm_test.mjs`
- Modify: `assets/package.json`

- [ ] **Step 1: Create failing segment FSM test file**

Create `assets/js/hooks/session_segment_fsm_test.mjs` with the following initial content:

```js
import assert from "node:assert/strict";
import {
	accountReps,
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";

const work = {
	type: "work_burpee",
	duration_sec: 10,
	burpee_count: 5,
	label: "Block 1",
};

const rest = {
	type: "work_rest",
	duration_sec: 5,
	burpee_count: 0,
	label: "Rest",
};

assert.deepEqual(currentFrame([work, rest], 2), {
	event: work,
	index: 0,
	phase_elapsed: 2,
	phase_remaining: 8,
});

let reps = {
	currentEventKey: "0:work_burpee:Block 1",
	doneInEvent: 4,
	burpeeCountDone: 4,
	previousFrame: { event: work, index: 0 },
};

reps = accountReps(reps.previousFrame, null, reps);
assert.equal(reps.burpeeCountDone, 5);

let result = segmentTransition(initialSegmentState(), {
	type: "SEGMENT_READY",
	timeline: [work, rest],
	blockCount: 1,
});
assert.equal(result.state.mode, "idle");
assert.equal(result.state.timeline.length, 2);

result = segmentTransition(result.state, { type: "COUNTDOWN_START", now: 1000 });
assert.equal(result.state.mode, "countdown");
assert.deepEqual(result.commands, [{ type: "startCountdownTimer" }]);

result = segmentTransition(result.state, { type: "COUNTDOWN_DONE", now: 6000 });
assert.equal(result.state.mode, "running");
assert.equal(result.state.clock.totalDurationSec, 15);
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = segmentTransition(result.state, { type: "TICK", elapsedSec: 3 });
assert.deepEqual(result.commands, [
	{ type: "renderRunningFrame", elapsedSec: 3 },
	{ type: "scheduleAnimationFrame" },
]);

result = segmentTransition(result.state, { type: "TICK", elapsedSec: 15 });
assert.equal(result.state.mode, "done");
assert.deepEqual(result.commands.at(-1), {
	type: "segmentDone",
	result: { burpeeCountDone: 5, durationSec: 15 },
});

console.log("session_segment_fsm tests passed");
```

- [ ] **Step 2: Update `assets/package.json` test command temporarily**

Set the test script to run both the existing test and the new failing test:

```json
{
  "scripts": {
    "test": "node js/hooks/session_fsm_test.mjs && node js/hooks/session_segment_fsm_test.mjs"
  }
}
```

Keep all other `package.json` fields unchanged.

- [ ] **Step 3: Run the failing test**

Run:

```bash
npm --prefix assets test
```

Expected: fails because `session_segment_fsm.mjs` does not exist.

- [ ] **Step 4: Commit is not allowed yet**

Do not commit a red test by itself. Continue to Task 2.

---

### Task 2: Create `session_segment_fsm.mjs`

**Files:**

- Create: `assets/js/hooks/session_segment_fsm.mjs`
- Modify: `assets/js/hooks/session_segment_fsm_test.mjs`

- [ ] **Step 1: Copy generic helpers from current FSM**

Create `assets/js/hooks/session_segment_fsm.mjs` with:

```js
export function initialSegmentState() {
	return {
		mode: "idle",
		timeline: [],
		blockCount: 0,
		clock: {
			startTime: null,
			pauseTime: null,
			hiddenAt: null,
			elapsedSec: 0,
			totalDurationSec: 0,
		},
		reps: {
			currentEventKey: null,
			doneInEvent: 0,
			burpeeCountDone: 0,
			previousFrame: null,
		},
		countdown: {
			value: null,
			paused: false,
			stepStartedAt: null,
			stepElapsedMs: 0,
		},
		beeps: {
			lastRepIndex: -1,
			lastRestCount: null,
		},
		display: {
			lastEventType: null,
			lastBurpeeCount: 0,
		},
	};
}

export function currentFrame(timeline, elapsedSec) {
	let cursor = 0;

	for (let index = 0; index < timeline.length; index++) {
		const event = timeline[index];
		if (elapsedSec < cursor + event.duration_sec) {
			return {
				event,
				index,
				phase_elapsed: elapsedSec - cursor,
				phase_remaining: event.duration_sec - (elapsedSec - cursor),
			};
		}
		cursor += event.duration_sec;
	}

	return null;
}

export function eventKey(frameOrEvent, fallbackIndex = 0) {
	if (!frameOrEvent) return null;
	const event = frameOrEvent.event || frameOrEvent;
	const index = Number.isInteger(frameOrEvent.index)
		? frameOrEvent.index
		: fallbackIndex;
	return `${index}:${event.type}:${event.label || ""}`;
}

export function accountReps(previousFrame, nextFrame, reps) {
	if (!previousFrame || !previousFrame.event) return reps;

	const previousEvent = previousFrame.event;
	const previousKey = eventKey(previousFrame);
	const nextKey = eventKey(nextFrame);

	if (previousKey === nextKey) return reps;
	if (
		previousEvent.type !== "work_burpee" &&
		previousEvent.type !== "warmup_burpee"
	)
		return { ...reps, previousFrame: nextFrame };

	const target = previousEvent.burpee_count || 0;
	const doneInEvent =
		reps.currentEventKey === previousKey ? reps.doneInEvent : 0;
	const missing = Math.max(target - doneInEvent, 0);

	return {
		...reps,
		currentEventKey: nextKey,
		doneInEvent: 0,
		burpeeCountDone: reps.burpeeCountDone + missing,
		previousFrame: nextFrame,
	};
}
```

- [ ] **Step 2: Add segment transition skeleton**

Append:

```js
export function segmentTransition(state, event) {
	switch (event.type) {
		case "SEGMENT_READY":
			return {
				state: {
					...initialSegmentState(),
					timeline: event.timeline || [],
					blockCount: event.blockCount || 0,
				},
				commands: [],
			};

		case "COUNTDOWN_START":
			return {
				state: {
					...state,
					mode: "countdown",
					countdown: {
						...state.countdown,
						value: 5,
						paused: false,
						stepStartedAt: event.now || null,
					},
				},
				commands: [{ type: "startCountdownTimer" }],
			};

		case "COUNTDOWN_DONE": {
			const totalDurationSec = state.timeline.reduce(
				(sum, item) => sum + item.duration_sec,
				0,
			);
			return {
				state: {
					...state,
					mode: "running",
					clock: {
						...state.clock,
						startTime: event.now || null,
						totalDurationSec,
					},
				},
				commands: [{ type: "startAnimationFrame" }],
			};
		}

		case "TICK": {
			if (event.elapsedSec >= state.clock.totalDurationSec) {
				const frame = currentFrame(state.timeline, event.elapsedSec);
				const reps = accountReps(state.reps.previousFrame, frame, state.reps);
				const finalReps = accountReps(reps.previousFrame, null, reps);
				return {
					state: { ...state, mode: "done", reps: finalReps },
					commands: [
						{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
						{
							type: "segmentDone",
							result: {
								burpeeCountDone: finalReps.burpeeCountDone,
								durationSec: Math.round(event.elapsedSec),
							},
						},
					],
				};
			}

			return {
				state: {
					...state,
					clock: { ...state.clock, elapsedSec: event.elapsedSec },
				},
				commands: [
					{ type: "renderRunningFrame", elapsedSec: event.elapsedSec },
					{ type: "scheduleAnimationFrame" },
				],
			};
		}

		default:
			return { state, commands: [] };
	}
}
```

- [ ] **Step 3: Run segment tests**

Run:

```bash
npm --prefix assets test
```

Expected: segment tests pass or fail only on command details. Fix minimal issues until `session_segment_fsm tests passed` appears.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor(session): add generic segment fsm"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

### Task 3: Move generic display, beep, pause, and completion behavior into segment FSM

**Files:**

- Modify: `assets/js/hooks/session_segment_fsm.mjs`
- Modify: `assets/js/hooks/session_segment_fsm_test.mjs`

- [ ] **Step 1: Add tests for display, beeps, pause, visibility, and finish early**

Append tests equivalent to the current `session_fsm_test.mjs`, but use segment names:

```js
result = segmentTransition(result.state, { type: "PAUSE", now: 7000 });
assert.equal(result.state.mode, "paused");
assert.deepEqual(result.commands, [{ type: "cancelAnimationFrame" }]);

result = segmentTransition(result.state, { type: "RESUME", now: 9000 });
assert.equal(result.state.mode, "running");
assert.deepEqual(result.commands, [{ type: "startAnimationFrame" }]);

result = segmentTransition(result.state, {
	type: "DISPLAY_FRAME",
	frame: { event: work, index: 0, phase_elapsed: 2, phase_remaining: 8 },
	elapsedSec: 2,
	totalDurationSec: 15,
	doneInEvent: 1,
});
assert.deepEqual(result.commands.slice(0, 3), [
	{ type: "renderProgressBar", percent: 13.3, color: "#4A9EFF" },
	{ type: "renderTimer", timeLeftSec: 13 },
	{ type: "renderBlockLabel", label: "Block 1 of 1" },
]);

result = segmentTransition(result.state, {
	type: "BEEP_FRAME",
	frame: { event: work, phase_elapsed: 2.1, phase_remaining: 7.9 },
});
assert.deepEqual(result.commands, [{ type: "playRepBeep" }]);

result = segmentTransition(result.state, { type: "FINISH_EARLY", elapsedSec: 7 });
assert.equal(result.state.mode, "done");
assert.deepEqual(result.commands.at(-1), {
	type: "segmentDone",
	result: { burpeeCountDone: 5, durationSec: 7 },
});
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
npm --prefix assets test
```

Expected: fails for missing `PAUSE`, `RESUME`, `DISPLAY_FRAME`, `BEEP_FRAME`, and `FINISH_EARLY` cases.

- [ ] **Step 3: Move helper functions from `session_fsm.mjs`**

Copy these current helper functions into `session_segment_fsm.mjs` and adapt only names that mention session-level concepts:

- `beepCommandsForFrame`
- `phaseColor`
- `blockLabel`
- `displayCommandsForFrame`

`displayCommandsForFrame` should use `event.totalDurationSec` directly, not `warmupEndSec` or `workoutDurationSec`.

- [ ] **Step 4: Implement missing transition cases**

Add cases for:

```js
COUNTDOWN_PAUSE
COUNTDOWN_RESUME
COUNTDOWN_TICK
DISPLAY_FRAME
ACCOUNT_REPS
BEEP_FRAME
FINISH_EARLY
PAUSE
RESUME
VISIBILITY_HIDDEN
VISIBILITY_VISIBLE
```

Use the current `session_fsm.mjs` behavior as the source, but replace final completion commands with `segmentDone`.

- [ ] **Step 5: Run tests**

Run:

```bash
npm --prefix assets test
```

Expected: all asset tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(session): move runner behavior to segment fsm"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

### Task 4: Add flow FSM tests and implementation

**Files:**

- Create: `assets/js/hooks/session_flow_fsm.mjs`
- Create: `assets/js/hooks/session_flow_fsm_test.mjs`
- Modify: `assets/package.json`

- [ ] **Step 1: Create failing flow FSM tests**

Create `assets/js/hooks/session_flow_fsm_test.mjs`:

```js
import assert from "node:assert/strict";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";

const workoutTimeline = [{ type: "work_burpee", duration_sec: 10, burpee_count: 5, label: "Block 1" }];
const warmupTimeline = [{ type: "warmup_burpee", duration_sec: 6, burpee_count: 3, label: "Warmup" }];

let result = flowTransition(initialFlowState(), {
	type: "SESSION_READY",
	workoutTimeline,
	blockCount: 1,
});
assert.equal(result.state.mode, "warmup_prompt");
assert.deepEqual(result.commands, [{ type: "renderPrompt" }]);

result = flowTransition(result.state, { type: "WARMUP_SKIP" });
assert.equal(result.state.mode, "workout_countdown");
assert.deepEqual(result.commands, [
	{ type: "startSegment", segment: "workout", timeline: workoutTimeline, blockCount: 1 },
]);

result = flowTransition(initialFlowState(), {
	type: "SESSION_READY",
	workoutTimeline,
	blockCount: 1,
});
result = flowTransition(result.state, { type: "WARMUP_YES" });
assert.deepEqual(result.commands, [{ type: "pushWarmupRequested" }]);

result = flowTransition(result.state, { type: "WARMUP_READY", warmupTimeline });
assert.equal(result.state.mode, "warmup_countdown");
assert.deepEqual(result.commands, [
	{ type: "startSegment", segment: "warmup", timeline: warmupTimeline, blockCount: 1 },
]);

result = flowTransition(result.state, {
	type: "SEGMENT_DONE",
	segment: "warmup",
	result: { burpeeCountDone: 3, durationSec: 6 },
});
assert.equal(result.state.mode, "warmup_done_prompt");
assert.deepEqual(result.commands, [{ type: "showWarmupDonePrompt" }]);

result = flowTransition(result.state, { type: "WORKOUT_READY" });
assert.equal(result.state.mode, "workout_countdown");
assert.deepEqual(result.commands, [
	{ type: "startSegment", segment: "workout", timeline: workoutTimeline, blockCount: 1 },
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
```

- [ ] **Step 2: Update test script**

Set `assets/package.json` test script to:

```json
{
  "scripts": {
    "test": "node js/hooks/session_segment_fsm_test.mjs && node js/hooks/session_flow_fsm_test.mjs"
  }
}
```

- [ ] **Step 3: Run failing tests**

Run:

```bash
npm --prefix assets test
```

Expected: fails because `session_flow_fsm.mjs` does not exist.

- [ ] **Step 4: Implement flow FSM**

Create `assets/js/hooks/session_flow_fsm.mjs`:

```js
const zeroSegmentResult = { burpeeCountDone: 0, durationSec: 0 };

export function initialFlowState() {
	return {
		mode: "idle",
		workoutTimeline: [],
		blockCount: 0,
		activeSegment: null,
		warmupResult: zeroSegmentResult,
		workoutResult: null,
	};
}

export function flowTransition(state, event) {
	switch (event.type) {
		case "SESSION_READY":
			return {
				state: {
					...state,
					mode: "warmup_prompt",
					workoutTimeline: event.workoutTimeline || [],
					blockCount: event.blockCount || 0,
				},
				commands: [{ type: "renderPrompt" }],
			};

		case "WARMUP_SKIP":
			return {
				state: { ...state, mode: "workout_countdown", activeSegment: "workout" },
				commands: [
					{
						type: "startSegment",
						segment: "workout",
						timeline: state.workoutTimeline,
						blockCount: state.blockCount,
					},
				],
			};

		case "WARMUP_YES":
			return { state, commands: [{ type: "pushWarmupRequested" }] };

		case "WARMUP_READY":
			return {
				state: { ...state, mode: "warmup_countdown", activeSegment: "warmup" },
				commands: [
					{
						type: "startSegment",
						segment: "warmup",
						timeline: event.warmupTimeline || [],
						blockCount: 1,
					},
				],
			};

		case "SEGMENT_DONE":
			if (event.segment === "warmup") {
				return {
					state: {
						...state,
						mode: "warmup_done_prompt",
						activeSegment: null,
						warmupResult: event.result,
					},
					commands: [{ type: "showWarmupDonePrompt" }],
				};
			}

			return {
				state: {
					...state,
					mode: "workout_done",
					activeSegment: null,
					workoutResult: event.result,
				},
				commands: [
					{
						type: "pushSessionComplete",
						payload: {
							warmup: {
								burpee_count_done: state.warmupResult.burpeeCountDone,
								duration_sec: state.warmupResult.durationSec,
							},
							main: {
								burpee_count_done: event.result.burpeeCountDone,
								duration_sec: event.result.durationSec,
							},
						},
					},
				],
			};

		case "WORKOUT_READY":
			return {
				state: { ...state, mode: "workout_countdown", activeSegment: "workout" },
				commands: [
					{
						type: "startSegment",
						segment: "workout",
						timeline: state.workoutTimeline,
						blockCount: state.blockCount,
					},
				],
			};

		default:
			return { state, commands: [] };
	}
}
```

- [ ] **Step 5: Run flow tests**

Run:

```bash
npm --prefix assets test
```

Expected: both segment and flow tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(session): add session flow fsm"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

### Task 5: Wire hook to flow FSM and segment FSM

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_segment_fsm.mjs`
- Modify: `assets/js/hooks/session_flow_fsm.mjs`

- [ ] **Step 1: Replace imports**

In `session_hook.js`, replace current FSM import with:

```js
import {
	currentFrame,
	initialSegmentState,
	segmentTransition,
} from "./session_segment_fsm.mjs";
import { flowTransition, initialFlowState } from "./session_flow_fsm.mjs";
```

Keep renderer/audio/wake-lock imports unchanged.

- [ ] **Step 2: Initialize both FSMs**

In `mounted()` replace:

```js
this.fsm = initialSessionState();
```

with:

```js
this.flow = initialFlowState();
this.segment = initialSegmentState();
this.activeSegment = null;
```

- [ ] **Step 3: Add flow dispatch methods**

Add methods to `SessionHook`:

```js
dispatchFlow(event) {
	const result = flowTransition(this.flow, event);
	this.flow = result.state;
	result.commands.forEach((command) => this.runFlowCommand(command));
},

runFlowCommand(command) {
	switch (command.type) {
		case "renderPrompt":
			this.showWarmupPrompt();
			break;
		case "pushWarmupRequested":
			this.pushEvent("warmup_requested", {});
			break;
		case "startSegment":
			this.startSegment(command);
			break;
		case "showWarmupDonePrompt":
			this.showWarmupDonePrompt();
			break;
		case "pushSessionComplete":
			this.pushEvent("session_complete", command.payload);
			break;
	}
},
```

- [ ] **Step 4: Rename current dispatch to segment dispatch**

Replace `dispatchSession(event)` with:

```js
dispatchSegment(event) {
	const result = segmentTransition(this.segment, event);
	this.segment = result.state;
	this.timeline = this.segment.timeline;
	this.blockCount = this.segment.blockCount;
	result.commands.forEach((command) => this.runSegmentCommand(command));
},
```

Rename `runSessionCommand` to `runSegmentCommand`.

- [ ] **Step 5: Update server event routing**

Replace `session_ready` handling with:

```js
this.handleEvent("session_ready", ({ timeline, block_count }) => {
	this.dispatchFlow({
		type: "SESSION_READY",
		workoutTimeline: timeline,
		blockCount: block_count || 0,
	});
});
```

Replace `warmup_ready` handling with:

```js
this.handleEvent("warmup_ready", ({ warmup }) => {
	this.dispatchFlow({ type: "WARMUP_READY", warmupTimeline: warmup });
});
```

- [ ] **Step 6: Implement `startSegment`**

Add:

```js
startSegment({ segment, timeline, blockCount }) {
	this.activeSegment = segment;
	this.segment = initialSegmentState();
	this.dispatchSegment({ type: "SEGMENT_READY", timeline, blockCount });
	this.dispatchSegment({ type: "COUNTDOWN_START", now: performance.now() });
},
```

- [ ] **Step 7: Route warmup prompt buttons through flow FSM**

Update:

```js
onWarmupYes() {
	this.dispatchFlow({ type: "WARMUP_YES" });
}

onWarmupSkip() {
	this.dispatchFlow({ type: "WARMUP_SKIP" });
}
```

- [ ] **Step 8: Route segment completion into flow FSM**

In `runSegmentCommand`, replace `segmentDone` handling with:

```js
case "segmentDone":
	this.dispatchFlow({
		type: "SEGMENT_DONE",
		segment: this.activeSegment,
		result: command.result,
	});
	break;
```

Remove hook-side `COMPLETE_SESSION` dispatch and final payload construction.

- [ ] **Step 9: Run tests**

Run:

```bash
npm --prefix assets test
mix assets.build
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all pass.

- [ ] **Step 10: Commit**

```bash
jj describe -m "refactor(session): wire flow and segment fsms"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

### Task 6: Add warmup done prompt and fresh workout countdown

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_flow_fsm_test.mjs`

- [ ] **Step 1: Add click target for workout ready**

In the event delegation block, add:

```js
const workoutReady = e.target.closest("#workout-ready-btn");
if (workoutReady) this.onWorkoutReady();
```

- [ ] **Step 2: Add `onWorkoutReady`**

Add:

```js
onWorkoutReady() {
	this.dispatchFlow({ type: "WORKOUT_READY" });
},
```

- [ ] **Step 3: Add warmup done prompt renderer**

Add:

```js
showWarmupDonePrompt() {
	if (this.rafId) cancelAnimationFrame(this.rafId);
	this.rafId = null;
	this.audio.stop();
	this.startTime = null;
	this.countdownCount = null;
	this.countdownPaused = false;

	let overlay = this.el.querySelector("#start-overlay");
	if (!overlay) {
		overlay = document.createElement("div");
		overlay.id = "start-overlay";
		overlay.className =
			"absolute inset-0 z-10 flex flex-col items-center justify-center gap-5 rounded-lg bg-base-100/95 text-center backdrop-blur-sm";
		this.el.querySelector("#session-runner-client")?.appendChild(overlay);
	}

	overlay.innerHTML = `
		<span class="text-xl font-semibold tracking-tight">Warmup complete</span>
		<p class="max-w-xs text-sm text-base-content/60">Take a breath. Start the workout when you're ready.</p>
		<button type="button" id="workout-ready-btn" class="rounded-xl bg-primary px-8 py-4 text-sm font-semibold text-primary-content transition active:scale-[0.97] hover:brightness-110">
			Start workout
		</button>
	`;
}
```

- [ ] **Step 4: Ensure `startCountdown` removes prompt**

Confirm `startCountdown()` still removes `#start-overlay` before rendering countdown. If not, add:

```js
const overlay = this.el.querySelector("#start-overlay");
if (overlay) overlay.remove();
```

- [ ] **Step 5: Run tests and build**

Run:

```bash
npm --prefix assets test
mix assets.build
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(session): pause between warmup and workout"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

### Task 7: Remove old combined FSM and update final verification

**Files:**

- Delete: `assets/js/hooks/session_fsm.mjs`
- Delete or replace: `assets/js/hooks/session_fsm_test.mjs`
- Modify: `assets/package.json`

- [ ] **Step 1: Remove old imports**

Search:

```bash
rg "session_fsm|initialSessionState|transition\(" assets/js/hooks
```

Expected after cleanup: no production imports of `session_fsm.mjs` remain.

- [ ] **Step 2: Delete old combined FSM file**

Delete:

```bash
rm assets/js/hooks/session_fsm.mjs
```

- [ ] **Step 3: Keep test entrypoint stable**

Either delete `session_fsm_test.mjs` and set `assets/package.json` to:

```json
{
  "scripts": {
    "test": "node js/hooks/session_segment_fsm_test.mjs && node js/hooks/session_flow_fsm_test.mjs"
  }
}
```

or replace `session_fsm_test.mjs` with:

```js
import "./session_segment_fsm_test.mjs";
import "./session_flow_fsm_test.mjs";
```

and keep:

```json
{
  "scripts": {
    "test": "node js/hooks/session_fsm_test.mjs"
  }
}
```

Choose the second option if you want minimal `package.json` churn.

- [ ] **Step 4: Run full verification**

Run:

```bash
npm --prefix assets test
mix assets.build
mix test test/burpee_trainer_web/live/session_live_test.exs
mix precommit
```

Expected:

```text
session_segment_fsm tests passed
session_flow_fsm tests passed
271 tests, 0 failures
```

- [ ] **Step 5: Remove generated pi-lens files if present**

Run:

```bash
rm -rf assets/.pi-lens
jj st
```

Expected: no `assets/.pi-lens` files remain.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(session): remove combined runner fsm"
jj new
jj bookmark set master -r @-
jj git push -b master
```

---

## Manual QA checklist

After implementation, manually run through:

- Warmup skip -> workout countdown -> workout -> logger
- Warmup yes -> warmup countdown -> warmup -> ready prompt -> workout countdown -> workout -> logger
- Countdown pause/resume during warmup
- Countdown pause/resume during workout
- Running pause/resume during warmup
- Running pause/resume during workout
- Finish early during warmup should be disabled or ignored unless explicitly implemented
- Finish early during workout should open the logger
- Tab hidden/visible during a segment preserves elapsed time
- Mobile viewport keeps ring and progress layout stable
