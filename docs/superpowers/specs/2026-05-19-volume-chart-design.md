# Volume Chart — Design Spec

Date: 2026-05-19

## Overview

Replace the volume chart placeholder on the Stats screen with a stacked SVG bar chart showing weekly burpee reps by type (6-count and navy seal), with per-type dashed trend lines.

## Data Layer

New function `Workouts.weekly_volume/1`:

```elixir
@spec weekly_volume(User.t()) :: [%{week_start: Date.t(), six_count_reps: integer, navy_seal_reps: integer}]
```

- Queries `workout_sessions` grouped by ISO week (Monday start), summing `burpee_count_actual` per `burpee_type`
- Returns last 12 weeks, most recent first, with zeros for weeks with no sessions of a given type
- Excludes sessions tagged `"warmup"` (same filter as `weekly_minutes/1`)
- Nil `burpee_count_actual` treated as 0

## StatsLive changes

- Call `Workouts.weekly_volume(user)` in `mount/3`, store as `@volume_data`
- Pass `volume_data={@volume_data}` to `volume_chart/1` (replacing current placeholder)
- Refresh `@volume_data` in `handle_info(:session_saved, ...)` alongside existing refreshes

## Chart component

`volume_chart/1` private function in `StatsLive`.

**SVG dimensions:** `viewBox="0 0 300 80"` — matches `weekly_minutes_chart/1`.

**Bar layout:** 12 bars, same `bar_w = 18`, `gap = 7` as the minutes chart, oldest week left.

**Stacking:** Navy seal reps on bottom (orange `#F97316`), 6-count reps on top (blue `#4A9EFF`). Max scale = highest weekly total across all 12 weeks (minimum 1 to avoid division by zero). Bar height scaled to 70px max.

**Trend lines:** Linear regression (least squares) over the 12 data points for each type separately. Each trend line is a `<line>` element, dashed (`stroke-dasharray="3,3"`), drawn only if that type has at least one non-zero week. Colors: blue (`#4A9EFF`) for 6-count, orange (`#F97316`) for navy seal, opacity 0.6.

**Legend:** Two small dots + labels below the SVG:
- `●` blue `#4A9EFF` — "6-Count"
- `●` orange `#F97316` — "Navy SEAL"

Rendered as a flex row, `text-xs text-base-content/40`, same card padding.

**Empty state:** If all 12 weeks have zero reps for both types, show "No sessions yet." text instead of the SVG.

## Linear regression helper

Private function `linear_trend/1` — takes a list of `{x, y}` pairs, returns `{slope, intercept}` for `y = slope * x + intercept`. Used to compute trend line start/end points for the SVG.

```elixir
defp linear_trend(points) do
  n = length(points)
  sum_x = Enum.sum_by(points, fn {x, _} -> x end)
  sum_y = Enum.sum_by(points, fn {_, y} -> y end)
  sum_xy = Enum.sum_by(points, fn {x, y} -> x * y end)
  sum_xx = Enum.sum_by(points, fn {x, _} -> x * x end)
  denom = n * sum_xx - sum_x * sum_x
  if denom == 0 do
    {0.0, sum_y / n}
  else
    slope = (n * sum_xy - sum_x * sum_y) / denom
    intercept = (sum_y - slope * sum_x) / n
    {slope, intercept}
  end
end
```

## Testing

- Unit tests for `Workouts.weekly_volume/1`: correct aggregation, zero-filling missing weeks, warmup exclusion, 12-week window
- Unit tests for `linear_trend/1`: flat data, rising data, single point
- No LiveView integration test for the chart rendering (SVG output is hard to assert meaningfully)

## Out of scope

- Interactive tooltips
- Clicking bars to filter sessions
- More than 12 weeks of history
