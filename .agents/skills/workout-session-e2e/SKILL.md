---
name: workout-session-e2e
description: Use when browser-verifying workout session flow, offline behavior, completion scrolling, camera degradation, draft restoration, Save idempotency, or deferred trace upload in this repository.
---

# Workout Session E2E

## Canonical procedure

Read `../../../docs/testing/workout-session-e2e.md` completely before acting.
That runbook is the source of truth for all agents and browser controllers.
Do not copy or reinterpret its scenario steps here.

## Required behavior

- Prove the server PID belongs to the current workspace and revision.
- Use an isolated named browser profile, one origin, and one test identity.
- Create and clean data only through `scripts/e2e/`.
- Measure completion scrolling and verify both accessible and computed visual
  pressed-state changes.
- Verify exactly one saved row for the captured `client_session_id`.
- Preserve redacted evidence under `.e2e-artifacts/`.
- Report unavailable browser, network, or camera capabilities as `blocked`.
- Never substitute unit or integration results for missing browser evidence.

## Completion

Report scenario verdicts, evidence paths, database verification, cleanup result,
and explicit gaps. Do not claim success from a click alone; verify the resulting
URL, DOM state, network boundary, or database state required by the runbook.
