# Agent handover: review and improve the Coach/Home authoring branch

## Your assignment

Review this branch against `master@origin`, independently challenge its correctness and evidence, then fix concrete defects with focused regression tests. Review the whole net diff, not just the last minute-block prompt fix. Preserve the approved product behavior below. Prioritize data integrity, ownership, model-output validation, concurrency, migration safety, offline completion, and rebase integration before stylistic changes.

Do not treat this document, passing tests, or prior assistant success claims as proof. Trace the implementation and verify outcomes yourself. Do not replace the architecture or redesign approved screens without first proposing the change to the owner. Give a findings-first report with severity, file/line, reproduction, impact, fixes, fresh verification, and remaining risks.

## Workspace, version control, and safety

- Workspace: `/home/aktersnurra/projects/vibe/burpee_trainer.workspaces/coach-memory-llm-2026-09-06`.
- Use **jj**, not direct git commands. This is a jj workspace, not necessarily a named feature bookmark. Working-copy change ID: `vuttkmwz`.
- On 2026-10-04, `jj git fetch --remote origin -b master` confirmed upstream `9d8bfcf7` (`fix(logging): persist Burpee runtime diagnostics`). All 32 feature changes were rebased onto it, with conflict resolutions. Check the current state again; commit hashes change when the working copy changes.
- Inspect with `jj status`, `jj log -r 'master@origin..@'`, and `jj diff --from master@origin --to @`. The last command is the review scope; `jj diff` alone only covers the current change relative to its parent.
- **No push, merge, deployment, new history organization, workspace deletion, or destructive database operation without approval.** Do not squash the existing stack just to make review easier.
- Preserve the development server **PID 19018 / port 4000**. Re-check identity/cwd before any interaction. Do not restart, explicitly reload modules, or replace its environment without owner approval. Do not claim that the long-running server has loaded the latest backend code merely because source and fresh runtimes pass.
- Do not reset, prune, compact, migrate, or otherwise mutate the development database for testing. Earlier approved compaction is not continuing permission to repeat it.
- Keep browser/report artifacts under `.e2e-artifacts`; use guarded disposable databases and isolated Firefox profiles. Remove cookies, private auth manifests, and disposable databases; stop only processes you own.
- Do not send new paid authoring requests without fresh approval and a request budget. Prior bounded live runs were specifically approved; that is not an unlimited standing budget. Local Req plugs/provider replay are preferred.
- Do not launch additional agents unless delegation is explicitly authorized. You are already the requested fresh review agent.
- Read repository `AGENTS.md` and applicable debugging, TDD, review, and verification skills. Use `mix precommit` at completion.

## Original mission and approved product contracts

The mission grew from reliable Coach memory and level-aware workout authoring into a coherent Home → workout → completion → History/Coach experience. The app must preserve saved workouts, immutable execution/history, offline drafts, accessibility, and responsive presentation while making model-assisted authoring trustworthy and easy to use.

### Authoring and immutable workouts

- Home **New** uses structured parameters. Editing the current workout is **conversational**, opened with the pencil after expanding the current workout. Textbox: **“What do you want to change?”**
- Preparation is an unsaved, validated review. Complete candidate inspection precedes approval. Approval saves a **new** workout, never mutates the original. Selection is separate.
- Approval must be owned, source/hash verified, audited, checked against current context, provider-free, and idempotent. An explicit alternative requires explicit approval; do not silently relax the original request.
- Preserve exact requested reps, active pace, and explicitly supplied ordered sets. Duration and fixed-rest start tolerance is **±10 seconds**; requested total-pause lengths are exact. Do not weaken these tolerances or silently alter a candidate to make it pass.
- Approximate block lengths and ordinary-rest evenness are currently model-guided preferences, not hard semantic constraints. Explicit uneven/timed pauses, forbidden recovery, ordered sets, and hard numerical constraints take precedence.
- The review must expose the full compiler-backed workout, including cadence tails and exceptional intervals, not a thin summary that hides recovery.
- Preparing/saving status must remain visible, including a reduced-motion fallback. Abort/cancel must preserve appropriate drafts and leave the current workout unchanged.

### Home, History, Coach, and archival

- Warm-paper surfaces, **Arial**, generous whitespace, hairlines, restrained icons, and minimum 44px targets.
- Collapsed Home shows Play. Expanded Home reveals Switch / Play / New and the current-workout Edit pencil.
- No top-right navigation/Coach cluster. Weekly progress opens History. Coach access is through History or day/week completion.
- Coach order: grounded summary → expandable editable/deletable Details → new-info textbox. Opening Coach is local/provider-free; do not invent biography.
- Manual guidance edits/deletion must immediately replace effective provider context. Delayed classification must not overwrite subsequent edits.
- Owned published-workout trash is beside each chooser entry, separate from selection, with confirmation: **“Delete this workout? Past sessions will be kept.”** It archives, not physically deletes historical evidence.
- Preserve level/type filters. An excluded high-rep workout can be correctly level-filtered; do not “fix” that by changing publication, filters, or ownership.
- Standalone workout creation/library, Videos catalog, session-analysis, and Stats UI were removed or superseded. Legacy URLs redirect to Home/History. Running video-session/player/stream functionality remains. Do not resurrect obsolete screens to satisfy an old test.

## What was implemented

### Domain and authoring pipeline

- Level-aware requests, bounded input parsing, projected authoring context, structured extraction/configuration, typed phased work/rest definitions, compiler validation, and bounded repair.
- Explicit ordered `set_reps`, active-pace checking, fixed pause anchors, total-pause accounting including cadence tails, and schema selection for eligible optional-recovery Unbroken requests.
- `Coach.prepare_plan/4` / `Coach.approve_plan/3`, source/context ownership checks, prepared-candidate audits, explicit alternative review, provider-free/idempotent save, and separate selection.
- `Context.messages/7` projects initial/baseline and active instruction, effective memory, source, and bounded extras instead of replaying discarded design history. Audited entries remain distinct from the projected prompt. JSON cap: 262144 bytes.
- Durable guidance records and scoped manual editing/deletion. Delayed classification compares original text/`updated_at` and returns `{:error, :stale_review}` when appropriate.
- Local-by-default reconciliation/fallback: opening Home/Coach does not authorize a model request.

### UI and session behavior

- Inline Home/History, contextual Coach access, conversational Edit, visible progress/Abort, full compiled inspection, explicit approval and selection, and published-plan archival.
- Stable server session ID plus immutable `program_snapshot`/content hash. Offline work/completion draft retention and retry paths.
- `SessionHook.completionPayload()` rounds only `duration_sec_planned` to integer seconds. This fixes a real Save failure from `1200.0000000000002`; it must not round or modify runtime schedules, elapsed timing, or snapshots.

### Precision and latest intent fix

- Phase feedback now mirrors compiler **per-value millisecond quantization**, rather than pretending a sub-millisecond raw sum is executable. Prompt requests at most three fractional second digits and explicit balancing of flexible recovery. Mandatory pauses are not padded and tolerance is not loosened.
- Latest user wording:
  > try to make the rests more even except the 60s and 40s rests at min 11 and 18. try to base each set to be roughly 1 min long and then use the shave off  to save up to the additional rests
- Earlier proposal incorrectly treated one minute as active work, used ordinary rests **60 → 33 → 5 seconds**, and claimed exactly 20:00 despite compiling to 20:05. Arithmetic acceptance did not establish intent satisfaction.
- Updated extraction/source instructions distinguish **work plus ordinary recovery** blocks from active work alone, inherit the existing active pace for recovery edits, and avoid inventing exact ordered-set constraints from approximate preferences.
- Planning guidance balances ordinary recovery **across the whole workout**, excluding fixed pauses; permits jointly redistributing unconstrained sets/reps across phases; preserves ordered sets/hard constraints; and asks for truthful duration/compromise explanations.
- A compiler-validated reference preserves 140 reps at 5s, exactly 1200s, fixed 60s at 660s and 40s at 1080s, and sixteen ordinary 25s pauses across 19 sets.
- One approved Luna run of the exact wording used two calls, no repair/save: 140 reps, 5s pace, 18 sets, exactly 1200s, fixed pauses preserved, ordinary recovery **25–27s**. Work/rest cycles were mostly roughly 62–71.667s with a 50s tail, not all exactly 60s. This demonstrates one improvement, not a general semantic guarantee.

## Rebase integration — review carefully

Upstream brought OIDC/Pocket ID, camera/worker and runtime performance fixes, diagnostics, and defensive parameter handling. The feature stack intentionally replaces legacy workout/execution/editor flows. Neither blanket “ours” nor “theirs” is an adequate semantic resolution.

- Kept upstream OIDC subject resolution/linking and dependencies; retained timezone provisioning, paged users, reconciliation wake behavior, and Coach supervision. Application starts both Coach and configured OIDC children. No password authentication was restored.
- Kept source ownership lookup; obsolete mutable-plan/execution-program APIs and removed-screen files remain deleted where the branch replaces them.
- Preserved immutable session-keyed storage and durable finalization/resume rather than reviving the old client-UUID lifecycle/recovery screen. Blocked IndexedDB upgrade handling remains actionable and settles safely.
- Preserved camera failure **stage** propagation, camera-preview visibility signaling, pose-tracker suspend/resume for workout and countdown pause, renderer-owned countdown cleanup, and the upstream precomputed-frame render path to avoid duplicate rep accounting.
- Preserved upstream renderer caching/rest-breathing layer behavior and accessible **Pace progress** labeling. Legacy Abort/Discard confirmations are not reintroduced into the resume-preserving UI.
- Adapted incoming malformed-ID/filter/ownership regressions to the current Home chooser; legacy editor/Stats regressions assert safe redirects. Do not weaken current ownership/malformed-input tests merely because the old screens disappeared.
- Fixture scripts now use `Accounts.create_user/1`, report OIDC auth mode, and no longer generate password credentials. Cleanup decoy SQL follows the actual password-free schema. Cookie-injected fixture browsing does not establish real Pocket ID sign-in.
- README and browser runbook clarify current authoring/auth boundaries. Some older specs/history may still describe superseded UI/auth; compare against code and the contracts above, not historical wording alone.

## Navigation map

Start here, then follow callers and tests:

- `lib/burpee_trainer/coach.ex` — extraction, source revision context, prepare/review/approval orchestration.
- `lib/burpee_trainer/coach/{context,memory,guidance,guidance_entry,workout_request,workout_configuration,phased_workout_definition,workout_guidance,client,catalog}.ex`.
- `lib/burpee_trainer/{workouts,plan_compiler,coach_reconciler,application,accounts}.ex` and `lib/burpee_trainer/accounts/user.ex`.
- `lib/burpee_trainer/workouts/{workout_plan,home_selection,inspection,session_log}.ex` and compiler/program hash modules.
- `lib/burpee_trainer_web/live/{overview_live,home_workout_request,session_live,stats_live}.ex`, router, auth, legacy controller, and video session code.
- `lib/burpee_trainer_web/components/{home_workout_components,home_coach_components,home_history_components,session_components,layouts}.ex`.
- `assets/js/hooks/{session_hook.js,session_flow_fsm.mjs,session_segment_fsm.mjs,session_renderer.mjs,session_store.mjs,home_adjustment.mjs,home_pending_session.mjs}`; upstream pose tracker/detector/worker modules; `assets/css/{adaptive_home,app}.css`.
- `scripts/e2e/{library_setup,setup,verify,cleanup}.exs`, migrations/rehearsal helpers, and their tests.
- Authoring tests under `test/burpee_trainer/coach/`; snapshot/archival tests under `test/burpee_trainer/workouts/`; Home authoring/lifecycle/history/session tests under `test/burpee_trainer_web/`; browser hook `*_test.mjs`.

Useful stable selectors: `#home-title-action`, `#home-progress-history`, `#history-coach-open`, `#home-result-coach`, `#home-coach-summary`, `#history-coach-memory-toggle`, `#history-coach-entries`, `#home-edit-form`, `#home-edit-instruction`, `#home-edit-progress`, `#home-edit-review`, `#home-inspection`, `#home-request-confirm`, `#home-new-select`, `#home-delete-workout-<id>`, `#home-alternative-plan-<id>-select`.

## How to review and improve

1. **Orient and audit the full diff.** Confirm master ancestry and absence of conflicted feature revisions. Inventory deleted APIs/routes and migration changes. Look for unintentionally lost upstream behavior outside the conflicted hunks as well as inside them.
2. **Prove data/authority boundaries.** Attempt cross-user source/candidate/guidance/archive/session operations, stale hashes/context, repeated approvals, asynchronous races, and forged prepared input. Verify original definitions and completed snapshots stay byte/semantically immutable. Review migration rehearsal against representative existing schemas/data; passing fresh-schema tests is not permission to run destructive migration on real data.
3. **Trace request → schema → prompt → provider/replay → compiler → review → approval → selection.** Separate exact constraints from preferences and explanations. Challenge prompt-string tests with executable candidate/replay checks. Test forbidden/optional/even recovery, unknown pace, explicit one-set semantics, supplied ordered sets, fractional rests, fixed anchors, and infeasibility without silent relaxation.
4. **Challenge semantic quality.** Vary natural phrasing for minute-long work/rest blocks and global ordinary-rest balance. Do not hard-code the single 140-rep example. If stronger semantic enforcement or clarification is warranted, propose the smallest design before changing the request/schema contract. Treat false rationale (“exact” vs tolerated duration, “even” vs phase-local allocation) as a defect, not as evidence of success.
5. **Review concurrency and memory.** Async cancellation, source/context changes during preparation, stale delayed guidance classification, approval idempotency, projected-context bounds, and absence of provider work during local navigation/reconciliation.
6. **Exercise current UI, not historical mockups.** Phone/desktop and reduced motion; keyboard/focus; collapsed/expanded actions; Coach access/order; complete review before approval; select separate from save; confirmation and independent trash/select targets; level filtering; draft retention and repeat requests. Follow `docs/testing/workout-session-e2e.md` with its historical-section caveats.
7. **Exercise offline/session integration.** Same server identity/hash/snapshot across reload; completion before channel join; integer completion DTO; online retry; acknowledged server completion versus pending local evidence; pose trace ownership; blocked IndexedDB; new worker/preview/pause behavior; video session start/stream/completion. Do not infer clock restoration or physical rep counting from snapshot identity alone.
8. **Fix verified defects with RED → GREEN tests**, minimal changes, fresh checks, and an evidence report. Do not just rewrite tests to bless changed output. Keep one writer per cwd if delegation is later approved.

## Verification and evidence boundaries

Latest post-rebase checks are logged in:

- `.e2e-artifacts/rebase-final-precommit.log` — **605 Elixir tests passed**, compilation with warnings-as-errors and formatting/dependency checks.
- `.e2e-artifacts/rebase-final-js.log` — **288 JS tests passed**, including upstream camera/runtime additions.
- `.e2e-artifacts/rebase-final-assets.log` — app plus pose-worker build **exit 0**.
- `.e2e-artifacts/rebase-route-tests.log` / `rebase-cleanup-test.log` — focused integration regressions.
- `.e2e-artifacts/rebase-before.json` — pre-rebase ref/operation/workspace identities, for inspection only; do not blindly undo shared repo operations.

Run fresh after your edits:

```sh
ERL_FLAGS='+S 4:4' MIX_ENV=test mix precommit
npm --prefix assets ci
npm --prefix assets test
ERL_FLAGS='+S 4:4' MIX_ENV=test mix assets.build
```

`ERL_FLAGS` bounds schedulers in this environment. Use test/disposable configuration, never a dev database alias. `mix precommit` can format files/unlock unused dependencies; inspect its resulting diff. Run focused failing tests first. Probe changed paths with active LSP diagnostics, but distinguish confirmed clean, unavailable/push-only, and cached findings. Temporary rebase marker errors can remain in the session cache after current Mix files compile; standalone auxiliary Elixir checking can also falsely report unloaded `ConnCase`. Verify with current Mix compilation/tests, do not suppress actual errors or claim empty/stale caches prove cleanliness.

Prior evidence (local workspace, not new post-rebase browser acceptance):

- `.e2e-artifacts/reports/{merge-readiness-verification,minute-block-verification,coach-corrections-verification,edit-feedback-verification,soft-delete-verification}.md` and accompanying JSON/logs/screenshots.
- `.e2e-artifacts/reports/minute-block-live.json`, `.e2e-artifacts/minute-block-candidate.json`, and `.e2e-artifacts/minute-block-calls.log`.
- Before rebase: 584 Elixir / 234 JS tests passed; bounded live New/Edit, review/approval/select/reload, archival/history, guidance editing, offline early-finish draft/save retry, immutable DB snapshots, and projected context with 3000 discarded entries were exercised.
- The offline browser session was **1 rep / 5 seconds early finish**, not a completed 20-minute prescription. Fixture/controlled runs do not establish real model compliance, authentication, camera hardware, or playable video.

Still unproved or requiring owner coordination:

- Loaded backend readiness in the original long-running development process (including the older Context readiness task); source/fresh-runtime success is insufficient. The user has not approved a restart. Upstream adds OIDC schema/configuration; coordinate any real database migration/runtime transition with the owner instead of assuming the old process/database is ready.
- New post-rebase browser/OIDC acceptance.
- Full prescribed workout duration, real camera/pose counting, playable video, and paused elapsed-clock restoration across reload.
- General model instruction compliance: evenness/minute blocks remain preferences; one successful Luna example is bounded evidence.

The `/docs/` tree and `.e2e-artifacts` are ignored for newly created files. Later local plans/specs and reports may not travel to a fresh checkout. If present, latest authority includes the October 2 Coach/Edit corrections and soft-delete plans and October 3 minute-block plan; older shared-form/top-right Coach plans are superseded. This handover intentionally repeats the approved contracts so review does not depend on those private/local files.

## Required return to owner

Summarize: reviewed scope/base; ranked findings; minimal fixes and added tests; exact verification commands/results; browser/provider evidence and request counts (if authorized); data/process cleanup; remaining risks/blockers; and whether the branch is ready for owner-controlled integration. Do not merge, deploy, restart the protected server, or label blocked physical/runtime checks as passed.
