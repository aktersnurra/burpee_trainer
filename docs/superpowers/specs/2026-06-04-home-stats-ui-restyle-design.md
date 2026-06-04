# Home and Stats UI Restyle Design

## Goal

Restyle the Home and Stats pages so they visually belong with the new Session and Workouts UI. Use `mock/_ overview.html` and `mock/_stats.html` as loose visual direction, not pixel-perfect targets.

The work is visual only. Preserve existing page intent, information hierarchy, data flow, routes, events, modals, and behavior.

## Visual Direction

- Use the warm-paper / black-ink Session visual system.
- Use Geist as the only font family.
- Use `.session-surface` and shared `--session-*` color tokens for page background, text, borders, muted labels, and tracks.
- Avoid generic SaaS/dark-dashboard chrome.
- Prefer flat, sharp training-instrument surfaces: restrained borders, clear typographic hierarchy, minimal decoration.
- Keep blue only where it already communicates action/data emphasis; avoid turning the pages into blue-accent dashboards.
- Support light/dark through existing session token overrides, including system-dark fallback.

## Scope

### In scope

- `lib/burpee_trainer_web/live/overview_live.ex`
- `lib/burpee_trainer_web/live/stats_live.ex`
- `lib/burpee_trainer_web/live/stats_live/render.html.heex`
- stats partial templates if needed for chart/card surfaces
- `lib/burpee_trainer_web/components/layouts.ex` only if Home/Stats need the same session page shell/nav treatment as Workouts
- `assets/css/app.css` only for shared visual utilities/tokens required by Home/Stats

### Out of scope

- No data-model changes.
- No chart data changes.
- No new navigation structure.
- No new features.
- No removal of current Home or Stats sections.
- No deployment/phone testing in this pass.

## Home Design

Home keeps its current order and purpose:

1. at-risk banner when applicable
2. weekly status strip
3. workout card / pick-up-where-left-off action
4. coach suggestions
5. log past session link/modal

Restyle these elements to match the mock direction:

- Page uses warm-paper background and black ink.
- Weekly status becomes a quiet top instrument: large minutes, compact goal text, muted session/push-up metadata, and thin progress/rhythm bars using session tokens.
- Workout card becomes the primary action row/card, closer to the mock’s “pick up where you left off” feel: strong workout name/count, concise metadata, clear play action.
- Empty workout state stays functional but uses the same quiet panel style.
- Coach suggestion remains present but becomes a low-noise recommendation row rather than a colorful alert card.
- Log past session remains a secondary text action.

## Stats Design

Stats keeps its existing sections and behavior:

1. at-risk banner
2. streak/weekly progress
3. goals
4. trends/charts
5. recent sessions
6. log and goal modals

Restyle these sections using the stats mock as direction:

- Top stats area should feel like a performance ledger, not a dashboard.
- Streak card keeps current data but becomes flatter and more typographic.
- Goals remain visible and actionable, but use restrained warm-paper panels and compact progress treatments.
- Trends/charts remain, with surfaces, labels, and filters aligned to session tokens.
- Recent sessions should feel like a precise training log: row-based, clear date/type/count/duration, muted secondary metadata.
- Existing load-more behavior remains unchanged.

## Layout and Navigation

- Home and Stats should use the same full-page session surface treatment already used by Workouts where appropriate.
- Top and bottom nav should visually remain consistent across Home, Workouts, and Stats once these pages adopt the session surface.
- Mobile spacing must account for the fixed bottom nav.
- Avoid fixed-width mobile tab assumptions that can overflow narrow phones.

## Implementation Constraints

- Preserve existing LiveView events and IDs used by tests where possible.
- Keep key test selectors intact, especially modal IDs and existing interaction targets.
- Use Tailwind classes and existing CSS tokens; do not add inline scripts.
- Do not introduce new dependencies.
- Do not create speculative reusable abstractions unless repeated code becomes clearly harmful.
- Run `mix precommit` before pushing.
- Use `jj` for version control.

## Testing / Verification

Minimum verification:

- Existing LiveView tests still pass.
- `mix precommit` passes.
- Manual visual check of Home and Stats in light mode.
- Manual visual check of Home and Stats in dark/system-dark mode.
- Mobile check for bottom nav spacing and recent-session row readability.

## Approval

Approved direction: loose mock-inspired restyle while preserving current content and behavior.
