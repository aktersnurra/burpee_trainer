# Rest Animation Refinement Design

**Date:** 2026-07-13  
**Status:** Approved  
**Related design:** `docs/superpowers/specs/2026-07-13-workout-session-redesign-design.md`

## Context

The redesigned workout runner gives rest a bottom-anchored blue breathing surface and uses an orange half-screen fill plus a circular numeral halo for the final between-set countdown. In practice, the current breathing movement is too restrained and the final countdown does not feel like a continuous transformation of the rest surface.

This refinement increases the breathing range and turns the same surface into an orange contour for the final `3`, `2`, `1`. It remains a visual-only change: existing workout timing, state transitions, pause behavior, audio cues, tracking, and persistence remain authoritative.

## Goals

- Make the breathing motion the dominant rest signal without allowing it to become a full-screen fill.
- Move the visible top edge through roughly 25% to 75% of viewport height over the existing breathing cycle.
- Transform the filled blue breathing surface into an orange outline before the final `3`, `2`, `1`.
- Pulse the contour and numeral together with each existing countdown beep.
- Preserve room-scale legibility, reduced-motion behavior, and stable bottom statistics.

## Non-goals

- Changing rest duration, timeline semantics, or the 8.4-second breathing cadence.
- Changing when `5`, `4`, `3`, `2`, or `1` occur.
- Changing beep generation or adding audio cues.
- Changing the initial pre-workout count-in, which retains its dot display.
- Adding labels, instructions, or explanatory copy to the active surface.
- Refactoring the session FSM, camera tracking, pause flow, or persistence.

## Approved visual behavior

### Normal rest

The existing bottom-anchored blue surface remains filled and keeps its soft curved upper edge. Its visible top edge travels between approximately 25% and 75% of viewport height during each 8.4-second cycle:

- 4.2 seconds expanding toward 75% for inhale.
- 4.2 seconds contracting toward 25% for exhale.
- The surface never reaches the top of the viewport and never reads as a full-screen progress fill.

The large remaining-rest timer and the completed-reps and time-left statistics stay fixed while the surface moves behind them. No phase label or breathing instruction is added.

### Final-five transition

At `5` seconds remaining, continuous breathing stops at its currently rendered geometry. The transition must begin from that exact visible position without snapping to a predetermined keyframe.

Across `5` and `4`:

- The blue fill drains to transparent.
- An outline of the same curved, bottom-anchored silhouette emerges.
- The outline color shifts from blue toward work orange `#FD7236`.
- The silhouette settles near the middle of the viewport.
- The regular remaining-rest timer continues to show `5` and `4`.

The transition reaches an orange, outline-only state before `3` appears.

### Final `3`, `2`, `1`

At `3`, only the orange contour remains. The bottom edge stays outside the viewport so the visible contour reads as the curved upper boundary and sides of the former breathing surface rather than as an unrelated card or screen frame.

For each `3`, `2`, and `1`:

- The existing large numeral is shown.
- The contour briefly expands and thickens.
- The numeral receives a restrained scale pop.
- One existing synchronized beep is emitted.

The current circular halo around the numeral is removed; the surface contour carries that visual beat instead. The contour stays behind the numeral and bottom statistics and must not reduce their legibility.

When work begins, the contour disappears and the orange per-rep work fill starts from zero as it does today.

## Runtime and component boundaries

The existing display states remain authoritative:

- `rest-breathe` controls continuous blue breathing.
- `rest-settle` controls the `5` and `4` transition.
- `rest-countdown` controls `3`, `2`, and `1`.

No FSM timing or event changes are required. `SessionRenderer` captures the currently rendered rest-shape geometry when entering `rest-settle` so CSS can transition from that exact position without a jump. The visual implementation remains owned by `SessionRenderer`, `#session-rest-shape`, and the session CSS.

Pause freezes the active breathing, settle, or countdown animation and resumes from the same runtime state. Existing count values and beep commands remain unchanged.

## Responsive and accessibility behavior

- Preserve readable numerals and statistics at 320px width and modern iPhone viewports.
- Keep the breathing surface and contour below the content layer.
- Use a responsive contour width that stays visible without dominating the numeral.
- Preserve light and dark theme contrast on the active workout surface.
- Do not rely on color alone: filled breathing motion, outline transition, changing numerals, and audio distinguish the phases.
- Keep existing live-region and pause/resume behavior.

With `prefers-reduced-motion`:

- Replace continuous 25%→75% oscillation with a static, clearly bounded blue surface.
- Replace animated draining and pulsing with discrete filled-blue, orange-contour, and numeral states.
- Retain `3`, `2`, `1` and their existing beeps.

## Verification

### Automated

- Existing display-model tests continue to prove the `rest-breathe`, `rest-settle`, and `rest-countdown` timing boundaries.
- Renderer tests prove each changed `3`, `2`, and `1` value triggers one contour/numeral pulse and repeated frames do not retrigger it.
- Renderer and DOM tests prove work-entry clears the rest contour and rest-entry clears work fill.
- Reduced-motion CSS preserves distinct filled-rest and outline-countdown states.
- JavaScript tests, asset build, focused LiveView tests, and `mix precommit` pass.

### Manual

- Observe a full 8.4-second cycle and confirm the top edge travels approximately 25%→75%→25% without reaching full screen.
- Enter the final five seconds from both a high and low breathing position and confirm there is no geometry snap.
- Confirm the blue fill drains through `5` and `4` and is outline-only by `3`.
- Confirm the orange contour and numeral pulse once with each beep at `3`, `2`, and `1`.
- Confirm the old circular numeral halo is absent.
- Pause and resume during breathing, settling, and countdown.
- Check 320px, modern iPhone, light theme, dark theme, and reduced-motion mode.
- Apply the six-foot room test to the rest timer and final countdown.

## Acceptance criteria

- Normal rest visibly breathes between roughly 25% and 75% viewport height on the unchanged 8.4-second cadence.
- The breathing surface remains bounded and never becomes a full-screen fill.
- The final-five transition starts from the currently visible breathing geometry without snapping.
- The blue fill drains and becomes an orange contour during `5` and `4`.
- `3`, `2`, and `1` show an orange contour pulse plus a restrained numeral pulse and one existing beep each.
- The old circular countdown halo is removed.
- Initial count-in dots, workout timing, pause behavior, camera tracking, persistence, and work progress behavior remain unchanged.
