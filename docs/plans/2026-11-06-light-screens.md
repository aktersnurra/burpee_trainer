# Plan: light screens

Spec: `docs/specs/2026-11-06-light-screens-design.md`. Reference: `.docs/mockups/`.

One change per module, in this order; each passes `ERL_FLAGS='+S 4:4' MIX_ENV=test mix
precommit` before the next starts. Each is screenshotted at 390, 820 and 1440 against the mockup.

1. **Palette and shared pieces.** Tokens in `assets/css/adaptive_home.css` (`--six`, `--seal`,
   `--seal-line`, `--cobalt`, `--good`, `--clay`, `--amber`; drop `--changed` and the old series
   colours) and `docs/ui.md` §2. The writing box (`.composer`, Finish's and New's notes) as one
   two-line box. The diff marks (strike grey, cobalt highlight). Suggestions as a sideways
   scroller with a fade.
2. **Home and Edit.** Home's workout block lines; Edit's X corner, request bubble, diff and
   `was …` sentence.
3. **New.** Settings rows (Sets, Set size for Unbroken, Pace) in place of the folded line; the
   structure sentence; type and Sets tints; the request box; X / ✓ foot; no top chevron.
4. **Finish.** Layout, mood and tag colours, the note box, trash that asks in place.
5. **Progress.** Level and streak, best / needs / goal columns, the look-back link, the day grid,
   the dual-axis chart under the window tabs.
6. **Coach page.** A `HomeLive` live action (`/coach`) with the week, the chat and the memory
   sheet; entry from Home done's bookmark and Progress's look-back; back to where you came from.
   Home done's chat ordering.
7. **Runner camera figure.** The silhouette and pose overlay on the camera-setup screen.

Delete this plan when the last module merges.
