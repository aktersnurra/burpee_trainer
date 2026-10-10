# Home state machine and scoped authorization

## Status

Sub-project 3 of `2026-10-05-coach-first-architecture-design.md`, written 2026-10-05.
Requires the legacy cull. Decisions marked **(default)** were made by the spec author and are
open for owner review. Visual design of Home, History and Coach is unchanged.

## Problem

Home's behaviour is spread across `Coach.Policy`, `Workouts.home_entry_state/2`,
`Workouts.ensure_home_selection/2`, `HomeSelection`, `CoachReconciler`, and a 2,000-line
`OverviewLive` that also hosts History and Coach. The set of states and which action each
offers is implicit, so it cannot be tested exhaustively. Authorization is re-verified at
several layers with ad hoc `%User{}` matching.

## Design

### Facts and state (functional core)

`BurpeeTrainer.Home` has two functions:

- `Home.facts(scope, now) :: {:ok, Home.Facts.t()} | {:error, :invalid_timezone}` — the
  only effectful part: loads the policy slot (`Coach.Policy.required_slot/2`), the started
  session, the slot's selection (plan or video, if any), and whether the user has any
  history or owned plan.
- `Home.state(facts) :: Home.State.t()` — pure. Exactly one of:

| State | When | Primary action |
|---|---|---|
| `{:resume, session}` | a started session exists | Resume (client relabels to "Review & save" when a local completion draft exists, as today) |
| `{:start, selection}` | slot needs a workout and a selection exists | Start |
| `:first_workout` | slot needs a workout, no selection, no history and no owned plan | Describe first workout (existing bootstrap prompt) |
| `:choose` | slot needs a workout, no selection, but history or plans exist | Open chooser |
| `{:done_today, results}` | today's slot is done | Insights (opens History) |
| `{:week_complete, results}` | weekly target met | Insights (opens History) |

Precedence is top to bottom: a started session always wins. `:choose` only occurs when no
selection could be ensured (for example the fallback plan is missing); in normal operation
`Home.facts/2` ensures a selection via `Workouts.ensure_home_selection/2` before deriving
state.

### Routed workspace LiveView (owner-approved revision)

The owner approved this revision during implementation: one `HomeLive` process serves
three routes via `live_action`, preserving unsaved UI state without a new cache or storage
mechanism. Screen responsibilities are extracted into cohesive ordinary web modules:

- `/`, action `:home`, renders `Home.State` and owns Start/Resume, Switch (chooser),
  New/Edit authoring, and the day-boundary timer.
- `/history`, action `:history`, owns the period, week, session detail and delete flows
  (`home_history_components.ex`). Weekly progress on Home patches here.
- `/coach`, action `:coach`, owns the Coach summary, details and new-info box
  (`home_coach_components.ex`). It is reached from History and from the done-today and
  week-complete states. `?from=history|home` determines the return route; unsupported or
  missing values default to Home, never an arbitrary URL.
- All three routes target the same LiveView inside the same authenticated live session.
  Within this workspace, links use `patch` and handlers use `push_patch`; entering from
  a different LiveView uses normal navigation. `/?history=1` patches to `/history`.

Initialize draft forms once per mount. Screen changes must not overwrite an unsent Coach
message or Home working adjustment/expansion. Both survive a History roundtrip in the
same LiveView process; merely visiting History must not persist guidance or mutate the
Home selection. Refresh screen data separately from draft state. Browser reload, logout,
leaving this LiveView, or process termination is not given a new persistence guarantee.
No ETS/GenServer cache, browser draft storage, or database draft feature is added here.

This supersedes the original three-independent-LiveView default, not the pure Home core,
Scope migration, visual-preservation requirement, or approximately-800-line LiveView
limit. Existing element IDs used by tests and the browser runbook stay the same where the
element still exists; screen focus/keyboard/isolation assertions remain meaningful.

### Missing-selection recovery (owner-approved addition)

A genuine `:choose` state must offer usable existing catalog choices even when the
shared fallback is unavailable. The owner approved dedicated recovery commands, not
broader first-use authorization or fabricated HomeSelection/CAS tokens:

- `Workouts.current_home_selection(scope, slot)` is a read-only lookup of the verified
  current plan selection for that actor and slot, returning a selection or nil without
  creating, repairing, publishing, detaching or pinning anything.
- `Workouts.recover_home_workout_selection(scope, slot, plan_id)` returns the newly
  pinned HomeSelection only after an explicit choice. In an immediate transaction,
  re-read the current owned slot/eligibility, reject an active session or now-valid
  selection, validate the owned or shared published plan and its canonical hash, then
  create/use the actual slot recommendation and pin through existing revision/CAS
  machinery. Concurrent recovery must not replace the winner's valid selection.
- `Workouts.start_recovery_home_video(scope, slot, video_id, token)` starts an available
  canonical video under the same missing-selection/slot/eligibility guards, preserving
  exact-token/source/hash replay and one active session. An exact successful replay
  remains idempotent; a conflicting token/source or intervening valid selection is
  rejected without effects.

The recovery commands are for users eligible for `:choose`; original first-use and
normal reviewed-selection APIs retain their guards. Chooser reads/filtering/navigation
remain write-free. Foreign, archived, malformed, corrupt or stale choices must preserve
pointers, plans, sessions and audit data; failed transactions roll back any newly created
recommendation. Video selection uses real video-start semantics, not a fabricated plan
anchor. No schema/dependency, cache/storage or paid-provider feature is added.

`Home.facts/2` must first recognize a valid existing selection during a workout-needed
slot, including an authorized first-use selection of a shared built-in. Absence of owned
plans/history is not proof that no selection exists. Only the existing history/owned-plan
cases may ensure/create a fallback; first use without an existing selection remains
write-free and maps to `:first_workout`. Started/done/week guards remain unchanged.

### Returning-user evidence alignment (owner-approved follow-up)

The owner approved aligning Home observation and dedicated recovery eligibility with
existing `Workouts.home_entry_state/2` first-use authorization. Persisted actor-owned
plans include draft and archived plans; persisted history evidence includes sessions
and prior recommendations. These users must not be offered a first-use prompt whose
existing bootstrap guards correctly reject them. Facts must reflect actual evidence,
not a fabricated history/selection or a relaxed bootstrap rule.

Recognize valid pins first; for returning-user evidence, retain existing fallback and
corrupt owned-draft pin repair behavior. If no selection can genuinely be ensured,
derive `:choose` and permit only the approved explicit transactional recovery commands.
Recheck the same returning-user classification within recovery's current-slot transaction;
retain all valid-winner/active-session/ownership/type/hash/revision/CAS/replay guards.
Truly fresh users remain read-only `:first_workout`; foreign evidence never qualifies them.
The six-state pure derivation and first-use/normal selection command contracts stay intact.

### Scope **(default)**

Adopt the Phoenix 1.8 scope convention:

- `BurpeeTrainer.Accounts.Scope` struct `%Scope{user: %User{}}` with `for_user/1`.
- `BurpeeTrainerWeb.Auth` assigns `current_scope` in the plug pipeline and the LiveView
  `on_mount` hook; `current_user` remains available as `current_scope.user` only.
- Public functions of `Workouts`, `Coach`, `Goals`, `Videos` and `Home` that act for a user
  take `%Scope{}` as the first argument and filter every query by `scope.user.id`.
- Ownership checks happen once, in the query. Repeated re-verification of the same row in
  callers is removed (optimistic concurrency checks such as `home_revision` and
  `content_hash` comparisons stay, because they detect stale state, not ownership).

### Error handling

- `Home.facts/2` returning `{:error, :invalid_timezone}` renders the existing timezone error.
- No `rescue`/`catch` in `Home`, `HomeLive`, or its extracted screen modules.

## Testing

- Property test for `Home.state/1`: for generated facts, exactly one state is returned, a
  started session always yields `{:resume, _}`, and every state maps to exactly one primary
  action.
- LiveView full flows from the cull's core suite keep passing after the split (route and
  module names updated, behaviour unchanged).
- One test per routed screen that a different user's IDs (session, plan, guidance) are
  rejected through the scoped queries.
- Actual patch-navigation roundtrips retain the LiveView process, unsent Coach text and
  Home working adjustment/expansion, with no unintended guidance write or selection
  mutation. Screen entry/exit still preserves keyboard, heading focus and isolation.

## Out of scope

Replacing `CoachReconciler`, the coach agent, insights. The reconciler keeps running until
sub-project 4.
