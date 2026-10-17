# Changelog

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
