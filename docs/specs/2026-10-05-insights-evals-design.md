# Insights and LLM evals

## Status

Sub-project 5 of `2026-10-05-coach-first-architecture-design.md`, written 2026-10-05.
Requires sub-project 4 (agent, ledger, Oban). Decisions marked **(default)** were made by the
spec author and are open for owner review.

## Insights

### Metrics (pure, deterministic)

`BurpeeTrainer.Insights.Metrics.compute(sessions, goals, today, timezone)` returns a map of
metric IDs to `%{value: number, unit: atom, label: String.t()}`. Initial set:

| ID | Meaning |
|---|---|
| `week.minutes` | Minutes completed this week |
| `week.target_minutes` | Weekly target (80) |
| `week.reps.six_count`, `week.reps.navy_seal` | Reps this week per type |
| `session.reps`, `session.duration_min`, `session.pace_sec` | The latest session |
| `pace.change_6w.<type>` | Change in seconds per rep vs. the average of the previous 6 weeks |
| `streak.weeks` | Consecutive weeks meeting the target |
| `goal.<id>.progress_pct` | Progress toward each active goal |
| `level.<type>` | Current level per type |

Values are rounded for display by one formatter, `Metrics.format/1`.

### Narration (LLM, validated)

- Oban job `Insights.NarrateJob` runs after each completed session (enqueued with the planner
  job). One LLM call with strict JSON schema:
  `{"headline": string, "points": [{"text": string, "metric_ids": [string]}]}`,
  at most 3 points, headline ≤ 80 characters, each text ≤ 160 characters.
- Validator: every `metric_id` exists; every number appearing in a text equals the formatted
  value of one of that point's cited metrics. Any violation rejects the whole insight.
- Rejected or failed narration falls back to a deterministic insight built from the same
  metrics (headline "Session saved", points for week minutes and the latest session).
- Stored in `session_insights` (`session_id` unique, `headline`, `points` JSON, `source`
  `llm | fallback`, `inserted_at`).

### Presentation

- Home in `{:done_today, _}` and `{:week_complete, _}` shows the latest insight headline
  under the primary Insights button.
- History's session detail shows the insight's points. No new screens.

## Evals

- `mix burpee_trainer.eval --suite authoring --max-calls N` runs fixed scenarios against the
  configured provider. It refuses to run without `--max-calls` and stops when the ledger
  count for its run reaches N.
- Scenario files `priv/evals/authoring/*.json`: a request (form fields and optional note) and
  expected hard constraints. Initial scenarios include the owner's cases (140 reps at 5 s with
  60 s at 11:00 and 40 s at 18:00; minute-long work+rest blocks; unbroken single set; Navy
  Seal 80 reps in 20:00).
- Metrics reported per scenario and in total: first-try fit rate, success after one repair,
  failure reasons, provider calls, tokens, cost. Results are written to
  `.e2e-artifacts/evals/<timestamp>.json`.
- `--record` saves each scenario's provider responses to `test/fixtures/llm/<scenario>.json`;
  the replay plug used by tests serves them, so full-flow tests use real model output without
  paid calls.

## Testing

- Property tests for `Metrics.compute/4` (no metric for missing data; week totals equal the
  sum of sessions).
- Validator tests: numbers not in cited metrics, unknown metric IDs, over-length text.
- Full flow: complete a session → narration job with a recorded response → Home shows the
  headline → History detail shows points; a fabricated number in the recorded response yields
  the fallback insight.
- Eval task tests with the replay plug only; no paid calls in tests.
