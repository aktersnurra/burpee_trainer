# Session UI Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the live Session runner into a warm-paper monochrome training instrument while preserving existing session behavior.

**Architecture:** Keep `SessionLive` as the server-rendered shell and keep `SessionHook` as the behavior owner. Move visual state updates through `SessionRenderer`, adding small DOM targets for the new instrument, set glyphs, rest inversion, count-in, and pause states without changing persistence or session completion logic.

**Tech Stack:** Phoenix LiveView 1.8, HEEx, Tailwind v4, vanilla JavaScript hooks, Node `--test`, ExUnit, jj.

---

## File Map

- Modify `lib/burpee_trainer_web/live/session_live.ex`
  - Replace the dark dashboard runner markup with warm-paper instrument markup.
  - Add DOM targets for ring, count, grouped set glyphs, done/total reps, time left, count-in, rest, and pause states.
  - Keep `id="session-runner-client"`, `id="ring-container"`, `id="ring-svg"`, `id="count"`, `id="total-done"`, `id="total-plan"`, `id="progress-fill"`, and `id="time-left"` or intentionally migrate renderer selectors in the same task.

- Modify `assets/js/hooks/session_renderer.mjs`
  - Render depleting ring progress.
  - Add visual state class toggles for work/rest/count-in/paused.
  - Render grouped set glyphs from plan/timeline information.
  - Keep existing public methods unless explicitly updated in the same task.

- Modify `assets/js/hooks/session_hook.js`
  - Pass enough plan/timeline structure to `SessionRenderer` for set glyphs.
  - Ensure ring-container tap remains the pause/resume target.
  - Keep existing session flow and segment FSM behavior unchanged.

- Modify `test/burpee_trainer_web/live/session_live_test.exs`
  - Update structural LiveView tests to assert the new runner DOM and absence of visual-noise labels.

- Create `assets/js/hooks/session_renderer_test.mjs`
  - Unit-test renderer-only behavior using a lightweight DOM stub or `node:test` with a minimal fake root.

---

## Task 1: Update LiveView runner shell

**Files:**

- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `test/burpee_trainer_web/live/session_live_test.exs`

- [ ] **Step 1: Update the existing runner structural test first**

Replace the current test named `runner keeps client-owned fixed ring box and thicker progress bar` in `test/burpee_trainer_web/live/session_live_test.exs` with:

```elixir
test "runner renders warm-paper instrument shell", %{conn: conn, user: user} do
  plan = plan_fixture(user)
  {:ok, view, _html} = live(conn, ~p"/session/#{plan.id}")

  assert has_element?(view, "#session-runner-client[phx-update=ignore]")
  assert has_element?(view, "#ring-container[aria-label='Pause or resume session']")
  assert has_element?(view, "svg#ring-svg")
  assert has_element?(view, "#set-glyphs[aria-label='Workout sets']")
  assert has_element?(view, "#total-done")
  assert has_element?(view, "#total-plan")
  assert has_element?(view, "#time-left")

  html = render(view)
  refute html =~ "REPS LEFT"
  refute html =~ "RUNNING"
  refute html =~ "BEAT"
  refute html =~ "BLOCKS"
end
```

- [ ] **Step 2: Run the failing LiveView test**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs --trace
```

Expected: this test fails because `#set-glyphs` and the new aria label do not exist yet, and old runner markup still contains the old dark structure.

- [ ] **Step 3: Replace `session_runner/1` markup**

In `lib/burpee_trainer_web/live/session_live.ex`, replace only the `session_runner/1` function body with this HEEx structure. Keep the function name and attrs unchanged.

```elixir
defp session_runner(assigns) do
  ~H"""
  <div
    id="session-runner-client"
    class="relative min-h-[calc(100dvh-8rem)] overflow-hidden rounded-[2px] border border-[#ded8ca] bg-[#f4f0e6] px-6 py-8 text-[#070707]"
    phx-update="ignore"
  >
    <div
      id="ring-container"
      class="group relative mx-auto mt-8 h-[280px] w-[280px] cursor-pointer select-none touch-manipulation"
      style="flex: 0 0 280px;"
      role="button"
      tabindex="0"
      aria-label="Pause or resume session"
    >
      <svg
        id="ring-svg"
        viewBox="0 0 280 280"
        class="absolute inset-0 h-[280px] w-[280px]"
        aria-hidden="true"
      >
      </svg>

      <svg
        viewBox="0 0 280 280"
        class="pointer-events-none absolute inset-0 h-[280px] w-[280px]"
        aria-hidden="true"
      >
        <circle
          id="flash-circle"
          cx="140"
          cy="140"
          r="107"
          fill="none"
          stroke="#070707"
          stroke-width="10"
          opacity="0"
          transform="rotate(-90 140 140)"
        />
      </svg>

      <div
        id="instrument-face"
        class="pointer-events-none absolute inset-0 flex flex-col items-center justify-center rounded-full transition-colors duration-200"
      >
        <span
          id="count"
          class="text-[116px] font-black leading-none tracking-[-0.1em] tabular-nums text-[#070707]"
        >
          —
        </span>
        <span
          id="down-word"
          class="absolute text-[32px] font-mono font-semibold uppercase tracking-[0.18em] text-[#070707]"
          style="display: none;"
        >
          Down
        </span>
        <svg
          id="pause-icon"
          viewBox="0 0 48 48"
          fill="currentColor"
          class="absolute h-16 w-16 text-[#f4f0e6]"
          style="display: none;"
          aria-hidden="true"
        >
          <rect x="10" y="8" width="10" height="32" rx="2" />
          <rect x="28" y="8" width="10" height="32" rx="2" />
        </svg>
      </div>
    </div>

    <div
      id="set-glyphs"
      class="mt-6 flex min-h-7 items-end justify-center gap-4"
      aria-label="Workout sets"
    >
    </div>

    <div class="mt-7 grid grid-cols-2 border-y border-[#ded8ca] text-center font-mono">
      <div class="border-r border-[#ded8ca] px-2 py-4">
        <div
          id="total-done"
          class="text-[30px] font-black leading-none tracking-[-0.04em] tabular-nums text-[#070707]"
        >
          0
        </div>
        <div class="mt-1 text-[8px] uppercase tracking-[0.22em] text-[#777064]">
          Done / <span id="total-plan">{@summary.burpee_count_total}</span>
        </div>
      </div>
      <div class="px-2 py-4">
        <div
          id="time-left"
          class="text-[30px] font-black leading-none tracking-[-0.04em] tabular-nums text-[#070707]"
        >
          {Fmt.duration_sec(round(@summary.duration_sec_total))}
        </div>
        <div class="mt-1 text-[8px] uppercase tracking-[0.22em] text-[#777064]">
          Time left
        </div>
      </div>
    </div>

    <div class="sr-only">
      <div class="h-3 w-full overflow-hidden rounded-full bg-[#ddd6c7]">
        <div id="progress-fill" class="h-full transition-none" style="width: 0%; background-color: #070707;" />
      </div>
    </div>

    <%= if @phase == :idle do %>
      <.tap_to_start_overlay warmup_asked={@warmup_asked} />
    <% end %>
  </div>
  """
end
```

Notes:

- `#progress-fill` remains in an `sr-only` wrapper for compatibility during this task. Later tasks can stop relying on it if all renderer callers are updated.
- The old top `#block-info` remains outside `session_runner/1` for now. Do not redesign it in this task.

- [ ] **Step 4: Run the LiveView test again**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs --trace
```

Expected: LiveView tests pass, or failures are limited to changed copy/selectors in the updated structural test. Fix only those selector mismatches.

- [ ] **Step 5: Describe the jj change**

Run:

```bash
jj describe -m "refactor(session): add warm paper runner shell"
jj new
```

Expected: the shell change is saved in a described jj change and a fresh empty working-copy change is created.

---

## Task 2: Make the renderer deplete rings and support visual modes

**Files:**

- Modify: `assets/js/hooks/session_renderer.mjs`
- Create: `assets/js/hooks/session_renderer_test.mjs`

- [ ] **Step 1: Create renderer tests for ring depletion and mode classes**

Create `assets/js/hooks/session_renderer_test.mjs`:

```javascript
import assert from "node:assert/strict";
import test from "node:test";
import { SessionRenderer } from "./session_renderer.mjs";

function el(tag, attrs = {}) {
  return {
    tag,
    attrs: { ...attrs },
    style: {},
    children: [],
    textContent: "",
    firstChild: null,
    appendChild(child) {
      this.children.push(child);
      this.firstChild = this.children[0] || null;
    },
    removeChild(child) {
      this.children = this.children.filter((c) => c !== child);
      this.firstChild = this.children[0] || null;
    },
    setAttribute(name, value) {
      this.attrs[name] = String(value);
    },
    getAttribute(name) {
      return this.attrs[name];
    },
    classList: {
      values: new Set(),
      add(...names) {
        names.forEach((name) => this.values.add(name));
      },
      remove(...names) {
        names.forEach((name) => this.values.delete(name));
      },
      contains(name) {
        return this.values.has(name);
      },
    },
  };
}

function root() {
  const nodes = {
    "#ring-svg": el("svg"),
    "#ring-container": el("div"),
    "#instrument-face": el("div"),
    "#count": el("span"),
    "#down-word": el("span"),
    "#pause-icon": el("svg"),
    "#time-left": el("div"),
  };

  return {
    nodes,
    querySelector(selector) {
      return nodes[selector] || null;
    },
  };
}

global.document = {
  createElementNS(_ns, tag) {
    return el(tag);
  },
};

test("work ring depletes as progress increases", () => {
  const dom = root();
  const renderer = new SessionRenderer(dom);

  renderer.enterWorkPhase();
  renderer.updateWorkRing(0, "#070707");
  const startOffset = Number(renderer.workRingEl.getAttribute("stroke-dashoffset"));

  renderer.updateWorkRing(0.75, "#070707");
  const laterOffset = Number(renderer.workRingEl.getAttribute("stroke-dashoffset"));

  assert.equal(renderer.workRingEl.getAttribute("stroke"), "#070707");
  assert.ok(laterOffset > startOffset, "depleting ring offset should increase as progress advances");
});

test("rest mode inverts instrument and renders time", () => {
  const dom = root();
  const renderer = new SessionRenderer(dom);

  renderer.enterRestPhase();
  renderer.renderRestProgress(0.5, "#f4f0e6", 42);

  assert.equal(dom.nodes["#count"].textContent, "42");
  assert.equal(dom.nodes["#count"].style.color, "#f4f0e6");
  assert.ok(dom.nodes["#ring-container"].classList.contains("is-resting"));
});

test("paused mode hides count and shows pause icon", () => {
  const dom = root();
  const renderer = new SessionRenderer(dom);

  renderer.updatePauseButton(true);

  assert.equal(dom.nodes["#count"].style.visibility, "hidden");
  assert.equal(dom.nodes["#pause-icon"].style.display, "");
  assert.ok(dom.nodes["#ring-container"].classList.contains("is-paused"));
});
```

- [ ] **Step 2: Run renderer tests to verify failure**

Run:

```bash
cd assets && npm test -- js/hooks/session_renderer_test.mjs
```

Expected: tests fail because the current work ring fills by decreasing offset and no `is-resting` / `is-paused` classes are set.

- [ ] **Step 3: Update ring math and visual mode classes**

In `assets/js/hooks/session_renderer.mjs`:

1. Add helpers inside `SessionRenderer`:

```javascript
setMode(mode) {
  const ringContainer = this.root.querySelector("#ring-container");
  if (!ringContainer) return;
  ringContainer.classList.remove("is-working", "is-resting", "is-counting-in", "is-paused");
  if (mode) ringContainer.classList.add(mode);
}

depletingOffset(progress) {
  return CIRC * Math.min(Math.max(progress, 0), 1);
}
```

2. In `enterWorkPhase()`, call:

```javascript
this.setMode("is-working");
this.buildWorkRing();
```

3. In `enterRestPhase()`, before creating the rest ring, call:

```javascript
this.setMode("is-resting");
```

4. In `updateWorkRing(repProgress, color)`, change offset calculation to:

```javascript
const offset = this.depletingOffset(repProgress);
```

5. In `renderRestProgress(progress, color, timeLeftSec)`, change offset calculation to:

```javascript
const offset = this.depletingOffset(progress);
```

6. In `updatePauseButton(paused)`, add class behavior:

```javascript
if (paused) {
  if (ringContainer) ringContainer.classList.add("is-paused");
  ...
} else {
  if (ringContainer) ringContainer.classList.remove("is-paused");
  ...
}
```

Do not change the names of existing renderer methods.

- [ ] **Step 4: Run renderer tests again**

Run:

```bash
cd assets && npm test -- js/hooks/session_renderer_test.mjs
```

Expected: `session_renderer_test.mjs` passes.

- [ ] **Step 5: Run all JS hook tests**

Run:

```bash
cd assets && npm test
```

Expected: all hook tests pass. If existing session FSM tests fail, inspect whether the renderer test command accidentally changed behavior outside renderer; do not alter FSM logic for this UI task.

- [ ] **Step 6: Describe the jj change**

Run:

```bash
jj describe -m "refactor(session): deplete runner rings"
jj new
```

---

## Task 3: Render grouped set glyphs from the loaded plan

**Files:**

- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer_test.mjs`

- [ ] **Step 1: Add renderer tests for grouped set glyphs**

Append to `assets/js/hooks/session_renderer_test.mjs`:

```javascript
test("set glyphs group sets by block and fill current set", () => {
  const glyphs = el("div");
  const dom = root();
  dom.nodes["#set-glyphs"] = glyphs;
  const renderer = new SessionRenderer(dom);

  renderer.renderSetGlyphs([
    { setCount: 3, completedSets: 3, currentSetProgress: null },
    { setCount: 3, completedSets: 1, currentSetProgress: 0.5 },
    { setCount: 2, completedSets: 0, currentSetProgress: null },
  ]);

  assert.equal(glyphs.children.length, 3);
  assert.equal(glyphs.children[0].children.length, 3);
  assert.equal(glyphs.children[1].children.length, 3);
  assert.equal(glyphs.children[2].children.length, 2);
  assert.equal(glyphs.children[1].children[1].style.background, "linear-gradient(to top, #070707 50%, #ddd6c7 50%)");
});
```

- [ ] **Step 2: Run renderer tests to verify failure**

Run:

```bash
cd assets && npm test -- js/hooks/session_renderer_test.mjs
```

Expected: failure because `renderSetGlyphs` is not defined.

- [ ] **Step 3: Implement `renderSetGlyphs`**

Add this method to `SessionRenderer` in `assets/js/hooks/session_renderer.mjs`:

```javascript
renderSetGlyphs(blocks) {
  const container = this.root.querySelector("#set-glyphs");
  if (!container) return;
  while (container.firstChild) container.removeChild(container.firstChild);

  blocks.forEach((block) => {
    const group = document.createElement("div");
    group.className = "flex items-end gap-1";

    for (let i = 0; i < block.setCount; i += 1) {
      const mark = document.createElement("span");
      mark.className = "block w-[7px] h-[22px]";

      if (i < block.completedSets) {
        mark.style.background = "#070707";
      } else if (i === block.completedSets && block.currentSetProgress !== null) {
        const pct = Math.round(Math.min(Math.max(block.currentSetProgress, 0), 1) * 100);
        mark.style.background = `linear-gradient(to top, #070707 ${pct}%, #ddd6c7 ${pct}%)`;
      } else {
        mark.style.background = "#ddd6c7";
      }

      group.appendChild(mark);
    }

    container.appendChild(group);
  });
}
```

If the test fake DOM lacks `document.createElement`, add it beside `createElementNS` in the test:

```javascript
createElement(tag) {
  return el(tag);
},
```

- [ ] **Step 4: Derive glyph blocks in `session_hook.js`**

In `assets/js/hooks/session_hook.js`:

1. Add an instance field in `mounted()` after `this.blockCount = 0;`:

```javascript
this.setGlyphBlocks = [];
```

2. Add a method on `SessionHook`:

```javascript
setGlyphBlocksFromPlan(plan) {
  this.setGlyphBlocks = (plan.blocks || []).map((block) => ({
    setCount: (block.sets || []).length * (block.repeat_count || 1),
    completedSets: 0,
    currentSetProgress: null,
  }));
  this.renderer.renderSetGlyphs(this.setGlyphBlocks);
}
```

3. In the `session_ready` event handler, before `this.dispatchFlow(...)`, call:

```javascript
this.setGlyphBlocksFromPlan(plan);
```

This creates the initial grouped structure. It does not yet advance the current set; that happens in the next step.

- [ ] **Step 5: Run JS tests**

Run:

```bash
cd assets && npm test
```

Expected: all JS tests pass.

- [ ] **Step 6: Describe the jj change**

Run:

```bash
jj describe -m "refactor(session): render grouped set glyphs"
jj new
```

---

## Task 4: Advance set glyph fill during workout frames

**Files:**

- Modify: `assets/js/hooks/session_hook.js`
- Modify: `assets/js/hooks/session_renderer_test.mjs`

- [ ] **Step 1: Add a pure helper for set progress mapping**

In `assets/js/hooks/session_hook.js`, export a pure helper near the top of the file after constants:

```javascript
export function setGlyphBlocksFromFrame(plan, frame) {
  let remainingCompletedSets = frame.completedSetCount || 0;
  let currentSetIndex = frame.currentSetIndex ?? null;

  return (plan.blocks || []).map((block) => {
    const setCount = (block.sets || []).length * (block.repeat_count || 1);
    const completedSets = Math.min(remainingCompletedSets, setCount);
    remainingCompletedSets = Math.max(remainingCompletedSets - setCount, 0);

    let currentSetProgress = null;
    if (currentSetIndex !== null) {
      if (currentSetIndex < setCount) {
        currentSetProgress = frame.currentSetProgress ?? null;
        currentSetIndex = null;
      } else {
        currentSetIndex -= setCount;
      }
    }

    return { setCount, completedSets, currentSetProgress };
  });
}
```

- [ ] **Step 2: Add a focused test file for the helper**

Create `assets/js/hooks/session_set_glyphs_test.mjs`:

```javascript
import assert from "node:assert/strict";
import test from "node:test";
import { setGlyphBlocksFromFrame } from "./session_hook.js";

test("maps completed and current set progress into block groups", () => {
  const plan = {
    blocks: [
      { repeat_count: 1, sets: [{}, {}, {}] },
      { repeat_count: 1, sets: [{}, {}, {}] },
      { repeat_count: 1, sets: [{}, {}] },
    ],
  };

  const blocks = setGlyphBlocksFromFrame(plan, {
    completedSetCount: 4,
    currentSetIndex: 4,
    currentSetProgress: 0.5,
  });

  assert.deepEqual(blocks, [
    { setCount: 3, completedSets: 3, currentSetProgress: null },
    { setCount: 3, completedSets: 1, currentSetProgress: 0.5 },
    { setCount: 2, completedSets: 0, currentSetProgress: null },
  ]);
});
```

- [ ] **Step 3: Run the helper test to verify likely failure**

Run:

```bash
cd assets && npm test -- js/hooks/session_set_glyphs_test.mjs
```

Expected: if `session_hook.js` imports browser-only globals at module load, this test may fail. If it does, move the pure helper into a new file `assets/js/hooks/session_set_glyphs.mjs`, export it there, import it from `session_hook.js`, and update the test import to `./session_set_glyphs.mjs`.

- [ ] **Step 4: Wire glyph updates to actual frames**

Inspect `currentFrame(...)` output in `assets/js/hooks/session_segment_fsm.mjs`. If it already exposes set index/progress, use those fields. If not, derive conservative glyph updates from segment transitions only:

- Completed sets fill when the segment changes to a later set.
- Current set fills with `command.progress` in `renderWorkRepProgress`.

Add a method to `SessionHook`:

```javascript
renderSetGlyphsForCurrentFrame(frame) {
  if (!this.plan) return;
  const blocks = setGlyphBlocksFromFrame(this.plan, frame);
  this.renderer.renderSetGlyphs(blocks);
}
```

Then call it from `renderRunningFrame(elapsedSec)` or from the command handling site that has access to the frame. Do not change FSM semantics.

- [ ] **Step 5: Run JS tests**

Run:

```bash
cd assets && npm test
```

Expected: all JS tests pass.

- [ ] **Step 6: Describe the jj change**

Run:

```bash
jj describe -m "refactor(session): advance set glyph progress"
jj new
```

---

## Task 5: Apply rest, count-in, and pause visual states

**Files:**

- Modify: `assets/js/hooks/session_renderer.mjs`
- Modify: `assets/js/hooks/session_hook.js`
- Modify: `lib/burpee_trainer_web/live/session_live.ex`
- Modify: `assets/js/hooks/session_renderer_test.mjs`

- [ ] **Step 1: Add renderer tests for count-in mode**

Append to `assets/js/hooks/session_renderer_test.mjs`:

```javascript
test("count-in mode marks instrument without rest inversion", () => {
  const dom = root();
  const renderer = new SessionRenderer(dom);

  renderer.enterCountInPhase();

  assert.ok(dom.nodes["#ring-container"].classList.contains("is-counting-in"));
  assert.ok(!dom.nodes["#ring-container"].classList.contains("is-resting"));
});
```

- [ ] **Step 2: Run renderer tests to verify failure**

Run:

```bash
cd assets && npm test -- js/hooks/session_renderer_test.mjs
```

Expected: failure because `enterCountInPhase` does not exist.

- [ ] **Step 3: Implement count-in mode**

Add to `SessionRenderer`:

```javascript
enterCountInPhase() {
  this.setMode("is-counting-in");
  const countEl = this.root.querySelector("#count");
  if (countEl) {
    countEl.style.color = "#070707";
    countEl.style.visibility = "";
  }
}
```

In `countdownShowCount` logic in `session_hook.js`, call:

```javascript
this.renderer.enterCountInPhase();
```

before rendering the countdown value.

- [ ] **Step 4: Add CSS state selectors in `assets/css/app.css`**

Append a small session section near the existing session runner animation styles:

```css
#ring-container.is-resting #instrument-face {
  background: #070707;
}

#ring-container.is-resting #count {
  color: #f4f0e6;
}

#ring-container.is-counting-in #instrument-face {
  background: transparent;
}

#ring-container.is-paused #instrument-face {
  background: #070707;
}
```

No new color palette variables are required in this first slice.

- [ ] **Step 5: Run tests and formatter**

Run:

```bash
cd assets && npm test
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all pass.

- [ ] **Step 6: Describe the jj change**

Run:

```bash
jj describe -m "refactor(session): add runner mode visuals"
jj new
```

---

## Task 6: Final verification and precommit

**Files:**

- Modify only if verification exposes issues in files touched by previous tasks.

- [ ] **Step 1: Run JS tests**

Run:

```bash
cd assets && npm test
```

Expected: all Node hook tests pass.

- [ ] **Step 2: Run Session LiveView tests**

Run:

```bash
mix test test/burpee_trainer_web/live/session_live_test.exs
```

Expected: all session LiveView tests pass.

- [ ] **Step 3: Run project precommit**

Run:

```bash
mix precommit
```

Expected: compile, format checks, unused deps check, and tests pass.

- [ ] **Step 4: Manual browser check**

Run:

```bash
mix phx.server
```

Open the app and navigate to a session. Verify:

- Warm-paper instrument shell appears.
- Ring depletes during work.
- Tapping the instrument pauses/resumes.
- Rest inverts the instrument instead of adding color.
- Count-in is sparse and not inverted.
- Set glyphs are grouped by blocks.
- Done / total reps and time left are readable.
- No `REPS LEFT`, `RUNNING`, `BEAT`, or `BLOCKS` labels appear in the running UI.

Stop the server after checking.

- [ ] **Step 5: Describe final jj change if fixes were needed**

If final verification required fixes, run:

```bash
jj describe -m "fix(session): polish runner verification issues"
jj new
```

If no fixes were needed and `jj st` is empty, do not create an empty described change.

---

## Self-Review Notes

Spec coverage:

- Warm-paper visual shell: Task 1.
- Ring depletion: Task 2.
- Tap instrument to pause: Task 1 keeps the ring target and Task 2 preserves `updatePauseButton` state.
- Grouped set glyphs: Tasks 3 and 4.
- Rest inversion: Task 5.
- Count-in sparse visual mode: Task 5.
- Done / total reps and time-left readability: Task 1.
- Avoided noise labels: Task 1 test asserts absence.
- Existing behavior preserved: all tasks constrain changes to markup/renderer/hook visuals and verify with JS tests, LiveView tests, and `mix precommit`.

No placeholders remain. The one conditional in Task 4 is bounded: if `session_hook.js` cannot be imported under Node because of browser globals, move the pure helper into the named file `session_set_glyphs.mjs` and update the import path.
