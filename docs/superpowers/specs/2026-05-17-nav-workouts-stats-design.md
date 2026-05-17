# Design: Unified Nav — Workouts + Stats tabs

**Date:** 2026-05-17
**Status:** Approved for implementation

---

## Summary

Collapse the current 6-item nav into three tabs — Home, Workouts, Stats — by merging Plans + Videos into a unified Workouts screen and folding Goals + History + LogLive into a Stats screen. Log session creation moves to a FAB on Stats. New plan creation moves to a FAB on Workouts. The Log nav tab is retired.

---

## 1. Navigation

### Bottom nav (mobile) / top nav (desktop)

Before: `Home · Plans · Log · History · Goals · Videos · Logout`

After: `Home · Workouts · Stats`

Logout moves to a small icon in the top-right corner of the Home screen. It is not a tab destination.

All nav items carry a text label beneath the icon. Active state: filled icon variant + label in accent colour (`#4A9EFF`). Inactive: outline icon + muted label.

### Route changes

| Old route | New route | Notes |
|---|---|---|
| `/plans` | `/workouts` | Source filter defaults to no filter |
| `/plans/new` | `/workouts/new` | Modal, not a tab |
| `/plans/:id/edit` | `/workouts/:id/edit` | Modal |
| `/videos` | `/workouts` | Source filter pre-set to Videos |
| `/log` | `/stats` (FAB) | No dedicated route; modal on Stats |
| `/history` | `/stats` | Folded in as a section |
| `/goals` | `/stats` | Folded in as a section |

301 redirects from `/plans` → `/workouts` and `/videos` → `/workouts` for external links.

---

## 2. Workouts screen (`/workouts`)

### Purpose

"Find something to do right now." Browse all workouts — your plans and BDT videos — in one list and start one.

### Layout (top to bottom)

1. **Header.** Title `Workouts`, subtitle `Pick something to do.`
2. **Filter bar.** Single pill-bar with vertical dividers separating three groups.
3. **Workout list.** Vertically stacked cards.
4. **FAB.** Bottom-right, accent colour, `+` icon.

### Filter bar

Single horizontal pill-bar, all pills visible without scrolling on a standard phone width. Vertical dividers (1px, `#1E2535`) separate the three groups. Single-select within each group; tapping an active pill deselects it (no "All" pill needed — nothing selected = no filter applied).

```
[ Mine | Videos  ·  6-Count | Navy SEAL  ·  L1 | L2 | L3 ]
```

Active pill: white text on `#C8D8F0` background. Inactive pill: muted text, no fill, no border (the bar container provides the boundary).

Filter logic across groups is AND. Nothing selected in a group = that dimension is unfiltered.

Filter state is reflected in the URL query string (`?source=mine&type=six_count&level=l2`) so it is shareable and back-button friendly. Persist the last selection in LiveView session assigns; restore on next visit within the same session. Do not persist across logout.

### Card design

One component, no source badge. Source is implicit from the active filter; type and level chips on the card provide enough signal when viewing "All".

```
┌─────────────────────────────────────────────┐
│  <Title>                       [type chip]  │
│                                [level chip] │
│                                             │
│  BURPEES        DURATION                    │
│  150            19:57                       │
│                                             │
│  [    ▶ Start    ]                  [ ⋯ ]   │
└─────────────────────────────────────────────┘
```

- **Plan cards.** Show burpees + duration. Overflow menu (`⋯`): `Edit`, `Duplicate`, `Delete`.
- **Video cards.** Show duration only (burpee_count may be nil). Overflow menu: absent or `Open source` if a URL is available.

### Sort order

1. Plans before videos when source filter is unset.
2. Within plans: most recently used (latest `workout_session.started_at` for this plan), then by closest total reps to the user's current level target (ascending delta), then most recently created.
3. Within videos: by `inserted_at` ascending (BDT canonical order).

### FAB

Tapping the FAB opens a bottom sheet with two options:

```
New plan
Log past session
```

`New plan` → opens existing plan editor as a full-screen modal. On save, return to `/workouts` with no filter (so the new plan is visible).

`Log past session` → opens the existing `LogLive` form as a modal. On save, return to `/workouts`.

### Empty states

| Condition | Copy |
|---|---|
| No workouts at all (first launch) | `No workouts yet. Tap + to build your first plan.` |
| Source = Mine, user has no plans | `You haven't built any plans yet.` + inline `New plan` button |
| No matches for active filters | `Nothing matches these filters.` + `Clear filters` button |

### LiveView structure

```
WorkoutsLive                    # /workouts, /workouts/new, /workouts/:id/edit
├── WorkoutsLive.FilterBar      # pill-bar, emits filter-changed events
├── WorkoutsLive.WorkoutCard    # one component, :kind assign (:plan | :video)
├── WorkoutsLive.EmptyState     # polymorphic on reason
└── WorkoutsLive.CreateSheet    # FAB → bottom sheet
```

### Domain layer

Introduce `BurpeeTrainer.WorkoutFeed` (name chosen to avoid collision with the existing `BurpeeTrainer.Workouts` Ecto context):

```elixir
defmodule BurpeeTrainer.WorkoutFeed do
  @type filters :: %{
    optional(:source) => :mine | :videos,
    optional(:burpee_type) => :six_count | :navy_seal,
    optional(:level) => atom()
  }

  @spec list(user :: User.t(), filters()) :: [WorkoutItem.t()]
  def list(user, filters \\ %{})
end

defmodule BurpeeTrainer.WorkoutFeed.WorkoutItem do
  @type kind :: :plan | :video
  defstruct [:kind, :id, :title, :burpee_count, :duration_sec,
             :burpee_type, :level, :start_path, :edit_path,
             :last_used_at, :inserted_at]
end
```

The context merges and filters results from the existing `Workouts` and `Videos` contexts. `WorkoutsLive` is ignorant of the split.

Property test: `WorkoutFeed.list(user, filter)` equals `filter(plans, f) ++ filter(videos, f)` modulo sort, for all valid filter combinations.

---

## 3. Stats screen (`/stats`)

### Purpose

"How am I doing?" Glanceable for status, scrollable for depth. Every section answers that question; nothing else lives here.

### Layout (top to bottom)

```
Stats
├─ Header
├─ This week (streak card)        [full-width, prominent]
├─ Goals                          [two fixed slots, side-by-side]
├─ Recent sessions                [last 10, "Show all" expands inline]
├─ Trends                         [2 charts default, "Show more" reveals 3 extra]
└─ [+] FAB                        [→ Log past session modal]
```

### Header

Title `Stats`, subtitle `How you're tracking.` No top-right CTA.

### Streak card

Full-width, visually dominant, top of screen.

```
┌─────────────────────────────────────────────┐
│  THIS WEEK                                  │
│                                             │
│  62 / 80 min              7 week streak     │
│  ████████████░░░░                           │
│                                             │
│  Mon  Tue  Wed  Thu  Fri  Sat  Sun          │
│   ●    ·    ●    ●    ·    ·    ·           │
└─────────────────────────────────────────────┘
```

- Minutes shown in tabular figures. Format: `actual / 80 min`.
- Streak count right-aligned same row. Format: `N week streak`. When N = 0: `No active streak`.
- Progress bar colour:
  - `actual >= 80`: accent (`#4A9EFF`), week complete.
  - `actual >= 80 * (days_elapsed / 7)`: neutral-bright, on pace.
  - Otherwise: neutral-dim, behind pace.
  `days_elapsed` = 1 on Monday through 7 on Sunday (ISO week, user local timezone).
- Day strip: seven dots Mon–Sun. Filled = any logged session that day. Today = outlined when empty. Future days = dim.
- When streak = 0 and `previous_best_weeks > 0`: show muted line below card: `Previous best: N weeks`.

### Streak mechanics

1. Week = Monday 00:00 → Sunday 23:59:59, user's local timezone (ISO 8601 week).
2. Contributions: timer sessions + manually logged sessions. No other source.
3. Streak extends iff `sum(minutes) >= 80` for that week. Strict `>=`.
4. Streak breaks when a week closes with `< 80` min. Current week is never broken mid-week.
5. New streak starts the first week after a break that hits `>= 80`.
6. `previous_best_weeks` = max streak ever achieved. Updated when the active streak surpasses it (continuously) or ends having exceeded the prior best.

`previous_best_weeks` and `previous_best_ended_on` live in a `user_stats` table. Computed and persisted inside `Streak.compute/2` on each Stats mount — not via triggers or separate workflows.

### Goals section

Two fixed slots, side-by-side, one per burpee type (6-Count, Navy SEAL). Always rendered.

Uses the existing `Goals.Goal` schema as-is: `burpee_count_target`, `duration_sec_target`, `date_target`, `date_baseline`, `status` (`:active | :achieved | :abandoned`). No schema changes.

Progress display per slot:

- **Filled (active goal):** Show target burpee count, target date, and a progress bar computed as `sessions_since_baseline_burpees / burpee_count_target`. Tap → goal detail (edit / abandon).
- **Empty, user has sessions of this type:** `No goal set` + `Set goal` button.
- **Empty, user has zero sessions of this type:** Muted `No <type> sessions yet` + smaller `Set goal` link.
- **Setting a goal when one is active:** Confirmation `Replace your current goal?` → `Replace / Cancel`. Replaced goal transitions to `:abandoned` (existing `Goals.create_goal/2` already does this atomically).

`GoalsLive` is retired. The `Goals` context is reused unchanged.

### Recent sessions

Reverse-chronological, last 10 sessions. `Show all` button expands the list inline to the full history (replaces `HistoryLive`). `HistoryLive` module is deleted.

Each row:

```
17 May                    19:57   150 burpees
Level 2 Grind · 6-Count           OK · hot
```

- Date in short locale-aware format.
- Plan name if available, otherwise `Logged manually`.
- Duration + burpee count.
- Mood + tags on secondary line if set.

Tap → session detail (notes, plan structure, edit/delete). No long-press.

Plan name follows current plan name (not denormalized at session save). If the plan is deleted, show `Deleted plan` in muted text.

### Trends

Two charts visible by default. `Show more` toggle reveals three additional charts. Hard cap: five charts total.

Default visible:
1. **Weekly minutes** — bar chart, 12 weeks, horizontal line at 80. Bar colour: accent when `>= 80`, neutral below. Rendered as server-side SVG via Contex.
2. **Volume over time** — burpees/week, 12 weeks, stacked by burpee type. SVG via Contex.

Behind `Show more`:
3. **Pace over time** — avg sec/burpee, 12 weeks, line per type.
4. **Level progression** — discrete timeline of level changes.
5. **Calendar heatmap** — 12 weeks, intensity by daily minutes.

No JS charting library. All charts are server-rendered SVG.

### FAB

Single action — `+` icon, accent colour. Tapping opens `LogLive` form as a full-screen modal. On save, Stats remounts: streak card and recent sessions update. No bottom sheet (one action only).

### LiveView structure

```
StatsLive                   # /stats
├── StatsLive.StreakCard     # streak + this-week panel
├── StatsLive.GoalSlot       # rendered twice, once per burpee_type
├── StatsLive.Sessions       # recent list + show-all expansion
├── StatsLive.Trends         # SVG charts + show-more toggle
└── StatsLive.LogModal       # FAB target; reuses existing LogLive form logic
```

`Streak.compute/2` runs on mount. Sessions are refreshed via PubSub (`"sessions:#{user_id}"`) when the log modal saves.

---

## 4. Home screen changes

- **Logout** moves from nav to a small icon (top-right of Home header).
- **Quick actions** on Home (`Run a plan` → `/workouts`, `Log a session` → Stats FAB) update their link targets.
- No other changes to `OverviewLive`.

---

## 5. Data model changes

### New table: `user_stats`

```sql
CREATE TABLE user_stats (
  user_id INTEGER PRIMARY KEY REFERENCES users(id),
  previous_best_weeks INTEGER NOT NULL DEFAULT 0,
  previous_best_ended_on TEXT,  -- ISO date, nullable
  updated_at TEXT NOT NULL
);
```

Backfill from session history in the migration (walk all sessions once, compute streak, insert row per user).

### No other schema changes

- `Goals.Goal` schema unchanged.
- `WorkoutSession` unchanged.
- `WorkoutPlan` unchanged.

---

## 6. Modules retired

| Module | Fate |
|---|---|
| `PlansLive.Index` | Replaced by `WorkoutsLive` |
| `VideoLive.Index` | Replaced by `WorkoutsLive` |
| `LogLive` | Replaced by modal on Stats and Workouts FAB |
| `HistoryLive` | Folded into `StatsLive.Sessions` |
| `GoalsLive` | Folded into `StatsLive.GoalSlot` |

Routes `/log`, `/history`, `/goals` return 301 → `/stats`.

---

## 7. Acceptance criteria

### Navigation
- [ ] Bottom nav has exactly 3 items: Home, Workouts, Stats — all labelled.
- [ ] Logout is a small icon on the Home screen, not a nav tab.
- [ ] Old routes `/plans`, `/videos`, `/log`, `/history`, `/goals` redirect to their new destinations.

### Workouts
- [ ] `/workouts` renders plans and videos in one list.
- [ ] Filter bar is a single pill-bar with dividers; single-select per group.
- [ ] Nothing selected = no filter applied (no "All" pill).
- [ ] Filter state reflected in URL query string.
- [ ] Sort: plans before videos (unfiltered), then most-recently-used, then closest reps delta, then most recently created.
- [ ] FAB opens bottom sheet with `New plan` and `Log past session`.
- [ ] `New plan` returns to `/workouts` unfiltered after save.
- [ ] Empty states render for: no content, no plans (Mine), no filter matches.
- [ ] Property test: `WorkoutFeed.list(user, filter)` equals filtered union of plans + videos modulo sort.

### Stats
- [ ] `/stats` renders streak card as the top section, full-width.
- [ ] Streak card shows minutes, target (80), progress bar, day strip, streak count.
- [ ] Progress bar colour reflects on-pace vs. behind-pace vs. complete.
- [ ] Day strip fills dots for days with any logged session in current Mon–Sun week.
- [ ] Streak resets to 0 on first render in a new week after a sub-80-minute week.
- [ ] Previous-best line renders when streak = 0 and previous_best > 0.
- [ ] Goals section renders exactly two slots, one per burpee type.
- [ ] Empty slot (no sessions of type): muted copy, smaller `Set goal` link.
- [ ] Empty slot (sessions exist, no goal): `Set goal` button.
- [ ] Replace confirmation shown when setting a goal on an occupied slot.
- [ ] Recent sessions shows last 10, reverse-chronological; `Show all` expands inline.
- [ ] Trends: 2 charts default, up to 5 with `Show more`.
- [ ] All charts are server-rendered SVG (no JS charting library).
- [ ] FAB opens log-session modal; saving updates streak card and recent sessions.
- [ ] Property test: `Streak.compute/2` over synthetic session history matches naive reference implementation.

---

## 8. Open questions (deferred)

1. Day-strip dots: tappable to jump to that session? Default: not tappable in v1.
2. Goal completion celebration: banner on next Stats visit when a goal flips to `:achieved`? Default: out of scope v1.
3. Plan name in sessions: follow renames (current plan name). Revisit if stable history becomes a requirement.
