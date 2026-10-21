# Comparing training ranges through MCP

Read `burpee://analytics-guide`, then call `history_stats` twice with the same
cohort filters and different inclusive local `from`/`to` dates. Compare the
`summary` and `by_type` values and their measurement counts, not just minutes.
For example:

```json
{"from":"2026-09-01","to":"2026-09-30","burpee_type":"six_count","warmup":"exclude","min_duration_sec":600,"capture_mode":"timed","group_by":"week"}
```

Omit `group_by` for one range summary with no periods; use `day`, `week` or
`month` to inspect nonempty periods. `query_history` accepts the same filters
and returns inspectable sessions; follow its opaque `next_cursor` unchanged.

## Interpretation contract

- Filters intersect. Duration bounds are inclusive nonnegative ACTUAL seconds,
  never planned. Dates use the owner's timezone, including DST. Missing warmup
  means `include`; `exclude`/`only` use exactly `tags == "warmup"`, not substrings.
  Type, workout id/name, tags, actual rep bounds and capture mode also filter.
- `actual_reps` and `elapsed_seconds` sum actual values, including selected warmups,
  never planned ones. Zero counts toward them but not toward pace.
- `credited_seconds` uses the app's weekly credit rules, excluding canonical warmups.
  `minutes` floors total credited seconds / 60; use seconds for precise comparisons.
  `recorded_days` counts selected local dates; `training_days` counts dates with
  positive credited work. Neither is evidence of unrecorded activity.
- `measured_average_pace_sec` is total seconds / total reps over positive measured
  pairs, rounded to two decimals. `measurement_samples` counts those pairs;
  `unmeasured_sessions` counts the remainder. Each overall pace field is null when the
  sessions behind it mix burpee types (`pace_comparability` says whether the measured
  ones do); compare `by_type` instead. Keep capture mode comparable too:
  camera tracking, timer sessions and manual logs have different measurement sources.
- Legacy `reps`, `average_pace_sec`, and `best_reps_per_20_min` exclude warmups and
  require positive actual reps and seconds. `legacy_measurement_samples` exposes
  that count. Legacy reps can therefore differ from `actual_reps`.
  `best_normalized_reps_per_20_min` includes selected warmups and normalizes observed
  throughput; it is NOT a prescribed-workout personal best. Neither best field
  proves cross-type or cross-capture comparability.
- All aggregates include an overall `summary`. Explicit week/month retain legacy
  period fields, with additive metrics/context; mixed-type overall legacy pace is
  intentionally now null rather than a misleading pooled value.
- `partial` marks periods clipped by the requested range or current cutoff,
  including today's unfinished day. Weeks start Monday. Empty periods are omitted:
  no matching recorded sessions is not proof of zero exercise.
- Weekly `target_met` and `target_seconds` describe whole-week, all-type, unfiltered
  owner history as of this request, NOT the selected cohort. `target_scope` states
  this; target values come from existing Week policy including pro-rated signup weeks.
- `context` records requested filters (including the exact local dates), normalized
  applied filters (including default warmup), timezone, inclusive UTC start, exclusive
  UTC end, effective cutoff and whether that cutoff is inclusive. Future completions
  are excluded with the same captured `as_of` clock used in metadata.
- Successful aggregates are complete for the applied filters; over 100000 selected
  rows returns an error asking you to narrow the range, never a partial total.
  `returned_sessions`, `matched_sessions` where known, and non-authoritative exclusion
  counts describe coverage. Filtered-out rows are not counted as missing measurements.
- Query `continuation_exhausted` only means no later page remains. `complete_range`
  is true only for a first page with no continuation; a final cursor page is not the
  whole range. `matched_sessions` is null unless the response covers the whole range.
  Each page captures a new clock: `as_of` is NOT a repeatable snapshot; later edits,
  deletions or insertions may change subsequent calls.

These deterministic values do not infer trends, projections, causality or exercise
that was not recorded. No user rows are embedded in the analytics resource.
