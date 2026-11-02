# Edit and New as a chat, swipes on Home, and a box that rides the keyboard

Status: requested by the owner on 2026-10-29. Replaces the inline Edit and New forms of
`docs/specs/2026-10-13-cockpit-flows-design.md`; what is reviewed, approved and saved is unchanged.

## The problem

Each time the owner asked to improve a proposal, the request was read against the workout the
design started from, so every follow-up reset the work. Edit and New were forms laid over Home,
with a way back that discarded the proposal.

## Home: a tap each, and a swipe

Swap, Edit and New are a button each on Home (`.home-corner`), whether the workout is opened or
not: along the bottom edge on a phone, at the top-left corner on a wide screen. Each is one tap
from Home. `HomeGestures` (`assets/js/hooks/home_gestures.mjs`, on the whole Home screen) adds the
swipe for Swap.

- **Right** opens the swap list as a drawer, as in the Claude app: the page slides right
  (`#home-page` moves with `left`, not a transform, so the fixed drawer stays put) and the list of
  workouts takes the space it leaves. A swipe left, or a tap on the page, closes it. Choosing a
  workout previews it and confirms as before.
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
              (▶ Run)                ← under the card
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

## New: one form

New opens on one form, in the column the chat that follows it takes: burpee type as a choice of
two side by side, then duration and reps, each a number to type with a round button either side
that moves it by a step (held, it keeps stepping: the `HoldRepeat` hook). Style (a choice of two),
for unbroken sets the most reps in one set (no limit to start), and pace fold under a **More** row
whose summary reads them; most workouts leave them as suggested. Folded, they are still in the
form and sent. Then an optional note and **Create workout**. Back from the form leaves; there is no close
button. `NewWorkoutForm` (pure but for the suggested reps) holds the rules; `Coach.NewDefaults`
holds what each value starts from.

- **Duration** starts at 20 minutes, or at what the week has left if that is less, and steps by
  five up to what is left, which is always one of them. Never past the week's 80 minutes; a value
  typed is kept within that.
- **Reps** start from the athlete's progression for the type (a recent comparable session, within
  the planner's ceiling), else their recent best, else the next level's landmark, scaled to the
  duration. They step by five up to 50 and by ten from there; the last step up stops at the most
  that fits.
- **Set size** (unbroken only) steps in fives below the reps, then no limit; a limit at or above
  the reps is no limit. It is a constraint: `WorkoutRequest.max_set_reps` tells the coach and
  rejects a layout with a longer set (after the one correction), and a follow-up keeps it unless it
  is changed.
- **Pace** starts mid-reference for the type (4.5 s six-count, 8 s Navy SEAL), or faster when the
  reps leave little room to recover. It steps by half a second.

Reps and pace follow the duration and type until the athlete sets them; after that they stay as
set. Movement alone must fit the duration: the value being changed is capped at what the others
leave room for, and a change of duration or type lowers the reps when they no longer fit. Under the
reps the form says what the values come to ("11:15 moving · 3:45 recovering",
`NewDefaults.budget/3`).

A value typed is sent when the typing pauses or the field is left; Create applies whatever the form
holds, so a value typed and sent with Enter counts. The note goes to the coach with the values,
which are not said again in the chat: the proposal's card shows what came of them. Back from a
proposal, or from the request in flight, is to the form as it was.

## Run

A proposal's card has Run under it, and nothing else: **Run** saves the proposal, makes it today's workout
and starts it, as Home's play does, with the camera and warmup choices the device remembers from
Home; the chat shows no toggles.

A proposal changes only by asking the coach in the box under it; there is no editing its numbers
by hand. To save typing, the coach offers up to three asks it expects next as quiet pills just
above the box ("Even out the rests", "Add a 1-minute rest at 10:00"): `suggestions` in the same
`workout_layout` response, so no extra call, kept short and distinct by
`WorkoutLayout.suggestions/1`. A tap sends one as a follow-up, exactly as if it were typed. Every proposal is marked against the one it replaced (`previous` in `Flow`). Leaving the session screen discards the session if it was started by mistake.

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
