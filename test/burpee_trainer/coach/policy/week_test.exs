defmodule BurpeeTrainer.Coach.Policy.WeekTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Coach.Policy.Week

  # 2026-10-05 is a Monday.
  test "a regular week has the full target and weekend catch-up days" do
    assert %Week{start: ~D[2026-10-12], target_sec: 4_800, catch_up_days: [6, 7]} =
             Week.new(~D[2026-10-09], ~D[2026-10-12])
  end

  test "the sign-up week is pro-rated by days left and has no catch-up days" do
    for {sign_up, target} <- [
          {~D[2026-10-05], 4_800},
          {~D[2026-10-08], 4_800},
          {~D[2026-10-09], 3_600},
          {~D[2026-10-10], 2_400},
          {~D[2026-10-11], 1_200}
        ] do
      assert %Week{start: ~D[2026-10-05], target_sec: ^target, catch_up_days: []} =
               Week.new(sign_up, ~D[2026-10-05])
    end
  end

  property "only the sign-up week differs, and its target is 20 min per day left, capped at 80" do
    check all(sign_up <- date_gen(), offset <- integer(-2..3)) do
      week_start = Date.add(Date.beginning_of_week(sign_up), 7 * offset)
      week = Week.new(sign_up, week_start)

      assert week.start == week_start

      if offset == 0 do
        days_left = Date.diff(Date.end_of_week(sign_up), sign_up) + 1
        assert week.target_sec == min(1_200 * days_left, 4_800)
        assert week.catch_up_days == []
      else
        assert week.target_sec == 4_800
        assert week.catch_up_days == [6, 7]
      end
    end
  end

  defp date_gen, do: map(integer(0..3_650), &Date.add(~D[2024-01-01], &1))
end
