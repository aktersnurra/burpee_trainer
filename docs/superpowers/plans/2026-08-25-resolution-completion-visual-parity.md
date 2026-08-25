# Resolution and Completion Visual Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unfinished-session resolution use the same reflection and save experience as post-workout completion.

**Architecture:** Keep `SessionResolutionLive` and `SessionRecoveryHook` responsible for recovery and server reporting. Replace only its visual shell and form controls with the completion review's existing classes and interaction patterns. Mood becomes a hook-managed segmented control backed by the existing form field, just as tags remain hook-managed pills.

**Tech Stack:** Phoenix LiveView, HEEx, Tailwind CSS, browser-native JavaScript, ExUnit, Node test runner.

## Global Constraints

- Preserve UUID-scoped recovery, lifecycle authority, reconciliation, idempotent reporting, and abort behavior.
- Keep existing stable resolution IDs; add stable mood-button IDs.
- Use the shared `session-choice-toggle` selected-state rule; do not create a second visual state system.
- Resolution-specific copy must state that values may be recorded or estimated.
- Do not change the post-workout completion review or introduce raw camera data into the UI work.

---

### Task 1: Add recovery-hook mood toggles

**Files:**
- Modify: `assets/js/hooks/session_recovery_hook.js:1-213`
- Test: `assets/js/hooks/session_recovery_hook_test.mjs:57-280`

**Interfaces:**
- Consumes: hidden `#session-resolution-mood` input and buttons bearing `data-resolution-mood`.
- Produces: `setMood(value)` that writes the hidden form value, dispatches input/change, and sets exactly one mood button's `aria-pressed` value to `true`.

- [ ] **Step 1: Write failing hook tests**

Add three fake mood buttons to `mountedHook`, expose them from `root.querySelectorAll("[data-resolution-mood]")`, then assert click and recovery behavior:

```js
test("mood buttons serialize one selection and expose pressed state", () => {
  const { hook, moods, inputs } = mountedHook();
  hook.setMood(0);

  assert.equal(inputs[2].value, "0");
  assert.equal(moods.ok.getAttribute("aria-pressed"), "true");
  assert.equal(moods.tired.getAttribute("aria-pressed"), "false");
});

test("recovery prefill updates the matching mood button", async () => {
  const { hook, moods } = mountedHook({ localDraft: draft() });
  await hook.recovery;
  assert.equal(moods[1].getAttribute("aria-pressed"), "true");
});
```

- [ ] **Step 2: Run the focused test to verify RED**

Run: `cd assets && node --test js/hooks/session_recovery_hook_test.mjs`

Expected: FAIL because `setMood` and mood button harness support do not exist.

- [ ] **Step 3: Implement the smallest mood-control extension**

Add `moodInput`, `moodButtons`, and `setMood` beside the existing tag helpers. Extend the click handler without changing tag behavior:

```js
const mood = pill?.dataset?.resolutionMood;
if (mood !== undefined) {
  event.preventDefault();
  this.setMood(mood);
}
```

`setMood` must accept only the existing numeric mood values (`-1`, `0`, `1`), clear invalid values to an empty hidden input, dispatch `input` and `change`, and set pressed state by string equality. In `prefillReport`, route draft mood through `setMood` rather than assigning the hidden input directly.

- [ ] **Step 4: Run the focused test to verify GREEN**

Run: `cd assets && node --test js/hooks/session_recovery_hook_test.mjs`

Expected: PASS.

- [ ] **Step 5: Commit the hook slice**

```bash
jj describe -m "feat(resolve): add completion-style mood toggles"
jj commit -m "feat(resolve): add completion-style mood toggles"
```

### Task 2: Apply the completion-review visual contract to resolution

**Files:**
- Modify: `lib/burpee_trainer_web/live/session_resolution_live.ex:113-299`
- Test: `test/burpee_trainer_web/live/session_resolution_live_test.exs:14-66`

**Interfaces:**
- Consumes: existing `@form`, `@count_estimated?`, `@duration_estimated?`, `@mood_options`, and `@tag_options` assigns.
- Produces: resolution form markup with `#session-resolution-mood` hidden input and three `data-resolution-mood` buttons, while retaining `#session-resolution-form`, report input names, and abort action.

- [ ] **Step 1: Write the failing LiveView markup test**

Extend the owner-resolution test with exact structure checks:

```elixir
assert has_element?(view, "#session-resolution[data-completion-style='true']")
assert has_element?(view, "#session-resolution-mood[type='hidden']")
assert has_element?(view, "#session-resolution-mood-tired[data-resolution-mood='-1'][aria-pressed='false']")
assert has_element?(view, "#session-resolution-mood-ok[data-resolution-mood='0'][aria-pressed='false']")
assert has_element?(view, "#session-resolution-mood-hyped[data-resolution-mood='1'][aria-pressed='false']")
refute has_element?(view, "select#session-resolution-mood")
```

- [ ] **Step 2: Run the focused test to verify RED**

Run: `mix test test/burpee_trainer_web/live/session_resolution_live_test.exs`

Expected: FAIL because the current screen has a `<select>` mood input and no completion-style marker or mood toggle IDs.

- [ ] **Step 3: Replace only the resolution presentation markup**

Use the completion review's narrow scroll panel and control classes:

```heex
<div id="session-resolution" data-completion-style="true" class="session-surface mx-auto max-w-[430px] min-h-dvh overflow-y-auto px-5 pb-10 pt-[max(4rem,env(safe-area-inset-top))] text-[var(--session-ink)]">
```

Replace the Mood select with a hidden input plus the completion-review segmented control:

```heex
<.input field={@form[:mood]} id="session-resolution-mood" type="hidden" />
<div id="session-resolution-mood-options" class="flex border-y border-[var(--session-border)]">
  <button :for={{label, value} <- @mood_options} id={"session-resolution-mood-#{String.downcase(label)}"} type="button" data-resolution-mood={value} aria-pressed="false" class="session-choice-toggle min-h-14 flex-1 text-sm font-medium text-[var(--session-muted)] transition-colors duration-150 active:scale-[0.98]">{label}</button>
</div>
```

Use the completion input, tag, save, and discard classes from `SessionComponents.completion_review/1`. Keep the unfinished-session context and recorded/estimated source labels compact and secondary; retain all existing input IDs, report form, and abort event.

- [ ] **Step 4: Run focused tests to verify GREEN**

Run:

```bash
mix test test/burpee_trainer_web/live/session_resolution_live_test.exs
cd assets && node --test js/hooks/session_recovery_hook_test.mjs
```

Expected: both commands PASS.

- [ ] **Step 5: Commit the visual slice**

```bash
jj describe -m "feat(resolve): match completion review"
jj commit -m "feat(resolve): match completion review"
```

### Task 3: Verify recovery behavior and visual parity

**Files:**
- Evidence: `.e2e-artifacts/reports/resolution-completion-parity-2026-08-25.md`

- [ ] **Step 1: Run repository verification**

Run:

```bash
cd assets && npm test
mix precommit
```

Expected: both exit successfully.

- [ ] **Step 2: Run a fresh browser recovery check**

Create a new E2E identity through `scripts/e2e/setup.exs`, retain an unresolved or report-pending lifecycle row, and open `/sessions/:id/resolve` in an isolated Firefox profile. Verify the narrow completion-style surface, mood pressed-state change, tag selection, compact scrolling, and that Save produces exactly one report row. Capture redacted evidence under `.e2e-artifacts/`.

- [ ] **Step 3: Commit evidence only if it is tracked by project convention**

Do not commit server logs, browser profiles, credentials, raw pose traces, or screenshots with user data.
