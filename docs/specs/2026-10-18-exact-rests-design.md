# Exact rests in workout layouts

## Status

Approved on 2026-10-18 after feedback from Claude writing workouts through the MCP server.
Replaces `rest_weights` in `2026-10-05-authoring-rest-fitter-design.md`.

## Problem

A layout gave each gap between sets a relative weight, and the fitter split the phase's spare
time by weight, cadence tail included, then took the tail off each share. So a rest was
`spare × w / Σw − tail`, which nobody could predict, and the `editable` form (stored rests
sent back as weights) changed a workout's rests on an unchanged edit: rests of 20 s and 60 s
came back as 16.5 s and 63.5 s. Errors named neither the anchor a phase ends at nor what to
change, and the summary showed only a range of rests.

## Design

- Each gap is `{"sec": n}` (exactly n seconds after the last rep's beat; 0 starts the next set
  on the next beat, with no rest event) or `{"share": w}` (w > 0).
- Shares split what is left after the phase's sets, cadence tails and exact rests, in whole
  milliseconds; the rounding remainder goes to the last share.
- A phase with a gap ends exactly at its anchor: the next timed rest's start, or
  `target_duration_sec`. Without a share, sets, tails and exact rests must add up exactly. A
  phase of one set keeps the ±10 s tolerance, since nothing in it can stretch.
- `editable` returns stored rests as `{"sec": n}`, so an unchanged edit stores an equal workout.
- Errors say which phase, what it is anchored to, what the time is made of, by how much it is
  off, and what to change. A single set that falls short of the workout's end explains that the
  tail after the last rep is not counted.
- The MCP summary lists every rest in order.
- `burpee://workout-format` has one Timing section with a worked example that a test fits.
- The app's own coach uses the same layout. Its guidance says to use shares, giving `sec` only
  for a rest the user stated, and to keep at least one share per phase, so the fitter still does
  the arithmetic the model is bad at.

## Not changed

A workout ends when its last rep's work ends: a rep is work + rest, but the final rep is only
work. An even-paced workout therefore lasts `(reps − 1) × sec_per_rep + sec_per_burpee`, so 60
reps at 20 s with 4 s of work is 19:44, not 20:00. This is deliberate and stays.
