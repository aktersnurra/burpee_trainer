# Reading fatigue, sets and slack through MCP

The camera counts each rep and records when it finished. `query_history` and
`get_session` compare those times with the workout's plan: when each set's beep
went, how many reps it asked for and at what pace. Everything here is derived from
those two things, so it exists only for camera sessions (`capture_mode` `tracked`).
Timed and logged sessions have `fatigue` null, `window_slack` null, `fade` null,
`active_pace_sec` null and `sets` empty.

**When the camera missed the start** (`fatigue` holds only `camera_coverage`), the
summaries `active_pace_sec`, `window_slack` and `fade` are null too: a shrinking curve
could be a camera that stopped working, not the athlete. `sets` still lists what the
camera counted, so you can see what it caught.

All times are seconds. "From the session start" means from the first set's
count-in, the same clock for every field.

## Session pace

| Field | Unit | Meaning | Null when |
|---|---|---|---|
| `elapsed_pace_sec` | s/rep | `duration_sec / reps`: wall-clock time per rep, **rests included**. A workout with long rests reads slow even when every set was fast. | no reps or no duration |
| `active_pace_sec` | s/rep | Over the complete sets, seconds from each set's beep to its last rep, summed, divided by their reps. **Rests excluded.** Compare with the plan's seconds per rep. | no camera, or no set complete |
| `pace_consistency` | 0..1 | Each set's evenness, 1 minus the coefficient of variation of its rep intervals divided by its planned interval, averaged over sets weighted by their intervals. 1 is perfectly even; rests, planned pace changes and a set run evenly ahead of the beat are not unevenness. | no camera, or fewer than two in-set intervals |

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
| `recovery_delta_sec` | s | the first rep after a rest lands later on its beat than the workout's first rep did: slower to restart; a first rep ahead of its beat counts as on it | the workout's first rep, after the same count-in | no rests, or no first rep after a rest counted |

How the parts are found:

- Each counted rep is matched in order to a scheduled rep. A count more than half an
  interval after a scheduled rep leaves that rep missed; a count early, however early,
  is that rep done ahead of the beat.
- **Stretches** for `slip_at_sec` are each set split evenly into pieces of at most 10
  reps. A stretch slipped when its median lag behind the beat, net of the opening
  stretch's lag, is over 1.5 s (a rep ahead of its beat lags by nothing, so going
  out fast and settling onto the beat is not a slip), or when at least two and over 30% of its reps were
  missed. One missed rep is a camera blink, never a slip on its own.
- Running ahead of the beat is keeping up. It does show in `decline` and
  `pace_delta_sec`: going out ahead and settling onto the beat later is a real
  slowdown, so `decline` is positive while `kept_up` stays true. Read the two together.
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
| `first_rep_vs_beat_sec` | s | the first counted rep against its beat; negative is ahead | no rep counted |
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
| `rest_sec` | s | median planned rest after the measured sets: read `last_sec` against it |
| `trend_sec_per_set` | s per set | least-squares slope of slack on set number; negative is the window shrinking as they tire |
| `sets_planned` | count | sets in the workout |
| `runs_out_at_set` | set number | where the fitted slack line reaches zero, carried on past the workout if need be: an estimate of the ceiling without falling behind. At or below `sets_planned`, the curve runs out inside this workout. Null when slack is not shrinking or fewer than four sets were measured |

The planner reads the same curve. A last set with under a quarter of its rest left,
on a shrinking curve, holds the next session at the same reps (`slack_running_out`)
even when they kept up, and so does a curve whose `runs_out_at_set` is within the
workout's own sets. Half the rest or more left in every set, shrinking by under
a quarter of a rest over the session, after two successful sessions, allows a bigger
step (`repeated_success_with_headroom`).

## `restart`

How each set's first rep lands against its beat, set by set: starting later as they
tire is a different signal from slowing inside a set. Null with fewer than two sets
with a first rep counted, or when the camera missed the start.

| Field | Unit | Meaning |
|---|---|---|
| `sets_measured` | count | sets with a first rep counted |
| `first_sec` / `last_sec` | s | `first_rep_vs_beat_sec` of the first and last of them; negative is ahead |
| `trend_sec_per_set` | s per set | least-squares slope; positive is starting each set later |

## `fade`

Where the pace faded: inside sets (the sets are too long) or from set to set (the
rests are too short to recover). The first rep of each set is left out of both,
since it carries the reaction to the beep. Null when neither can be measured.

| Field | Unit | Positive means | Compared against | Null when |
|---|---|---|---|---|
| `within_set` | fraction | the second half of a set's rep-to-rep intervals was slower than its first half; 0.1 is 10% slower. Median over complete sets | the same set's first half | no complete set has four reps |
| `across_sets` | fraction | the last third of complete sets moved slower against their planned beat than the first third; 0.05 is 5% slower | the first third of the same session | fewer than three complete sets |
| `pattern` | text | `within_sets` (within_set over 0.1), `across_sets` (across_sets over 0.05), `both`, or `none` | | |

## `same_workout_last_time` (`get_session`)

This session against the last camera session of the same workout (the same program,
to the microsecond), when the camera caught the start of both. Null without one.

| Field | Unit | Meaning |
|---|---|---|
| `session_id` / `date` | | the earlier session |
| `sets_compared` | count | sets complete in both |
| `sets_faster` | count | of those, sets finished sooner after their beep this time |
| `finish_change_sec` | s | median change in each set's `finish_sec`; negative is faster |

## `camera_by_feedback` (`history_stats`)

The selected camera sessions (start caught) grouped by what the athlete reported:
`limiter.<breathing|whole_body|upper_body|legs>`, `mood.<-1|0|1>`, `low_energy`,
`high_energy`, `heat_affected`, and `all`. A session is in every group its feedback
puts it in. Null with no such session. These describe the selection; they do not
show a cause, and a group of two sessions shows little.

| Field | Unit | Meaning |
|---|---|---|
| `sessions` | count | camera sessions in the group |
| `kept_up_share` | 0..1 | share that kept up to the end |
| `median_decline` | ratio | median `decline` |
| `slack_sessions` | count | sessions with a slack curve |
| `median_slack_trend_sec_per_set` | s per set | median `trend_sec_per_set` |
| `median_slack_last_share_of_rest` | 0..1+ | median `last_sec / rest_sec`: how much of the last rest was left |
