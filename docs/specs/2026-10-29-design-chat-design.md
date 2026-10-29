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
(a card to tap, which answers and moves on), then duration and reps, then, for unbroken sets, the
most reps in one set (no limit to start), then pace. Duration, reps, set size and pace are values
you swipe left and right (the buttons and arrow keys do the same; `SwipeValue`) with a Next, since
nothing says you are done. Back is one step back, out of the first; there is no close button.
`NewWorkoutSteps` (pure) holds the steps; `Coach.NewDefaults` holds what each starts from.

- **Duration** starts at 20 minutes, or at what the week has left if that is less, and moves in
  steps of five up to what is left, which is always one of them. Never past the week's 80 minutes.
- **Reps** start from the athlete's progression for the type (a recent comparable session, within
  the planner's ceiling), else their recent best, else the next level's landmark, scaled to the
  duration. They move by five and stop where movement alone would not fit the duration.
- **Set size** (unbroken only) moves in fives below the reps, then no limit. It is a constraint:
  `WorkoutRequest.max_set_reps` tells the coach and rejects a layout with a longer set (after the
  one correction), and a follow-up keeps it unless it is changed.
- **Pace** starts mid-reference for the type (4.5 s six-count, 8 s Navy SEAL), or faster when the
  reps leave little room to recover. It moves by half a second.

Under reps and pace the screen says what the choices come to ("11:15 moving · 3:45 recovering"),
the one number that tells whether a combination is sensible (`NewDefaults.budget/3`).

The last screen is what was chosen, each row a way back to that question, with two ways on:

- **Create workout** sends the choices as they are.
- **Add a request** opens the chat with an empty box, for a request only (Send works without a word).
  The answers are not said again: the screen before showed them, and the proposal's card shows what
  came of them.

Back from the chat, or from a proposal, is to the summary. The header carries only its title; the
rest of the screen says what it is about.

## Run

A proposal's card has Save and Run under it. **Run** saves the proposal, makes it today's workout
and starts it, as Home's play does, so the camera and warmup toggles sit beside it (the device
remembers them). Leaving the session screen discards the session if it was started by mistake.

## The dock

`ChatDock` (`assets/js/hooks/chat_dock.mjs`) docks a composer at the bottom of the screen:

- On iPhone the keyboard shrinks the visual viewport and leaves the layout viewport alone, so a
  bottom-fixed box ends up behind it. The hook sets `--keyboard-inset` from `visualViewport` and
  lifts the dock by it; below 80px the change is the browser's own bars, not a keyboard.
- `--chat-dock-height` sizes a spacer under the conversation so its last line clears the dock.
- When the conversation moves on (`data-version`), the newest message scrolls to the top of the
  screen with its answer below it; reduced motion scrolls without animation.
- The dock holds the quick changes and the box. The coach's message box uses the same dock.

## The coach reads like a coach

- `Coach.Voice` asks for a person, not a dashboard: start from what was just said, pick up what
  it knows in its own words, no trends or "insights", one thing at a time.
- The coach page answers across the gym floor, at most three sentences and one question.
- The note on Home is written from what the athlete told the coach (its notes and this week's
  last messages) as well as the metrics, and its look back names something specific or is empty.
- A change to the coach's memory writes the note again, so replying to the coach changes what
  it says next.
