# Deterministic MCP range analytics

Approved scope: extend the existing history tools with comparable-session filters,
whole-range and optional day/week/month summaries, explicit coverage/context, and a
static analytics guide. No model calls, SQL agent, new endpoint or comparison engine.
Clients compare cohorts by making separate calls.

## Shared selection contract (Task 1)

`Mcp.Sessions.filter_schema/0`, `filter_keys/0`, and `filters(args, user, now)`
are shared by both tools. Duration bounds are nonnegative integers, inclusive,
and compare only `duration_sec_actual`, never planned values. Reversed duration
bounds and reversed explicit local date windows are errors. Explicit null is not
an omitted duration or warmup filter.

`warmup` is `include` (default), `exclude`, or `only`. Canonical warmup means
exactly `tags == "warmup"`, not a tag substring or trimmed/multi-tag match.
Exclusion retains NULL tags. Existing tag filtering remains separate; supplied
filters intersect.

Normalization returns the existing Workouts map plus `:min_duration_sec`,
`:max_duration_sec`, `:warmup` (string enum, always present), and `:as_of`
(the trusted supplied request clock, always present). `:from` is inclusive UTC
local midnight and `:before` is exclusive UTC midnight after the requested `to`
date. These boundaries remain distinct from the inclusive `:as_of` predicate;
a future `from` legitimately selects no rows. DST conversion uses UserTime.
The integration owner must capture one clock and reuse it in selection and metadata.
An as-of cutoff is not a repeatable snapshot across separate page calls.

Workouts preserves owner scope, completed state, descending completion/id order,
and opaque compound cursor semantics. SQL comparisons naturally omit NULL actual
durations when a bound is present. Current database source-snapshot constraints
forbid NULL actual duration on completed sessions, so database tests exercise zero
and actual/planned disagreement without disabling constraints. Missing-measurement
summary behavior belongs to the pure summary component.

## Remaining component contracts

Task 2 supplies `HistorySummary.summarize(sessions, timezone)` over trusted selected
authoritative sessions, with actual reps, elapsed/credited seconds, measurement coverage,
local recorded/training days and per-type measured weighted pace. Preserve legacy
eligibility; do not compare mixed-type overall pace or confuse normalized throughput
with prescribed personal bests.

Task 3 exposes range/default/day/week/month groups and overall summaries; adds exact
request context, honest pagination and complete-aggregate cap refusal; preserves and
labels whole-week target policy; marks partial periods and explains omitted empty
periods. It also adds the static analytics resource and user guide. No unrelated
workout/session behavior changes are authorized.

## Actual metrics producer (Task 2)

`Mcp.HistorySummary.summarize(sessions, timezone)` returns the summary; the caller
has validated the timezone (`Sessions.filters` does). Input is trusted,
owner-scoped authoritative session structs/atom-keyed maps with completion timestamps;
this pure producer neither queries nor infers authority, filters, or completeness.
The summary has string keys and a sorted `by_type` list with the same totals plus
`burpee_type`; nested entries do not recursively contain `by_type`.

- `actual_reps` and `elapsed_seconds` sum actual values, including selected warmups.
  Zero counts. The schema requires both actuals on completed sessions; planned values
  are never substituted.
- `credited_seconds` uses History credit (canonical warmups excluded); `minutes`
  floors total credit divided by 60, not each session.
- `recorded_days` counts distinct selected local completion dates. `training_days`
  counts those with positive credited work. Neither claims consecutive activity.
- `measurement_samples` counts sessions with both positive integer actual reps and
  seconds; `unmeasured_sessions` is its complement. `measured_average_pace_sec` is
  their total seconds / total reps, rounded to two decimals, including warmups.
  `best_normalized_reps_per_20_min` uses History/Series normalization (rounded integer
  reps at the observed throughput), including warmups. It is NOT a prescribed PB;
  manual, video and non-20-minute sessions can contribute.
- Legacy `reps`, `best_reps_per_20_min`, and `average_pace_sec` retain History.points
  eligibility AND canonical warmup exclusion. `legacy_measurement_samples` exposes
  that denominator; `warmup_sessions` exposes the canonical warmup count.
- Each average pace field is null when the sessions it is computed from (legacy or
  measured) contain more than one burpee type. `pace_comparability` is
  `mixed_burpee_types` when the measured sessions do, otherwise `single_burpee_type`;
  absent measurements still yield null pace/best metrics.
  Per-type summaries remain comparable. The legacy best field remains available for
  compatibility, but does not establish cross-type comparability or PB eligibility.

All totals describe only the supplied sessions. Group boundaries, empty-period
omission, partial-period markers, capture-mode context and range completeness remain
Task 3 responsibilities, not inferred by this producer.

## Integrated response contract (Task 3)

`history_stats` defaults to `range` (empty periods); `day`, `week`, and `month`
return only recorded groups and always an overall `summary`. Group totals consume
HistorySummary unchanged. Mixed-type legacy overall pace now returns null, the
necessary compatibility correction; explicit week/month legacy fields remain.
Periods include calendar `start`/`end` and `partial`, computed against normalized
UTC bounds and the single request clock, not against first/last recorded session.
Weekly target fields read History.weeks (and thus Week policy), unfiltered across
all owner types, with explicit `target_scope` and `target_seconds`.

`HistoryStats.fetch_all` refuses any page with continuation at the 100000-row aggregate
limit. Its optional limit is a lower-level pagination seam exercised with real
scoped rows, not mocked forwarding or 100001 fixtures. Successful aggregate context
is complete. Query context distinguishes continuation exhaustion from full range
returned: a final cursor page is never complete_range, and matched_sessions is
unknown/null except on a complete first page. Non-authoritative exclusions describe
only retrieved rows. No counts are invented for rows excluded by filters.

HistoryContext records requested filters and normalized applied predicates (workout
normalizes to plan_id/name), default warmup, UTC bounds, effective
cutoff inclusivity, timezone and as_of. This is not a repeatable multi-page snapshot.
The static analytics resource embeds the committed user guide at compile time and
contains no owner data; workout-format and unknown-resource errors are preserved.
