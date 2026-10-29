# Edit and New as a chat, swipes on Home, and a box that rides the keyboard

Status: requested by the owner on 2026-10-29. Replaces the inline Edit and New forms of
`docs/specs/2026-10-13-cockpit-flows-design.md`; what is reviewed, approved and saved is unchanged.

## The problem

Each time the owner asked to improve a proposal, the request was read against the workout the
design started from, so every follow-up reset the work. Edit and New were forms laid over Home,
with a way back that discarded the proposal.

## Home: two swipes

`HomeGestures` (`assets/js/hooks/home_gestures.mjs`, on the whole Home screen) turns a swipe into
the event a button already sends. The buttons stay for anyone who cannot swipe.

- **Right** opens the swap list as a drawer, as in the Claude app: the page slides right
  (`#home-page` moves with `left`, not a transform, so the fixed drawer stays put) and the list of
  workouts takes the space it leaves. A swipe left, or a tap on the page, closes it. Choosing a
  workout previews it and confirms as before.
- **Up** opens a sheet with two choices, Edit this workout and New workout. Down closes it.
- `swipe.mjs` recognises a stroke: 56px, at least 1.6 times more in its direction than across, under
  800ms. An upward stroke counts only when the page cannot scroll further, so it never fights a
  scroll. Strokes that start in a field, or an element marked `data-no-swipe`, are left alone.

## The studio

Edit and New take Home's place as a chat (`HomeStudioComponents`, `data-stage` on `#home-studio`).
A header carries the back button (it leaves with no change) and the workout or the answers so far.

```
‹  Edit workout
   Starter Navy Seal
╭ Today's workout ────────╮   ← the coach's first message: a card
│ Starter Navy Seal       │
│ table                   │
╰─────────────────────────╯
What would you like to change?
                 Make it 150 reps   ← you
(spinner) Working on it…
Two even sets with a breather.      ← the proposal arrives as a card
╭ Proposal ───────────────╮
╰─────────────────────────╯
              (Save) (▶ Run)         ← under the card
╭─────────────────────────╮
│ Change anything else? ↑ │
╰─────────────────────────╯
```

- The studio rises in; each message and the proposal card rise in as they arrive. The newest
  message scrolls to the top of the screen (`ChatDock`).
- **Each follow-up refines the latest proposal** (`Coach.prepare_refinement/4`, then
  `Coach.prepare_plan/4` with `base_definition:`), carried in the prompt as `current_proposal`; the
  workout the design started from stays only as provenance, so approval still verifies it.
  `HomeAuthoring.Flow` keeps what each follow-up replaced as `design_turns` and the ask in flight
  as `pending_turn`. A late answer is applied only while it is the work in flight.
- A follow-up that fails leaves the proposal on screen and the words in the box, and says so.
  Back works while the coach is on a follow-up and takes the proposal with it.

## New: one question at a time

New asks one question per screen, centred, with its progress above: burpee type and set style
(a card to tap, which answers and moves on), then duration, reps and pace, each a value you swipe
left and right (the buttons and arrow keys do the same; `SwipeValue`) with a Next, since nothing
says you are done. Back is one question back (out of the first); a close button always leaves.
`NewWorkoutSteps` (pure) holds the steps; `Coach.NewDefaults` holds what each starts from.

- **Duration** starts at 20 minutes, or at what the week has left if that is less, and moves in
  steps of five up to what is left, which is always one of them. Never past the week's 80 minutes.
- **Reps** start from the athlete's progression for the type (a recent comparable session, within
  the planner's ceiling), else their recent best, else the next level's landmark, scaled to the
  duration. They move by five and stop where movement alone would not fit the duration.
- **Pace** starts mid-reference for the type (4.5 s six-count, 8 s Navy SEAL), or faster when the
  reps leave little room to recover. It moves by half a second.

Then the chat opens on a message made of the answers, in the box and ready to send:

```
Six-count · Unbroken · 20 min · 75 reps · 4.5 s per rep
Additional request: ▌
```

The cursor sits after the prefix (`ComposerCaret`). Send works as it is, without text. Only what
follows the prefix reaches the coach as the athlete's request (`HomeWorkoutRequest.note/1`); the
choices come from the answers, so editing the first line changes nothing. Above the box the choices
are parts you can tap to change; what followed a changed answer is suggested again.

## The dock

`ChatDock` (`assets/js/hooks/chat_dock.mjs`) docks a composer at the bottom of the screen:

- On iPhone the keyboard shrinks the visual viewport and leaves the layout viewport alone, so a
  bottom-fixed box ends up behind it. The hook sets `--keyboard-inset` from `visualViewport` and
  lifts the dock by it; below 80px the change is the browser's own bars, not a keyboard.
- `--chat-dock-height` sizes a spacer under the conversation so its last line clears the dock.
- When the conversation moves on (`data-version`), the newest message scrolls to the top of the
  screen with its answer below it; reduced motion scrolls without animation.
- The dock holds Save and Run (the proposal's actions, now under its card) and the quick changes, so none scrolls
  away. The coach's message box uses the same dock.

## The coach reads like a coach

- `Coach.Voice` asks for a person, not a dashboard: start from what was just said, pick up what
  it knows in its own words, no trends or "insights", one thing at a time.
- The coach page answers across the gym floor, at most three sentences and one question.
- The note on Home is written from what the athlete told the coach (its notes and this week's
  last messages) as well as the metrics, and its look back names something specific or is empty.
- A change to the coach's memory writes the note again, so replying to the coach changes what
  it says next.
