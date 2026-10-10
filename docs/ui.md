# BurpeeTrainer — UI Specification

> Single source of truth for all visual and interaction decisions.
> Read this before touching any template or CSS.
> Design directive: quiet, warm, tasteful. Light Quiet stone is the default; optional dark mode is warm charcoal. Typography, whitespace, and thin rules carry the interface. Muted clay replaces saturated blue as the rare accent.

---

## 1. Design Principles

- **Restraint first.** If something can be removed, remove it. Every element must earn its place.
- **Hierarchy through scale and weight**, not color and decoration.
- **Warm light by default.** Quiet stone carries the app; optional dark mode shifts to warm charcoal rather than cool blue-gray.
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

Geist is the app font. Keep the type system restrained: most text uses 400 / 500 / 600 weights, with large headings using careful negative tracking.

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

## 5. Navigation and screens

There is no navigation bar. The app opens on the one thing the owner needs now, and each
screen leads to the next in context:

- **Home** (`/`) shows today's state: the ready workout with Start, or the day's insight
  once trained. The week strip opens History. Design:
  `docs/specs/2026-09-09-adaptive-home-pre-workout-design.md`, revised by
  `docs/specs/2026-10-10-frictionless-home-design.md`.
- **History** (`/history`) leads with level, this week's minutes, goals and the coach
  summary; the summary opens Coach. Design: `docs/specs/2026-10-10-frictionless-home-design.md`.
- **Coach** (`/coach`) holds the summary, goals, the message box and the notebook; back
  returns to History.
- **Session** (`/session/:session_id`, `/videos/:video_id/session/:session_id`) runs a
  workout. Design: `docs/specs/2026-07-13-workout-session-redesign-design.md` and the
  session and camera specs that follow it.

Every screen uses the `--color-base-100` page background, Geist, and Home's centred
column.

---

## 6. What We Are NOT Doing

- No navigation bar or tab bar
- No heavy dashboard treatment on Home
- No new font family beyond the existing Geist setup
- No animation beyond ring pulse and progress transitions
- No mandatory dark-first experience — light Quiet stone is default, with optional warm charcoal dark mode
