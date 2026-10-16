# Progress: one headline

Status: approved direction on 2026-10-13 (canvas "Progress directions", boards D and
D2–D6). Supersedes the goal instruments and status row of
`docs/specs/2026-10-13-cockpit-flows-design.md` § Progress. Type, lines and actions follow
`docs/ui.md`.

## The screen's job

Progress is a status screen: "am I on track?". It leads with one headline number, says
what to do in one coach line, and keeps the record below. Each fact appears once.

```
Progress                               Level 1A

130 / 150                      ← the headline, 64px
Six-count in 20 min, by 9 Nov
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Protect Thursday. Keep it unbroken…          ›   ← the coach line; opens the coach

──────────────────────────────────────────────
Navy SEAL, 60 by 10 Jan                     20   ← other goals, one quiet row each

Minutes each week                          Weeks | Days
Reps per 20 minutes                        Chart | Sessions
```

Sizes: 64px for the headline number only, 28px for the page title, 16px for everything
else. Level sits beside the title; the streak is dropped (it repeated the weekly record).

## What the headline shows

The first that applies:

1. **Goal reached.** A goal achieved in the last 7 days: the best reps toward it, "Goal
   reached 2 Nov, a week early" (or "on 9 Nov" when not early), a full bar, and the next
   goal (below) with Set this goal and Not now.
2. **Active goal.** The active goal with the nearest date: "best / target", what and by
   when, a bar, and the course (below) when it is honest to show one.
3. **No goal, three or more measured sessions.** Your best six-count in 20 min (Navy SEAL
   when that is all you do), and the next goal with Set this goal and Choose my own.
4. **One or two measured sessions.** The first measured result as "your starting point",
   and one line: two more sessions and the coach suggests a goal. No charts yet.
5. **Nothing measured.** The existing empty state.

"Best" is `Insights.Metrics.goal_best/2` for a goal; for no goal, the most reps in one
session of 20 minutes or less of that type. "Measured" means it has a reps-per-20-minutes
value (`History.points/1`).

### The next goal

Deterministic, never a model call: the next level landmark above the best for that type
(`Levels`: six-count 50, 100, 150, 200, 250, 275, 325; Navy SEAL 20, 40, 60, 80, 100, 120,
150), in 20 minutes, six weeks from today. Above the last landmark: best + 10%, rounded up
to 5. Set this goal creates it as the active goal (`Goals.create_goal/2`, baseline = the
current best today). Not now hides it until the next page load; Choose my own opens the
coach with its field focused.

### The course (D3)

Shown under an active goal only when honest:

- the goal's type has a best per week (reps per 20 minutes) in at least three of the last
  eight weeks;
- a least-squares line through those weekly bests rises.

The projected date is where the line reaches the target. It reads "On course for 2 Nov"
when that is on or before the goal date, otherwise "At this pace, 30 Nov". The mini chart
shows the weekly bests, the target as a dashed line, the projection as a dashed segment
to the projected date. When the rule does not hold, nothing is shown.

## The coach line

The coach's latest summary, one or two sentences that say what to do, never restating
the headline's numbers. Tapping it opens the coach in place (D2). The summary prompt asks
for the next action rather than progress numbers. The deterministic fallback keeps only
last week's shortfall ("Last week: 50 of 80 minutes."), which nothing else on the page
shows; with no shortfall there is no fallback line.

With nothing to summarize, the line reads "Set a goal with the coach".

## The coach, open (D2)

Under the coach line, in place, no panel or card:

- the last exchange: your message, then the coach's reply, behind a thin rule;
- two replies you can send with one tap: "Make the next one harder", "Make the next one
  easier";
- the field, "Message the coach", with Send once there is text;
- goals waiting for Confirm or Dismiss;
- "What the coach knows about you", the notebook, collapsed.

The last exchange is stored (`coach_exchanges`: user, message, reply, inserted_at), so it
survives a reload. Only the latest is shown.

## The record

"Minutes each week" shows only weeks from the first week with a session, never a row of
empty cells. The density chart and sessions are unchanged.

## Out of scope

Model-written reply suggestions, more than one stored exchange, and Home.
