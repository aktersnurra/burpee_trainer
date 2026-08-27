# Pushup Occlusion-Tolerant HSMM Implementation Plan

> **For implementation:** Follow this plan in order. Keep changes limited to the HSMM, its derived-feature tests, and design evidence.

**Goal:** Count a completed burpee after temporary camera loss during pushups, without relaxing ordered transitions outside that phase.

**Architecture:** Rename the internal HSMM state vocabulary from upright/floor-oriented terms to `standing`, `lowering`, `pushup`, and `rising`. On an unusable frame, preserve state only in `pushup`; every other incomplete phase resets to `standing`. Keep the existing emissions, 0.72 forward threshold, 1.1 span guard, and refractory logic. Make only the final `rising → standing` threshold 0.47.

**Tech stack:** Browser ES modules, Node built-in test runner, derived pose-feature fixtures, Phoenix verification.

---

## 1. Make derived-feature regressions fail

**Files:**
- Modify: `assets/js/hooks/pose_burpee_hsmm_test.mjs`

1. Rename synthetic phase labels to `standing`, `lowering`, `pushup`, `pushup_press`, and `rising` so the test language matches the state vocabulary.
2. Replace the current “any unusable frame abandons a partial path” assertion with a sequence that enters pushup, includes one or more unusable frames, then supplies fresh rising and standing frames. Expect exactly one rep.
3. Add a contrasting unusable frame during lowering and assert it resets the path.
4. Add an out-of-order standing observation after a preserved pushup gap and assert it resets.
5. Add boundary tests showing the final score at 0.47 counts and one below it does not.
6. Run `npm test -- pose_burpee_hsmm_test.mjs`; confirm the new cases fail before implementation.

## 2. Implement the minimal HSMM change

**Files:**
- Modify: `assets/js/hooks/pose_burpee_hsmm.mjs`

1. Rename `PHASES`, `NEXT`, emission keys, and state comparisons to `standing`, `lowering`, `pushup`, and `rising`.
2. Rename the public internal constant to match its behavior and change only its value from 0.48 to 0.47.
3. On `!usable(frame)`, preserve state only when `state.phase === "pushup"`; otherwise use `resetCandidate/1`.
4. Keep cadence and `lastRepAtMs` untouched when preserving or resetting candidates.
5. Retain all existing score functions, the 0.72 forward threshold, strong out-of-order logic, span guard, and refractory logic.
6. Run the focused test again; expect it to pass.

## 3. Verify handoff and retained fixtures

**Files:**
- Verify: `assets/js/hooks/pose_burpee_hsmm_fixture_test.mjs`
- Verify: `assets/js/hooks/pose_tracker_impl_test.mjs`

1. Run the HSMM fixture test to confirm the derived user-labeled two-rep trace stays at two.
2. Run tracker/session tests to confirm actual counted reps still hand off to completion.
3. Run the full asset suite: `cd assets && npm test`.
4. Run `mix precommit` at the workspace root.
5. Check edited-file diagnostics before reporting success.

## 4. Review and publish evidence

1. Inspect the final diff for scope and phase-name consistency.
2. Request an independent code review focused on false-positive risk after camera loss and threshold-boundary coverage.
3. Fix any confirmed findings and rerun the affected commands.
4. Update the real-camera evidence report with the aggregate three-rep simulation result; do not add raw landmarks.
5. Create a signed Jujutsu commit only after verification passes.