# Low Front-Camera HSMM Counting Design

**Status:** Historical design with the authoritative phase-count correction below.

**Supersedes:** the camera-placement and emission-feature portions of `2026-08-18-zero-setup-hsmm-camera-counting-design.md`. The durable lifecycle, trace-upload, explicit-correction, and general macro-cycle decisions remain unchanged.

> **Authoritative correction:** This document's former expiry and no-reset details are historical. The phase-count contract below supersedes them.

## Goal

Count observed burpee macro-cycles from a fixed, low phone positioned in front of the athlete. The model must remain client-only, require no reference repetition or camera calibration, and prefer an omitted rep over a fabricated rep.

## Supported Placement Contract

- The phone is fixed on or near the floor, facing the athlete.
- The full body is visible in both standing and floor phases: head, shoulders, wrists, hips, knees, ankles, and feet.
- The athlete stays within the frame. A cropped, occluded, or low-confidence frame is an absent observation, not an error or product state.
- The runtime does not infer camera height, a ground plane, or a person-specific baseline. It does not ask the athlete to reposition, calibrate, or confirm recovery from a gap.

This is the only supported camera placement for automatic counting. Other placements are not silently reinterpreted as this contract.

## Inference Model

The model preserves one general temporal grammar:

`upright → lowering_to_floor → floor_work → returning_from_floor → upright`

A repetition commits only on an observed `returning_from_floor → upright` transition after all preceding phases have been observed and the refractory interval has elapsed. Pushups within `floor_work` do not create additional cycles.

### World-Landmark Feature Vector

BlazePose world landmarks are the primary phase signal. Every scalar is calculated from differences between body landmarks, then normalized by a body-scale measure derived from the same frame. The model must not use absolute camera coordinates, person height, or distance to camera.

The feature vector contains:

- **body vertical span:** shoulder-to-ankle and hip-to-ankle world-space vertical separation;
- **torso elevation:** vertical component of the shoulder-to-hip vector divided by torso length;
- **support geometry:** world-space relationships among wrists, shoulders, hips, and ankles that distinguish standing, descent, supported floor work, and return;
- **motion direction:** finite differences of normalized vertical span and support geometry;
- **visibility gate:** image-landmark confidence and complete required-landmark coverage.

Image-plane landmarks are used only for the visibility gate. They must not be phase evidence: low floor placement makes 2-D apparent size, foreshortening, and pixel distances unreliable.

### Emissions and State Reset Contract

Each usable frame gets a bounded, hand-authored emission score for the macro phases; scores are not trained weights. There are **no phase-duration or repetition-duration caps**. A transition ordinarily requires sufficiently strong forward evidence and may remain in its current phase while evidence is weak.

An unusable camera frame (including cropped, occluded, or low-confidence observations) resets an **incomplete candidate only** to `upright` and emits no rep. A strong out-of-order emission—score `>= 0.72` for neither the current phase nor its direct next phase—also resets to `upright` and emits no rep. The only completion transition is `returning_from_floor → upright`, which requires score `>= 0.48` after the strict preceding path `upright → lowering_to_floor → floor_work → returning_from_floor` has been observed. No other transition emits a rep.

The model retains the current phase, prior feature values for motion, last committed rep time, and cadence. It has no gap state or duration-expiry recovery behavior.

## Product and Reporting Contract

- The timer remains independent of camera observations.
- Ordinary absent observations produce no warning, degradation status, provenance reason, trace annotation, database field, report requirement, or manual fallback.
- A valid active camera runtime can finish with zero observed reps; zero is a camera result, not a timer fallback.
- A stopped or unavailable tracker cannot manufacture a camera completion or substitute timer values.
- The completion form uses the detected camera count. Only a user edit selects user-corrected provenance.
- The server-minted lifecycle UUID remains authoritative; IndexedDB may restore retry state only for that exact UUID.

## Verification

Tests must use raw BlazePose-shaped low-front fixtures, not only precomputed feature maps. They must prove:

1. a low-front full-body one-pushup macro-cycle produces one rep;
2. a three-pushup floor-work phase still produces one rep;
3. two cycles separated by absent/cropped frames produce exactly two reps;
4. a cropped or low-confidence required landmark frame resets an incomplete candidate to upright and produces no rep;
5. a strong out-of-order emission (score `>= 0.72` for neither current nor direct-next phase) resets and produces no rep;
6. only `returning_from_floor → upright` at score `>= 0.48`, after the strict prior phases, emits a rep;
7. no phase or repetition duration cap expires an incomplete path;
8. a squat-only motion and an interrupted floor path produce no rep;
9. the production app bundle and deployment bundle cannot activate the browser fixture;
10. the test-only fixture bundle can drive a low-front camera session through two cycles, no warning, enabled Save, and exactly one UUID-backed report when a browser controller is available.

## Non-Goals

- No pose-world calibration, camera-extrinsic estimation, floor-plane fitting, trained model, model download, or server inference.
- No attempt to count a movement performed entirely during absent observations.
- No support claim for side, overhead, handheld, or partial-body camera placements.
