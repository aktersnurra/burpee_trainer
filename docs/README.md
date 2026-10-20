# Documentation

| Path | Contents |
|---|---|
| `specs/` | Design specs for the code as it is, named `YYYY-MM-DD-<topic>-design.md`. The umbrella for the current architecture is `specs/2026-10-05-coach-first-architecture-design.md`. |
| `plans/` | Implementation plans still in progress, named `YYYY-MM-DD-<topic>.md`. A plan is deleted once it is complete; version control keeps it. |
| `guides/` | Runbooks and checklists: browser E2E, pose capture smoke test. |
| `ui.md` | The visual system: palette, typography, spacing, and how screens connect. |
| `testing.md` | Test policy and the core-flow suite. |

Analytics: [MCP usage, runtime preflight and trace privacy](guides/analytics-agent.md) ·
[opt-in evaluation](guides/analytics-evaluation.md).

Local notes, reviews, evidence and scratch documents belong in the git-ignored `.docs/`
at the repository root, not here. When the code a spec describes is removed, delete the
spec.
