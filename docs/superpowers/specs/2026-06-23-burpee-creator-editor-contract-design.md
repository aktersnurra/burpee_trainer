# Burpee Trainer Creator/Editor Contract Design

Date: 2026-06-23  
Workspace: `/Users/aktersnurra/projects/vibe/burpee_trainer.workspaces/ui-ux-refactor`  
Scope approved: creator/editor first; Home/overview is deferred to a later pass.

## Goal

Refactor the workout creator/editor so it feels like a training contract editor, not a solver/debug panel. The user should understand the workout before they edit the mechanics.

The default UI must answer:

- What workout am I about to do?
- How hard should it feel?
- Can I trust the generated structure?
- What can I safely override?

The default UI must not expose implementation details such as raw solver variables, schema-first block/set fields, reps/sec pace, set indexes, MILP state, or debug constraints.

## Product principle

The editor must make the workout understandable before it makes it editable.

This creates three UI levels:

1. **Read mode** — readable workout contract and block score.
2. **Edit mode** — focused controls for the selected block or advanced constraints.
3. **Debug mode** — hidden developer-only solver details, not part of normal creator/editor flow.

## Existing context

The current `/workouts/new` and `/workouts/:id/edit` LiveView already has useful solver behavior and tests, but the UI shape is too mechanism-forward:

- `render.html.heex` renders peer surfaces for Type, Target, Style, metadata, and prescription.
- `plan_solution_card_template.html.heex` exposes block pattern editing, prescription stats, recommendations, rest placement, graph inspector, and save controls in one surface.
- `blocks_editor_template.html.heex` contains a read/manual split, but manual mode still exposes schema-shaped set rows with fields such as Reps, Pace, Rest, repeat count, and set-level actions.
- `assets/css/app.css` already uses Tailwind v4 imports and session CSS variables. Keep the current color system for this pass.

The refactor should preserve the working solver/editor model and the current color palette while changing the user-facing hierarchy, copy, disclosure, and default controls.

## Aesthetic guidelines

**Tone:** brutally edited operational minimalism. The screen should feel calm, deliberate, and training-oriented, not SaaS-dashboard decorative.

**Color:** defer palette changes. Keep the current app colors for this pass; only avoid adding new competing accent colors or decorative icon color. Reserve existing semantic colors for selected state, locked/manual state, invalid/conflict state, destructive actions, current live block, and completion.

**Typography:** tight tool typography. Use large type only for hero state, generated workout summary, and live/session screens. Block rows should be readable but not loud.

**Motion:** subtle micro-interactions only. Mobile pressed/loading/disabled/invalid states matter more than hover.

**Spatial composition:** mobile-first single column. One dominant contract surface, then one readable structure list. Advanced controls are disclosed only after intent is clear.

**Backgrounds:** clean solids with fine borders and spacing. No decorative gradients, colorful icon clusters, or chart-heavy chrome.

**Differentiation:** the structure map. The workout should read like a compact training score: blocks, rhythm, rest, and progression.

## Information architecture

The creator/editor flow is:

1. Intent screen.
2. Generated workout review.
3. Workout editor overview.
4. Block edit sheet/panel.
5. Conflict or infeasible resolution state.

Home/overview redesign is intentionally deferred. This pass should not attempt to rebuild the app navigation or weekly dashboard.

## Creator screen

The initial creator surface must show only declarative intent:

- Burpee type: Six-count / Navy SEAL.
- Duration: 20 min / 30 min / Custom.
- Intent: Planned session / Catch up / Easy technique / Max reps.
- Difficulty: a simple slider or segmented control.

Primary action:

- Generate workout.

Advanced constraints are collapsed under **Advanced constraints**:

- Unbroken cap.
- Minimum rest.
- Maximum pace.
- Manual target reps.
- Solver strictness.

The initial creator screen must not show block/set tables or prescription graph mechanics.

## Generated workout review

After generation, show a contract summary before literal block data:

- Duration and burpee type.
- Total reps.
- Number of blocks.
- Structure summary.
- Expected feel.

Example copy:

```text
20 min Six-count
185 reps · 12 blocks
Mostly unbroken, rests increase gradually
Expected feel: controlled, not all-out
```

Primary action:

- Start workout.

Secondary action:

- Edit workout.

Below the summary, show the structure map and a compact grouped preview, for example:

```text
Structure
1–4   15 reps · short rest
5–8   15 reps · medium rest
9–12  16 reps · longer rest
```

## Structure map

Add a compact monochrome workout map. Each block is a small vertical mark.

- Height = reps or work density.
- Gap = rest after block.
- Optional shade = relative intensity.

The map is a preview, not an analytics chart. It should look like a small score for the workout, not a dashboard widget.

Implementation note: this can be rendered in HEEx with simple div marks and inline CSS custom properties derived from block summaries. No chart library is needed.

## Editor overview

The editor overview is a readable block list, not a spreadsheet.

Header content:

- Edit workout.
- `20 min · Six-count`.
- `185 reps · 12 blocks`.
- Structure map.
- One primary Start button.

Block row format:

```text
Block 4
Unbroken · 15 reps
Rep every 3.8s · 0:38 rest
```

If manually edited:

```text
Block 4
Unbroken · 15 reps
Rep every 3.8s · 0:38 rest
Locked by you
```

Actions:

- Add rest.
- Rebalance unlocked blocks.
- Advanced constraints.

The default editor must not display all controls. It should display readable rows; tapping or selecting a row reveals focused edit controls.

## Block editing

Tapping a block opens a focused edit panel. On mobile this should read as a bottom-sheet-like panel; in LiveView it can be implemented as an in-page sheet anchored after the block list if a true JS bottom sheet is unnecessary.

Fields:

- Reps stepper.
- Seconds per rep.
- Rest after.
- Lock this block.
- Duplicate block.
- Delete block.

User-facing copy:

- Use “Rep every 3.8s”.
- Use “Seconds per rep”.
- Use “Rest after”.
- Use “Locked by you”.

Avoid default display of:

- reps/sec.
- “cadence” as a technical term.
- solver variables.
- set indexes unless the user enters an advanced/debug detail mode.

## Manual edits and locking

Manual edits are first-class constraints. The UI should describe them as **Locked by you**.

When the user rebalances, only unlocked blocks may change. The button copy must be explicit:

- Rebalance unlocked blocks.

The app must not silently mutate locked/manual blocks.

## Conflict and infeasible states

If an edit breaks the target duration, show a visible conflict state instead of silently fixing everything.

Manual conflict copy:

```text
Workout no longer fits 20:00
You are 0:42 over.
```

Actions:

- Rebalance unlocked blocks.
- Keep 20:42.
- Undo change.

Infeasible copy:

```text
This cannot fit in 20:00
The locked blocks and rests exceed the duration.
```

Actions:

- Show locked blocks.
- Unlock all.
- Allow longer workout.
- Undo.

Existing `plan_feedback/3` and timeline error rendering can be reused, but copy and actions should match these product states.

## Visual implementation rules

Do not change the current color palette in this pass. Work inside the existing `--session-*` token system and avoid adding new decorative colors.

Only one heavy primary button should appear on a screen. Secondary actions should be ghost/outline/text. Destructive actions should use the existing muted destructive styling and never become the primary button.

All tappable elements need default, pressed, disabled, loading where relevant, and invalid where relevant states.

## Do not do

- Do not use a spreadsheet/table layout as the default editor.
- Do not show all block fields at once.
- Do not expose solver/debug data by default.
- Do not use emojis.
- Do not use colorful icons.
- Do not use multiple heavy primary buttons on one screen.
- Do not silently change locked/manual blocks.
- Do not show repeated empty states.
- Do not introduce a new color palette in this pass.

## Naming consistency

The creator, editor, and live/session surfaces should use the same nouns whenever this pass touches related copy:

- Workout.
- Block.
- Set.
- Rest.

Do not make the creator say “sets,” the editor say “blocks,” and the live screen say “rounds” for the same concept. Full live-screen redesign remains out of scope, but any creator/editor copy should align with this vocabulary.

## Deferred or compressed from original input

The original input also covered broader app/UI doctrine. This creator/editor-first spec intentionally leaves these items out of implementation scope for now:

- **Home screen redesign**: the “This week / 42 of 80 min / Next workout” operational home surface is deferred.
- **Live screen refactor**: matching the live workout screen to the editor vocabulary and structure is deferred except for copy consistency where touched.
- **Exact color palette replacement**: deferred; keep current colors.
- **Week-complete state**: the “80 / 80 min” completion copy belongs with the Home/overview pass.
- **No generated workout and generating states**: useful product states, but the existing LiveView currently generates immediately; add them only if the implementation introduces an explicit pre-generation or async generation step.
- **Developer details trigger**: the spec says solver/debug details are hidden, but the exact trigger (Developer details, long-press, or debug flag) can be decided if we expose that mode in this pass.
- **Exact typography scale**: the spec keeps the hierarchy rule but does not mandate the full pixel scale from the input because this pass should avoid broad visual-token churn.

## Implementation boundaries

This pass should touch creator/editor surfaces and supporting tests/styles only:

- `lib/burpee_trainer_web/live/plans_live/edit.ex`
- `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex` if the current manual editor remains part of the flow
- `assets/css/app.css`
- relevant LiveView tests under `test/burpee_trainer_web/live/`

Avoid broad home/overview, live-session, stats, video, database, or solver changes unless the creator/editor refactor needs a small helper.

## Testing strategy

Follow test-first implementation. Add or update LiveView tests before production edits.

Key tests:

1. `/workouts/new` renders an intent-first creator surface with burpee type, duration choices, intent choices, difficulty, Generate workout, and collapsed Advanced constraints.
2. The initial creator does not expose block pattern, prescription graph, Pace, set indexes, or solver/debug language by default.
3. Generated review shows contract summary, structure map, Start workout, and Edit workout.
4. Editor overview shows readable block rows with user-facing copy such as “Rep every …” and “rest”, not schema-first fields.
5. Block details are disclosed only after selecting/editing a block.
6. Conflict/infeasible states use product copy and actions.
7. Existing save behavior remains functional for generated plans.
8. Existing rest placement behavior remains functional, but is presented as structure editing rather than graph debugging.

Verification target:

- Run focused LiveView tests first.
- Run `mix format`.
- Run `mix precommit` before declaring completion.
