# Reading fatigue, sets and slack through MCP

The camera counts each rep and records when it finished. `query_history` and
`get_session` compare those times with the workout's plan: when each set's beep
went, how many reps it asked for and at what pace. Everything here is derived from
those two things, so it exists only for camera sessions (`capture_mode` `tracked`).
Timed and logged sessions have `fatigue` null, `window_slack` null,
`active_pace_sec` null and `sets` empty.

All times are seconds. "From the session start" means from the first set's
count-in, the same clock for every field.

## Session pace

| Field | Unit | Meaning | Null when |
|---|---|---|---|
| `elapsed_pace_sec` | s/rep | `duration_sec / reps`: wall-clock time per rep, **rests included**. A workout with long rests reads slow even when every set was fast. | no reps or no duration |
| `active_pace_sec` | s/rep | Over the complete sets, seconds from each set's beep to its last rep, summed, divided by their reps. **Rests excluded.** Compare with the plan's seconds per rep. | no camera, or no set complete |
| `pace_consistency` | 0..1 | 1 minus the coefficient of variation of each in-set rep interval divided by its planned interval. 1 is perfectly even; rests and planned pace changes are not unevenness. | no camera, or fewer than two in-set intervals |

## `fatigue`

`fatigue` is null without the camera. When the camera caught less than 80% of the
opening third of the planned reps it holds only `camera_coverage`: later misses
could not be told from a camera that never worked, so the other fields are absent.

| Field | Unit | Positive means | Compared against | Null when |
|---|---|---|---|---|
| `camera_coverage` | 0..1 | share of planned reps the camera matched to a counted rep | the plan's rep count | never, inside `fatigue` |
| `kept_up` | boolean | true: they stayed on or ahead of the beat to the end; finishing a set early is keeping up | `slip_at_sec` | opening coverage too low |
| `slip_at_sec` | s from session start | when they fell behind for good: the start of the first stretch from which every later stretch slipped | each rep's due time | they kept up, or opening coverage too low |
| `decline` | ratio | the last third of reps was slower against plan than the first third; 0.08 is 8% slower | the first third of the same session | either third has no in-set pair of counted reps |
| `pace_delta_sec` | s | median seconds slower than planned between consecutive reps of a set; negative is faster | the set's planned seconds per rep | no in-set pair of counted reps |
| `recovery_delta_sec` | s | the first rep after a rest lands later on its beat than the workout's first rep did: slower to restart | the workout's first rep, after the same count-in | no rests, or no first rep after a rest counted |

How the parts are found:

- Each counted rep is matched in order to a scheduled rep. A count more than half an
  interval after a scheduled rep leaves that rep missed; a count early, however early,
  is that rep done ahead of the beat.
- **Stretches** for `slip_at_sec` are each set split evenly into pieces of at most 10
  reps. A stretch slipped when its median lag behind the beat, net of the opening
  stretch's lag, is over 1.5 s, or when at least two and over 30% of its reps were
  missed. One missed rep is a camera blink, never a slip on its own.
- `decline` and `pace_delta_sec` use only intervals between two counted reps of the
  same set, so rests never count as slow reps.

## `sets` (with `get_session`, or `query_history` with `include_sets`)

One entry per planned set, in order. A set's **window** runs from its beep to the
next set's beep: its work and the rest after it. The last set's window is its work
plus any rest after it. A rep belongs to the window it was counted in.

| Field | Unit | Meaning | Null when |
|---|---|---|---|
| `set` | number | 1-based position | never |
| `reps_planned` / `reps` | count | reps the set asked for / reps counted in its window | never |
| `sec_per_rep_planned` | s/rep | the set's planned beat | never |
| `start_sec` | s from session start | the set's beep | never |
| `work_end_sec` | s from session start | when the set's last rep was due | never |
| `window_end_sec` | s from session start | the next set's beep | never |
| `window_sec` / `rest_after_sec` | s | window length / planned rest after the set | never |
| `finish_sec` | s from the set's beep | when its last counted rep finished | set incomplete |
| `finish_vs_plan_sec` | s | last rep against `work_end_sec`; negative is finished early | set incomplete |
| `slack_sec` | s | `window_end_sec` minus the last rep: what was left of the window to recover in | set incomplete |
| `active_pace_sec` | s/rep | `finish_sec / reps` | set incomplete |
| `rep_times_sec` | s from the set's beep | when each counted rep finished | never (empty when none) |

A set is complete when the camera counted at least `reps_planned` reps in its window.

## `window_slack`

The slack curve across the session, for interval workouts: the clearest sign of
fatigue when sets are finished ahead of the beat and the rest of the window is
recovery. Only complete sets with a rest after them count, since a window with no
rest is all work. Null with fewer than two such sets.

| Field | Unit | Meaning |
|---|---|---|
| `sets_measured` | count | sets behind the curve |
| `first_sec` / `last_sec` | s | slack of the first and last measured set |
| `min_sec` / `median_sec` | s | smallest and median slack |
| `trend_sec_per_set` | s per set | least-squares slope of slack on set number; negative is the window shrinking as they tire |
