# PlanEditor HEEx File Extraction Plan

Goal: move the largest PlanEditor inline `~H` blocks into colocated `.html.heex` files using `embed_templates`, preserving behavior.

## Scope

Target module:

- `lib/burpee_trainer_web/live/plans_live/edit.ex`

Target template folder:

- `lib/burpee_trainer_web/live/plans_live/edit/`

Extract only large components where the file boundary improves readability. Keep small controls inline unless they grow.

## Task 1: Extract page render template

- Add `embed_templates "edit/*"` near the top of `PlansLive.Edit`.
- Create `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`.
- Move only the contents of `render/1`'s `~H` block into `render.html.heex`.
- Remove the inline `render/1` body if `embed_templates` generates `render/1` cleanly, or keep a tiny wrapper only if Phoenix requires it.
- Preserve all component calls and assigns.
- Run `mix test test/burpee_trainer_web/live`.

## Task 2: Extract block editor template

- Create `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor.html.heex`.
- Move only the contents of inline `blocks_editor/1`'s `~H` block into the file.
- Delete inline `defp blocks_editor/1` to avoid function conflict.
- Keep helper functions such as `sets_uniform?/1`, `block_time_ranges/2`, and formatting helpers in `edit.ex`.
- Run `mix test test/burpee_trainer_web/live`.

## Task 3: Extract solution card template if still useful

- Create `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card.html.heex`.
- Move only the `~H` contents of `plan_solution_card/1` into the file.
- Keep the assign preparation that computes `block_time_ranges` in a small Elixir wrapper only if needed. If that conflicts with `embed_templates`, rename the template function to `plan_solution_card_template/1` and call it from the wrapper.
- Preserve `id="plan-form"`, all LiveView events, and save-button behavior.
- Run `mix test test/burpee_trainer_web/live`.

## Task 4: Verify and ship

- Run `mix precommit`.
- Commit with `refactor(plans): move editor heex to templates`.
- Move `master` and push.

## Non-goals

- Do not change PlanEditor state, assigns, event names, or DOM IDs.
- Do not split every small function component; avoid extraction that adds more indirection than clarity.
- Do not move business logic into `.html.heex` files.
