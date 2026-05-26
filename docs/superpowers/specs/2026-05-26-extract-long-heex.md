# Spec: Extract Long HEEx Into Separate Files

## Goal

Keep LiveView modules readable by moving large inline `~H""" ... """` blocks into colocated `.html.heex` files.

Use this for page-level templates and large private function components such as editors, cards, panels, and repeated UI sections.

## Rule of thumb

Extract HEEx when any of these are true:

- The `~H` block is longer than ~80–120 lines.
- The markup contains nested conditionals, loops, or `inputs_for`.
- The function is mostly HTML with only small assign preparation.
- The UI section has a clear name, such as `blocks_editor`, `set_row`, `workout_card`, or `session_summary`.

Do not extract very small components where a separate file would add more indirection than clarity.

## Use `embed_templates`

In the LiveView or component module, add:

```elixir
embed_templates "MODULE_FOLDER/*"
```

Example:

```elixir
defmodule MyAppWeb.WorkoutPlanLive.Form do
  use MyAppWeb, :live_view

  alias MyApp.Fmt

  embed_templates "workout_plan_live/*"

  # private helpers used by templates may remain here
  defp format_sec(value), do: ...
  defp sets_uniform?(sets), do: ...
end
```

A file named:

```txt
blocks_editor.html.heex
```

generates a function:

```elixir
blocks_editor(assigns)
```

So remove any existing inline `defp blocks_editor/1` to avoid a name conflict.

## File placement

Place extracted templates next to the LiveView/module that owns them:

```txt
lib/my_app_web/live/workout_plan_live/form.ex
lib/my_app_web/live/workout_plan_live/blocks_editor.html.heex
lib/my_app_web/live/workout_plan_live/set_row.html.heex
lib/my_app_web/live/workout_plan_live/block_header.html.heex
```

Use filenames that match the UI concept and generated function name.

## Calling extracted templates

From HEEx:

```heex
<.blocks_editor
  form={@form}
  expanded_blocks={@expanded_blocks}
  block_time_ranges={@block_time_ranges}
  manual_edit={@manual_edit}
  open_block_menu={@open_block_menu}
/>
```

Pass only the assigns the template needs. Avoid relying on broad, implicit state when possible.

## Template rules

Inside `.html.heex` files:

- Keep HTML structure in the template.
- Keep business logic and data mutations in Elixir functions.
- Small display calculations are okay, for example formatting, grouping, or simple derived values.
- Prefer private helper functions in the owning module for reusable logic.
- Keep names stable and descriptive.

Example:

```heex
<% expanded = MapSet.member?(@expanded_blocks, block_f.index) %>
<% sets = block_sets(block_f) %>
<% uniform = sets_uniform?(sets) %>
```

Prefer this over large pipelines repeated inline.

## Refactor process

1. Identify a long `defp component(assigns) do ~H""" ... """ end`.
2. Create `component.html.heex` in the owning template folder.
3. Move only the contents of the `~H` block into the file.
4. Add `embed_templates "folder/*"` to the module.
5. Delete the old inline function.
6. Update call sites to use `<.component ... />` if needed.
7. Run formatter and tests.

```sh
mix format
mix test
```

## Acceptance criteria

- Long inline HEEx blocks are removed from the `.ex` module.
- Extracted templates compile through `embed_templates`.
- Existing UI and LiveView events behave unchanged.
- Private helper functions used by templates remain available.
- The module is easier to scan: Elixir state/event logic is in `.ex`, markup is in `.html.heex`.
