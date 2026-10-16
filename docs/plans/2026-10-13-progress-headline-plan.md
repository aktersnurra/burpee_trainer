# Plan: Progress, one headline

Spec: `docs/specs/2026-10-13-progress-headline-design.md`. One jj change per step, each
with tests first, `mix precommit` green and a Chrome check at phone width.

1. **Headline (D).** `BurpeeTrainer.ProgressHeadline` (pure): picks the headline from
   active/achieved goals, measured sessions and today. Progress renders it: title row with
   level, headline, coach line, other goals as rows. Streak and the goal list go. Coach
   line opens the coach in place. Weeks start at the first week with a session.
2. **Coach line copy.** Summary prompt asks for the next action without the headline's
   numbers; the fallback keeps only last week's shortfall.
3. **Goal reached, no goal, first week (D4–D6).** `BurpeeTrainer.NextGoal` (pure) from
   `Levels`; Set this goal / Not now / Choose my own.
4. **Coach open (D2).** Migration and `Coach.Exchanges` (store/latest); the reply is stored
   after `Agent.run`; one-tap replies; restyle without the paper panel; notebook renamed
   "What the coach knows about you".
5. **Course (D3).** `BurpeeTrainer.GoalCourse` (pure, property tests): weekly bests,
   least-squares slope, projected date, honesty rule; the mini chart.
