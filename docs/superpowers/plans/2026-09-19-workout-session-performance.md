# Workout Session Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove verified workout-session main-thread, paint, and camera-pipeline waste while preserving timing, visuals, 15 FPS pose inference, model complexity, and rep accuracy.

**Architecture:** Keep the client-authoritative session architecture. Make hot-path rendering value-diffed, make continuous visuals compositor-friendly, make trace byte accounting incremental, and add explicit tracker suspension/overlay visibility without changing camera acquisition or inference quality.

**Tech Stack:** Phoenix LiveView, JavaScript ES modules, Node test runner, Tailwind CSS v4, MediaPipe Pose, Jujutsu.

## Global Constraints

- Preserve workout timing, rep accounting, audio cues, completion, persistence, and approved visual behavior.
- Preserve front-camera selection, 15 FPS pose inference, and MediaPipe `modelComplexity: 1`.
- Preserve hook-local ownership of the server-rendered video and overlay canvas.
- Do not restore Tailwind `scale-y-0`; JS must own the complete work-fill transform.
- Follow TDD: every production change begins with a focused failing test.
- Run `mix precommit` after all changes.

---

### Task 1: Eliminate duplicate tick computation

**Files:**

- Modify: `assets/js/hooks/session_segment_fsm.mjs:348-400`
- Modify: `assets/js/hooks/session_hook.js:982-1067,1210-1238`
- Test: `assets/js/hooks/session_segment_fsm_test.mjs`
- Test: `assets/js/hooks/session_hook_flow_test.mjs`

**Interfaces:**

- Produces: `renderRunningFrame` command containing `{elapsedSec, frame}`.
- Consumes: the already-accounted `segment.reps` state when rendering.

- [ ] **Step 1: Write failing FSM test**

Add a test asserting a `TICK` transition emits one `renderRunningFrame` command whose `frame` is the same frame stored in `next.state.reps.previousFrame`.

```js
const result = segmentTransition(runningState, { type: "TICK", elapsedSec: 0.5 });
const command = result.commands.find(({ type }) => type === "renderRunningFrame");
assert.equal(command.frame, result.state.reps.previousFrame);
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `cd assets && node --test js/hooks/session_segment_fsm_test.mjs`

Expected: FAIL because `renderRunningFrame` does not contain `frame`.

- [ ] **Step 3: Pass the computed frame through the command**

Change the running and completion command creation to:

```js
{ type: "renderRunningFrame", elapsedSec: event.elapsedSec, frame }
```

and use `completionElapsedSec` for the completion command.

- [ ] **Step 4: Write failing hook regression test**

Add a focused flow test proving a tick updates scheduled totals once and renders from the command frame without dispatching a second `ACCOUNT_REPS` transition.

- [ ] **Step 5: Run the hook test and verify RED**

Run: `cd assets && node --test js/hooks/session_hook_flow_test.mjs`

Expected: FAIL because `renderRunningFrame` still dispatches `ACCOUNT_REPS`.

- [ ] **Step 6: Consume the command frame without re-accounting**

Update command handling and rendering:

```js
case "renderRunningFrame":
  this.renderRunningFrame(command.elapsedSec, command.frame);
  break;
```

Remove the nested `ACCOUNT_REPS` dispatch from `renderRunningFrame`; synchronize `doneReps` from the already-updated segment state.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run: `cd assets && node --test js/hooks/session_segment_fsm_test.mjs js/hooks/session_hook_flow_test.mjs`

Expected: PASS.

- [ ] **Step 8: Commit the task**

```bash
jj describe -m "perf(session): reuse computed workout frame"
jj new
```

---

### Task 2: Diff hot-path DOM writes and remove forced layout

**Files:**

- Modify: `assets/js/hooks/session_renderer.mjs`
- Test: `assets/js/hooks/session_renderer_test.mjs`

**Interfaces:**

- Produces: renderer methods with unchanged public signatures.
- Internal state: cached hot nodes and last applied discrete/continuous values.

- [ ] **Step 1: Add assignment counters to the renderer test harness**

Extend fake elements to count `hidden`, attribute, style, and text assignments without changing production behavior.

- [ ] **Step 2: Write failing identical-model test**

Render the same work model twice and assert the second call does not increase text, attribute, hidden, class, or discrete style mutation counts. Permit no additional work-fill/session-progress transform write when progress is unchanged.

- [ ] **Step 3: Run the renderer test and verify RED**

Run: `cd assets && node --test js/hooks/session_renderer_test.mjs`

Expected: FAIL because repeated models rewrite DOM state.

- [ ] **Step 4: Cache hot nodes and last values**

In `SessionRenderer`, resolve frequently used nodes once in the constructor and add small helpers such as:

```js
setText(node, value, key) {
  const text = String(value ?? "");
  if (this.rendered[key] === text) return;
  this.rendered[key] = text;
  node.textContent = text;
}
```

Apply value guards to timer text, accessible status, counts, totals, set progress, hidden state, ARIA label, work-fill progress, and session progress. Retain the existing visual-state guard.

- [ ] **Step 5: Run renderer tests and verify GREEN**

Run: `cd assets && node --test js/hooks/session_renderer_test.mjs`

Expected: PASS.

- [ ] **Step 6: Write failing DOWN-cue test**

Give the fake count element an `offsetWidth` getter that throws, call `triggerDown`, and assert no exception.

- [ ] **Step 7: Run the test and verify RED**

Expected: FAIL because `triggerDown` reads `offsetWidth`.

- [ ] **Step 8: Replace forced reflow with retained animation**

Use `element.animate(...)` when available. Provide a fallback that removes and restores the class in separate animation frames without reading geometry. Preserve timeout cleanup and visible cue behavior.

- [ ] **Step 9: Run renderer tests and verify GREEN**

Run: `cd assets && node --test js/hooks/session_renderer_test.mjs`

Expected: PASS.

- [ ] **Step 10: Commit the task**

```bash
jj describe -m "perf(session): skip unchanged renderer mutations"
jj new
```

---

### Task 3: Move full-screen visuals to compositor-friendly layers

**Files:**

- Modify: `lib/burpee_trainer_web/components/session_components.ex:261-374`
- Modify: `assets/css/app.css:245-288`
- Modify: `assets/js/hooks/session_renderer.mjs:348-356`
- Test: `assets/js/hooks/session_renderer_test.mjs`
- Test: `assets/js/hooks/session_styles_test.mjs`

**Interfaces:**

- Produces: `#session-work-fill` whose complete transform is `translate3d(0, <percent>%, 0)` or equivalent bottom-up transform.
- Produces: two rest breathing layers animated only through opacity.

- [ ] **Step 1: Write failing style-contract tests**

Assert that session CSS no longer animates `background-color` or uses `clip-path` for work fill, and that the template contains the dedicated breathing layers.

- [ ] **Step 2: Run style tests and verify RED**

Run: `cd assets && node --test js/hooks/session_styles_test.mjs js/hooks/session_renderer_test.mjs`

Expected: FAIL against current CSS and template.

- [ ] **Step 3: Implement transform-owned work fill**

Replace clip-path writes with one JS-owned transform. The initial CSS transform must match empty progress without any Tailwind scale utility. Update the renderer test to assert progress 0, 0.5, and 1 map to empty, half, and full states.

- [ ] **Step 4: Implement opacity breathing layers**

Add two pointer-inert absolute layers under content. Keep the same blue colors and five-second timing, but animate only opacity. Pause both animations when paused and disable them under reduced motion.

- [ ] **Step 5: Run focused style and renderer tests**

Run: `cd assets && node --test js/hooks/session_styles_test.mjs js/hooks/session_renderer_test.mjs`

Expected: PASS.

- [ ] **Step 6: Run relevant LiveView tests**

Run: `mix test test/burpee_trainer_web/live/session_live_test.exs`

Expected: PASS.

- [ ] **Step 7: Commit the task**

```bash
jj describe -m "perf(session): composite workout visual layers"
jj new
```

---

### Task 4: Make pose trace byte accounting incremental

**Files:**

- Modify: `assets/js/hooks/pose_capture_recorder.mjs`
- Test: `assets/js/hooks/pose_capture_recorder_test.mjs`

**Interfaces:**

- Recorder state adds exact pending encoded-byte accounting.
- Existing chunk payload and public function signatures remain unchanged.

- [ ] **Step 1: Write failing incremental-accounting tests**

Inject or export a sample-byte measurement seam and assert each accepted sample is measured once, while exact-boundary and over-boundary chunks remain below `MAX_TRACE_CHUNK_BYTES`.

- [ ] **Step 2: Run recorder tests and verify RED**

Run: `cd assets && node --test js/hooks/pose_capture_recorder_test.mjs`

Expected: FAIL because the full candidate payload is measured on every call.

- [ ] **Step 3: Implement exact incremental accounting**

Store the encoded size contribution of the pending sample array and account for JSON envelope and comma bytes. On flush, reset pending bytes. Preserve single-sample overflow diagnostics and three-second flush behavior.

- [ ] **Step 4: Run recorder tests and verify GREEN**

Run: `cd assets && node --test js/hooks/pose_capture_recorder_test.mjs`

Expected: PASS.

- [ ] **Step 5: Commit the task**

```bash
jj describe -m "perf(tracking): account trace bytes incrementally"
jj new
```

---

### Task 5: Suspend pose work and render overlay only when visible

**Files:**

- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Test: `assets/js/hooks/pose_tracker_impl_test.mjs`
- Test: `assets/js/hooks/session_hook_flow_test.mjs`

**Interfaces:**

- Tracker events: `pose-tracker:suspend`, `pose-tracker:resume`, and `pose-tracker:preview-visibility` with `{visible}`.
- Suspension preserves stream/detector resources but performs no inference or trace capture.

- [ ] **Step 1: Write failing overlay visibility test**

Start the controlled tracker, mark preview invisible, advance frames, and assert inference/rep processing continues while overlay draw calls do not increase.

- [ ] **Step 2: Run tracker tests and verify RED**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs`

Expected: FAIL because overlay drawing is unconditional.

- [ ] **Step 3: Add explicit preview visibility state**

Handle `pose-tracker:preview-visibility`; draw only when visible. Have flow rendering dispatch visibility changes when entering or leaving camera setup.

- [ ] **Step 4: Write failing pause/resume tests**

Assert suspension causes scheduled callbacks to perform no inference or trace capture, resume restarts sampling once, and temporal tracking state is reset.

- [ ] **Step 5: Run tracker and flow tests and verify RED**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/session_hook_flow_test.mjs`

Expected: FAIL because pause does not control the tracker.

- [ ] **Step 6: Implement suspension and integration**

Add idempotent suspend/resume handlers. Dispatch suspend from session pause and resume from session resume. Do not stop tracks or dispose the detector. Reset HSMM/feature timing on resume before the next inference.

- [ ] **Step 7: Write failing visible-size test**

Start with a zero-size canvas rectangle, then expose a non-zero rectangle and assert the backing canvas is sized only after visibility.

- [ ] **Step 8: Implement visibility-aware sizing**

Ignore zero dimensions, resize when preview becomes visible, and use `ResizeObserver` when available. Disconnect the observer during stop/destroy.

- [ ] **Step 9: Run focused tracker and flow tests**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/session_hook_flow_test.mjs`

Expected: PASS.

- [ ] **Step 10: Commit the task**

```bash
jj describe -m "perf(tracking): suspend hidden pose work"
jj new
```

---

### Task 6: Full verification and physical-device handoff

**Files:**

- Modify only if verification exposes a regression.
- Reference: `docs/testing/workout-session-e2e.md`

- [ ] **Step 1: Run proactive diagnostics**

Run LSP and pi-lens diagnostics for all modified JavaScript, CSS, HEEx/Elixir, and test files. Resolve new blocking findings.

- [ ] **Step 2: Run the complete JavaScript suite**

Run: `cd assets && npm test`

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run project precommit**

Run: `mix precommit`

Expected: exit 0.

- [ ] **Step 4: Run workout browser E2E where supported**

Follow `docs/testing/workout-session-e2e.md`. Exercise manual mode and the controlled pose fixture. Mark physical camera/iPhone-only portions blocked rather than inferring them from desktop automation.

- [ ] **Step 5: Review the final diff**

Run: `jj diff --git` and confirm every change maps to this plan. Confirm camera cadence, model complexity, camera selection, workout timing, and payload shape remain unchanged.

- [ ] **Step 6: Describe the final verification change if needed**

```bash
jj describe -m "test(session): verify mobile performance fixes"
```
