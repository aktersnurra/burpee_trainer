# Design as a conversation, and a box that rides the keyboard

Status: requested by the owner on 2026-10-29. Refines the Edit and New flows of
`docs/specs/2026-10-13-cockpit-flows-design.md`; what is reviewed, approved and saved is unchanged.

## The problem

Each time the owner asked to improve a proposal, the request was read against the workout the
design started from, so every follow-up reset the work. The only way back to the text box was
Edit, which discarded the proposal.

## Each follow-up refines the proposal on screen

- A design is a conversation. After the first proposal, the box stays and each message is a
  follow-up read against the **latest proposal** (`Coach.prepare_refinement/4`, then
  `Coach.prepare_plan/4` with `base_definition:`). The prompt carries it as `current_proposal`; the
  workout the design started from stays only as provenance, so approval still verifies it.
- `HomeAuthoring.Flow` keeps what each follow-up replaced as `design_turns` (the ask and the
  proposal's name, minutes and reps) and the ask in flight as `pending_turn`. A late answer is
  applied only while it is the work in flight, as before.
- A follow-up that fails leaves the proposal on screen, the words in the box, and says the
  proposal is unchanged. Cancel works while the coach is on a follow-up.
- Edit and New share this. New's first message is still its fields; once a proposal exists, New
  refines by talking too, and the pencil returns to the fields.

```
Today's workout            ← Edit keeps it in view
 table
                 Make the rests longer   ← you
 Steady six-count · 20 min · 130 reps    ← the proposal it became, kept
                      Add ten reps       ← you
 table (this proposal, changes marked)
╭──────────────────────────────╮
│ Change anything else?      ↑ │  ← docked above the keyboard
╰──────────────────────────────╯
```

## The dock

`ChatDock` (`assets/js/hooks/chat_dock.mjs`) docks a composer at the bottom of the screen:

- On iPhone the keyboard shrinks the visual viewport and leaves the layout viewport alone, so a
  bottom-fixed box ends up behind it. The hook sets `--keyboard-inset` from `visualViewport` and
  lifts the dock by it; below 80px the change is the browser's own bars, not a keyboard.
- `--chat-dock-height` sizes a spacer under the conversation so its last line clears the dock.
- When the conversation moves on (`data-version`), the newest message scrolls to the top of the
  screen with its answer below it; reduced motion scrolls without animation.
- The dock holds the actions on a proposal (Save, Use) and the chips, so neither scrolls away.
- The Coach's message box uses the same dock. It starts where it is, not scrolled into view.

## The coach reads like a coach

- `Coach.Voice` asks for a person, not a dashboard: start from what was just said, pick up what
  it knows in its own words, no trends or "insights", one thing at a time.
- The coach page answers across the gym floor, at most three sentences and one question.
- The note on Home is written from what the athlete told the coach (its notes and this week's
  last messages) as well as the metrics, and its look back names something specific or is empty.
- A change to the coach's memory writes the note again, so replying to the coach changes what
  it says next.
