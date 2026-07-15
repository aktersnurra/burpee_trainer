# Rest Animation Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the rest breathing surface from roughly 25% to 75% viewport height and transform it into a pulsing orange contour for the final `3`, `2`, `1` without changing workout timing or audio behavior.

**Architecture:** Keep `rest-breathe`, `rest-settle`, and `rest-countdown` as the authoritative display states. `SessionRenderer` captures the live CSS breathing transform when settle begins and coordinates one contour pulse class with the existing numeral pulse; CSS owns geometry, fill-to-contour interpolation, countdown motion, and reduced-motion fallbacks.

**Tech Stack:** Phoenix LiveView 1.8, JavaScript ES modules, Node test runner, Tailwind CSS v4 plus custom CSS, ExUnit, Jujutsu.

## Global Constraints

- Preserve existing workout timing, state transitions, pause behavior, audio cues, tracking, persistence, and per-rep work progress.
- Keep the existing 8.4-second breathing cycle: 4.2 seconds expanding and 4.2 seconds contracting.
- Move the visible breathing edge through approximately 25%→75%→25% of viewport height without reaching full screen.
- At `5`, stop breathing at the currently rendered geometry without snapping; use `5` and `4` to drain the blue fill into an orange contour.
- At `3`, `2`, and `1`, pulse both the orange contour and numeral once and retain exactly one existing beep per value.
- Remove the circular countdown halo; do not add labels or explanatory copy.
- Initial pre-workout count-in dots remain unchanged.
- Reduced motion uses discrete filled-blue, orange-contour, and numeral states while retaining beeps.
- Preserve Tailwind v4 import syntax and do not add dependencies.

## File Map

- Modify `assets/js/hooks/session_renderer.mjs`: capture the live breathing transform before class transition; coordinate contour and numeral pulse classes; clear countdown pulse state on exit.
- Modify `assets/js/hooks/session_renderer_test.mjs`: model CSS style properties and CSS animations; cover no-snap capture, one contour pulse per number, duplicate-frame suppression, and work-entry cleanup.
- Modify `assets/css/app.css`: implement exact breathing range, two-second fill-to-contour settle, orange contour pulse, and reduced-motion states.
- Modify `assets/js/hooks/session_styles_test.mjs`: lock the CSS geometry, transition, pulse, old-halo removal, pause, and reduced-motion contracts.
- Do not modify `session_display_model.mjs`, `session_segment_fsm.mjs`, `session_hook.js`, or `session_live.ex`; their timing, beeps, states, and DOM already provide the required inputs.

---

### Task 1: Capture the Live Rest Shape and Coordinate Countdown Pulses

**Files:**

- Modify: `assets/js/hooks/session_renderer_test.mjs:19-90,164-229`
- Modify: `assets/js/hooks/session_renderer.mjs:20-52,200-219`

**Interfaces:**

- Consumes: existing visual states `rest-breathe`, `rest-settle`, and `rest-countdown`; existing `model.visual.pulse` values `3 | 2 | 1 | null`.
- Produces: `SessionRenderer.captureRestSettleStart()` and the `is-contour-pulse` class on `#session-rest-shape`.
- CSS contract for Task 2: `--session-rest-settle-from-transform` contains the committed breathing transform and `is-contour-pulse` is added once per changed countdown value.

- [ ] **Step 1: Extend the renderer test harness with CSS style and animation behavior**

Add this helper before `element()` in `assets/js/hooks/session_renderer_test.mjs`:

```javascript
function style() {
	return {
		setProperty(name, value) {
			this[name] = String(value);
		},
		getPropertyValue(name) {
			return this[name] || "";
		},
		removeProperty(name) {
			delete this[name];
		},
	};
}
```

In the object returned by `element()`, replace `style: {},` with `style: style(),` and add this method next to `getAttribute`:

```javascript
getAnimations() {
	return [];
},
```

This keeps existing direct assignments such as `node.style.transform = "scaleY(0.5)"` working while exposing the browser APIs used by the new renderer path.

- [ ] **Step 2: Write failing renderer regressions**

Add these tests after `rest switches from breathing to settle to numeric countdown`:

```javascript
test("rest settle captures the live breathing transform without snapping", () => {
	const { renderer, elements } = harness();
	const shape = elements["#session-rest-shape"];
	const calls = [];
	shape.getAnimations = () => [
		{
			animationName: "session-breathe",
			commitStyles() {
				calls.push("commit");
				shape.style.transform = "matrix(1, 0, 0, 0.63, 0, 0)";
			},
			cancel() {
				calls.push("cancel");
			},
		},
	];

	renderer.renderDisplayModel({
		visual: { state: "rest-breathe", progress: 0, pulse: null },
		primaryCount: 6,
	});
	renderer.renderDisplayModel({
		visual: { state: "rest-settle", progress: 0, pulse: null },
		primaryCount: 5,
	});

	assert.deepEqual(calls, ["commit", "cancel"]);
	assert.equal(
		shape.style.getPropertyValue("--session-rest-settle-from-transform"),
		"matrix(1, 0, 0, 0.63, 0, 0)",
	);
	assert.equal(shape.style.transform, undefined);

	renderer.renderDisplayModel({
		visual: { state: "rest-settle", progress: 0, pulse: null },
		primaryCount: 4,
	});
	assert.deepEqual(calls, ["commit", "cancel"]);
});

test("work entry clears the between-set contour pulse", () => {
	const { renderer, elements } = harness();
	const shape = elements["#session-rest-shape"];

	renderer.renderDisplayModel({
		visual: { state: "rest-countdown", progress: 0, pulse: 3 },
		primaryCount: 3,
	});
	assert.equal(shape.classList.contains("is-contour-pulse"), true);

	renderer.renderDisplayModel({
		visual: { state: "work", progress: 0, pulse: null },
		primaryCount: 6,
	});
	assert.equal(shape.classList.contains("is-contour-pulse"), false);
	assert.equal(
		elements["#count"].classList.contains("countdown-pop"),
		false,
	);
});
```

Extend `between-set pulse survives duplicate frames and retriggers once per number` by declaring the shape and asserting its pulse count alongside the numeral:

```javascript
const shape = elements["#session-rest-shape"];
```

Inside the loop, after the first render assertions add:

```javascript
assert.equal(shape.classList.contains("is-contour-pulse"), true);
assert.equal(shape.classList.addCount("is-contour-pulse"), index + 1);
```

After the duplicate render add the same two assertions. They prove duplicate animation frames do not restart either pulse.

- [ ] **Step 3: Run the renderer test and verify RED**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs
```

Expected: FAIL because settle does not commit the active breathing animation and `#session-rest-shape` never receives `is-contour-pulse`.

- [ ] **Step 4: Add live-transform capture before the visual-state class changes**

Add this method before `setVisualState()` in `assets/js/hooks/session_renderer.mjs`:

```javascript
captureRestSettleStart() {
	const shape = this.root.querySelector("#session-rest-shape");
	const breathing = shape
		?.getAnimations?.()
		.find((animation) => animation.animationName === "session-breathe");
	if (!breathing?.commitStyles || !breathing?.cancel) return;

	breathing.commitStyles();
	const transform = shape.style.transform;
	breathing.cancel();
	if (transform) {
		shape.style.setProperty(
			"--session-rest-settle-from-transform",
			transform,
		);
	}
	shape.style.removeProperty("transform");
}
```

Replace `setVisualState()` with:

```javascript
setVisualState(state) {
	if (this.appliedVisualState === state) return;

	if (state === "rest-settle" && this.appliedVisualState === "rest-breathe") {
		this.captureRestSettleStart();
	}

	const surface = this.root.querySelector("#session-runner-client");
	const restShape = this.root.querySelector("#session-rest-shape");
	const count = this.root.querySelector("#count");
	if (state !== "rest-countdown") {
		restShape?.classList.remove("is-contour-pulse");
		count?.classList.remove("is-between-set-pulse", "countdown-pop");
	}
	if (state === "rest-breathe") {
		restShape?.style.removeProperty("--session-rest-settle-from-transform");
	}

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

	this.appliedVisualState = state;
}
```

The capture runs while `is-rest-breathe` is still applied, so `commitStyles()` records the presentation transform before the CSS animation is removed.

- [ ] **Step 5: Pulse the contour with the existing numeral pulse**

Replace `renderRestState()` with:

```javascript
renderRestState(model) {
	const count = this.root.querySelector("#count");
	const restShape = this.root.querySelector("#session-rest-shape");
	if (!count) return;

	count.textContent = String(model.primaryCount ?? "");
	count.style.visibility = this.paused ? "hidden" : "";

	const pulse = model.visual?.pulse;
	if (model.visual?.state === "rest-countdown") {
		if (pulse !== this.lastPulseValue) {
			count.classList.remove("is-between-set-pulse", "countdown-pop");
			restShape?.classList.remove("is-contour-pulse");
			count.classList.add("is-between-set-pulse");
			void count.offsetWidth;
			if (restShape) void restShape.offsetWidth;
			count.classList.add("countdown-pop");
			restShape?.classList.add("is-contour-pulse");
		}
	} else {
		count.classList.remove("is-between-set-pulse", "countdown-pop");
		restShape?.classList.remove("is-contour-pulse");
	}
	this.lastPulseValue = pulse;
}
```

Do not alter `model.visual.pulse`, beep dispatch, countdown dots, or state timing.

- [ ] **Step 6: Run renderer and full JavaScript tests**

Run:

```bash
cd assets && node --test js/hooks/session_renderer_test.mjs
cd assets && npm test
```

Expected: both commands PASS with zero failures; existing work-fill, pause, accessible-status, and initial-dot tests remain green.

- [ ] **Step 7: Commit the renderer behavior**

```bash
jj describe -m "feat(session): coordinate rest contour transition"
jj new
```

---

### Task 2: Expand Breathing Geometry and Transform Fill into Contour

**Files:**

- Modify: `assets/js/hooks/session_styles_test.mjs:19-31,122-138,181-211`
- Modify: `assets/css/app.css:257-306,334-369,390-404`

**Interfaces:**

- Consumes: `--session-rest-settle-from-transform` and `is-contour-pulse` from Task 1.
- Produces: CSS animations `session-breathe`, `session-rest-settle`, and `session-countdown-contour` plus a static orange contour endpoint.
- Geometry invariant: with `bottom: -8dvh` and `height: 83dvh`, `scaleY(0.4)` exposes about 25dvh, `scaleY(1)` exposes 75dvh, and `scaleY(0.7)` settles near 50dvh.

- [ ] **Step 1: Add a media-block test helper**

Add this helper after `keyframesFor()` in `assets/js/hooks/session_styles_test.mjs`:

```javascript
function mediaFor(query) {
	const start = css.indexOf(`@media ${query}`);
	assert.notEqual(start, -1, `${query} media query should exist`);
	const open = css.indexOf("{", start);
	let depth = 0;

	for (let index = open; index < css.length; index += 1) {
		if (css[index] === "{") depth += 1;
		if (css[index] === "}") depth -= 1;
		if (depth === 0) return css.slice(open + 1, index);
	}

	assert.fail(`${query} media query should be closed`);
}
```

- [ ] **Step 2: Replace the halo and settle tests with failing contour contracts**

Replace `between-set numerals retain dark ink while a work-orange halo pulses` with:

```javascript
test("between-set numerals and the work-orange surface contour pulse together", () => {
	const count = ruleFor("#count.is-between-set-pulse")?.declarations || "";
	assert.match(count, /color:\s*var\(--session-active-ink\);/);
	assert.equal(
		ruleFor("#count.is-between-set-pulse.countdown-pop::after"),
		undefined,
	);

	const contour =
		ruleFor(
			"#session-runner-client.is-rest-countdown #session-rest-shape.is-contour-pulse",
		)?.declarations || "";
	assert.match(
		contour,
		/animation:\s*session-countdown-contour\s+0\.35s[^;]*\bboth;/,
	);

	const frames = keyframesFor("session-countdown-contour");
	assert.match(frames, /0%,\s*100%[\s\S]*transform:\s*scaleY\(0\.7\);/);
	assert.match(frames, /40%[\s\S]*transform:\s*scaleY\(0\.74\);/);
	assert.match(frames, /40%[\s\S]*border-width:\s*calc\(/);
});
```

Add this breathing-range test immediately before the settle test:

```javascript
test("rest breathing moves through the bounded 25 to 75 percent range", () => {
	const shape = ruleFor("#session-rest-shape")?.declarations || "";
	assert.match(shape, /bottom:\s*-8dvh;/);
	assert.match(shape, /height:\s*83dvh;/);
	assert.match(
		shape,
		/border:\s*var\(--session-rest-contour-width\) solid transparent;/,
	);
	assert.match(shape, /transform:\s*scaleY\(0\.4\);/);

	const frames = keyframesFor("session-breathe");
	assert.match(frames, /0%,\s*100%[\s\S]*transform:\s*scaleY\(0\.4\);/);
	assert.match(frames, /50%[\s\S]*transform:\s*scaleY\(1\);/);
});
```

Replace `rest settle is a finite pausable animation with a static countdown endpoint` with:

```javascript
test("rest settle drains into a finite pausable orange contour", () => {
	const settleFrames = keyframesFor("session-rest-settle");
	assert.match(
		settleFrames,
		/from\s*\{[\s\S]*background-color:\s*var\(--session-rest\);[\s\S]*border-color:\s*var\(--session-rest\);[\s\S]*transform:\s*var\(--session-rest-settle-from-transform, scaleY\(0\.7\)\);/,
	);
	assert.match(
		settleFrames,
		/to\s*\{[\s\S]*background-color:\s*transparent;[\s\S]*border-color:\s*var\(--session-work\);[\s\S]*transform:\s*scaleY\(0\.7\);/,
	);

	const settleSelector =
		"#session-runner-client.is-rest-settle #session-rest-shape";
	const settle = ruleFor(settleSelector)?.declarations || "";
	assert.match(settle, /animation:\s*session-rest-settle\s+2s[^;]*\bboth;/);

	const countdown =
		ruleFor("#session-runner-client.is-rest-countdown #session-rest-shape")
			?.declarations || "";
	assert.match(countdown, /background-color:\s*transparent;/);
	assert.match(countdown, /border-color:\s*var\(--session-work\);/);
	assert.match(countdown, /transform:\s*scaleY\(0\.7\);/);

	const pausedSelector = "#session-runner-client.is-paused #session-rest-shape";
	assert.match(
		ruleFor(pausedSelector)?.declarations || "",
		/animation-play-state:\s*paused;/,
	);
	assert.ok(css.lastIndexOf(pausedSelector) > css.indexOf(settleSelector));
});

test("reduced motion uses discrete rest and countdown shapes", () => {
	const reduced = mediaFor("(prefers-reduced-motion: reduce)");
	assert.match(
		reduced,
		/#session-runner-client\.is-rest-breathe #session-rest-shape\s*\{[\s\S]*transform:\s*scaleY\(0\.7\);/,
	);
	assert.match(
		reduced,
		/#session-runner-client\.is-rest-settle #session-rest-shape,[\s\S]*#session-runner-client\.is-rest-countdown #session-rest-shape\s*\{[\s\S]*background-color:\s*transparent;[\s\S]*border-color:\s*var\(--session-work\);/,
	);
	assert.doesNotMatch(reduced, /session-countdown-halo/);
});
```

- [ ] **Step 3: Run the style tests and verify RED**

Run:

```bash
cd assets && node --test js/hooks/session_styles_test.mjs
```

Expected: FAIL because the current shape uses `54dvh`, breathes `0.82→1.04`, settles in `700ms` to an orange fill, and still defines `session-countdown-halo`.

- [ ] **Step 4: Replace the rest shape, breathing, settle, and countdown CSS**

Replace the block from `#session-rest-shape` through the paused rule with:

```css
#session-rest-shape {
  --session-rest-contour-width: clamp(0.25rem, 1.2vw, 0.5rem);
  bottom: -8dvh;
  box-sizing: border-box;
  height: 83dvh;
  background-color: var(--session-rest);
  border: var(--session-rest-contour-width) solid transparent;
  border-radius: 50% 50% 0 0 / 14% 14% 0 0;
  opacity: 0;
  transform: scaleY(0.4);
  transform-origin: bottom;
  will-change: transform, background-color, border-color, border-width;
}

@keyframes session-breathe {
  0%, 100% { transform: scaleY(0.4); }
  50% { transform: scaleY(1); }
}

#session-runner-client.is-rest-breathe #session-rest-shape {
  opacity: 1;
  animation: session-breathe 8.4s cubic-bezier(0.42, 0, 0.16, 1) infinite;
}

@keyframes session-rest-settle {
  from {
    background-color: var(--session-rest);
    border-color: var(--session-rest);
    transform: var(--session-rest-settle-from-transform, scaleY(0.7));
  }

  to {
    background-color: transparent;
    border-color: var(--session-work);
    transform: scaleY(0.7);
  }
}

#session-runner-client.is-rest-settle #session-rest-shape {
  opacity: 1;
  background-color: transparent;
  border-color: var(--session-work);
  transform: scaleY(0.7);
  animation: session-rest-settle 2s cubic-bezier(0.22, 1, 0.36, 1) both;
}

#session-runner-client.is-rest-countdown #session-rest-shape {
  opacity: 1;
  background-color: transparent;
  border-color: var(--session-work);
  transform: scaleY(0.7);
  animation: none;
}

@keyframes session-countdown-contour {
  0%, 100% {
    border-width: var(--session-rest-contour-width);
    transform: scaleY(0.7);
  }

  40% {
    border-width: calc(var(--session-rest-contour-width) + 0.15rem);
    transform: scaleY(0.74);
  }
}

#session-runner-client.is-rest-countdown #session-rest-shape.is-contour-pulse {
  animation: session-countdown-contour 0.35s cubic-bezier(0.22, 1, 0.36, 1) both;
}

#session-runner-client.is-paused #session-rest-shape {
  animation-play-state: paused;
}
```

The arithmetic is intentional: `83 × 0.4 - 8 ≈ 25`, `83 × 1 - 8 = 75`, and `83 × 0.7 - 8 ≈ 50` viewport-height units.

- [ ] **Step 5: Remove the circular halo while keeping the numeral pop**

Keep `#count.is-between-set-pulse` only as the numeral color contract:

```css
#count.is-between-set-pulse {
  color: var(--session-active-ink);
}
```

Delete the entire `@keyframes session-countdown-halo` block and the entire `#count.is-between-set-pulse.countdown-pop::after` rule. Do not remove the existing global `countdown-pop` animation because it provides the approved restrained numeral scale pulse.

- [ ] **Step 6: Add discrete reduced-motion states**

Inside the existing `@media (prefers-reduced-motion: reduce)` block, delete the old `#count.is-between-set-pulse.countdown-pop::after` fallback and add:

```css
#session-runner-client.is-rest-breathe #session-rest-shape {
  transform: scaleY(0.7);
}

#session-runner-client.is-rest-settle #session-rest-shape,
#session-runner-client.is-rest-countdown #session-rest-shape {
  background-color: transparent;
  border-color: var(--session-work);
  transform: scaleY(0.7);
}

#session-runner-client.is-rest-countdown #session-rest-shape.is-contour-pulse {
  border-width: var(--session-rest-contour-width);
  transform: scaleY(0.7);
}
```

Keep the existing `animation: none !important` and `transition-duration: 1ms !important` declarations for `#session-rest-shape` and `#count` so neither contour nor numeral motion runs under reduced motion.

- [ ] **Step 7: Run style and full JavaScript tests**

Run:

```bash
cd assets && node --test js/hooks/session_styles_test.mjs
cd assets && npm test
```

Expected: both commands PASS with zero failures. The style suite proves the old circular halo is absent, the contour is orange and outline-only by `3`, and reduced motion remains distinct.

- [ ] **Step 8: Build assets and commit the visual refinement**

Run:

```bash
mix assets.build
```

Expected: exit status `0` with no Tailwind or esbuild errors.

Commit:

```bash
jj describe -m "feat(session): expand breathing rest animation"
jj new
```

---

### Task 3: Full Regression and Manual Release Verification

**Files:**

- Verify: `assets/js/hooks/session_renderer.mjs`
- Verify: `assets/css/app.css`
- Verify: `test/burpee_trainer_web/live/app_flow_test.exs`

**Interfaces:**

- Consumes: the renderer and CSS contracts from Tasks 1 and 2.
- Produces: evidence that the refinement preserves the full workout session, asset pipeline, accessibility contracts, and release checks.

- [ ] **Step 1: Run proactive diagnostics on edited source files**

Use `lsp_diagnostics` on:

```text
assets/js/hooks/session_renderer.mjs
assets/js/hooks/session_renderer_test.mjs
assets/js/hooks/session_styles_test.mjs
```

Expected: no errors. CSS has no configured language server in this project, so its structural coverage comes from `session_styles_test.mjs` and the asset build.

- [ ] **Step 2: Run focused JavaScript and LiveView regressions**

Run:

```bash
cd assets && npm test
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: both commands PASS with zero failures. The AppFlow suite confirms the session runner DOM and accessible starting state remain intact.

- [ ] **Step 3: Run the project release gate**

Run:

```bash
mix precommit
```

Expected: formatter, compiler, and complete ExUnit suite all pass with zero failures.

- [ ] **Step 4: Perform the visual and physical checks**

Run a workout containing a rest interval and verify:

1. At normal motion, the blue edge reaches approximately 25% at minimum and 75% at maximum during one complete 8.4-second cycle.
2. Enter settle once near the high point and once near the low point; neither transition snaps before moving toward the mid-screen contour.
3. During `5` and `4`, the blue fill drains while the contour changes toward orange.
4. At `3`, `2`, and `1`, only the orange contour remains; contour and numeral pulse once with exactly one beep each.
5. The old circular halo is absent.
6. Pause/resume freezes and resumes breathing, settle, and countdown states.
7. Work begins with the contour hidden and per-rep orange progress starting from zero.
8. Repeat at 320px width, a modern iPhone viewport, dark theme, and `prefers-reduced-motion: reduce`.
9. Apply the six-foot room test to the rest timer and final countdown.

If no browser or physical device is available, record these checks as the only remaining release risk instead of claiming them complete.

- [ ] **Step 5: Record the final implementation head**

Run:

```bash
jj log -r '@-' --no-graph -T 'commit_id.short() ++ " | " ++ description.first_line() ++ "\n"'
```

Expected: the output identifies the final non-empty implementation commit. Keep the working copy at a clean empty child before publishing or handing off.
