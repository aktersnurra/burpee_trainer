defmodule BurpeeTrainer.Coach.Policy.WeekTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias BurpeeTrainer.Coach.Policy.Week

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
