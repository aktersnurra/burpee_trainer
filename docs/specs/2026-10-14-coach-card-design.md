# The coach section, its memory, and the streak on Progress

Status: approved by the owner on 2026-10-14. Refines the Home half of
`docs/specs/2026-10-14-coach-on-home-design.md`; where the coach lives is unchanged (Done's
result opens it).

## The coach section

The coach is a section of Home under Done's result, not a card: nothing else in the app
is boxed. A hairline sets it off; it shares the column's edge.

```
          Six-count
       20:00 · 130 reps
        Done for today.
──────────────────────────────────────
Keep Thursday unbroken and aim for 135.   ← the coach's word leads
— Six-count               Mon · 20 min    ← Progress's rows
— Six-count               Tue · 20 min
- - Navy SEAL                   20 min    ← left: muted
──────────────────────────────────────
                I train evenings now  ←   you: a soft bubble on the right
18:00 then.                               ← the coach: plain, on the left
🔖 Noted: Trains at 18:00
(Make Saturday easier) (Add Sunday)
Message the coach                    ↵
Goals waiting      ✕ (✓)
```

- **The week's window** (`WeekWindow.lay_out/2`): this week's sessions done, in order, then
  what is left of the weekly target in 20-minute sessions, each to the burpee type with
  less time so far (as `Coach.Policy` picks the next workout). Warmups do not count. It
  needs no model, so it is always right.
- **The coach's note** explains what the rest of the week should aim for, given what is
  left of the window and the active goals. A completed session admits a new summary.
- **The conversation** reads as a chat: your messages in a soft bubble on the right, the
  coach's replies plain on the left, what it noted or forgot as quiet lines between.
- **The predicted replies, the message field and waiting goals** follow.

## The coach's memory

Superseded by `2026-10-30-coach-memory-design.md` (two bounded parts and a memory tool, as
in the Hermes agent). What follows is the earlier design.

There is no notebook to read or edit. The coach keeps its own memory:

- **One note per fact** (`coach_notes`): a sentence of up to 160 characters. A forgotten
  note keeps its date (`forgotten_at`), so the thread can say so.
- **Kept after events** (`Coach.MemoryJob`): after each exchange, and after each completed
  session with feedback (notes, tags, mood, limiter, preference), the model reads the
  notes and the event and returns ops: add, forget or replace. Without a provider nothing
  changes. The chat no longer writes memory mid-reply.
- **Made safe** (`Memory.Ops.plan/2`): at most five ops count; a note must be new
  (ignoring case and spacing), non-empty, within 160 characters and free of internal ids;
  only active notes can be forgotten; past twenty notes the oldest are forgotten.
- **Seen in the thread**: what the coach noted or forgot reads as a quiet line ("Noted:
  …", "Forgot: …") after the exchange that caused it, live, over PubSub. The owner
  corrects the memory by saying so.
- **Read by the coach** as `memory` in its context: the notes, oldest first.
- The notebook's lines became notes in the migration (list marks and heading lines dropped).

## The streak

Progress shows a flame and the weeks in a row at the weekly target opposite the level,
only while there is a run (`History.streak/1`). The week in progress counts once it is
met and never breaks the run while it is not.
