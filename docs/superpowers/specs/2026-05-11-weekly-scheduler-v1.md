# Weekly Scheduler v1 — Design

**Status:** draft
**Date:** 2026-05-11
**Author:** brainstorm session
**Scope:** single-week scheduling for two fixed goals (six-count + navy seal). No
MILP, no periodization, no multi-week horizon. v2 retrofits those.

---

## Goal

Each Monday morning, the app produces a 4-session plan for the current week:
2 six-count sessions + 2 navy seal sessions, alternating types, biased toward
the user's preferred training days. Sessions are lightweight `ScheduledSession`
rows; the full `WorkoutPlan` materializes at training time via the existing
`StyleRecommender` + `StyleGenerator` path.

## Non-goals (v1)

- Periodization (build/deload phases) — deferred to v2
- Multi-week solve / planning horizon — deferred to v2
- Mixed-integer programming — deferred to v2 where it earns its keep
- Goal types beyond `:six_count` and `:navy_seal`
- Day-of-week × style-performance scoring
- "Today I'm too tired" / interactive reschedule UX

---

## Data model

### `ScheduledSession` (new Ecto schema)

```
id              :binary_id
user_id         references users
goal_id         references goals
date            :date                         # the day this session is for
burpee_type     :string                       # "six_count" | "navy_seal"
target_reps     :integer
state           :string                       # "pending" | "rolled" | "missed" | "completed"
rolled_from     :date | nil                   # if state=pending and was rolled, original date
workout_session_id  references workout_sessions, nullable
inserted_at, updated_at
```

State transitions:

- `pending` → `completed` when a `WorkoutSession` for this `ScheduledSession`
  is completed (fulfillment link set then, per Q11c)
- `pending` → `rolled` when end-of-day passes without completion AND there is
  a future available day this week with no session yet → a NEW `pending` row
  is created on that day with `rolled_from = original_date`; old row stays as
  `rolled` for audit
- `pending` → `missed` when end-of-day passes without completion AND no future
  available day remains this week

Indexes: `(user_id, date)`, `(user_id, state)`.

### `User.available_days` (new field)

```
available_days :string   # comma-joined: "mon,tue,wed,thu,fri,sat,sun"
                          # default: "mon,tue,wed,thu,fri,sat,sun" (all 7)
```

Editable via a Settings UI (multi-select checkboxes). Used by the scheduler
to constrain day selection.

### `WorkoutSession.scheduled_session_id` (new nullable FK)

Set when a session is completed (Q11c) so we can mark the corresponding
`ScheduledSession` fulfilled. Nullable because ad-hoc workouts (no schedule)
remain possible.

---

## Modules

### `BurpeeTrainer.Schedule` (new context)

```
list_week(user, start_date) :: [ScheduledSession]
get_today(user) :: ScheduledSession | nil
generate_week(user, start_date) :: {:ok, [ScheduledSession]} | {:error, term}
roll_missed_sessions(user, today_date) :: {n_rolled, n_missed}
fulfill(scheduled_session, workout_session) :: {:ok, ScheduledSession}
```

`generate_week/2`:

1. Loads active goals for the user (expect at most one per burpee type).
2. For each goal, calls `Progression.recommend_weekly_volume/2` → integer.
3. Calls `Scheduler.pick_schedule/1` (pure module) with the inputs.
4. Persists `ScheduledSession` rows in a single transaction.
5. Idempotent: if rows already exist for that week, returns existing.

`roll_missed_sessions/2`: scans yesterday's `pending` rows, applies the
roll-forward rule per Q10b, creates replacement rows where possible.

### `BurpeeTrainer.Scheduler` (new pure module)

```
pick_schedule(%Request{
  week_start :: Date,                       # Monday
  available_days :: [:mon | :tue | ... ],
  goals :: [
    %{burpee_type: :six_count | :navy_seal, weekly_volume: pos_integer}
  ],
  reserved_dates :: [Date]                  # days already containing sessions
                                            # (used by roll-forward re-solve)
}) :: {:ok, [%{date, burpee_type, target_reps}]} | {:error, atom}
```

Pure. No I/O. No DB. Returns up to 4 sessions (2 per goal). May return fewer
if `available_days` doesn't have room.

**Algorithm:**

1. **Day selection.** From `available_days`, drop `reserved_dates`. Sort by
   `day_preference[d]` ascending, take the first 4. If <4, return what we
   can (caller decides if that's an error).
2. **Type assignment.** Sort the 4 chosen dates ascending. Alternate types
   starting with `:six_count`: positions 1,3 → six-count; 2,4 → navy seal.
3. **Volume split.** For each type, `[div(v,2), v - div(v,2)]`. Assign the
   larger half to the earlier session (small tiebreaker favoring early-week
   intensity).

Day preference table (per Q7):

```
mon → 0, tue → 0, thu → 0, fri → 0
wed → 2
sat → 3, sun → 3
```

Ties broken by chronological order within the week.

### `BurpeeTrainer.Progression` (extend)

Add:

```
recommend_weekly_volume(user, burpee_type) :: pos_integer
```

Implementation derives from existing `Progression.recommend/2` trend logic:
take recent (last 4 weeks) completed sessions of `burpee_type`, compute a
weekly average, apply the safe progression cap (~15% w/w increase max),
return rounded integer. If no history, fall back to goal baseline.

This keeps "how fast to progress" in `Progression`, away from `Scheduler`.

### `BurpeeTrainer.SchedulerCron` (new GenServer)

- On `init/1`: compute next fire time. Fire times are:
  - **Monday 06:00 local** → `generate_week/2` for current week (Q8c)
  - **Daily 00:05 local** → `roll_missed_sessions/2` for the user
- Uses `Process.send_after/3`, re-arms on each fire.
- Re-arms on app boot via `application.ex` supervision tree.
- Single user (this is a personal app) so we don't iterate users — but the
  context functions take a `user` arg to keep the door open.

Timezone: use `Application.get_env(:burpee_trainer, :timezone, "Europe/Stockholm")`
or similar — TBD whether to hardcode or read from user. v1: hardcode to local
system time (`NaiveDateTime.local_now/0`-equivalent via DateTime + tz).

### `BurpeeTrainerWeb` integration

- **HomeLive / GoalsLive**: new "This week" panel showing the 4 scheduled
  sessions for the current week, grouped by date. Each card shows:
  date · burpee_type · target_reps · state badge.
- **Tap behavior**: tapping a `pending` session card:
  1. Calls `StyleRecommender.recommend/2` with the burpee type
  2. Calls `StyleGenerator.generate/2` to produce a `%WorkoutPlan{}`
  3. Saves the plan, links `scheduled_session.plan_id`-equivalent via the
     `WorkoutSession` it eventually generates (deferred until completion
     per Q11c). For v1 we hand the plan to `PlannerLive` and pass the
     `scheduled_session_id` through so the eventual `WorkoutSession` carries
     the FK.
- **Settings**: new "Available training days" multi-select.

---

## Roll-forward rule (Q10b detail)

At 00:05 each day, for every `pending` row with `date < today`:

1. Compute remaining available days this week (Mon-Sun ISO week of the
   original date) that are in `user.available_days`, are `>= today`, and
   are not yet occupied by a `pending` or `completed` row.
2. If at least one remaining day exists, pick the one with lowest
   `day_preference[d]`. Insert a new `pending` row on that date with the
   same `goal_id`, `burpee_type`, `target_reps`, `rolled_from = original`.
   Mark the original row `rolled`.
3. If no remaining day exists, mark the original row `missed`. No
   replacement. Next Monday's `generate_week/2` will see the miss reflected
   in `Progression`'s view of recent completed volume.

Edge case: rolling can cascade — a session rolled to Wednesday that's then
missed Wednesday gets considered again Thursday. The `rolled_from` chain
preserves the audit trail. Cap: a single original session can roll at most
once (if the rolled replacement is missed, it goes straight to `missed`,
not rolled again). Prevents thrashing.

---

## Idempotence & re-runs

- `generate_week/2` is idempotent: if any `ScheduledSession` exists for the
  target week, it returns those rather than regenerating. Manual "regenerate
  this week" requires deleting the rows first (admin/dev only for v1).
- The cron firing twice on the same Monday is therefore safe.
- Roll-forward inserts only if no replacement already exists for the chosen
  date, so it's also idempotent within a day.

---

## Errors / edge cases

- **No active goals.** `generate_week/2` returns `{:ok, []}`. Cron logs and
  moves on.
- **Available days < 4.** `Scheduler.pick_schedule/1` returns the best it can
  (1-3 sessions). UI shows a notice: "Only N sessions could be scheduled —
  check your available days."
- **One goal only (e.g. user paused navy seal).** `Scheduler` should still
  produce sessions for the active goal; type-alternation rule degrades to
  "all sessions are the active type." Volume split still applies.
- **Progression returns 0.** Skip that goal for the week. UI shows
  "Not scheduled — insufficient recent activity."

---

## Out of scope (v2 candidates)

- Multi-week horizon (4-12 week build phases with periodization)
- MILP-based scheduling — earns its keep when soft constraints conflict
- Deload weeks (every 4th week at 80% volume)
- Interactive reschedule ("move Tuesday's session to Wednesday")
- Day-of-week × time-of-day × style performance scoring
- Goal types beyond six-count + navy seal
- Push notifications for upcoming sessions

---

## Test surface

- `Scheduler.pick_schedule/1` — property-based tests via StreamData:
  invariants are "≤4 sessions returned", "types alternate", "volume sums
  match input", "no day outside available_days", "no day in reserved_dates".
- `Schedule.generate_week/2` — integration test with seeded goals and
  Progression stub.
- `Schedule.roll_missed_sessions/2` — exercises the cascade cap, the
  no-room-left → `missed` path, and the normal roll path.
- `SchedulerCron` — manual nudge via `send/2` rather than waiting for
  wall-clock; assert it triggers the context functions.
- LiveView: "This week" panel renders, tap-to-train wires through.

---

## Open questions (flag during plan)

1. Timezone source: hardcode `"Europe/Stockholm"` or add a user setting?
   v1 lean: hardcode in config.
2. Should the "rolled" original row be hidden from UI or shown greyed? v1
   lean: shown greyed with "rolled to <date>" hint.
3. If user manually starts a workout that doesn't match any pending
   `ScheduledSession`, does it create one retroactively or stay ad-hoc?
   v1 lean: stay ad-hoc; `scheduled_session_id` is null.
