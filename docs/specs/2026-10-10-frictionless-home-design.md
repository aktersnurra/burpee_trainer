# Frictionless Home, coach summary, and one visual system

## Status

Direction chosen by the owner on 2026-10-10 after a walkthrough of the `coach-first` build.
Decisions marked **(default)** were made by the spec author and are open for owner review.
Builds on sub-projects 1–5 of `2026-10-05-coach-first-architecture-design.md`.

## Owner intent

Opening the app shows what the owner wants right now, with no fluff and no navigation bar.
It should feel LLM-enabled without friction: the coach has already done its work when the
owner arrives, and the owner never has to describe a workout just to get started.

## Problems found in the walkthrough

1. **First use is a blank text box.** A fresh user sees "Make it yours.", a free-text
   "Describe the workout you want" box, and Workouts/Videos tabs below it. A returning
   user's New is a structured form (type, style, reps, duration, pace, sets, rests). The
   two authoring entries look and behave differently.
2. **The page background changes between screens.** `body` is `#F3EEE8`, Home paints its own
   lighter surface, and History/Coach show the body colour. `docs/ui.md` specifies one page
   background, `--color-base-100` (`#F4F2EE`).
3. **The chooser uses a serif heading** ("Choose a workout"); every other screen uses Geist.
4. **History and Coach use a different layout** from Home: left-aligned, small heading,
   bare one-line empty state.
5. **Coach is two levels deep** (Home → History → Coach), its layout is broken (the
   "New info" label renders below a narrow textarea, the send button is stranded at the far
   right, the notebook hides behind "Details"), and it says nothing about progress.

## Design

### 1. First use shows a ready workout

- A user with no history and no plans gets a workout-needed Home in the `{:start, _}` state
  on first open, exactly like a returning user. The `:first_workout` state and the
  free-text bootstrap form are removed.
- **(default) Starter built-ins.** Add two built-in published plans, one per burpee type,
  sized for level 1A over 20 minutes: "Starter Six-Count" (100 reps, 10 even sets of 10)
  and "Starter Navy Seal" (40 reps, 8 even sets of 5). Pace stays inside the default
  reference ranges. A user with no completed sessions is pinned to the starter for the
  slot's burpee type; the existing 2-minute "Built-in Steady 10" stays the fallback for
  every other case.
- **Pro-rated sign-up week (owner decision).** In the local week that contains the user's
  sign-up date (`users.inserted_at` in the user's timezone), the weekly target is
  `min(20 min × days left in the week, 80 min)`, counting the sign-up day; Monday is the
  first day of the week. **The sign-up week has no catch-up sessions** (owner decision):
  every slot in it is a standard slot of `min(remaining, 20 min)`. Because the target is
  exactly 20 minutes per remaining day, one standard session per day meets it, so a
  catch-up is never needed; a missed day simply leaves the week short. Examples: sign-up
  Monday–Thursday → 80 min; Friday → 60 min; Saturday → 40 min; Sunday → 20 min, each as
  daily 20-minute sessions. Every later week uses the normal 80-minute target and the
  existing weekend catch-up rule.
- **Week model: data, not conditionals** (owner requirement: no scattered `if`s or
  flags). One pure constructor, `Coach.Policy.Week.new(sign_up_date, week_start)`,
  returns
  `%Week{start: Date.t(), target_sec: pos_integer(), catch_up_days: [1..7]}`.
  The difference between weeks is decided there once, by matching on whether
  `sign_up_date` falls in the week: a regular week → 80 min and `catch_up_days: [6, 7]`;
  the sign-up week → `min(20 min × days left, 80 min)` and `catch_up_days: []`. Everything
  downstream reads the fields and never asks whether the user is new. The existing slot
  rule changes only from `Date.day_of_week(date) in [6, 7]` to
  `Date.day_of_week(date) in week.catch_up_days`, and from the `@weekly_target_sec`
  constant to `week.target_sec`. The `Week` is the single source for slot duration and
  strategy, week-complete, Home's week strip, week close, and the `week.target_minutes`
  / `last_week.target_minutes` metrics (which today hard-code 80).
- On first open the planner job is enqueued for the slot, as after a completed session.
  When it finishes, its selection replaces the starter on the next Home render. Home
  never waits for it and shows no "planning" state.
- New opens the same structured form for every user, with one optional **Note** field
  (free text) for anything the fields do not cover. The note travels as the authoring
  instruction, as today.

### 2. Coach summary at the top of History

- History's header shows, in order: level, this week's minutes, active goals (one line),
  then the **coach summary**: at most two sentences on progress and trajectory toward the
  active goals (or toward the next level when no goal is active). The summary is a single
  link to the Coach screen.
- Home does not show the summary or a coach entry point. The only route to Coach is the
  History summary line; Coach's back control returns to History.
- `?from=` on `/coach` is removed: Coach is reached only from History.

### 3. Summary generation (LLM, validated, cached)

- `Coach.SummaryJob` (Oban, queue `coach`, unique per user while available/scheduled,
  `max_attempts: 1`) regenerates the summary. It is admitted, through a non-rolling
  `admit/1`, when:
  - a session completes (next to the planner and narration jobs);
  - a goal is confirmed or dismissed;
  - the notebook is saved from the Coach screen;
  - a week closes short of the target: the owner's local week ended with fewer completed
    minutes than that week's target (80, or the pro-rated sign-up-week target). The
    summary then reflects the shortfall even when the owner has not trained since.
- **Week close.** An hourly Oban cron job, `Coach.WeekCloseJob`, finds users whose local
  week ended within the last hour (Monday 00:00 in their timezone, so DST and timezones
  are respected) and whose completed minutes for that week are below that week's target. It admits one
  `SummaryJob` per user per closed week, unique on `(user_id, week_start)`. The closed
  week's numbers reach the model as metrics `last_week.minutes` and
  `last_week.target_minutes`, so the shortfall is stated from computed values.
- The job computes metrics with `Insights.Metrics` plus per-goal trajectory metrics
  (`goal.<id>.best_reps`, `goal.<id>.target_reps`, `goal.<id>.days_left`, and the
  existing `goal.<id>.progress_pct`, `pace.change_6w.<type>`, `streak.weeks`,
  `level.<type>`). One `Client.chat/2` call with a strict schema
  `{"text": string ≤ 280, "metric_ids": [string]}` and ledger purpose `summary`.
- The same validator rules as insights apply: every number in the text equals the
  formatted value of a cited metric, and every cited id exists. Any violation, provider
  failure or budget exhaustion stores a deterministic fallback built from the same
  metrics (for example "150 reps by 1 Dec: best so far 120. 52 days left.").
- Stored in `coach_summaries` (`user_id` unique, `text`, `metric_ids` JSON, `source`
  `llm | fallback`, `updated_at`). History reads the stored row and never calls the
  provider. With no completed session and no goal, the summary line is absent.

### 4. Coach screen

One centred column, top to bottom:

1. Heading "Coach" and the same summary text (not a link).
2. Goals: active goals with progress; proposed goals with Confirm and Dismiss.
3. Message box: full-width textarea labelled "Tell the coach", primary send button below
   it, then the latest reply. Busy state labelled "Sending to the coach".
4. "What the coach knows": the notebook, collapsed by default, with Save and Clear inside.

### 5. One visual system

- Every screen (Home, History, Coach, chooser, session pre-start) uses
  `--color-base-100` as the page background. Home's separate surface and the body's
  `#F3EEE8` are removed. Panels and the chooser use `--color-base-200` / `--color-base-300`
  as `docs/ui.md` specifies.
- Geist only: the serif chooser heading becomes the shared screen-heading style.
- History and Coach use Home's centred column width and the shared heading scale.
- Empty History state follows `docs/ui.md` empty-state rules: one calm sentence and the
  primary action (back to today's workout).
- `docs/ui.md` is updated to state there is no navigation bar; the week strip on Home is the
  entry to History.

## Error handling

- Starter pinning reuses `Workouts.ensure_home_selection/2` guards; a missing starter
  falls back to "Built-in Steady 10".
- Summary job failures never block completion, goal changes or notebook saves
  (non-rolling admission, logged as `coach_summary_not_admitted`).
- No `rescue` in the new code; the job is the crash boundary.

## Testing

- Home state: a fresh user's first open derives `{:start, _}` with the starter for the
  slot type, and the planner job is enqueued.
- Policy property test: for any sign-up date, timezone and session history, the sign-up
  week's target equals `min(20 min × days left, 80 min)` with no catch-up days; every later
  week has an 80-minute target and weekend catch-up days; no slot exceeds the remaining
  target; the sign-up week never yields a catch-up slot (every slot ≤ 20 min); weekday
  slots never exceed 20 min. Example tests for sign-up on Friday (60), Saturday (40, a 20-minute
  first slot) and Sunday (20), including a DST week.
- Summary: validator rejects unsupported numbers and unknown ids; fallback stored on
  provider failure; job admitted on completion, goal confirm/dismiss and notebook save;
  completion still succeeds when admission fails.
- Week close: a user whose local week just ended under its target gets exactly one summary
  job (repeat sweeps in the same hour are no-ops); a user who met the target (including a
  pro-rated sign-up week), or whose
  week has not ended in their timezone, gets none; the fallback text states the
  shortfall from `last_week.*` metrics.
- Full flows: fresh user → Start → complete → History shows the summary → tap → Coach →
  back to History. New form with a note authors a workout (existing flow, form-only).
- Visual contract (kept by the test policy only where it is behaviour): Coach is reachable
  only from History; no `:first_workout` state remains.

## Out of scope

Live push of a planner selection into an already-open Home, conversation transcripts,
summary history, changes to the session runner.
