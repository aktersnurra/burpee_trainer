# Adaptive Home: approved pre-workout design

Status: pre-workout interaction and visual direction approved on 2026-09-09. Follow-on scope revised on 2026-09-12: retain the original adaptive state machine and inline interactions, not separate Library/Create page redesigns. See [the inline state-machine plan revision](../plans/2026-09-12-adaptive-home-inline-revision.md) for current scope, gaps and sequencing. This is a product/design specification, not a claim that the production app implements it.

## Scope and authority

Implement the approved **pre-workout Home surface** first. The existing workout compiler, immutable published library, session snapshots, and authentication remain authoritative. This document supersedes conflicting older Home presentation and draft-interaction descriptions in `SPEC.md`, not its safety, ownership, compilation, or immutability requirements.

The deliverable is a working real-data counterpart of the reviewed prototype, including inline revision, grouped inspection, filtered alternatives, and the Start/Update action. History redesign and interrupted-session recovery are separate follow-on slices. Their previously agreed direction is recorded at the end so it is not lost.

Do not transplant the prototype's simulated generation, hardcoded workout levels, sample account progress, or in-memory persistence into production.

## Product principle

This is a personal, get-things-done tool, not a social app or a chat app. Opening Home should present the next useful thing. The domain chooses the kind of surface; the coach chooses an appropriate structured workout when training is needed.

- Phone is the primary device, approximately 90% of usage; laptop/desktop account for the rest.
- The default Home fits on one phone screen at ordinary text sizes.
- Expanded content and accessibility text may scroll. Never shrink text to force a fit.
- Prefer direct expansion to navigation. No navbar, floating action menu, nested sheets, or Back-button maze on this surface.
- Extra information is revealed on deliberate interaction, not shown by default.

## Approved visual direction

Reference: the user's `screenshot_046.png`, refined through the latest prototype.

- Warm off-white surface, dark text, muted secondary information, fine neutral rules.
- A small weekly progress display at the top, with the actual week/progress from domain data. The progress bar is always available across Home states as the entry point to inline History: tap or keyboard-activate it to expand History without leaving Home or changing the workout. Preserve accessible progress semantics and return focus to the opener when History closes.
- A prominent, centered workout name, followed by a compact duration/reps line.
- Generous surrounding whitespace. No card border, recommendation paragraph, badge, or `Recommended`/`Selected`/`Draft` eyebrow above the title.
- One font family; a deliberately prominent title and restrained supporting text. Avoid a proliferation of font sizes and decorative typography.
- No full-width/fat Start button. The expanded surface has a small text action with a directional arrow.
- Opening the summary smoothly moves it upward and reveals its contents. Expansion should explain the spatial change, not feel like a page transition.
- Use approximately 240–300 ms restrained transitions; honor reduced-motion preferences.

Approved reference captures:

- [Collapsed Home](assets/adaptive-home-summary.png)
- [Expanded inspection and borderless adjustment](assets/adaptive-home-expanded.png)
- [Expanded filters](assets/adaptive-home-filters.png)

These captures contain sample data. Their copy/numbers are not product constants.

## Summary selection

The automatic recommendation is either a valid new draft or an eligible published structured workout. **It is never a video.** Videos are available only through explicit selection in the alternatives list.

Reopening Home alone must not reshuffle the recommendation. A new day, completed training, or explicit feedback may justify reconsideration. A coach response must not silently replace a workout the user is inspecting, revising, or starting.

Selecting a stored workout replaces the current summary and inspection contents, clears the prior instruction/error, and closes the alternatives list. Keep the inspection available for immediate adjustment. Do not navigate through a library detail screen or require a separate acceptance step.

The selected workout is a pointer to a library item or current draft, not a mutable execution session. An execution snapshot is created only when starting.

## Expand and inspect

Clicking the workout summary expands/collapses the detail area in place. The expanded area contains:

1. A compact, spreadsheet-style representation of the actual workout.
2. The borderless `Adjust…` input.
3. The single Start/Update action.
4. The expandable Other workouts section, with its filter control on the right.

The latest approved design places the action inside the expansion. It replaces earlier mockups with an always-visible large Start button and a paragraph as the collapsed recommendation.

### Grouped sets and blocks

Group **consecutive identical** sets or blocks into one summary row. Preserve execution order; do not group matching items across intervening different work.

- A repeated set group shows its repeat count, reps per set, prescribed cadence, and inter-set rest.
- A repeated block group shows its repeat count and contained set structure.
- Expanding a group reveals the actual ordered constituent sets/blocks in place.
- Equality must compare exact workout data, including timing and rests, not rounded display strings.
- Expanding/collapsing is presentation only. Never rewrite the canonical definition or program for display grouping.
- Do not fabricate or suppress recovery to make rows look uniform. Preserve differences at block boundaries and represent any real trailing recovery explicitly.
- Timing labels must distinguish prescribed rep cadence from measured active rep pace.

The production view derives these facts from the validated definition/program, not from the prototype's arithmetic fixtures. Use semantic table structure, accessible expansion controls, and stable DOM IDs.

## Borderless adjustment and one action

`Adjust…` looks like quiet text, not a textarea box. Clicking it places the caret directly in an actual editable control. It grows as needed. Keep an accessible label and keyboard support without a decorative input container.

The action is determined by the trimmed submitted text:

| Input | Label | Effect |
| --- | --- | --- |
| Empty/whitespace | Start | Start the displayed workout; finalize it first if it is a draft. |
| Nonblank | Update | Request a revised draft; do not start a session. |

The server must derive this operation from the submitted input, not trust a stale client label.

There is no separate Save, Publish, Use this workout, or Copy & adjust step on Home.

### Revising a published workout

The input is available for published workouts as well as drafts. Typing instructions and choosing Update implicitly uses the displayed published workout as the source of a new draft.

- The source remains immutable and retains its identity/history.
- A failed revision must not alter the source or leave a spurious visible draft.
- Success selects the new validated draft in the same Home workspace.
- Revising a draft can replace its current valid content with stale-revision protection; the design log remains append-only.
- User instructions can change workout type, reps, duration, or structure. For example, a Navy SEAL recommendation can become `140 six-counts in 20 min`.
- Deterministic validity/physical constraints still apply. A user-authored change is not rejected merely because it differs from the coach's original type or duration preference.

### While updating

On submission, hide the current workout/detail/input area. Display **only the loading animation in its place**. Do not retain a dimmed, blurred, or readable previous draft behind it. Do not navigate away.

Preserve the current valid workout and submitted text in state while the task runs. Prevent overlapping updates, starting the stale workout, or applying a response to a different selected item. LiveView must remain responsive; the provider call runs asynchronously under supervision.

On success:

- Parse, validate, compile, and verify the provider result before showing it.
- Replace the summary and inspection with the new draft, still expanded.
- Clear the instruction. The action becomes Start.

On failure:

- Restore the exact previous valid workout, whether it was a draft or published source.
- Preserve the submitted instruction. The action remains Update and can retry it.
- Show a quiet local message near the instruction, for example: `Couldn’t update. Your previous workout is unchanged.`
- Prefer an actionable safe reason when available; never dump provider/validation internals into the UI.
- No toast, red banner, modal, warning icon, or accumulating notifications.

Preserve existing input and HTTP limits: at most 500 graphemes and 4,000 bytes per instruction; at most one provider request per user update; no automatic multi-call repair. A failed request must not erase a usable workout.

## Start and direct video selection

### Structured workout

With empty input, Start uses the exact displayed revision.

- For a draft, finalization and creation of the immutable started-session snapshot form one atomic operation.
- For a published workout, start it unchanged.
- Authenticate ownership, revalidate availability/content and the expected revision/selection, and prevent stale or duplicate starts.
- Load the existing session flow directly after successful creation. No intermediate acceptance or preview screen.
- A failure must not leave a published draft without its intended session or navigate using an unrelated recommendation.

Published and archived definitions remain immutable. Subsequent adjustment always creates a draft copy; execution/history continue to use their snapshots.

### Video

Choosing a video from the Videos tab immediately starts/loads the existing video session flow after the necessary server-side ownership, availability, and session-creation checks. It does **not** replace the Home summary and wait for another Start click. It does not publish a workout draft.

## Other workouts and filters

The expandable **Other workouts** heading has a quiet **Filter** control aligned on its right. Opening Filter reveals its controls in place and opens the alternatives area if needed; it does not open a separate sheet or route.

The alternatives area contains two tabs:

- **Workouts:** eligible stored structured workouts, in coach-recommended order.
- **Videos:** available videos, ordered by level from the current level toward higher levels.

Filters:

- Workout type: six-count and Navy SEAL, independently selectable; both selected initially.
- Level: the user's actual current level and the next level selected initially. At the highest level, select only the current level.
- The same filter selection applies across both tabs.
- Changing tabs or filters does not select a workout or change the current summary.
- Preserve relative ranking among matching workouts; use stable tie-breaking so the list does not jump around.
- Reset restores both types and current/next levels.
- Empty results show a small local message inviting the user to change filters.

Candidate level metadata and coach ranking must be provided by the domain. The prototype's `1C` user level, per-item classifications, and list order are fixtures, not an approved production classification algorithm. The implementation plan must explicitly map this data contract to real catalog facts; it must not infer levels from arbitrary sample IDs or silently use fabricated rankings.

Follow-on revision: unfinished authoring drafts must remain recoverable inline without silently displacing the current selection. All creation belongs to the Home draft flow, not a separate Create page. When no usable workout exists, show a text box for an explicit LLM request to bootstrap the first validated draft; retain the prompt on failure. Existing usable workouts and deterministic fallback must not depend on provider success. Other workouts is the browsing/selection surface. Preserve unique Library/Create capabilities and saved drafts until their inline replacements or explicit retirement have been reviewed and verified.

## Coach context and memory boundary

A non-chat UI does not mean a stateless authoring request.

- Supply global coach settings/memory before asking the provider to design a workout.
- Retain an append-only design-session log of instructions, proposals, and revision outcomes.
- Subsequent requests receive the accumulated design context and the current workout. Hiding message history in the UI must not discard that history from the request.
- Keep workout-specific design history separate from global preferences. `Less rest in this workout` is not automatically `Always use less rest`.
- Do not silently truncate design history. If provider/request bounds prevent using the required context, return a bounded failure and preserve the valid workout rather than pretending it was sent in full.
- No extra snapshot/refresh UI for global settings changing midway through a design session.

Successful draft finalization publishes a small post-commit event, containing identities rather than large prompts. A supervised PubSub subscriber can use the persisted workout and design log to update coach memory asynchronously.

This memory update is **best effort**. Missing an event is acceptable. Do not add Kafka, an outbox, delivery tracking, replay, durable retry jobs, or recovery machinery for this callback. Do not block Start on a memory update. Emit no finalization event for a rolled-back transaction or merely selecting a video.

The existing deterministic workout fallback must remain usable when the provider is unavailable.

## Integration findings from the current checkout

This design was recorded while existing, uncommitted creator/library work was present. Those source changes were not made by this prototype/design pass and must be preserved when planning implementation.

Relevant integration points inspected:

- `lib/burpee_trainer_web/live/overview_live.ex`: current Home priority/rendering, separate candidate controls, Start/Resume routing.
- `lib/burpee_trainer_web/components/home_coach_components.ex`: current recommendation heading presentation.
- `lib/burpee_trainer_web/live/workout_creation_live.ex`: existing asynchronous authoring and reviewed-draft Start flow.
- `lib/burpee_trainer_web/components/workout_draft_structure.ex`: exact program/recovery rendering that must not be replaced with fabricated uniform sets.
- `lib/burpee_trainer/workouts.ex`: draft lifecycle, candidate attachment, expected-revision checks, and `publish_and_start_draft/3` in the current uncommitted work.
- `lib/burpee_trainer/coach.ex`: existing create/refine provider boundary.
- `lib/burpee_trainer/workouts/workout_plan.ex` and `workout_video.ex`: neither schema currently exposes a level field. Candidate-level filtering needs an explicit domain mapping, not a UI-only assumption.

In particular, publishing an unattached user draft is not the same as accepting a coach-attached candidate. The latter must update the recommendation pointer and create the intended session atomically, without reinstating the discarded two-step acceptance UX.

## Acceptance scenarios

1. Default Home shows actual weekly progress and a structured workout name/duration/reps; no inferred-state label, navbar, chat feed, or full-width Start button.
2. Clicking the summary expands the exact grouped structure and borderless input; clicking it again collapses without navigation.
3. Identical adjacent sets/blocks group; differing timings/rests and non-adjacent repetitions do not get merged or reordered.
4. The input is focusable and editable on a phone and by keyboard. Empty/whitespace input says Start; nonblank input says Update.
5. A type-changing instruction produces a verified draft in place. During generation only the animation occupies the workout area.
6. Failed generation restores the exact last valid item and input; retry works without accumulated notifications.
7. Selecting a stored plan loads its summary and permits immediate inline adjustment. Updating it cannot mutate its published source.
8. Start atomically finalizes the exact draft and starts its snapshot, or starts the selected published item unchanged. Stale revisions/selections fail safely.
9. Videos are never automatic recommendations. Explicit video selection loads the video flow without a second Start.
10. Type/level filters default from real user state, work across both tabs, preserve ordering, and never change selection on their own.
11. Full design context reaches the authoring boundary; local edits are not indiscriminately promoted to global preferences.
12. Finalization broadcasts after commit only; subscriber/provider failure does not break a successful Start.
13. Ordinary collapsed Home fits a small phone screen. Expanded content, filters, and large text can scroll without horizontal overflow.
14. Transitions remain smooth and reduced-motion is respected. No development controls, fixture data, or simulated provider logic ships.

Verify real implementation with focused ExUnit/LiveView tests, JavaScript tests where applicable, the authenticated isolated Firefox procedure in `docs/guides/workout-session-e2e.md`, and `mix precommit`. Prototype tests do not substitute for real application checks.

## Follow-on slices already discussed, not part of this prototype's approval

### Adaptive post-workout Home and history

Today’s completed result remains primary even when it completes the weekly target. On subsequent days, show weekly completion until Monday. Completed states have no primary action or push to do another workout.

Clicking the result expands History inline on Home, with `This week | 4 weeks | All time`, separate six-count/Navy Seal line plots, an optional line/bar toggle, and an expandable spreadsheet-style session list. Default comparison metric is reps per 20 minutes: `actual reps × 1,200 / actual duration seconds`. This is training density, not a predicted 20-minute personal best. Tapping a point reveals actual reps and duration.

Pace means active movement time per rep; cadence includes rest between reps within a set, excluding inter-set rest. Do not present prescribed timing as measured timing. Navy Seal push-up count is three per rep, but multiplying by three does not make overall effort equivalent to six-counts.

### Interrupted-session recovery

An unfinished session must be resolved before another starts. Same-device recovery is sufficient. Resume is available for approximately 30 minutes since the last workout activity, not 30 minutes since starting. Recover paused. After expiration or a missing checkpoint, offer Log or Discard, without automatic logging.

Current local completion drafts are not in-progress execution checkpoints; reliable resume across reloads needs separate implementation. Do not imply the prototype added that capability.

### Weekly recommendation policy

The app offers a next workout toward a flexible weekly target, rather than prescribing a mandatory training day. When catch-up is appropriate, prioritize completing the remaining week, with an explicit regular 20-minute escape hatch. Monday starts fresh; no debt accumulation.

### Coach feedback surface

Keep global coach feedback small and direct, not a conversation feed. Distinguish temporary context from lasting preferences. Make memory inspectable/removable and support clearing it with confirmation. This separate surface has not yet received the same visual approval as pre-workout Home.
