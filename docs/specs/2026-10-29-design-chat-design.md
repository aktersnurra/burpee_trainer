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
A header carries only Back (⌄, since the studio rises over Home); the title is the workout's name in
Edit, and "New workout" in New, large under it. With a proposal on screen Back keeps it (saved, today's workout, back on Home); otherwise it leaves with no change.

```
‹  Edit workout
     Starter Navy Seal           ← the coach's first message: the workout as on Home
     20 min · 15 reps
   table
                 Make it 150 reps   ← you
(spinner) Working on it…
        Steady 150               ← the proposal, read the same way
   Two even sets with a breather.
   table
   (▶ Run)
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

New opens on one form of big numbers, in the column the chat that follows it takes: burpee
type as two words, then duration and reps, each a large centred number to type with a plain
button either side that moves it by a step (held, it keeps stepping: the `HoldRepeat` hook).
Style (a choice of two), for unbroken sets the most reps in one set, pace and an optional note
fold under one **More** line whose summary reads them; most workouts leave them as suggested.
Folded, they are still in the form and sent. **Create workout** sits at the foot. Back from the form leaves; there is no close
button. `NewWorkoutForm` (pure but for the suggested reps) holds the rules; `Coach.NewDefaults`
holds what each value starts from.

- **Duration** starts at 20 minutes, or at what the week has left if that is less, and steps by
  five up to what is left, which is always one of them. Never past the week's 80 minutes; a value
  typed is kept within that.
- **Reps** start a step past the athlete's best 20-minute pace for the type in the last eight
  weeks (five, or ten from 50), never more than the planner's 10% above it, scaled to the
  duration: a best of 40 opens on 44, of 100 on 110. When their latest session says to ease off
  (`Progression` `:ease`), the eased rate instead; with no recent session, the next level's
  landmark. They step by five up to 50 and by ten from there; the last step up stops at the most
  that fits.
- **Set size** (unbroken only) starts at the step nearest a tenth of the reps (15 for 150) and
  follows the reps until the athlete sets it. It steps in fives below the reps, then no limit; a
  limit at or above the reps is no limit. It is a constraint: `WorkoutRequest.max_set_reps` tells the coach and
  rejects a layout with a longer set (after the one correction), and a follow-up keeps it unless it
  is changed.
- **Pace** starts mid-reference for the type (4.5 s six-count, 8 s Navy SEAL), or faster when the
  reps leave little room to recover. It steps by half a second and is never faster than the
  graduated level: 20 minutes over its count (325 six-count, 150 Navy SEAL), so 3.7 s and 8 s. That
  also bounds the reps, which must fit the duration at the pace.

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
  lifts the dock by it, measured from the dock's own resting edge (not `innerHeight`, which
  drifts with Safari's bars) and dropping the home-indicator padding while the keyboard is up
  (`--keyboard-open`); below 80px the change is the browser's own bars, not a keyboard.
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
