# The coach on Home, and Progress per burpee type

Status: approved by the owner on 2026-10-14. Supersedes
`docs/specs/2026-10-14-coach-screen-design.md` and the headline in
`docs/specs/2026-10-13-progress-headline-design.md`.

## No navigation bar

The app is opened to train and closed again. Instead of tabs, Home shows what the moment
needs, and Progress is always one tap away on the week strip.

## The coach speaks when the day is done

Before training there is nothing to talk about; changing the workout is Edit's job. Once
the day is done, Home shows the result with the coach open under it, nothing to tap:

```
          Six-count
       20:00 · 130 reps
        Done for today.
──────────────────────────────────────
Keep Thursday unbroken and aim for 135.   ← the coach's report on the week
│ Can Thursday be mornings?               ← this week's conversation
│ Yes. 7:00, same sets.
│ Make it shorter
│ Thursday is now 15 minutes.
(Back to 20 next week) (Can I add Saturday?)   ← predicted replies
Message the coach                    (Send)
Goals waiting for you   Confirm / Dismiss
What the coach knows about you          ⌄
```

- The report is the weekly summary's note: how the week is going and what to change. A
  completed session admits a new summary job, so it follows the week.
- Every exchange is kept. The conversation shown is this week's (from the owner's local
  week start), oldest first, and the coach receives it as prior turns with each message.
- The pills are the last reply's suggestions, else the note's, else two plain asks.
- `/coach` redirects to Home.

## Progress: what happened

```
Progress                                Level 1B
Six-count is climbing ten reps a week.   ← the coach's look back (summary.review)
Navy SEAL hasn't moved since September.
──────────────────────────────────────
— Six-count          - - Navy SEAL
130                  38
of 150 by 9 Nov      of 60 by 10 Jan 2027
On course for 26 Oct On course for 21 Dec
12 weeks  Year  All time
Reps per 20 minutes          Chart  Sessions
150 ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ 60     ← both goals on one line
115  ●───●───●──●─●                  40
 80   ○ - ○ - ○ - ○                  20
Minutes each day             (a column a week)
```

- **The look back** is a second field the summary job writes (`review`), validated like the
  note; one that fails validation is left out, not the note. It shows only when present.
- **A gauge per type**, same shape for both (`ProgressGauges.for_types/4`): the active
  goal with the nearest date (best, "of target by date", its course when honest); else a
  goal reached in the last week with the next goal; else the best with the next goal;
  else the first result; else "No sessions yet". A reached or best gauge offers
  "Set N by date" for its type. A new goal set after one is reached shows at once.
- **A small chart per type**, stacked on one time axis, each named in its colour (the
  gauges' keys) and on its own scale, so neither line is read against the other's numbers.
  A scale tops out at the type's goal, drawn dashed; without a goal at the best rounded up.
  Sessions open in the charts' place.
- **The next level, in words.** Under the level, one line says what the next one takes ("Level
  1C: 100 six-count and 40 Navy SEAL in 20 minutes, both in one week"), and each gauge says how
  its type stands toward that same level ("Ready for 1C", "10 to go for 1C").
