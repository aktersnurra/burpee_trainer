# Light screens: Home, Edit, New, Finish, Progress, Coach

Status: approved in review of the screens mockup (artifact "Burpee Trainer Screens", v62,
2026-11-06). The mockup's source is kept locally in `.docs/mockups/screens.html` (rendered) and
`.docs/mockups/screens_app_pages.py` (the generator: markup and CSS per page); the "Now" side
is `.docs/mockups/now/*.jpg`. Where this spec and the mockup disagree, the mockup wins.

## Palette

One palette across every view. A colour means one thing.

| Token | Hex | Means |
|---|---|---|
| `--ink` | `#262722` | text and the one action (Play, Run, ✓) |
| greys | `--muted`, `--line`, `--fill` as now | labels, lines, quiet fills |
| `--six` | `#1f3f73` navy | six-count: its days, its solid line, its picked type |
| `--seal` | `#86aee0` sky (lines and marks `#5f8fcf`) | Navy SEAL: its days, its dashed line, its picked type |
| `--cobalt` | `#2f63ad` | as a tint: what the coach changed; an OK session |
| `--good` | `#3f9161` | a Good session |
| `--clay` | `#b46958` | at stake: abort, delete, where you stopped; a Rough session |
| `--amber` | `#c48a24` | Finish's tags; the streak's flame |

The old `--changed` clay underline and the chart series colours (`#245b70`, `#c8641f`) go.

A choice is a soft tint of its colour with a thin ring of it and text in the full colour
(`rgba(c, .16–.32)` fill, `inset 0 0 0 1px rgba(c, .45–.6)`), never a solid fill:

- New's type: navy for six-count, sky for Navy SEAL. Even / Unbroken takes the picked type's tint.
- Finish's mood: clay Rough, cobalt OK, green Good. Finish's tags: amber.

## Shared pieces

- **The writing box.** Every place you write (Home done's coach, Edit, New's request, Finish's
  note, the Coach page) is one box: `--radius-surface` corners, about two lines tall at rest
  (84px), placeholder at the top left, growing with its text. Where it sends on its own (coach,
  Edit) the send key sits in the bottom-right corner. New's request and Finish's note go with ✓
  and have no send key.
- **The foot.** A screen you leave with a result has X (or trash) on the left and the ✓ pill on
  the right (New, Finish). Actions are icons, not words.
- **Close.** Edit's corner is an X, as New's foot; closing Edit with a proposal still keeps it as
  today's workout.
- **The diff.** What a proposal changed: the old value struck through in grey, the new value on a
  soft cobalt highlight.
- **Suggestions** above Edit's and the coach's box are one row that scrolls sideways, fading at
  its right edge; a tap sends that line as if typed.
- **The memory sheet** is the workout picker's bottom sheet (88%, grip, x-mark, scrim, Escape).

## Screens

- **Home.** Name, then `20 min · 15 reps`, then the structure as a sentence, `5 sets of 3 · 4:30
  rest`; no `every 8s`, no `best 40 in 20 min` (best moves to Progress). No chart, no display
  numerals.
- **Home, done.** The result (type, `104 reps · 20:00`, `4 sets of 26, all done`, the week line),
  the week's sessions as rows with the type's mark, then the chat: the coach plain from the left,
  you in a bubble on the right. The coach's opener is the chat's first message. "Coach ›" heads
  the chat and opens the Coach page; the bookmark is only ever the coach's memory.
- **Edit.** Your request as a bubble, then one workout block with the diff (`20 min · ~~15~~ 150
  reps`, why, `2 sets of 75 · 7:30 rest ~~was 5 sets of 3~~`), the set table with changed cells
  highlighted, Run as the play pill, suggestions and the box at the foot. X in the corner.
- **New.** Title, type pills (tinted by type), the big duration and reps steppers, the structure
  sentence (`One rep every 27 s, all the way`; `4 sets of 11 · 4:43 rest` for Unbroken) updating
  as you step, then rows labelled like settings: Sets (Even / Unbroken), Set size (Unbroken only),
  Pace (− 8.0 s +). Then the request box. Foot: X left, ✓ right; no chevron at the top.
- **Finish.** `Ended early` (or the plan's name), the count stepper, `of 15 reps · 10:20 of
  20:00`, `3 of 5 sets`, who counted, mood pills (coloured when chosen), tags (amber), the note box,
  trash left and ✓ right. Trash asks in place as Abort does in the runner: the page steps back, ✓
  shrinks away, trash slides to the middle in clay with "Delete this session?" above; a second tap
  deletes, anything else lets go.
- **Progress.** The week bar; `Level 1A` as the one headline with the streak (`3 🔥`)
  opposite, the coach's look-back at the training history as its caption (a link to the Coach
  page; nothing when there is none); "Best in 20 minutes" over two columns, each with the type's mark and name, the best
  (30px), `✓ 1B needs 50`, and the goal when it has one; "Days you trained": a GitHub-style grid,
  square cells, a column a week from Monday, as many weeks as fit (18 on a phone), Mon/Wed/Fri
  labels, month labels, each day navy / sky / split diagonally for both, a key with the total
  minutes; "Reps per 20 minutes": the last 12 weeks, no window tabs or session list, a point
  opening its session (with its trash) under the chart; one chart, close to square, six-count on the left axis as a solid navy line, Navy SEAL on the
  right axis as a dashed sky line, each axis labelled in its colour.
- **Coach.** A page of its own, reached from Home's "Coach ›" and from Progress's look-back.
  Back chevron, "Coach", the memory bookmark on the right. The week as one card, closed to "This
  week" and its minutes against the target, open on its sessions (no week bar under the header),
  then the chat (the same as Home done's), suggestions, the box. From Progress the look-back is
  the first message. The bookmark opens the memory sheet: "About you" and "Coaching notes", each
  with how full it is, the lines read only, "To change a line, tell the coach." at the
  foot; a line the coach just changed is highlighted. Back returns where you came from.

## Runner

The mockup draws a slim filled figure because it has no camera; in the app the feed shows you, so
only the pose over it changes: a fine line with a soft glow, ringed joints and a ring round the
head. While the camera looks for you a lit scan line passes down your body; when it has you the
line turns green and glows and the joints fill. Reduced motion stops the scan.

## Out of scope

No new data. Every number shown already exists in the app (levels, bests, goals, streak, week
sessions, memory parts and their limits).
