defmodule BurpeeTrainer.LevelsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Levels

  # A level is N reps in 20 minutes; only a session of about 20 minutes (±10 s) counts.
  property "a session counts toward a level only when it lasted 20 minutes ± 10 seconds" do
    check all(
            burpee_type <- member_of([:six_count, :navy_seal]),
            duration <- integer(0..2_400),
            count <- integer(1..400)
          ) do
      session = %{
        burpee_type: burpee_type,
        duration_sec_actual: duration,
        burpee_count_actual: count,
        completed_at: ~U[2026-10-05 12:00:00Z]
      }

      expected =
        if duration in 1_190..1_210,
          do: Levels.level_for_count(burpee_type, count),
          else: :level_1a

      assert Levels.level_for_type([session], burpee_type) == expected
    end
  end
end
