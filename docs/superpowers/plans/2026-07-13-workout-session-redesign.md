# Workout Session Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the workout ring UI with the approved July 13 full-screen work and breathing-rest design while preserving the existing session runtime, camera tracking, timing, audio, completion, and persistence behavior.

**Architecture:** Keep `SessionLive`, `SessionHook`, `session_flow_fsm.mjs`, and `session_segment_fsm.mjs` as the behavioral owners. Add an explicit visual-state contract to `session_display_model.mjs`, then make `SessionRenderer` translate that contract into CSS classes, a per-rep orange work fill, a bounded blue breathing shape, and the between-set final-five/final-three transition. Recompose existing HEEx and prompt DOM around those visuals without changing event names, hook ownership, or persisted data.

**Tech Stack:** Phoenix 1.8 LiveView/HEEx, Elixir, vanilla JavaScript ES modules, Node's built-in test runner, Tailwind CSS v4, custom CSS, ExUnit/LazyHTML, Jujutsu (`jj`).

## Global Constraints

- Treat `docs/superpowers/specs/2026-07-13-workout-session-redesign-design.md` as authoritative.
- This is a visual-only redesign except for the approved between-set presentation: do not change timeline, rep accounting, clock, pause, tracking, completion, or persistence semantics.
- Preserve all pre-existing working-copy changes, especially camera-preview and pose-tracking work in `session_live.ex`, `session_hook.js`, `pose_tracker_impl.mjs`, `pose_overlay.mjs`, and their tests.
- At execution start, create a clean child change with `jj new`; never squash implementation work into the pre-existing parent change.
- Do not add dependencies or a frontend framework.
- Keep Tailwind v4's existing `app.css` import syntax; do not add `tailwind.config.js`, inline `<script>` tags, `@apply`, or DaisyUI components.
- Keep `<Layouts.app flash={@flash} ...>` around the LiveView.
- Use existing event names and key IDs: `#capture-tracked-btn`, `#capture-timed-btn`, `#camera-setup-start-btn`, `#warmup-yes-btn`, `#warmup-skip-btn`, `#workout-ready-btn`, `#ring-container`, `#finish-early-btn`, and `#session-abort-btn`.
- Work color: `#FD7236`; rest color: `#749CCE`; warm-paper background remains `#F4F2EE`/the existing session background token.
- Work fill uses existing per-rep `0→1` progress and resets every rep. Never add set-level or whole-workout progress.
- Rest uses an 8.4-second breathing cycle: 4.2 seconds expanding and 4.2 seconds contracting. It never fills the viewport.
- Between-set final five seconds stop breathing and settle toward work; final three seconds show pulsing/beeping numeric `3`, `2`, `1`.
- The initial workout count-in remains dots.
- Never show `Rest`, `Get ready`, `Start position`, `Next set`, or explanatory phase copy on the active surface.
- Use `start_supervised!/1` for any new Elixir test processes; do not use `Process.sleep/1`.
- Run focused tests after every task and `mix precommit` only after all tasks.

## File Map

### Create

- `assets/js/hooks/session_display_model_test.mjs` — pure visual-state contract tests.
- `assets/js/hooks/session_renderer_test.mjs` — DOM rendering tests for work fill, rest modes, countdown pulse, and pause.
- `assets/js/hooks/session_segment_fsm_test.mjs` — regression tests proving one existing beep command per between-set `3`, `2`, `1`.

### Modify

- `assets/js/hooks/session_display_model.mjs` — derive explicit visual state from existing frame data.
- `assets/js/hooks/session_renderer.mjs` — replace ring/set-glyph rendering with work fill, breathing, transition, countdown, and pause rendering.
- `assets/js/hooks/session_hook.js` — preserve flow/runtime while mapping existing commands to the new renderer and restyling prompt builders.
- `assets/js/hooks/session_hook_flow_test.mjs` — lock prompt/camera flow and pause-action DOM contracts; merge with existing uncommitted tests.
- `lib/burpee_trainer_web/live/session_live.ex` — recompose active, camera, pause, completion, review, and save surfaces while preserving hook ownership and event IDs.
- `test/burpee_trainer_web/live/app_flow_test.exs` — integration assertions for new stable DOM; merge with existing uncommitted camera assertions.
- `assets/css/app.css` — add exact work/rest tokens, full-screen layers, breathing/settle/pulse motion, pause treatment, and reduced-motion rules; remove ring-only rules.

### Delete

- `assets/js/hooks/session_ring.mjs` — no consumer remains after the renderer stops drawing a ring.

---

### Task 1: Define the Session Visual-State Contract

**Files:**

- Create: `assets/js/hooks/session_display_model_test.mjs`
- Modify: `assets/js/hooks/session_display_model.mjs:1-127`

**Interfaces:**

- Consumes: existing `frame.event`, `frame.phase_elapsed`, `frame.phase_remaining`, `timeLeftSec`, `totalDone`, `totalTarget`, and `doneInEvent` values.
- Produces: `model.visual` with exact shape `{state, progress, pulse}` where `state` is one of `initial-countdown | work | rest-breathe | rest-settle | rest-countdown`, `progress` is the existing per-rep work fraction, and `pulse` is `3 | 2 | 1 | null`.
- Preserves: `primaryCount`, `countdownDots`, `restTimeLeftSec`, `totalDone`, `totalTarget`, and `timeLeftSec` until Task 2 removes obsolete ring/set-glyph fields.

- [ ] **Step 1: Isolate implementation work from the existing working copy**

Run:

```bash
jj st
jj new
jj st
```

Expected: the first status shows the existing camera/session changes; the second status shows a clean child working-copy change whose parent contains those changes.

- [ ] **Step 2: Write failing display-model tests**

Create `assets/js/hooks/session_display_model_test.mjs`:

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import {
  countdownDisplayModel,
  runningDisplayModel,
} from "./session_display_model.mjs";

function runningModel(event, frameOverrides = {}) {
  return runningDisplayModel({
    timeline: [event],
    frame: {
      event,
      index: 0,
      phase_elapsed: 0,
      phase_remaining: event.duration_sec || event.reps * event.sec_per_rep,
      ...frameOverrides,
    },
    timeLeftSec: 60,
    totalDone: 4,
    totalTarget: 20,
    doneInEvent: 1,
  });
}

test("initial count-in keeps dots", () => {
  const model = countdownDisplayModel({
    value: 3,
    total: 5,
    totalDone: 0,
    totalTarget: 20,
    timeLeftSec: 60,
  });

  assert.deepEqual(model.visual, {
    state: "initial-countdown",
    progress: 0,
    pulse: null,
  });
  assert.deepEqual(model.countdownDots, {count: 5, faded: 2});
});

test("work exposes existing per-rep progress", () => {
  const model = runningModel(
    {kind: "work", reps: 6, sec_per_rep: 4},
    {phase_elapsed: 6, phase_remaining: 18},
  );

  assert.deepEqual(model.visual, {
    state: "work",
    progress: 0.5,
    pulse: null,
  });
  assert.equal(model.primaryCount, 5);
});

test("rest breathes before the final five seconds", () => {
  const model = runningModel(
    {kind: "rest", duration_sec: 30},
    {phase_elapsed: 18, phase_remaining: 12},
  );

  assert.equal(model.visual.state, "rest-breathe");
  assert.equal(model.primaryCount, "12");
  assert.equal(model.countdownDots, null);
});

test("rest settles at five and four seconds", () => {
  for (const remaining of [5, 4]) {
    const model = runningModel(
      {kind: "rest", duration_sec: 30},
      {phase_elapsed: 30 - remaining, phase_remaining: remaining},
    );

    assert.equal(model.visual.state, "rest-settle");
    assert.equal(model.visual.pulse, null);
    assert.equal(model.primaryCount, String(remaining));
  }
});

test("between-set final three seconds use numeric pulses, not dots", () => {
  for (const remaining of [3, 2, 1]) {
    const model = runningModel(
      {kind: "rest", duration_sec: 30},
      {phase_elapsed: 30 - remaining, phase_remaining: remaining},
    );

    assert.equal(model.visual.state, "rest-countdown");
    assert.equal(model.visual.pulse, remaining);
    assert.equal(model.primaryCount, remaining);
    assert.equal(model.countdownDots, null);
  }
});
```

- [ ] **Step 3: Run the new test and verify it fails**

Run:

```bash
cd assets && node --test js/hooks/session_display_model_test.mjs
```

Expected: FAIL because `model.visual` is undefined and rest final-three still returns countdown dots.

- [ ] **Step 4: Add the minimal visual-state derivation**

In `assets/js/hooks/session_display_model.mjs`, add:

```javascript
function visualStateForFrame({isRest, isWork, remainingSec, progress}) {
  if (isWork) {
    return {state: "work", progress, pulse: null};
  }

  if (!isRest) {
    return {state: "work", progress: 0, pulse: null};
  }

  if (remainingSec > 5) {
    return {state: "rest-breathe", progress: 0, pulse: null};
  }

  if (remainingSec > 3) {
    return {state: "rest-settle", progress: 0, pulse: null};
  }

  const pulse = remainingSec > 0 ? Math.ceil(remainingSec) : null;
  return {state: "rest-countdown", progress: 0, pulse};
}
```

Add this exact field to `countdownDisplayModel/1`'s returned object:

```javascript
visual: {state: "initial-countdown", progress: 0, pulse: null},
```

In `runningDisplayModel/1`, derive remaining time once and return the visual contract:

```javascript
const remainingSec = frame?.phase_remaining ?? timeLeftSec ?? 0;
const visual = visualStateForFrame({
  isRest,
  isWork,
  remainingSec,
  progress,
});
```

Replace the old rest-countdown fields with:

```javascript
visual,
primaryCount:
  visual.state === "rest-countdown"
    ? visual.pulse
    : isRest
      ? formatTime(remainingSec)
      : isWork
        ? Math.max((event?.reps || 0) - doneInEvent, 0)
        : (event?.reps ?? totalTarget ?? "—"),
countdownDots: null,
restTimeLeftSec: isRest ? remainingSec : null,
```

Keep `countdownDisplayModel/1`'s existing dots unchanged.

- [ ] **Step 5: Run focused and full JavaScript tests**

Run:

```bash
cd assets && node --test js/hooks/session_display_model_test.mjs
cd assets && npm test
```

Expected: both commands PASS.

- [ ] **Step 6: Commit the visual-state contract**

```bash
jj describe -m "test(session): define workout visual states"
jj new
```

---

### Task 2: Replace the Ring with the Per-Rep Work Surface

**Files:**

- Create: `assets/js/hooks/session_renderer_test.mjs`
- Modify: `assets/js/hooks/session_renderer.mjs:1-365`
- Modify: `assets/js/hooks/session_hook.js:195-269`
- Modify: `lib/burpee_trainer_web/live/session_live.ex:619-803`
- Modify: `assets/css/app.css:141-413`
- Delete: `assets/js/hooks/session_ring.mjs`

**Interfaces:**

- Consumes: Task 1's `model.visual.state` and `model.visual.progress`.
- Produces: `SessionRenderer.updateWorkFill(progress)` and stable DOM IDs `#session-work-fill`, `#session-rest-shape`, `#count`, `#pause-icon`, and `#ring-container`.
- Preserves: `#ring-container` as the existing pointer/keyboard pause target even though it no longer contains a ring.

- [ ] **Step 1: Write failing renderer tests for work fill and initial dots**

Create `assets/js/hooks/session_renderer_test.mjs`:

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import {SessionRenderer} from "./session_renderer.mjs";

function classList() {
  const values = new Set();
  return {
    add: (...names) => names.forEach((name) => values.add(name)),
    remove: (...names) => names.forEach((name) => values.delete(name)),
    contains: (name) => values.has(name),
  };
}

function element() {
  return {
    classList: classList(),
    style: {},
    textContent: "",
    firstChild: null,
    appendChild() {},
    removeChild() {},
    setAttribute() {},
  };
}

function harness() {
  const elements = {
    "#session-work-fill": element(),
    "#session-runner-client": element(),
    "#count": element(),
    "#time-left": element(),
    "#total-done": element(),
    "#total-plan": element(),
    "#pause-icon": element(),
  };
  const root = {
    classList: classList(),
    querySelector: (selector) => elements[selector] || null,
  };
  return {renderer: new SessionRenderer(root), elements};
}

test("work fill uses the existing zero-to-one progress", () => {
  const {renderer, elements} = harness();

  renderer.updateWorkFill(0.5);
  assert.equal(elements["#session-work-fill"].style.transform, "scaleY(0.5)");

  renderer.updateWorkFill(0);
  assert.equal(elements["#session-work-fill"].style.transform, "scaleY(0)");
});

test("initial countdown still renders dots", () => {
  const {renderer, elements} = harness();
  renderer.renderDisplayModel({
    visual: {state: "initial-countdown", progress: 0, pulse: null},
    primaryCount: 3,
    countdownDots: {count: 5, faded: 2},
    totalDone: 0,
    totalTarget: 20,
    timeLeftSec: 60,
  });

  assert.equal(elements["#session-runner-client"].classList.contains("is-initial-countdown"), true);
});
```

- [ ] **Step 2: Run the renderer test and verify it fails**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs
```

Expected: FAIL because `updateWorkFill/1`, `#session-work-fill`, and `is-initial-countdown` handling do not exist.

- [ ] **Step 3: Replace ring methods with surface methods**

In `assets/js/hooks/session_renderer.mjs`:

1. Remove the `session_ring.mjs` import.
2. Remove `workRingEl`, `buildWorkRing`, `ensureWorkRing`, `clearWorkRing`, and `updateWorkRing`.
3. Add this state list and methods:

```javascript
const VISUAL_STATE_CLASSES = [
  "is-working",
  "is-rest-breathe",
  "is-rest-settle",
  "is-rest-countdown",
  "is-initial-countdown",
];

setVisualState(state) {
  const surface = this.root.querySelector("#session-runner-client");
  this.root.classList?.remove?.(...VISUAL_STATE_CLASSES);
  surface?.classList?.remove?.(...VISUAL_STATE_CLASSES);

  const className = {
    work: "is-working",
    "rest-breathe": "is-rest-breathe",
    "rest-settle": "is-rest-settle",
    "rest-countdown": "is-rest-countdown",
    "initial-countdown": "is-initial-countdown",
  }[state];

  if (className) {
    this.root.classList?.add?.(className);
    surface?.classList?.add?.(className);
  }
}

updateWorkFill(progress) {
  const fill = this.root.querySelector("#session-work-fill");
  if (!fill) return;
  const clamped = Math.min(Math.max(Number(progress) || 0, 0), 1);
  fill.style.transform = `scaleY(${clamped})`;
}
```

Update `resetReady/0` to call `setVisualState(null)` and `updateWorkFill(0)`.

Update `renderDisplayModel/1` so its work and initial-countdown branches are:

```javascript
const visual = model.visual || {state: "work", progress: 0, pulse: null};
this.setVisualState(visual.state);

if (visual.state === "initial-countdown") {
  this.renderCountdownDots(model.countdownDots || {count: 5, faded: 0});
} else if (visual.state === "work") {
  this.updateWorkFill(visual.progress);
  this.updateCurrentSetRepCount(model.primaryCount);
}
```

Keep rest rendering temporarily delegated to `renderRestProgress/1`; Task 3 replaces it.

In `assets/js/hooks/session_hook.js`, update the existing command mapping without renaming the FSM command:

```javascript
case "renderWorkRepProgress":
  this.renderer.updateWorkFill(command.progress);
  break;
```

Update the fake renderer in `session_hook_flow_test.mjs` from `updateWorkRing() {}` to `updateWorkFill() {}`.

- [ ] **Step 4: Recompose the active runner markup**

In `session_runner/1` in `session_live.ex`, keep `#session-runner-client` and `#ring-container`, remove `#phase-label`, ring SVGs, rest ripples, and `#set-glyphs`, and add these layers before the content:

```heex
<div id="session-visual-layers" class="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden="true">
  <div id="session-work-fill" class="absolute inset-0 origin-bottom scale-y-0 bg-[var(--session-work)]"></div>
  <div id="session-rest-shape" class="absolute inset-x-0 bottom-0"></div>
</div>
```

Use this structure for the primary interaction surface:

```heex
<div class="relative z-10 mx-auto flex min-h-[calc(100dvh-4rem)] w-full max-w-[430px] flex-col px-5 py-8">
  <div
    id="ring-container"
    class="relative flex min-h-0 flex-1 cursor-pointer select-none touch-manipulation items-center justify-center"
    role="button"
    tabindex="0"
    aria-label="Pause or resume session"
  >
    <span id="count" class="qs-tabular text-[clamp(7rem,34vw,13rem)] font-semibold leading-none tracking-[-0.085em]">—</span>
    <svg id="pause-icon" viewBox="0 0 48 48" fill="currentColor" class="absolute size-24" style="display: none;" aria-hidden="true">
      <rect x="10" y="8" width="10" height="32" rx="2" />
      <rect x="28" y="8" width="10" height="32" rx="2" />
    </svg>
  </div>

  <div id="session-status-line" class="relative z-10 flex items-end justify-between pb-[max(1rem,env(safe-area-inset-bottom))] tabular-nums">
    <div><span id="total-done" data-total-plan={@summary.burpee_count_total}>0</span><span class="block text-sm text-[var(--session-muted)]">done</span></div>
    <div class="text-right"><span id="time-left">{Fmt.duration_sec(round(@summary.duration_sec_total))}</span><span class="block text-sm text-[var(--session-muted)]">left</span></div>
    <span id="total-plan" class="sr-only">{@summary.burpee_count_total}</span>
  </div>
</div>
```

- [ ] **Step 5: Add work-surface tokens and CSS**

In the session token block in `assets/css/app.css`, add:

```css
--session-work: #FD7236;
--session-rest: #749CCE;
```

Add the work layer and typography rules:

```css
#session-work-fill {
  background: var(--session-work);
  transform: scaleY(0);
  transform-origin: bottom;
  will-change: transform;
}

#session-runner-client:not(.is-working) #session-work-fill {
  visibility: hidden;
}

#session-runner-client.is-working #session-work-fill {
  visibility: visible;
}

#session-status-line #total-done,
#session-status-line #time-left {
  font-size: clamp(3.5rem, 16vw, 5.5rem);
  font-weight: 600;
  line-height: 0.9;
  letter-spacing: -0.07em;
}
```

Delete ring-only selectors and keyframes after confirming no remaining `ring-svg`, `flash-circle`, `rest-ripple`, or `set-glyphs` references.

- [ ] **Step 6: Delete the ring module and verify the work slice**

Delete `assets/js/hooks/session_ring.mjs`, then run:

```bash
cd assets && node --test js/hooks/session_display_model_test.mjs js/hooks/session_renderer_test.mjs
cd assets && npm test
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: all commands PASS; `rg "session_ring|ring-svg|flash-circle|updateWorkRing" assets lib test` returns no matches except historical docs.

- [ ] **Step 7: Commit the work surface**

```bash
jj describe -m "feat(session): replace ring with per-rep work fill"
jj new
```

---

### Task 3: Implement Breathing Rest and the Numeric Between-Set Transition

**Files:**

- Create: `assets/js/hooks/session_segment_fsm_test.mjs`
- Modify: `assets/js/hooks/session_renderer_test.mjs`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_display_model.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `assets/css/app.css`

**Interfaces:**

- Consumes: Task 1 visual states and the existing `beepCommandsForFrame` behavior.
- Produces: `renderRestState(model)` and a single visual pulse when `model.visual.pulse` changes to `3`, `2`, or `1`.
- Preserves: initial count-in dots and the existing `SessionAudio.playLeadBeep()` implementation.

- [ ] **Step 1: Write failing beep-regression tests**

Create `assets/js/hooks/session_segment_fsm_test.mjs`:

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import {
  initialSegmentState,
  segmentTransition,
} from "./session_segment_fsm.mjs";

function restFrame(remaining) {
  return {
    event: {kind: "rest", duration_sec: 30},
    phase_elapsed: 30 - remaining,
    phase_remaining: remaining,
    index: 1,
  };
}

test("between-set countdown emits one lead beep for 3, 2, and 1", () => {
  let state = initialSegmentState();

  for (const remaining of [3, 2, 1]) {
    const first = segmentTransition(state, {
      type: "BEEP_FRAME",
      frame: restFrame(remaining),
    });
    assert.deepEqual(first.commands, [{type: "playLeadBeep"}]);
    state = first.state;

    const duplicate = segmentTransition(state, {
      type: "BEEP_FRAME",
      frame: restFrame(remaining - 0.2),
    });
    assert.deepEqual(duplicate.commands, []);
    state = duplicate.state;
  }
});

test("rest does not emit countdown beeps before three seconds", () => {
  const result = segmentTransition(initialSegmentState(), {
    type: "BEEP_FRAME",
    frame: restFrame(4),
  });

  assert.deepEqual(result.commands, []);
});
```

- [ ] **Step 2: Extend renderer tests for all rest states**

Add `#session-rest-shape` to the renderer harness and append:

```javascript
test("rest switches from breathing to settle to numeric countdown", () => {
  const {renderer, elements} = harness();

  renderer.renderDisplayModel({
    visual: {state: "rest-breathe", progress: 0, pulse: null},
    primaryCount: "12",
    countdownDots: null,
    totalDone: 8,
    totalTarget: 20,
    timeLeftSec: 40,
  });
  assert.equal(elements["#session-runner-client"].classList.contains("is-rest-breathe"), true);
  assert.equal(elements["#count"].textContent, "12");

  renderer.renderDisplayModel({
    visual: {state: "rest-settle", progress: 0, pulse: null},
    primaryCount: "5",
    countdownDots: null,
    totalDone: 8,
    totalTarget: 20,
    timeLeftSec: 33,
  });
  assert.equal(elements["#session-runner-client"].classList.contains("is-rest-settle"), true);

  renderer.renderDisplayModel({
    visual: {state: "rest-countdown", progress: 0, pulse: 3},
    primaryCount: 3,
    countdownDots: null,
    totalDone: 8,
    totalTarget: 20,
    timeLeftSec: 31,
  });
  assert.equal(elements["#count"].textContent, "3");
  assert.equal(elements["#count"].classList.contains("is-between-set-pulse"), true);
});
```

- [ ] **Step 3: Run the focused tests and verify the renderer test fails**

Run:

```bash
cd assets && node --test js/hooks/session_segment_fsm_test.mjs js/hooks/session_renderer_test.mjs
```

Expected: beep tests PASS against existing behavior; renderer rest-state assertions FAIL.

- [ ] **Step 4: Implement rest rendering without changing the clock**

In `SessionRenderer` add `lastPulseValue = null` in the constructor and:

```javascript
renderRestState(model) {
  const count = this.root.querySelector("#count");
  if (!count) return;

  count.classList.remove("is-between-set-pulse", "countdown-pop");
  count.textContent = String(model.primaryCount ?? "");
  count.style.visibility = this.paused ? "hidden" : "";

  const pulse = model.visual?.pulse;
  if (model.visual?.state === "rest-countdown" && pulse !== this.lastPulseValue) {
    count.classList.add("is-between-set-pulse");
    void count.offsetWidth;
    count.classList.add("countdown-pop");
  }
  this.lastPulseValue = pulse;
}
```

Extend `renderDisplayModel/1`:

```javascript
if (["rest-breathe", "rest-settle", "rest-countdown"].includes(visual.state)) {
  this.updateWorkFill(0);
  this.renderRestState(model);
}
```

Reset `lastPulseValue` on entry to work or initial count-in. Do not call `renderCountdownDots/1` for rest states.

Keep the existing `BEEP_FRAME → playLeadBeep` dispatch unchanged.

- [ ] **Step 5: Add the bounded breathing shape and transition CSS**

Style `#session-rest-shape` as a bottom-anchored shape whose maximum height stays below the viewport:

```css
#session-rest-shape {
  bottom: -8dvh;
  height: min(54dvh, 34rem);
  background: var(--session-rest);
  border-radius: 50% 50% 0 0 / 14% 14% 0 0;
  opacity: 0;
  transform: scaleY(0.82);
  transform-origin: bottom;
  will-change: transform, border-radius, background-color;
}

@keyframes session-breathe {
  0%, 100% { transform: scaleY(0.82); }
  50% { transform: scaleY(1.04); }
}

#session-runner-client.is-rest-breathe #session-rest-shape {
  opacity: 1;
  animation: session-breathe 8.4s cubic-bezier(0.42, 0, 0.16, 1) infinite;
}

#session-runner-client.is-rest-settle #session-rest-shape,
#session-runner-client.is-rest-countdown #session-rest-shape {
  opacity: 1;
  animation: none;
  background: var(--session-work);
  border-radius: 0;
  transform: scaleY(0.5);
  transition:
    background-color 500ms ease,
    border-radius 700ms ease,
    transform 700ms cubic-bezier(0.22, 1, 0.36, 1);
}

#count.is-between-set-pulse {
  color: var(--session-work);
}

@media (prefers-reduced-motion: reduce) {
  #session-rest-shape,
  #count {
    animation: none !important;
    transition-duration: 1ms !important;
  }
}
```

The shape's `54dvh` height plus `-8dvh` offset caps visible coverage near 46dvh, so it cannot fill the viewport.

- [ ] **Step 6: Run all JavaScript tests**

Run:

```bash
cd assets && node --test js/hooks/session_display_model_test.mjs js/hooks/session_renderer_test.mjs js/hooks/session_segment_fsm_test.mjs
cd assets && npm test
```

Expected: PASS. Confirm the initial-countdown test still asserts dots and rest-countdown tests assert numerals.

- [ ] **Step 7: Commit the rest transition**

```bash
jj describe -m "feat(session): add breathing rest transition"
jj new
```

---

### Task 4: Match the Pre-Workout and Camera Setup Mockups

**Files:**

- Modify: `assets/js/hooks/session_hook.js:271-441`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs:116-209`
- Modify: `lib/burpee_trainer_web/live/session_live.ex:448-618,744-803`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs:115-187`
- Modify: `assets/css/app.css`

**Interfaces:**

- Consumes: existing flow commands `showCapturePrompt`, `showCameraSetupPrompt`, `renderPrompt`, `showWarmupDonePrompt`, and `showWorkoutReadyPrompt`.
- Produces: mock-matched prompt DOM using the existing action IDs.
- Preserves: PoseTracker-owned video/canvas DOM and the invariant that setup confirmation hides the preview but leaves tracking mounted.

- [ ] **Step 1: Add failing prompt-structure tests without replacing existing camera tests**

Append to `session_hook_flow_test.mjs` using its existing `buildHarness/1`:

```javascript
test("capture prompt uses the mock hierarchy and stable actions", () => {
  const ctx = buildHarness();
  ctx.dispatchFlow({type: "SESSION_READY", workoutTimeline: [], blockCount: 1});

  const overlay = ctx.el.querySelector("#start-overlay");
  assert.equal(overlay.children[0].textContent, "Track your workout?");
  assert.ok(ctx.el.querySelector("#capture-tracked-btn"));
  assert.ok(ctx.el.querySelector("#capture-timed-btn"));
});

test("warmup and ready prompts retain their stable action ids", () => {
  const ctx = buildHarness();
  ctx.dispatchFlow({type: "SESSION_READY", workoutTimeline: [], blockCount: 1});
  ctx.dispatchFlow({type: "CAPTURE_TIMED"});

  assert.equal(ctx.el.querySelector("#start-overlay").children[0].textContent, "Warm up first?");
  assert.ok(ctx.el.querySelector("#warmup-yes-btn"));
  assert.ok(ctx.el.querySelector("#warmup-skip-btn"));

  ctx.dispatchFlow({type: "WARMUP_SKIP"});
  assert.ok(ctx.el.querySelector("#workout-ready-btn"));
});
```

In `app_flow_test.exs`, extend the tracked workout test with these non-text selectors:

```elixir
assert has_element?(session, "#camera-setup-panel #camera-setup-start-btn")
assert has_element?(session, "#pose-tracker-preview-frame #pose-tracker-preview")
assert has_element?(session, "#pose-tracker-preview-frame #pose-tracker-canvas")
```

Do not remove the existing uncommitted pointer-events and preview-boundary assertions.

- [ ] **Step 2: Run focused tests and verify prompt assertions fail**

Run:

```bash
cd assets && node --test js/hooks/session_hook_flow_test.mjs
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: JavaScript prompt-copy/hierarchy assertions FAIL; existing camera-flow assertions continue to PASS.

- [ ] **Step 3: Restyle the JavaScript prompt builders**

For `showCapturePrompt/0`, render:

```javascript
const title = document.createElement("h1");
title.className = "qs-heading-tight text-[clamp(2.75rem,10vw,4.75rem)] font-medium leading-[0.98]";
title.textContent = "Track your workout?";

const description = document.createElement("p");
description.className = "max-w-lg text-lg leading-relaxed text-[var(--session-muted)]";
description.textContent = "Use camera tracking for pace and rep detection, or run the session with the timer only.";
```

Keep `#capture-tracked-btn` and `#capture-timed-btn`, with a shared two-column container on wider screens and stacked full-width actions at 320px.

For `showWarmupPrompt/0`, use `h1` copy `Warm up first?`, the approved supporting sentence, `#warmup-yes-btn`, and `#warmup-skip-btn`.

For `showWorkoutStartPrompt/2`, ignore divergent warmup-complete title copy and always render:

```javascript
meta.textContent = "Ready when you are";
title.textContent = "Start when you’re ready.";
button.id = "workout-ready-btn";
button.textContent = "Start workout";
```

Do not alter `dispatchFlow/1` or flow FSM transitions.

- [ ] **Step 4: Recompose the camera setup around the existing hook DOM**

In `camera_setup_panel/1`:

- Keep `#camera-setup-panel` and `#camera-setup-start-btn`.
- Remove the floating card/shadow treatment.
- Use one quiet heading/instruction group above the PoseTracker preview and one full-width ink action below it.
- Keep the preview DOM exactly inside `#pose-tracker[phx-hook="PoseTracker"][phx-update="ignore"]`.
- Keep the current classes that hide the full preview layer after `@capture_setup_state == :started`.

Use `Camera ready` when `@setup_state == :ready`; otherwise use `Adjust your camera`. Keep the supporting sentence exactly: `Make sure your full body is visible. We’ll save pose traces for warmup and main workout.` This copy is limited to camera setup and never appears on the active workout surface.

Restyle `not_runnable_panel/1` without changing its behavior:

```heex
<div id="session-not-runnable" class="flex min-h-dvh items-center justify-center bg-[var(--session-bg)] px-8 text-center">
  <div class="max-w-sm">
    <h1 class="qs-heading-tight text-4xl font-medium text-[var(--session-ink)]">No timed events</h1>
    <p class="mt-4 text-base leading-relaxed text-[var(--session-muted)]">
      Add at least one block with one set before running.
    </p>
  </div>
</div>
```

- [ ] **Step 5: Run prompt, camera, and integration tests**

Run:

```bash
cd assets && node --test js/hooks/session_hook_flow_test.mjs
cd assets && npm test
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: PASS with the existing camera diagnostics/tracking tests intact.

- [ ] **Step 6: Commit the pre-workout flow**

```bash
jj describe -m "feat(session): match pre-workout mock flow"
jj new
```

---

### Task 5: Redesign Pause, Completion, Review, and Save Surfaces

**Files:**

- Modify: `assets/js/hooks/session_renderer_test.mjs`
- Modify: `assets/js/hooks/session_renderer.mjs:63-91`
- Modify: `assets/js/hooks/session_hook_flow_test.mjs:652-750`
- Modify: `lib/burpee_trainer_web/live/session_live.ex:459-492,490-516,804-999`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs:40-187`
- Modify: `assets/css/app.css`

**Interfaces:**

- Consumes: existing pause/resume state, `#session-pause-actions`, completion form assigns, tracked-review assigns, and celebration data.
- Produces: paused visual state with dominant pause glyph, `Finish early` primary action, quiet confirmed `Abort`, and warm-paper completion/review/save hierarchy.
- Preserves: all form field names, validation events, save/discard events, tracked completion values, and celebration behavior.

- [ ] **Step 1: Write failing pause renderer assertions**

Append to `session_renderer_test.mjs`:

```javascript
test("pause hides the active number and shows the pause glyph", () => {
  const {renderer, elements} = harness();
  renderer.updatePauseButton(true);

  assert.equal(elements["#count"].style.visibility, "hidden");
  assert.equal(elements["#pause-icon"].style.display, "");

  renderer.updatePauseButton(false);
  assert.equal(elements["#count"].style.visibility, "");
  assert.equal(elements["#pause-icon"].style.display, "none");
});
```

Extend `app_flow_test.exs` completion assertions:

```elixir
assert has_element?(session, "#session-completion-summary")
assert has_element?(session, "#session-completion-form")
assert has_element?(session, "#session-save-btn")
assert has_element?(session, "#session-discard-btn")
```

For tracked completion, also assert:

```elixir
assert has_element?(session, "#tracked-review")
```

- [ ] **Step 2: Run focused tests and verify new selectors fail**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: pause behavior may already pass partially; completion summary/save/discard IDs FAIL until markup is recomposed.

- [ ] **Step 3: Apply the approved paused hierarchy**

Keep `SessionRenderer.updatePauseButton/1` behavior, but remove ring opacity manipulation and instead toggle `is-paused` on `#session-runner-client`.

Recompose `#session-pause-actions` so its visible state contains:

```heex
<button id="finish-early-btn" type="button" disabled class="w-full rounded-[1.75rem] border border-[var(--session-border)] bg-[var(--session-bg)] px-6 py-5 text-lg font-medium disabled:hidden">
  Finish early
</button>
<button id="session-abort-btn" type="button" phx-click="discard" data-confirm="Abort this session without saving?" class="px-6 py-3 text-base text-[var(--session-muted)]">
  Abort
</button>
```

Keep the pause glyph as the only primary paused-state indicator; do not add `Paused` copy. Add this rule so pausing during rest freezes the breathing shape at its exact frame:

```css
#session-runner-client.is-paused #session-rest-shape {
  animation-play-state: paused;
}
```

- [ ] **Step 4: Recompose completion and tracked review without changing the form contract**

Add exact helpers in `SessionLive` so string form values are safely rendered as metrics:

```elixir
defp completion_integer(form, field) do
  case Integer.parse(to_string(form[field].value || "")) do
    {value, ""} -> value
    _ -> 0
  end
end

defp completion_duration_label(form) do
  form
  |> completion_integer(:duration_sec_actual)
  |> Fmt.duration_sec()
end
```

Add a stable summary wrapper:

```heex
<section id="session-completion-summary" class="text-center">
  <p class="qs-tabular text-[clamp(5rem,24vw,9rem)] font-semibold leading-none tracking-[-0.08em]">
    {completion_integer(@form, :burpee_count_actual)}
  </p>
  <p class="mt-3 text-sm text-[var(--session-muted)]">done</p>
  <p class="qs-tabular mt-8 text-3xl font-medium">{completion_duration_label(@form)}</p>
</section>
```

Keep the existing `<.form for={@form} id="session-completion-form" ...>` and every existing `<.input field={@form[...]}>`, mood button, tag button, note, validation message, and event binding. Add:

```heex
<button id="session-save-btn" type="submit" class="w-full rounded-2xl bg-[var(--session-ink)] px-6 py-5 text-base font-semibold text-[var(--session-bg)]">
  Save session
</button>
<button id="session-discard-btn" type="button" phx-click="discard" data-confirm="Discard this session?" class="mx-auto block px-6 py-3 text-sm text-[var(--session-muted)]">
  Discard
</button>
```

Keep `#tracked-review` but flatten its decorative card treatment into the same summary flow. Preserve all celebration data/functions. Inside `#celebration-overlay`, replace each `qs_surface` card with a flat divider row:

```heex
<div class="w-full border-t border-[var(--session-border)] py-6 text-center last:border-b">
  <p class="text-sm text-[var(--session-muted)]">{celebration_title(event)}</p>
  <p class="qs-tabular mt-2 text-5xl font-semibold tracking-[-0.06em]">{celebration_headline(event)}</p>
  <p class="mt-2 text-sm text-[var(--session-muted)]">{celebration_detail(event)}</p>
</div>
```

Keep `phx-click="dismiss_celebration"`, change only the Continue button classes to the same full-width rounded ink action used by the ready/save states, and keep its visible copy `Continue`.

- [ ] **Step 5: Run formatter and focused tests**

Run:

```bash
mix format lib/burpee_trainer_web/live/session_live.ex test/burpee_trainer_web/live/app_flow_test.exs
cd assets && npm test
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: PASS; completion save still creates a session, tracked completion still opens analysis, and discard remains confirmation-protected.

- [ ] **Step 6: Commit pause and completion surfaces**

```bash
jj describe -m "feat(session): redesign pause and completion surfaces"
jj new
```

---

### Task 6: Accessibility, Responsive Polish, and Full Verification

**Files:**

- Modify: `assets/css/app.css`
- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_renderer_test.mjs`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/app_flow_test.exs`

**Interfaces:**

- Consumes: all prior tasks.
- Produces: a shippable session redesign at 320px and modern iPhone widths, with reduced-motion behavior and no stale ring/set-map code.

- [ ] **Step 1: Write failing accessibility-state tests**

Update the `element()` helper in `session_renderer_test.mjs` to retain attributes:

```javascript
function element() {
  const attributes = new Map();
  return {
    attributes,
    classList: classList(),
    style: {},
    textContent: "",
    firstChild: null,
    appendChild() {},
    removeChild() {},
    setAttribute(name, value) { attributes.set(name, String(value)); },
    getAttribute(name) { return attributes.get(name) || null; },
  };
}
```

Add `"#ring-container": element()` to the harness and append:

```javascript
test("renderer exposes meaningful count and pause labels", () => {
  const {renderer, elements} = harness();
  renderer.renderDisplayModel({
    visual: {state: "work", progress: 0.5, pulse: null},
    primaryCount: 5,
    countdownDots: null,
    totalDone: 4,
    totalTarget: 20,
    timeLeftSec: 60,
  });

  assert.equal(elements["#count"].getAttribute("aria-label"), "5 reps remaining");
  assert.equal(elements["#ring-container"].getAttribute("aria-label"), "Pause session");

  renderer.updatePauseButton(true);
  assert.equal(elements["#ring-container"].getAttribute("aria-label"), "Resume session");
});
```

- [ ] **Step 2: Run the accessibility test and verify it fails**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs
```

Expected: FAIL because the renderer does not yet assign state-specific accessible labels.

- [ ] **Step 3: Add explicit accessibility state updates**

Store the current visual state/count in `renderDisplayModel/1`, then update labels without adding visible copy:

```javascript
updateAccessibleState({state, primaryCount}) {
  const target = this.root.querySelector("#ring-container");
  const count = this.root.querySelector("#count");
  const primaryLabel = state === "work"
    ? `${primaryCount} reps remaining`
    : state?.startsWith("rest-")
      ? `Rest time remaining ${primaryCount}`
      : "Workout starting";

  if (target) {
    target.setAttribute("aria-label", this.paused ? "Resume session" : "Pause session");
  }
  if (count) count.setAttribute("aria-label", primaryLabel);
}
```

In `renderDisplayModel/1`:

```javascript
this.currentVisualState = visual.state;
this.currentPrimaryCount = model.primaryCount;
this.updateAccessibleState({state: visual.state, primaryCount: model.primaryCount});
```

In `updatePauseButton/1`, call:

```javascript
this.updateAccessibleState({
  state: this.currentVisualState,
  primaryCount: this.currentPrimaryCount,
});
```

Keep color-independent numbers and existing keyboard pause/resume handling.

- [ ] **Step 4: Complete responsive and reduced-motion CSS**

Verify/adjust these exact constraints:

```css
@media (max-width: 360px) {
  #count { font-size: clamp(6rem, 31vw, 8rem); }
  #session-status-line #total-done,
  #session-status-line #time-left { font-size: clamp(3rem, 15vw, 4rem); }
}

@media (prefers-reduced-motion: reduce) {
  #session-work-fill,
  #session-rest-shape,
  #count,
  #session-pause-actions {
    animation: none !important;
    transition-duration: 1ms !important;
  }
}
```

Ensure the rest shape's visible maximum remains below 50dvh and bottom stats remain legible on both warm-paper and colored surfaces.

- [ ] **Step 5: Run stale-contract searches**

Run:

```bash
rg "session_ring|ring-svg|flash-circle|rest-ripple|set-glyphs|updateWorkRing|renderSetGlyphs" assets lib test
rg -n 'Rest|Get ready|Start position|Next set' lib/burpee_trainer_web/live/session_live.ex assets/js/hooks/session_hook.js assets/js/hooks/session_renderer.mjs
```

Expected: first command has no runtime-code matches. Second command has no active-surface copy matches; setup/history text outside the active surface must be reviewed rather than blindly deleted.

- [ ] **Step 6: Run proactive diagnostics before builds**

Use Pi's LSP diagnostics on:

- `lib/burpee_trainer_web/live/session_live.ex`
- `test/burpee_trainer_web/live/app_flow_test.exs`
- `assets/js/hooks/session_display_model.mjs`
- `assets/js/hooks/session_renderer.mjs`
- `assets/js/hooks/session_hook.js`

Expected: no blocking errors.

- [ ] **Step 7: Run complete JavaScript and focused Elixir tests**

Run:

```bash
cd assets && npm test
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: PASS.

- [ ] **Step 8: Run the project pre-commit gate**

Run:

```bash
mix precommit
```

Expected: compile with warnings-as-errors, dependency checks, formatting, and the full ExUnit suite all PASS.

- [ ] **Step 9: Perform manual visual checks**

Run the app and verify:

1. 320px viewport: no clipped primary number, bottom stat, camera action, or paused action.
2. Work: orange fill grows `0→1` for every rep and resets immediately.
3. Rest: blue shape breathes for 8.4 seconds and never fills the screen.
4. Rest at `5`/`4`: breathing stops and surface settles toward orange.
5. Rest at `3`/`2`/`1`: numeric pulse plus exactly one beep per number; no dots.
6. Initial count-in: dots remain.
7. Pause: exact visual state freezes; pause glyph and actions appear; resume continues correctly.
8. Camera: preview/overlay show only during setup; tracking continues after hidden.
9. Completion/review/save: values and actions behave exactly as before.
10. Reduced motion: no continuous breathing/pulse motion, but counts and color/state changes remain clear.
11. Not runnable: an execution program with no timed events shows `#session-not-runnable` with the existing guidance and no broken active controls.

- [ ] **Step 10: Commit final polish**

```bash
jj describe -m "fix(session): polish workout accessibility and motion"
jj new
```
