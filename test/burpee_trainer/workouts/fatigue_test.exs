defmodule BurpeeTrainer.Workouts.FatigueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Workouts.Fatigue

  # Sets of `reps` at `spr` seconds per rep, separated by `rest` seconds.
  defp program(sets, reps, spr, rest) do
    work = %{kind: :work, reps: reps, sec_per_rep: spr}

    [work | List.duplicate([%{kind: :rest, duration_sec: rest}, work], sets - 1)]
    |> List.flatten()
  end

  # When each rep is due, in ms, shifted by `lag.(set, rep)` seconds.
  defp on_beat(sets, reps, spr, rest, lag \\ fn _set, _rep -> 0.0 end) do
    for set <- 0..(sets - 1), rep <- 1..reps do
      round((set * (reps * spr + rest) + rep * spr + lag.(set, rep)) * 1_000)
    end
  end

  defp shape do
    gen all(
          sets <- integer(3..8),
          reps <- integer(6..20),
          spr <- member_of([4.0, 6.0, 8.5, 12.0]),
          rest <- member_of([0, 15, 30, 45])
        ) do
      {sets, reps, spr, rest}
    end
  end

  property "keeping up on the beat reads as no fatigue" do
    check all({sets, reps, spr, rest} <- shape(), offset <- float(min: 0.0, max: 1.0)) do
      fatigue =
        Fatigue.compute(
          on_beat(sets, reps, spr, rest, fn _, _ -> offset end),
          program(sets, reps, spr, rest)
        )

      assert fatigue.coverage == 1.0
      assert fatigue.kept_up
      assert fatigue.slip_at_sec == nil
      assert abs(fatigue.pace_delta_sec) < 0.01
      assert abs(fatigue.decline) < 0.01
      assert fatigue.consistency == 1.0
      if rest > 0, do: assert(abs(fatigue.recovery_delta_sec) < 0.01)
    end
  end

  property "one missed or extra detection does not shift the reps after it" do
    check all(
            {sets, reps, spr, rest} <- shape(),
            drop <- integer(0..(sets * reps - 1)),
            extra? <- boolean()
          ) do
      beats = on_beat(sets, reps, spr, rest)

      cadence =
        if extra?,
          do: Enum.sort([Enum.at(beats, drop) + round(spr * 600) | beats]),
          else: List.delete_at(beats, drop)

      fatigue = Fatigue.compute(cadence, program(sets, reps, spr, rest))

      assert fatigue.kept_up
      assert abs(fatigue.pace_delta_sec) < 0.01
      assert abs(fatigue.decline) < 0.01
    end
  end

  property "decline is relative to the plan, so the same session at another pace reads the same" do
    check all(
            {sets, reps, spr, rest} <- shape(),
            scale <- member_of([0.5, 2.0]),
            fade <- float(min: 0.0, max: 0.03)
          ) do
      # Each rep a little later than the last, a fraction of the interval.
      lag = fn base -> fn set, rep -> (set * reps + rep) * fade * base end end

      at = fn s ->
        Fatigue.compute(
          on_beat(sets, reps, spr * s, rest * s, lag.(spr * s)),
          program(sets, reps, spr * s, rest * s)
        )
      end

      assert_in_delta at.(1.0).decline, at.(scale).decline, 0.01
    end
  end

  property "running ahead of the beat reads as keeping up, however far ahead" do
    check all({sets, reps, spr, rest} <- shape(), pace <- float(min: 0.5, max: 1.0)) do
      # Each set's reps at `pace` of the planned interval: the set ends early.
      ahead = fn _set, rep -> -rep * spr * (1 - pace) end

      fatigue =
        Fatigue.compute(on_beat(sets, reps, spr, rest, ahead), program(sets, reps, spr, rest))

      assert fatigue.coverage == 1.0
      assert fatigue.kept_up
      assert fatigue.slip_at_sec == nil
      assert fatigue.pace_delta_sec <= 0
    end
  end

  property "recovery is how late a set's first rep lands, not when the set before ended" do
    check all(
            {sets, reps, spr, rest} <- shape(),
            rest > 0,
            pace <- float(min: 0.5, max: 1.0),
            # Under half the shortest interval, past which the first rep reads as missed.
            restart <- float(min: 0.0, max: 1.9)
          ) do
      # Each set run ahead and finished early; every set after the first restarts late.
      lag = fn
        0, rep -> -(rep - 1) * spr * (1 - pace)
        _set, rep -> restart - (rep - 1) * spr * (1 - pace)
      end

      fatigue =
        Fatigue.compute(on_beat(sets, reps, spr, rest, lag), program(sets, reps, spr, rest))

      assert_in_delta fatigue.recovery_delta_sec, restart, 0.01
    end
  end

  test "pace consistency is how even each set was against its own planned pace" do
    # A ladder: 6, 4 and 8 s per rep, with rests between.
    events = [
      %{kind: :work, reps: 6, sec_per_rep: 6.0},
      %{kind: :rest, duration_sec: 30},
      %{kind: :work, reps: 6, sec_per_rep: 4.0},
      %{kind: :rest, duration_sec: 45},
      %{kind: :work, reps: 6, sec_per_rep: 8.0}
    ]

    beats = fn jitter ->
      [{0.0, 6.0}, {66.0, 4.0}, {135.0, 8.0}]
      |> Enum.flat_map(fn {start, spr} ->
        for rep <- 1..6, do: round((start + rep * spr + jitter.(rep) * spr) * 1_000)
      end)
    end

    assert Fatigue.compute(beats.(fn _rep -> 0.0 end), events).consistency == 1.0

    uneven =
      Fatigue.compute(beats.(fn rep -> if rem(rep, 2) == 0, do: 0.2, else: 0.0 end), events)

    assert uneven.consistency < 0.9
  end

  test "finishing the last set early is not falling behind" do
    # Ten sets of fifteen every 6 s with 30 s rests, the last done 12 s ahead of its end.
    ahead = fn set, rep -> if set == 9, do: -rep * 0.8, else: 0.0 end
    fatigue = Fatigue.compute(on_beat(10, 15, 6.0, 30, ahead), program(10, 15, 6.0, 30))

    assert fatigue.kept_up
    assert fatigue.slip_at_sec == nil
  end

  test "falling behind from the last third on marks where it began" do
    # Six sets of ten every 8 s with 30 s rests; from the fifth set each rep lands 2.5 s late.
    lag = fn set, _rep -> if set >= 4, do: 2.5, else: 0.0 end
    fatigue = Fatigue.compute(on_beat(6, 10, 8.0, 30, lag), program(6, 10, 8.0, 30))

    refute fatigue.kept_up
    assert fatigue.slip_at_sec == 4 * (10 * 8.0 + 30)
  end

  test "reps dropped late count as slipping, a camera that missed the start yields nothing" do
    beats = on_beat(6, 10, 8.0, 30)
    events = program(6, 10, 8.0, 30)

    late =
      Fatigue.compute(Enum.take(beats, 50) ++ Enum.take_every(Enum.drop(beats, 50), 2), events)

    refute late.kept_up
    assert late.slip_at_sec == 5 * (10 * 8.0 + 30)

    blind = Fatigue.compute(Enum.drop(beats, 15), events)
    assert blind.coverage == 0.75
    assert blind.kept_up == nil
  end

  test "an empty program or no detections" do
    assert Fatigue.compute([1_000], []).coverage == nil
    assert Fatigue.compute([], program(3, 10, 8.0, 30)).coverage == 0.0
  end
end
