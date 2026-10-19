# Plan: Fatigue insights and progression

Spec: `docs/specs/2026-10-19-fatigue-insights-design.md`. Builds on the planner prompt in
`planner-recent-best-cap`. Each step tests first, `mix precommit` green.

1. **Metrics.** Done. `BurpeeTrainer.Workouts.Fatigue` (pure, property tests): schedule, nearest
   matching, coverage, the fields in the spec.
2. **Persistence.** Migration for the new session fields; computed at completion in place of
   the zipped `cadence_decline`/`pace_delta_sec`; `recovery_delta_sec` filled.
3. **Exposure.** Planner context (`Coach.Tools.History.summary/1`) and MCP `query_history`.
4. **Progression rule.** Planner prompt per the spec.
5. **Real session.** Export one full camera session into `test/fixtures/pose/` and pin its
   metrics in a test.
