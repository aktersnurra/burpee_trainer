# BurpeeTrainer — UI Specification

> Single source of truth for all visual and interaction decisions.
> Read this before touching any template or CSS.
> Design directive: quiet, warm, tasteful. Light Quiet stone is the only theme; there is no dark mode. Typography, whitespace, and thin rules carry the interface. Muted clay replaces saturated blue as the rare accent.

---

## 1. Design Principles

- **Restraint first.** If something can be removed, remove it. Every element must earn its place.
- **Show what is needed, reveal the rest when asked.** A screen starts with the one thing to do;
  what it can also do waits until the athlete asks. Swap, Edit and New are three quiet icons, a
  tap each; a swipe right is the shortcut to Swap. Hiding a control is only right when asking is
  cheap and findable, and never worth an extra tap on a way the athlete takes every week.
- **For someone who knows it.** The athlete knows the app: no hint lines, no canned replies (the
  coach's suggestions under a proposal are its guesses about this workout, not boilerplate),
  no subtitles that explain a choice, and no number said twice on one screen. Density beats
  explanation: a workout's shape reads in one line (`5 × 3 · every 8s · 4:30 rest`), with their
  best beside it.
- **Hierarchy through scale and weight**, not color and decoration.
- **Warm light, always.** Quiet stone carries the app; there is no dark mode.
- **Rare accent color.** Muted clay is the restrained accent. Orange (navy seal series) is data only.
- **No shadows, no gradients.** Flat surfaces separated by subtle borders and opacity. The
  composer (4a1) is the one exception: a faint lift that says "write here".
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

### One set of tokens (`assets/css/adaptive_home.css`, on `:root`)

Every view (Home, Progress, the drawer, the studio, sign in) takes its colours from these and
nothing else; a new hex in a rule is a bug.

```
--ink:        #262722   text, the filled pill, the chosen tab and pick
--ink-soft:   #55534c   a title under the pointer
--muted:      #696b65   secondary text, labels, icons at rest
--line:       #d6d7d0   every hairline: rows, tables, the drawer's edge, tabs at rest
--fill:       base-300  quiet buttons: steppers, suggestions, start choices that are on
--fill-hover: #e6e3db   a quiet button under the pointer
--focus:      #5e615b   every focus ring
--bubble:     #e9e5dc   your messages
--changed:    #a77b5d   the clay underline on what a proposal changed
```

### Data series (chart only)

```
six_count: #245b70   (--series-six-count)
navy_seal: #c8641f   (--series-navy-seal — data only, never UI chrome)
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
Two more sizes exist, only where a screen is built around one thing: `--text-heading` (20px,
600) names a card or a choice, and `--text-hero` (64px, 600) is the one value you are setting.
Nothing else needs a size of its own; the tokens live in `assets/css/app.css`.
Numbers that summarise something (streak, level, latest and best density, a session's reps
and time) are a display-size number with a body word beside it on one baseline.

Letter-spacing: `-0.02em` on headings/large numbers. `0.06em` on badge text (uppercase).

---

## 4. Spacing & Radius

```
--gutter:          30px   the one edge: Home, Progress, the studio and its dock share it
Section gap:       24px (space-y-6)
Card padding:      20px
Gap inside a card: 16px

--radius-surface:  20px   every card, box, sheet, drawer corner and the composer
--radius-badge:    999px  pills, chips and round buttons
--radius-input:    6px
```

A screen never shifts its left edge: the studio, the drawer's list and the docked box start where
Home's content does (`--gutter`), and a docked box is as wide as the column, not the screen.

## 4a. Lines and edges

- One column edge per screen: the progress row, header and content share the 640px column.
- One top row: the week bar's labels, the studio's back and title and the drawer's close and
  title all centre at the same height (`--top`, 32px on a phone and 48px wide, less half the
  44px button), so nothing jumps between views.
- One workout block: a workout reads the same wherever it shows (Home, Edit, a proposal, Resume):
  its name at the title size, `20 min · 15 reps` in one muted line, its sets in Home's table, and
  under it the filled pill, centred, in Home's 354px column.
- One row: a one-line row (a set, a session of the week) is 52px; a two-line row (a workout in
  the drawer, a session in Progress) has 14px above and below. Every row ends in a `--line`.
- One tab: body size, muted, the chosen one in ink over a 1.5px ink line, 24px apart (Progress's
  periods, the drawer's Workouts and Videos).
- A line marks an input (the underlined field row), a chosen tab, or data (the progress
  track, chart grid). Spacing separates everything else.

## 4a1. The composer

Every box you write words in (Edit's follow-ups, a request for New, a message to the coach) is the
composer: one rounded line (`--color-base-200`, a `--color-base-border` edge, `--radius-surface`,
a faint shadow) that grows with its text up to nine lines, the send key inside its right edge.
Its send key is a 44px target. Its placeholder names it; the label stays for screen readers. Send is a return arrow, grey until
there is something to send, then ink (always ink where an empty send is fine, as New's request);
while the coach works it is a small square. Its border darkens while focused, so the text draws
no ring of its own. There are no suggested words above it. Classes: `.composer`,
`.composer-bar`, `.composer-send`, `.composer-stop`.

On a phone the composer is one capsule, as the iOS chat apps draw it: the words and the send key
on one line, growing upward as the words wrap. A conversation's composer (a design's follow-ups,
the coach) is docked: `.chat-dock` holds it, fixed at the bottom of the screen above the home
indicator, and the `ChatDock` hook lifts it onto the iPhone keyboard with a transform, frame by
frame and never eased, so it rides the keyboard instead of trailing it. A spacer (`.chat-dock-spacer`) keeps the last line clear of
it. Your messages are soft bubbles on the right (`.studio-bubble`, `.coach-exchange-you`); new
lines rise in rather than jump.

## 4a1a. Swipes, the drawer and the studio

Swap, Edit and New are three muted 44px icons (`.home-corner`: bars, pencil, plus), a tap each,
in a centred row under the sets once the workout is opened; closed, Home is the workout and Play
alone. Every icon button (these, back and close in the studio and drawer, Progress's view
switches) is the same: 44px, plain and muted, filled on hover, pressed in on a tap. Every view
shares one 640px column. Swap opens the list of workouts and videos:

- **On a phone** it is a sheet from the bottom, as iOS does it: 88% of the screen with Home showing
  above it under a light scrim, a grip at its top edge. A pull down from the top of its list moves
  it with the finger (`SheetDrag`); let go past a quarter of its height, or with a flick, and it
  closes, otherwise it settles back. The scrim, the ✕ and Escape close it too. A sideways stroke does
  nothing on a phone.
- **On a tablet** it is a drawer from the left over the page, under the same scrim; a swipe right
  opens it and a swipe left puts it away. **At 1024px and up** it is a sidebar and the page
  re-centres beside it.
- Both slide on a transform (the list keeps `hidden` and lets `display` wait for the slide out).
  Nothing is ever wider than the screen and the page takes only vertical pans (`touch-action:
  pan-y`), so a sideways stroke never pans the page; scrollers inside it still scroll sideways.
- A tap on a workout makes it today's: its name flies from its row into Home's title while the
  list leaves. A tap on a video starts it.

Edit and New are the studio, a full-screen chat on the same page and gutter as Home. They rise from
the bottom like the sheet grown to the full screen, and drop away the same way. They are never a
sheet: a conversation needs the screen above the keyboard, and a stray pull must not throw it away.

- **Header**: a 44px Back in the corner, nothing else. Edit and New rise over Home, so Back
  points down (⌄); the one step back inside New (from a request in flight to its form) points
  left. The title is the workout itself: in Edit its name, large, under the bar (the heading is
  for screen readers); in New "New workout" in the same type and place. With a
  proposal on screen Back keeps it: it is saved and made today's workout, the studio drops away and
  the proposal's name settles into Home's title (Run still starts it at once). Otherwise Back is
  one step back, and out of the first. A drawer or sheet is closed with an x-mark, since it
  covers part of Home rather than replacing it. Where a screen's own head leads back (Progress's
  week strip), that stays.
- **Messages**: the coach's plain on the left, yours in soft bubbles on the right (one bubble,
  `--bubble`, in the studio and the coach chat alike). A workout
  reads as on Home, with no card: its name centred at the title size, minutes and reps one muted
  line, why, then the table in body size. A proposal is marked against the one it replaced
  (Edit's first, against the workout): a changed total and a changed cell take the clay
  underline. Sets read by number (`1–4`, `5`), rests as clocks (`4:30`).
- **New's form** is big numbers (`.studio-form-hero`): the burpee as two words centred, the
  chosen one in ink; duration and reps as 64px centred numbers with their unit under them and a
  plain 52px step either side that keeps stepping while held; a hint under each in small muted
  type. Style, set size, pace and the note fold under one centred **More** line that reads them
  ("Even · 4.5 s/rep") and unfolds as quiet rows between hairlines. Create workout, the one
  filled pill, sits at the foot of the screen within the thumb's reach.
- **Suggested asks**: up to three of the coach's guesses at the next change sit as quiet
  pills (`.studio-suggestion`, muted small type) just above the chat box, wrapping on a wide screen and in one sideways-scrolling row on a phone, and go while the coach works; a tap sends one as
  a follow-up.
- **Words on pills**: the studio is a conversation, so its actions are words on pills (the one
  filled ink pill per view is the way on: Run, Create workout), where the rest of the app
  uses icons (4a2). Run keeps its play mark and uses Home's camera and warmup choices; the studio
  has no toggles of its own.

A screen's seldom-used extra is an icon beside what it belongs to, opening a sheet (`.home-sheet`,
`.home-sheet-backdrop`, a grip, closed by the backdrop or Escape): the coach's memory is a bookmark
beside its note, never a section of the page.

Everything rises in with `home-enter` or `studio-in`, both `--motion-settle`; reduced motion removes
every animation here.

- Meta never joins unlike things with middle dots; each goal is its own line.

## 4a2. Actions

- One filled pill per view for the primary action, as an icon: Start and Resume are a
  play mark in a wide pill; Approve a check; Review an arrow right; sending words is the
  composer's arrow up (4a1).
- Every other action is a quiet icon from one set (heroicons), each with an `aria-label`
  and `title`, one icon per meaning everywhere: pencil-square edits, arrows-right-left
  switches or chooses a workout, plus adds or sets, trash deletes, x-mark cancels, closes,
  keeps or dismisses, check confirms, arrow-path resets, retries or reloads, chevron-down loads
  more.
- Words stay only where they are the content or an icon would be ambiguous: picks (types,
  levels, styles), tabs (period, Workouts and Videos), the coach's predicted replies, and
  "Sign in with Pocket ID". The studio (4a1a) is the one place actions are words, since it is a
  conversation; Home's play is still a play mark, and means the same as the studio's Run.
- A view switch is one icon at the end of its heading showing the view it leads to, and
  it turns into the other when tapped: list-bullet shows the sessions, chart-bar the
  chart.
- Deleting a session: tap its row and its trash shows; the first tap on the trash arms it
  (error colour), the second deletes. Tapping the row again or Escape lets go.
- A chevron only means "opens here" or, pointing down at the end of a list, "more".
- Every pick (burpee type, set style) is the same: its options as words side by side, a
  middle dot between, the chosen one in ink at 600. A destructive decision is the filled pill in
  the error colour.
- Three kinds of button and no more. The **filled pill** (ink, 48px, `--pill-h`) is the one way
  on per view: Play, Resume, Approve, Sign in, Run, Create workout. The **quiet pill** (`--fill`,
  no border) is everything secondary that is words or a step: steppers, suggestions, More, a
  start choice that is on. The **icon button** (4a1a) is the rest. Nothing has a border but
  the composer.
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
arrives in place instead of beside the old. Moving between views (Home, Progress, New, Edit) is a
view transition (`js/view_transitions.mjs`): a control marked `data-vt="forward"` or `"back"`
slides the update it causes 12px and fades it over 240ms, forward from the right, back from the
left, while the week bar holds still (Home and Progress). `"rise"` brings Edit or New up from the
bottom over 360ms while Home recedes a little, and `"drop"` sends the studio back down. With
`data-vt-from`, the workout's name travels: the element it names before the update and Home's
title after it share the `workout-title` transition name, so a name picked from the list or kept
from the studio flies into Home's title (`"attach"` is that flight with the list leaving as one
piece). Buttons that start or change something (Play, the start
choices, steppers, icon buttons) press in to 96% under the finger. Reduced motion turns it all off.

## 5. Navigation and screens

There is no navigation bar. The app opens on the one thing the owner needs now, and each
screen leads to the next in context:

- **Home** (`/`) shows today's state: the ready workout with Start (a starter workout on
  first use, never an empty prompt), or once trained, the day's result. The result's title
  opens it like the workout's onto the coach, a section of the page (never a card): the
  coach's word on the rest of the week, this week's sessions done and left in Progress's
  rows, the conversation as a chat (you on the right in a soft bubble, the coach plain on
  the left), predicted replies, "Message the coach" and waiting goals. The coach keeps its own memory; what it
  noted or forgot reads as a quiet line in the conversation. The coach speaks only once
  the day is done; `/coach` lands on Home. The week strip opens Progress. Design:
  `docs/specs/2026-09-09-adaptive-home-pre-workout-design.md`, revised by
  `docs/specs/2026-10-10-frictionless-home-design.md` and
  `docs/specs/2026-10-14-coach-on-home-design.md` and
  `docs/specs/2026-10-14-coach-card-design.md`.
- **Progress** (`/progress`; `/history` redirects) keeps the week strip on top, which leads
  back Home, then your level as its title with the streak (a flame and the weeks in a row
  at the target) opposite, then the coach's look back over recent weeks, then a gauge per burpee type
  side by side (best against goal, its course, or the next goal to set), then the period tabs,
  then **Minutes each day** drawn as GitHub draws commits (a column a week, Monday on top, the
  darker the more minutes, month names over the weeks that start them, a dark tick under a week
  that reached its target; a long period scrolls sideways and opens at the newest week), then one
  chart with both types on their own axes. Design:
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
