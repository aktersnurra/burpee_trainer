# Workout Editor UI Restyle Design

## Goal

Restyle `/workouts/new` and `/workouts/:id/edit` so the current three-layer workout editor visually matches the new Session, Workouts, Home, and Stats warm-paper interface.

## Decision

Preserve the current implementation flow. The existing editor interaction model is preferred:

1. name/type basics
2. target and pacing controls
3. additional rests
4. generated/editable block prescription
5. derived duration/reps validation and save

Use `mock/_workouts_new _ 3-layer.html` as loose visual direction only. Do not restructure the current flow to match the mock exactly.

## Visual Direction

- Use `.session-surface` and `--session-*` tokens.
- Use Geist only.
- Use warm-paper background, black ink, muted tan labels, and square bordered controls.
- Active segmented choices should invert ink/background, matching the Workouts filters/nav language.
- Progress bars should be square, not rounded.
- Avoid dark-dashboard classes (`bg-base-300`, `base-content/40`, `primary`) on the editor surface except where existing shared form components require them internally.
- Avoid decorative shadows/gradients.

## Scope

In scope:

- `lib/burpee_trainer_web/live/plans_live/edit.ex`
- `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
- focused tests for `/workouts/new` shell/selectors and existing behavior

Out of scope:

- No changes to solver logic.
- No changes to editor state transitions.
- No changes to generated block calculations.
- No new fields or validation rules.
- No restructuring of the current editor flow.

## Behavior Preservation

Keep all current events, inputs, IDs, names, forms, and routes intact:

- `change_basics`
- `pick_type`
- `pick_pacing`
- `add_rest`
- `remove_rest`
- `validate`
- `save`
- `enable_manual_edit`
- block/set copy/remove/expand events
- `id="plan-form"`

## Verification

- `/workouts/new` renders with session-surface style.
- Existing editor flow still updates live.
- Existing save behavior still works.
- Focused LiveView tests pass.
- `mix precommit` passes before push.
