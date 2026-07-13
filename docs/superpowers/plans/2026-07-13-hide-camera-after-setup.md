# Hide Camera Preview After Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the tracked-session camera preview immediately after camera setup while the existing stream and pose tracker continue running.

**Architecture:** `SessionHook` will perform the visibility transition locally in `onCameraSetupStart()` because LiveView cannot patch classes on `#pose-tracker` while it has `phx-update="ignore"`. The hook will replace the visible-state classes with the existing hidden-state classes, then continue the current server event and flow transition unchanged.

**Tech Stack:** JavaScript ES modules, Node test runner, Phoenix LiveView/HEEx, Tailwind CSS v4, jj

## Global Constraints

- Hide the full camera preview surface immediately after the user taps **Start camera**.
- Leave the camera stream, `PoseTracker` hook, video, canvas, animation loop, and pose estimator mounted.
- Do not stop, pause, remove, or reacquire the camera stream.
- Do not change front-camera selection or minimum-zoom behavior.
- Keep `POSE_FPS = 15`.
- A missing tracker DOM node must not block the existing `camera_setup_started` event or `CAMERA_SETUP_READY` flow.
- Do not rely on LiveView patching `#pose-tracker`; it remains `phx-update="ignore"`.
- Production deployment happens only after independent task and final reviews approve the implementation.

---

### Task 1: Hide the tracked preview when camera setup completes

**Files:**

- Modify: `assets/js/hooks/session_hook.js:468-471`
- Test: `assets/js/hooks/session_hook_flow_test.mjs:8-67,198-210`

**Interfaces:**

- Consumes: `SessionHook.el.querySelector("#pose-tracker")`, the tracker element's `classList`, `pushEvent("camera_setup_started", {})`, and `dispatchFlow({type: "CAMERA_SETUP_READY"})`.
- Produces: `onCameraSetupStart()` immediately changes the existing tracker from `z-10 opacity-100` to `invisible -z-10 opacity-0` without removing it, and always continues the current event/flow behavior.

- [ ] **Step 1: Add DOMTokenList behavior to the test element and write failing visibility tests**

Add this getter to `FakeElement` in `assets/js/hooks/session_hook_flow_test.mjs`:

```javascript
	get classList() {
		const element = this;
		const tokens = () => element.className.split(/\s+/).filter(Boolean);

		return {
			add(...names) {
				element.className = [...new Set([...tokens(), ...names])].join(" ");
			},
			remove(...names) {
				const removed = new Set(names);
				element.className = tokens()
					.filter((name) => !removed.has(name))
					.join(" ");
			},
		};
	}
```

Add these tests after `tracked camera prompt leaves preview rendering to PoseTracker`:

```javascript
test("starting a tracked session hides the preview without removing the tracker", () => {
	const ctx = buildHarness({ poseTrackerReady: true });
	const tracker = ctx.el.querySelector("#pose-tracker");
	tracker.className = "pointer-events-none z-10 opacity-100";

	ctx.onCameraSetupStart();

	assert.equal(ctx.el.querySelector("#pose-tracker"), tracker);
	assert.equal(tracker.removed, undefined);
	assert.doesNotMatch(tracker.className, /(?:^|\s)z-10(?:\s|$)/);
	assert.doesNotMatch(tracker.className, /(?:^|\s)opacity-100(?:\s|$)/);
	assert.match(tracker.className, /(?:^|\s)invisible(?:\s|$)/);
	assert.match(tracker.className, /(?:^|\s)-z-10(?:\s|$)/);
	assert.match(tracker.className, /(?:^|\s)opacity-0(?:\s|$)/);
	assert.deepEqual(ctx.events, [
		{ name: "camera_setup_started", payload: {} },
	]);
	assert.equal(ctx.flow.mode, "warmup_prompt");
});

test("camera setup continues when the tracker DOM is absent", () => {
	const ctx = buildHarness({ poseTrackerReady: null });

	assert.doesNotThrow(() => ctx.onCameraSetupStart());
	assert.deepEqual(ctx.events, [
		{ name: "camera_setup_started", payload: {} },
	]);
	assert.equal(ctx.flow.mode, "warmup_prompt");
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
cd assets && node --test js/hooks/session_hook_flow_test.mjs
```

Expected: FAIL in `starting a tracked session hides the preview without removing the tracker` because `z-10 opacity-100` remain and `invisible -z-10 opacity-0` are absent. The missing-tracker test should already pass.

- [ ] **Step 3: Implement the immediate client-side visibility transition**

Replace `onCameraSetupStart()` in `assets/js/hooks/session_hook.js` with:

```javascript
	onCameraSetupStart() {
		const tracker = this.el.querySelector("#pose-tracker");
		if (tracker) {
			tracker.classList.remove("z-10", "opacity-100");
			tracker.classList.add("invisible", "-z-10", "opacity-0");
		}

		this.pushEvent("camera_setup_started", {});
		this.dispatchFlow({ type: "CAMERA_SETUP_READY" });
	},
```

Do not alter the server-rendered `#pose-tracker`, `phx-update="ignore"`, pose-tracker lifecycle, media stream, camera constraints, or sampler.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
cd assets && node --test js/hooks/session_hook_flow_test.mjs
```

Expected: PASS with 18 tests, 0 failures.

- [ ] **Step 5: Run the complete JavaScript suite**

Run:

```bash
cd assets && npm test
```

Expected: PASS with 19 tests, 0 failures, including the existing single-stream zoom fallbacks and `POSE_FPS === 15` assertion.

- [ ] **Step 6: Run Phoenix project verification**

Run:

```bash
mix precommit
```

Expected: exit 0 with 190 tests passing.

- [ ] **Step 7: Inspect the scoped diff**

Run:

```bash
jj diff --git
jj status
```

Expected: only `assets/js/hooks/session_hook.js` and `assets/js/hooks/session_hook_flow_test.mjs` contain implementation changes; the already-written plan artifact may also be present in its own documentation change.

- [ ] **Step 8: Describe the implementation change**

Run:

```bash
jj describe -m "fix(tracking): hide camera preview after setup"
jj new
```

Expected: the completed implementation is recorded as a described jj change and a new empty working-copy change is created above it.

## Controller-owned post-review deployment

After independent task review and final review approve the implementation:

1. Point or publish the chosen jj bookmark at the reviewed implementation change.
2. Deploy from the reviewed workspace using the NUC `nuc/apps/burpee/deploy` flow with `REPO_PATH` set to that workspace.
3. Verify `https://burpee.gustafrydholm.xyz/` returns successfully.
4. Confirm the active digested JavaScript bundle contains the `classList.remove("z-10", "opacity-100")` and `classList.add("invisible", "-z-10", "opacity-0")` behavior.
5. Confirm `burpee_trainer` is running in the `burpee` jail and the deployed source still exports `POSE_FPS = 15`.
