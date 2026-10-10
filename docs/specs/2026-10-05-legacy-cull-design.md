# Legacy cull and test policy

> **Superseded in part** by `2026-10-10-frictionless-home-design.md`: first use opens on a starter workout; the `:first_workout` state and the free-text bootstrap prompt are removed.

## Status

Approved by the owner in conversation on 2026-10-05. First sub-project of
`2026-10-05-coach-first-architecture-design.md`. Product behaviour visible to the owner does
not change, except that old redirect-only URLs are removed.

## Goal

Remove every line of production code that the running app cannot reach, every test that
cannot catch a regression, and the branch's intermediate migration history, while ending
with a small suite of full-flow tests that does catch regressions.

## Already done (working copy, 2026-10-04)

Unreachable modules removed, suite green (586 tests): `Streak`, `WeeklyTrainingContract`
and its four submodules, `PaceModel`, `Workouts.SessionLog`, `Workouts.Capture`,
`LogFormComponent`, `GoalFormComponent`, `StubLive`, `Params`, `Release`, `Duration`, `Mood`,
`BurpeeType`, plus manual free-form session logging (no UI used it). The test fixture for
manual history rows now inserts the row directly.

## Scope

### 1. Dead public API

Delete every public function with no caller in `lib/`, then every private function the
compiler reports as unused, repeating until `mix compile --warnings-as-errors` is clean.
The list as of 2026-10-05:

- `Coach`: `prepare_draft`, `confirm_draft`, `prepare_refinement`, `confirm_refinement`,
  `create_draft`, `refine_draft`, `recommend_workout`, and private helpers they alone use.
- `Workouts`: `abort_pose_capture_run`, `append_pose_trace_chunk`,
  `complete_pose_capture_run`, `start_pose_capture_run`, `attach_candidate`,
  `attach_candidate_if_current`, `reject_candidate`, `select_recommendation`,
  `select_recommendation_if_current`, `select_recommendation_candidate_if_current`,
  `best_qualifying_session`, `copy_to_draft`, `current_week_pushups`, `delete_draft`,
  `gamification_stats`, `get_plan`, `get_plan!`, `get_session!`, `last_run_plan`,
  `last_session_for_type`, `list_drafts`, `list_owned_supported_plans`,
  `list_trailing_authoritative_sessions`, `pending_coach_clarification`, `preload_plan`,
  `publish_and_start_draft`, `publish_draft`, `replace_draft`, `this_week_trained_days`.
- `Accounts`: `any_user?`, `change_user_registration`, `get_user!`.
- `Coach.AuthoritativeSession.session_sort_key`, `Coach.Policy.catch_up_ceiling`,
  `Levels`: `landmark_achieved?`, `landmark_history`, `level_status`, `next_landmark`;
  `Scoring.weekly_pushups`, `UserTime.in_week?`; `Videos`: `get_available_video`,
  `get_video!`, `list_available_follow_along_videos`, `list_videos`.
- Schema helpers: `CoachRecommendation.candidate_changeset`,
  `PoseCaptureRun.abort_changeset`.
- Components and helpers: `qs_action_row`, `qs_info_note`, `recommendation_heading`,
  `result_session`, `theme_button`, `begin_conflict`, `Fmt.level_color`,
  `Fmt.session_started_at`, `CreationParameters.from_draft`.

- Email: sign-in is OIDC-only and nothing sends mail, so delete `BurpeeTrainer.Mailer`, the
  Swoosh dependency and its configuration, and the `/dev/mailbox` route.

`Workouts.accept_candidate` stays: starting a pending bootstrap draft uses it.

### 2. Disabled LLM recommendation path

`CoachReconciler` only calls the provider when `provider_requests_enabled?` is true, and no
configuration enables it. Delete `Coach.Recommendation`, the `:coach_recommendation`
response schema in `Coach.Client`, the `:recommendation` system prompt in
`Coach.WorkoutGuidance`, and the reconciler's provider code (`provider_options`,
`provider_requests_enabled?`, `maybe_request_candidate`, `fallback_selected?`,
`provider_messages`, `history_context`, `library_context`). The reconciler keeps its
deterministic job (ensure the slot's recommendation row and an available selection) until
the coach-agent sub-project replaces it. `ranked_plan_ids` stays in the schema and in
`Catalog.order_plans`; it is always empty until the coach agent writes it.

### 3. Keyword heuristics

After step 1, every authoring path carries a user-confirmed `WorkoutRequest`. Make it
mandatory (`bootstrap_home_draft` and `revise_home_workout` become private to their
`confirm_*` callers) and replace the regex checks with request fields:

| Removed | Replacement |
|---|---|
| `requested_rest?(instruction)` | `request.recovery == "required"` |
| `requested_active_pace?(instruction)` | `request.requested_pace_sec != nil` |

This covers `validate_requested_rest`, `validate_default_movement_pace`,
`correction_feedback` advice, and `target_rest_budget`. Recovery rules that
`WorkoutRequest.validate_definition` already enforces are not duplicated.

### 4. Routes

- Delete `LegacyPageController`, `StatsLive`, and the routes `/workouts`, `/workouts/new`,
  `/workouts/drafts/:id`, `/videos`, `/videos/:id`, `/stats`, `/stats/sessions/:id`.
  Unknown paths return 404.
- Move `/tracking-test` (camera diagnostic) into the existing `dev_routes` scope so it is
  not served in production.
- **Video workouts are a supported feature and must keep working:** Home chooser Videos tab,
  `/videos/:video_id/session/:session_id` (`VideoLive.Show`), `/videos/stream/:filename`
  (`VideoController`), completion logging, and `mix burpee_trainer.add_video`.

### 5. Goals

Goals stay: the coach-agent sub-project adds goal creation through a Coach-page tool. This
sub-project keeps the `Goal` schema, its table, and goal attribution on session completion,
and deletes only the Goals functions no code calls (`create_goal`, `change_goal`,
`abandon_goal`, `get_goal!`, `get_active_performance_goal`, `list_active_goals`,
`list_current_goals`). The coach-agent sub-project adds back exactly what its tool needs.

### 6. Migrations

Production runs `master` and has applied none of this branch's migrations (owner, 2026-10-05).

- Replace the branch's 18 migrations (`20260804220023` … `20260928202639`) with one
  migration, version `20261005000000`, that transforms the upstream schema (all `master`
  migrations through `20260908000000_add_oidc_sub_to_users`) into the current final schema.
- Data rules are unchanged from the current chain: keep completed sessions with their
  snapshots, pose evidence, users, videos and published plans; drop the obsolete tables
  listed in `20260829085005_rebuild_workout_library.exs`; discard abandoned state as that
  migration does today. The migration runs atomically with foreign keys off, checks one exact
  source schema fingerprint, treats an exact target fingerprint as already applied, and
  otherwise fails closed. It is irreversible; `down` directs the operator to the backup.
- **Equivalence proof before deletion:** seed a database built from `master` migrations with
  representative data (adapted from the deletion-first seed: completed and abandoned
  sessions, plans, recommendations, pose runs and chunks, videos). Run the old chain on one
  copy and the squashed migration on another. Schemas must match except `users` column
  order; all table contents must match exactly. Only then delete the old migrations.
- The retained migration test asserts those data rules explicitly against the squashed
  migration (fresh database and upstream-shaped database with data). The four current
  migration test files are replaced by it.
- `scripts/migrations/rehearse_deletion_first.exs` is retargeted to the squashed migration so
  a copy of the production database can be rehearsed before deploying.

### 7. Local dev database

At implementation time, and only after the owner's explicit go-ahead: stop the dev server
the owner is running, copy `burpee_trainer_dev.db` (with `-wal`/`-shm`) to a dated backup,
create a fresh database from the migrations, and sign in again through Pocket ID (the first
login creates the user). The backup is kept, not deleted.

### 8. Test policy

**A test is kept only if** it would fail on a real regression of user-visible behaviour, a
data-integrity or ownership rule, or a pure-core invariant. **Delete** tests that:

- assert prompt strings, CSS classes, markup structure or copy details;
- test private helpers or internal call shapes rather than behaviour;
- mock the unit under test, or replay canned provider answers through code that only
  forwards them;
- cover removed or unreachable code;
- duplicate a full-flow test without adding a distinct failure mode.

**Core flow suite (must exist afterwards; add or rewrite where missing):**

1. Home New → review → approve (saved and published, not selected) → select → start →
   complete → visible in History.
2. Edit the current workout → review → approve a new variation; the original and existing
   session snapshots are unchanged.
3. Archive a workout from the chooser; past sessions are kept; Home falls back correctly.
4. Coach page: add, edit and delete guidance; a late classification never overwrites an edit.
5. Offline completion: lost save reply → retry acknowledged; reconnect to an already-saved
   session settles local evidence and returns Home.
6. Cross-user and stale-state attacks on approve, select, archive, guidance and session
   completion are rejected without side effects.
7. Video workout: pick a video on Home → session → log → visible in History.
8. Migration: fresh database and upstream-shaped database both reach the final schema
   with the data rules above.
9. JS: the runner and session state machines execute a real compiled program end to end
   (timing, rests, completion payload), and the session store finalizes evidence.

Provider-dependent flows use the existing local provider plug with recorded responses; no
test makes paid calls. Property-based tests stay for `PlanCompiler` and `WorkoutRequest`
validation, as `TESTING.md` requires.

### 9. Documentation

`CLAUDE.md` describes the code as it is after the cull: the module map drops removed
modules and the missing `INTELLIGENCE_LAYER.md` reference, and the testing section states
the policy above. `README.md` drops removed screens and routes.

## Out of scope

The Home state machine, scoped authorization, coach agent, rest fitter, durable jobs,
insights, and removal of `CoachReconciler` or the design-session audit log. Those are later
sub-projects.

## Acceptance criteria

- `mix precommit` (test env), `npm --prefix assets test`, and `mix assets.build` pass.
- The reachability scan (xref graph from application, router, endpoint and mix tasks) and
  the unused-public-function scan report nothing except framework entry points configured
  outside code (`ErrorHTML`, `ErrorJSON`, `SessionHTML`).
- The nine core flows above exist and pass.
- The migration equivalence check passed before the old migrations were deleted.
- A before/after line-count report for `lib/`, `test/`, `assets/js/` and
  `priv/repo/migrations/` is included in the completion report.

## Working rules

- Deletions need the owner's approval prompts; no auto-mode bulk deletion.
- No commits, pushes, deploys or dev-server restarts without explicit owner approval. Step 7
  needs a separate go-ahead.
- No paid provider calls.
