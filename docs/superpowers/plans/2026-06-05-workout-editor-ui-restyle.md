# Workout Editor UI Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle `/workouts/new` and `/workouts/:id/edit` to match the warm-paper session surface while preserving the current editor flow.

**Architecture:** Keep `PlansLive.Edit` state, events, forms, generated blocks, and solver behavior unchanged. Apply visual changes in the existing HEEx component boundaries and opt the `:plans` page into the shared session surface shell.

**Tech Stack:** Phoenix LiveView, HEEx, Tailwind CSS v4, session CSS variables, ExUnit/LiveViewTest, jj.

---

## Task 1: Opt Plan Editor Into Session Shell

**Files:**

- Modify `lib/burpee_trainer_web/components/layouts.ex`
- Modify `test/burpee_trainer_web/components/layouts_test.exs`

Steps:

- [ ] Add `:plans` to `session_surface_page?/1`.
- [ ] Update the layout test loop from `[:home, :workouts, :stats]` to `[:home, :workouts, :stats, :plans]`.
- [ ] Run `mix test test/burpee_trainer_web/components/layouts_test.exs`.
- [ ] Commit with `jj describe -m "style(layout): include plan editor surface"` and `jj new`.

## Task 2: Add Workout Editor Smoke Tests

**Files:**

- Modify `test/burpee_trainer_web/live/workouts_live_test.exs`

Steps:

- [ ] Add a `/workouts/new` describe block with tests that render the new plan page, assert `session-surface`, `id="plan-form"`, `New plan`, `Six-Count`, `Navy SEAL`, and `Create plan`.
- [ ] Add a lightweight interaction test that clicks Navy SEAL via `button[phx-click='pick_type'][phx-value-type='navy_seal']` and asserts the page still renders `Navy SEAL` and `plan-form`.
- [ ] Run `mix test test/burpee_trainer_web/live/workouts_live_test.exs`.
- [ ] Commit with `jj describe -m "test(plans): cover editor surface"` and `jj new`.

## Task 3: Restyle Editor Header and Controls

**Files:**

- Modify `lib/burpee_trainer_web/live/plans_live/edit/render.html.heex`
- Modify `lib/burpee_trainer_web/live/plans_live/edit.ex`

Steps:

- [ ] Change the wrapper in `render.html.heex` to `class="session-surface mx-auto max-w-3xl space-y-5 pb-24 text-[var(--session-ink)]"`.
- [ ] Restyle `plan_editor_header/1` input and level label using session tokens.
- [ ] Restyle `plan_type_picker/1`, `plan_goal_controls/1`, `plan_pacing_controls/1`, and `plan_rest_controls/1` from rounded dark panels to square bordered warm-paper controls.
- [ ] Preserve all `phx-click`, `phx-change`, field names, input names, and values.
- [ ] Run `mix test test/burpee_trainer_web/live/workouts_live_test.exs`.
- [ ] Commit with `jj describe -m "style(plans): restyle editor controls"` and `jj new`.

## Task 4: Restyle Solution and Blocks

**Files:**

- Modify `lib/burpee_trainer_web/live/plans_live/edit/plan_solution_card_template.html.heex`
- Modify `lib/burpee_trainer_web/live/plans_live/edit/blocks_editor_template.html.heex`
- Modify helper markup in `lib/burpee_trainer_web/live/plans_live/edit.ex` if needed for block summaries.

Steps:

- [ ] Restyle the solution card to session token border/background, square save button, and muted validation text.
- [ ] Restyle block headers, set summaries, manual edit inputs, menus, add/remove/copy actions with session tokens.
- [ ] Remove rounded corners from progress-like bars; do not remove rounded icons/badges unless they are progress bars.
- [ ] Preserve `id="plan-form"`, form submit/change behavior, hidden fields, block/set sort/drop fields, and manual edit events.
- [ ] Run `mix test test/burpee_trainer_web/live/workouts_live_test.exs`.
- [ ] Run `mix precommit`.
- [ ] Commit with `jj describe -m "style(plans): restyle generated blocks"` and `jj new`.

## Task 5: Final Review and Push

Steps:

- [ ] Run `mix test test/burpee_trainer_web/live/workouts_live_test.exs test/burpee_trainer_web/components/layouts_test.exs`.
- [ ] Run `mix precommit`.
- [ ] Review the diff for behavior changes.
- [ ] Move/push master if requested: `jj bookmark set master -r @- && jj git push -b master`.

---

## Self-Review

- Covers shell, tests, editor controls, solution card, and generated blocks.
- Preserves current flow by keeping events, forms, field names, and hidden sort/drop inputs.
- No data/model/solver changes.
