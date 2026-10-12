# Cockpit flows: Home and Progress show only what the moment needs

Status: approved by the owner on 2026-10-13. Builds on `docs/ui.md` (type, lines, actions,
words, motion) and `docs/specs/2026-10-10-frictionless-home-design.md`.

## Principle

Each screen answers one question and shows only what that answer needs. Everything else
opens in place, one tap away, and never hides what the owner was looking at.

- Home answers "what do I do now?": today's workout and Start.
- Progress answers "am I on track?": goals as instruments, then the coach, then the record.

## Home: one centred column

Home keeps its centred column. The workout title, its totals, Start and the quiet
Edit · Switch · New sit in it; New, Edit and Switch open inside the same column. A title
always sits in the hero's place.

### Switch opens in place

Switch no longer covers the page. The list of workouts opens inline where the set table
was; the workout title, totals and actions stay above it (inactive while choosing), and
the current workout is marked in the list. Close, Escape or picking a workout returns to
the table. No backdrop.

### Edit keeps the workout in view

Edit no longer replaces the workout. The title, totals and set table stay; the actions
row gives way to one field under the table, named by its placeholder ("e.g. two sets of
25, a minute's rest between"), with Cancel and Review.

Review redraws the same table in place from the proposed workout, with every value that
changed from the current workout marked. The totals line shows the proposed totals, with
changed parts marked. Edit, Cancel and Save follow. Save replaces today's workout; Cancel
returns to the unchanged workout.

A changed value is a cell whose text differs from the cell in the same row and column of
the current table, or any cell in a row the current table does not have.

### New sits where the title sits

"New workout" takes the workout title's place, at the title size and centred, and the
form follows in the same column. Cancel returns the workout to that place.

## Progress: goals are instruments

Each active goal is one instrument instead of a sentence:

```
150 six-count in 20 min                 by 9 Nov
[██████████████████░░░░░]   120 / 150     27 days left
```

- The bar fills to the best 20-minute reps for that burpee type in the goal's window
  (the same density the chart plots), capped at the target.
- "120 / 150" leads as numbers; days left is the only other words.
- With no measured session yet the bar is empty and reads "no 20-minute set yet".

The coach summary, weeks and density follow as today. The coach area itself is redesigned
separately in the coach presence spec.

## Out of scope

The session runner, the coach conversation, and any new data beyond the best density per
burpee type.
