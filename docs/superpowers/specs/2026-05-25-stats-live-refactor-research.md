# StatsLive Refactor Research

## Current Shape

`lib/burpee_trainer_web/live/stats_live.ex` is about 864 lines. It combines:

- LiveView lifecycle and events: `mount/3`, modal events, load-more sessions, goal modal events, `handle_info/2` refreshes.
- Data loading: workouts, goals, weekly minutes, sessions, levels, goal progress.
- Presentation components: streak card, goals section, session rows, trends section.
- Chart rendering: weekly minutes chart and progress chart SVG/markup.
- Computation: goal progress and chart-ready values mixed with rendering.

## Recommended Boundary

Create a pure data-shaping module before changing rendering:

`BurpeeTrainer.Stats.Series`

Responsibilities:

- Normalize weekly minutes into chart points.
- Normalize progress sessions into progress chart series.
- Compute chart bounds/ticks/labels where possible.
- Keep SVG/HEEx rendering in `StatsLive` for now.

Do not move modal events or PubSub refresh handling in the first slice.

## Why This Boundary

The charts are the densest non-template logic in `StatsLive`. Extracting series/bounds calculations creates pure unit-testable behavior without a large HEEx diff.

## Proposed Tests

- weekly minutes empty input returns empty chart model.
- weekly minutes with values returns sorted points and max bounds.
- progress sessions produce count/pace points for a burpee type.
- chart bounds are stable for single-point and multi-point inputs.

## Risks

- Existing chart code may rely on assigns and inline calculations. Keep the first extraction narrow and preserve current rendered output.
- Do not introduce Chart.js changes in this refactor; that belongs to asset/setup or chart hook work.

## Recommendation

Plan before implementation. The next implementation slice should be `Stats.Series` plus tests, then a small `StatsLive` adapter change.
