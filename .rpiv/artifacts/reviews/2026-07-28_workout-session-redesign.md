---
template_version: 2
date: 2026-07-28T00:32:23+02:00
author: Gustaf Rydholm
repository: burpee_trainer
branch: master
commit: b8cafe827f4c
review_type: commit
scope: "34-change workout-session redesign stack from master@git through @-"
scope_strategy: explicit-range
in_scope_files_count: 44
status: ready
severity: { critical: 4, important: 5, suggestion: 4 }
verification: { verified: 13, weakened: 1, falsified: 0 }
blockers_count: 9
tags: [code-review, workout-session, pose-tracking, liveview, ux]
---

<!-- markdownlint-disable MD013 MD036 -->

# Code Review — Workout Session Redesign

**Commit:** `b8cafe827f4c` · **Status:** `ready` · **Findings:** 4🔴 · 5🟡 · 4🔵 · **Verification:** 13✓ / 1− / 0✗

## Top Blockers

1. **I2** — A pre-readiness wrist gesture splits the client and server camera-setup states.
2. **I3** — A detector-frame failure can still be saved as trusted camera tracking.
3. **I4** — Editing camera-counted reps or duration can make the completion impossible to save.
4. **I1** — A failed tracked-capture start leaves the client in an unusable camera-setup flow.

---

## Legend

```text
Severity    🔴 fix before merge   🟡 fix soon   🔵 nice to have   💭 discuss
ID prefix   I interaction   Q quality   S security   G gap
Verify      ✓ verified   − weakened (demoted)   ✗ falsified (dropped)
Annotate    [precedent-weighted]   [cascade: <kind>]   [subsumed-by <ID>]
```

---

## 🔴 Critical

### I1 🔴 Tracked-capture creation fails after the client has already committed to camera setup

**Where**
`assets/js/hooks/session_flow_fsm.mjs:101`

**Code**

```javascript
{ type: "chooseTrackedCapture" },
```

**Why**
`CAPTURE_TRACKED` immediately queues the server request and hides the client-owned choice overlay. If `Workouts.start_pose_capture_run/2` fails, `SessionLive` switches only its assigns back to timed mode; the client FSM remains in `camera_setup`, while the server removes the tracker and setup panel.

**Fix**
Enter camera setup only after a positive server acknowledgement; route failure through the client `CAPTURE_TIMED` transition and restore a usable prompt.

---

### I2 🔴 Camera gesture readiness is a false promise that strands setup `[cascade: stranded-state]`

**Where**
`assets/js/hooks/pose_tracker_impl.mjs:255`

**Code**

```javascript
if (armedStep && armedHoldFramesRequired > 0) {
```

**Why**
The gesture needs only a visible wrist and shoulder, while readiness also requires stable shoulders, hips, and a knee. A gesture can therefore advance the client to warmup while the server rejects `camera_setup_started` because it remains `:arming`, leaving the camera panel rendered over a different client phase.

**Fix**
Gate camera confirmation on latched `ready | optimal` state and commit the client transition only after the server accepts setup start.

---

### I3 🔴 Detector-frame failure can still produce a trusted tracked completion

**Where**
`assets/js/hooks/pose_tracker_impl.mjs:216`

**Code**

```javascript
hook.pushEvent("track", {
```

**Why**
The frame-exception path reports loss only to LiveView and then stops the loop. It does not dispatch local `pose-tracker:status`, clear `data-pose-tracker-ready`, or degrade the client observer. The stale observer can pass both trust checks, send `finish`, and replace the server's degraded state with `:review`.

**Fix**
Use one local-and-server loss transition for confidence loss and detector exceptions, clearing readiness and degrading the observer before stopping or retrying inference.

---

### I4 🔴 Editable camera results cannot always be saved

**Where**
`lib/burpee_trainer_web/live/session_live.ex:275`

**Code**

```elixir
"cadence_ms" => tracked.cadence_ms,
```

**Why**
The completion UI advertises manual correction, but save always combines the edited total/duration with the original cadence. `Workouts` requires one timestamp per actual rep and requires the last timestamp to fit the edited duration, so increasing reps or shortening duration deterministically rejects persistence.

**Fix**
Define explicit manual-override persistence semantics and stop validating the untouched camera cadence as if it represented the edited result; add a submit-and-persist flow test.

---

## 🟡 Important

### Q1 🟡 Warmup gesture remains armed and can restart the warmup

**Where**
`assets/js/hooks/session_hook.js:533`

**Code**

```javascript
onWarmupYes() {
```

**Why**
Unlike `onWorkoutReady`, the warmup Yes path never disarms. Lowering and raising the wrist again creates another satisfied transition, dispatches `WARMUP_READY`, and resets the active segment to a new warmup.

**Fix**
Consume/disarm every gesture step before dispatching its flow transition, including Yes, Skip, fallback, and camera confirmation.

---

### Q2 🟡 Failed timer-fallback cleanup retains active pose data

**Where**
`lib/burpee_trainer_web/live/session_live.ex:137`

**Code**

```elixir
|> abort_active_pose_capture("camera_setup_fallback")
```

**Why**
If deleting the active run fails, the unchanged socket continues into timed mode. Later completion skips the still-active run because cleanup is gated to `capture_mode == :tracked`, leaving uploaded pose data stranded.

**Fix**
Represent cleanup failure explicitly and retain a retry/cleanup path when switching to timed mode.

---

### Q3 🟡 The tracked hands-free flow hides all actions without explaining the gesture

**Where**
`assets/js/hooks/session_hook.js:524`

**Code**

```javascript
(this.flow.captureMode === "tracked" ? " hidden" : "");
```

**Why**
Warmup silently skips after four seconds, while workout start hides its only button and has no timeout. The fixed copy never says to raise and hold a hand, so users who do not know or cannot trigger the gesture are indefinitely blocked.

**Fix**
Show room-readable gesture/timeout instructions and retain a quiet tappable fallback, especially for workout start.

---

### Q4 🟡 Camera consent copy omits persisted pose traces

**Where**
`assets/js/hooks/session_hook.js:431`

**Code**

```javascript
"Use camera tracking for pace and rep detection, or run the session with the timer only.";
```

**Why**
The choice describes live detection but not that pose samples are recorded, uploaded, and persisted through `pose_capture_chunk`.

**Fix**
Disclose trace storage and intended use before the user selects **Use camera**, using accurate retention wording.

---

### Q5 🟡 Invalid completion submissions provide no visible recovery `[subsumed-by I4]`

**Where**
`lib/burpee_trainer_web/live/session_live.ex:294`

**Code**

```elixir
{:noreply, assign(socket, :completion_form, to_form(changeset))}
```

**Why**
The error branch only reassigns the form. The custom reps and minutes inputs render neither field errors nor cadence errors, so failed submissions appear to do nothing.

**Fix**
Render accessible field/global errors beside the completion controls and focus or announce the error summary after submit.

---

## 🔵 Suggestions

### Q6 🔵 Countdown and completion announcements are incomplete

**Where**
`assets/js/hooks/session_renderer.mjs:103`

**Fix**
Announce the current countdown numeral, add an announced completion heading/status target, and make pause/resume state changes explicit. Existing role/label semantics make this narrower than the original finding.

---

### Q7 🔵 Intra-rep recovery has no distinct visual treatment

**Where**
`assets/js/hooks/session_renderer.mjs:58`

**Fix**
Use the existing `is-work-recovery` class to preserve intra-rep recovery semantics while sharing the breathing blue rest field and centered bare seconds without adding visual clutter.

---

### Q8 🔵 Warmup-complete context is discarded

**Where**
`assets/js/hooks/session_hook.js:487`

**Fix**
Render the supplied title/description so warmup completion differs from direct start, or remove the unused arguments and intentionally standardize the transition.

---

### Q9 🔵 Regression tests do not cross the affected boundaries

**Where**
`test/burpee_trainer_web/live/app_flow_test.exs:430`

**Fix**
Submit and assert the edited tracked session outcome, and enter tracked mode before checking conditional camera-panel markup. Replace the raw-HTML assertion in `session_live_test.exs` with element/LazyHTML selectors.

---

## 💭 Discussion

### Q10 💭 Should zoom and scrollbar suppression remain global?

**Where**
`lib/burpee_trainer_web/components/layouts/root.html.heex:7`

**Why**
The root viewport disables user scaling, and universal CSS hides scrollbar affordances for every route and nested scroller. This matches an existing project-level visual decision, but it trades away accessibility and discoverability outside the workout runner.

---

## Impact

| Consumer | Change | Findings |
| --- | --- | --- |
| `lib/burpee_trainer_web/router.ex:49` | Authenticated session entry route | I1, I2, Q3, Q4 |
| `assets/js/hooks/session_hook.js:30` | Client-owned workout lifecycle | I1, I2, I3, Q1, Q3 |
| `lib/burpee_trainer_web/live/session_live.ex:65` | Browser/server flow and persistence boundary | I1, I2, I4, Q2, Q5 |
| `lib/burpee_trainer/workouts.ex:580` | Tracked-session persistence | I4 |
| `assets/js/hooks/session_renderer.mjs:10` | Workout display and accessibility | Q6, Q7 |
| `lib/burpee_trainer_web/components/layouts/root.html.heex:1` | Every application route | Q10 |

---

## Precedents

| Commit | Subject | Follow-ups |
| --- | --- | --- |
| `2b107eb92f42` et al. | Full workout-session visual redesign | Accessibility, stale state, progress, recovery, count-in, and vestigial-contract fixes within 13 days |
| `e2472239e188` | Canonical workout execution programs | Session-flow/setup hardening and stale runtime fields after cross-layer cutover |
| `39b927b3a796` et al. | Local pose tracker and tracked pre-workout choice | Backend initialization, import ordering, and abort-data cleanup fixes |
| `c2fc5b42af33` et al. | Split runner into segment and flow FSMs | Rep accounting, warmup persistence, rests, and duration-boundary fixes |

**Recurring lessons (most → least frequent)**

1. Runner changes are cross-layer contract migrations, not isolated visual edits.
2. Pose readiness is temporal; hook mount, readiness, gesture, server acknowledgement, and timeout ordering must be tested together.
3. Client-owned clocks and state machines need end-to-end boundary tests, not reducer-only assertions.
4. Camera abort/fallback behavior must prove both UI recovery and durable data cleanup.

---

## Recommendation

| # | ID | Action | Alt / Note |
| - | - | - | - |
| 1 | I1, I2 | Make tracked setup server-acknowledged and readiness-gated | One explicit pre-workout protocol is safer than parallel client/server assumptions |
| 2 | I3 | Unify detector loss handling across local observer, readiness, and LiveView | Preserve timer progression; tracking remains backup-only |
| 3 | I4, Q5 | Define and test manual camera-result override semantics | Do not fabricate cadence for edited reps |
| 4 | Q1, Q3 | Consume gesture arms and add visible instructions/fallbacks | Preserve hands-free as convenience, not a trap |
| 5 | Q4, Q2 | Restore informed camera choice and reliable pose-data cleanup | Treat trace retention as a user trust boundary |
| 6 | Q6-Q9 | Apply focused accessibility, recovery-state, copy, and test polish | Keep the runner visually restrained |
