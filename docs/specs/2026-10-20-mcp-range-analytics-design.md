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
authoritative sessions, with actual reps, elapsed/credited seconds, sample coverage,
local recorded/training days and per-type measured weighted pace. Preserve legacy
eligibility; do not compare mixed-type overall pace or confuse normalized throughput
with prescribed personal bests.

Task 3 exposes range/default/day/week/month groups and overall summaries; adds exact
request context, honest pagination and complete-aggregate cap refusal; preserves and
labels whole-week target policy; marks partial periods and explains omitted empty
periods. It also adds the static analytics resource and user guide. No unrelated
workout/session behavior changes are authorized.
