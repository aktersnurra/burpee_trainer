# BurpeeTrainer — UI Specification

> Single source of truth for all visual and interaction decisions.
> Read this before touching any template or CSS.
> Design directive: quiet, warm, tasteful. Light Quiet stone is the only theme; there is no dark mode. Typography, whitespace, and thin rules carry the interface. Muted clay replaces saturated blue as the rare accent.

---

## 1. Design Principles

- **Restraint first.** If something can be removed, remove it. Every element must earn its place.
- **Hierarchy through scale and weight**, not color and decoration.
- **Warm light, always.** Quiet stone carries the app; there is no dark mode.
- **Rare accent color.** Muted clay is the restrained accent. Orange (navy seal series) is data only.
- **No shadows, no gradients.** Flat surfaces separated by subtle borders and opacity.
- **Generous whitespace.** Breathing room is a feature, not waste.
- **Typography carries the load.** Large numbers, small labels, clear contrast ratios.

---

## 2. Color Palette

### Base surfaces

```
--color-base-100:    #F4F2EE   background — warm stone
--color-base-200:    #FAF8F3   card/panel surface — soft paper
--color-base-300:    #EFECE4   elevated surface (modal, dropdown)
--color-base-border: #DAD6CE   border — warm quiet seam
```

### Text

```
--color-base-content:      #20201D   primary text
--color-base-content/70:   #74716A   secondary/muted labels
--color-base-content/40:   #9A9489   tertiary / placeholder
```

### Core interactive ink

```
--color-primary:         #20201D   interactive text, active state, chart line
--color-primary-content: #FAF8F3   text on primary fills

--color-accent:          #A77B5D   muted clay accent for rare emphasis
--color-accent-content:  #FFF8F0   text on accent fills
```

### Phase colors (session runner)

```
--phase-work:          #20201D   work set — ink emphasis
--phase-work-bg:       #EFECE4
--phase-work-content:  #20201D

--phase-warmup:        #A77B5D   warmup — muted clay
--phase-warmup-bg:     #FFF8F0
--phase-warmup-content:#20201D

--phase-rest:          #6F7F8F   rest — softened slate
--phase-rest-bg:       #F2F0EA
--phase-rest-content:  #20201D

--phase-done:          #6F7D55   done — subdued olive
--phase-done-bg:       #EEF1E6
--phase-done-content:  #20201D
```

### Data series (chart only)

```
six_count: #20201D   (primary ink)
navy_seal: #A77B5D   (muted clay — data-only, never UI chrome)
```

### Status colors

```
success:  #6F7D55   (goal met, level unlock)
warning:  #A77B5D   (muted clay)
error:    #A55643
```

---

## 3. Typography

Font stack: `Geist, ui-sans-serif, system-ui, -apple-system, sans-serif`

Geist is the only typeface: no serif or Arial declarations anywhere, including headings, the chooser and session panels. Use `var(--font-sans)` rather than repeating the stack; headings change size and weight, never family. Keep the type system restrained: most text uses 400 / 500 / 600 weights, with large headings using careful negative tracking.

Home and Progress use three sizes, as tokens in `assets/css/adaptive_home.css`:

| Token            | Size | Roles                                                         |
|------------------|------|---------------------------------------------------------------|
| `--text-display` | 28px | page heading (600), the one big number on a screen (600)      |
| `--text-body`    | 16px | what you read and tap: summaries, section headings (600), buttons (500) |
| `--text-small`   | 13px | labels, captions, goals, dates, chart scales (muted)          |

`--text-title` (34px, 600) is reserved for Home's one title: today's workout or the result.
Numbers that summarise something (streak, level, latest and best density, a session's reps
and time) are a display-size number with a body word beside it on one baseline.

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

## 4a. Lines and edges

- One column edge per screen: the progress row, header and content share the 640px column.
- A line marks an input (the underlined field row), a chosen tab, or data (the progress
  track, chart grid). Spacing separates everything else.
- Meta never joins unlike things with middle dots; each goal is its own line.

## 4a2. Actions

- One filled pill per view for the primary action. Start keeps its word; a filled action
  inside a field or row is an icon (Send is an arrow up, Confirm and Save a check).
- Every other action is a quiet icon from one set (heroicons), each with an `aria-label`
  and `title`, one icon per meaning everywhere: pencil-square edits, arrows-right-left
  switches, plus adds or sets, trash deletes or clears, x-mark dismisses, check confirms,
  chevron-down loads more.
- Words stay only where an icon would be ambiguous: period tabs ("12 weeks"), Weeks and
  Days, Start.
- Views of the same data switch like the period tabs, as an icon pair (chart-bar for the
  chart, list-bullet for the sessions), the current one underlined.
- Deleting a session: tap its row and its trash shows; the first tap on the trash arms it
  (error colour), the second deletes. Tapping the row again or Escape lets go.
- A chevron only means "opens here" or, pointing down at the end of a list, "more".
- Every pick (burpee type, set style, filters, levels) is the same rounded choice; the
  chosen one is filled light. A destructive decision is the filled pill in the error colour.
- The burpee types are always "Six-count" and "Navy SEAL" (lowercase "six-count" mid-sentence).

## 4a3. Words

Every visible word earns its place. No eyebrow labels ("Today", "This week"), no captions
restating a heading, no legends for a single series, no field labels where a placeholder
names the field (keep the label for screen readers).

## 4b. Motion

Two durations and two curves, as tokens: `--motion-quick` (180ms) for fades, folds and
hovers; `--motion-settle` (360ms) for things that arrive or open; `--motion-stagger`
(80ms) between related arrivals. `--ease-out` for arrivals, `--ease-in-out` for folds.
Leaving runs on the action and LiveView holds the patch until it ends, so the new content
arrives in place instead of beside the old. Reduced motion turns it all off.

## 5. Navigation and screens

There is no navigation bar. The app opens on the one thing the owner needs now, and each
screen leads to the next in context:

- **Home** (`/`) shows today's state: the ready workout with Start (a starter workout on
  first use, never an empty prompt), or once trained, the day's result. The result's title
  opens it like the workout's: the coach's report on the week, this week's conversation,
  replies the coach predicts you'll send, "Message the coach", goals waiting for Confirm
  or Dismiss, and "What the coach knows about you". The coach speaks only once the day is
  done; `/coach` lands on Home. The week strip opens Progress. Design:
  `docs/specs/2026-09-09-adaptive-home-pre-workout-design.md`, revised by
  `docs/specs/2026-10-10-frictionless-home-design.md` and
  `docs/specs/2026-10-14-coach-on-home-design.md`.
- **Progress** (`/progress`; `/history` redirects) keeps the week strip on top, which leads
  back Home, then the coach's look back over recent weeks, then a gauge per burpee type
  side by side (best against goal, its course, or the next goal to set), then one chart
  with both types on their own axes and the weekly record. Design:
  `docs/specs/2026-10-14-coach-on-home-design.md`.
- **Session** (`/session/:session_id`, `/videos/:video_id/session/:session_id`) runs a
  workout. Design: `docs/specs/2026-07-13-workout-session-redesign-design.md` and the
  session and camera specs that follow it.

Every screen uses the `--color-base-100` page background, Geist, and Home's centred
column: Home and Progress render in the same `.adaptive-home` container on the
layout's session surface, so the background, gutters and width never change between
them. Sheets and the chooser use `--color-base-200`. Never hard-code a page background.

---

## 6. What We Are NOT Doing

- No navigation bar or tab bar
- No heavy dashboard treatment on Home
- No new font family beyond the existing Geist setup
- No decorative animation: motion only answers an action (see 4b)
- No dark mode — light Quiet stone is the only theme
