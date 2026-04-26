# BurpeeTrainer — UI Specification

> Single source of truth for all visual and interaction decisions.
> Read this before touching any template or CSS.
> Design directive: sleek, classy, tasteful. Scandinavian dark. Blue replaces green everywhere.

---

## 1. Design Principles

- **Restraint first.** If something can be removed, remove it. Every element must earn its place.
- **Hierarchy through scale and weight**, not color and decoration.
- **Cool dark, not warm dark.** Blacks have a blue-gray tint, not brown or charcoal.
- **One accent color.** Electric blue is the sole accent. Orange (navy seal series) is data only.
- **No shadows, no gradients.** Flat surfaces separated by subtle borders and opacity.
- **Generous whitespace.** Breathing room is a feature, not waste.
- **Typography carries the load.** Large numbers, small labels, clear contrast ratios.

---

## 2. Color Palette

### Base surfaces

```
--color-base-100:    #0C0E14   background — deepest, cool near-black
--color-base-200:    #11141C   card/panel surface
--color-base-300:    #181C26   elevated surface (modal, dropdown)
--color-base-border: #1E2535   border — barely visible seam
```

### Text

```
--color-base-content:      #E2E8F4   primary text
--color-base-content/70:   #9BA8BF   secondary/muted labels
--color-base-content/40:   #596170   tertiary / placeholder
```

### Primary accent — electric blue

```
--color-primary:         #4A9EFF   interactive elements, active state, chart line
--color-primary-subtle:  #1A2D4A   blue tint background (badges, highlights)
--color-primary-content: #E6F1FF   text on blue backgrounds
```

### Phase colors (session runner)

```
--phase-work:          #4A9EFF   work set — electric blue (NOT green)
--phase-work-bg:       #1A2D4A
--phase-work-content:  #E6F1FF

--phase-warmup:        #F59E0B   warmup — amber
--phase-warmup-bg:     #2D1F08
--phase-warmup-content:#FEF3C7

--phase-rest:          #6B8FA8   rest — desaturated steel blue
--phase-rest-bg:       #141E28
--phase-rest-content:  #D4E4EF

--phase-done:          #8B77DB   done — soft purple
--phase-done-bg:       #1E1A35
--phase-done-content:  #EDE9FE
```

### Data series (chart only)

```
six_count: #4A9EFF   (primary blue)
navy_seal: #F97316   (orange — data-only, never UI chrome)
```

### Status colors

```
success:  #22C55E   (goal met, level unlock)
warning:  #F59E0B   (amber)
error:    #EF4444
```

---

## 3. Typography

Font stack: `ui-sans-serif, system-ui, -apple-system, sans-serif`

No custom web fonts. System fonts render crisply on mobile in bright light.

| Role                  | Size   | Weight | Color              |
|-----------------------|--------|--------|--------------------|
| Page heading          | 28px   | 600    | base-content       |
| Section heading       | 13px   | 500    | base-content/70    |
| Body                  | 14px   | 400    | base-content       |
| Stat number (large)   | 32px   | 600    | base-content       |
| Stat number (medium)  | 20px   | 500    | base-content       |
| Label / caption       | 12px   | 400    | base-content/40    |
| Badge text            | 11px   | 500    | varies             |

Letter-spacing: `-0.02em` on headings/large numbers. `0.06em` on badge text (uppercase).

---

## 4. Spacing & Radius

```
Page horizontal padding:  16px mobile, 24px tablet+
Section gap:              24px (space-y-6)
Card internal padding:    20px
Component gap inside card: 16px

--radius-card:   10px
--radius-badge:  999px (pill)
--radius-button: 8px
--radius-input:  6px
```

---

## 5. Navigation

Top bar. No bottom tab bar (app is web, not native).

```
BurpeeTrainer    Plans   Log   History   Goals
```

- `BurpeeTrainer` — wordmark, 15px, font-weight 600, base-content, links to `/`
- Nav links — 14px, base-content/60, hover: base-content, transition 150ms
- Active link — base-content, with a 2px blue underline offset 4px below the text
- No background on the nav bar — transparent, just a 1px bottom border (base-border)
- Height: 52px. Content max-width: 680px, centered.

---

## 6. Overview Page — `/`

New root route. Landing page after login.

### Layout (top to bottom)

```
[1] Weekly streak — current streak count + this week's progress bar
[2] Weekly calendar — last 12 weeks as a grid, goal-met highlighted
[3] Quick actions — two buttons: Run a plan, Log session
```

### 6.1 Weekly Streak

Single card. Left side: streak number + label. Right side: this week's progress bar.

```
┌──────────────────────────────────────────────────────────────┐
│  🔥 4 weeks                     This week                    │
│  current streak                 ████████░░  64 / 80 min      │
└──────────────────────────────────────────────────────────────┘
```

- Streak number: 32px font-weight 600 base-content + "weeks" 14px base-content/40
- "current streak" caption: 12px base-content/40
- Progress bar: full-width within its column, 8px height, rounded, primary fill on base-border track
- Minutes text: 13px base-content/40, `{done} / 80 min`
- If goal already met this week: bar fills fully, caption changes to "Goal met ✓" in success color
- Streak = consecutive weeks where `met_goal == true`, counting back from the most recently
  completed week. If the current week already meets goal, count it too.

### 6.2 Weekly Calendar

Card. Header: "Weekly progress" left, "goal: 80 min / week" right (12px base-content/40).

Grid of last 12 weeks, 4 columns × 3 rows on mobile, 6 × 2 on wider.

Each cell:
```
┌────────┐   ┌────────┐   ┌────────┐
│ Apr 7  │   │ Apr 14 │   │ Apr 21 │
│  ████  │   │  ████  │   │  ░░░░  │
│ 82 min │   │ 78 min │   │ 21 min │
└────────┘   └────────┘   └────────┘
  ✓ met        ✓ met        · missed
```

- Cell bg: base-200, border: base-border, radius 8px, padding 12px
- Date: 11px base-content/40
- Bar: 4px height, full-width, rounded — primary if met goal, base-border track always visible
- Minutes: 12px font-weight 500 base-content
- Status: 11px — met: "✓" in success color; missed: "·" in base-content/20; current: "→" in primary
- Current week cell: 1px primary border to distinguish it

### 6.3 Quick Actions

Two full-width buttons, stacked.

```
[ ▶  Run a plan    ]
[ +  Log a session ]
```

- "Run a plan": primary style — primary bg, white text, 48px height, radius-button
- "Log a session": ghost style — transparent bg, base-border border, base-content text
- Navigate to `/plans` and `/log` respectively
- Full-width on mobile, max-width 320px centered on wider screens

---

## 7. History Page — `/history`

Three sections, top to bottom:

```
[1] Stats row — three PRs in one horizontal card
[2] Chart section — "Burpees over time" with series selector and time range tabs
[3] Recent sessions list — compact rows, "View all" expands in-place
```

### 7.1 Stats Row

Single card, full-width. Three stats side by side, divided by subtle vertical rules.

```
┌─────────────────────────────────────────────────────────────┐
│  ↗  Most burpees   │  ◷  Longest session  │  ↗  Best rate  │
│     150            │     20:00            │     7.5        │
│     Apr 25, 2026   │     Apr 25, 2026     │  burpees / min │
└─────────────────────────────────────────────────────────────┘
```

- Card bg: base-200, border: base-border, radius: radius-card
- Icon: 16px, primary color
- Label: 12px, base-content/40, uppercase, tracking-wide, margin-top 8px
- Number: 28px, font-weight 600, base-content, margin-top 4px
- Sub-label (date or unit): 12px, base-content/40
- Vertical dividers: 1px base-border
- Stats are aggregate across both burpee types

### 7.2 Chart Section

Card with header row and canvas.

**Header row:**
```
Burpees over time                        [6-count ▾]
── 6-count  -- Goal (80 burpees)
```

- Series selector: pill dropdown, 12px, base-content/60, border: base-border
  → `phx-click="set_chart_series"` to switch which type is shown
- Canvas height: 220px

Chart.js configuration:
```
Background: transparent
Grid lines: 1px, rgba(255,255,255,0.04)
Axis labels: 11px, #596170
Main series: #4A9EFF, tension 0.3, pointRadius 4
Goal line: dashed [6,4], borderWidth 1, pointRadius 0
Trend line: dashed [2,2], opacity 0.4
Tooltips: bg #181C26, border #1E2535, borderWidth 1, padding 10,
          titleColor #E2E8F4, bodyColor #9BA8BF, cornerRadius 6
```

**Time range tabs** (below canvas, inside card):
```
  4W    3M   [6M]   1Y    All
```
- 12px, base-content/50. Active: base-content with 2px blue underline.
- `phx-click="set_range"` — default: 6M.

### 7.3 Recent Sessions List

Card with "Recent sessions" header and "View all" footer link.

Show 5 most recent by default. "View all sessions" expands to full list (toggle, no navigation).

**Row layout:**
```
┌──────────────────────────────────────────────────────────────┐
│  Apr 25, 2026              150 burpees      20:00          › │
│  6-count · Burst sets                                        │
└──────────────────────────────────────────────────────────────┘
```

- Row height: ~56px, padding 16px horizontal, 12px vertical
- Date: 14px, font-weight 500, base-content
- Sub-row: 12px, base-content/40 — `{burpee_type_label} · {plan_name or style_name if present}`
- Right: burpee count 14px 500 base-content, duration 14px base-content/40, chevron icon
- Dividers between rows: 1px base-border
- Hover: bg base-300, transition 100ms
- Plain `<ul>/<li>` with flex rows — not a table

**Level unlock badge:** if the session unlocked a level, show a small blue pill `Level 1D`
inline after the date.

**"View all sessions" footer:** `phx-click="toggle_show_all"` — shows "Show less" when expanded.

### 7.4 Empty State

Single centered card when no sessions exist:
```
No sessions yet.
Run a plan or log a session to see your history here.

                  + Log a session
```

- Card: base-200 bg, dashed border, radius-card, padding 48px
- Text: base-content/40, centered

---

## 8. Session Runner Page — `/session/:plan_id`

Design optimized for glanceability and zero cognitive load. Used mid-workout, often on a phone
with sweaty hands.

Max content width: 420px, centered. No horizontal scrolling. The entire session fits on one
screen — no scrolling during a workout.

### Architecture

Client-driven. The server pushes a flat timeline on mount. `SessionHook` (JS) owns the clock
(`performance.now()` + `requestAnimationFrame`), state machine, beeps, and all DOM updates.
The server is idle during the workout and only involved at save time.

### Layout (top to bottom)

1. Phase bar
2. Analog clock (large, central)
3. Burpee counter below clock
4. Workout progress bar
5. Pause button

### 8.1 Phase Bar (top strip)

Left side: phase badge (pill shape).
Right side: "Block 2 · Set 1 of 3" label (muted text).

Phase badge colors (blue replaces the old green for work):
```
:work_burpee   → --phase-work    blue  (#4A9EFF bg, #E6F1FF text)
:warmup_burpee → --phase-warmup  amber (#F59E0B bg, #FEF3C7 text)
:work_rest     → --phase-rest    steel blue (#6B8FA8 bg, #D4E4EF text)
:warmup_rest   → --phase-rest    steel blue
:rest_block    → --phase-rest    steel blue — label "Rest"
:done          → --phase-done    purple (#8B77DB bg, #EDE9FE text)
```

Badge text: uppercase, letter-spacing 0.06em, font-size 13px, font-weight 500.
The color shift between work (blue) and rest (steel blue) is the primary visual cue.

### 8.2 Analog Clock (centerpiece)

SVG circle, ~220px diameter, centered.

Outer ring: circular progress track (stroke, not fill).
- Track: thin arc, base-border color, stroke-width 14px
- Fill arc: same stroke-width, color matches phase, stroke-linecap: round
- Starts at 12 o'clock (-90deg rotation), fills clockwise
- 0% filled = start of set/rest. 100% filled = end of set/rest.
- Ring color transitions: 0.4s on phase change

Inside the ring (centered text stack):
- Top: "reps left" — 13px, muted
- Middle: large number — burpees remaining in current set, 46px, font-weight 500
  (during rest: show remaining seconds large instead of rep count)
- Bottom: "of N" — 13px, muted (N = total reps in this set; hidden during rest)

### 8.3 Burpee Counter (below clock)

Single line, centered:
```
47 / 124 burpees
```

- done: 36px 500 base-content
- separator + total: 20px 400 base-content/70
- "burpees": 13px base-content/40

Cumulative counter — total completed across all sets so far.

### 8.4 Workout Progress Bar

Thin bar (6px height, full width, rounded caps).
Fill color matches current phase color. Color transitions smoothly on phase change.

Below the bar, two items on one line:
- Left: "Time left: 12:22" (13px, time in font-weight 500)
- Right: "Workout 20:00" (total planned duration, muted)

### 8.5 Pause Button

Full width, 48px height, rounded corners, border 0.5px.
Left-aligned pause icon + "Pause" text.
On click: freezes client clock, icon swaps to play triangle, text to "Resume".
Pause/resume is handled entirely client-side — shifts `startTime` by pause duration.
Active state: scale(0.98).

### 8.6 Phase Transitions

When phase changes:
- Badge color snaps instantly (or 0.4s cross-fade)
- Clock ring color: 0.4s transition
- Progress bar color: 0.4s transition
- Clock ring resets to 0% (new set/rest starts)
- Center number resets to new rep count (or switches to rest display)

When 5 seconds remain in any rest:
- Client fires rest-ending beep (440hz, 400ms, sine) — no server involvement
- Optional: subtle scale pulse on clock ring (CSS keyframe, 1s)

### 8.7 Beep Behavior (SessionHook)

Two sounds via Web Audio API (no audio files):

Rep beep (short, sharp):
- 880hz, 80ms, square waveform, gain 0.3
- Fires at each rep boundary within a work phase, computed from `sec_per_burpee`
- Client-side only — `performance.now()` elapsed vs rep index

Rest-ending beep (longer, lower):
- 440hz, 400ms, sine waveform, gain 0.4
- Fires when 5s remain in any rest phase
- Client-side only — no server push

AudioContext initialized inside the mood picker tap (user gesture, browser requirement).

### 8.8 Warmup + Mood Overlay

On first mount, before the session starts, show a full-screen overlay:

**Step 1 — Warmup prompt:**
```
Do you want a warmup?   [ Yes ]  [ Skip ]
```
- Yes: `pushEvent("warmup_requested")` → server responds with `warmup_ready` → prepend warmup events to timeline
- Skip: proceed directly to mood picker

**Step 2 — Mood picker:**
```
😮‍💨 Tired    😐 OK    💪 Hyped
```
- Tap initializes AudioContext (browser requirement)
- Sets mood (-1 / 0 / 1), then session begins

### 8.9 Completion Modal

Shown when timeline completes. Full-screen overlay.

Fields (all pre-filled, all editable):
- `burpee_count_actual` (pre-filled from client count)
- `duration_sec_actual` (pre-filled from elapsed time)
- `mood` (pre-filled from mood picker)
- `tags` (multi-select: tired | great_energy | bad_sleep | sick | travel | hot)
- `note_pre` (text area, optional)
- `note_post` (text area, optional)

Buttons: "Save session" (primary) and "Discard" (secondary, confirm dialog).

On save: `Workouts.save_session/2` computes all derived fields, upserts `StylePerformance`.

### 8.10 Accessibility and Usability

- Minimum tap target: 44×44px for all interactive elements
- Font sizes: never below 13px
- All color meaning must have a secondary cue (badge text label, not just color)
- No information requiring reading mid-set — clock and rep number must be sufficient
- Test layout at 320px width (iPhone SE) — nothing should overflow or truncate

---

## 9. Plans Page — `/plans`, `/plans/new`, `/plans/:id/edit`

### Plan list — `/plans`

Grid of plan cards. Each card: plan name, burpee_type badge, derived duration, total burpees.
"+ New Plan" button at top.

Card styling: base-200 bg, base-border border, radius-card.
No green accents — use blue for active/primary states.

### Three-layer editor — `/plans/new` and `/plans/:id/edit`

One page, three stacked sections. See SPEC.md for full logic.

**Layer 1 — Basics:** name, burpee type, target duration, total reps, sec/rep, pacing.
Pace input shows floor value: "Min: 3.7s (graduation pace)". Immediate error if below floor.

**Layer 2 — Additional rests** (even pacing only, hidden for unbroken):
Entries: `[__] seconds at min [__]   [× remove]`. Inline error on unplaceable rest.

**Layer 3 — Blocks** (auto-generated from solver, user-editable):
Live derived duration at top of section, color-coded:
- Green: both constraints satisfied
- Amber: duration within ±5s
- Red: constraint violated

Save validation: reps exact, duration ±5s, pace ≥ floor. Blocked until all pass.

---

## 10. Log Page — `/log`

Fields: `burpee_type`, `burpee_count_actual`, `duration_sec_actual`,
`mood`, `tags`, `note_pre`, `note_post`, `inserted_at` (default now, editable).

Card styling: base-200, base-border, radius-card.
Submit button: primary style.

---

## 11. Goals Page — `/goals`

Level display section, goal card, recommendation panel. No redesign in current pass.

Color updates only: replace any green accents with blue.

---

## 12. What We Are NOT Doing

- No bottom tab bar (web app, not native)
- No Goals or Log page full redesign in this pass
- No font changes (system fonts are fine)
- No animation beyond ring pulse and progress transitions
- No dark/light mode toggle — always dark
