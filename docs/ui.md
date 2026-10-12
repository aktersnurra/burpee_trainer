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

Home, History and Coach use three sizes, as tokens in `assets/css/adaptive_home.css`:

| Token            | Size | Roles                                                         |
|------------------|------|---------------------------------------------------------------|
| `--text-display` | 28px | page heading (600), the one big number on a screen (600)      |
| `--text-body`    | 16px | what you read and tap: summaries, section headings (600), buttons (500) |
| `--text-small`   | 13px | labels, captions, goals, dates, chart scales (muted)          |

Home's workout title and result heading are the only larger display sizes.

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
  first use, never an empty prompt), or the day's insight once trained. The week strip
  opens History. Home has no coach entry. Design:
  `docs/specs/2026-09-09-adaptive-home-pre-workout-design.md`, revised by
  `docs/specs/2026-10-10-frictionless-home-design.md`.
- **History** (`/history`) keeps the week strip on top, which leads back Home, then leads
  with level, active goals and the coach summary. The summary is the only way into Coach;
  while it is refreshing it shows the app's loader labelled "Updating your summary", and
  with nothing to summarize it reads "Tell the coach what you're training for". Design:
  `docs/specs/2026-10-10-frictionless-home-design.md`.
- **Coach** opens inside History, under the summary, like the workout card on Home; there
  is no separate Coach screen. `/coach` is History with Coach open. It reads top to bottom:
  goals waiting for Confirm or Dismiss (active ones read in the header), "Tell the coach"
  with Send as an arrow inside the field once there is text, the reply, and the notebook
  collapsed under "What the coach knows". The summary and Coach share one paper surface
  (`--color-base-200`); Coach unfolds inside it. The summary and Escape close it.
- **Session** (`/session/:session_id`, `/videos/:video_id/session/:session_id`) runs a
  workout. Design: `docs/specs/2026-07-13-workout-session-redesign-design.md` and the
  session and camera specs that follow it.

Every screen uses the `--color-base-100` page background, Geist, and Home's centred
column: Home, History and Coach render in the same `.adaptive-home` container on the
layout's session surface, so the background, gutters and width never change between
them. Sheets and the chooser use `--color-base-200`. Never hard-code a page background.

---

## 6. What We Are NOT Doing

- No navigation bar or tab bar
- No heavy dashboard treatment on Home
- No new font family beyond the existing Geist setup
- No decorative animation: motion only answers an action (see 4b)
- No dark mode — light Quiet stone is the only theme
