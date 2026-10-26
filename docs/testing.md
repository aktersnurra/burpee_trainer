# Testing

## Policy

Keep a test only when it would fail on a real regression of user-visible behavior, a data-integrity or ownership rule, or a pure-core invariant.

Delete tests that:

- assert prompt strings, copy, CSS classes, or markup structure **only for styling or structure**. Keep assertions that establish accessibility contracts, including roles, ARIA labels, screen-reader behavior, keyboard operation, `prefers-reduced-motion`, and 44px target size;
- test private helpers or internal call shapes rather than behavior;
- mock the unit under test or replay a provider answer through code that only forwards it;
- cover removed or unreachable code; or
- duplicate a full flow without adding a distinct failure mode.

Provider-dependent coverage uses the local recorded-response plug. Tests do not make paid provider calls. Property-based tests remain for `PlanCompiler` and `WorkoutRequest` validation.

## Core flow suite

The full-flow suite has one file for each user-visible behavior below:

1. New workout through review, approval, selection, session completion, and History: `test/burpee_trainer_web/flows/new_workout_flow_test.exs`
2. Editing a variation preserves the source and used session snapshots: `test/burpee_trainer_web/flows/edit_workout_flow_test.exs`
3. Archiving preserves completed snapshots and selects the Home fallback: `test/burpee_trainer_web/flows/archive_flow_test.exs`
4. Coach-page conversation: a reply, a proposed goal confirmed in place, notebook edits (each admitting a summary refresh), and a retained message when the provider is unavailable: `test/burpee_trainer_web/flows/coach_conversation_flow_test.exs`
5. Lost completion acknowledgement retry and reconnect settlement: `test/burpee_trainer_web/flows/offline_completion_flow_test.exs`
6. Foreign-user and stale-state approval, selection, archive, notebook, and completion attacks rejected without side effects: `test/burpee_trainer_web/flows/ownership_flow_test.exs`
7. Video selection from Home through logging and History: `test/burpee_trainer_web/flows/video_workout_flow_test.exs`
8. Fresh and upstream-shaped databases reach the final schema and preserve the specified data rules: `test/burpee_trainer/schema_migration_test.exs`
9. A compiled program drives the JavaScript runner and durable session-store finalization end to end: `assets/js/hooks/session_runner_flow_test.mjs`
10. Session completion schedules the planning job, which selects a workout Home then shows with its rationale: `test/burpee_trainer_web/flows/planned_next_workout_flow_test.exs`
11. Session completion narrates an insight (validated or fallback) shown on Home and in History: `test/burpee_trainer_web/flows/insight_flow_test.exs`, `test/burpee_trainer_web/flows/insight_presentation_test.exs`
12. A fresh user opens on a ready starter workout with Start as the one action, and opening Home never plans; planning follows a completed or logged session or Retry: `test/burpee_trainer_web/live/home_first_use_test.exs`
13. The coach summary heads History and is the only way into Coach and back; a summary from an earlier week shows the loader until the refresh arrives; with nothing to summarize the line invites the owner to the coach instead: `test/burpee_trainer_web/flows/history_summary_flow_test.exs`
14. Real recorded 20-minute sessions, replayed through the camera's rep detector (HSMM), count exactly their reps: a steady one (140) and one that slipped with a long pause (135): `assets/js/hooks/pose_burpee_hsmm_session_fixture_test.mjs`. Their features are also rebuilt from the recorded keypoints, must match the recorded ones (within the stored rounding) and still count exactly, and with one frame in 30 made unusable they still count exactly. Each fixture is every usable pose sample the camera recorded, gzipped.
15. A trace the tracker records replays through the counter to exactly the reps it emitted, dropouts included: `assets/js/hooks/pose_tracker_impl_test.mjs`.

## Commands

Use bounded schedulers and the test environment for Elixir checks:

```bash
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test
ERL_FLAGS='+S 4:4' MIX_ENV=test mix test test/burpee_trainer_web/flows
npm --prefix assets test
```

The final integrated gate additionally runs `ERL_FLAGS='+S 4:4' MIX_ENV=test mix precommit` and `ERL_FLAGS='+S 4:4' MIX_ENV=test mix assets.build`. Do not treat a docs-lane run as the integrated gate.
