defmodule BurpeeTrainer.Stats.SeriesTest do
  use ExUnit.Case, async: true

  alias BurpeeTrainer.Stats.Series

  test "weekly_minutes returns empty model for no rows" do
    assert %{points: [], max_minutes: 0} = Series.weekly_minutes([])
  end

  test "weekly_minutes sorts rows and computes max" do
    rows = [
      %{week_start: ~D[2026-05-18], minutes: 25.0},
      %{week_start: ~D[2026-05-11], minutes: 40.0}
    ]

    model = Series.weekly_minutes(rows)

    assert Enum.map(model.points, & &1.week_start) == [~D[2026-05-11], ~D[2026-05-18]]
    assert model.max_minutes == 40.0
  end

  test "progress returns empty model for no sessions" do
    assert %{points: [], max_count: 0, min_pace: nil, max_pace: nil} = Series.progress([])
  end

  test "progress keeps chronological count and pace points" do
    sessions = [
      %{inserted_at: ~U[2026-05-20 10:00:00Z], burpee_count_actual: 30, duration_sec_actual: 90},
      %{inserted_at: ~U[2026-05-18 10:00:00Z], burpee_count_actual: 20, duration_sec_actual: 80}
    ]

    model = Series.progress(sessions)

    assert Enum.map(model.points, & &1.burpee_count) == [20, 30]
    assert Enum.map(model.points, & &1.sec_per_burpee) == [4.0, 3.0]
    assert model.max_count == 30
    assert model.min_pace == 3.0
    assert model.max_pace == 4.0
  end
end
