# The coach card, and the streak on Progress

Status: approved by the owner on 2026-10-14. Refines the Home half of
`docs/specs/2026-10-14-coach-on-home-design.md`; where the coach lives is unchanged (Done's
result opens it).

## The card

The coach is one card with two faces. It turns over on its vertical axis (a plain swap
with reduced motion); both faces sit in one grid cell, so the card keeps one height.

```
Front                                   Back
┌──────────────────────────────────┐   ┌──────────────────────────────────┐
│ This week                     📖 │   │ What the coach knows about you ↺ │
│ ● Six-count            Mon, 20 min│   │ Trains mornings. Left knee sore  │
│ ● Navy SEAL            Tue, 20 min│   │ after jumps.                     │
│ ○ Six-count                20 min │   │                                  │
│ ○ Navy SEAL                20 min │   │                                  │
│ ──────────────────────────────── │   │ ──────────────────────────────── │
│ Keep Thursday unbroken; aim 135. │   │                          🗑  (✓)  │
│ │ Can Thursday be mornings?      │   └──────────────────────────────────┘
│ │ Yes, 7:00.                     │
│ (Make Saturday easier) (Add Sun) │
│ Message the coach           (↑)  │
│ Goals waiting      ✕ (✓)         │
└──────────────────────────────────┘
```

- **The week's window** (`WeekWindow.lay_out/2`): this week's sessions done, in order, then
  what is left of the weekly target in 20-minute sessions, each to the burpee type with
  less time so far (as `Coach.Policy` picks the next workout). Warmups do not count. It
  needs no model, so it is always right.
- **The coach's note** explains what the rest of the week should aim for, given what is
  left of the window and the active goals. A completed session admits a new summary.
- **The conversation, the predicted replies, the message field and waiting goals** stay on
  the front.
- **The back** is the coach's notebook: the notes fill the face; trash clears, the check
  saves. The book turns the card over; the U-turn turns it back. The hidden face is inert.

## The streak

Progress shows a flame and the weeks in a row at the weekly target opposite the level,
only while there is a run (`History.streak/1`). The week in progress counts once it is
met and never breaks the run while it is not.
