defmodule BurpeeTrainer.Analytics.Schema do
  @moduledoc "Versioned, non-user-specific analytics schema and metric definitions."

  @columns ~w(session_id completed_at local_date source_kind burpee_type capture_mode reps_actual reps_planned duration_sec_actual duration_sec_planned credited_seconds warmup pace_sec reps_per_20_min)

  def columns, do: @columns
  def version, do: 1

  def text do
    """
    burpee://analytics/schema (version 1)
    One table: sessions. Only the authenticated owner's authoritative completed sessions,
    completed_at <= as_of. Snapshot is immutable across queries; no production database access.
    Columns in order:
    session_id INTEGER: owned session ID, evidence link only.
    completed_at TEXT: UTC ISO8601 timestamp.
    local_date TEXT: YYYY-MM-DD in the captured owner timezone, including DST.
    source_kind TEXT: plan/video/manual.
    burpee_type TEXT: six_count/navy_seal; compare separately.
    capture_mode TEXT: tracked/timed/logged; compare separately.
    reps_actual INTEGER NULL: actual reps, never planned substitutes.
    reps_planned INTEGER NULL: prescribed reps.
    duration_sec_actual INTEGER NULL: actual measured seconds.
    duration_sec_planned INTEGER NULL: prescribed seconds.
    credited_seconds INTEGER: History.credited_seconds, max(actual seconds or 0, 0)
      for authoritative non-warmup sessions; 0 for warmups.
    warmup INTEGER: 1 exactly when canonical tags == "warmup", otherwise 0.
    pace_sec REAL NULL: actual seconds / actual reps only when both positive.
    reps_per_20_min INTEGER NULL: round(actual reps / actual seconds * 1200),
      only when both positive, matching Stats.Series normalization.
    Default comparisons exclude warmups and separate types/capture methods. Normalized
    throughput is extrapolation, not a 20-minute PB or comparable endurance proof. PB
    eligibility cannot be certified from these columns. Observations do not establish causality.
    Clarify what 'improved' means: volume, frequency, pace or comparable-session performance.
    SQL: one read-only SELECT with operators/CASE/subqueries and sum,count,avg,min,max,
    round,abs,coalesce,nullif. No metadata, PRAGMA, recursive CTEs, unsafe functions or writes.
    Limits: 5000 snapshot candidates / 1 MiB; SQL 4096 UTF-8 bytes; helper 1000ms / 128MiB;
    results 100 rows / 16 columns / 1024 bytes per cell / 8192 encoded bytes. Overflow refuses,
    never silently truncates. Missing actuals remain NULL.
    """
  end
end
