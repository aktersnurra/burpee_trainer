# Goal Creation Modal — Design Spec

Date: 2026-05-19

## Overview

Add a modal to the Stats screen that lets the user set a burpee count goal and target date for a specific burpee type. The modal is opened from the goal slot cards.

## Trigger

Each `goal_slot` component has a "Set goal" link. This becomes a `phx-click="open_goal_modal"` button with `phx-value-type={@burpee_type}`. The parent `StatsLive` stores `goal_modal_type` (atom or nil) — nil means closed.

## Pre-condition: baseline session required

On open, `StatsLive` looks up the most recent session for that burpee type via a new `Workouts.last_session_for_type/2` query. If none exists, the modal renders an empty state:

> "Log at least one [6-Count / Navy SEAL] session before setting a goal."

No form is shown. The user can close the modal.

## Form fields (user inputs)

| Field | Input type | Notes |
|---|---|---|
| Burpee count target | number | required, > baseline |
| Target date | date | required, must be after today |

Burpee type is fixed to the slot's type — no picker.

## Derived fields (computed on save, not shown)

| Field | Derivation |
|---|---|
| `burpee_count_baseline` | `last_session.burpee_count_actual` |
| `duration_sec_baseline` | `last_session.duration_sec_actual` |
| `date_baseline` | today |
| `duration_sec_target` | `burpee_count_target * (duration_sec_baseline / burpee_count_baseline)` |

## Component

`BurpeeTrainerWeb.GoalFormComponent` — a `live_component`, mirroring the structure of `LogFormComponent`.

- Receives: `id`, `current_user`, `burpee_type`, `baseline_session`, `on_save`
- Handles events: `"save"` (phx-submit), `"cancel"`
- On success: calls `send(self(), socket.assigns.on_save)` → `{:goal_saved}`
- On error: re-renders with changeset errors

## Modal shell (StatsLive)

Same pattern as the log modal:

- Assign: `goal_modal_type` (`:six_count` | `:navy_seal` | nil)
- Assign: `goal_baseline_session` (the last session, or nil)
- Events: `"open_goal_modal"`, `"close_goal_modal"`
- On `{:goal_saved}`: refresh `@goals`, close modal

## Data layer

New function in `BurpeeTrainer.Workouts`:

```elixir
@spec last_session_for_type(User.t(), atom) :: WorkoutSession.t() | nil
def last_session_for_type(user, burpee_type)
```

Queries most recent session by `inserted_at` for that user + burpee type where `burpee_count_actual` and `duration_sec_actual` are not nil (needed for baseline derivation).

## UI style

- Same modal shell as log modal: bottom sheet on mobile, centered on desktop
- `bg-[#0D1017] border border-[#1E2535] rounded-t-2xl sm:rounded-2xl p-6`
- Primary button: `bg-primary` (electric blue `#4A9EFF`)
- No shadows, no gradients

## Out of scope (deferred)

- MILP-derived duration target (future goal patch)
- Goal editing / abandoning from Stats (separate feature)
- Volume chart per-type breakdown
