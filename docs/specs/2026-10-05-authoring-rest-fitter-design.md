# Authoring pipeline: LLM layout + deterministic rest fitter

> **Superseded in part** (2026-10-11): the New form has no Sets or Pauses fields; the athlete says them in the note, the coach reads them into `set_reps` and `timed_rests` (`Coach.prepare_new_request/4`), and Review shows them before saving.

## Status

Direction approved by the owner on 2026-10-05 (sub-project 2 of
`2026-10-05-coach-first-architecture-design.md`). Requires the legacy cull to be complete.
Decisions marked **(default)** were made by the author of this spec and are open for owner
review.

## Problem

The LLM currently has to produce exact arithmetic: every work and rest duration must sum to
the target total and place fixed pauses at exact elapsed times. It routinely misses (for
example 20:05 instead of 20:00), which led to a repair loop, ~250 lines of arithmetic
feedback in `Coach`, a phased response schema (`PhasedWorkoutDefinition`), and an
"alternative rests" review path. The arithmetic is not an optimization problem once the set
structure is fixed; it is one linear equation per phase.

## Pipeline

1. **Request.** The New form produces a typed `WorkoutRequest` locally
   (`HomeWorkoutRequest.request/2`, unchanged): type, style, reps, duration, optional active
   pace, optional ordered sets, optional fixed pauses ("60s at 11:00"), recovery. Free text
   in the form's note travels as the instruction. The Edit flow keeps its interpretation call
   (`Coach.prepare_home_revision`) to turn conversational text into a request.
2. **Layout (LLM).** One call returns a *layout*, not a timeline. The LLM chooses structure
   only.
3. **Rest fitter (pure).** `Coach.RestFitter.fit(request, layout)` computes every rest
   duration exactly and returns a canonical workout definition map, or an infeasibility with
   numbers.
4. **Validation.** `WorkoutDefinition.new/1`, `PlanCompiler.compile/1`, and
   `WorkoutRequest.validate_definition/2` run unchanged.
5. **Repair.** On infeasibility or validation failure, the exact error text is sent back
   with the rejected layout for one retry. Then the failure is shown to the owner.
6. **Review and approval.** Unchanged (approval publishes, selection is separate).

## Layout schema (LLM output)

```json
{
  "name": "string",
  "rationale": "string",
  "phases": [
    {
      "sets": [{"reps": 10, "sec_per_rep": 6.0, "sec_per_burpee": 5.0}],
      "rest_weights": [1.0]
    }
  ]
}
```

- `phases` has exactly `length(request.timed_rests) + 1` entries, in order. Fixed pauses sit
  between consecutive phases; the LLM does not emit them.
- `rest_weights` has exactly `length(sets) - 1` positive numbers per phase. Equal weights mean
  even rests. Weights are relative; only ratios matter.
- Burpee type, pacing style, target reps and target duration come from the request and are
  not part of the layout.
- `sec_per_rep` and `sec_per_burpee` must be whole milliseconds (at most three decimals),
  `sec_per_burpee <= sec_per_rep`; for `unbroken` style they are equal.

## Timing model (from the existing compiler and `WorkoutRequest.rest_timeline/1`)

For a set with `reps`, cadence `c = sec_per_rep` and active time `a = sec_per_burpee`:

- movement span `m = (reps - 1) * c + a` (from the first rep's start to the end of the last
  movement);
- cadence tail `t = c - a` (idle time after the last movement inside a non-terminal set's
  duration `reps * c`).

A *pause* is everything between the end of one set's last movement and the start of the next
set: `pause = t_previous + rest_event_duration`. `rest_timeline/1` already measures pauses
this way, and fixed pauses are validated as pauses (start within ±10 s, duration exact).

## Fitter algorithm

Given phases `P_1..P_n` and fixed pauses `F_i = (start s_i, duration d_i)` for `i < n`:

```
cursor = 0
for each phase i:
  movement = Σ m_j over the phase's sets
  gaps     = number of sets − 1
  if i < n: target_end = s_i            # movement must end where the fixed pause starts
  else:     target_end = total_duration # terminal set ends exactly at the target
  budget   = target_end − cursor − movement      # time for ordinary pauses in this phase
  if gaps > 0:
    require budget > 0
    pause_j = budget × w_j / Σw, in whole milliseconds; floor each, add the remainder to the
              last gap
    rest_j  = pause_j − t_j   (t_j = tail of the set before gap j); require rest_j ≥ 1 ms
    phase_end = target_end
  else:
    phase_end = cursor + movement
    require |phase_end − target_end| ≤ 10 s
  if i < n:
    fixed rest event duration = d_i − t_last_set_of_phase; require ≥ 1 ms
    cursor = phase_end + d_i
```

- The definition's `target_duration_sec` equals the actual total. A terminal phase without
  gaps can end within ±10 s of the requested total; its actual total is then a whole number
  of seconds or the fitter reports `total_not_whole_second`.
- Every value is computed in integer microseconds; inputs that are not whole milliseconds
  are rejected (`timing_not_whole_millisecond`).
- Infeasibility returns `{:error, {reason, details}}` with reasons
  `:wrong_phase_count`, `:wrong_weight_count`, `:non_positive_weight`,
  `:timing_not_whole_millisecond`, `:phase_overfull` (movement exceeds budget),
  `:rest_shorter_than_tail`, `:pause_shorter_than_tail`, `:phase_misses_anchor`,
  `:total_not_whole_second`, plus `phase` index and the relevant numbers in microseconds.
  `Coach` renders these as one line of feedback, for example
  `phase 2 needs 7:40 of movement but only 7:00 is available before the pause at 18:00`.
- **Boundary:** the fitter never adds, removes, merges, or reorders sets, and never changes
  reps or pace. If a layout cannot be fitted, the LLM must change it.

## What is removed

- `Coach.PhasedWorkoutDefinition` and its tests.
- The `workout_definition` response kind for authoring (replaced by `workout_layout`).
  `WorkoutDefinition.json_schema/0` stays only if another caller needs it; otherwise remove.
- In `Coach`: `correction_feedback/3`, `timeline_arithmetic/1`, `format_timeline_arithmetic/3`,
  `target_rest_budget/3`, `format_seconds/1`, `reconcile_actual_duration/2`,
  `flatten_provider_definition/2`, `feedback_proposal/2`, `review_request/2`,
  `choose_review_rests/3`, `complete_review_request/2`'s alternative branch, and the
  `prepare_review` alternative-acceptance branch in `correct_definition`.
- **(default)** The explicit-alternative review (`alternative?`, `accept_alternative`, the
  `use_prepared_alternative` event, its UI and tests). With exact fitting, fixed pauses land
  exactly or the request is infeasible; there is no nearby alternative to offer.
- Prompt text that teaches arithmetic. The definition system prompt
  (`WorkoutGuidance.system_prompt(user, :definition)`) is rewritten to describe the layout:
  structure, set shapes, recovery placement via weights, and level guidance.

## Error handling

- Provider and transport errors keep their current codes and UI copy.
- Fitter infeasibility after the retry surfaces as `:infeasible_workout_definition` with the
  rendered one-line reason in the review area; the owner's fields and note stay editable.

## Testing

Owner clarification: preserve the specified floor-plus-last-remainder allocation. The last
ordinary pause may differ from its ideal proportional share by more than 1 ms because it
receives the entire rounding remainder. Gapless phases retain the specified ±10 s tolerance.

- `RestFitter` property tests (StreamData): for any generated feasible layout, the fitted
  definition compiles, its total equals the target, every fixed pause starts at its exact
  start (zero error) with its exact duration for phases with adjustable gaps, ordinary pauses
  equal their proportional shares floored to milliseconds with all rounding remainder on the
  phase's last ordinary pause, sets/reps/pace are unchanged; generated infeasible layouts return the
  documented reason and never a definition.
- Example tests for the owner's cases: 140 reps at 5 s with 60 s at 11:00 and 40 s at
  18:00 in 20:00; a single unbroken set; no fixed pauses with even weights.
- One full-flow LiveView test: New with fixed pauses → recorded layout response → review
  shows exact pauses → approve.
