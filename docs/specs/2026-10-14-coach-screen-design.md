# Coach: its own screen, with predicted replies

Status: approved by the owner on 2026-10-14. Supersedes "The coach, open (D2)" in
`docs/specs/2026-10-13-progress-headline-design.md`.

## Why its own screen

Progress looks back ("am I on track?"); the coach is a conversation about what comes next.
Mixing the two made Progress read wrong, so the coach line on Progress now leads to
`/coach`, the coach's own screen. Escape and the Progress link return to Progress; the
week's progress on top leads Home, as on every screen.

```
0 / 80 min                                   12–18 Oct
──────────────────────────────────────────────────────
Coach                                         Progress

Protect Thursday. Keep it unbroken…         ← the note
│ Can Thursday be mornings?                 ← last exchange
│ Yes. 7:00, same sets.
(Move it to Friday) (Why Thursday?)         ← predicted replies
Message the coach                     (Send)
Goals waiting for you   Confirm / Dismiss
What the coach knows about you            ⌄
```

## Predicted replies

The pills are what the coach expects the athlete to say next, written by the model:

- each coach reply carries up to three `suggestions` with the reply;
- the weekly summary carries up to three `replies` for when the screen is first opened;
- `Coach.Suggestions.clean/1` keeps at most three trimmed, distinct phrases of 60
  characters or fewer, whatever the model sends.

The pills show the last exchange's suggestions, else the note's (before any exchange), else
two plain asks ("Make the next one harder", "Make the next one easier"). Tapping one sends
it. Both are stored with the exchange and the summary, so they survive a reload.
