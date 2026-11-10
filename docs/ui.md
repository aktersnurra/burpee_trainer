# BurpeeTrainer — UI Specification

> Single source of truth for all visual and interaction decisions.
> Read this before touching any template or CSS.
> Design directive: quiet, warm, tasteful. Light Quiet stone is the only theme; there is no dark mode. Typography, whitespace, and thin rules carry the interface. A few muted colours each mean one thing.

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
  explanation: a workout's structure reads as one plain sentence (`5 sets of 3 · 4:30 rest`;
  `One rep every 27 s, all the way` when it has no rest).
- **Hierarchy through scale and weight**, not color and decoration.
- **Warm light, always.** Quiet stone carries the app; there is no dark mode.
- **A colour means one thing.** Ink and greys carry the app; the few colours (2) each say one
  thing wherever they show, and never decorate.
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

### The session at night (`.session-night`, camera setup and the runner)

The runner is the app turned inside out: `--ink` is the ground and the paper the numbers.
Pace and breath are data, never decoration. Finish (4a2) keeps the light tokens.

```
--session-ground:   #262722   the ground of every runner screen (--ink)
--session-ink:      #F4F2EE   the number, icons, the workout line's elapsed part
--session-muted:    #A9A79F   secondary text (sets done in a rest, pause, camera setup)
--session-track:    #3A3B35   the workout line's track; quiet chips
--session-on-fill:  #262722   the number where a fill or the sink's disc covers it
--pace-steady:      #FFA557   the rep fill on the beat; the final-three ring
--pace-ahead:       #90A959   the rep fill ahead; the skeleton once the camera has you
--pace-behind:      #B46958   the rep fill behind
--session-breath:   #BAD7FF   the sink's disc and its air
--session-last:     #F4BF75   the number on the set's last rep
```

Screens are four parts: the workout line on top, the title block (name and a muted line),
the number or the sink in the middle, and the foot (rest's `7/20` or the camera-lost chip).
Actions are 44px round chips with an icon, an `aria-label` and a `title`: continue without
camera, try the camera again, finish early, abort. Finish early and Abort ask before they act:
the first tap arms one (`aria-pressed`, "Tap again to …"), its question takes the title's and
the pause mark's place ("Finish early? What you've done is kept." or "Abort workout? It won't be
saved."), the other chip steps aside and the armed one slides to the centre, filled: paper for
Finish early, `--pace-behind` for Abort. The second tap acts. Escape or a tap elsewhere runs it
back, still paused.
On camera setup your pose is drawn over the feed (`pose_overlay.mjs`): a fine line with a soft
glow, ringed joints and a ring round the head, in `--session-ink` while the camera looks for you,
with a scan line passing down your body (none under reduced motion); once it has you, in
`--pace-ahead`, glowing brighter, the joints filled.
Design: `docs/specs/2026-11-05-night-session-runner-design.md`.

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
```

### Colours that mean something

One palette across every view. A colour means one thing.

| Token | Hex | Means |
|---|---|---|
| `--six` | `#1f3f73` navy | six-count: its days, its solid line, its picked type |
| `--seal` | `#86aee0` sky | Navy SEAL: its days, its picked type (its text there is `--six` 75% into `--seal-line`, since sky is too light to read) |
| `--seal-line` | `#5f8fcf` | Navy SEAL's dashed line and its marks |
| `--cobalt` | `#2f63ad` | as a tint: what the coach changed; an OK session |
| `--good` | `#3f9161` | a Good session |
| `--clay` | `#b46958` | at stake: abort, delete, where you stopped; a Rough session |
| `--amber` | `#c48a24` | Finish's tags; the streak's flame |

A choice is a soft tint of its colour with a thin ring of it and its text in the full colour
(`rgba(c, .16–.32)` fill, `inset 0 0 0 1px rgba(c, .45–.6)`), never a solid fill.

The diff shows what a proposal changed: the old value struck through in `--muted`
(`.diff-was`), the new one on a soft cobalt highlight (`--cobalt` at 16%, a 3px corner, 4px
either side: `.diff-now`, and a changed cell's value in the set table).

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
  its name at the title size, `20 min · 15 reps` in one muted line, its structure as a sentence
  in small ink type (`Workouts.Shape`), its sets in Home's table, and under it the filled pill,
  centred, in Home's 354px column.
- One row: a one-line row (a set, a session of the week) is 52px; a two-line row (a workout in
  the drawer, a session in Progress) has 14px above and below. Every row ends in a `--line`.
- One tab: body size, muted, the chosen one in ink over a 1.5px ink line, 24px apart (the
  drawer's Workouts and Videos).
- A line marks an input (the underlined field row), a chosen tab, or data (the progress
  track, chart grid). Spacing separates everything else.

## 4a1. The composer

Every place you write (Edit's follow-ups, the coach, New's request, Finish's note) is one box,
the composer: `--color-base-200`, a `--line` edge, `--radius-surface` corners and the faintest
lift. At rest it is about two lines tall (84px), its placeholder at the top left; it grows with
its text, up to nine lines when docked. The words fill the box, so a tap anywhere in it writes.
Its placeholder names it; the label stays for screen readers. Its border darkens while focused,
so the text draws no ring of its own. The box is the same on a phone and a wide screen.

Where it sends on its own (Edit, the coach) the send key sits in the bottom-right corner, inside
the box: a 34px circle in a 44px target. It is grey until there is something to send, then ink;
the composer stays grey while the coach works. With a mouse and keyboard, Enter sends and
Shift+Enter starts a new line; on a touch screen the return key is a new line and the arrow sends
(`ChatDock`). New's note and Finish's note go with the screen's
✓ and have no send key. Classes: `.composer`, `.composer-bar`, `.composer-send`.

A conversation's composer (a design's follow-ups, the coach) is docked: `.chat-dock` holds it, fixed at the bottom of the screen above the home
indicator, and the `ChatDock` hook lifts it onto the iPhone keyboard with a transform, frame by
frame and never eased, so it rides the keyboard instead of trailing it. A spacer (`.chat-dock-spacer`) keeps the last line clear of
it. A screen with a dock (Edit and New's chat, the Coach page, Home once the day is done) scrolls
inside itself, as tall as what the keyboard leaves (`--viewport-height`), and the page stays at
the top: were the page to scroll, iOS would slide it under the keyboard and the box would trail. Your messages are soft bubbles on the right (`.studio-bubble`, `.coach-exchange-you`); new
lines rise in rather than jump. A message moves into the thread when it is sent and the box
empties (it comes back if the coach cannot answer).

Every reply streams, as in LibreChat: the app's loader until the first word, then the words as the
coach writes them, plain on the left with a soft dot after the last one (`.chat-streaming`, still
with reduced motion). The model's thinking is never shown. On the Coach page that is the reply; in
Edit and New it is the coach's reason for the proposal, and the card follows it once its sets
check out.

## 4a1a. Swipes, the drawer and the studio

Swap, Edit and New are three icons in the start toggles' pill (`.home-corner`: bars, pencil,
plus; 44px tall, `--color-base-200`, ink), a tap each, in a centred row under the sets once the
workout is opened; closed, Home is the workout and Play alone. Every other icon button (back and
close in the studio and drawer, the drawer's filter) is the same: 44px, plain and muted,
filled on hover, pressed in on a tap. Every view
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
- The filter icon (adjustments) at the tabs' end opens the filters under them: the two types and
  the eight levels as picks (4a2), with a reset (arrow-path) beside "Levels". They start on both
  types and the athlete's level and every one above, so an easier workout waits behind a tap. A
  workout's level is that of the 20-minute session it is as good as, fatigue counted, so a long
  catch-up is not graded on its raw reps. With the filters hiding everything, the list says so
  ("No workouts match these filters."); with nothing at all, "No workouts yet."

Edit and New are the studio, a full-screen chat on the same page and gutter as Home. They rise from
the bottom like the sheet grown to the full screen, and drop away the same way. They are never a
sheet: a conversation needs the screen above the keyboard, and a stray pull must not throw it away.

- **Header**: a 44px button in the corner, nothing else. Edit's is Close (x-mark). New's form has
  none: it closes from its foot (below). With New's proposal on screen it is Close too; the one
  step back inside New (from a request in flight to its form) points left. The title is the workout itself: in Edit its name, large, under the bar (the heading is
  for screen readers); in New "New workout" in the same type and place. Close always leaves with
  nothing changed, a proposal on screen included.
- **A proposal** is the coach's message, on the left like its words: its reason, then the card
  (name, totals, sentence, sets), then two pills under it, left-aligned: Save (✓, the toggles'
  soft pill) saves it and makes it today's workout, the studio drops away and its name settles
  into Home's title; Run (the ink play pill) does that and starts it. A drawer or sheet is closed with an x-mark, since it
  covers part of Home rather than replacing it. Where a screen's own head leads back (Progress's
  week strip), that stays.
- **Messages**: the coach's plain on the left, yours in soft bubbles on the right (one bubble,
  `--bubble`, in the studio and the coach chat alike). A workout
  reads as on Home, with no card: its name centred at the title size, minutes and reps one muted
  line, why, its structure sentence, then the table in body size. One workout is on screen at a
  time: Edit opens on today's, and once you ask, your words stand at the top and only the
  proposal follows. A proposal is marked against the one it replaced (Edit's first, against the
  workout): a changed total shows the diff (2), the old number struck through and the new one
  highlighted; a changed structure is followed by `was 5 sets of 3` struck through in grey; a
  changed Reps, Every, Move or Rest cell is highlighted (never the Set column). Sets read by
  number (`1–4`, `5`), rests as clocks (`4:30`).
- **New's form** is big numbers (`.studio-form-hero`): the burpee as two pills centred, the
  picked one in its type's tint (2); duration and reps as 64px centred numbers with their unit
  under them and a plain 52px step either side that keeps stepping while held, the week's time
  left under the duration. Under them, the structure sentence of what the form would make
  (`One rep every 27 s, all the way`; `4 sets of 10 · 4:53 rest`), changing as the values do
  (`NewWorkoutForm.shape/1`). Then quiet rows labelled like settings, between hairlines: **Sets**
  (Even / Unbroken pills, the picked one in the picked type's tint), **Set size** (Unbroken only)
  and **Pace** (`− 8.0 s +`), each a 36px step in a 44px target. Then the request box (4a1), no
  send key. The foot holds X (Close, a quiet 44px round) on the left and the ✓ pill (Create) on
  the right; it stays at the bottom of the screen within the thumb's reach, the form fading out
  under it.
- **Suggested asks**: up to three of the coach's guesses at the next change sit as quiet
  pills (`.studio-suggestion`, muted small type) just above the chat box, in one row that
  scrolls sideways and fades at its right edge (on a phone the row runs on to the screen's
  edge), and go while the coach works; a tap sends one as a follow-up.
- **Words on pills**: the studio is a conversation, so its actions are words on pills (the one
  filled ink pill per view is the way on: Run, New's ✓), where the rest of the app
  uses icons (4a2). Run is Home's play pill, the mark alone (labelled "Run"), and uses Home's
  camera and warmup choices; the studio has no toggles of its own.

A screen's seldom-used extra is an icon beside what it belongs to, opening a sheet, never a
section of the page. The coach's memory is the bookmark on the Coach page's top row, and opens
on a phone in the workout picker's bottom sheet (`.home-sheet`, `.home-sheet-backdrop`): 88% of
the screen, a grip, the x-mark and "What I remember" on its top row, under the scrim. On a wide
screen (601px and up) it is a popup instead: centred, 480px wide, as tall as its lines (at most
80% of the screen), no grip, settling in place. The ✕, the scrim, Escape or a pull down
(`SheetDrag`, on a phone) close it, and focus returns to the bookmark. Its two parts,
"About you" and "Coaching notes", each have a short cobalt track for how full they are; the lines
are read only; a line the coach rewrote this week wears the diff's cobalt highlight (2); "To
change a line, tell the coach." closes it.

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
  levels, styles), tabs (Workouts and Videos), the coach's predicted replies, and
  "Sign in with Pocket ID". The studio (4a1a) is the one place actions are words, since it is a
  conversation; Home's play is still a play mark, and means the same as the studio's Run.
- Deleting asks in place, never in a browser dialog: the first tap on the trash arms it (error
  colour, "Confirm delete …"), the second deletes. A session opens from its point on Progress's
  chart, its trash at the row's end; tapping the point or the row again, or Escape, lets go. A
  workout in the drawer arms the same way; switching tab or closing the drawer lets go, and its
  past sessions stay.
- Finish (the light screen after a session): `Ended early` or the plan's name, the count between
  quiet − and +, `of 15 reps · 10:20 of 20:00`, `3 of 5 sets` (the plan's whole sets the
  schedule reached), who counted, the mood pills (Rough `--clay`, OK `--cobalt`, Good `--good`,
  each a soft tint when chosen), the tags (amber when chosen), the note (4a1), and the foot:
  trash a quiet round on the left, ✓ the ink pill (Save) on the right. Trash asks in place as
  Abort does in the runner: the first tap arms it (`aria-pressed`, "Tap again to delete", the
  question said aloud), the page steps back out of reach, ✓ shrinks away and trash slides to
  the middle in `--clay` under "Delete this session?"; the second tap deletes. A tap anywhere
  else or Escape lets go. Every session ends on this screen
  (`SessionComponents.completion_review/1`): the runner's hook drives a plan's; a video's
  LiveView drives its own through the component's `events`, its title the video's name, the
  count typed as well as stepped, and `of 100 reps · 5:12 of 20:00` (the video's count when
  it has one, the time watched).
- Watching a video: the title, the video, and under it Finish early (flag) and Abort (X) as
  quiet 48px rounds. Each asks in place as the runner's pause does: the title gives way to
  "Finish early?" or "Abort workout?", the other round steps aside and the armed one slides
  to the middle (Finish early in ink, Abort in `--clay`); the second tap acts, a tap anywhere
  else or Escape lets go. With Home's camera toggle on, the camera sets up as the page opens,
  as the plan session's camera setup: the feed fills the screen under its vignette, the status
  at the top ("Starting camera", "Step into frame", then "Hand up" over "or tap play") and the
  chips at the foot (play, and the camera with a slash to carry on without it); Back to Home
  at the top left. A raised hand plays the video (no timer: it never starts while you step
  back), as does the play chip; refused without a tap, the status says "Tap play" and the chip
  fills and breathes (under reduced motion it only fills). Playing, the feed sits small and mirrored in
  the video's top-right corner with the count over it, counting from the first frame of the
  video, and Finish starts at that count ("Counted by camera", then "Camera counted 97" once
  corrected). A camera that cannot start says "Camera unavailable" over Retry and the slashed
  camera; without it the video plays as before and the athlete counts.
- A chevron only means "opens here" or, pointing down at the end of a list, "more".
- Every pick (burpee type, set style) is the same: its options as quiet pills side by side, the
  chosen one a soft tint of its colour (2), never solid ink; a set style takes the picked type's
  tint. A destructive decision is the filled pill in the error colour.
- Three kinds of button and no more. The **filled pill** (ink, 48px, `--pill-h`) is the one way
  on per view: Play, Resume, Approve, Sign in, Run, New's ✓. The **quiet pill** (`--fill`,
  no border) is everything secondary that is words or a step: steppers, suggestions, picks at rest, a
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
piece). Play grows into the runner: an ink curtain opens from the pill's box to the screen over
360ms (`js/session_curtain.mjs`, since Play is a live navigation the patch transitions cannot
see), and leaving a night screen by live navigation shrinks it back into Play. Buttons that start or change something (Play, the start
choices, steppers, icon buttons) press in to 96% under the finger. Reduced motion turns it all off.

## 5. Navigation and screens

There is no navigation bar. The app opens on the one thing the owner needs now, and each
screen leads to the next in context:

- **Home** (`/`) shows today's state: the ready workout with Start (a starter workout on
  first use, never an empty prompt), or once trained, the day's result. Done is one order,
  never a card: the result, this week's sessions done and left in Progress's rows, then the
  chat under a small "Coach" with its bookmark (which opens the Coach page): the coach's word
  on the rest of the week is its first message, then the conversation (you on the right in a
  soft bubble, the coach plain on the left), "Message the coach" and waiting goals. The coach
  keeps its own memory; what it noted or forgot reads as a quiet line in the conversation. The
  coach speaks on Home only once the day is done. The week strip opens Progress. Design:
  `docs/specs/2026-09-09-adaptive-home-pre-workout-design.md`, revised by
  `docs/specs/2026-10-10-frictionless-home-design.md` and
  `docs/specs/2026-10-14-coach-on-home-design.md` and
  `docs/specs/2026-10-14-coach-card-design.md`.
- **Progress** (`/progress`; `/history` redirects) keeps the week strip on top, which leads
  back Home, then your level as its one headline with the streak (an amber flame and the weeks
  in a row at the target) opposite. "Best in 20 minutes" sits over two columns, one per type:
  its mark and name, the best at 30px, what the next level needs (`✓ 1B needs 50` once the
  best is past it; the next level is said only here), then its goal when it has one. The coach's look back follows as one paragraph under the page's only rule, all
  of it a link to the Coach page (`Coach ›` over it), which opens on it. With the app's coach,
  `Coach ›` stays when there is no look back, so Progress always leads to the coach.
  **Days you trained** is drawn as GitHub draws contributions: square cells, a column a week
  from Monday, Mon/Wed/Fri on the left, month names over the weeks that start them, each day
  navy for six-count, sky for Navy SEAL, split diagonally for both, a quiet fill for none; a
  phone shows the latest 18 weeks and the 640px column 34, and a key gives their minutes. The
  grid never changes. **Reps per 20 minutes** covers the last 12 weeks, with no window tabs or
  list: one chart, six-count off the left axis as a solid navy line, Navy SEAL off the right as
  a dashed sky one, each axis's numbers in its line's colour, a small legend above and months
  below. A session longer than 20 minutes is drawn as the 20-minute session it is as good as,
  fatigue counted (`Coach.Endurance`): 105 reps in 40 minutes reads 70. A point opens its
  session under the chart: name, date, reps, time, tags and its trash. Design: `docs/specs/2026-11-06-light-screens-design.md`.
- **Coach** (`/coach`, with the app's coach; without it, Home) is the coach's own page. Its top
  row: Back (a chevron, to where you came from: `/coach?from=progress` back to Progress, else
  Home), "Coach", and the memory bookmark (4a1a). Then this week's sessions as on Home done (no
  week bar: the header is enough), then the same chat, the box docked at the foot. Its first message is the coach's
  word on the week, or, arriving from Progress, the look back. The coach has no suggestions of its
  own, so there is no suggestions row. Leaving after the coach wrote to its memory as it talked
  here writes the summary again. Design:
  `docs/specs/2026-11-06-light-screens-design.md`.
- **Session** (`/session/:session_id`, `/videos/:video_id/session/:session_id`) runs a
  workout at night: the inverted palette above, a fill per rep that follows the camera, and a
  breathing sink in rests. Design: `docs/specs/2026-11-05-night-session-runner-design.md`,
  over `docs/specs/2026-07-13-workout-session-redesign-design.md` and the session and camera
  specs that follow it.

Every screen uses the `--color-base-100` page background, Geist, and Home's centred
column: Home and Progress render in the same `.adaptive-home` container on the
layout's session surface, so the background, gutters and width never change between
them. Sheets and the chooser use `--color-base-200`. Never hard-code a page background.

### How the screens are rendered

Home, Progress and Coach are one LiveView (`HomeLive`), and only what changed is sent to the
browser. Two rules keep it so:

- `HomeLive.render/1` calls a screen (`HomeScreen.screen/1`, `HistoryScreen.screen/1`,
  `HomeCoachComponents.page/1`) as a function with its own assigns, so the screen reads `@name`
  as the view does.
- Every component under a screen declares the values it reads as attributes and is given each
  one by name. Never pass a component all the assigns (`{assigns}`, `state={assigns}`): LiveView
  then sends the component's whole content again on every update.

---

## 6. What We Are NOT Doing

- No navigation bar or tab bar
- No heavy dashboard treatment on Home
- No new font family beyond the existing Geist setup
- No decorative animation: motion only answers an action (see 4b)
- No dark mode — light Quiet stone is the only theme
