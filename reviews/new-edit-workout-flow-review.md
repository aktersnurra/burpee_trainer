# Review: New/Edit Workout Flow

## Verdict

High risk. The focused new/edit test slice passes, and the happy-path create/edit/start flows are represented, but the refactor exposes core editor actions that can silently lose locked/manual edits, create unscheduled duplicate blocks, and misapply block-sheet edits for multi-set blocks. I would not ship this UI until those data-preservation paths are fixed or disabled.

## Findings

### blocker — Locked/manual blocks can be silently overwritten by subsequent solver changes

**Evidence**

- `docs/superpowers/specs/2026-06-23-burpee-creator-editor-contract-design.md:212` — `The app must not silently mutate locked/manual blocks.`
- `lib/burpee_trainer/plan_editor.ex:143` — `form_plan: solution.plan,`
- `lib/burpee_trainer/plan_editor.ex:144` — `manual_edit?: false,`
- `lib/burpee_trainer/plan_editor.ex:153` — `@spec change_basics(State.t(), map()) :: {:ok, State.t()}`
- `lib/burpee_trainer/plan_editor.ex:159` — `|> regenerate()`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:707` — `def handle_event("change_basics", params, socket) do`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:713` — `|> regenerate()`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:719` — `def handle_event("pick_type", %{"type" => type}, socket) do`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:725` — `|> regenerate()`

**Impact**
A user can edit/lock a block, then change duration/reps/type/pacing/block pattern in Advanced constraints. The lock set remains, but the locked block content is replaced by fresh solver output. The UI can still show “Locked by you” for a regenerated block, which is worse than losing the label because it falsely tells the user their manual constraint was preserved.

**Smallest safe fix**
Route every solver regeneration after manual edits through a locked-block-preserving path, not only `rebalance_unlocked_blocks/1`. Reuse `locked_blocks_by_index/2` + `restore_locked_blocks/2` for `change_basics`, `pick_type`, `pick_pacing`, `change_block_pattern`, pace/rest changes, or disable those controls until the user explicitly unlocks. Add a LiveView test: edit/lock block -> change duration/reps -> assert locked block values still match.

### blocker — The exposed Duplicate block action creates blocks that are unscheduled and may reuse persisted IDs

**Evidence**

- `docs/superpowers/specs/2026-06-23-burpee-creator-editor-contract-design.md:187` — `- Duplicate block.`
- `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex:75` — `<button`
- `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex:77` — `phx-click="copy_block"`
- `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex:81` — `Duplicate`
- `lib/burpee_trainer/plan_editor.ex:265` — `copied_block = %{source_block | position: length(blocks) + 1}`
- `lib/burpee_trainer/plan_editor.ex:266` — `form_plan = %{state.form_plan | blocks: blocks ++ [copied_block]}`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:53` — `steps`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:55` — `|> Enum.flat_map(fn`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:56` — `%{kind: :block_run, block_position: block_position, repeat_count: repeat_count} ->`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:62` — `_step ->`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:63` — `[]`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:256` — `set_attrs = if set.id, do: Map.put(set_attrs, "id", set.id), else: set_attrs`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:261` — `block_attrs = if block.id, do: Map.put(block_attrs, "id", block.id), else: block_attrs`

**Impact**
Generated and many persisted plans have `steps`. `copy_block/2` appends a new block but does not add a `PlanStep`, while the default presentation for stepped plans renders only `:block_run` steps. The duplicate can therefore be invisible and unrunnable. For existing persisted plans, the copied struct also keeps the original block/set IDs, and `blocks_to_attrs/1` writes those IDs back into both copies, risking duplicate nested-association IDs on save.

**Smallest safe fix**
Disable the Duplicate button until it is implemented safely, or make `copy_block/2` clear block/set IDs and insert/reposition a matching `PlanStep` at the selected execution location. Add tests for duplicate -> visible row count increases -> save/reload -> session outline includes the duplicate and IDs are distinct.

### important — The block sheet writes a displayed block total into only the first set

**Evidence**

- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:140` — `defp block_reps(%Block{sets: sets}) when is_list(sets) do`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:141` — `sets |> Enum.map(&(&1.burpee_count || 0)) |> Enum.sum()`
- `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex:36` — `name="block[reps]"`
- `lib/burpee_trainer_web/live/plans_live/edit/block_sheet_template.html.heex:37` — `value={row.reps}`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:683` — `set_params = %{`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:684` — `"burpee_count" => Map.get(block_params, "reps"),`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:689` — `blocks = update_timeline_set(form_plan.blocks, source_block_index, 0, set_params)`

**Impact**
For a multi-set block, the sheet displays total block reps but saves the entered number into set index `0` only. Example: a block with sets `[4, 3]` displays `7` reps; entering `17` produces `[17, 3]` (20 total), not 17. The same mismatch applies to “Rest after” because the displayed rest is from the last set while the handler updates the first set.

**Smallest safe fix**
Either make the focused sheet explicitly edit a single-set block only, or implement true block-level editing: distribute/replace all sets consistently, or normalize the selected block into one set with the requested total. Add a regression test using a block pattern with at least two sets.

### important — Intent, difficulty, and Catch up are visible controls but have no solver effect

**Evidence**

- `lib/burpee_trainer_web/live/plans_live/edit/creator_intent_template.html.heex:62` — `<%= for {label, value} <- [{"Planned workout", "planned_session"}, {"Catch up", "catch_up"}, {"Easy technique", "easy_technique"}, {"Max reps", "max_reps"}] do %>`
- `lib/burpee_trainer_web/live/plans_live/edit/creator_intent_template.html.heex:83` — `<form id="creator-difficulty-form" phx-change="set_creator_difficulty" class="space-y-3">`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:623` — `{:noreply, assign(socket, :creator_intent, intent)}`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:633` — `{:noreply, assign(socket, :creator_difficulty, difficulty)}`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:636` — `def handle_event("generate_workout", _params, socket) do`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:637` — `{:noreply, assign(socket, :creator_phase, :review)}`
- `lib/burpee_trainer/plan_editor.ex:123` — `solver_input = %SolverInput{`
- `lib/burpee_trainer/plan_editor.ex:133` — `block_pattern: state.input.block_pattern`

**Impact**
The creator asks “What are we doing?” and offers Catch up / Easy technique / Max reps / Difficulty, but generating the workout uses the same `PlanEditor` input regardless of those choices. This makes the primary creator flow misleading, especially because the project already has catch-up planning paths elsewhere.

**Smallest safe fix**
Either wire these choices into solver input/metadata (for example map difficulty to target/pace and catch-up to the existing catch-up planner) or hide/disable non-functional options with explicit “coming later” copy. Add tests that selecting each supported intent changes the generated contract or metadata.

### important — Invalid creator and persistence validation states can leave users with no visible error

**Evidence**

- `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex:13` — `<.creator_intent_template`
- `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex:19` — `derived={@derived}`
- `lib/burpee_trainer_web/live/plans_live/edit/creator_intent_template.html.heex:148` — `disabled={not (@derived && @derived.both_ok)}`
- `lib/burpee_trainer/plan_editor/input.ex:94` — `| name: Map.get(params, "name", input.name),`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1203` — `{:error, changeset} ->`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1206` — `|> assign(:form, to_form(changeset))`
- `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex:295` — `<.form`
- `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex:301` — `class="hidden"`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1426` — `<input`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1428` — `name="name"`

**Impact**
On the initial creator screen, an impossible advanced target disables Generate but the template receives only `derived`, not `solver_error` or feedback copy. Separately, blanking the name is accepted into `PlanEditor.Input`; create/save/start can then fail in `Workouts.changeset/2`, but the only form with changeset errors is hidden, and the visible name input is not tied to the changeset. Users can be stuck with no actionable error.

**Smallest safe fix**
Pass/render solver feedback in the creator template whenever Generate is disabled by constraints. Normalize blank names back to a safe default or render name validation errors next to the visible header input; do not rely on hidden form errors. Add tests for impossible targets before generation and blank-name save/start failures.

### important — Explicit rest steps and “Add rest” are not represented in the default editor overview

**Evidence**

- `docs/superpowers/specs/2026-06-23-burpee-creator-editor-contract-design.md:169` — `Actions:`
- `docs/superpowers/specs/2026-06-23-burpee-creator-editor-contract-design.md:171` — `- Add rest.`
- `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex:93` — `<div class="flex items-center justify-between gap-3">`
- `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex:96` — `id="rebalance-unlocked-blocks"`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:56` — `%{kind: :block_run, block_position: block_position, repeat_count: repeat_count} ->`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:62` — `_step ->`
- `lib/burpee_trainer_web/live/plans_live/edit/presentation.ex:63` — `[]`

**Impact**
Plans with explicit `PlanStep` rests open into a default overview that renders only block rows. Rest rows are dropped from the structure list, and there is no default Add rest action despite the intended editor actions. The user can only discover rest mechanics in Advanced constraints, so the contract view can omit material parts of the workout.

**Smallest safe fix**
Represent rest steps in `Presentation.block_rows/2`/a separate structure row list and add a visible Add rest affordance, or clearly label rest editing as Advanced and show rest markers in the structure map. Add open/save/reload tests for plans with explicit rest steps.

### minor — Remediation actions are presented as actions but are disabled

**Evidence**

- `lib/burpee_trainer_web/live/plans_live/edit.ex:1387` — `actions: ["Show locked blocks", "Unlock all", "Allow longer workout", "Undo"]`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1405` — `"Rebalance unlocked blocks",`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1406` — `"Keep #{Fmt.duration_sec(round(derived.duration_sec))}",`
- `lib/burpee_trainer_web/live/plans_live/edit.ex:1407` — `"Undo change"`
- `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex:63` — `<button`
- `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex:66` — `disabled`
- `lib/burpee_trainer_web/live/plans_live/edit/workout_editor_overview_template.html.heex:68` — `title="Not available in this editor yet"`

**Impact**
The conflict card looks actionable but most remedies cannot be clicked. That increases confusion in exactly the impossible-state path where users need clear recovery.

**Smallest safe fix**
Implement at least Undo and Allow longer / Keep duration, or render unavailable remedies as explanatory text rather than disabled buttons.

## Test/verification run

- `jj diff --from master --to ui-ux-refactor --stat` — inspected; reported 16 files changed, 3934 insertions, 520 deletions.
- `jj diff --from master --to ui-ux-refactor --git` — inspected full changed-file diff output from jj (shell output was truncated by tool, but VCS command was jj as requested).
- `mix test test/burpee_trainer/plan_editor_test.exs test/burpee_trainer_web/live/plans_live/edit/presentation_test.exs test/burpee_trainer_web/live/workouts_live_test.exs` — passed: 96 tests, 0 failures, 33.4s.

## Open questions / deferred UX polish

- Should the visible name field stay above the intent screen, or move under Advanced constraints as suggested in the implementation plan?
- Are Catch up / Easy technique / Max reps meant to affect solver output in this pass, or should only Planned workout be selectable for now?
- High-risk tests to add: locked edit survives target/type/pacing changes; multi-set block sheet save/reload; Duplicate block save/reload/session execution; initial creator impossible target feedback; blank-name save/start validation; explicit rest step display in default overview; intent/difficulty changes influencing generated output.
