# Low Front-Camera HSMM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current image-plane burpee phase gates with a no-calibration, low front-camera world-landmark model for full-body workout framing.

**Architecture:** `featureFrameFromPose/4` will derive body-scale-normalized relative BlazePose-world signals while retaining existing image-plane/debug fields. `pose_burpee_hsmm.mjs` will consume only those world signals for bounded macro-phase emissions. Tracker, reporting, and absence behavior remain unchanged: incomplete, cropped, or low-confidence observations are silent no-ops.

**Tech Stack:** Vanilla ES modules, MediaPipe BlazePose world landmarks, Node test runner, Phoenix LiveView, existing test-only fixture asset entrypoint.

## Global Constraints

- Support only a fixed phone on or near the floor, facing the athlete, with full-body framing.
- Do not add calibration, ground-plane fitting, camera-extrinsic estimation, trained models, model downloads, or server inference.
- Use world-landmark *differences* normalized by same-frame body scale; never use absolute camera coordinates, person height, or camera distance.
- Image landmarks may gate visibility and confidence only; they must not be phase evidence.
- An absent/cropped/low-confidence frame is a silent no-op: no reset, warning, trace annotation, fallback, provenance field, or invented rep.
- Preserve the general macro-cycle `upright → lowering_to_floor → floor_work → returning_from_floor → upright`; internal pushups do not add reps.
- Preserve lifecycle UUID authority, explicit-only correction provenance, bounded trace uploads, and production-bundle exclusion of the browser fixture.
- Use `jj --config signing.behavior=drop` for every Jujutsu mutation.

---

### Task 1: Derive normalized low-front world-landmark features

**Files:**
- Modify: `assets/js/hooks/pose_features.mjs`
- Modify: `assets/js/hooks/pose_features_test.mjs`

**Interfaces:**
- Consumes: BlazePose keypoints whose required macro landmarks include `point.world.{x,y,z}`.
- Produces in `featureFrameFromPose/4`: `worldBodyVerticalSpan`, `worldHipVerticalSpan`, `worldWristVerticalSpan`, `worldTorsoElevation`, `worldBodyScale`, `dWorldBodyVerticalSpan`, and `dWorldWristVerticalSpan`.
- A feature is `null` when its source world landmarks are missing or non-finite.

- [ ] **Step 1: Write failing low-front feature tests**

```js
test('derives body-scale-normalized world geometry without camera coordinates', () => {
  const previous = featureFrameFromPose(lowFrontPose('upright'), 0, video);
  const frame = featureFrameFromPose(lowFrontPose('lowering'), 100, video, previous);

  assert.equal(frame.worldBodyVerticalSpan, 3);
  assert.equal(frame.worldHipVerticalSpan, 2);
  assert.equal(frame.worldWristVerticalSpan, 1.25);
  assert.equal(frame.worldTorsoElevation, 1);
  assert.equal(frame.dWorldBodyVerticalSpan, -5);
});

test('omits world macro features when a required landmark has no world point', () => {
  const frame = featureFrameFromPose(lowFrontPose('floor', ['left_wrist']), 0, video);
  assert.equal(frame.worldWristVerticalSpan, null);
  assert.equal(frame.worldBodyVerticalSpan, 0.25);
});
```

Make `lowFrontPose/2` use realistic full-body image keypoints plus `world` coordinates. It must model standing as a tall world-space vertical body and floor work as a low vertical span even when image-plane geometry is foreshortened.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd assets && node --test js/hooks/pose_features_test.mjs`

Expected: FAIL because the world geometry fields do not yet exist.

- [ ] **Step 3: Add pure world-geometry helpers and feature fields**

Keep current 2-D fields for diagnostics. Add world-space helpers that never fall back to pixel coordinates:

```js
const worldShoulderMid = worldMidpoint(points.get('left_shoulder'), points.get('right_shoulder'));
const worldHipMid = worldMidpoint(points.get('left_hip'), points.get('right_hip'));
const worldAnkleMid = worldMidpoint(points.get('left_ankle'), points.get('right_ankle'));
const worldWristMid = worldMidpoint(points.get('left_wrist'), points.get('right_wrist'));
const worldTorsoLength = worldDistance(worldShoulderMid, worldHipMid);
const worldShoulderWidth = worldDistance(points.get('left_shoulder')?.world, points.get('right_shoulder')?.world);
const worldHipWidth = worldDistance(points.get('left_hip')?.world, points.get('right_hip')?.world);
const worldBodyScale = finiteMaximum(worldTorsoLength, worldShoulderWidth, worldHipWidth, 0.01);

worldBodyVerticalSpan: worldVerticalDistance(worldShoulderMid, worldAnkleMid, worldBodyScale),
worldHipVerticalSpan: worldVerticalDistance(worldHipMid, worldAnkleMid, worldBodyScale),
worldWristVerticalSpan: worldVerticalDistance(worldWristMid, worldAnkleMid, worldBodyScale),
worldTorsoElevation: worldVerticalDistance(worldShoulderMid, worldHipMid, worldTorsoLength),
worldBodyScale: round4(worldBodyScale),
```

`worldMidpoint/2` returns `null` unless both world points have finite `x`, `y`, and `z`; `worldVerticalDistance/3` returns `null` for a missing point or non-positive scale. Extend `addVelocities/2` with only `dWorldBodyVerticalSpan` and `dWorldWristVerticalSpan`.

- [ ] **Step 4: Run the focused feature test**

Run: `cd assets && node --test js/hooks/pose_features_test.mjs`

Expected: PASS. Task 2 owns migration of the old 2-D macro fixtures and scorer.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'feat(tracking): derive low-front world pose features'
jj --config signing.behavior=drop new
```

### Task 2: Score the macro-cycle from world geometry

**Files:**
- Modify: `assets/js/hooks/pose_burpee_hsmm.mjs`
- Modify: `assets/js/hooks/pose_burpee_hsmm_test.mjs`

**Interfaces:**
- Consumes: Task 1's `world*` fields and their two velocity fields.
- Produces unchanged `initialBurpeeHsmmState/0` and `stepBurpeeHsmm(state, frame) -> {state, rep, repAtMs}`.
- `usable/1` requires all Task 1 world signals and retains existing confidence/visible-fraction gates.

- [ ] **Step 1: Replace 2-D fixture maps with failing raw low-front poses**

```js
test('counts one low-front observed cycle with one or three floor pushups', () => {
  const frames = lowFrontFeatureFrames([
    ['upright', 0], ['lowering', 150], ['floor', 300], ['floor_pushup', 450],
    ['returning', 750], ['upright', 900],
    ['upright', 2500], ['lowering', 2650], ['floor', 2800], ['floor_pushup', 2950],
    ['floor', 3100], ['floor_pushup', 3250], ['floor', 3400], ['returning', 3550], ['upright', 3700],
  ]);
  assert.deepEqual(run(frames).reps, [900, 3700]);
});

test('foreshortened image coordinates do not change world-based phase results', () => {
  assert.deepEqual(run(lowFrontFeatureFrames(lowFrontCycle(), {foreshortenImage: true})).reps, [900]);
});

test('advances only when weighted low-front evidence clears the forward threshold', () => {
  const result = stepBurpeeHsmm(
    { ...initialBurpeeHsmmState(), phase: 'upright', phaseStartedAtMs: 0 },
    lowFrontFrame('lowering', 150, { worldWristVerticalSpan: 1.8 }),
  );
  assert.equal(result.state.phase, 'lowering_to_floor');
});
```

Keep regressions for squat-only motion, interrupted floor paths, absent frames, required-landmark confidence, and duration expiry. Their frames must now carry valid Task 1 world features instead of `wristToAnkle` or `shoulderToAnkle` phase values.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_test.mjs`

Expected: FAIL because `usable/1` and `scoreMacroEmissions/1` still use image-plane fields.

- [ ] **Step 3: Replace phase scoring with bounded weighted world emissions**

Delete the old `wristToAnkle`, `shoulderToAnkle`, `torsoUprightness`, `hipToKnee`, and related velocity checks from `usable/1` and `scoreMacroEmissions/1`. Set `FORWARD_EMISSION` to `0.72`. Use only world geometry and return each phase's weighted score in `[0, 1]`:

```js
function scoreMacroEmissions(frame) {
  return {
    upright: weightedScore([
      [rises(frame.worldBodyVerticalSpan, 2.8, 3.2), 0.35],
      [rises(frame.worldHipVerticalSpan, 1.6, 2.0), 0.2],
      [rises(frame.worldTorsoElevation, 0.75, 0.85), 0.25],
      [rises(frame.worldWristVerticalSpan, 1.2, 1.5), 0.2],
    ]),
    lowering_to_floor: weightedScore([
      [band(frame.worldBodyVerticalSpan, 1.1, 2.1, 3.2), 0.35],
      [falls(frame.worldTorsoElevation, 0.8, 0.45), 0.2],
      [falls(frame.worldWristVerticalSpan, 1.6, 0.7), 0.15],
      [falls(frame.dWorldBodyVerticalSpan, -0.25, -0.8), 0.3],
    ]),
    floor_work: weightedScore([
      [falls(frame.worldBodyVerticalSpan, 1.5, 1.1), 0.3],
      [falls(frame.worldHipVerticalSpan, 1.0, 0.7), 0.2],
      [falls(frame.worldTorsoElevation, 0.5, 0.35), 0.3],
      [falls(frame.worldWristVerticalSpan, 0.8, 0.45), 0.2],
    ]),
    returning_from_floor: weightedScore([
      [band(frame.worldBodyVerticalSpan, 1.1, 2.1, 3.2), 0.25],
      [band(frame.worldTorsoElevation, 0.3, 0.55, 0.85), 0.2],
      [rises(frame.worldHipVerticalSpan, 0.7, 1.1), 0.15],
      [rises(frame.dWorldBodyVerticalSpan, 0.25, 0.8), 0.4],
    ]),
  };
}
```

Define clamped pure helpers beside `scoreMacroEmissions/1`:

```js
function rises(value, zeroAt, fullAt) {
  return clamp01((value - zeroAt) / (fullAt - zeroAt));
}

function falls(value, zeroAt, fullAt) {
  return clamp01((zeroAt - value) / (zeroAt - fullAt));
}

function band(value, low, center, high) {
  return value <= center
    ? rises(value, low, center)
    : falls(value, high, center);
}

function weightedScore(entries) {
  return entries.reduce((total, [score, weight]) => total + score * weight, 0);
}
```

The Step 1 weak-wrist regression proves a single weak feature can still permit a forward phase only when the remaining weighted evidence reaches `0.72`. Retain `NEXT`, duration expiry, and refractory behavior. Do not add a view-mode selector or a 2-D fallback.

- [ ] **Step 4: Run focused HSMM tests**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_test.mjs js/hooks/pose_features_test.mjs`

Expected: PASS; one and three pushups count once each, image foreshortening cannot alter the result, and unseen/cropped/incomplete paths count zero.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'feat(tracking): score burpees from world landmarks'
jj --config signing.behavior=drop new
```

### Task 3: Admit and record only usable low-front world frames

**Files:**
- Modify: `assets/js/hooks/pose_tracker_impl.mjs`
- Modify: `assets/js/hooks/pose_tracker_impl_test.mjs`
- Modify: `assets/js/hooks/pose_burpee_hsmm_fixture_test.mjs`

**Interfaces:**
- Consumes: the unchanged `stepBurpeeHsmm/2` result plus Task 1 world fields.
- Produces: existing local `pose-tracker:rep` events and pose-capture records only for a usable world frame.

- [ ] **Step 1: Write failing tracker admission tests**

```js
test('does not emit a candidate or persist an isolated frame without required world landmarks', async () => {
  const tracker = mountedTrackerWithLowFrontFrames([
    lowFrontFrame('lowering', 150, {missingWorld: ['left_wrist']}),
  ]);
  await tracker.run();
  assert.deepEqual(tracker.repIndexes(), []);
  assert.equal(tracker.traceChunkCount(), 0);
  assert.equal(tracker.statusEvents().includes('lost'), false);
});

test('persists only usable world frames from a mixed low-front sequence', async () => {
  const tracker = mountedTrackerWithLowFrontFrames([
    lowFrontFrame('upright', 0),
    lowFrontFrame('lowering', 150, {missingWorld: ['left_wrist']}),
    lowFrontFrame('floor', 300),
  ]);
  await tracker.run();
  assert.deepEqual(tracker.traceTimestamps(), [0, 300]);
});

test('keeps counting after absent low-front frames without image-plane fallback', async () => {
  const tracker = mountedTrackerWithLowFrontFrames([
    ...lowFrontCycle(0), ...absentFrames(1000, 2000), ...lowFrontCycle(3500),
  ]);
  await tracker.run();
  assert.deepEqual(tracker.repIndexes(), [1, 2]);
});
```

- [ ] **Step 2: Run the tests to verify failure**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs`

Expected: FAIL because `usableBurpeeHsmmFrame/1` currently admits the old image-plane feature set.

- [ ] **Step 3: Make tracker admission match HSMM usability**

Update `usableBurpeeHsmmFrame/1` to require finite Task 1 world fields and the existing confidence, macro-landmark-confidence, and visible-fraction gates. The function must not accept an image-plane substitute:

```js
const worldFeatures = [
  frame.worldBodyVerticalSpan,
  frame.worldHipVerticalSpan,
  frame.worldWristVerticalSpan,
  frame.worldTorsoElevation,
  frame.dWorldBodyVerticalSpan,
  frame.dWorldWristVerticalSpan,
];
return worldFeatures.every(Number.isFinite) && confidenceAndVisibilityAreUsable(frame);
```

Keep missing frames silent: no `lost` event, no capture write, no reset, and no server event.

- [ ] **Step 4: Run focused tracker tests**

Run: `cd assets && node --test js/hooks/pose_tracker_impl_test.mjs js/hooks/pose_burpee_hsmm_fixture_test.mjs js/hooks/pose_burpee_hsmm_test.mjs`

Expected: PASS; capture recording and phase inference agree on which low-front frames are usable.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'fix(tracking): gate low-front world observations'
jj --config signing.behavior=drop new
```

### Task 4: Update the controlled fixture and browser runbook for low-front capture

**Files:**
- Modify: `assets/js/hooks/pose_burpee_hsmm_fixture_test.mjs`
- Modify: `docs/testing/workout-session-e2e.md`
- Modify: `docs/superpowers/specs/2026-08-19-low-front-camera-hsmm-design.md`

**Interfaces:**
- Consumes: `lowFrontFrame/2` feature maps from Tasks 1–3 and the existing test-only `app_fixture.js` entrypoint.
- Produces: an integration fixture that exercises real `SessionHook`/`SessionRenderer` state with low-front world features; the runbook states the exact supported placement and fixture injection process.

- [ ] **Step 1: Write the failing session-rendered fixture assertion**

```js
test('low-front fixture counts across an absence without warning or disabled Save', async () => {
  const page = await runControlledSessionFixture([
    ...lowFrontCycle(0), ...absentFrames(1200, 2000), ...lowFrontCycle(3500),
  ]);

  assert.equal(page.text('#session-actual-reps'), '2');
  assert.doesNotMatch(page.text('#session-live-status'), /tracking degraded|out of frame/i);
  assert.equal(page.hasAttribute('#session-save-btn', 'disabled'), false);
});
```

- [ ] **Step 2: Run the test to verify failure**

Run: `cd assets && node --test js/hooks/pose_burpee_hsmm_fixture_test.mjs`

Expected: FAIL until all controlled frames use Task 1 world features and Task 3 admission accepts them.

- [ ] **Step 3: Migrate controlled frames and runbook**

Replace every controlled phase frame that supplies the old 2-D macro fields with a complete low-front world feature map. Keep the fixture’s real `SessionHook`/`SessionRenderer` DOM assertions and the test-only asset interception path. In the runbook, state:

```markdown
Place the fixed phone on or near the floor, facing the athlete, far enough away to keep the head, wrists, hips, knees, ankles, and feet in frame while standing and on the floor. The controlled fixture must carry BlazePose-shaped world landmarks. A cropped or low-confidence frame is an absent observation; it must not generate a warning or a report fallback.
```

Do not change normal/deploy asset aliases. The production bundle must remain free of `__burpeePoseFixture`, `pose_tracker_fixture`, and `app_fixture` markers.

- [ ] **Step 4: Run fixture, bundle, and focused LiveView checks**

Run:

```bash
cd assets && node --test js/hooks/pose_burpee_hsmm_fixture_test.mjs js/hooks/pose_tracker_impl_test.mjs
cd .. && mix assets.fixture && mix assets.build
mix test test/burpee_trainer_web/live/app_flow_test.exs
```

Expected: PASS. Verify the normal built `priv/static/assets/js/app.js` contains none of the three fixture markers.

- [ ] **Step 5: Commit**

```bash
jj --config signing.behavior=drop describe -m 'test(tracking): cover low-front camera counting'
jj --config signing.behavior=drop new
```

### Task 5: Run full regression verification and record browser-E2E status

**Files:**
- No source files; record redacted browser evidence under `.e2e-artifacts/reports/` only when the controller scenario runs.

**Interfaces:**
- Consumes: the production build plus test-only fixture asset from Task 4.
- Produces: current-run browser evidence or an explicit blocked verdict; no source change is permitted during the browser scenario.

- [ ] **Step 1: Run full automated verification**

```bash
cd assets && npm test
cd .. && mix precommit
mix assets.deploy
```

Expected: all Node tests and `mix precommit` pass; deploy bundle contains no fixture markers.

- [ ] **Step 2: Execute the conditional low-front browser scenario when controller capability exists**

Read `.agents/skills/workout-session-e2e/SKILL.md` and `docs/testing/workout-session-e2e.md` completely. Build `mix assets.fixture`, intercept the normal development `app.js` with the local fixture bundle, then inject the low-front full-body world-landmark fixture before page load. Use `scripts/e2e/setup.exs`, Save the camera session, verify `count: 1` with `scripts/e2e/verify.exs`, redact evidence, and clean with `scripts/e2e/cleanup.exs`.

If no browser controller can inject and intercept the fixture asset, record `blocked` with the exact unavailable capability. Do not call automated fixture tests browser evidence.

- [ ] **Step 3: Check diagnostics and preserve evidence**

Run: `lsp_diagnostics` on every changed source file, then `lens_diagnostics(mode: 'all')`.

Expected: no blocking diagnostics. Preserve any redacted browser evidence under `.e2e-artifacts/reports/`; it remains outside the implementation change unless explicitly requested for version control.

## Plan Self-Review

- **Spec coverage:** Tasks 1–2 replace image-plane phase evidence with normalized world landmark geometry and retain the required macro-cycle. Task 3 preserves silent absence behavior at tracker/trace boundaries. Task 4 updates the real rendered fixture and E2E placement contract while retaining production fixture isolation. Task 5 requires full regression, deployment-bundle, and browser-evidence checks.
- **Completeness scan:** Every implementation task has concrete interfaces, test cases, commands, and validation; none defers behavior or leaves an interface unassigned.
- **Type consistency:** Task 1 defines each `world*` feature and velocity that Task 2 and Task 3 consume. `stepBurpeeHsmm/2` and the existing tracker/session event contracts do not change.
