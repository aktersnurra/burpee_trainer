# Starting a workout with one tap

## Summary

Today a workout starts after up to five steps: ▶ on Home, "Track burpees with the
camera?", the camera screens, "Warm up first?", and "Ready when you are". Two of them ask
the same questions every day. This moves those two questions onto Home as remembered
toggles beside ▶, so ▶ is the only tap. The session goes straight to the camera, or to the
5-second countdown that every warmup and workout already starts with. The finish screen
drops the inputs the timer and tracker already filled.

## Home

The action row of the workout hero becomes:

```
   [camera]   [edit] [switch] ( ▶ ) [new]   [warmup]
```

- Camera and warmup are icon toggles (`hero-video-camera`, `hero-fire`), always visible,
  not behind expand. Off shows the icon dimmed and struck through; `aria-pressed` carries
  the state, and `aria-label` names it ("Camera tracking", "Warmup").
- Edit, switch and new stay as they are, shown when expanded.
- Choices are remembered per device in `localStorage` (`burpee.start.camera`,
  `burpee.start.warmup`): the camera depends on where the phone is, not on who you are.
  First use, or storage unavailable: camera off, warmup on.
- The toggles are client-only. Home's server state does not change; ▶ is unchanged.

## The session

The session reads the two choices when it boots, after it has checked for a completion
draft to restore (a resumed session that was finishing still opens on the finish screen).

| Camera | Warmup | After ▶ |
|---|---|---|
| off | off | countdown, workout |
| off | on | countdown, warmup, countdown, workout |
| on | off | camera, hand up or hold still, countdown, workout |
| on | on | camera, hand up or hold still, countdown, warmup, countdown, workout |

- **The countdown** is the existing segment countdown: 5 seconds, beeps, tap to pause. It
  is the time to put the phone down and get into position, so it stays at 5.
- **No gate after the warmup.** The workout's own countdown follows it directly, with or
  without the camera.
- **The camera screen** is one screen: the preview, with one status line that follows the
  state: "Starting camera", "Step into frame", "Hand up or hold still". A raised hand, or
  1.5 s still in frame (the tracker's existing auto-confirm), starts the countdown. The
  skeleton the preview already draws shows what is in frame, so the sentence about
  shoulders, hips and knee goes. "Continue without camera" stays on it, and continues as camera off with the
  same warmup choice.
- **Camera fails:** the same screen shows "Camera unavailable", with retry and continue
  without camera. Nothing has started.

Removed: the capture choice, warmup choice and workout-ready screens, the 4-second
warmup skip, and their copy. The flow FSM loses `capture_choice`, `warmup_choice` and
`workout_ready`; `SESSION_READY` carries the two choices.

## Finishing

- The reps and seconds inputs go. The big count and the "of N · m:ss" line show them;
  tapping either opens it for correction.
- Mood stays as three taps, optional.
- The note sits behind an icon (`hero-pencil`), opening the text field in place. It can
  also be added later from Claude, since notes on a finished session are correctable.
- Leave and save are unchanged. A good day is one ✓.

## Out of scope

- Server-side start preferences or syncing them across devices.
- Changing the warmup itself, the runner, or the gesture detector.

## Checks

- Flow FSM tests: each row of the table above, camera failure, continue without camera
  from the camera screen, and draft restore before start.
- Hook flow tests: ▶ to running workout with no clicks for camera off.
- Home LiveView test: both toggles render with `aria-pressed`, outside the expansion.
- Finish screen: no reps or seconds input by default; tapping the count edits it; saving
  without touching anything saves the counted reps and time.
