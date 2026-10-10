# Coach-first architecture (umbrella)

## Status

Implemented: all five sub-projects are complete on `coach-first`. Their implementation
plans were removed from `docs/plans/` once complete; they remain in version control at
commit `264b01877b73` (`docs/superpowers/plans/2026-10-05-*.md`).

Direction approved by the owner in conversation on 2026-10-05. This document records the
target architecture, the design principles every sub-project must follow, and the order of
sub-projects. Each sub-project gets its own spec → plan → implementation cycle; this
document is not implemented directly.

## Product intent

BurpeeTrainer is a personal training app that should need almost no time in the UI.
Opening it should show the one thing the owner wants right now. The best interaction is a
single button press: start today's workout, or see stats and insights. The app is also an
experiment in how far an LLM coach can be taken when it is bounded by rigorous,
deterministic validation.

## Target system

1. **Home state machine.** A pure function `Home.state(user, now)` returns exactly one state
   (resume a started session, save a pending offline completion, start today's workout,
   insights for a finished day, week complete), each with one primary action. The LiveView
   only renders it.
2. **History.** Completed-session snapshots, insights, and the entry point to the Coach page.
3. **LLM coach with tools.** One agent, bounded call budget, typed tools: read history,
   goals, library, and its notebook; `propose_workout` (validated by the compiler and the rest
   fitter, errors returned as tool results); `select_workout`; `note`; and `propose_goal`,
   which is offered **only** in Coach-page conversations and creates a pending goal the owner
   confirms with one tap.
4. **Client-side runner.** The JS bundle executes immutable compiled programs offline,
   including camera pose counting and video follow-along sessions.
5. **Database.** Ecto + SQLite, one authorization point (`current_scope`).

Supported features that are not in the five-part summary but stay: OIDC sign-in (Pocket ID),
video workouts (Home chooser Videos tab, `VideoLive.Show`, streaming, completion logging,
`mix burpee_trainer.add_video`), camera pose tracking and trace upload, levels, scoring,
milestones, and goals.

## Authoring pipeline (decided)

- The New form is the fastest input, not a separate generator. Its fields (type, style,
  reps, duration) become hard constraints in the typed request without an interpretation
  call. Optional free text adds nuance and is the only part that needs interpretation.
- The LLM chooses structure: set count, reps per set, which phase each set belongs to, and a
  relative weight for each ordinary rest.
- A pure **rest fitter** computes exact rest durations. Fixed pauses (for example an extended
  rest at minute 11 and another at minute 18) split the workout into phases with fixed time
  budgets. Per phase: `ordinary rest = phase budget − phase work`, distributed by the
  weights, rounded to milliseconds with the rounding remainder on the phase's last ordinary
  rest. Infeasible phases are reported with numbers; the fitter never changes sets.
- **Scope boundary:** the fitter only subtracts, distributes, and rounds. Any need to search
  or reshuffle structure belongs to the LLM. If the fitter ever needs more, stop and revisit
  the design.

## Design principles

- Functional core, imperative shell: pure modules (compiler, rest fitter, Home state,
  scoring, policy) carry the logic and have property tests; effects live at the edges.
- One authorization point: context functions take `current_scope` and every query is
  scoped by it. No repeated ownership re-checks per layer.
- Let it crash: no catch-all `rescue`/`catch` that converts bugs into domain errors.
- Every LLM output is validated by deterministic code before it can be saved or shown as
  fact. Numbers in insights come from computed metrics, never from model text.
- LLM calls are recorded (model, tools used, tokens, cost, outcome) for evaluation, replay
  fixtures, and cost tracking.
- Tests must catch regressions: full flows and property tests of the pure core. No tests of
  prompt strings, markup trivia, internal helpers, or removed code.
- No dead code, no test-only production APIs, no feature-flagged paths that never run.

## Sub-projects, in order

| # | Sub-project | Spec | Plan |
|---|---|---|---|
| 1 | Legacy cull + test policy | `2026-10-05-legacy-cull-design.md` | `plans/2026-10-05-legacy-cull.md` |
| 2 | Authoring pipeline (LLM layout + rest fitter) | `2026-10-05-authoring-rest-fitter-design.md` | `plans/2026-10-05-authoring-rest-fitter.md` |
| 3 | Home state machine + scoped authorization | `2026-10-05-home-state-machine-design.md` | `plans/2026-10-05-home-state-machine.md` |
| 4 | Coach agent: tools, notebook, goals, planned next workout (Oban), LLM call ledger | `2026-10-05-coach-agent-design.md` | `plans/2026-10-05-coach-agent.md` |
| 5 | Insights + evals | `2026-10-05-insights-evals-design.md` | `plans/2026-10-05-insights-evals.md` |

Sub-projects run strictly in this order; each plan assumes the previous ones are complete
and must re-locate code by module and function name, not by line number.

Each sub-project leaves the app working and `mix precommit` green.
