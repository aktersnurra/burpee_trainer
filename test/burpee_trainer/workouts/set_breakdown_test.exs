defmodule BurpeeTrainer.Workouts.SetBreakdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BurpeeTrainer.Workouts.SetBreakdown

  defp program(sets, reps, spr, rest) do
    work = %{kind: :work, reps: reps, sec_per_rep: spr}

    [work | List.duplicate([%{kind: :rest, duration_sec: rest}, work], sets - 1)]
    |> List.flatten()
  end

  # Each set's reps at `spr`, `early.(set)` seconds ahead of the beat at the set's end,
  # spread evenly over its reps.
  defp reps(sets, reps, spr, rest, early) do
    for set <- 0..(sets - 1), rep <- 1..reps do
      start = set * (reps * spr + rest)
      round((start + rep * (spr - early.(set) / reps)) * 1_000)
    end
  end

  defp shape do
    gen all(
          sets <- integer(3..10),
          reps <- integer(3..20),
          spr <- member_of([3.0, 4.0, 6.0, 8.5]),
          rest <- member_of([10, 30, 45])
        ) do
      {sets, reps, spr, rest}
    end
  end

  property "on the beat, every set is complete, on plan, and its slack is its rest" do
    check all({sets, reps, spr, rest} <- shape()) do
      result =
        SetBreakdown.compute(
          reps(sets, reps, spr, rest, fn _ -> 0 end),
          program(sets, reps, spr, rest)
        )

      assert length(result.sets) == sets

      for set <- result.sets do
        assert set["reps"] == reps
        assert abs(set["finish_vs_plan_sec"]) < 0.01
        assert length(set["rep_times_sec"]) == reps
      end

      measured = Enum.reject(result.sets, &(&1["rest_after_sec"] == 0))
      assert Enum.all?(measured, &(abs(&1["slack_sec"] - rest) < 0.01))
      assert abs(result.active_pace_sec - spr) < 0.01
      assert abs(result.window_slack["trend_sec_per_set"]) < 0.01
    end
  end

  property "every counted rep lands in exactly one set" do
    check all(
            {sets, reps, spr, rest} <- shape(),
            jitter <- list_of(integer(-500..500), length: sets * reps)
          ) do
      cadence =
        reps(sets, reps, spr, rest, fn _ -> 0 end)
        |> Enum.zip(jitter)
        |> Enum.map(fn {t, j} -> max(t + j, 0) end)
        |> Enum.sort()

      result = SetBreakdown.compute(cadence, program(sets, reps, spr, rest))
      assert result.sets |> Enum.map(& &1["reps"]) |> Enum.sum() == length(cadence)
    end
  end

  property "finishing each set less early shrinks the slack, and the trend says so" do
    check all({sets, reps, spr, rest} <- shape(), lead <- float(min: 0.05, max: 0.5)) do
      # The first set ends a `lead` share of its work early, each later one less.
      early = fn set -> lead * reps * spr * (sets - set) / sets end

      result =
        SetBreakdown.compute(reps(sets, reps, spr, rest, early), program(sets, reps, spr, rest))

      slack = Enum.map(Enum.take(result.sets, sets - 1), & &1["slack_sec"])

      assert slack == Enum.sort(slack, :desc)
      assert result.window_slack["trend_sec_per_set"] < 0
      assert result.active_pace_sec < spr
    end
  end

  test "a set the camera did not finish has no finish or slack" do
    result = SetBreakdown.compute([4_000, 8_000, 12_000, 64_000], program(2, 3, 4.0, 30))

    assert [%{"reps" => 3, "slack_sec" => 30.0}, %{"reps" => 1, "slack_sec" => nil} = last] =
             result.sets

    assert last["rep_times_sec"] == [22.0]
    assert result.window_slack == nil
    assert result.active_pace_sec == 4.0
  end

  test "without detected reps or a program there is nothing to break down" do
    empty = %{sets: [], active_pace_sec: nil, window_slack: nil, fade: nil}
    assert SetBreakdown.for_session(nil, %{"events" => []}) == empty
    assert SetBreakdown.for_session("[1000]", nil) == empty
  end

  # Each set's reps with their gaps from the beep given by `gap.(set, rep)`.
  defp paced(sets, reps, spr, rest, gap) do
    for set <- 0..(sets - 1) do
      start = set * (reps * spr + rest)

      Enum.scan(1..reps, 0, fn rep, at -> at + gap.(set, rep) end)
      |> Enum.map(&round((start + &1) * 1_000))
    end
    |> List.flatten()
  end

  property "slowing inside each set and slowing from set to set are told apart" do
    check all({sets, reps, spr, rest} <- shape(), reps >= 6, fade <- float(min: 0.3, max: 0.5)) do
      program = program(sets, reps, spr, rest)
      steady = spr * 0.6
      # The second half of every set slower than its first, the same in every set.
      within = fn _set, rep ->
        if rep > div(reps, 2) + 1, do: steady * (1 + fade), else: steady
      end

      # Every rep of a set equally slower the later the set.
      across = fn set, _rep -> steady * (1 + fade * set / sets) end

      assert SetBreakdown.compute(paced(sets, reps, spr, rest, within), program).fade["pattern"] ==
               "within_sets"

      assert SetBreakdown.compute(paced(sets, reps, spr, rest, across), program).fade["pattern"] ==
               "across_sets"

      assert SetBreakdown.compute(paced(sets, reps, spr, rest, fn _, _ -> steady end), program).fade[
               "pattern"
             ] == "none"
    end
  end

  test "the same workout compares set by set; another workout does not compare" do
    program = program(3, 5, 4.0, 30)
    before = SetBreakdown.compute(reps(3, 5, 4.0, 30, fn _ -> 0 end), program).sets

    now =
      SetBreakdown.compute(reps(3, 5, 4.0, 30, fn set -> if set < 2, do: 2, else: 0 end), program).sets

    assert SetBreakdown.compare(now, before) == %{
             "sets_compared" => 3,
             "sets_faster" => 2,
             "finish_change_sec" => -2.0
           }

    other = SetBreakdown.compute(reps(3, 4, 4.0, 30, fn _ -> 0 end), program(3, 4, 4.0, 30)).sets
    assert SetBreakdown.compare(now, other) == nil
  end
end
