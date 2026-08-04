# Durable Workout Lifecycle and Recovery Design

## Summary

Make a workout or guided-video run durable before it begins without moving the active timer, camera, or rep counter to the server. The browser continues to run the workout locally. The server owns one UUID-keyed lifecycle row per user so an interrupted workout must be recorded manually or aborted before another can start. Browser-local drafts and pose traces become a retryable recovery outbox keyed by that same UUID.

## Problem

The current workout runner does not create a `workout_sessions` row until the user submits its final report. Its completion report is only an IndexedDB draft, and the video report is only LiveView socket state. Reloading, navigation, unavailable IndexedDB, an old program hash, or an explicit local discard can therefore make the report unavailable. The server cannot know that a workout began, cannot block a second workout, and cannot provide a durable recovery path.

## Goals

- Create a durable UUID-backed server lifecycle before a plan workout or video playback starts.
- Keep live runtime execution client-authoritative: no timer ticks, pose samples, or progress checkpoints are sent while a workout runs.
- Permit exactly one unresolved workout per user, across plans and videos.
- Require an unresolved workout to be manually reported or explicitly aborted before another plan workout or guided video can begin.
- Use the original lifecycle row for final reporting, never create a duplicate fact row during recovery.
- Restore locally retained report data whenever it matches the durable lifecycle UUID.
- Retry deferred pose uploads safely after prior failures without duplicate chunks or silent content replacement.
- Exclude unresolved and aborted sessions from every fact-based read model.

## Non-goals

- Resuming a timer, program position, camera stream, or pose counter after a browser crash.
- Uploading live pose traces while a workout runs.
- Making historical free-form logging block a new workout. A direct manual log remains a new `reported` record.
- Changing the existing request-size boundary for trace uploads.

## Lifecycle

`WorkoutSession` becomes the lifecycle aggregate as well as the reported workout fact.

```text
running -> report_pending -> reported
   \---------------------> aborted
```

### `running`

A plan runner generates a UUID immediately before its first warmup or workout action. A guided video generates one after an explicit **Start workout** action and before `video.play()` is allowed. The browser persists a local `start` command using that UUID, sends it to the server, and begins only after the server acknowledges the matching `running` row.

The row stores immutable source context derived by the server: user, plan or video, burpee type, planned count/duration, and execution program where applicable. The browser never supplies ownership, plan, video, or planned values.

### `report_pending`

When the client has finished its local runtime, it persists a local completion command/draft before requesting `running -> report_pending`. It renders the completion report only after the server acknowledges that transition.

If the client crashes before acknowledgement, the retained command is replayed on recovery. If local data is unavailable, the durable `running` row still blocks another workout and offers manual reporting or abort.

### `reported`

A report submission atomically updates the original row with actual count/duration, note/mood/tags, capture provenance, derived statistics, and `reported_at`. Only this state represents a completed workout fact. Milestones and style-performance side effects run only on the first successful transition to `reported`.

### `aborted`

A user may abort only `running` or `report_pending`. The transition records `aborted_at`; it does not delete the lifecycle row. An aborted row is never reportable, never shown as workout history, and never contributes to statistics. Its local completion draft, pose chunks, and upload marker are removed only after the abort acknowledgement.

## Data Model and Constraints

Add these fields to `workout_sessions`:

- `status` — Ecto enum persisted as a string: `running`, `report_pending`, `reported`, `aborted`.
- `source` — Ecto enum persisted as a string: `plan`, `video`, `manual`.
- `video_id` — nullable foreign key to `workout_videos`; exactly one of `plan_id` or `video_id` is set for a runtime-created lifecycle.
- `report_fingerprint` — SHA-256 of canonical, server-normalized report content. It distinguishes a replay of the same report from a conflicting second report.
- `report_pending_at`, `reported_at`, and `aborted_at` — lifecycle audit timestamps.

Backfill every current row to `status: "reported"` and infer `source: "plan"` when it has a plan, otherwise `source: "manual"`.

A database partial unique index on `user_id`, limited to `status IN ('running', 'report_pending')`, is the race-safe enforcement for the one-unresolved-session rule. The context also checks this rule so callers receive a meaningful existing lifecycle instead of a raw constraint error.

The schema has separate changesets:

- `start_changeset/2` accepts only server-derived lifecycle source fields and validates a `running` row.
- `report_changeset/2` validates required actual values and allowed tracking provenance when transitioning to `reported`.
- `abort_changeset/1` accepts no browser data.

Existing planned and free-form creation functions become compatibility wrappers around these changesets. Direct historical/manual logging inserts a `manual` + `reported` row in one transaction. Runtime completion always updates an existing UUID row.

## Server Context API

The `Workouts` context is the only place that transitions lifecycle state:

```elixir
begin_plan_session(user, plan, client_session_id)
begin_video_session(user, video, client_session_id)
mark_report_pending(user, client_session_id)
report_session(user, client_session_id, attrs, tracking)
abort_session(user, client_session_id)
get_unresolved_session(user)
```

Each operation scopes every lookup by `user_id` and UUID.

### Idempotency

- A repeated begin with the same UUID and identical server-owned source returns the existing row.
- A begin with a different UUID while an unresolved row exists returns that unresolved row without creating anything.
- Repeating `mark_report_pending` returns the row when it is already pending or reported; it rejects an aborted row.
- Repeating `report_session` returns `{:ok, session, :existing}` only when its canonical fingerprint equals the stored fingerprint. A different report for a reported UUID returns a conflict and never overwrites facts.
- Repeating abort returns the aborted row. Aborting a reported row returns a transition error.
- All stat/milestone side effects are conditional on an actual first transition to `reported`.

## Recovery and UI

All start entry points query `get_unresolved_session/1` before allowing work:

- `SessionLive` and `VideoLive.Show` redirect an unresolved user to a shared `SessionResolutionLive`.
- The resolution screen identifies the interrupted plan or video and exposes only **Log manually** and **Discard**.
- The manual form is the current logging experience applied to the original lifecycle row. It derives plan/video defaults server-side and changes the row to `reported`.

`SessionResolutionLive` owns a small recovery hook. It loads local data by the exact server UUID; it never searches by newest plan or program hash.

- When it finds a completion command while the server says `running`, it asks the server to replay `mark_report_pending`, then pre-fills the form from that draft.
- When it finds a draft while the server says `report_pending`, it pre-fills the form directly.
- When it finds no usable draft, the manual form remains available.
- If IndexedDB cannot open or write, the server lifecycle still ensures manual recovery and blocks new starts.

The plan runner keeps its existing IndexedDB trace and draft storage, but upgrades its database version and stores lifecycle commands/drafts by UUID. A successful report no longer deletes report data merely because navigation began: it removes it only after the reported response has been confirmed. A successful abort removes it only after the aborted response has been confirmed.

The video page stops treating native `ended` as the sole state source. An explicit Start workout gate creates the lifecycle before playback. Native `ended` requests `report_pending`; its report surface follows the same recovery and manual-resolution rules as a plan workout.

## Pose Trace Retry

Pose traces remain local while a workout runs. Once `report_session` succeeds, the client marks the UUID's trace queue ready with the server session ID and the global uploader drains it outside a session page.

The uploader retries on application mount, browser `online`, and its existing explicit drain trigger. It retains every chunk and ready marker after network, 413, parse, or other non-success responses. It removes a chunk only after the server acknowledges that chunk index.

The server uses the existing capture-run and `(run_id, chunk_index)` uniqueness, strengthened with a payload digest check:

- Same UUID, chunk index, and digest is an acknowledged no-op.
- Same UUID and chunk index with a different digest is a conflict; existing pose evidence is never overwritten.
- Traces may attach only to a user-owned `reported` plan session. Aborted, unresolved, video, and another user's rows are rejected.

A failed trace upload therefore cannot create duplicate pose chunks, cannot replace a prior chunk, and cannot block a later workout after its report is durable.

## Read Models

Every query that treats `workout_sessions` as facts must require `status == :reported`. This includes lists/history, weekly minutes, trained dates, last-run plan, charts, PB qualification, goal/milestone evaluation, gamification, style performance, streaks, and the workout feed. `SessionAnalysisLive` must redirect unless the user owns a `reported`, tracked session.

## Verification

### Context and schema

- Starting the same UUID twice is idempotent.
- Starting a second UUID while one is unresolved is rejected with the existing lifecycle.
- Valid and invalid transitions, duplicate report fingerprints, abort behavior, and first-transition-only side effects are covered.
- A newly created running row has no actuals; a reported row requires them.
- Every existing fact query ignores running, report-pending, and aborted rows.

### LiveView and browser hooks

- A plan cannot start until the server acknowledges its running UUID.
- A video cannot play before the server acknowledges its running UUID.
- Plan and video entry points redirect to the resolution page when any unresolved lifecycle exists.
- Local completion drafts replay the pending transition and prefill the resolution form by exact UUID.
- Missing local data exposes manual reporting and abort.
- Save/abort retries remain idempotent and do not clear local state before acknowledgement.

### Pose uploads

- Repeated acknowledged chunks do not duplicate rows.
- A repeated chunk index with altered content returns a conflict and retains the local queue.
- Retry after non-2xx preserves queue state and later drains successfully.
- Aborted or unresolved sessions cannot ingest traces.

### Final checks

Run focused JS and ExUnit suites while developing, then `mix precommit`. Follow `docs/testing/workout-session-e2e.md` to capture real-browser proof of plan recovery, video recovery, manual resolution, and deferred pose retry.
