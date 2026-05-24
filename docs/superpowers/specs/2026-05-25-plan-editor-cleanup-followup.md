# Plan Editor Cleanup Follow-up

## Current State

`PlansLive.Edit` now keeps editor state in `%BurpeeTrainer.PlanEditor.State{}` and mirrors selected fields into legacy assigns for template compatibility.

Remaining loose assign usage is template-facing only:

- `@plan_input` drives form values, selected type/pacing styling, rest rows, and helper calls.
- `@solver_error` renders the solver error message.
- `@solver_solution` renders suggested pace text.
- `@manual_edit` controls Layer 3 edit/read-only UI.
- `@expanded_blocks` and `@open_block_menu` control block tree display.

Callback-side reads have largely moved to `socket.assigns.editor`.

## Recommendation

Do not replace all template-facing assigns with `@editor.*` in one broad pass. The remaining usages are concentrated in HEEx, and changing them would create a large visual/template diff with little domain payoff.

The next safe slice is rendering extraction, not more state-machine work:

1. Extract the Layer 1/2 controls into small function components that receive `plan_input`, `solver_error`, and `solver_solution` explicitly.
2. Extract the Layer 3 block tree into a function component that receives `form`, `manual_edit`, `expanded_blocks`, `open_block_menu`, and `plan_input` explicitly.
3. Keep the mirrored assigns until the render components are stable.

## Why

The editor state machine now owns the behavior-heavy transitions. The largest remaining complexity is template size and presentation branching. Component extraction will reduce `PlansLive.Edit` line count and make future `@editor` replacement mechanical.

## Tests Needed

- Existing `test/burpee_trainer_web/live` suite.
- Add smoke tests only if extraction changes DOM IDs or event targets.
- Prefer `has_element?/2` over raw HTML assertions.

## Defer

Do not start a full HEEx rewrite without a separate implementation plan. The current state is stable and verified; the next slice should be UI-component decomposition.
