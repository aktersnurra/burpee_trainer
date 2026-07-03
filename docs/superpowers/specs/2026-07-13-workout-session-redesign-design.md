# Workout Session Redesign

Date: 2026-07-13
Status: Approved for implementation planning

## Context

The active workout session already has a client-owned execution model: `SessionHook` owns the clock, countdowns, state machine, beeps, pause/resume, and high-frequency DOM updates, while `SessionLive` loads the canonical execution program and handles tracking setup, completion, review, and persistence.

This redesign improves the presentation without changing those behaviors. The nine images added to `mock/` on 2026-07-13 are the primary visual reference. The linked Headspace breathing screen is the reference for the rest animation.

The working copy already contains camera-preview and pose-tracking changes. Implementation must preserve those changes and must not replace or weaken their behavior.

## Goals

- Match the July 13 mockups' warm, minimal, full-screen composition.
- Make the changing workout state readable at a glance and from across a room.
- Replace the circular progress ring with a full-screen work animation driven by the same existing per-rep progress value.
- Give rest a distinct deep-breathing animation rather than treating it as another progress fill.
- Apply the same visual language to tracking choice, camera setup, warmup choice, ready, pause, completion/review, and save states.
- Preserve all existing session timing, tracking, audio, pause, completion, and persistence behavior.

## Non-goals

- No workout timeline, state-machine, timing, pacing, or persistence redesign.
- No whole-workout or per-set progress model.
- No new tracking or pace calculations.
- No new dependencies or frontend framework.
- No redesign of unrelated app screens.
- No visible camera preview after camera setup is confirmed; tracking continues in the background as it does now.

## Design principles

1. **One changing state dominates.** During exercise, the user sees only the current count/timer and its animation.
2. **Animation carries phase meaning.** Work and rest are distinguished by motion, shape, and color rather than labels or explanatory copy.
3. **Stable information stays anchored.** Completed reps and remaining workout time do not move as phases change.
4. **No runtime reinvention.** Existing progress, rest timing, countdown, audio, tracking, and completion signals remain authoritative.
5. **Room-test legibility.** Primary numerals remain readable from roughly six feet away on a phone.

## Visual language

- Warm paper background matching the mockups and the existing Quiet Stone palette.
- Near-black ink for primary type and controls.
- Solid orange for work.
- Solid blue for rest/breathing.
- Geist with tabular numerals for counts and timers.
- Large centered primary numerals; quiet secondary status; generous whitespace.
- Flat fills, thin borders, and restrained transitions. Avoid decorative cards, gradients, and unnecessary shadows.
- Work uses a straight horizontal fill boundary.
- Rest uses a soft, organic curved boundary inspired by the Headspace reference.

## Existing state flow

The existing flow remains unchanged:

```text
tracking choice
  → optional camera setup
  → warmup choice
  → optional warmup execution
  → ready prompt
  → initial count-in
  → workout work/rest phases
  → completion/review
  → save or discard
```

Timer-only sessions bypass camera setup. Tracked sessions keep the live camera preview and overlay only during setup, then hide them while tracking continues in the background.

## Pre-workout states

### Tracking choice

Match the mockup composition:

- Heading: `Track your workout?`
- Supporting copy explains camera tracking versus timer-only execution.
- Primary action: `Use camera`.
- Secondary action: `Timer only`.
- Preserve `#capture-tracked-btn` and `#capture-timed-btn` behavior.

### Camera setup

- The live camera preview is the dominant visual object.
- Use minimal framing guidance so the user's full body is visible.
- One dominant `Start tracked session` action.
- Preserve camera initialization, diagnostics, overlay rendering, and `#camera-setup-start-btn` behavior.
- On confirmation, hide the preview layer immediately without unmounting the tracking runtime.
- If tracked capture cannot start, preserve the existing timer-mode fallback and error message.

### Warmup choice

Match the mockup composition:

- Heading: `Warm up first?`
- Supporting copy: a short warmup or direct entry to the workout.
- Primary action: `Warm up`.
- Secondary action: `Skip warmup`.
- Preserve `#warmup-yes-btn` and `#warmup-skip-btn` behavior.

### Ready state

Use the same screen whether the user skips warmup or completes it:

- Small metadata line: `Ready when you are`.
- Heading: `Start when you’re ready.`
- One dominant `Start workout` action.
- Preserve `#workout-ready-btn` behavior.

### Initial count-in

The initial workout count-in keeps the existing dot display and existing audio behavior. The numeric `3`, `2`, `1` treatment described below applies only to transitions between sets.

## Active work state

### Primary hierarchy

1. Remaining reps in the current work event.
2. Existing camera-tracking state in tracked mode only.
3. Completed reps and remaining workout time, fixed at the bottom.

Tracked mode may show the existing `tracking_state` as a quiet `Tracking` or `Tracking lost` status. Timer-only mode omits this line. Do not show `On pace` or calculate a new pace classification because no such display signal currently exists.

### Per-rep work fill

- Remove the visible circular progress ring.
- Continue consuming the existing `model.ring.progress` value.
- During work, that value already moves from `0` to `1` over each rep and resets for the next rep.
- Map the value directly to a bottom-anchored orange layer that grows from empty to full height.
- The work layer has a straight horizontal upper boundary.
- The reset occurs at the same moment as the current ring reset; no timer or rep-boundary logic changes.
- The primary rep counter remains above the animation and readable at every fill height.

### Stable stats

- Completed reps remain bottom-left.
- Remaining workout time remains bottom-right.
- Use large tabular numerals and quiet labels, matching the mockups.
- Keep these positions stable through work, rest, countdown, and pause.

### Active-surface copy

Do not show `Rest`, `Get ready`, `Start position`, `Next set`, `Running`, `Blocks`, or explanatory phase copy. The animation and primary numeral carry the state.

## Rest and between-set transition

### Normal rest

Show only:

- A large remaining-rest timer.
- A blue deep-breathing animation.
- The stable completed-reps and time-left stats.

The blue shape is anchored to the bottom and has a soft curved upper edge. It expands during inhale and contracts during exhale, inspired by the linked Headspace reference. It must remain within a bounded portion of the viewport and never become a full-screen fill.

The animation is visual guidance only. It does not alter the existing rest duration or timeline. Use the established 8.4-second breathing cycle: 4.2 seconds expanding for inhale and 4.2 seconds contracting for exhale. The final-five-second transition overrides the cycle immediately.

### Final five seconds

- Keep the same screen and layout.
- Stop the breathing oscillation.
- Let the blue organic surface settle into the orange work color/state.
- Keep showing the remaining-rest timer for `5` and `4`.
- Show no transition label or explanatory copy.

### Final three seconds

- Replace the rest timer with large numeric `3`, `2`, `1` values.
- Emit one visual orange pulse per number.
- Emit one synchronized beep per number using the existing session audio system.
- Do not use countdown dots here.

### Start of next set

- Transition immediately into the work animation.
- Make the remaining-rep counter primary.
- Resume per-rep orange fill using the existing progress value.
- Do not insert an additional readiness state.

## Pause state

- Tapping the existing central pause target freezes the runtime and exact visual state.
- Replace the active primary numeral with a large pause glyph; do not add a `Paused` label.
- Preserve completed reps and remaining workout time.
- Show `Finish early` as the main paused action.
- Demote `Abort` to a quiet text action with the existing confirmation.
- Tapping the pause surface resumes using the existing pause/resume behavior.
- Preserve keyboard activation and accessible pause/resume naming.

## Completion, tracked review, and save

These states use the same warm-paper, large-type, low-chrome visual language without changing their data or actions.

### Completion/review hierarchy

1. Actual completed reps as the dominant result.
2. Actual duration as the supporting result.
3. Existing tracked-review information when applicable.
4. Editable completion details below the result.

### Completion form

- Preserve all existing editable values, mood options, tags, notes, validation, save, and discard behavior.
- Use a single-column mobile-first composition with thin separators rather than nested decorative cards.
- Keep `Save session` as the single dominant action.
- Keep discard/destructive actions visually quiet and confirmation-protected.
- Preserve celebration behavior; only adapt its presentation to the same typography and color system.

## Component and code boundaries

Use direct visual substitution rather than a renderer rewrite.

### `lib/burpee_trainer_web/live/session_live.ex`

- Recompose server-rendered state shells and completion surfaces.
- Preserve existing event names, IDs, tracked-camera ownership, and assigns.
- Keep `<Layouts.app>` and the current authenticated routing behavior.

### `assets/js/hooks/session_hook.js`

- Restyle prompt builders to match the approved pre-workout screens.
- Preserve the flow FSM, timing ownership, camera commands, and pause behavior.
- Keep the distinction between initial count-in and between-set countdown.

### `assets/js/hooks/session_display_model.mjs`

- Continue deriving authoritative work/rest progress and display state.
- Expose the final-five and final-three visual modes from existing phase-remaining values without changing timeline semantics.

### `assets/js/hooks/session_renderer.mjs`

- Replace ring rendering with CSS-variable/class updates for work fill, breathing rest, transition, numeric countdown pulses, and pause.
- Keep high-frequency updates client-side.
- Preserve accessible text updates and stable stat rendering.

### `assets/css/app.css`

- Add the work-fill layer, breathing-shape animation, work-settle transition, numeric pulse, and responsive sizing.
- Keep animations transform/opacity-based where possible.
- Provide a reduced-motion treatment that preserves state clarity without continuous breathing motion.

## Errors and edge states

- **Camera startup failure:** preserve timer-mode fallback and visible error feedback.
- **Tracking degraded/lost:** preserve existing tracking state and do not block the timer-based workout runtime.
- **No timed events:** retain the existing not-runnable state, restyled consistently.
- **Paused during transition:** freeze the current number, fill, breathing position, and timer; resume from the same runtime state.
- **Very short rest:** enter the appropriate final-five/final-three state immediately based on remaining time.
- **Reduced motion:** replace continuous expansion/contraction and pulses with discrete size/color state changes while retaining numbers and beeps.
- **Small screens:** support 320px width without clipping primary numbers, bottom stats, or paused actions.

## Accessibility

- Minimum 44×44px interactive targets.
- Primary counts and timers remain readable without relying on color.
- Work/rest meaning is carried by motion/shape plus the changing count/timer context, not color alone.
- Preserve keyboard pause/resume behavior.
- Keep live-updated accessible labels for count, timer, and pause state.
- Respect `prefers-reduced-motion`.

## Verification strategy

### JavaScript unit tests

- Work progress maps `0→1` to bottom-up fill and resets at each rep boundary.
- Rest uses breathing mode outside the final five seconds.
- At five and four seconds, breathing stops and the surface settles toward work state.
- At three, two, and one seconds, the renderer shows numeric values, pulses once, and requests one beep per value.
- Initial count-in still uses dots.
- Pause freezes and resumes the current visual/runtime state.
- Timer-only and tracked prompt flows remain unchanged.

### LiveView tests

- Tracking, camera setup, warmup, ready, active, pause, completion, review, save, discard, and not-runnable surfaces retain stable IDs and actions.
- Camera preview remains visible during setup and hidden after confirmation while the tracking hook remains mounted.
- Completion validation and save outcomes remain unchanged.

### Manual checks

- Test at 320px width and a modern iPhone viewport.
- Apply the room test: primary work count, rest timer, final countdown, and pause state are recognizable from six feet.
- Verify work fill never obscures numerals or bottom stats.
- Verify the rest shape never covers the full viewport.
- Verify one beep and one pulse occur for each between-set `3`, `2`, `1`.
- Verify the initial count-in still uses dots.
- Verify light and optional dark themes retain sufficient contrast.
- Run `mix precommit` after implementation.

## Success criteria

- The workout flow visually matches the July 13 mockups across all in-scope states.
- Existing session behavior remains intact.
- The ring is gone.
- Work uses bottom-up orange fill driven by existing per-rep progress and resets every rep.
- Rest uses a bounded blue deep-breathing shape and never fills the viewport.
- Between-set final five seconds settle toward work; final three seconds show pulsing/beeping `3`, `2`, `1`.
- Initial count-in remains dots.
- Active screens contain no forbidden phase or explanatory copy.
- Camera setup, completion/review, and save share the same restrained visual system.
- Automated tests and `mix precommit` pass.

## References

- Local mockups: `mock/ChatGPT Image Jul 13, 2026, *.png`
- Headspace breathing reference: <https://mobbin.com/screens/43f17864-7e82-4968-a736-b41225e0ba74>
- Existing visual specification: `UI.md`
