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
end
