# Zero-Setup HSMM Camera Counting Design

**Status:** Approved for planning

**Supersedes:** `2026-08-06-calibrated-camera-counting-design.md` for camera-counting behavior. Deferred pose-trace upload boundaries remain unchanged.

## Goal

Count visible burpee repetitions reliably in the browser with a small pose-feature hidden semi-Markov model (HSMM). Starting a workout requires no reference repetitions. Briefly leaving the camera view, low-quality landmarks, or putting down the device must not interrupt the workout, demand manual reporting, or become product data.

## Product Contract

- The client owns camera sampling, temporal inference, count display, and timer.
- The counter starts immediately after the user enables the camera. There is no calibration flow.
- A completed, observed burpee cycle increments the camera count exactly once.
- Missing or unusable pose samples are absent observations. They do not create a tracking state, warning, provenance reason, database field, trace annotation, or report requirement.
- The model never invents a rep performed entirely while no usable pose was observed.
- The timer continues independently of camera observations.
- The completion form pre-fills the camera count. An explicit user edit is a user correction; ordinary missing samples are not a correction or degradation.

## Non-Goals

- No trained TCN, model download, labelled-trace collection, or training pipeline.
- No server-side pose inference.
- No user-visible “tracking degraded”, “out of frame”, or camera-health workflow.
- No attempt to reconstruct an entirely unobserved repetition.
- No changes to durable workout lifecycle, report idempotency, or bounded deferred trace upload behavior.

## Runtime Architecture

### Inputs

The browser reuses the existing sampled pose landmarks and timestamps. Each usable sample becomes a compact body-relative feature vector, such as normalized torso height, shoulder-to-ankle distance, elbow bend, hip bend, and vertical velocity. Normalization is per sample against stable body proportions, so it requires no personal reference motion.

Samples without the required visible landmarks or minimum confidence are omitted from the observation stream. The runtime retains no user-facing or persisted record that an omission occurred.

### HSMM

The counter runs a bounded rolling Viterbi-style HSMM over one general burpee macro-cycle:

`upright → lowering_to_floor → floor_work → returning_from_floor → upright`.

This graph counts the outer movement, not a named style. `lowering_to_floor` requires evidence that the hands and torso move toward the ground. `floor_work` requires supported ground work—plank, pushups, or another continuous floor movement—and can contain any number of internal pushup motions without creating another burpee. `returning_from_floor` covers the feet returning under the body and the squat-like rise before upright posture.

Each state has broad, tested duration bounds and an emission score derived from normalized pose features. The emissions distinguish hand/torso lowering, supported floor geometry, return-to-squat motion, and upright posture. A candidate repetition is committed only when the best path completes the full observed macro-cycle, including floor work, and passes a refractory interval. The plan's burpee type remains a workout-program label; it does not change the counting graph.

The rolling window is bounded by time and sample count. It retains only the model state needed for the next decision, not a full workout history.

### Missing Observations

The HSMM receives no emission for unusable samples. Its duration constraints keep a stale partial path from surviving indefinitely. After a short ordinary break between repetitions, subsequent usable samples continue from the most likely path. If an absence makes a partial repetition ambiguous, the model returns to a non-counted stable path and waits for a fresh observed cycle.

This is intentionally internal inference behavior. It must not produce a gap state or product-facing tracking classification.

## Completion and Persistence

A camera session saves the detected count and cadence for completed observed repetitions as camera-counted provenance. If the user edits the count, the session saves as user-corrected while retaining the original detected count for analysis. No absent-observation condition can force a blank count, disable Save, or select a timer-derived count as the actual result.

Existing lifecycle states (`running`, `report_pending`, `reported`, `aborted`) and UUID idempotency are unchanged. Existing trace chunks remain optional bounded diagnostics; their retry and digest rules are unchanged.

## Migration From the Current Counter

Remove the two-reference-repetition calibration UI, calibration recorder/template matcher dependency, calibrated trust/degraded transitions, and degradation-specific completion validation. Replace the current threshold phase machine with the HSMM counter behind the existing pose tracker interface so the session flow keeps a simple `camera count` result.

Retain explicit user correction handling. Do not retain automatic camera degradation as a report mode.

## Verification

Unit tests must deterministically prove:

- a complete body-to-floor-to-standing cycle produces one rep;
- a floor-work phase with one pushup produces one rep;
- a floor-work phase with three pushups still produces one rep;
- two complete macro-cycles produce two reps without double counts;
- a water-break-like missing interval between cycles does not change the count and the next valid cycle counts;
- missing samples during a partial cycle do not create a phantom rep;
- low-quality samples do not create a rep;
- short and long timing variations within broad bounds remain countable;
- a squat-only or incomplete floor sequence never produces a rep;
- repeated pushups inside one continuous floor-work phase never produce extra burpees;
- an explicit user correction changes only correction provenance;
- absence never blanks the completion count, disables Save, or creates a degradation field.

Browser verification must prove a camera workout can continue through a normal temporary absence without pausing, warning, restarting, or changing report requirements. A controlled pose fixture is required for this scenario; a real camera alone is insufficiently repeatable.

## Risks and Boundaries

The HSMM improves temporal robustness but cannot observe hidden motion. It must prefer no count over a fabricated count when a rep is wholly unobserved. Broad priors must be validated against representative burpee tempo tests before release. If measured errors later justify a learned model, a TCN may be introduced only with a labelled corpus, accuracy target, model versioning, and an explicit replacement design.
