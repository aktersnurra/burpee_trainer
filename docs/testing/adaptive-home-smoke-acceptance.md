# Inline Home state and History acceptance evidence

This is the Task 7 evidence record, not independent whole-slice approval. Tasks 1–6
were independently accepted. The parent directly approved the corrected current-run
visual presentation at the second screenshot gate. No checkpoint or clean-tree claim.

## Current evidence boundary

- Guarded disposable **Firefox / MIX_ENV=test** only; original data is not a fixture.
- Four viewports: 390×844, 320×844, 844×390, 1280×800; enlarged root text (200%) and
  reduced motion. Natural-scroll full-page captures and explicitly top-framed viewport
  captures are separately identified, with scroll coordinates retained.
- Current matrix and screenshots: `.e2e-artifacts/reports/inline-home-state-history/browser-report.json`.
  Timestamped native-focus/focusin/out, LiveView patch and node-removal/identity evidence:
  `boundary-trace-report.json` in that directory.
- Full commands, failures, source hashes and cleanup: `.superpowers/implementation/inline-home-state-history/task-7/verification.md`.
  Final reproduction and original-server evidence are named there.

## Exercised behavior

Repeated bar/result pointer, Enter and Space activation proves real sticky hidden/inert
state, heading focus, keyboard exclusion and reveal-before-opener focus on close.
History preserves instruction, groups, filters, Start token and every scoped persisted
plan/recommendation/design-context/session value during read-only actions. Empty and
unavailable states are distinct; no fabricated measurements or first-use prompt claim.

Actual today results take precedence at target; prior-day target completion and
unfinished-session coexistence retain exact Resume and prevent a second Start.
Per-type plots expose actual rep/duration values, density range and completion dates.
The session table preserves whole headers/numbers; oversized text uses a named native
keyboard-scrollable region rather than clipping, shrinking or global overflow hiding.

Controlled in-memory Req barriers exercise one-request busy success/failure and immutable
published/session content. A separately recorded explicit candidate Start and reload use
the canonical UUID verifier, not accidental Start during History inspection.

## Deliberate limitations

The supervisor-approved support script and its refusal/idempotence/cleanup/decoy tests
are evidence-only, confined to an exact disposable DB/run/user/BEAM/cwd. Persisted
completion fixtures and existing `home_now`/nil-selection socket seam injection prove
real browser patch/focus behavior, **not actual wall-clock midnight, onboarding or
reload checkpoint recovery**. Reconnect observations use actual current domain time.
The earlier untraced retained-focus failure did not reproduce in the instrumented
diagnostic; its timing cause is inconclusive. Final synchronized tests await the
documented native animation frames without reacquiring lost focus.

No live-provider, media playback, camera/tracking, full-duration performance, fresh-dev
migration, runtime/deployment or bootstrap readiness claim. One fresh marked test-DB
migration failed at the historical video-authorization rename; the approved single
canonical retry with PHX_SERVER unset during migration succeeded. That establishes
only this guarded setup, not the migration's root cause or general migration readiness.

## Earlier acceptance record (historical; not current-run proof)

# Adaptive Home Task 10 smoke evidence

## Accepted boundary

Supervisor adjudication for correction 1 accepts **guarded `MIX_ENV=test` disposable
Firefox smoke plus automated gates only**. This is not fresh-development startup,
deployment, full-duration workout/tracking, or whole-feature review approval.
The canonical procedure remains [workout-session-e2e.md](workout-session-e2e.md).

The following are accepted limitations, not passes or outstanding Task 10 scope decisions:

| Boundary | Disposition and evidence |
| --- | --- |
| Real-provider revision/Create | **Blocked: HOME-UPDATE-SUCCESS — external provider credentials and separately guarded disposable provider harness unavailable.** LIB-AUTHOR has the same prerequisites. The runbook's “Real-provider Create, Refine, persistence, and Publish” section requires both; ordinary fixtures remain provider-disabled. |
| Video playback/completion | Blocked by unavailable fixture media. `.e2e-artifacts/reports/task10-firefox-1789003214314.json` proves known-count Home and nil-count Videos route/snapshot/reload only. |
| Fresh-dev migration | Reproducible historical migration failure; root cause/regression attribution unresolved and outside demonstrated test-mode startup. `.superpowers/implementation/adaptive-home/task-10/dev-migration-investigation.log` records the exact failing rename in `20260826213050_add_video_execution_authorization_lanes.exs`. Age does not establish inherited cause. |
| Offline/History/pose browser scenarios | Not performed; outside this Home slice. No interrupted-session, camera, tracking, or full-duration performance claim. |
| Early-finish completion | `.e2e-artifacts/reports/task10-firefox-1789005510434.json` proves Home → Start → reload → active no-camera workout → finish/save: exactly one completed session with unchanged UUID, source, hash and program. Zero reps/seconds means persistence-path evidence only. |
| Server guarantees | Automated evidence below supports these guarantees, not separate Firefox injections or real-provider success. |

## Source-mapped automated evidence

Paths below are under `test/burpee_trainer/` unless stated otherwise:

- `workouts/home_selection_test.exs:15,128,145`: stale tab, wrong-source token,
  and exact duplicate Start. `:84` detects changed candidate content.
- `coach/context_test.exs:29,75,90,122`: shared-source privacy, explicit concurrent
  attempt identity, concurrent initialization, and ownership.
- `coach/draft_authoring_test.exs:97,327,536,569,593,616`: malformed/over-limit input,
  independent concurrent refinement CAS, stale source without orphan, accepted
  content/pointer/outcome commit and rollback boundaries. Requests use in-memory Req
  adapters, not live-provider traffic.
- `test/burpee_trainer_web/live/overview_live_test.exs:282`: malformed adjustment;
  `overview_revision_test.exs:8`: loader-only overlap/failure restoration.
- `workouts/finalization_test.exs:7,22,34,66` and `coach/memory_subscriber_test.exs:29`:
  rollback, scoped identity, accepted instructions, memory facts and subscriber handling.
  Separate committed-connection evidence for absent/raising subscriber is in
  `.superpowers/implementation/adaptive-home/task-7/committed.exs:70–84` and
  `committed.log`; it is not a browser injection.

Exact expanded inspection was corrected before this checkpoint:
`.e2e-artifacts/reports/task10-firefox-1789005388760.json` awaits expanded controls
and visible detail rows, compares eight ordered numeric prescriptions to canonical
persisted events, and verifies unchanged persistence. Its expanded screenshot is
`.e2e-artifacts/screenshots/1789005388760-1-inspection-expanded.png`.
Both corrected inspection/completion reports contain runtime isolation, credential
deletion, cleanup twice, decoy/trigger survival, and resource-removal proofs.
No browser/source behavior changed in correction 1.

## Correction 1 validation and contention finding

All logs here are under `.superpowers/implementation/adaptive-home/task-10/`.
Source/tests initially matched checkpoint `48c73706084a401321455ded5383ddbe6c407194`.
The first covering gate passed 65 tests (`fix-1-focused.log`, seed 134186).
A new unmodified `mix precommit` failed 384/385 (`fix-1-precommit.log`, seed 980297),
waiting one second for the concurrent refinement's provider readiness. The same-seed
file reproduced 22/23 (`fix-1-repro.log`). Earlier passing logs do not replace this failure.

Process/DB ownership inspection (`fix-1-processes.log`) found no competing test or
migration runner before reproduction; Expert nodes were present and untouched.
Diagnostic copies (`fix-1-diagnostic_test.exs`, `fix-1-timing_test.exs`) and their logs
show independent context writes still running at the deadline: one task in existing
Repo transaction retry, the other inserting the context baseline. Both reached their
provider barriers about two seconds after checkout and passed unchanged CAS assertions.
Thus contention precedes failed-test teardown; it was not eliminated.

Supervisor approved the narrow test-only fix: match the exact task PID/ref/barrier,
fail on premature result/exit, and allow a bounded ten-second readiness deadline,
matching the existing Task.await budget. Both tasks remain concurrent; ordered provider
release, stale outcome, and exact persisted assertions are unchanged. No production
retry/timeout, test serialization, or provider configuration changed.

Commands and final results:

- `mix help test` / `mix help precommit`: passed (`fix-1-help-*.log`).
- `mix test test/burpee_trainer/coach/draft_authoring_test.exs --seed 980297`:
  **23 passed**, 8.0s (`fix-1-green.log`). Expected contention log remains.
- `mix precommit`: **385 passed**, seed 434284, 146.8s
  (`fix-1-precommit-final.log`); two SQLite connection-lock diagnostics remain at
  lines 17–18, without failed tests. Do not interpret this as elimination of SQLite contention.
- Prior unchanged Node gate: **226 passed** (`fix-node.log`); no assets changed here.

Correction 1 changes only the concurrency test synchronization and this acceptance
record. Independent review remains required; no code verdict is claimed here.
