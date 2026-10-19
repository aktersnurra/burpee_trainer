# Fatigue insights and progression

## Problem

The planner sees reps, duration, pace and feedback per session, nothing about how a session
went inside it. Sessions are paced by a beep, so average pace equals the plan whenever the
athlete keeps up: repeated 140-rep sessions at exactly the planned 8.57 s/rep say only that
140 is below their ceiling. The signal that matters is whether, and when, they fell behind.

`Workouts` already derives `pace_delta_sec`, `cadence_decline` and `recovery_delta_sec` from
`cadence_ms` (pose-detected rep timestamps), but:

- intervals are zipped against the plan by index, so one missed or extra detection
  misaligns every later rep;
- `cadence_decline` compares the first and last three intervals only, in raw seconds, so a
  plan that changes pace on purpose reads as fatigue;
- `pace_delta_sec` is a mean, dominated by one missed detection;
- `recovery_delta_sec` is always nil;
- none of it reaches the planner or the MCP.

## Design

### `BurpeeTrainer.Workouts.Fatigue` (pure)

Input: detected rep timestamps and the program snapshot. Output, all nil when coverage is
too low:

| Field | Meaning |
|---|---|
| `coverage` | matched reps / planned reps |
| `pace_delta_sec` | median (actual − planned) interval over work reps |
| `decline` | median(actual/planned) of the last third of work reps − the first third |
| `slip_at_sec` | start of the first segment (a set, split evenly into segments of at most 10 reps) from which every later segment slipped: median lag, net of the opening segment's, above 1.5 s, or at least two and over 30% of its reps missed; nil when they kept up |
| `kept_up` | `slip_at_sec` is nil |
| `recovery_delta_sec` | median (actual − planned) time across rests, last rep before to first rep after |

1. Scheduled time of each rep from the snapshot (cumulative work intervals and rests).
2. Match each detection to the nearest scheduled rep within half an interval; unmatched
   schedule slots are misses, unmatched detections are dropped. A rep the athlete fell a
   whole interval behind on reads as missed, so slipping shows as late lag, misses, or both.
3. Below 80% coverage of the opening third, return only `coverage`: late misses can only be
   read as slipping when the camera worked while the athlete was fresh.

An unpaced (max-effort) work kind does not exist yet; when it does, add a Theil–Sen slope of
interval on rep index for it.

Properties: a detection list equal to the schedule gives zero deltas, `kept_up` and no
slip; dropping or inserting one detection changes no metric of later sets; scaling a
plan's intervals and its detections together leaves `decline` unchanged.

### Exposure

- Persist the new fields on the session at completion (migration), replacing
  `cadence_decline` and the always-nil `recovery_delta_sec`.
- `Coach.Tools.History.summary/1` (planner context) and the MCP `query_history` session
  shape gain `kept_up`, `slip_at_sec`, `decline`, `coverage` when present.

### Progression rule (planner prompt)

- Kept up, mood fine: next time about +5 reps, or the same reps with shorter rests.
- Slipped in the last third, or rated hard: repeat.
- Slipped early or stopped: one step back.
- No camera data: use reps completed, whether the session was finished, and mood.
- Occasionally end with a few unpaced minutes, so the ceiling stays measured.

## Out of scope

Pose-derived form signals (squat depth, jump height per rep) until the timing loop runs and
the camera is used regularly. No separate analytics store: SQLite holds the data, and
DuckDB can read the SQLite file directly for ad hoc analysis.

## Test data

`assets/js/hooks/pose_burpee_hsmm_user_labeled_fixture.mjs` covers about two reps. A full
camera session (program snapshot, `cadence_ms`, trace chunks) exported from production into
`test/fixtures/pose/` would let the metrics be checked against a real workout.
