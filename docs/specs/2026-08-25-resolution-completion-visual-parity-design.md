# Resolution and Completion Visual Parity

**Goal:** Make the unfinished-workout resolution screen look and behave like the post-workout completion review, while retaining its server-authoritative recovery lifecycle.

## Decision

The post-workout completion review is the visual contract. Resolution is the same reflection-and-save task reached through recovery, not a separate administrative form.

The implementation will keep `SessionResolutionLive` as a LiveView and preserve reconciliation, report, and abort behavior. It will adopt the completion review's mobile panel, hierarchy, control shapes, spacing, and selected-state treatment.

## Layout

- Use the same narrow mobile reading width, generous vertical rhythm, quiet secondary text, and full-height scroll behavior as `#session-completion-review`.
- Lead with `Finish workout record` and compact unfinished-session context. Started/source metadata remains available, but is tertiary information rather than the page's dominant structure.
- Keep planned workout facts as a compact supporting summary rather than a separate, bordered administrative section.
- Present recorded values, reflection, and saving as one continuous completion flow.

## Controls

- Replace the Mood `<select>` with the same three-option segmented mood toggle used after a workout. The selected option must expose `aria-pressed="true"` and synchronize with the existing LiveView form value.
- Keep tags as toggle pills, using the same geometry, colors, and selected-state styling as completion review.
- Give actual reps, duration, and notes the same custom input geometry and type scale as completion review.
- Use the same large, rounded, dark primary save button and quiet text-style discard action.

## Constraints

- Do not alter workout lifecycle authority, UUID reconciliation, report idempotency, or provenance rules.
- Preserve stable resolution IDs needed by LiveView tests and recovery-hook behavior. Add stable IDs to mood controls if needed.
- Resolution-specific copy must remain honest: values may be recorded or estimated, and discard remains destructive.
- Do not add a client-rendered duplicate of the resolution form or change the post-workout completion review's behavior.

## Verification

1. Update LiveView tests to prove the resolution surface has mood toggle buttons, no mood select, selected `aria-pressed` state, preserved form submission, and existing record/discard actions.
2. Run the focused resolution tests, relevant asset tests, and `mix precommit`.
3. Use a fresh local browser recovery session to verify the visual hierarchy, compact scrolling, mood selection, save, and discard state.
