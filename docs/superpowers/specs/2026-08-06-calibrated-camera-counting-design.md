# Calibrated Camera Counting and Reliable Trace Uploads

## Summary

Make the workout camera path trustworthy without a trained model. A user performs two slow reference burpees during setup. The client then uses calibrated temporal and pose-template checks to count only high-quality reps, records what happened at save time, and requires a user-entered count whenever camera tracking degrades. Deferred pose traces remain optional, retryable, and bounded below HTTP request limits.

## Evidence and Problem Statement

A camera-selected session was persisted as `timed` with the timer-derived count. Its LiveView save payload showed:

```elixir
%{
  "enabled" => true,
  "reason" => "confidence_lost",
  "trust" => "degraded",
  "detected_reps" => nil,
  "cadence_ms" => []
}
```

The runtime currently turns one pose sample below `0.5` confidence into a permanent tracking loss. The completion form always prefills `burpeeCountDone`, which is derived from the timer/program timeline rather than the camera. It therefore can persist an expected count as `burpee_count_actual`.

The trace uploader batches up to 20 three-second chunks by count. A real deferred upload exceeded `Plug.Parsers`' body limit and failed with `Plug.Parsers.RequestTooLargeError`.

## Decisions

- Do not introduce an HSMM or a trained model in this change. There is no labelled, representative training corpus or measured accuracy target.
- Use a calibrated, deterministic temporal matcher for the personal-use app.
- A trusted camera result is authoritative for the initial completion value; a degraded result is never silently substituted with a timer-derived actual value.
- Preserve deferred trace upload as best-effort and non-blocking. It must never interrupt the workout or discard data after a failed upload.
- Keep the existing no-camera runner behavior unchanged.

## Camera Counting Design

### Guided calibration

After the camera is ready and before warmup, the user performs two slow reference burpees.

1. Accept calibration only when both motions have sufficient landmark quality, a complete down/up cycle, compatible durations, and compatible motion ranges.
2. Produce a per-session reference containing normalized movement shape, motion amplitude, and a plausible duration band.
3. If calibration fails, explain the framing or motion issue and offer retry or continue without camera. Do not enter camera-counting mode without a valid calibration.
4. Calibration remains in-memory for that workout; it is not presented as a universal user model.

### Runtime counting

The live counter remains client-authoritative and local:

1. Reject low-quality samples without counting them.
2. Use the existing readiness hysteresis before declaring tracking unavailable; a single low-confidence frame must not degrade the whole workout.
3. Treat a potential standing → down → up cycle as a rep only if it meets the calibrated amplitude and duration bounds and its normalized feature window matches the calibrated template.
4. Keep the refractory rule to prevent double counts.
5. Emit explicit local states for live, temporarily poor quality, and degraded tracking. A sustained quality loss degrades the result; no recovered confidence retroactively makes the interrupted observation trusted.

This is an explainable calibrated heuristic, not a claim of clinical or general-purpose accuracy. Future work may collect the user's consented, labelled traces and compare a sequence model against measured precision/recall targets.

## Completion and Persistence Design

### Completion form

| Session outcome | Initial actual reps | Save requirement | User-visible source |
| --- | --- | --- | --- |
| Trusted camera tracking | Camera-detected count | Editable; unchanged value saves as trusted | `Camera counted N reps` |
| Camera degraded or corrected | Blank | User must enter actual reps before Save | Explanation of camera failure or manual correction |
| No-camera workout | Existing timer-derived flow | Existing behavior | Timer/manual flow |

`actual_reps_confirmed` is local draft state. It starts false for a degraded camera run and becomes true only after a valid user entry. The Save control is disabled until that invariant holds. Draft restoration preserves the entered value and confirmation state.

### Durable audit fields

Add a `camera_reviewed` capture mode, distinct from `tracked`, `timed`, and `logged`. Add durable provenance fields to `workout_sessions`:

- `tracking_reason` — nullable string such as `confidence_lost` or `manual_correction`
- `detected_reps` — nullable integer
- `detected_duration_sec` — nullable numeric value

Persistence rules:

- `tracked`: a calibrated, finished camera result whose submitted actuals equal the detected result; store cadence and detected provenance.
- `camera_reviewed`: the camera was selected but degraded, or the user corrected a trusted result; store the entered actuals plus detection provenance/reason and no trusted cadence.
- `timed`: no-camera workout; preserve existing behavior.
- `logged`: existing free-form logging behavior.

The server validates the allowed relationship between submitted actuals, tracking trust, source, and provenance. Client UI gating is helpful UX, not the only protection.

## Deferred Trace Upload Design

### Recorder

Keep the existing three-second flush interval, but also flush before appending a sample that would make the serialized chunk payload exceed a conservative per-chunk byte budget below the server's `250_000` byte validation limit. If one sample cannot fit alone, omit that optional trace sample, retain a local diagnostic reason, and continue the workout.

### Uploader

Replace count-only batching with serialized-byte-budget batching:

- Keep a small secondary maximum item count.
- Build each request below a conservative body budget (for example 512 KiB), including envelope and JSON encoding.
- Delete only server-acknowledged chunk indexes.
- Retain all chunks and the ready marker after every non-2xx response, including 413.

This also lets already-queued valid chunks retry in smaller requests after deployment. The endpoint's parser limit remains a security boundary; the client adapts rather than globally increasing it.

## Testing and Verification

### Automated tests

- JS: calibration acceptance/rejection; one bad frame does not degrade; sustained loss does; calibrated cycle counts once; mismatched shape/duration does not count; trusted and reviewed completion drafts; draft restore; disabled Save until manual actual count exists.
- ExUnit: persistence mode and provenance fields for trusted, camera-reviewed, and timed sessions; malformed/forged tracking payloads cannot claim `tracked`.
- JS uploader: byte-limited chunk flush, byte-limited request batches, 413/non-2xx retention, and final-batch completion.
- Controller: accepted byte-safe batches, duplicate/idempotent batches, and invalid oversized individual chunks.

### Browser verification

1. Complete a valid calibrated camera workout and verify the completion prefill matches the camera count, the saved session is `tracked`, and cadence/provenance exist.
2. Force sustained confidence loss. Verify a visible explanation, blank actual-reps input, disabled Save until entry, and saved `camera_reviewed` provenance.
3. Verify a no-camera workout is unchanged.
4. Capture deferred upload request sizes below the budget and verify retry after a simulated non-2xx response.
5. Run `mix assets.build`, `mix precommit`, the required E2E artifact capture, DB verification, and cleanup.

## Non-goals

- No HSMM, neural model, external training pipeline, or claim of general-purpose rep-count accuracy.
- No upload of raw videos or dependence on third-party YouTube footage.
- No server interaction while an active workout is running.
