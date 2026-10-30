# Changelog

## 2026-10-30 — Swap is the drawer; Edit and New wait behind the opened workout

- Home no longer has Edit, Swap or New buttons. Swap is a swipe right (the drawer); Edit and New appear when you open the workout and swipe up, or use the handle at the bottom of the opened workout. A closed workout only says "Swipe right to swap". The server refuses `open_options` on a closed workout.

## 2026-10-30 — The handle shows everything Home can do; hidden until asked

- Edit, Swap and New stay hidden until asked for, as designed: Home starts with the one thing to do. The ways to ask are a tap on the workout, a swipe, or the handle at the bottom, and the handle's sheet now offers Swap workout beside Edit and New, so nothing needs the workout opened first. `docs/ui.md` states the principle.

## 2026-10-30 — The swipes are findable; the studio has a browser check

- Home has a handle at its bottom edge that opens the Edit / New sheet, and a line above it saying what the two swipes do, for the first three visits or until the first swipe (`HomeHint`).
- `scripts/e2e/studio_journey.mjs` drives the swipes, Edit and New in a phone-sized browser against a stubbed server (`scripts/e2e/studio_preview.exs`) and fails on a layout, gesture or tap-target regression: the shared left edge, sideways scroll, spinner, Save and Run, the swiped value, the set size, the summary and Run (`docs/guides/studio-e2e.md`). `docs/guides/ios-device-check.md` lists what only a phone can check.
- The send key is a 44px target (it was 40), the docked box measures again once the keyboard has settled, and the sheet no longer draws a focus ring on its first choice.
- Small composition fixes: the quick-change chips run to the screen edge when they scroll, the start toggles line up with the card above them, and the coach's loader sits level with its line.

## 2026-10-29 — One set of conventions across the pages

- One edge: Home, Progress, the studio and the docked box all start at `--gutter` (30px); the studio and the dock had their own (36px and 16px).
- One radius for every card, box, sheet and the composer (`--radius-surface`, 20px), instead of 18, 20, 22 and 26.
- One composer: the single growing line with the send key inside, for the coach and the studio alike (the older two-row card is gone).
- The type is the Home tokens plus two for screens built around one thing (`--text-heading`, `--text-hero`); the studio's own sizes, its uppercase card label and its small-caps table header are gone.
- Motion uses the two durations (`--motion-settle`, `--motion-quick`) everywhere, including the drawer and the studio.
- `docs/ui.md` says where the studio differs on purpose (words on its pills, a round back button) and where it must not (gutter, radius, type, motion).

## 2026-10-29 — Edit and New are a chat; swipes on Home

- Swipe right on Home and the page slides over to reveal the list of workouts to swap to, as in the Claude app; swipe left or tap the page to close it. Swipe up for Edit this workout and New workout. The buttons stay.
- Edit and New take Home's place as a chat with a back button. Edit opens with today's workout as the coach's first message; each message refines the latest proposal, a spinner shows while the coach works, and the proposal arrives as a new card with Save and Run pills under it (and Save). Back leaves with no change.
- New asks one question per screen: burpee type and set style by tap (which answers and moves on), then duration, reps and pace by swiping the value (or its buttons) with a Next. Duration starts at 20 minutes or what the week has left and never passes it; reps start from your progression; pace from a typical reference that leaves room to recover. Unbroken sets also ask for the most reps in one set, which the coach must respect. The last screen is what you chose, with Create workout (sent as it is) or Add a request, which opens the chat with an empty box for a request only. Reps and pace show what they come to (moving and recovering time). The New header has no close button and no subtitle; back is one step back.
- Run (under a proposal) now saves it, makes it today's workout and starts it; the camera and warmup toggles sit beside it.
- Workout cards are redone: a label, the name, minutes and reps as chips, why, then a small table.
- Removed the inline Edit and New forms and their review (`HomeWorkoutRequest`'s form fields, budgets and pills).

## 2026-10-29 — Design by conversation, a box above the keyboard, a coach that sounds like one

- Opening the app on iPhone showed the old stick-figure plank on the launch screen. The launch images (`priv/static/images/startup/`) now show the app icon on the warm-stone background (`scripts/render_startup_screens.py`). iOS caches launch images per home-screen shortcut: remove and re-add the shortcut to see the new one.
- The loading animation is the approved silhouette inverted: dark ink on a transparent background, so it sits on any surface instead of in a black square. The ivory-on-black exports are gone (`scripts/render_burpee_loader.py`).
- Each follow-up to a workout design was read against the workout the design started from, so every improvement set it back. After the first proposal the box stays and each message refines the **latest proposal** (`Coach.prepare_refinement/4`); what each follow-up replaced stays above it as a conversation (`design_turns`). A follow-up that fails leaves the proposal and the typed words in place, and Cancel works while the coach is on it. New refines by talking too once it has a proposal.
- The box you write in is docked above the iPhone keyboard (`ChatDock`, from `visualViewport`) for a design's follow-ups and for the coach, and brings the newest message into view as the conversation grows. The actions on a proposal (Save, Use) ride the dock, so they stay reachable.
- The coach reads like a person, not a dashboard: its voice starts from what was just said and drops trends and "insights"; the coach page answers in a few sentences with at most one question; the note on Home is written from what you have told the coach (its notes about you and this week's last messages), and the look back names something specific or is left empty. When the coach changes its memory after a reply, the note is written again.

## 2026-10-27 — Pace consistency is measured inside each set

- Pace consistency was 1 minus the coefficient of variation of every gap between reps, the gaps across rests included, so every workout with rests scored 0 (sessions 56 and 57), and a ladder's planned change of pace read as unevenness. It is now derived with the session's fatigue (`Workouts.Fatigue`), from each rep's interval inside a set against that set's planned one; `Workouts.PaceConsistency` is removed. Production: 56 is 0.896, 57 is 0.957, and 40 and 58, without rests, keep 0.974 and 0.972.
- Like the fatigue columns, `pace_consistency` is derived from the locked `cadence_ms` and `program_snapshot`, so the completion trigger no longer locks it; a migration recomputes it for completed camera sessions. The coach's glossary, which Claude reads through the MCP, defines it.

## 2026-10-27 — Running ahead of the beat is keeping up

- Fatigue (`Workouts.Fatigue`) dropped a rep done more than half an interval ahead of its beat, so its beat read as missed: finishing a set early could read as falling behind, and the planner then repeated the workout for late fatigue instead of progressing. Scheduled reps now take the detections in order, and an early one is that rep done ahead. Late is unchanged: a rep more than half an interval behind still leaves its beat missed, so one missed detection still never shifts the reps after it, and falling behind still shows.
- A migration recomputes completed camera sessions' fatigue. On production data only session 56 changes its verdict: it finished sets 2, 5, 9 and 10 by 10–21 s early and read as slipping at 19:18; it now reads as kept up, with 149 of 150 reps caught.
- Recovery (`recovery_delta_sec`) was the gap from a set's last rep to the next set's first, so finishing a set early, and the longer rest camera pacing gives it, read as slow recovery (session 56: 1.3 s). It is now how late the first rep after a rest lands on its beat, net of how late the workout's first rep landed after the same count-in (session 56: 0.5 s, session 57: 0.7 s). A second migration recomputes it.
- The coach's glossary, which Claude reads through the MCP too, says finishing a set early is keeping up, that a negative pace delta is ahead, and what recovery now measures.

## 2026-10-27 — The favicon and web app manifest load in production

- In production the layout links the fingerprinted favicon and manifest (`/favicon-<digest>.ico`, `/manifest-<digest>.webmanifest`), and both answered 404: the static plug serves only paths whose first segment is listed, and a digested top-level file no longer matches its name. A browser without a cached icon (a private window, a first visit) showed none, and the phone never got the manifest or its icons. The endpoint now also serves top-level files starting with `favicon` or `manifest`.

## 2026-10-27 — Poses upload from the finish screen

- A camera workout's poses start uploading as soon as its finish screen shows, while you fill it in, instead of after Save. The server takes poses for a workout not saved yet and completes the trace when it is saved; poses written after that still land on it.
- Removing a workout removes its trace everywhere. Deleting or discarding it already deleted the server's copy; now, when a device uploads poses for a workout no one has any more, the server answers 410 Gone and the device deletes its copy, instead of showing a rejection notice for good. A workout that exists but is someone else's still answers 404, so a shared device keeps the other sign-in's poses.

## 2026-10-27 — Camera workouts follow your pace

- While the camera counts, the screen shows its reps instead of the schedule's: the reps left in the set and the total. The top bar keeps the clock as a faded fill, with a solid fill of the reps done over it, so being ahead of or behind the clock shows at a glance. If tracking drops, the screen goes back to the schedule.
- A set ends when the camera has counted its reps: the rest starts at once (the beeps stop), and the set's remaining time goes to that rest, so the next set starts when it would have and the workout keeps its length (a 20-minute session still counts for levels and goals). Only a set followed by a rest ends early; the last set, or a set straight into another, runs on the clock. Behind the clock, a set ends on the clock as before.

## 2026-10-26 — A proper HSMM counts camera reps

- The camera's rep counter is an explicit-duration HSMM (`pose_burpee_hsmm.mjs`): standing, lowering, pushup, rising, and an "other" phase for bending or squatting during rests, on a 100 ms clock where an unusable frame is a missing observation. It is decoded by Viterbi with a 600 ms lag, so a rep is decided about 0.7 s after you stand up; the session dates it when it happened (`lagMs` on `pose-tracker:rep`). Its parameters (`pose_burpee_hsmm_model.mjs`) are fitted, not hand-tuned. Before, one bad frame while lowering lost the rep. On the recorded sessions (140 and 135 reps) it still counts exactly, and with dropouts it holds where the old counter did not: 1% bursts of 830 ms leave 138–140 of 140 (was 108–120).
- Traces are replayable (payload version 2): the tracker records every frame the counter saw, with unusable frames and resets as markers, and the reps it emitted. A replay reproduces the live count exactly.
- `mix burpee_trainer.export_pose_corpus OUT_DIR [--database copy.db]` exports recorded sessions; `node assets/js/tools/pose_corpus_report.mjs` replays them against logged counts and the schedule; `node assets/js/tools/fit_burpee_hsmm.mjs` refits the model from them. See `docs/guides/pose-corpus.md`.
- `/tracking-test` runs the session counter (it ran an older, separate one); the old decoder modules are deleted.
- Pose uploads show a progress bar and "N of M parts" while they run, and send up to 4 MB of JSON per request (was 512 KB), so a 20-minute session goes up in a handful of requests instead of about 45.

## 2026-10-26 — The debrief shapes the next pick

- "Avoid" and "choose again" now belong to the workout they were said about (`Coach.WorkoutPreference`): the latest answer for a workout counts, a later session without an answer changes nothing, and an answer lapses after four weeks. A workout you asked to avoid is no longer offered to the decision model and the planner's `select_workout` refuses it; picking it yourself is unchanged. A "choose again" workout is marked to the decision model as one you want to repeat.
- A recent limiter (legs, upper body, breathing, whole body) is part of the progression guidance the planner and decision model share: arrange sets to spare it, with shorter sets and fuller recovery inside the same reps and duration.

## 2026-10-26 — One action row for New, Edit and Swap

- New, Edit, review and Swap share one action row under their content: Cancel (X) at the left, confirm at the right, and the extras (Edit, Save to library) as icons beside confirm. Cancel no longer sits inside the text box. Swap shows the previewed workout as the Home title, and the chooser's close is at the left.
- The Time today (20/40 min) row is removed from Home, with `Coach.DurationChoice` and its `choose_duration` event.
- A dismissed pose-upload notice stays dismissed across app opens (kept in `localStorage`), instead of returning on every load.
- Development only: `/dev/login` signs in a local `dev` user without Pocket ID, routed only when `dev_routes` is on.

## 2026-10-21 — A goal is reps in 20 minutes

- Setting a goal takes only the reps and the burpee type (and a date): every goal is one 20-minute session, the length levels are counted in. The coach's `propose_goal` and Claude's `set_goal` no longer take a duration. A migration makes open goals (active and proposed) 20-minute goals with the same reps; achieved and abandoned goals keep the duration they had.
- Only a 20-minute session counts toward a goal, as for levels (20 minutes, give or take ten seconds): its starting point, its progress on Progress and in the coach's summary, and reaching it. A longer session no longer sets the starting point, and a shorter one no longer fills the gauge without reaching the goal.

## 2026-10-20 — Planning follows events

- Opening the app never plans. The next workout is planned when something happens: a completed or logged session (at the next local day), Retry, or a choice by you or Claude. A day without training keeps the workout chosen before it while it still fits the day (same burpee type and minutes), so Home no longer falls back to Steady 10 and spends a decision call and a model call on a new day.

## 2026-10-20 — Pose traces stored gzipped

- Camera pose traces are stored gzipped (`Workouts.GzipText`): a 20-minute session took about 120 MB as plain JSON, about 18 MB now. A migration compresses existing traces one chunk at a time; on a copy of production data the database went from 317 MB to 54 MB after `VACUUM`, with every chunk's digest unchanged. Run `VACUUM` once after deploying to give the space back.
- Two real 20-minute camera sessions are test fixtures: replayed through the rep detector (HSMM), a steady one counts exactly 140 reps and one that slipped with a long pause exactly 135. Their features are also rebuilt from the recorded keypoints, so feature extraction is tested on about 23,000 real frames. Six HSMM tests that only pinned tuning constants or replayed a synthetic happy path, and one synthetic world-geometry test, are removed.

## 2026-10-19 — The planner picks before it designs

- The next workout is planned by a decision model first (`typesafe/jev-1.14` on OpenRouter's Decisions API): it picks one of the saved or built-in workouts that fit the slot's burpee type, minutes and level band, or answers that none suits today. A pick at confidence 0.6 or more is selected with a template rationale, and a sure `create_new` has the coach design one with `propose_workout` only. Without a decision model, when the call fails, or when it is unsure, the full planner runs as before. The planner never replaces a workout you or Claude chose for the day, including one chosen while the decision is out. `DECISIONS_MODEL`, `DECISIONS_URL` and `DECISIONS_ENABLED` configure it.
- Automated LLM calls (planning, summary, memory, insight) and the ones you start have separate rolling-24-hour budgets, 25 and 40, so many chats no longer use up the overnight planner's calls. A $0.25 daily cost cap spans both.
- Your recent best decides how hard the planner may go: at most 10% above your best 20-minute pace for the type in the last eight weeks, whatever your level; the next level caps it only when you have no recent session of that type. One rule (`Coach.RepCeiling`) holds for the workouts the coach designs and the saved ones it may pick.
- `CatchUpPolicy.prescription/3`, the old catch-up rep ceiling nothing used since the coach-first cull, is removed.
- Requests to OpenRouter name the app (`https://PHX_HOST`, "BurpeeTrainer", hidden from public listings), so its logs no longer show them as an unknown app.
- Fixes a planner run that chose nothing: it finished as a success, so Home kept the default workout and the slot was never planned again. The planner is now reminded once, then the job is cancelled so it cannot spend the automated budget on retries; Home keeps its fallback.

## 2026-10-19 — Warnings fail the build; unused code removed

- Every compile of the app fails on a warning (`elixirc_options: [warnings_as_errors: true]`), not only precommit and CI, and `mix test --warnings-as-errors` covers the test files.
- Removed public functions nothing called, found by tracing every call at compile time:
  - the Phoenix generator's unused components (`button`, `header`, `table`, `list`, `qs_surface`, `translate_errors`) and History's `kpi`, with its CSS;
  - weekly minutes (`Workouts.weekly_minutes/1`, `Stats.Series.weekly_minutes/1`);
  - `Accounts.list_users_page`, `Exchange.latest/1`, `ProgramHash.encode!/1` and `Program.events/1`;
  - `CreationParameters`' unused schema, changeset and request text;
  - the schemas' enum accessors, `Milestones.comeback_days/0` and `PlanCompiler.schema_version/0`.

## 2026-10-18 — The composer

- Every box you write words in is one soft card holding the text and its actions: Edit's instruction, the coach's message, New's "Anything else" and a finished session's note (plan and video). Send is a small arrow-up square, grey until there is text; Cancel sits at the card's bottom left.
- Edit offers three common changes under the card (Split into sets, Longer rests, Make it shorter); one tap sends it, like the coach's predicted replies, which now sit under its card too.
- New's "Anything else" holds its Cancel and Review like Edit's card, instead of a row under it.
- `docs/ui.md` 4a1 describes the composer.

## 2026-10-18 — Exact rests

- A layout gives each gap between sets `{"sec": n}`, exactly n seconds after the last rep's beat (0 runs the next set on the next beat), or `{"share": w}`, a share of the time left after the sets, cadence tails and exact rests. `rest_weights` are gone, for Claude and for the app's own coach.
- Fixes an unchanged MCP edit changing a workout's rests: `editable` now gives the stored rests exactly (20 s and 60 s used to come back as 16.5 s and 63.5 s).
- A phase with a gap ends exactly at its anchor; only a single-set phase keeps ±10 s.
- Fitter errors name the phase, its anchor (a timed rest, or `target_duration_sec`), what its time is made of, by how much it is off and what to change; a single set short of the end explains that the tail after the last rep is not counted.
- The MCP summary lists every rest; `burpee://workout-format` has a Timing section with a tested worked example.
- Spec: `docs/specs/2026-10-18-exact-rests-design.md`.

## 2026-10-18 — Latest packages

- Hex: every dependency at its latest, including Phoenix 1.8.15, LiveView 1.2, Ecto SQL 3.14, ecto_sqlite3 0.25, LiveDashboard 0.9, Req 0.7, Bandit 1.13, Oban 2.24.2, tzdata 1.2, Reach 2.8; `mix.exs` requirements raised where the old ones held them back.
- Binaries: esbuild 0.28.2, Tailwind 4.3.3. npm: @mediapipe/tasks-vision 1.1.1 (same wasm files, copied by `prepare_pose_assets.sh`), date-fns 4.4, @fontsource/geist 5.3, prettier 3.9.
- LiveView 1.2's formatter writes empty elements as `></tag>`; four templates reformatted, nothing else changed in the app.

## 2026-10-18 — Finish early or abort; the video page in the session's style

- Paused, a workout offers Finish early or Abort; the back arrow is gone. Abort asks in place ("Abort this workout? Nothing will be saved.", Keep / Abort) and deletes the started session; resuming closes the question, and a refused abort stays paused and says so.
- The video page has no app navigation and no breadcrumb: the video, then Finish early or Abort. Finish early or the video's end opens the plan workout's finish screen: the count with − and + (typed too, since a video often has none), mood, tags and a note, trash or ✓. The time logged is how far the video got.
- The video log's duration field and its feedback block (energy, heat, limiter, preference) are gone, as on the plan finish screen.

## 2026-10-17 — Claude signs in through a Pocket ID API

- `/mcp` is a Pocket ID API (resource `https://<host>/mcp`) that Claude registers with through CIMD, like Fund; Claude no longer needs a client of its own. `MCP_OIDC_AUDIENCE` is that resource.
- A token that also carries the issuer as an audience, which Pocket ID adds when Claude asks for `openid`, is accepted; any other extra audience is still refused. Before, every such token was refused.
- `docs/guides/mcp-setup.md` describes the API setup.

## 2026-10-17 — Agent tooling and a quality gate

- `usage_rules` (dev only, pinned) writes AGENTS.md's dependency rules from an allowlist in `mix.exs`: its own rules with Elixir and OTP, and Phoenix's elixir, phoenix, ecto, html and liveview rules. Never `:all`, no package skills. AGENTS.md says those rules are reference material that the project's own guidance outranks.
- VibeKit adds `mix ci`: warnings as errors, format check, tests, `credo --strict` with ExSlop, Dialyzer, ExDNA with no clones, and Reach. Credo and Dialyzer start from a baseline of what already failed (`.credo.exs`, `.dialyzer_ignore.exs`, by file), so new code is checked in full; Dialyzer's PLT includes `:mix`.
- ExDNA's two clones are extracted: `PlanCompiler.CanonicalJson` and `BurpeeTrainerWeb.Params`.
- Dialyzer's 134 warnings had one main root: `UserTime.context/2` (and `HomeDayBoundary.delay_ms/2`) typed their argument as a map with only `:timezone`, which no `%User{}` is, so everything downstream looked unreachable. Fixing those specs cleared 120 warnings, including every "never called" one. The rest were real unreachable branches, now deleted: string-key and `version` fallbacks in workout drafts, a `:boundary` interval comparison never asked for, a `:chunk_conflict` upload reply never returned, impossible `with`/`case` fallbacks in the coach, `|| ""` on regex groups that are never nil. Two wrong types were fixed (`Mcp.handle/3` takes a nil scope; `WorkoutRequest` never aliased `WorkoutDefinition`). The baseline is down to two library false positives.
- Database tests run one at a time; the six that ran async against SQLite failed at random with "Database busy", and the sandbox now refuses an async database test.

## 2026-10-16 — Starting and finishing a workout with one tap

- Home has camera and warmup toggles beside play, remembered per device (default: camera off, warmup on); play is the only tap before the workout.
- The session no longer asks about the camera, the warmup, or being ready: it opens the 5-second countdown, or one camera screen ("Starting camera", "Step into frame", "Hand up or hold still", "Camera unavailable"); the warmup runs straight into the workout's countdown. A session left on its finish screen still reopens there.
- On a device without a camera the camera toggle is off and disabled ("No camera on this device"), and a remembered camera choice starts the workout without it.
- Pausing offers ← Back to Home under Finish early (the session stays resumable), and the finish screen can discard an unsaved session after an on-page confirmation; the server deletes only a started session and the device's draft and trace go with it.
- Finish early works on any pause (warmup and countdowns too) without a browser confirm, so a session can always reach discard; the camera and warmup toggles also flank Resume.
- The finish screen says "Ended early" after Finish early (from any pause, including mid-workout), starts with no mood chosen (a save without one stores none; tapping the chosen mood clears it), sits centred, and shows the trash as an outlined button.
- The pose tracker holds a start sent while its code loads, so the camera cannot stall on "Starting camera".
- The finish screen is save or discard: it shows the counted reps and time with no fields, with mood, tags and a note under it in Home's pill and field styles, and no leave-and-resume-later.
- The count is corrected with − and + beside it (hold to keep counting; − stops at zero); the time is the timer's and no longer editable. A line under it says "Counted by camera" or "From your plan", and after a correction shows the original with Undo. The device draft keeps where the count came from.
- Discard's question takes the place of the trash and ✓, with equal Keep and Discard buttons; Keep brings them back.
- Finishing early from the warmup or the workout countdown with the camera on can be saved: a camera that never settled finishes as lost tracking (it was sent as "arming"/"observing", which the server refuses), and a draft holding one opens the same way.
- − / + say the new count to a screen reader, end a hold when slid off or disabled, and hand focus to + when − or Undo goes away; the finish screen's own announcement no longer repeats on every edit. Older drafts that hold the camera's unchanged count say "Counted by camera".
- Discard locks the finish screen while the server answers and gives up after 10 seconds.

## 2026-10-04 — Coach/Home branch review fixes

- Migration `20260829085005_rebuild_workout_library` now accepts the upstream-OIDC source/target schema fingerprints, so databases deployed from upstream (OIDC already applied) can migrate; the gate stays exact-match and fails closed for any other shape.
- Coach prompt context keeps only the 12 most recent finalized-workout memories, so authoring no longer fails permanently with `authoring_context_too_large` as a user's library grows.
- Approving a reviewed workout saves it as a new **published** workout (still provider-free, idempotent, and not selected); dismissing the saved notice no longer leaves it as an unreachable draft.
- A completion retry after a lost save reply is acknowledged when it carries the session's own `client_session_id`; reopening an already-saved session settles retained local evidence (draft → trace upload queue) and returns Home instead of "Session not found".
- Coach background tasks are no longer capped at two globally, so guidance reviews and workout memories are not silently dropped under load.
- Saving guidance with unchanged text keeps its classification and spends no provider review.
- Workout memories for approved reviews now include the user's instruction.

## 2026-08-31 — Deletion-first workout library and immutable sessions

- Rebuilt `workout_plans` as the canonical durable library with enforced `draft → published → archived` lifecycle semantics, immutable published content, copy-to-draft, and no manual block/set editor.
- Added bounded one-request natural-language Create and Refine through `Req`; validated output persists as a draft only, invalid output persists nothing, and publishing always requires explicit acceptance.
- Replaced lifecycle/outbox/authorization machinery with small recommendation pointers, a supervised transient reconciler, deterministic fallback/policy, and atomic candidate Use/Current-workout-better decisions.
- Made `workout_sessions` the sole execution authority: Start creates the exact `started` row with immutable plan or video snapshots, Resume stays pinned, and completion updates the same row once.
- Moved History and Stats to completed-session snapshots so plan archival and later catalog changes cannot rewrite completed workouts; retained confirmed feedback, pose evidence, video facts, and nil-count video semantics.
- Added an atomic destructive migration with verified-backup restoration rehearsal, normalized disposable `/tmp` E2E fixtures, authenticated Firefox runbook, and deletion/reference/LOC gates.
- Removed obsolete configured-workout, structured-editor, persisted execution-program, preparation, provider-delivery, execution-permission, and compatibility architecture while preserving all historical migrations.

## 2026-06-08 — Deterministic intelligence layer

- Removed the MILP/HiGHS infrastructure and old `PlanSolver.Lp`; `PlanSolver` now uses deterministic candidate/rest placement with rich solution metadata, PaceModel-backed pace bounds, manual pace overrides, and human-shaped non-uniform set patterns.
- Removed the old Thompson-sampling coach modules and Home coach cards now use `CoachTargetPlanner` with active type-specific performance goals.
- Added `WeeklyTrainingContract`, `PerformanceModel`, `TrainingState`, `PaceModel`, `CoachTargetPlanner`, and type-locked `CatchUpPlanner`.
- Catch-up planning now creates one long selected-type session only, with duration intensity factors: 20 min 100%, 30 min 85%, 40 min 75%, 60 min 60%, 80+ min 50%.
- Home coach and catch-up actions create real workout plans and navigate to the plan editor.
- Added generated plan metadata (`coach_suggestion_kind`, `coach_target_reps`, `plan_solver_metadata`) and a compact “Why this?” section on plan edit.

## 2026-05-21 — PlanSolver: joint MILP with solver-chosen pace

- Replaced `BurpeeTrainer.PlanWizard` with `BurpeeTrainer.PlanSolver`.
- `sec_per_burpee` is no longer a user input. The solver finds the optimal pace bounded below by `PlanSolver.sustainable_ceiling/1` (level-derived: level_1a=8.0s down to graduated=3.70s).
- Extended LP formulation: `p` (pace) is a free variable in the same problem as rest distribution, finding the true joint optimum rather than two sequential optima.
- New shared LP infrastructure: `BurpeeTrainer.Milp.{Problem, Mps, Highs}` — reusable for future ScheduleSolver.
- UI: Layer 1 shows level + min pace hint instead of sec/burpee input. Layer 3 shows solver-chosen pace, set structure, and rest as a read-only summary.
- Deleted: `BurpeeTrainer.PlanWizard` and all sub-modules.

## 2026-05-11 — MILP plan wizard

- Replaced the bespoke constraint-solver pipeline (`Reservation`, `Constraints/*`) with a MILP model serialized to MPS and solved by HiGHS.
- New modules: `PlanWizard.Lp`, `PlanWizard.Lp.Problem`, `PlanWizard.Mps`, `PlanWizard.Highs`.
- Added `fatigue_factor` field to `WorkoutPlan` and `PlanInput`. Biases rest distribution toward later slots in the workout via a linear weight ramp applied to the soft objective. Three-stop control (None / Mild / Strong) in the plan edit form. Default `0.0` preserves existing behavior.
- HiGHS CLI is now a runtime dependency; see README for build/install instructions.
- Deleted: `Reservation`, `Constraints.MinimizePlacementError`, `Constraints.MinimizeRestDeviation`, `Constraints.RestNonNegative`, `Constraints.TotalDuration`, `Constraints.ValidPlacement`. `Constraints.PaceFloor` retained as the pre-LP feasibility gate.

## 2026-05-09 — Constraint-solver refactor (FEAT_CONTRAINED_SOLVER)

Replaced the procedural `:even` / `:unbroken` branching in
`BurpeeTrainer.PlanWizard` with a unified **variables → constraints → solvers**
pipeline. Both pacing styles now flow through the same code path; their only
difference is the slot-weight vector supplied as data by `Styles.weight_vector/3`.

### New modules

- `PlanWizard.PlanInput` — extracted struct.
- `PlanWizard.SlotModel` — universal representation: `total_reps − 1`
  inter-rep slots, weight vector, reservations, distributed `slot_rests`.
- `PlanWizard.Styles` — `weight_vector(style, total_reps, reps_per_set)`.
  `:even` → all 1.0; `:unbroken` → 1.0 only at `k × reps_per_set`.
- `PlanWizard.Reservation` — places `additional_rests` at the nearest slot
  (±30s tolerance). `:even` uses `prev_slot + 1` bumping; `:unbroken` uses
  independent nearest-boundary placement.
- `PlanWizard.Solver` — pipeline: `PaceFloor.check_input` → `build_slot_model`
  → `Reservation.place` → closed-form `distribute_remaining_budget` →
  `RestNonNegative` → `TotalDuration` → `ValidPlacement`.
- `PlanWizard.Apply` — collapses a solved `%SlotModel{}` into `%WorkoutPlan{}`
  with `%Block{}` / `%Set{}`. Reads structural fields from the model; per-set
  numerics use the legacy closed-form formulas to keep regression tolerances
  tight (`sec_per_rep` to ±1 ms, total duration to ±0.1s).
- `PlanWizard.Errors` — centralised error strings, preserving legacy wording.
- `PlanWizard.Constraints.{PaceFloor,RestNonNegative,TotalDuration,ValidPlacement}`
  — hard constraints, each `check/1 :: :ok | {:error, [msg]}`.
- `PlanWizard.Constraints.{MinimizePlacementError,MinimizeRestDeviation}` —
  soft penalties, computed and stored on the model (not yet wired into solver
  decisions).

### Rewritten

- `PlanWizard` (392 → 134 lines): thin wrapper that resolves
  `reps_per_set` defaults, validates positivity, short-circuits the degenerate
  one-set `:unbroken` case (where `reps_per_set ≥ total_reps`), and otherwise
  delegates to `Solver.solve/2` then `Apply.to_workout_plan/2`. Public
  helpers `validate_pace/2` and `default_reps_per_set/1` preserved.

### Deleted

Legacy private helpers in `plan_wizard.ex`: `build_even`,
`build_even_with_rests`, `build_unbroken`, `build_unbroken_sets`,
`find_even_splits`, `build_even_segments`, `inject_unbroken_rests`,
`build_set_boundaries`, `find_all_boundary_injections`,
`find_nearest_boundary`, `apply_injections`, `wrap_plan`, `encode_rests`.

### Test results

- `test/burpee_trainer/plan_wizard_test.exs` — **26/26 unmodified**
  (regression contract).
- New tests: `styles_test.exs`, `reservation_test.exs`, `solver_test.exs`,
  `apply_test.exs` — all green.
- Combined PlanWizard + Planner: **114/114**.
- `mix compile --warnings-as-errors`, `mix format`, `mix deps.unlock --unused`
  all clean.

### Deferred (per plan)

DP conflict solver, replacing `Planner.fit_rest_to_duration/2`, StreamData
property tests, new pacing styles (`:pyramid`, `:tabata`), soft-constraint
penalty wiring into solver decisions, fatigue model.

---

## UI Polish — Stats, Workouts, Plan Editor (2026-05-21)

### Stats screen

- Removed "How you're tracking." subtitle; level badge moved into streak card header
- Goal cards: state leads (number/achieved), type label demoted to tertiary
- "Goal reached" card: trophy icon, achieved target shown as `N burpees`, completion date
- "Trends" section header added; "Sessions" floating header removed
- Weekly minutes chart: fixed viewBox (always 300px wide), 12 slots always rendered, sparse data fills from right, 120 label removed, "80" label on LHS beside dashed target line
- Progress chart: gridline y-axis labels removed for target values; target numbers anchored to right end of dashed lines, color-matched to series
- `Fmt.burpee_type/1`: "6-count" → "6-Count" for consistent casing with "Navy SEAL"

### Workouts screen

- "Pick something to do." subtitle removed
- Level filter pill labels: "1A/1B/1C/1D" → "L1A/L1B/L1C/L1D" for consistency with "L2/L3/L4"

### Plan editor (`/workouts/new`, `/workouts/:id/edit`)

- Single input card with `divide-y` hairlines replacing three separate cards (Basics, Additional rests, Advanced)
- Plan name is the page title — inline editable input, updates on change
- Fatigue bias moved behind `▸ Advanced` disclosure (collapsed by default)
- Additional rests: compact inline row, trash icon instead of "× remove"
- Solution card wraps blocks + save button; solution header shows `✓ Solution · 20:01 · 150 burpees`
- Block actions (Duplicate, Remove) moved to `⋯` overflow menu
- Set rows: dense single-line format with `Reps | Rest [s]` column headers; `sec/rep` and `sec/burpee` hidden (submitted as hidden inputs, defaulting to plan-level pace for new sets)
- Uniform sets collapsed to summary line ("10 × 15 reps · 29s rest") with "Edit sets" affordance
- Footer row shows live `duration · burpees` status beside Save button
- Stale solver error cleared on manual block edits
- Picker pattern unified: Burpee type, Pacing, Fatigue bias all use same pill-strip component
- Cancel demoted to plain text link
- Section numbers dropped from headers
- Native number input spinners hidden globally via CSS

### Tests

- 261 tests, 0 failures throughout
