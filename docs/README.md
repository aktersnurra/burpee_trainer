# Documentation

| Path | Contents |
|---|---|
| `specs/` | Design specs for the code as it is, named `YYYY-MM-DD-<topic>-design.md`. The umbrella for the current architecture is `specs/2026-10-05-coach-first-architecture-design.md`. |
| `plans/` | Implementation plans still in progress, named `YYYY-MM-DD-<topic>.md`. A plan is deleted once it is complete; version control keeps it. |
| `guides/` | Runbooks and checklists: browser E2E, pose capture smoke test, replaying recorded camera sessions (`pose-corpus.md`). |
| `guides/studio-e2e.md` | The browser check for Home's swipes and the studio: what it asserts and how to run it. |
| `guides/ios-device-check.md` | What only a phone can check: the keyboard dock, iOS gestures, the launch screen. |
| `guides/mcp-analytics.md` | Comparing deterministic MCP history ranges, units and coverage. |
| `ui.md` | The visual system: palette, typography, spacing, and how screens connect. |
| `testing.md` | Test policy and the core-flow suite. |
| `branding/` | Burpee icon master artwork, exports, and browser/home-screen integration notes. |

Local notes, reviews, evidence and scratch documents belong in the git-ignored `.docs/`
at the repository root, not here. When the code a spec describes is removed, delete the
spec.
