## SESSION RUNNER UI — `/session/:plan_id`

Design and implement the live session screen. This is the most important screen in the app —
it will be used mid-workout, often on a phone, often with sweaty hands. Every design decision
must optimize for glanceability and zero cognitive load.

---

### Layout (mobile-first, single column)

Max content width: 420px, centered. No horizontal scrolling. Safe on any screen ≥ 320px wide.
The entire session fits on one screen — no scrolling during a workout.

Top to bottom:
  1. Phase bar
  2. Analog clock (large, central)
  3. Burpee counter below clock
  4. Workout progress bar
  5. Pause button

---

### 1. Phase bar (top strip)

Left side: phase badge (pill shape)
Right side: "Block 2 · Set 1 of 3" label (muted text)

Phase badge colors:
  - :work_burpee   → green  (#1D9E75 bg, #E1F5EE text)
  - :warmup_burpee → amber  (#BA7517 bg, #FAEEDA text)
  - :work_rest     → blue   (#185FA5 bg, #E6F1FB text)
  - :warmup_rest   → muted  (secondary bg, secondary text)
  - :shave_rest    → blue   (#185FA5 bg, #E6F1FB text) — label "Shave rest"
  - :done          → purple (#534AB7 bg, #EEEDFE text)

Badge text: uppercase, letter-spacing 0.06em, font-size 13px, font-weight 500.
The color shift between work (green) and rest (blue) is the primary visual cue — instant
recognition without reading the label.

---

### 2. Analog clock (center piece)

SVG circle, ~220px diameter, centered.

Outer ring: circular progress track (stroke, not fill).
  - Track (background): thin arc, muted color (--color-background-tertiary), stroke-width 14px
  - Fill arc: same stroke-width, color matches phase badge color, stroke-linecap: round
  - Starts at 12 o'clock (top, -90deg rotation), fills clockwise
  - 0% filled = start of set/rest period. 100% filled = end of set/rest period.
  - Transition: stroke-dashoffset animates smoothly (CSS transition: 1s linear)
  - Color transitions instantly on phase change (transition: stroke 0.4s)

Inside the ring (centered text stack):
  - Top: "reps left" — 13px, muted, secondary color
  - Middle: large number — count of burpees remaining in current set, 46px, font-weight 500
    (during rest: show "rest" or remaining seconds large instead of a rep count)
  - Bottom: "of N" — 13px, muted (N = total reps in this set)

The large center number is the single most important piece of information. Size and weight
must make it readable at arm's length in bright light.

---

### 3. Burpee counter (below clock)

Single line, centered:
  [burpees done]  /  [total burpees in plan]  burpees

Example: "47 / 124 burpees"

Font sizes: done = 36px 500, separator + total = 20px 400 muted, "burpees" = 13px tertiary.
This is the cumulative workout counter — how many have been completed across all sets so far.

---

### 4. Workout progress bar

Thin bar (6px height, full width, rounded caps).
Fill color matches current phase color (green for work, blue for rest).
Color transitions smoothly on phase change.

Below the bar, two items on one line:
  Left:  "Time left: 12:22"  (font-size 13px, time in font-weight 500)
  Right: "Workout 20:00"     (total planned duration, muted)

---

### 5. Pause button

Full width, 48px height, rounded corners, border 0.5px.
Left-aligned pause icon (two vertical bars) + "Pause" text.
On click: freezes server timer + client metronome, icon swaps to play triangle, text to "Resume".
Active state: scale(0.98).

---

### Phase transitions

When phase changes (work → rest, rest → work, etc.):
  - Badge color snaps instantly (or 0.4s cross-fade)
  - Clock ring color transitions: 0.4s
  - Progress bar color transitions: 0.4s
  - Clock ring resets to 0% (new set/rest starts)
  - The large center number resets to new rep count (or switches to rest display)

During rest phases:
  - Clock ring fills as rest elapses (same mechanic, different color)
  - Center of clock shows remaining seconds (large) instead of rep count
  - "reps left" label changes to "rest"
  - "of N" label hides or shows rest duration

When 5 seconds remain in any rest:
  - Push JS hook event to trigger distinct beep (handled by BurpeeHook)
  - Optional: pulse animation on the clock ring (subtle scale pulse, 1s, CSS keyframe)

---

### Beep behavior (BurpeeHook JS hook)

Two sounds, generated via Web Audio API (no audio files):

Rep beep (short, sharp):
  - Frequency: 880hz, duration: 80ms, waveType: "square", gain: 0.3
  - Triggered by client-side setInterval at sec_per_burpee * 1000 ms
  - Started via push_event("start_metronome", %{interval_ms: ms}) from LiveView
  - Stopped via push_event("stop_metronome") on phase end

Rest-ending beep (longer, lower):
  - Frequency: 440hz, duration: 400ms, waveType: "sine", gain: 0.4
  - Triggered by push_event("warn_rest_ending") from server when 5s remain

AudioContext must be initialized inside a user gesture handler (pause/resume button click
or a "tap to start" overlay on first load) — browsers block AudioContext without user interaction.

---

### "Tap to start" overlay

On first mount, before the session starts, show a full-screen overlay on top of the clock area:
  - Large text: "Ready"
  - Subtext: "Tap anywhere to begin"
  - Semi-transparent background over the clock
  - Tapping: dismisses overlay, sends phx-click to start session, initializes AudioContext

This solves the browser AudioContext restriction cleanly.

---

### LiveView implementation

Use a single LiveView module: BurpeeTrainerWeb.SessionLive.

Socket assigns:
  timeline          :: [%Event{}]          -- full timeline from Planner.to_timeline/1
  timeline_index    :: integer             -- current position in timeline
  phase_elapsed_sec :: integer             -- seconds elapsed in current phase
  paused            :: boolean
  burpee_count_done :: integer             -- cumulative burpees completed
  started           :: boolean             -- false until tap-to-start

Timer: :timer.send_interval(1000, self(), :tick)

On :tick (if not paused and started):
  - Increment phase_elapsed_sec
  - Increment burpee_count_done at the correct cadence based on sec_per_burpee
  - If phase_elapsed_sec >= current event duration_sec: advance timeline_index, reset phase_elapsed_sec
  - Push "warn_rest_ending" when rest phase has 5 seconds left
  - Push "stop_metronome" / "start_metronome" on phase transitions

On pause/resume:
  - Toggle paused assign
  - Push "pause_metronome" / "start_metronome" to hook

On reaching end of timeline: set phase to :done, stop timer, show completion modal.

---

### Completion modal

Shown when phase = :done. Full-screen overlay (not position:fixed — use an in-flow wrapper
with min-height so the iframe sizes correctly).

Fields (all pre-filled, all editable):
  - burpee_count_actual   (pre-filled: burpee_count_done)
  - duration_sec_actual   (pre-filled: planned duration)
  - note_pre              (text area, optional)
  - note_post             (text area, optional)

Two buttons: "Save session" (primary) and "Discard" (secondary, confirm dialog).

---

### Accessibility and usability constraints

- Minimum tap target: 44×44px for all interactive elements
- Font sizes: never below 13px
- All color meaning must have a secondary cue (badge text label, not just color)
- No information that requires reading mid-set — the clock and rep number must be
  sufficient to know what to do next
- Clock ring must have sufficient contrast against background in both light and dark mode
- Test layout at 320px width (iPhone SE) — nothing should overflow or truncate
