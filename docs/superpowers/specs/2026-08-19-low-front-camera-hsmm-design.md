# Low Front-Camera HSMM Counting Design

**Status:** Approved for implementation planning

**Supersedes:** the camera-placement and emission-feature portions of `2026-08-18-zero-setup-hsmm-camera-counting-design.md`. The durable lifecycle, trace-upload, explicit-correction, and general macro-cycle decisions remain unchanged.

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

### Emissions and Durations

Each usable frame gets a bounded emission score for the current macro phases. Scores are hand-authored combinations of the world-landmark features; they are not trained weights. A transition requires sufficiently strong forward evidence and may remain in its current phase while evidence is weak. Each active phase has a broad maximum duration. On expiry, the model returns to `upright` without emitting a rep.

The model retains only the current phase, phase start time, prior feature values for motion, last committed rep time, and cadence. It has no gap state. An absent frame neither resets nor advances this state. A later usable frame can continue an unambiguous partial path; otherwise duration expiry discards it without a count.

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
4. a cropped or low-confidence required landmark frame neither advances nor resets the model;
5. a squat-only motion and an interrupted floor path produce no rep;
6. an overlong partial path expires without a rep;
7. the production app bundle and deployment bundle cannot activate the browser fixture;
8. the test-only fixture bundle can drive a low-front camera session through two cycles, no warning, enabled Save, and exactly one UUID-backed report when a browser controller is available.

## Non-Goals

- No pose-world calibration, camera-extrinsic estimation, floor-plane fitting, trained model, model download, or server inference.
- No attempt to count a movement performed entirely during absent observations.
- No support claim for side, overhead, handheld, or partial-body camera placements.
