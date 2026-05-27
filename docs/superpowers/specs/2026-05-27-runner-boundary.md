# Session Runner Boundary

## Decision

Phoenix owns persistence and plan loading. The browser owns session execution.

## Server responsibilities

- Load the persisted workout plan for the current user.
- Render the session shell and completion form.
- Push serialized plan data with `session_ready`.
- Validate the client completion payload.
- Save the main workout session and optional warmup session atomically.

Phoenix does not derive runner warmup/workout timelines for client execution.

## Client responsibilities

- Derive warmup and workout timelines from serialized plan data.
- Run the flow FSM that orchestrates warmup, warmup-done prompt, and workout.
- Run the generic segment FSM for each runnable segment.
- Render segment-local progress, timer, completed reps, and planned reps.
- Push completion results when the workout segment finishes.

## Rationale

The runner DOM is `phx-update="ignore"` and high-frequency state is client-owned. Keeping timeline derivation in the same runtime as the FSM prevents server/client disagreement about warmup totals, workout totals, and segment timing.
