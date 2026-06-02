# Session UI Refactor Design

Date: 2026-06-02

## Scope

Refactor the live session runner UI first. This is a visual-only first slice: keep the existing Phoenix LiveView and JavaScript session behavior intact, including start, warmup/count-in, pause/resume, completion, tracked-session review, and save flow.

The session screen becomes the anchor for the app's new visual language. Home, Workouts, Stats, and diagnostics can adopt the language later after the session surface proves it.

## Visual Direction

Use a warm-paper monochrome editorial training-instrument style.

- Warm paper background.
- Near-black ink for primary marks and numbers.
- Pale gray hairlines for rings, dividers, and future progress.
- No electric-blue accent on the session runner.
- No shadows, gradients, or decorative color.
- Typography is dominated by a huge tabular numeric display and tiny mono instrumentation labels.

The reference screenshots are direction, not truth. The real implementation must preserve the current app's behavior and constraints.

## Live Runner Composition

The live runner has one dominant object: the instrument.

Primary hierarchy:

1. Huge central count number.
2. Depleting circular ring around the number.
3. Grouped set glyphs below the instrument.
4. Two readable stat blocks: completed reps and time left.

Remove visual noise from the running state:

- No visible pause button.
- No `RUNNING` footer label.
- No `BEAT` metadata.
- No `REPS LEFT` label.
- No extra bottom metadata unless required for behavior.

## Ring Behavior

The ring should deplete rather than fill.

- At the start of the relevant unit, the ring appears full.
- As progress advances, the active mark drains away.
- During work, the ring represents work progress for the current unit.
- During rest, the ring represents rest time remaining.

The ring/counter area is the pause/resume target. Clicking or tapping anywhere on the instrument pauses or resumes. The running state stays visually clean; paused state may show a clear pause overlay inside the instrument.

## Structured Set Progress

Use grouped vertical set glyphs instead of a conventional progress map.

- Each vertical mark represents one set.
- Larger gaps between groups represent blocks.
- Completed sets are filled black.
- The current set fills gradually during the set.
- Future sets are pale.
- Text label is optional; if needed, use only `SETS`.
- Do not add a `BLOCKS` label or header.

This lets users glance at workout structure without adding a dashboard-like map.

## Stat Blocks

Keep two readable stat blocks below the set glyphs:

- Done / total reps, e.g. `036` with `DONE / 150`.
- Time left, e.g. `06:12` with `TIME LEFT`.

These stats should be large enough to read quickly during exercise but secondary to the central count.

## Rest State

Use inversion, not color.

Rest is a mode shift, so the instrument flips polarity:

- Page background remains warm paper.
- Instrument area becomes dark ink.
- Rest number becomes paper-colored.
- Label may change to `REST` if needed for clarity.
- Ring still depletes, now representing rest time remaining.

Do not introduce a rest color. Extra color would pollute the monochrome language.

## Count-In State

Count-in should feel transitional, not like work or rest.

- Keep the paper background.
- Show a huge `3`, `2`, `1` countdown.
- Use a thin pulse or tick around the number.
- Suppress set glyph emphasis and secondary stats during count-in if they distract.
- Avoid full inversion and avoid introducing color.

Count-in is the instrument arming.

## Pause State

Pause is entered by tapping the ring/counter instrument.

- No separate pause button while running.
- Paused state should clearly communicate the stopped state inside the instrument.
- Acceptable treatments: muted/frozen instrument plus pause icon, or `PAUSED` inside the ring.
- Resume uses the same instrument tap target.

## Completion State

Completion can remain mostly as-is for this first visual slice unless simple styling changes are needed for consistency.

The first refactor should not redesign the save form or milestone celebration deeply. It may apply basic warm-paper tokens, but the live runner is the priority.

## Implementation Boundaries

This design intentionally excludes:

- Refactoring Home, Workouts, Stats, Tracking Test, or plan editor screens.
- Changing workout/session state machine behavior.
- Adding new session features.
- Changing persistence or completion logic.
- Adding new JavaScript frameworks or external libraries.
- Jump-based terminology or assumptions.

## Success Criteria

- The live session screen visually matches the warm-paper monochrome instrument direction.
- Existing session behavior still works.
- The ring depletes instead of fills.
- Pause/resume is controlled by tapping the ring/counter area, without a visible running-state pause button.
- Rest uses inverted instrument treatment, not a new color.
- Count-in uses sparse countdown pulse treatment, not inversion or color.
- Set glyphs show grouped blocks and filling set progress.
- Done/total reps and time left are readable at a glance.
- No `REPS LEFT`, `RUNNING`, `BEAT`, or `BLOCKS` labels appear in the running UI.
